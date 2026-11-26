import Foundation

/// 429 드롭 공 하나의 경로 (서버가 정해서 보낸다, ADR-0018).
/// 줄 `from + i`에서 칸 `js[i]`의 핀을 맞고, 마지막 줄(11)에서 `bucket`으로 떨어진다.
public struct PlinkoBall: Codable, Sendable, Equatable {
    /// 첫 줄 (가운데 레인 0, 옆 레인은 가이드 핀 때문에 1)
    public let from: Int
    /// 줄마다 맞은 핀의 j (x = 가운데 + j × 핀 간격 / 2)
    public let js: [Int]
    /// 0~12, 스타트 포켓에 잡혔으면 nil
    public let bucket: Int?
    /// 골드 핀 보너스 합 (배수에 더해진다)
    public let gold: Double
    public let mult: Double
    public let payout: Int64
    public let pocket: Bool
    /// 분열한 줄 (없으면 nil)
    public let split: Int?
    /// 분열로 생긴 공 (`from` = split + 1). 구조체가 자기 자신을 품을 수 없어 배열로 들고 있다
    private let clones: [PlinkoBall]
    public var clone: PlinkoBall? { clones.first }

    enum CodingKeys: String, CodingKey { case from, js, bucket, gold, mult, payout, pocket, split, clone }

    public init(from: Int, js: [Int], bucket: Int?, gold: Double = 0, mult: Double = 0, payout: Int64 = 0,
                pocket: Bool = false, split: Int? = nil, clone: PlinkoBall? = nil) {
        self.from = from
        self.js = js
        self.bucket = bucket
        self.gold = gold
        self.mult = mult
        self.payout = payout
        self.pocket = pocket
        self.split = split
        self.clones = clone.map { [$0] } ?? []
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(Int.self, forKey: .from)
        js = try c.decode([Int].self, forKey: .js)
        bucket = try c.decodeIfPresent(Int.self, forKey: .bucket)
        gold = try c.decodeIfPresent(Double.self, forKey: .gold) ?? 0
        mult = try c.decodeIfPresent(Double.self, forKey: .mult) ?? 0
        payout = try c.decodeIfPresent(Int64.self, forKey: .payout) ?? 0
        pocket = try c.decodeIfPresent(Bool.self, forKey: .pocket) ?? false
        split = try c.decodeIfPresent(Int.self, forKey: .split)
        clones = try c.decodeIfPresent(PlinkoBall.self, forKey: .clone).map { [$0] } ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(from, forKey: .from)
        try c.encode(js, forKey: .js)
        try c.encode(bucket, forKey: .bucket)
        try c.encode(gold, forKey: .gold)
        try c.encode(mult, forKey: .mult)
        try c.encode(payout, forKey: .payout)
        try c.encode(pocket, forKey: .pocket)
        try c.encode(split, forKey: .split)
        try c.encode(clone, forKey: .clone)
    }
}

/// 스타트 포켓에 잡힌 공의 미니 3릴
public struct PlinkoPocket: Codable, Sendable, Equatable {
    public let reels: [String]
    public let fever: Bool
    /// 비일치일 때 돌려받는 칩
    public let refund: Int64
    /// 4·2·9 글자를 다 모아서 확정된 FEVER (ADR-0019)
    public let ceiling: Bool

    enum CodingKeys: String, CodingKey { case reels, fever, refund, ceiling }

    public init(reels: [String], fever: Bool, refund: Int64, ceiling: Bool = false) {
        self.reels = reels
        self.fever = fever
        self.refund = refund
        self.ceiling = ceiling
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reels = try c.decode([String].self, forKey: .reels)
        fever = try c.decode(Bool.self, forKey: .fever)
        refund = try c.decode(Int64.self, forKey: .refund)
        ceiling = try c.decodeIfPresent(Bool.self, forKey: .ceiling) ?? false
    }

    /// 앞의 두 릴이 429면 리치 (셋째 릴이 늦게 멈춘다)
    public var reach: Bool { reels.count == 3 && reels[0] == "429" && reels[1] == "429" }
}

