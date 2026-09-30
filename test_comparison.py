#!/usr/bin/env python3
"""Run quota comparison cases against the shipped Swift source in isolated storage."""
import json
import subprocess
import tempfile
from pathlib import Path

source = (Path(__file__).resolve().parent / "CodexQuotaBar.swift").read_text()
models = source[source.index("private struct LimitWindow"):source.index("private struct RateLimitResponse")]
tracker = source[source.index("private struct ComparisonBaseline"):source.index("private struct RPCResponse")]
CASES = 'let prefs = UserDefaults(suiteName: "local.codex.quota.bar.regression")!\nprefs.removePersistentDomain(forName: "local.codex.quota.bar.regression")\nlet file = TEST_CACHE_PATH\ntry? FileManager.default.removeItem(atPath: file)\ndefer { try? FileManager.default.removeItem(atPath: file); prefs.removePersistentDomain(forName: "local.codex.quota.bar.regression") }\nfunc reading(_ five: Double, _ weekly: Double, _ reset: Double) -> RateLimits {\n RateLimits(primary: LimitWindow(usedPercent: five, windowDurationMins: 300, resetsAt: reset), secondary: LimitWindow(usedPercent: weekly, windowDurationMins: 10080, resetsAt: 1791053626))\n}\nlet tracker = ComparisonTracker()\nlet current = tracker.update(reading(20, 24, 1790777830), at: Date(timeIntervalSince1970: 1790764200))!\nassert(current.coversWindowStart && current.weeklyIncrease == 3, "Recover existing window")\nlet oldReset = 1790777830.0\nlet idle = tracker.update(reading(20, 25, oldReset), at: Date(timeIntervalSince1970: oldReset + 30))!\nassert(idle.weeklyIncrease == 0, "Expired window waits for first usage")\nlet newReset = oldReset + 60 + 18000\nlet restarted = ComparisonTracker()\nlet firstUse = restarted.update(reading(2, 26, newReset), at: Date(timeIntervalSince1970: oldReset + 65))!\nassert(firstUse.coversWindowStart && firstUse.weeklyIncrease == 1, "First use includes consumption since idle baseline across relaunch")\nlet later = restarted.update(reading(14, 28, newReset), at: Date(timeIntervalSince1970: oldReset + 600))!\nassert(later.weeklyIncrease == 3, "Continue current usage window")\nlet zeroReset = newReset + 18000\nlet zero = restarted.update(reading(0, 28, zeroReset), at: Date(timeIntervalSince1970: zeroReset - 18000))!\nassert(zero.weeklyIncrease == 0, "Zero usage records new baseline")\nlet next = ComparisonTracker().update(reading(4, 29, zeroReset), at: Date(timeIntervalSince1970: zeroReset - 17900))!\nassert(next.coversWindowStart && next.weeklyIncrease == 1, "Zero baseline survives restart")\nlet staleReset = zeroReset + 36000\nlet stale = restarted.update(reading(2, 30, staleReset), at: Date(timeIntervalSince1970: staleReset - 17990))!\nassert(!stale.coversWindowStart, "Do not use stale idle reading as exact baseline")\nprint("PASS: recovery, idle cache, first-use trigger, restart, zero-use reset, stale-cache rejection")\n'

with tempfile.TemporaryDirectory(prefix="codex-quota-test-") as folder:
    root = Path(folder)
    sessions = root / ".codex/sessions"
    sessions.mkdir(parents=True)
    event = {"type": "event_msg", "timestamp": "2026-09-30T09:19:28.582Z", "payload": {
        "type": "token_count", "rate_limits": {
            "primary": {"used_percent": 0, "resets_at": 1790777830},
            "secondary": {"used_percent": 21, "resets_at": 1791053626}}}}
    (sessions / "fixture.jsonl").write_text(json.dumps(event) + "\n")
    tracker = tracker.replace("FileManager.default.homeDirectoryForCurrentUser", "URL(fileURLWithPath: " + json.dumps(folder) + ")")
    tracker = tracker.replace("UserDefaults.standard", 'UserDefaults(suiteName: "local.codex.quota.bar.regression")!')
    cases = CASES.replace("TEST_CACHE_PATH", json.dumps(str(root / "Library/Application Support/CodexQuotaBar/comparison.json")))
    swift = root / "comparison-tests.swift"
    swift.write_text(("import Foundation\n" + models + tracker + cases).replace("private ", ""))
    subprocess.run(["swift", str(swift)], check=True)
