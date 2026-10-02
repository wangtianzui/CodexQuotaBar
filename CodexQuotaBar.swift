import AppKit
import Foundation
import SwiftUI

private struct LimitWindow: Decodable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?
}

private struct RateLimits: Decodable {
    let primary: LimitWindow?
    let secondary: LimitWindow?
}

private struct RateLimitResponse: Decodable {
    let rateLimits: RateLimits?
    let rateLimitResetCredits: ResetCredits?
    let summary: TokenSummary?
    let dailyUsageBuckets: [TokenDailyBucket]?
}

private struct ResetCredits: Decodable {
    let availableCount: Int
    let credits: [ResetCredit]
}

private struct ResetCredit: Decodable {
    let status: String
    let expiresAt: TimeInterval?
}

private struct TokenSummary: Decodable {
    let lifetimeTokens: Int64?
}

private struct TokenDailyBucket: Decodable {
    let startDate: String
    let tokens: Int64
}

private struct TokenActivity {
    let lifetimeTokens: Int64?
    let latestDay: TokenDailyBucket?
}

private final class LocalTokenReader: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private struct FileState {
        var offset: UInt64 = 0
        var previous: Int64 = 0
        var pending = Data()
    }
    private var files: [String: FileState] = [:]
    private var seen = Set<String>()
    private var day: Date?
    private var tokens: Int64 = 0
    private let root: URL

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")) {
        self.root = root
    }

    // Incremental cumulative deltas avoid counting repeated token notifications twice.
    func read(at now: Date = Date(), calendar: Calendar = .current) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        if day != start {
            files.removeAll(); seen.removeAll(); tokens = 0; day = start
        }
        guard FileManager.default.isReadableFile(atPath: root.path),
              let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()
        for case let url as URL in entries where url.pathExtension == "jsonl" {
            guard let attributes = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = attributes.contentModificationDate, modified >= start,
                  let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            var state = files[url.path] ?? FileState()
            // A replaced/truncated log requires rebuilding the day's aggregate.
            if UInt64(attributes.fileSize ?? 0) < state.offset {
                files.removeAll(); seen.removeAll(); tokens = 0; day = nil
                return read(at: now, calendar: calendar)
            }
            do {
                try handle.seek(toOffset: state.offset)
                while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                    state.offset += UInt64(chunk.count)
                    state.pending.append(chunk)
                    while let newline = state.pending.firstIndex(of: 10) {
                        let line = Data(state.pending.prefix(upTo: newline))
                        state.pending.removeSubrange(...newline)
                        guard line.range(of: Data("\"token_count\"".utf8)) != nil,
                              let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                              event["type"] as? String == "event_msg",
                              let stamp = event["timestamp"] as? String,
                              let date = formatter.date(from: stamp) ?? plainFormatter.date(from: stamp),
                              let payload = event["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                              let info = payload["info"] as? [String: Any],
                              let usage = info["total_token_usage"] as? [String: Any],
                              let total = (usage["total_tokens"] as? NSNumber)?.int64Value else { continue }
                        let last = ((info["last_token_usage"] as? [String: Any])?["total_tokens"] as? NSNumber)?.int64Value ?? 0
                        let delta = total >= state.previous ? total - state.previous : last
                        state.previous = total
                        guard date >= start, date < end else { continue }
                        let key = "\(stamp)|\(total)|\(usage["input_tokens"] ?? 0)|\(usage["output_tokens"] ?? 0)"
                        if seen.insert(key).inserted { tokens += max(0, delta) }
                    }
                }
                files[url.path] = state
            } catch { continue }
        }
        return tokens
    }
}

private struct QuotaReading {
    let limits: RateLimits
    let resetCredits: ResetCredits?
    let tokenActivity: TokenActivity?
}

private enum CodexIcon {
    static let image: NSImage? = [
        "/Applications/ChatGPT.app/Contents/Resources/icon-codex-dark-color.png",
        "/Applications/Codex.app/Contents/Resources/icon-codex-dark-color.png",
        "/Applications/ChatGPT.app/Contents/Resources/icon-codex-light.png",
        "/Applications/Codex.app/Contents/Resources/icon-codex-light.png"
    ].compactMap { NSImage(contentsOfFile: $0) }.first

}

