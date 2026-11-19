import Foundation
import Testing
@testable import LoungeCore

private func assistant(id: String, req: String, ts: String, input: Int, output: Int, cacheRead: Int = 0) -> String {
    #"{"type":"assistant","timestamp":"\#(ts)","requestId":"\#(req)","message":{"id":"\#(id)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":\#(cacheRead)}}}"#
}

@Test func dedupesContentBlocksOfSameMessage() {
    let log = [
        assistant(id: "m1", req: "r1", ts: "2026-11-19T10:00:00.000Z", input: 10, output: 5),
        assistant(id: "m1", req: "r1", ts: "2026-11-19T10:00:01.000Z", input: 10, output: 5),
        assistant(id: "m2", req: "r2", ts: "2026-11-19T10:01:00.000Z", input: 1, output: 2, cacheRead: 100),
    ].joined(separator: "\n")

    var p = LogParser()
    p.consume(Data(log.utf8))
    #expect(p.records.count == 2)
    #expect(p.records.map(\.input).reduce(0, +) == 11)
}

@Test func skipsUserLinesAndGarbage() {
    let log = """
    {"type":"user","message":{"content":"\\"type\\":\\"assistant\\" usage"}}
    not json "type":"assistant"
    \(assistant(id: "m1", req: "r1", ts: "2026-11-19T10:00:00Z", input: 3, output: 4))
    """
    var p = LogParser()
    p.consume(Data(log.utf8))
    #expect(p.records.count == 1)
}

@Test func detects429() {
    let line = #"{"type":"assistant","timestamp":"2026-11-14T10:27:31.162Z","error":"rate_limit","apiErrorStatus":429,"quotaLimits":{"status":"rejected","resetsAt":1794667200,"rateLimitType":"five_hour"},"message":{"id":"x","usage":{"input_tokens":0,"output_tokens":0}}}"#
    var p = LogParser()
    p.consume(Data(line.utf8))
    #expect(p.records.isEmpty)
    #expect(p.limitHits.count == 1)
    #expect(p.limitHits[0].type == "five_hour")
    #expect(p.limitHits[0].resetsAt == Date(timeIntervalSince1970: 1794667200))
}

@Test func scannerSplitsTodayAndWindow() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("proj"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let now = try #require(LogParser.parseDate("2026-11-19T03:00:00Z"))
    let log = [
        assistant(id: "a", req: "1", ts: "2026-11-18T23:00:00Z", input: 100, output: 0), // 어제, 5h 안
        assistant(id: "b", req: "2", ts: "2026-11-19T01:00:00Z", input: 10, output: 0),  // 오늘, 5h 안
        assistant(id: "c", req: "3", ts: "2026-11-18T10:00:00Z", input: 999, output: 0), // 범위 밖
        #"{"type":"assistant","timestamp":"2026-11-19T02:00:00Z","error":"rate_limit","apiErrorStatus":429,"quotaLimits":{"resetsAt":\#(now.timeIntervalSince1970 + 3600),"rateLimitType":"five_hour"}}"#,
    ].joined(separator: "\n")
    try Data(log.utf8).write(to: dir.appendingPathComponent("proj/s.jsonl"))

    let s = UsageScanner(root: dir).scan(now: now, calendar: utc)
    #expect(s.today.fresh == 10)
    #expect(s.last5h.fresh == 110)
    #expect(s.activeLock(at: now)?.type == "five_hour")
    #expect(s.activeLock(at: now.addingTimeInterval(7200)) == nil)
}
