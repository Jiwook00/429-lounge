import Foundation

/// Codex CLI 세션 로그(`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`)에서 사용량/리밋을 모은다.
/// codex-cli 0.170.0 로그 기준. `consume`은 파일 하나 단위로 부른다 (구버전 대체 경로가 파일 단위라서).
///
/// - 사용량: 응답마다 남는 `token_usage_record`를 `response_id`로 중복 제거해서 센다.
///   이 줄이 없는 구버전 로그는 `token_count` 이벤트의 `last_token_usage`로 대신한다.
/// - 리밋: `token_count.rate_limits`의 창(primary/secondary)이 가득 차면 429로 본다.
///   실제로 걸린 로그 샘플로는 아직 확인하지 못했다.
struct CodexLogParser {
    private(set) var records: [UsageRecord] = []
    private(set) var limitHits: [RateLimitHit] = []
    private var seen: Set<String> = []

    private static let recordMarker = Data(#""token_usage_record""#.utf8)
    private static let countMarker = Data(#""token_count""#.utf8)
    private let decoder = JSONDecoder()

    mutating func consume(_ data: Data) {
        var fromRecords: [UsageRecord] = []
        var fromCounts: [UsageRecord] = []
        var lastTotal: Int?

        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            let isRecord = line.range(of: Self.recordMarker) != nil
            // 대화 내용 줄은 디코딩 전에 걸러낸다
            guard isRecord || line.range(of: Self.countMarker) != nil,
                  let entry = try? decoder.decode(CodexLine.self, from: line),
                  let ts = entry.timestamp.flatMap(LogParser.parseDate),
                  let p = entry.payload
            else { continue }

            if entry.type == "token_usage_record", let u = p.usage {
                if let id = p.response_id {
                    guard seen.insert(id).inserted else { continue }
                }
                if let r = u.record(at: ts) { fromRecords.append(r) }
            } else if entry.type == "event_msg", p.type == "token_count" {
                // 같은 누계가 두 번 찍히는 경우가 있어서, 누계가 늘었을 때만 증가분을 센다
                if let info = p.info, let total = info.total_token_usage?.total_tokens, total != lastTotal {
                    lastTotal = total
                    if let r = info.last_token_usage?.record(at: ts) { fromCounts.append(r) }
                }
                if let limits = p.rate_limits { limitHits += limits.hits(at: ts) }
            }
        }
        records += fromRecords.isEmpty ? fromCounts : fromRecords
    }
}

private struct CodexLine: Decodable {
    let timestamp: String?
    let type: String?
    let payload: Payload?

    struct Payload: Decodable {
        let type: String?
        let response_id: String?
        let usage: Usage?
        let info: Info?
        let rate_limits: RateLimits?
    }

    struct Info: Decodable {
        let total_token_usage: Usage?
        let last_token_usage: Usage?
    }

    struct Usage: Decodable {
        let input_tokens: Int?
        let cached_input_tokens: Int?
        let cache_write_input_tokens: Int?
        let output_tokens: Int?
        let total_tokens: Int?

        /// Codex의 input_tokens는 캐시 읽기/쓰기를 포함한 전체 입력이라 Claude 기준으로 쪼갠다.
        /// reasoning 토큰은 output_tokens 안에 이미 들어 있다.
        func record(at ts: Date) -> UsageRecord? {
            let cached = cached_input_tokens ?? 0
            let write = cache_write_input_tokens ?? 0
            let r = UsageRecord(
                timestamp: ts,
                input: max(0, (input_tokens ?? 0) - cached - write),
                output: output_tokens ?? 0,
                cacheCreation: write,
                cacheRead: cached
            )
            return r.input + r.output + r.cacheCreation + r.cacheRead > 0 ? r : nil
        }
    }

    struct RateLimits: Decodable {
        let primary: Window?
        let secondary: Window?
        let rate_limit_reached_type: String?

        func hits(at ts: Date) -> [RateLimitHit] {
            let windows = [primary, secondary].compactMap { $0 }
            var full = windows.filter { ($0.used_percent ?? 0) >= 100 }
            // 퍼센트가 덜 찼는데 도달 표시만 온 경우: 가장 많이 찬 창을 리밋으로 본다
            if full.isEmpty, rate_limit_reached_type != nil,
               let top = windows.max(by: { ($0.used_percent ?? 0) < ($1.used_percent ?? 0) }) {
                full = [top]
            }
            return full.compactMap { w in
                guard let resets = w.resetsAt(from: ts) else { return nil }
                return RateLimitHit(hitAt: ts, resetsAt: resets, type: w.limitType)
            }
        }
    }

    struct Window: Decodable {
        let used_percent: Double?
        let window_minutes: Int?
        let resets_at: Double?
        /// 구버전 필드
        let resets_in_seconds: Double?

        func resetsAt(from ts: Date) -> Date? {
            if let at = resets_at { return Date(timeIntervalSince1970: at) }
            return resets_in_seconds.map { ts.addingTimeInterval($0) }
        }

        /// 서버(`claim_golden`)가 아는 이름으로 맞춘다. 5시간 = 3개, 그 외 = 10개
        var limitType: String {
            switch window_minutes {
            case 300: "five_hour"
            case 10080: "seven_day"
            case let m?: "codex_\(m)m"
            case nil: "unknown"
            }
        }
    }
}
