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
    /// "five_hour", "seven_day" 등 Claude가 내려주는 값 그대로.
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
    /// 가장 최근의 429 기록 (해제됐을 수도 있음)
    public var lastLimitHit: RateLimitHit?

    public init() {}

    /// 지금 리밋에 걸려 있으면 그 기록을 돌려준다.
    public func activeLock(at now: Date = .now) -> RateLimitHit? {
        guard let hit = lastLimitHit, hit.isActive(at: now) else { return nil }
        return hit
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