private struct ComparisonBaseline: Codable {
    let fiveHourResetAt: TimeInterval
    let weeklyResetAt: TimeInterval
    let fiveHourUsed: Double
    let weeklyUsed: Double
    let recordedAt: TimeInterval
    let coversWindowStart: Bool
}

private struct IdleQuotaReading: Codable {
    let weeklyResetAt: TimeInterval
    let weeklyUsed: Double
    let recordedAt: TimeInterval
}

private struct ComparisonCache: Codable {
    let baseline: ComparisonBaseline?
    let idle: IdleQuotaReading?
}

private struct ComparisonSnapshot {
    let weeklyIncrease: Double
    let coversWindowStart: Bool
}

private final class ComparisonTracker {
    private let storageKey = "quotaComparisonBaseline"
    private let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexQuotaBar/comparison.json")
    private var baseline: ComparisonBaseline?
    private var idle: IdleQuotaReading?
    private var recoveryAttemptedFor: String?

    init() {
        if let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(ComparisonCache.self, from: data) {
            baseline = cache.baseline
            idle = cache.idle
        } else if let data = UserDefaults.standard.data(forKey: storageKey) {
            baseline = try? JSONDecoder().decode(ComparisonBaseline.self, from: data)
            save()
        }
    }

    // The backend may round the same reset timestamp by one second.
    private func sameReset(_ lhs: TimeInterval?, _ rhs: TimeInterval) -> Bool {
        guard let lhs else { return false }
        return abs(lhs - rhs) <= 2
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(ComparisonCache(baseline: baseline, idle: idle))
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            QuotaLog.write("Comparison cache save failed: \(error.localizedDescription)")
        }
    }

    func update(_ limits: RateLimits, at date: Date) -> ComparisonSnapshot? {
        guard let five = limits.primary, let weekly = limits.secondary,
              let fiveUsed = five.usedPercent, let weeklyUsed = weekly.usedPercent,
              let fiveReset = five.resetsAt, let weeklyReset = weekly.resetsAt,
              let duration = five.windowDurationMins else { return nil }
        let now = date.timeIntervalSince1970
        let windowStart = fiveReset - Double(duration * 60)
        if fiveUsed == 0 || now >= fiveReset {
            idle = IdleQuotaReading(weeklyResetAt: weeklyReset, weeklyUsed: weeklyUsed, recordedAt: now)
            if fiveUsed == 0 {
                baseline = ComparisonBaseline(fiveHourResetAt: fiveReset, weeklyResetAt: weeklyReset, fiveHourUsed: 0, weeklyUsed: weeklyUsed, recordedAt: now, coversWindowStart: true)
            }
            save()
            return ComparisonSnapshot(weeklyIncrease: 0, coversWindowStart: true)
        }
        if baseline == nil || !sameReset(baseline?.fiveHourResetAt, fiveReset) || !sameReset(baseline?.weeklyResetAt, weeklyReset) ||
            fiveUsed < (baseline?.fiveHourUsed ?? 0) || weeklyUsed < (baseline?.weeklyUsed ?? 0) {
            // The last idle poll belongs to the moment before first use. Avoid
            // treating a stale cache from hours ago as the start of this window.
            let startReading = idle.flatMap { reading -> IdleQuotaReading? in
                guard sameReset(reading.weeklyResetAt, weeklyReset), reading.weeklyUsed <= weeklyUsed,
                      reading.recordedAt <= windowStart + 2, windowStart - reading.recordedAt <= 120 else { return nil }
                return reading
            }
            baseline = ComparisonBaseline(
                fiveHourResetAt: fiveReset,
                weeklyResetAt: weeklyReset,
                fiveHourUsed: startReading == nil ? fiveUsed : 0,
                weeklyUsed: startReading?.weeklyUsed ?? weeklyUsed,
                recordedAt: startReading?.recordedAt ?? now,
                coversWindowStart: startReading != nil
            )
            save()
            QuotaLog.write("Started five-hour comparison: fiveReset=\(fiveReset), idleBaseline=\(startReading != nil)")
        }
        let recoveryKey = "\(fiveReset):\(weeklyReset)"
        if baseline?.coversWindowStart == false && recoveryAttemptedFor != recoveryKey {
            recoveryAttemptedFor = recoveryKey
            if let recovered = recoverBaseline(fiveReset: fiveReset, weeklyReset: weeklyReset, windowStart: fiveReset - Double(duration * 60), now: now) {
            baseline = recovered
            save()
            QuotaLog.write("Recovered comparison baseline: weeklyUsed=\(recovered.weeklyUsed), fiveReset=\(fiveReset)")
            }
        }
        guard let baseline else { return nil }
        return ComparisonSnapshot(
            weeklyIncrease: max(0, weeklyUsed - baseline.weeklyUsed),
            coversWindowStart: baseline.coversWindowStart
        )
    }

    // Recover only quota events at zero usage in this exact window. Never infer
    // a weekly percentage from the five-hour percentage.
    private func recoverBaseline(fiveReset: TimeInterval, weeklyReset: TimeInterval, windowStart: TimeInterval, now: TimeInterval) -> ComparisonBaseline? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        let timestampParser = ISO8601DateFormatter()
        timestampParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var earliest: ComparisonBaseline?
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        // An old conversation can remain active today, so use file modification
        // time rather than the date in its directory name.
        for case let file as URL in files where file.pathExtension == "jsonl" {
            guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  modified.timeIntervalSince1970 >= windowStart,
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n") where line.contains("token_count") {
                    guard let data = line.data(using: .utf8),
                          let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          event["type"] as? String == "event_msg",
                          let payload = event["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                          let rates = payload["rate_limits"] as? [String: Any],
                          let primary = rates["primary"] as? [String: Any], let secondary = rates["secondary"] as? [String: Any],
                          sameReset(primary["resets_at"] as? Double, fiveReset), sameReset(secondary["resets_at"] as? Double, weeklyReset),
                          (primary["used_percent"] as? Double) == 0, let weeklyUsed = secondary["used_percent"] as? Double,
                          let stamp = event["timestamp"] as? String, let date = timestampParser.date(from: stamp) else { continue }
                    let recorded = date.timeIntervalSince1970
                    guard recorded >= windowStart - 2, recorded <= now, recorded < (earliest?.recordedAt ?? .infinity) else { continue }
                    earliest = ComparisonBaseline(fiveHourResetAt: fiveReset, weeklyResetAt: weeklyReset, fiveHourUsed: 0, weeklyUsed: weeklyUsed, recordedAt: recorded, coversWindowStart: true)
                }
        }
        return earliest
    }
}

