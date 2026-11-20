import Foundation

/// Claude Code(`~/.claude/projects/**/*.jsonl`)와 Codex CLI(`~/.codex/sessions/**/*.jsonl`)
/// 세션 로그를 읽어서 오늘/최근 5시간 토큰 사용량과 429 기록을 계산한다. 두 도구를 함께 쓰면 합산한다.
public struct UsageScanner: Sendable {
    public let claudeRoot: URL
    public let codexRoot: URL

    /// 429 기록을 찾기 위해 거슬러 올라가는 기간. 주간 리밋까지 잡으려고 7일.
    public var limitLookback: TimeInterval = 7 * 24 * 3600

    public init(claudeRoot: URL = UsageScanner.defaultClaudeRoot, codexRoot: URL = UsageScanner.defaultCodexRoot) {
        self.claudeRoot = claudeRoot
        self.codexRoot = codexRoot
    }

    public static var defaultClaudeRoot: URL {
        home(env: "CLAUDE_CONFIG_DIR", fallback: ".claude").appendingPathComponent("projects")
    }

    public static var defaultCodexRoot: URL {
        home(env: "CODEX_HOME", fallback: ".codex").appendingPathComponent("sessions")
    }

    private static func home(env: String, fallback: String) -> URL {
        ProcessInfo.processInfo.environment[env].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(fallback)
    }

    public func scan(now: Date = .now, calendar: Calendar = .current) -> UsageSnapshot {
        let dayStart = calendar.startOfDay(for: now)
        let windowStart = now.addingTimeInterval(-5 * 3600)
        let usageSince = min(dayStart, windowStart)
        let fileSince = min(usageSince, now.addingTimeInterval(-limitLookback))

        var claude = LogParser()
        for data in logs(in: claudeRoot, modifiedSince: fileSince) { claude.consume(data) }
        var codex = CodexLogParser()
        for data in logs(in: codexRoot, modifiedSince: fileSince) { codex.consume(data) }

        var snapshot = UsageSnapshot()
        for r in claude.records + codex.records where r.timestamp >= usageSince && r.timestamp <= now {
            if r.timestamp >= dayStart { snapshot.today.add(r) }
            if r.timestamp >= windowStart { snapshot.last5h.add(r) }
            snapshot.lastActivity = max(snapshot.lastActivity ?? r.timestamp, r.timestamp)
        }
        snapshot.limitHits = Self.mergeHits(claude.limitHits + codex.limitHits, now: now)
        return snapshot
    }

    /// 같은 리밋이 여러 줄에 찍히면 하나로 합친다. Codex는 같은 리밋의 resets_at이 초 단위로 흔들려서
    /// (서버는 resets_at으로 중복 지급을 막는다) 종류가 같고 10분 안이면 가장 먼저 찍힌 기록으로 고정한다.
    static func mergeHits(_ hits: [RateLimitHit], now: Date) -> [RateLimitHit] {
        var merged: [RateLimitHit] = []
        for hit in hits.filter({ $0.hitAt <= now }).sorted(by: { $0.hitAt < $1.hitAt }) {
            let dup = merged.contains {
                $0.type == hit.type && abs($0.resetsAt.timeIntervalSince(hit.resetsAt)) < 600
            }
            if !dup { merged.append(hit) }
        }
        return merged
    }

    /// 루트 아래에서 최근에 바뀐 jsonl 파일들의 내용. 폴더가 없으면(그 도구를 안 쓰면) 비어 있다.
    private func logs(in root: URL, modifiedSince since: Date) -> [Data] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [Data] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true,
                  let modified = values?.contentModificationDate, modified >= since,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            else { continue }
            files.append(data)
        }
        return files
    }
}

/// Claude Code JSONL 바이트를 받아 사용량/429 기록을 모은다. 파일 I/O와 분리해서 테스트하기 쉽게.
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
