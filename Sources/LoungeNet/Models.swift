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
    /// 직접 정한 닉네임이면 true. false면 서버가 붙인 "손님 XXXXXX"
    public let named: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, chips, named
        case goldenChips = "golden_chips", goldenUntil = "golden_until"
    }

    public init(id: UUID, name: String, chips: Int64, goldenChips: Int = 0, goldenUntil: Date? = nil, named: Bool = true) {
        self.id = id
        self.name = name
        self.chips = chips
        self.goldenChips = goldenChips
        self.goldenUntil = goldenUntil
        self.named = named
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        chips = try c.decode(Int64.self, forKey: .chips)
        goldenChips = try c.decodeIfPresent(Int.self, forKey: .goldenChips) ?? 0
        goldenUntil = try c.decodeIfPresent(Date.self, forKey: .goldenUntil)
        named = try c.decodeIfPresent(Bool.self, forKey: .named) ?? true
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

// MARK: - 라운지 접속 (ADR-0008)

/// 라운지에 있는 회원 한 명의 상태. Realtime Presence로 주고받는다.
/// 프로젝트 이름, 토큰 양 같은 건 절대 담지 않는다. 대략적인 상태만.
public struct Member: Codable, Sendable, Hashable, Identifiable {
    public enum Place: String, Codable, Sendable {
        case lounge, oddeven, slot
    }

    /// 로컬 Claude Code 로그에서 계산한 대략적인 상태
    public enum Status: String, Codable, Sendable {
        /// 최근 5분 안에 Claude 활동
        case coding
        /// 429 리밋 걸려서 리셋 대기
        case vip
        /// 30분 넘게 활동 없음
        case resting
    }

    public let id: UUID
    public var name: String
    /// 팝오버를 열어 보고 있는지
    public var viewing: Bool
    /// 보고 있는 화면
    public var place: Place
    /// nil = 5~30분 사이 (표시 안 함)
    public var status: Status?

    public init(id: UUID, name: String, viewing: Bool = false, place: Place = .lounge, status: Status? = nil) {
        self.id = id
        self.name = name
        self.viewing = viewing
        self.place = place
        self.status = status
    }
}

/// 회원 명부의 한 명 (닉네임을 정한 회원). 접속 중이 아니면 "오프라인 · 3시간 전"으로 보여준다 (ADR-0011)
public struct Regular: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let name: String
    /// 앱이 마지막으로 켜져 있던 시각
    public let lastSeenAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name
        case lastSeenAt = "last_seen_at"
    }

    public init(id: UUID, name: String, lastSeenAt: Date?) {
        self.id = id
        self.name = name
        self.lastSeenAt = lastSeenAt
    }
}

/// 전광판 이벤트 (서버가 정산하면서 기록)
public struct LoungeEvent: Codable, Sendable, Identifiable, Equatable {
    public let id: Int64
    /// jackpot | bigwin
    public let kind: String
    /// slot | oddeven
    public let game: String
    public let name: String
    public let amount: Int64
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, kind, game, name, amount
        case createdAt = "created_at"
    }

    public init(id: Int64, kind: String, game: String, name: String, amount: Int64, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.game = game
        self.name = name
        self.amount = amount
        self.createdAt = createdAt
    }
}

public enum LoungeSignal: Sendable {
    /// 지금 라운지에 있는 회원 전체 (나 포함)
    case members([Member])
    case event(LoungeEvent)
}

/// 이번 주 큰손 한 줄 (ADR-0012). 순수익 = 지급액 - 실제로 건 칩
public struct BoardRow: Codable, Sendable, Identifiable, Hashable {
    /// 동점이면 같은 순위
    public let rank: Int
    public let name: String
    public let net: Int64
    /// 내 줄
    public let me: Bool

    /// 닉네임은 라운지에서 하나뿐이라 id로 쓴다
    public var id: String { name }

    public init(rank: Int, name: String, net: Int64, me: Bool = false) {
        self.rank = rank
        self.name = name
        self.net = net
        self.me = me
    }
}