private enum QuotaLog {
    static func write(_ message: String) {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CodexQuotaBar")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("quota.log")
        let entry = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = entry.data(using: .utf8) else { return }
        if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 262144 {
            try? FileManager.default.removeItem(at: file)
        }
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

private struct RPCResponse: Decodable {
    let id: Int?
    let result: RateLimitResponse?
    let error: RPCError?
}

private struct RPCError: Decodable {
    let message: String?
}

private enum QuotaError: LocalizedError {
    case cliMissing
    case timeout
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .cliMissing: return "找不到 Codex CLI。请安装或更新 Codex 桌面应用。"
        case .timeout: return "读取额度超时。"
        case .unavailable(let message): return message
        }
    }
}

private final class QuotaReader {
    private static let cliPaths = [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex"
    ]

    static func read() throws -> QuotaReading {
        guard let cli = cliPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw QuotaError.cliMissing
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["app-server"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            input.fileHandleForWriting.closeFile()
        }

        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-quota-bar","version":"1.0"}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read","params":{"excludeResetCreditDetails":false}}"#,
            #"{"id":3,"method":"account/usage/read","params":{}}"#
        ].joined(separator: "\n") + "\n"
        input.fileHandleForWriting.write(Data(requests.utf8))

        let quotaReady = DispatchSemaphore(value: 0)
        let usageReady = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var quotaAnswer: Result<RateLimits, Error>?
        var resetCredits: ResetCredits?
        var tokenAnswer: TokenActivity?
        DispatchQueue.global(qos: .utility).async {
            var buffer = Data()
            var hasQuota = false
            var hasUsage = false
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: newline)
                    buffer.removeSubrange(...newline)
                    guard let response = try? JSONDecoder().decode(RPCResponse.self, from: Data(line)) else { continue }
                    if response.id == 2 {
                        let result: Result<RateLimits, Error>
                        if let limits = response.result?.rateLimits {
                            result = .success(limits)
                        } else {
                            result = .failure(QuotaError.unavailable(response.error?.message ?? "Codex 未返回额度数据。请检查登录状态。"))
                        }
                        lock.lock()
                        quotaAnswer = result
                        resetCredits = response.result?.rateLimitResetCredits
                        lock.unlock()
                        hasQuota = true
                        quotaReady.signal()
                    } else if response.id == 3 {
                        lock.lock()
                        if let usage = response.result {
                            tokenAnswer = TokenActivity(
                                lifetimeTokens: usage.summary?.lifetimeTokens,
                                latestDay: usage.dailyUsageBuckets?.max(by: { $0.startDate < $1.startDate })
                            )
                        }
                        lock.unlock()
                        hasUsage = true
                        usageReady.signal()
                    }
                    if hasQuota && hasUsage { return }
                }
            }
            if !hasQuota {
                lock.lock()
                quotaAnswer = .failure(QuotaError.unavailable("Codex 连接已关闭。请检查登录状态。"))
                lock.unlock()
                quotaReady.signal()
            }
            if !hasUsage { usageReady.signal() }
        }
        guard quotaReady.wait(timeout: .now() + 15) == .success else { throw QuotaError.timeout }
        _ = usageReady.wait(timeout: .now() + 2)
        lock.lock()
        let quota = quotaAnswer
        let credits = resetCredits
        let tokens = tokenAnswer
        lock.unlock()
        return QuotaReading(limits: try quota!.get(), resetCredits: credits, tokenActivity: tokens)
    }
}

