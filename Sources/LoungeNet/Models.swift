import Foundation

public struct Player: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let chips: Int64
    public let goldenChips: Int
    /// 황금 칩 소멸 시각 (= 429 리셋 시각)
    public let goldenUntil: Date?
    /// 직접 정한 닉네임이면 true. false면 서버가 붙인 "손님 XXXXXX"
    public let named: Bool
    /// 마지막으로 오늘의 칩을 받은 날짜 (한국 시간, YYYY-MM-DD)
    public let lastDaily: String?
    /// 429 드롭의 4·2·9 글자 수 = 보드 레벨 (0~3, 3이면 HOT, ADR-0019)
    public let plinkoLetters: Int

    enum CodingKeys: String, CodingKey {
        case id, name, chips, named
        case goldenChips = "golden_chips", goldenUntil = "golden_until"
        case lastDaily = "last_daily", plinkoLetters = "plinko_letters"
    }

    public init(id: UUID, name: String, chips: Int64, goldenChips: Int = 0, goldenUntil: Date? = nil,
                named: Bool = true, lastDaily: String? = nil, plinkoLetters: Int = 0) {
        self.id = id
        self.name = name
        self.chips = chips
        self.goldenChips = goldenChips
        self.goldenUntil = goldenUntil
        self.named = named
        self.lastDaily = lastDaily
        self.plinkoLetters = plinkoLetters
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        chips = try c.decode(Int64.self, forKey: .chips)
        goldenChips = try c.decodeIfPresent(Int.self, forKey: .goldenChips) ?? 0
        goldenUntil = try c.decodeIfPresent(Date.self, forKey: .goldenUntil)
        named = try c.decodeIfPresent(Bool.self, forKey: .named) ?? true
        lastDaily = try c.decodeIfPresent(String.self, forKey: .lastDaily)
        plinkoLetters = try c.decodeIfPresent(Int.self, forKey: .plinkoLetters) ?? 0
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
    public let payoutMultiplier: Double
    public let payout: Int64
    public let player: Player

    enum CodingKeys: String, CodingKey {
        case reels, glitched, vip, multiplier, payout, player
        case initialReels = "initial_reels"
        case payoutMultiplier = "payout_multiplier"
    }

    public init(reels: [String], initialReels: [String]? = nil, glitched: [Int] = [], vip: Bool = false,
                multiplier: Int, payoutMultiplier: Double? = nil, payout: Int64, player: Player) {
        self.reels = reels
        self.initialReels = initialReels ?? reels
        self.glitched = glitched
        self.vip = vip
        self.multiplier = multiplier
        self.payoutMultiplier = payoutMultiplier ?? Double(multiplier)
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
        payoutMultiplier = try c.decodeIfPresent(Double.self, forKey: .payoutMultiplier) ?? Double(multiplier)
        payout = try c.decode(Int64.self, forKey: .payout)
        player = try c.decode(Player.self, forKey: .player)
    }
}

public struct LuckyTicket: Codable, Sendable, Equatable {
    public let day: String
    public let number: Int
    public let amount: Int
    public let claimedAt: Date

    enum CodingKeys: String, CodingKey {
        case day, number, amount
        case claimedAt = "claimed_at"
    }
}

public struct TicketGrant: Decodable, Sendable {
    public let ticket: LuckyTicket
    public let player: Player
}

/// 칩 지급 RPC 결과
public struct Grant: Codable, Sendable {
    public let granted: Int64
    public let player: Player
}

// MARK: - 라운지 접속 (ADR-0008)

