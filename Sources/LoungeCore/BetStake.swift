/// 블랙잭 한 판 베팅액 (일반 칩). 칩 단위를 반복해 눌러 판돈을 늘린다.
/// 서버 `bj_bet`의 상한(200칩)과 같은 값 — 바꾸면 마이그레이션과 docs/chip-economy.md도 같이.
public struct BetStake: Sendable, Equatable {
    public static let units: [Int64] = [10, 30, 50, 100]
    public static let defaultAmount: Int64 = 30
    public static let maxAmount: Int64 = 200

    public private(set) var amount: Int64
    /// 칩을 한 번이라도 눌렀는지. 안 눌렀으면 기본 베팅(30)에서 시작해 첫 탭이 그 값을 바꾼다
    public private(set) var touched = false

    public init(amount: Int64 = BetStake.defaultAmount) {
        self.amount = min(max(amount, 1), Self.maxAmount)
    }

    /// 칩 단위를 눌렀을 때. 첫 탭은 기존처럼 그 단위로 고르고, 이어지는 탭은 더한다. 상한을 넘으면 더하지 않는다
    public mutating func tap(_ unit: Int64) {
        guard unit > 0, unit <= Self.maxAmount else { return }
        if !touched {
            amount = unit
            touched = true
        } else if amount + unit <= Self.maxAmount {
            amount += unit
        }
    }

    /// 기본 베팅(30)으로 되돌린다
    public mutating func reset() {
        self = BetStake()
    }

    /// 이 단위를 더 얹을 수 있는가 (잔액과 상한)
    public func canAdd(_ unit: Int64, chips: Int64) -> Bool {
        let next = touched ? amount + unit : unit
        return next <= Self.maxAmount && next <= chips
    }

    /// 더블다운까지 걸 수 있는 칩이 있는가 (더블은 같은 금액을 한 번 더 건다)
    public func canDouble(chips: Int64) -> Bool { chips >= amount * 2 }
}
