import Foundation

/// 토큰 사용량 합계.
public struct TokenTotals: Sendable, Equatable {
    public var input = 0
    public var output = 0
    public var cacheCreation = 0
    public var cacheRead = 0
    public var messages = 0

    public init() {}

    /// 캐시 읽기를 제외한 "새로 쓴" 토큰. 캐시 읽기는 양이 압도적으로 많고
    /// 실제 작업량과 비례하지 않아서 칩 계산의 기준은 이 값으로 잡는다.
    public var fresh: Int { input + output + cacheCreation }
    public var all: Int { fresh + cacheRead }

    mutating func add(_ u: UsageRecord) {
        input += u.input
        output += u.output
        cacheCreation += u.cacheCreation
        cacheRead += u.cacheRead
        messages += 1
    }
}

/// 429(사용 한도 초과)에 걸린 기록.
public struct RateLimitHit: Sendable, Equatable {
    public let hitAt: Date
    public let resetsAt: Date
    /// "five_hour", "seven_day" 등. Codex는 창 길이로 같은 이름에 맞춘다.
    public let type: String

    public init(hitAt: Date, resetsAt: Date, type: String) {
        self.hitAt = hitAt
        self.resetsAt = resetsAt
        self.type = type
    }

    public func isActive(at now: Date) -> Bool { resetsAt > now }
}

public struct UsageSnapshot: Sendable {
    public var today = TokenTotals()
    public var last5h = TokenTotals()
    public var lastActivity: Date?
    /// 최근 7일의 429 기록 (Claude Code + Codex, 해제된 것 포함)
    public var limitHits: [RateLimitHit] = []

    public init() {}

    /// 가장 최근의 429 기록. 대입하면 그 기록 하나만 남긴다 (가짜 429용).
    public var lastLimitHit: RateLimitHit? {
        get { limitHits.max { $0.hitAt < $1.hitAt } }
        set { limitHits = newValue.map { [$0] } ?? [] }
    }

    /// 지금 걸려 있는 리밋 전부. 도구마다 따로 황금 칩을 받는다 (ADR-0009)
    public func activeLocks(at now: Date = .now) -> [RateLimitHit] {
        limitHits.filter { $0.isActive(at: now) }
    }

    /// 지금 걸려 있는 리밋 중 가장 늦게 풀리는 것 (화면 표시용)
    public func activeLock(at now: Date = .now) -> RateLimitHit? {
        activeLocks(at: now).max { $0.resetsAt < $1.resetsAt }
    }
}

/// 로그 한 줄에서 뽑아낸 사용량.
struct UsageRecord: Sendable, Equatable {
    let timestamp: Date
    let input: Int
    let output: Int
    let cacheCreation: Int
    let cacheRead: Int
}