@MainActor
private final class PanelState: ObservableObject {
    @Published var short: LimitWindow?
    @Published var weekly: LimitWindow?
    @Published var lastUpdated: Date?
    @Published var errorMessage: String?
    @Published var refreshInProgress = false
    @Published var tokenActivity: TokenActivity?
    @Published var localTodayTokens: Int64?
    @Published var resetCredits: ResetCredits?
    @Published var comparison: ComparisonSnapshot?
}

private struct FrostedBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct QuotaPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var state: PanelState
    let panelHeight: CGFloat
    let onRefresh: () -> Void
    let onQuit: () -> Void

    private var fiveHourColor: Color {
        colorScheme == .dark ? Color(red: 0.31, green: 0.92, blue: 0.53) : Color(red: 0.05, green: 0.56, blue: 0.27)
    }

    private var weeklyColor: Color {
        colorScheme == .dark ? Color(red: 0.78, green: 0.91, blue: 0.37) : Color(red: 0.45, green: 0.55, blue: 0.07)
    }

    private var usedColor: Color {
        colorScheme == .dark ? Color(red: 1.0, green: 0.55, blue: 0.42) : Color(red: 0.76, green: 0.27, blue: 0.18)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Group {
                    if let icon = CodexIcon.image {
                        Image(nsImage: icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(fiveHourColor.gradient, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex 额度")
                        .font(.system(size: 16, weight: .semibold))
                    Text("5 小时与 7 天用量")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("立即刷新")
                .disabled(state.refreshInProgress)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    quotaCard(title: "5 小时", symbol: "clock", window: state.short, color: fiveHourColor, isWeekly: false)
                    quotaCard(title: "7 天", symbol: "calendar", window: state.weekly, color: weeklyColor, isWeekly: true)

                    if let resetCredits = state.resetCredits {
                        resetCreditCard(resetCredits)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Token 统计")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("本机 / 云端")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 0) {
                            tokenMetric("今日本机估算", value: state.localTodayTokens)
                            Spacer()
                            tokenMetric("账号累计", value: state.tokenActivity?.lifetimeTokens)
                        }
                        Text("云端 \(latestDayLabel)汇总：\((state.tokenActivity?.latestDay?.tokens).map(formatTokens) ?? "暂无数据") · 可能延迟")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("本机按本地日期汇总，含缓存输入；不含其他设备，不能换算额度。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))

                    if let errorMessage = state.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(usedColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
            }

            Divider()

            HStack(spacing: 6) {
                Circle()
                    .fill(state.errorMessage == nil ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(footerStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("退出 Codex 额度", action: onQuit)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 22)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .frame(width: 338, height: panelHeight)
        .background(FrostedBackground().opacity(0.76))
    }

    private func quotaCard(title: String, symbol: String, window: LimitWindow?, color: Color, isWeekly: Bool) -> some View {
        let remaining = window?.usedPercent.map { max(0, min(100, 100 - $0)) }
        let used = window?.usedPercent.map { max(0, min(100, $0)) }
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                Spacer()
                Text("\(countdown(window))后重置")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(color.opacity(0.13), in: Capsule())
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(remaining.map { "\(Int($0.rounded()))" } ?? "—")
                    .font(.system(size: 31, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
                Text("% 剩余")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.11))
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: geometry.size.width * CGFloat((remaining ?? 0) / 100))
                }
            }
            .frame(height: 8)
            HStack(spacing: 8) {
                if isWeekly {
                    Text(weeklyChangeLabel)
                        .help(state.comparison?.coversWindowStart == true ? "本轮 5 小时内，7 天剩余额度下降的百分点" : "下一次 5 小时重置后开始记录整轮变化")
                } else {
                    Text(used.map { "5小时 −\(Int($0.rounded()))%" } ?? "5小时 —%")
                        .help("当前 5 小时额度已使用的比例")
                }
            }
            .foregroundStyle(usedColor)
            .font(.system(size: 11, weight: .medium))
            HStack {
                Text("重置于")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(resetDate(window))
                    .monospacedDigit()
            }
            .font(.system(size: 11))
        }
        .padding(12)
        .background(color.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.17)))
    }

    private func tokenMetric(_ title: String, value: Int64?) -> some View {
        let label = value.map(formatTokens) ?? "暂无数据"
        return VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: value == nil ? 11 : 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(value == nil ? Color.secondary : weeklyColor)
        }
    }

    private func resetCreditCard(_ summary: ResetCredits) -> some View {
        let available = summary.credits
            .filter { $0.status == "available" && ($0.expiresAt ?? 0) > Date().timeIntervalSince1970 }
            .sorted { ($0.expiresAt ?? .infinity) < ($1.expiresAt ?? .infinity) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("额度重置券", systemImage: "arrow.counterclockwise.circle")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("可用 \(summary.availableCount) 次")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(fiveHourColor)
            }
            ForEach(Array(available.enumerated()), id: \.offset) { index, credit in
                HStack {
                    Text("第 \(index + 1) 次")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(credit.expiresAt.map { "有效期至 \(formatCreditExpiry($0))" } ?? "有效期未知")
                        .monospacedDigit()
                }
                .font(.system(size: 11))
            }
            if available.isEmpty {
                Text("暂无可用重置券")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func formatCreditExpiry(_ timestamp: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    private func formatPoints(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private var weeklyChangeLabel: String {
        guard let comparison = state.comparison, comparison.coversWindowStart else { return "7天 —%" }
        return "7天 −\(formatPoints(comparison.weeklyIncrease))%"
    }

    private var latestDayLabel: String {
        guard let raw = state.tokenActivity?.latestDay?.startDate else { return "最近可用日" }
        let input = DateFormatter()
        input.dateFormat = "yyyy-MM-dd"
        guard let date = input.date(from: raw) else { return raw }
        let output = DateFormatter()
        output.locale = Locale(identifier: "zh_CN")
        output.dateFormat = "M月d日"
        return output.string(from: date)
    }

    private func formatTokens(_ value: Int64) -> String {
        if value >= 100_000_000 { return String(format: "%.1f亿", Double(value) / 100_000_000) }
        if value >= 10_000 { return String(format: "%.1f万", Double(value) / 10_000) }
        return value.formatted()
    }

    private var footerStatus: String {
        if state.refreshInProgress { return "正在更新…" }
        guard let lastUpdated = state.lastUpdated else { return "等待首次更新" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "更新于 \(formatter.string(from: lastUpdated)) · 每分钟自动刷新"
    }

    private func countdown(_ window: LimitWindow?) -> String {
        guard let timestamp = window?.resetsAt else { return "—" }
        let minutes = max(0, Int((timestamp - Date().timeIntervalSince1970) / 60))
        if minutes >= 1440 { return "\(minutes / 1440) 天 \((minutes % 1440) / 60) 小时" }
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分" }
        return "\(minutes) 分"
    }

    private func resetDate(_ window: LimitWindow?) -> String {
        guard let timestamp = window?.resetsAt else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEE HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}

@MainActor
private final class QuotaBar: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var previewWindow: NSWindow?
    private let panelState = PanelState()
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var limits: RateLimits?
    private var lastUpdated: Date?
    private var errorMessage: String?
    private var tokenActivity: TokenActivity?
    private var resetCredits: ResetCredits?
    private let comparisonTracker = ComparisonTracker()
    private let localTokenReader = LocalTokenReader()
    private var localTodayTokens: Int64?
    private var comparison: ComparisonSnapshot?
    private var refreshInProgress = false
    private var refreshTimer: Timer?
    private var clockTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preview = CommandLine.arguments.contains("--preview")
        NSApp.setActivationPolicy(preview ? .regular : .accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: 87)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "Codex 额度"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        let availableHeight = statusItem.button?.window?.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 700
        let panelHeight = min(570, max(320, availableHeight - 120))
        popover.contentSize = NSSize(width: 338, height: panelHeight)
        let panel = QuotaPanel(
            state: panelState,
            panelHeight: panelHeight,
            onRefresh: { [weak self] in self?.refresh() },
            onQuit: { NSApp.terminate(nil) }
        )
        popover.contentViewController = NSHostingController(rootView: panel)
        if preview {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 338, height: panelHeight), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Codex 额度 · 预览"
            window.center()
            window.contentViewController = NSHostingController(rootView: panel)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            previewWindow = window
        }
        render()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
    }

    private func refresh() {
        guard !refreshInProgress else { return }
        refreshInProgress = true
        let tokenReader = localTokenReader
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let localToday = tokenReader.read()
            let result = Result { try QuotaReader.read() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshInProgress = false
                self.localTodayTokens = localToday
                switch result {
                case .success(let reading):
                    self.limits = reading.limits
                    self.lastUpdated = Date()
                    self.errorMessage = nil
                    self.tokenActivity = reading.tokenActivity
                    self.resetCredits = reading.resetCredits
                    self.comparison = self.comparisonTracker.update(reading.limits, at: self.lastUpdated!)
                    QuotaLog.write("Quota: fiveUsed=\(reading.limits.primary?.usedPercent.map { String($0) } ?? "nil"), weeklyUsed=\(reading.limits.secondary?.usedPercent.map { String($0) } ?? "nil"), weeklyChange=\(self.comparison?.weeklyIncrease.description ?? "nil"), completeBaseline=\(self.comparison?.coversWindowStart.description ?? "nil")")
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                    QuotaLog.write("Quota refresh failed: \(error.localizedDescription)")
                }
                self.render()
            }
        }
    }

    private func remaining(_ window: LimitWindow?) -> String {
        guard let used = window?.usedPercent else { return "—" }
        return "\(Int(max(0, min(100, (100 - used).rounded()))))%"
    }

    private func render() {
        let short = limits?.primary
        let weekly = limits?.secondary
        statusItem.button?.title = ""
        statusItem.button?.image = makeStatusImage(
            first: "5h \(remaining(short))",
            second: "7d \(remaining(weekly))",
            warning: errorMessage != nil
        )
        statusItem.button?.toolTip = "5 小时剩余 \(remaining(short)) · 7 天剩余 \(remaining(weekly))" + (errorMessage == nil ? "" : " · 更新失败")
        panelState.short = short
        panelState.weekly = weekly
        panelState.lastUpdated = lastUpdated
        panelState.errorMessage = errorMessage
        panelState.refreshInProgress = refreshInProgress
        panelState.tokenActivity = tokenActivity
        panelState.localTodayTokens = localTodayTokens
        panelState.resetCredits = resetCredits
        panelState.comparison = comparison
    }

    private func makeStatusImage(first: String, second: String, warning: Bool) -> NSImage {
        let size = NSSize(width: 83, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            // Six linked loops echo a knot; an open segment distinguishes quota.
            for index in 0..<6 {
                NSGraphicsContext.saveGraphicsState()
                let transform = AffineTransform(
                    translationByX: 11, byY: 11)
                var rotation = transform
                rotation.rotate(byDegrees: CGFloat(index) * 60)
                rotation.translate(x: -11, y: -11)
                (rotation as NSAffineTransform).concat()
                let loop = NSBezierPath(roundedRect: NSRect(x: 8, y: 9, width: 7, height: 11), xRadius: 3.5, yRadius: 3.5)
                loop.lineWidth = 1.45
                loop.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            let center = NSBezierPath()
            for index in 0..<6 {
                let angle = Double(index) * .pi / 3
                let point = NSPoint(x: 11 + cos(angle) * 2.8, y: 11 + sin(angle) * 2.8)
                if index == 0 { center.move(to: point) } else { center.line(to: point) }
            }
            center.close()
            center.fill()
            NSBezierPath(rect: NSRect(x: 16.6, y: 3.3, width: 3.2, height: 2.2)).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setBlendMode(.sourceAtop)
            NSGradient(colors: [
                NSColor(red: 0.96, green: 0.78, blue: 0.80, alpha: 1),
                NSColor(red: 0.96, green: 0.84, blue: 0.74, alpha: 1),
                NSColor(red: 0.94, green: 0.91, blue: 0.74, alpha: 1),
                NSColor(red: 0.76, green: 0.91, blue: 0.81, alpha: 1),
                NSColor(red: 0.75, green: 0.89, blue: 0.93, alpha: 1),
                NSColor(red: 0.80, green: 0.83, blue: 0.96, alpha: 1),
                NSColor(red: 0.90, green: 0.80, blue: 0.94, alpha: 1)
            ])?.draw(in: NSRect(x: 0, y: 0, width: 22, height: 22), angle: 45)
            NSGraphicsContext.restoreGraphicsState()
            let style = NSMutableParagraphStyle()
            style.alignment = .left
            style.lineBreakMode = .byClipping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style
            ]
            let firstLine = (warning ? "! " : "") + first
            firstLine.draw(in: NSRect(x: 26, y: 11, width: rect.width - 26, height: 11), withAttributes: attributes)
            second.draw(in: NSRect(x: 26, y: 0, width: rect.width - 26, height: 11), withAttributes: attributes)
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.close()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startOutsideClickMonitors()
        }
    }

    private func startOutsideClickMonitors() {
        stopOutsideClickMonitors()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.closeIfClickedOutside() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.closeIfClickedOutside()
            return event
        }
    }

    private func closeIfClickedOutside() {
        guard popover.isShown else { return }
        let point = NSEvent.mouseLocation
        if statusItem.button?.window?.frame.contains(point) == true { return }
        if popover.contentViewController?.view.window?.frame.contains(point) == true { return }
        popover.close()
    }

    private func stopOutsideClickMonitors() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor); self.globalClickMonitor = nil }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor); self.localClickMonitor = nil }
    }

    func popoverDidClose(_ notification: Notification) { stopOutsideClickMonitors() }

}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = QuotaBar()
    app.delegate = delegate
    app.run()
}
