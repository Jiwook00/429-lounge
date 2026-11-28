import Foundation

// MARK: - 인디언 포커 (ADR-0023)

/// 인디언 포커 규칙 상수. 판단과 검사는 서버가 하고, 앱은 버튼을 켜고 끄는 데만 쓴다
public enum IndianPoker {
    /// 매 판 자동으로 내는 칩 = 첫 베팅 최소
    public static let ante: Int64 = 10
    /// 판 시작 뒤 카드를 나눠 주는 연출. 첫 차례는 이 뒤에 시작한다
    public static let dealSeconds: TimeInterval = 2
    /// 사람 차례 시간 (서버 기준)
    public static let turnSeconds: TimeInterval = 11
    /// 결과를 보여 주는 시간. 끝나면 다음 판
    public static let revealSeconds: TimeInterval = 5
    /// 테이블을 만들 때 고르는 컴퓨터 수
    public static let botRange = 1...3
}

/// ip_tick / ip_join / ip_create / ip_action / ip_leave 결과: 테이블 하나 전부
public struct IPState: Decodable, Sendable, Equatable {
    /// 서버 시각 (시계 차이 보정용)
    public let now: Date
    public let table: IPTable
    public let me: IPMe
    /// 지금 앉아 있는 사람 (다음 판을 기다리는 사람 포함)
    public let members: [IPMember]
    public let hand: IPHand?
    /// 이번 판 자리. 내 자리의 `card`는 판이 끝나기 전엔 늘 nil
    public let seats: [IPSeat]
    /// ip_action이 행동을 받지 않았을 때의 이유 (`stale_turn`, `not_your_turn`, `not_started`, `raise_too_small` 등).
    /// 이때도 밀린 정산은 끝난 최신 상태다. 다른 RPC 결과에선 늘 nil
    public let rejected: String?

    enum CodingKeys: String, CodingKey {
        case now, table, me, members, hand, seats, rejected
    }

    public init(now: Date, table: IPTable, me: IPMe, members: [IPMember] = [], hand: IPHand? = nil, seats: [IPSeat] = [],
                rejected: String? = nil) {
        self.now = now
        self.table = table
        self.me = me
        self.members = members
        self.hand = hand
        self.seats = seats
        self.rejected = rejected
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        now = try c.decode(Date.self, forKey: .now)
        table = try c.decode(IPTable.self, forKey: .table)
        me = try c.decode(IPMe.self, forKey: .me)
        members = try c.decode([IPMember].self, forKey: .members)
        hand = try c.decodeIfPresent(IPHand.self, forKey: .hand)
        seats = try c.decode([IPSeat].self, forKey: .seats)
        rejected = try c.decodeIfPresent(String.self, forKey: .rejected)
    }

    /// 행동이 거절됐으면 화면에 띄울 에러
    public var rejectedError: LoungeError? { rejected.map(LoungeError.server) }

    /// 이번 판의 내 자리. 판 도중에 들어왔으면 다음 판까지 nil
    public var mySeat: IPSeat? { me.handSeat.flatMap { s in seats.first { $0.seat == s } } }
    /// 지금 차례인 자리
    public var turn: IPSeat? { hand?.turnSeat.flatMap { s in seats.first { $0.seat == s } } }
    /// `date`(서버 시각으로 보정한 지금)에 내 차례인지. 딜 연출 2초 동안(차례 시작 전)과 마감 뒤엔 false → 버튼 비활성
    public func isMyTurn(at date: Date) -> Bool {
        guard let hand, hand.phase == .betting, let mine = mySeat, turn?.seat == mine.seat else { return false }
        if let start = hand.turnStartedAt, date < start { return false }
        if let deadline = hand.turnDeadline, date >= deadline { return false }
        return true
    }