/// 라운지에 있는 회원 한 명의 상태. Realtime Presence로 주고받는다.
/// 프로젝트 이름, 토큰 양 같은 건 절대 담지 않는다. 대략적인 상태만.
public struct Member: Codable, Sendable, Hashable, Identifiable {
    public enum Place: String, Codable, Sendable {
        /// 룰렛은 홀짝 자리를 이어받았다. 옛 앱이 아는 값("oddeven")을 그대로 보낸다 (모르는 값이면 회원 목록이 깨짐)
        case lounge, roulette = "oddeven", slot
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

/// 룰렛 테이블에 앉은 인원. 화면 위 바의 `TABLE · N명`과 라운지 타일의 `N명 앉음`이 같은 기준이 되게 한다.
/// 보는 중 + 룰렛 자리인 회원, 이번 판에 건 회원, 나(이 화면을 보고 있으니)의 합집합.
public enum TableSeats {
    public static func count(members: [Member], me: UUID?, bettors: some Sequence<UUID>) -> Int {
        var seated = Set(members.filter { $0.viewing && $0.place == .roulette }.map(\.id))
        seated.formUnion(bettors)
        if let me { seated.insert(me) }
        return seated.count
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
    /// slot | oddeven | blackjack | roulette
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

struct LastWeekRank: Decodable, Sendable {
    let rank: Int
}

// MARK: - 블랙잭 (ADR-0014)

/// 카드 한 장. 서버는 0~51 정수로 준다: 무늬 = c / 13 (스페이드·하트·다이아·클럽), 숫자 = c % 13 (0 = A, 9~12 = 10 J Q K)
public struct BJCard: Sendable, Hashable {
    public let code: Int

    public init(_ code: Int) { self.code = code }

    public var rank: Int { code % 13 }
    public var suit: Int { code / 13 }
    /// 하트·다이아
    public var red: Bool { suit == 1 || suit == 2 }
    /// 카드에 찍는 글자: A 2 … 10 J Q K
    public var label: String {
        switch rank {
        case 0: "A"
        case 10: "J"
        case 11: "Q"
        case 12: "K"
        default: "\(rank + 1)"
        }
    }

    /// 손패 합계 (A는 넘치지 않으면 11). soft = 11로 센 A가 남아 있음
    public static func total(_ cards: [BJCard]) -> (value: Int, soft: Bool) {
        var t = 0, aces = 0
        for c in cards {
            t += c.rank == 0 ? 11 : c.rank >= 9 ? 10 : c.rank + 1
            if c.rank == 0 { aces += 1 }
        }
        while t > 21 && aces > 0 { t -= 10; aces -= 1 }
        return (t, aces > 0)
    }
}

/// bj_tick / bj_bet / bj_action 결과: 지금 판 전부
public struct BJState: Decodable, Sendable, Equatable {
    /// 서버 시각 (시계 차이 보정용)
    public let now: Date
    public let round: BJRound?
    public let seats: [BJSeat]

    public init(now: Date, round: BJRound?, seats: [BJSeat]) {
        self.now = now
        self.round = round
        self.seats = seats
    }
}

public struct BJRound: Decodable, Sendable, Equatable {
    public enum Phase: String, Decodable, Sendable {
        case betting, playing, dealer, done
    }

    public let id: Int64
    public let phase: Phase
    public let betClosesAt: Date
    /// 지금 차례인 자리. nil = 딜 연출 중 / 딜러 / 끝
    public let turnSeat: Int?
    public let turnDeadline: Date?
    public let dealerCards: [Int]
    public let settledAt: Date?
    /// 결과 연출이 끝나는 시각
    public let nextAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, phase
        case betClosesAt = "bet_closes_at", turnSeat = "turn_seat", turnDeadline = "turn_deadline"
        case dealerCards = "dealer_cards", settledAt = "settled_at", nextAt = "next_at"
    }

    public init(id: Int64, phase: Phase, betClosesAt: Date, turnSeat: Int? = nil, turnDeadline: Date? = nil,
                dealerCards: [Int] = [], settledAt: Date? = nil, nextAt: Date? = nil) {
        self.id = id
        self.phase = phase
        self.betClosesAt = betClosesAt
        self.turnSeat = turnSeat
        self.turnDeadline = turnDeadline
        self.dealerCards = dealerCards
        self.settledAt = settledAt
        self.nextAt = nextAt
    }
}

public struct BJSeat: Decodable, Sendable, Equatable, Identifiable {
    public enum State: String, Decodable, Sendable {
        case waiting, playing, stood, bust, blackjack
    }

    public enum Result: String, Decodable, Sendable {
        case win, lose, push, blackjack
    }

    public enum Action: String, Codable, Sendable {
        case hit, stand, double, timeout
    }

    /// 1~4. 딜과 차례는 1번부터
    public let seat: Int
    /// nil = AI 봇
    public let playerId: UUID?
    public let name: String
    public let amount: Int64
    public let golden: Bool
    public let doubled: Bool
    public let cards: [Int]
    public let state: State
    public let lastAction: Action?
    public let result: Result?
    /// 지급액 (건 칩 포함). 봇은 늘 nil
    public let payout: Int64?

