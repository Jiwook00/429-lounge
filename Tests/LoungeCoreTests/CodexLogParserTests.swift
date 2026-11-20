import Foundation
import Testing
@testable import LoungeCore

// codex-cli 0.170.0 실제 로그 형식 (값만 줄임)
private func usage(_ input: Int, cached: Int, output: Int) -> String {
    #"{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":\#(input + output)}"#
}

private func record(_ resp: String, ts: String, input: Int, cached: Int, output: Int) -> String {
    #"{"timestamp":"\#(ts)","type":"token_usage_record","payload":{"response_id":"\#(resp)","usage":\#(usage(input, cached: cached, output: output))}}"#
}

private func tokenCount(ts: String, total: Int, last: (Int, Int, Int), primary: String = #"{"used_percent":0.0,"window_minutes":300,"resets_at":1797731014}"#) -> String {
    #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total)},"last_token_usage":\#(usage(last.0, cached: last.1, output: last.2))},"rate_limits":{"limit_id":"codex","primary":\#(primary),"secondary":null,"rate_limit_reached_type":null}}}"#
}

@Test func codexCountsUsageRecordsOnce() {
    let log = [
        record("r1", ts: "2026-11-20T01:43:36.127Z", input: 13522, cached: 10624, output: 15),
        record("r1", ts: "2026-11-20T01:43:36.127Z", input: 13522, cached: 10624, output: 15),
        tokenCount(ts: "2026-11-20T01:43:36.129Z", total: 13537, last: (13522, 10624, 15)),
        record("r2", ts: "2026-11-20T01:43:50.999Z", input: 13559, cached: 10624, output: 122),
        #"{"timestamp":"2026-11-20T01:43:34Z","type":"response_item","payload":{"type":"message","content":"token_usage_record"}}"#,
    ].joined(separator: "\n")

    var p = CodexLogParser()
    p.consume(Data(log.utf8))
    #expect(p.records.count == 2) // token_count는 record가 있으면 안 쓴다
    var t = TokenTotals()
    p.records.forEach { t.add($0) }
    // fresh = 입력 - 캐시 + 출력
    #expect(t.fresh == (13522 - 10624 + 15) + (13559 - 10624 + 122))
    #expect(t.cacheRead == 10624 * 2)
}

@Test func codexFallsBackToTokenCount() {
    let log = [
        tokenCount(ts: "2026-11-20T01:00:00Z", total: 100, last: (90, 50, 10)),
        tokenCount(ts: "2026-11-20T01:00:01Z", total: 100, last: (90, 50, 10)), // 같은 누계 중복
        tokenCount(ts: "2026-11-20T01:01:00Z", total: 150, last: (45, 0, 5)),
    ].joined(separator: "\n")
    var p = CodexLogParser()
    p.consume(Data(log.utf8))
    #expect(p.records.count == 2)
    #expect(p.records.map { $0.input + $0.output }.reduce(0, +) == 50 + 50)
}

@Test func codexDetectsFullWindow() {
    let full = #"{"used_percent":100.0,"window_minutes":300,"resets_at":1797731014}"#
    let jitter = #"{"used_percent":100.0,"window_minutes":300,"resets_at":1797731016}"#
    let log = [
        tokenCount(ts: "2026-11-20T01:00:00Z", total: 10, last: (10, 0, 0)),
        tokenCount(ts: "2026-11-20T02:00:00Z", total: 20, last: (10, 0, 0), primary: full),
        tokenCount(ts: "2026-11-20T02:01:00Z", total: 30, last: (10, 0, 0), primary: jitter),
    ].joined(separator: "\n")
    var p = CodexLogParser()
    p.consume(Data(log.utf8))
    #expect(p.limitHits.count == 2)
    #expect(p.limitHits[0].type == "five_hour")

    // resets_at이 2초 흔들려도 하나로, 먼저 찍힌 값으로 고정
    let merged = UsageScanner.mergeHits(p.limitHits, now: Date(timeIntervalSince1970: 1797731000))
    #expect(merged.count == 1)
    #expect(merged[0].resetsAt == Date(timeIntervalSince1970: 1797731014))
}

@Test func scannerAddsClaudeAndCodex() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let claude = dir.appendingPathComponent("claude/proj")
    let codex = dir.appendingPathComponent("codex/2026/11/20")
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let now = try #require(LogParser.parseDate("2026-11-20T03:00:00Z"))
    let resets = now.timeIntervalSince1970 + 3600

    try Data(#"""
    {"type":"assistant","timestamp":"2026-11-20T01:00:00Z","requestId":"q","message":{"id":"m","usage":{"input_tokens":100,"output_tokens":0}}}
    {"type":"assistant","timestamp":"2026-11-20T02:00:00Z","error":"rate_limit","apiErrorStatus":429,"quotaLimits":{"resetsAt":\#(resets),"rateLimitType":"five_hour"}}
    """#.utf8).write(to: claude.appendingPathComponent("s.jsonl"))
    let codexFull = #"{"used_percent":100.0,"window_minutes":10080,"resets_at":\#(resets + 86400)}"#
    try Data([
        record("r1", ts: "2026-11-20T01:30:00Z", input: 50, cached: 20, output: 5),
        tokenCount(ts: "2026-11-20T02:30:00Z", total: 55, last: (50, 20, 5), primary: codexFull),
    ].joined(separator: "\n").utf8).write(to: codex.appendingPathComponent("rollout-x.jsonl"))

    let s = UsageScanner(claudeRoot: dir.appendingPathComponent("claude"), codexRoot: dir.appendingPathComponent("codex"))
        .scan(now: now, calendar: utc)
    #expect(s.today.fresh == 100 + 35)
    #expect(Set(s.activeLocks(at: now).map(\.type)) == ["five_hour", "seven_day"])
    #expect(s.activeLock(at: now)?.type == "seven_day") // 가장 늦게 풀리는 것
}