    /// `date`에 할 수 있는 행동 (내 차례가 아니면 nil). 서버 ip_apply와 같은 규칙
    public func myOptions(at date: Date) -> IPOptions? {
        guard isMyTurn(at: date), let hand, let mine = mySeat else { return nil }
        let toCall = hand.currentBet - mine.bet
        let stack = mine.chips ?? 0
        return IPOptions(toCall: toCall, minRaise: hand.minRaise, stack: stack, opened: hand.currentBet > 0)
    }
}

/// 내 차례 버튼 상태. raise·bet의 금액은 "지금 베팅 위로 더 올리는 칩"
public struct IPOptions: Sendable, Equatable {
    /// 콜하려면 더 내야 하는 칩 (0이면 체크)
    public let toCall: Int64
    /// 베팅·레이즈 최소 폭 (직전에 올린 폭, 처음엔 앤티)
    public let minRaise: Int64
    /// 지금 지갑 칩
    public let stack: Int64
    /// 누가 이미 베팅했는지 (true면 bet 대신 raise)
    public let opened: Bool

    public var canCheck: Bool { toCall == 0 }
    public var canCall: Bool { toCall > 0 }
    /// 콜만 해도 칩이 바닥나면 올인 콜
    public var callIsAllIn: Bool { toCall > 0 && stack <= toCall }
    /// 최소 폭만큼 올릴 칩이 없으면 올리는 건 올인뿐
    public var raiseIsAllInOnly: Bool { stack <= toCall + minRaise }
    /// 베팅·레이즈 버튼을 켤지 (콜 금액보다 칩이 많아야 위로 올릴 수 있다)
    public var canRaise: Bool { stack > toCall }
    /// 올인할 때 보낼 금액 (지금 베팅 위로)
    public var allInAmount: Int64 { max(0, stack - toCall) }
}

public struct IPTable: Decodable, Sendable, Equatable {
    public enum Status: String, Decodable, Sendable { case open, closed }

    public let id: Int64
    /// 사람 + 컴퓨터 자리 수 (2~4)
    public let capacity: Int
    public let status: Status
    public let closedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, capacity, status
        case closedAt = "closed_at"
    }

    public init(id: Int64, capacity: Int, status: Status = .open, closedAt: Date? = nil) {
        self.id = id
        self.capacity = capacity
        self.status = status
        self.closedAt = closedAt
    }
}

public struct IPMe: Decodable, Sendable, Equatable {
    public enum LeftReason: String, Decodable, Sendable {
        /// 일어나기를 눌렀다
        case leave
        /// 연속 2판 시간 초과로 자동 폴드돼서 그 판 끝에 빠졌다
        case away
        /// 다음 판 앤티(10칩)가 없어서 빠졌다
        case broke
    }

    /// 지금 이 테이블에 앉아 있는지
    public let member: Bool
    /// 앉은 자리 (다음 판부터 이 자리)
    public let seat: Int?
    /// 이번 판에서 내 자리. 판 도중에 들어왔으면 nil
    public let handSeat: Int?
    /// 앉아 있지 않으면 마지막으로 빠진 이유
    public let leftReason: LeftReason?

    enum CodingKeys: String, CodingKey {
        case member, seat
        case handSeat = "hand_seat", leftReason = "left_reason"
    }

    public init(member: Bool, seat: Int? = nil, handSeat: Int? = nil, leftReason: LeftReason? = nil) {
        self.member = member
        self.seat = seat
        self.handSeat = handSeat
        self.leftReason = leftReason
    }
}

public struct IPMember: Decodable, Sendable, Equatable {
    public let seat: Int
    public let playerId: UUID
    public let name: String

    enum CodingKeys: String, CodingKey {
        case seat, name
        case playerId = "player_id"
    }

    public init(seat: Int, playerId: UUID, name: String) {
        self.seat = seat
        self.playerId = playerId
        self.name = name
    }
}

public struct IPHand: Decodable, Sendable, Equatable {
    public enum Phase: String, Decodable, Sendable { case betting, done }