    public var id: Int { seat }
    public var bot: Bool { playerId == nil }
    /// 실제로 건 칩 (더블이면 두 배, 황금 칩은 0)
    public var staked: Int64 { golden ? 0 : amount * (doubled ? 2 : 1) }
    /// 순수익 (정산 뒤)
    public var net: Int64? { payout.map { $0 - staked } }

    enum CodingKeys: String, CodingKey {
        case seat, name, amount, golden, doubled, cards, state, result, payout
        case playerId = "player_id", lastAction = "last_action"
    }

    public init(seat: Int, playerId: UUID?, name: String, amount: Int64 = 0, golden: Bool = false, doubled: Bool = false,
                cards: [Int] = [], state: State = .waiting, lastAction: Action? = nil, result: Result? = nil, payout: Int64? = nil) {
        self.seat = seat
        self.playerId = playerId
        self.name = name
        self.amount = amount
        self.golden = golden
        self.doubled = doubled
        self.cards = cards
        self.state = state
        self.lastAction = lastAction
        self.result = result
        self.payout = payout
    }
}

// MARK: - 미니 룰렛 (ADR-0015)

/// 미니 룰렛 0~12. 빨강 1 4 5 8 9 12, 0은 무효 판
public enum Roulette {
    public static let red: Set<Int> = [1, 4, 5, 8, 9, 12]
    /// 휠 칸 순서: 0이 맨 위, 시계 방향. 빨강과 검정이 번갈아 온다
    public static let wheel = [0, 12, 7, 1, 10, 5, 2, 9, 6, 4, 11, 8, 3]
    /// 한 판 시간: 베팅 12초 → 회전 6초 → 결과 4초
    public static let spin: TimeInterval = 6
    public static let reveal: TimeInterval = 4

    /// 걸 수 있는 칸. 숫자 하나 ×12, 나머지 ×2 (지급액은 건 칩 포함)
    public enum Spot: Hashable, Sendable, Codable, RawRepresentable {
        case number(Int)
        case red, black, odd, even, low, high

        public static let outside: [Spot] = [.low, .even, .red, .black, .odd, .high]

        public init?(rawValue: String) {
            switch rawValue {
            case "red": self = .red
            case "black": self = .black
            case "odd": self = .odd
            case "even": self = .even
            case "low": self = .low
            case "high": self = .high
            default:
                guard rawValue.hasPrefix("n"), let n = Int(rawValue.dropFirst()), (1...12).contains(n) else { return nil }
                self = .number(n)
            }
        }

        public var rawValue: String {
            switch self {
            case .number(let n): "n\(n)"
            case .red: "red"
            case .black: "black"
            case .odd: "odd"
            case .even: "even"
            case .low: "low"
            case .high: "high"
            }
        }

        public var label: String {
            switch self {
            case .number(let n): "\(n)"
            case .red: "빨강"
            case .black: "검정"
            case .odd: "홀"
            case .even: "짝"
            case .low: "1–6"
            case .high: "7–12"
            }
        }

        /// 황금 칩은 ×2 칸에만
        public var outside: Bool { if case .number = self { false } else { true } }

        /// 지급 배수 (건 칩 포함). 0은 무효 판이라 ×1
        public func multiplier(_ result: Int) -> Int {
            if result == 0 { return 1 }
            switch self {
            case .number(let n): return n == result ? 12 : 0
            case .red: return Roulette.red.contains(result) ? 2 : 0
            case .black: return Roulette.red.contains(result) ? 0 : 2
            case .odd: return result % 2 == 1 ? 2 : 0
            case .even: return result % 2 == 0 ? 2 : 0
            case .low: return result <= 6 ? 2 : 0
            case .high: return result >= 7 ? 2 : 0
            }
        }

        /// 이 결과에서 이긴 칸인지 (0이면 아무 칸도 아님)
        public func wins(_ result: Int) -> Bool { result != 0 && multiplier(result) > 1 }
    }

    /// 결과 한 줄: "7 · 검정 · 홀 · 7–12"
    public static func describe(_ result: Int) -> [String] {
        guard result != 0 else { return ["0"] }
        return ["\(result)", red.contains(result) ? "빨강" : "검정", result % 2 == 1 ? "홀" : "짝", result <= 6 ? "1–6" : "7–12"]
    }
}

/// roulette_tick / roulette_bet / roulette_spin 결과: 지금 판 전부
public struct RouletteState: Decodable, Sendable, Equatable {
    /// 서버 시각 (시계 차이 보정용)
    public let now: Date
    public let round: RouletteRound?
    public let bets: [RouletteBet]
    /// 지금 판 바로 앞 판의 결과
    public let lastResult: Int?

