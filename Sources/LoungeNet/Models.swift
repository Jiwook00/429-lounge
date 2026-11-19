import Foundation

public enum Side: String, Codable, Sendable, CaseIterable {
    case odd, even

    public var label: String { self == .odd ? "홀" : "짝" }
}

public struct Player: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let chips: Int64
    public let goldenChips: Int
    /// 황금 칩 소멸 시각 (= 429 리셋 시각)
    public let goldenUntil: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, chips
        case goldenChips = "golden_chips", goldenUntil = "golden_until"
    }

    public init(id: UUID, name: String, chips: Int64, goldenChips: Int = 0, goldenUntil: Date? = nil) {
        self.id = id
        self.name = name
        self.chips = chips
        self.goldenChips = goldenChips
        self.goldenUntil = goldenUntil
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        chips = try c.decode(Int64.self, forKey: .chips)
        goldenChips = try c.decodeIfPresent(Int.self, forKey: .goldenChips) ?? 0
        goldenUntil = try c.decodeIfPresent(Date.self, forKey: .goldenUntil)
    }

    /// 지금 쓸 수 있는 황금 칩 개수 (만료됐으면 0)
    public func golden(at now: Date = .now) -> Int {
        guard let until = goldenUntil, until > now else { return 0 }
        return goldenChips
    }
}

/// 슬롯 한 판 결과. 릴 심볼: cherry, bell, bar, seven, 429, 404, 200, 500
public struct SlotResult: Codable, Sendable, Equatable {
    /// 최종 릴 (500 리스핀 후)
    public let reels: [String]
    /// 처음 멈춘 릴 (500이 있으면 그 자리가 리스핀됨)
    public let initialReels: [String]
    /// 500으로 리스핀된 릴 번호 (0부터)
    public let glitched: [Int]
    /// VIP HOUR 판 (429가 더 자주 나오는 릴)
    public let vip: Bool
    public let multiplier: Int
    public let payout: Int64
    public let player: Player

    enum CodingKeys: String, CodingKey {
        case reels, glitched, vip, multiplier, payout, player
        case initialReels = "initial_reels"
    }

    public init(reels: [String], initialReels: [String]? = nil, glitched: [Int] = [], vip: Bool = false,
                multiplier: Int, payout: Int64, player: Player) {
        self.reels = reels
        self.initialReels = initialReels ?? reels
        self.glitched = glitched
        self.vip = vip
        self.multiplier = multiplier
        self.payout = payout
        self.player = player
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reels = try c.decode([String].self, forKey: .reels)
        initialReels = try c.decodeIfPresent([String].self, forKey: .initialReels) ?? reels
        // 서버는 1부터 센다
        glitched = (try c.decodeIfPresent([Int].self, forKey: .glitched) ?? []).map { $0 - 1 }
        vip = try c.decodeIfPresent(Bool.self, forKey: .vip) ?? false
        multiplier = try c.decode(Int.self, forKey: .multiplier)
        payout = try c.decode(Int64.self, forKey: .payout)
        player = try c.decode(Player.self, forKey: .player)
    }
}

/// 칩 지급 RPC 결과
public struct Grant: Codable, Sendable {
    public let granted: Int64
    public let player: Player
}

public struct Round: Codable, Sendable, Identifiable, Equatable {
    public let id: Int64
    public let roomCode: String
    public let opensAt: Date
    public let closesAt: Date
    /// 정산 전엔 nil. 서버만 정한다.
    public let marbles: Int?
    public let settledAt: Date?

    public var result: Side? { marbles.map { $0 % 2 == 1 ? .odd : .even } }

    enum CodingKeys: String, CodingKey {
        case id, marbles
        case roomCode = "room_code", opensAt = "opens_at", closesAt = "closes_at", settledAt = "settled_at"
    }

    public init(id: Int64, roomCode: String, opensAt: Date, closesAt: Date, marbles: Int?, settledAt: Date?) {
        self.id = id
        self.roomCode = roomCode
        self.opensAt = opensAt
        self.closesAt = closesAt
        self.marbles = marbles
        self.settledAt = settledAt
    }
}

public struct Bet: Codable, Sendable, Equatable {
    public let roundId: Int64
    public let roomCode: String
    public let playerId: UUID
    public let side: Side
    public let amount: Int64
    /// 정산 후 채워짐. 0이면 짐.
    public let payout: Int64?
    /// 황금 칩(공짜 100칩) 베팅
    public let golden: Bool

    enum CodingKeys: String, CodingKey {
        case side, amount, payout, golden
        case roundId = "round_id", roomCode = "room_code", playerId = "player_id"
    }

    public init(roundId: Int64, roomCode: String, playerId: UUID, side: Side, amount: Int64, payout: Int64?, golden: Bool = false) {
        self.roundId = roundId
        self.roomCode = roomCode
        self.playerId = playerId
        self.side = side
        self.amount = amount
        self.payout = payout
        self.golden = golden
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roundId = try c.decode(Int64.self, forKey: .roundId)
        roomCode = try c.decode(String.self, forKey: .roomCode)
        playerId = try c.decode(UUID.self, forKey: .playerId)
        side = try c.decode(Side.self, forKey: .side)
        amount = try c.decode(Int64.self, forKey: .amount)
        payout = try c.decodeIfPresent(Int64.self, forKey: .payout)
        golden = try c.decodeIfPresent(Bool.self, forKey: .golden) ?? false
    }

    /// 실제로 잃은 칩 (황금 칩 베팅은 0)
    public var cost: Int64 { golden ? 0 : amount }
}

/// 테이블에 앉아 있는 사람 (Realtime Presence)
public struct Seat: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public enum TableEvent: Sendable {
    case round(Round)
    case bet(Bet)
    case player(Player)
    case seats([Seat])
}