    public let id: Int64
    public let handNo: Int
    public let phase: Phase
    /// 이번 판 첫 행동 자리 (판마다 한 칸씩)
    public let firstSeat: Int
    /// 지금 차례. nil = 끝
    public let turnSeat: Int?
    /// 차례 번호 (차례가 바뀔 때마다 +1). ip_action에 그대로 보낸다
    public let turnNo: Int
    public let turnStartedAt: Date?
    /// 사람은 시작 + 11초(지나면 자동 폴드), 컴퓨터는 1~5초 뒤 행동
    public let turnDeadline: Date?
    /// 이번 판 가장 높은 베팅 (앤티 제외). 0이면 아직 아무도 안 걸었다
    public let currentBet: Int64
    /// 베팅·레이즈 최소 폭
    public let minRaise: Int64
    /// 판돈 (앤티 포함)
    public let pot: Int64
    public let startedAt: Date
    public let settledAt: Date?
    /// 결과 5초가 끝나는 시각 = 다음 판 시작
    public let nextAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, phase, pot
        case handNo = "hand_no", firstSeat = "first_seat", turnSeat = "turn_seat", turnNo = "turn_no", turnStartedAt = "turn_started_at"
        case turnDeadline = "turn_deadline", currentBet = "current_bet", minRaise = "min_raise"
        case startedAt = "started_at", settledAt = "settled_at", nextAt = "next_at"
    }

    public init(id: Int64, handNo: Int, phase: Phase, firstSeat: Int, turnSeat: Int? = nil, turnNo: Int = 0, turnStartedAt: Date? = nil,
                turnDeadline: Date? = nil, currentBet: Int64 = 0, minRaise: Int64 = IndianPoker.ante, pot: Int64 = 0,
                startedAt: Date, settledAt: Date? = nil, nextAt: Date? = nil) {
        self.id = id
        self.handNo = handNo
        self.phase = phase
        self.firstSeat = firstSeat
        self.turnSeat = turnSeat
        self.turnNo = turnNo
        self.turnStartedAt = turnStartedAt
        self.turnDeadline = turnDeadline
        self.currentBet = currentBet
        self.minRaise = minRaise
        self.pot = pot
        self.startedAt = startedAt
        self.settledAt = settledAt
        self.nextAt = nextAt
    }
}

public struct IPSeat: Decodable, Sendable, Equatable, Identifiable {
    public enum Action: String, Codable, Sendable {
        case check, bet, call, raise, fold
        /// 11초 시간 초과 = 자동 폴드
        case timeout
        /// 판 도중에 일어남 = 폴드
        case leave
    }

    /// 1~capacity
    public let seat: Int
    /// nil = 컴퓨터
    public let playerId: UUID?
    public let name: String
    /// 사람의 지갑 칩. 컴퓨터는 nil (무한)
    public let chips: Int64?
    /// 이번 판에 낸 칩 전부 (앤티 포함)
    public let put: Int64
    /// 베팅 라운드에서 낸 칩 (앤티 제외)
    public let bet: Int64
    public let folded: Bool
    public let allIn: Bool
    public let lastAction: Action?
    /// 마지막 행동으로 낸 칩
    public let lastAmount: Int64?
    /// 1~10. 판이 끝나기 전엔 내 자리는 nil
    public let card: Int?
    /// 지급액 (낸 칩 포함). 정산 전엔 nil
    public let payout: Int64?
    /// 순수익 = 지급 − 낸 칩
    public let net: Int64?

    public var id: Int { seat }
    public var bot: Bool { playerId == nil }

    enum CodingKeys: String, CodingKey {
        case seat, name, chips, put, bet, folded, card, payout, net
        case playerId = "player_id", allIn = "all_in", lastAction = "last_action", lastAmount = "last_amount"
    }

    public init(seat: Int, playerId: UUID?, name: String, chips: Int64? = nil, put: Int64 = IndianPoker.ante, bet: Int64 = 0,
                folded: Bool = false, allIn: Bool = false, lastAction: Action? = nil, lastAmount: Int64? = nil,
                card: Int? = nil, payout: Int64? = nil, net: Int64? = nil) {
        self.seat = seat
        self.playerId = playerId
        self.name = name
        self.chips = chips
        self.put = put
        self.bet = bet
        self.folded = folded
        self.allIn = allIn
        self.lastAction = lastAction
        self.lastAmount = lastAmount
        self.card = card
        self.payout = payout
        self.net = net
    }
}