    enum CodingKeys: String, CodingKey {
        case now, round, bets
        case lastResult = "last_result"
    }

    public init(now: Date, round: RouletteRound?, bets: [RouletteBet], lastResult: Int? = nil) {
        self.now = now
        self.round = round
        self.bets = bets
        self.lastResult = lastResult
    }
}

public struct RouletteRound: Decodable, Sendable, Equatable {
    public let id: Int64
    public let betClosesAt: Date
    /// 정산 전엔 nil
    public let result: Int?
    public let settledAt: Date?
    /// 결과 연출이 끝나는 시각 (= 마감 + 10초)
    public let nextAt: Date

    enum CodingKeys: String, CodingKey {
        case id, result
        case betClosesAt = "bet_closes_at", settledAt = "settled_at", nextAt = "next_at"
    }

    public init(id: Int64, betClosesAt: Date, result: Int? = nil, settledAt: Date? = nil, nextAt: Date? = nil) {
        self.id = id
        self.betClosesAt = betClosesAt
        self.result = result
        self.settledAt = settledAt
        self.nextAt = nextAt ?? betClosesAt.addingTimeInterval(Roulette.spin + Roulette.reveal)
    }
}

/// 한 회원이 한 칸에 건 칩 (같은 칸에 또 걸면 서버가 더한다)
public struct RouletteBet: Decodable, Sendable, Equatable {
    public let playerId: UUID
    public let name: String
    public let spot: Roulette.Spot
    public let amount: Int64
    /// 황금 칩이면 amount = 100 × 개수
    public let golden: Bool
    /// 지급액 (건 칩 포함). 정산 전엔 nil
    public let payout: Int64?

    /// 실제로 건 칩 (황금 칩은 0)
    public var staked: Int64 { golden ? 0 : amount }

    enum CodingKeys: String, CodingKey {
        case name, spot, amount, golden, payout
        case playerId = "player_id"
    }

    public init(playerId: UUID, name: String, spot: Roulette.Spot, amount: Int64, golden: Bool = false, payout: Int64? = nil) {
        self.playerId = playerId
        self.name = name
        self.spot = spot
        self.amount = amount
        self.golden = golden
        self.payout = payout
    }
}

// MARK: - 라운지 벽화 (ADR-0017)

/// 이번 주 벽 + 내 버킷. 칩과 무관하다
public struct PixelBoardState: Decodable, Sendable, Equatable {
    public struct Pixel: Decodable, Sendable, Equatable {
        public let x: Int
        public let y: Int
        /// 팔레트 번호 0~7
        public let c: Int
        /// 칠한 회원 이름
        public let p: String
        public let at: Date

        public init(x: Int, y: Int, c: Int, p: String, at: Date) {
            self.x = x; self.y = y; self.c = c; self.p = p; self.at = at
        }
    }

    public struct Painter: Decodable, Sendable, Equatable {
        public let name: String
        public let count: Int
        public let me: Bool

        public init(name: String, count: Int, me: Bool) {
            self.name = name; self.count = count; self.me = me
        }
    }

    public enum Status: String, Decodable, Sendable {
        case created, same, limited
    }

    /// 서버 시각 (시계 차이 보정용)
    public let now: Date
    public let cap: Int
    /// 충전 간격(초)
    public let refill: Int
    /// now 시점에 남은 픽셀
    public let left: Int
    /// 다음 픽셀이 차는 시각. 가득이면 nil
    public let nextAt: Date?
    public let pixels: [Pixel]
    public let painters: [Painter]
    /// pixel_paint 응답에만 있음
    public let status: Status?

    enum CodingKeys: String, CodingKey {
        case now, cap, refill, left, pixels, painters, status
        case nextAt = "next_at"
    }

    public init(now: Date, cap: Int = 10, refill: Int = 30, left: Int, nextAt: Date?, pixels: [Pixel],
                painters: [Painter], status: Status? = nil) {
        self.now = now; self.cap = cap; self.refill = refill; self.left = left; self.nextAt = nextAt
        self.pixels = pixels; self.painters = painters; self.status = status
    }
}
