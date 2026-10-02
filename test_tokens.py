#!/usr/bin/env python3
"""Test the production local token reader with isolated logs and a local day boundary."""
import json,subprocess,tempfile
from pathlib import Path
source=(Path(__file__).parent/'CodexQuotaBar.swift').read_text()
reader=source[source.index('private final class LocalTokenReader'):source.index('private struct QuotaReading')].replace('private ', '')
with tempfile.TemporaryDirectory() as folder:
 root=Path(folder)
 def event(stamp,total,last=0):
  return json.dumps(dict(type='event_msg',timestamp=stamp,payload=dict(type='token_count',info=dict(total_token_usage=dict(total_tokens=total,input_tokens=total,output_tokens=0),last_token_usage=dict(total_tokens=last)))))+'\n'
 before=event('2026-10-01T15:59:00Z',100)
 a=event('2026-10-01T16:01:00Z',150)
 b=event('2026-10-02T01:00:00Z',200)
 (root/'a.jsonl').write_text(before+a+a+b)
 (root/'fork.jsonl').write_text(before+a+b)
 cases='''
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 28800)!
let now = ISO8601DateFormatter().date(from: "2026-10-02T12:00:00Z")!
let root = URL(fileURLWithPath: ROOT)
let reader = LocalTokenReader(root: root)
assert(reader.read(at: now, calendar: calendar) == 100, "Midnight baseline, duplicate event and fork history")
assert(reader.read(at: now, calendar: calendar) == 100, "Refresh must not recount")
let handle = try FileHandle(forWritingTo: root.appendingPathComponent("a.jsonl"))
try handle.seekToEnd()
let next = NEXT
let split = next.count / 2
try handle.write(contentsOf: next.prefix(split))
assert(reader.read(at: now, calendar: calendar) == 100, "Incomplete notification waits")
try handle.write(contentsOf: next.dropFirst(split))
assert(reader.read(at: now, calendar: calendar) == 160, "Incremental complete notification")
try handle.write(contentsOf: RESET)
assert(reader.read(at: now, calendar: calendar) == 180, "Cumulative reset uses last usage")
try handle.close()
let nextDay = now.addingTimeInterval(86400)
assert(reader.read(at: nextDay, calendar: calendar) == 0, "Local midnight resets")
assert(LocalTokenReader(root: root.appendingPathComponent("missing")).read(at: now) == nil, "Missing logs are unavailable, not zero")
print("PASS: date boundary, duplicate/fork, repeat refresh, partial write, incremental read, cumulative reset, unavailable logs")
'''.replace('ROOT',json.dumps(str(root))).replace('NEXT','Data('+json.dumps(event('2026-10-02T02:00:00Z',260)) + '.utf8)').replace('RESET','Data('+json.dumps(event('2026-10-02T03:00:00Z',20,20))+'.utf8)')
 swift=root/'tests.swift';swift.write_text('import Foundation\n'+reader+cases)
 subprocess.run(['swift',str(swift)],check=True)