/// ip_lobby 결과: 열린 테이블 목록 (사람만 센다, 컴퓨터는 숨김)
public struct IPLobby: Decodable, Sendable, Equatable {
    public struct Table: Decodable, Sendable, Equatable, Identifiable {
        public let id: Int64
        public let capacity: Int
        /// 앉은 사람 수 (컴퓨터 제외). "2/4"의 2
        public let humans: Int
        /// 앉은 사람 이름 (자리 순)
        public let names: [String]
        public let handNo: Int?

        public var full: Bool { humans >= capacity }

        enum CodingKeys: String, CodingKey {
            case id, capacity, humans, names
            case handNo = "hand_no"
        }

        public init(id: Int64, capacity: Int, humans: Int, names: [String], handNo: Int? = nil) {
            self.id = id
            self.capacity = capacity
            self.humans = humans
            self.names = names
            self.handNo = handNo
        }
    }

    public let now: Date
    /// 내가 앉아 있는 테이블 (앱을 다시 켰을 때 바로 돌아가기)
    public let myTable: Int64?
    /// 자리 있는 테이블부터
    public let tables: [Table]

    enum CodingKeys: String, CodingKey {
        case now, tables
        case myTable = "my_table"
    }

    public init(now: Date, myTable: Int64? = nil, tables: [Table]) {
        self.now = now
        self.myTable = myTable
        self.tables = tables
    }
}

// MARK: - 화면용 계산 (판단은 서버, 여기선 보여 주기만)

/// 올인이 있을 때 판돈을 메인 팟 / 사이드 팟 두 줄로 나눠 보여 준다.
/// 서버 정산(ip_settle)과 같은 단계 나눔이지만 화면은 두 줄까지만: 가장 낮은 올인 금액까지가 메인, 나머지가 사이드
public struct IPPots: Sendable, Equatable {
    public let main: Int64
    public let side: Int64
    /// 메인 팟을 가져갈 수 있는 자리 (접지 않은 자리)
    public let mainSeats: [Int]
    /// 사이드 팟을 다툴 수 있는 자리 (접지 않았고 메인 상한에 걸린 올인이 아닌 자리. 아직 콜 전인 사람 포함)
    public let sideSeats: [Int]
    /// 상한에 걸린 올인 자리 (사이드 팟은 못 가져감)
    public let cappedSeats: [Int]
}

extension IPState {
    /// 이번 판 앤티 합 (자리마다 10)
    public var anteTotal: Int64 { Int64(seats.count) * IndianPoker.ante }

    /// 접지 않은 올인 자리보다 더 낸 칩이 있으면 메인/사이드로 나눈다. 없으면 nil (판돈 한 줄)
    public var pots: IPPots? {
        let live = seats.filter { !$0.folded }
        guard let cap = live.filter(\.allIn).map(\.put).min(),
              seats.contains(where: { $0.put > cap }) else { return nil }
        let main = seats.reduce(Int64(0)) { $0 + min($1.put, cap) }
        let total = seats.reduce(Int64(0)) { $0 + $1.put }
        return IPPots(main: main, side: total - main,
                      mainSeats: live.map(\.seat),
                      sideSeats: live.filter { !($0.allIn && $0.put <= cap) }.map(\.seat),
                      cappedSeats: live.filter { $0.allIn && $0.put <= cap }.map(\.seat))
    }

    /// 끝난 판에서 이긴 자리: 접지 않은 자리 중 가장 높은 카드 (동점이면 여럿)
    public var winners: [Int] {
        guard hand?.phase == .done else { return [] }
        let live = seats.filter { !$0.folded }
        guard let top = live.compactMap(\.card).max() else { return [] }
        return live.filter { $0.card == top }.map(\.seat)
    }
}