/// `plinko_drop` 응답: 공 하나(분열·FEVER 포함)의 결과 전체. 지갑은 이미 갱신된 값이지만
/// 화면은 공이 칸에 닿을 때 반영한다.
public struct PlinkoDrop: Codable, Sendable, Equatable {
    public enum Grade: String, Codable, Sendable { case none, good, perfect }

    public let ball: PlinkoBall
    public let pocket: PlinkoPocket?
    public let feverBalls: [PlinkoBall]
    /// 이번 공 전체 지급 (분열·FEVER·환급 합)
    public let payout: Int64
    public let topMult: Double
    public let fever: Bool
    public let lane: Int
    public let power: Int
    public let grade: Grade
    public let amount: Int64
    public let golden: Bool
    /// 이 판 뒤 4·2·9 글자 수 (0~3)
    public let letters: Int
    /// VIP HOUR 판 (포켓 입구가 넓다)
    public let vip: Bool
    public let player: Player

    enum CodingKeys: String, CodingKey {
        case ball, pocket, payout, fever, lane, power, grade, amount, golden, letters, vip, player
        case feverBalls = "fever_balls", topMult = "top_mult"
    }

    public init(ball: PlinkoBall, pocket: PlinkoPocket? = nil, feverBalls: [PlinkoBall] = [], payout: Int64,
                topMult: Double = 0, fever: Bool = false, lane: Int = 0, power: Int = 0, grade: Grade = .none,
                amount: Int64, golden: Bool = false, letters: Int = 0, vip: Bool = false, player: Player) {
        self.ball = ball
        self.pocket = pocket
        self.feverBalls = feverBalls
        self.payout = payout
        self.topMult = topMult
        self.fever = fever
        self.lane = lane
        self.power = power
        self.grade = grade
        self.amount = amount
        self.golden = golden
        self.letters = letters
        self.vip = vip
        self.player = player
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ball = try c.decode(PlinkoBall.self, forKey: .ball)
        pocket = try c.decodeIfPresent(PlinkoPocket.self, forKey: .pocket)
        feverBalls = try c.decodeIfPresent([PlinkoBall].self, forKey: .feverBalls) ?? []
        payout = try c.decode(Int64.self, forKey: .payout)
        topMult = try c.decodeIfPresent(Double.self, forKey: .topMult) ?? 0
        fever = try c.decodeIfPresent(Bool.self, forKey: .fever) ?? false
        lane = try c.decodeIfPresent(Int.self, forKey: .lane) ?? 0
        power = try c.decodeIfPresent(Int.self, forKey: .power) ?? 0
        grade = try c.decodeIfPresent(Grade.self, forKey: .grade) ?? .none
        amount = try c.decode(Int64.self, forKey: .amount)
        golden = try c.decodeIfPresent(Bool.self, forKey: .golden) ?? false
        letters = try c.decodeIfPresent(Int.self, forKey: .letters) ?? 0
        vip = try c.decodeIfPresent(Bool.self, forKey: .vip) ?? false
        player = try c.decode(Player.self, forKey: .player)
    }
}

/// 게이지 24칸 등급. 서버(`plinko_grade`)와 같은 식: 칸 = min(23, p × 24 / 1000)
public enum PlinkoGauge {
    public static let cells = 24
    /// 한 왕복의 절반(0→1)이 걸리는 시간
    public static let period: TimeInterval = 1.08

    public static func cell(power p: Int) -> Int { min(23, max(0, p) * 24 / 1000) }

    public static func grade(power p: Int) -> PlinkoDrop.Grade {
        switch cell(power: p) {
        case 20: .perfect
        case 18, 19, 21, 22: .good
        default: .none
        }
    }

    /// 누른 시각과 뗀 시각(이벤트 타임스탬프)에서 파워(0~1000). 왕복 파형
    public static func power(held: TimeInterval) -> Int {
        let t = max(0, held) / period
        let m = t.truncatingRemainder(dividingBy: 2)
        let power = m < 1 ? m : 2 - m
        return min(1000, Int((power * 1000).rounded(.down)))
    }
}
