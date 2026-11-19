import Foundation

public enum Side: String, Codable, Sendable, CaseIterable {
    case odd, even

    public var label: String { self == .odd ? "홀" : "짝" }
}

public struct Player: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let chips: Int64

    public init(id: UUID, name: String, chips: Int64) {
        self.id = id
        self.name = name
        self.chips = chips
    }
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

    enum CodingKeys: String, CodingKey {
        case side, amount, payout
        case roundId = "round_id", roomCode = "room_code", playerId = "player_id"
    }

    public init(roundId: Int64, roomCode: String, playerId: UUID, side: Side, amount: Int64, payout: Int64?) {
        self.roundId = roundId
        self.roomCode = roomCode
        self.playerId = playerId
        self.side = side
        self.amount = amount
        self.payout = payout
    }
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
