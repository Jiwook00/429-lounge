import Foundation

/// `~/.claude/projects/**/*.jsonl` (Claude Code 세션 로그)를 읽어서
/// 오늘/최근 5시간 토큰 사용량과 마지막 429 기록을 계산한다.
public struct UsageScanner: Sendable {
    public let root: URL

    /// 429 기록을 찾기 위해 거슬러 올라가는 기간. 주간 리밋까지 잡으려고 7일.
    public var limitLookback: TimeInterval = 7 * 24 * 3600

    public init(root: URL = UsageScanner.defaultRoot) {
        self.root = root
    }

    public static var defaultRoot: URL {
        let base = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return base.appendingPathComponent("projects")
    }

    public func scan(now: Date = .now, calendar: Calendar = .current) -> UsageSnapshot {
        let dayStart = calendar.startOfDay(for: now)
        let windowStart = now.addingTimeInterval(-5 * 3600)
        let usageSince = min(dayStart, windowStart)
        let fileSince = min(usageSince, now.addingTimeInterval(-limitLookback))

        var parser = LogParser()
        for file in logFiles(modifiedSince: fileSince) {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            parser.consume(data)
        }

        var snapshot = UsageSnapshot()
        for r in parser.records where r.timestamp >= usageSince && r.timestamp <= now {
            if r.timestamp >= dayStart { snapshot.today.add(r) }
            if r.timestamp >= windowStart { snapshot.last5h.add(r) }
            snapshot.lastActivity = max(snapshot.lastActivity ?? r.timestamp, r.timestamp)
        }
        snapshot.lastLimitHit = parser.limitHits
            .filter { $0.hitAt <= now }
            .max { $0.hitAt < $1.hitAt }
        return snapshot
    }

    private func logFiles(modifiedSince since: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true,
                  let modified = values?.contentModificationDate, modified >= since
            else { continue }
            files.append(url)
        }
        return files
    }
}

/// JSONL 바이트를 받아 사용량/429 기록을 모은다. 파일 I/O와 분리해서 테스트하기 쉽게.
struct LogParser {
    private(set) var records: [UsageRecord] = []
    private(set) var limitHits: [RateLimitHit] = []
    /// 하나의 API 응답이 콘텐츠 블록마다 여러 줄로 기록되므로 message.id + requestId로 중복 제거
    private var seen: Set<String> = []

    private static let assistantMarker = Data(#""type":"assistant""#.utf8)
    private let decoder = JSONDecoder()

    mutating func consume(_ data: Data) {
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            // 대부분의 줄(사용자 입력, 툴 결과)은 디코딩 전에 걸러낸다
            guard line.range(of: Self.assistantMarker) != nil,
                  let entry = try? decoder.decode(LogLine.self, from: line),
                  entry.type == "assistant",
                  let ts = entry.timestamp.flatMap(Self.parseDate)
            else { continue }

            if entry.apiErrorStatus == 429 || entry.error == "rate_limit",
               let resets = entry.quotaLimits?.resetsAt {
                limitHits.append(RateLimitHit(
                    hitAt: ts,
                    resetsAt: Date(timeIntervalSince1970: resets),
                    type: entry.quotaLimits?.rateLimitType ?? "unknown"
                ))
                continue
            }

            guard let u = entry.message?.usage else { continue }
            if let id = entry.message?.id {
                let key = id + "|" + (entry.requestId ?? "")
                guard seen.insert(key).inserted else { continue }
            }
            let record = UsageRecord(
                timestamp: ts,
                input: u.input_tokens ?? 0,
                output: u.output_tokens ?? 0,
                cacheCreation: u.cache_creation_input_tokens ?? 0,
                cacheRead: u.cache_read_input_tokens ?? 0
            )
            // 에러 메시지 등 사용량이 전부 0인 합성 메시지는 세지 않는다
            if record.input + record.output + record.cacheCreation + record.cacheRead > 0 {
                records.append(record)
            }
        }
    }

    static func parseDate(_ s: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s))
            ?? (try? Date.ISO8601FormatStyle().parse(s))
    }
}

/// 로그 한 줄 중 필요한 필드만.
private struct LogLine: Decodable {
    let type: String?
    let timestamp: String?
    let requestId: String?
    let error: String?
    let apiErrorStatus: Int?
    let quotaLimits: Quota?
    let message: Message?

    struct Message: Decodable {
        let id: String?
        let usage: Usage?
    }

    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
    }

    struct Quota: Decodable {
        let resetsAt: Double?
        let rateLimitType: String?
    }
}
