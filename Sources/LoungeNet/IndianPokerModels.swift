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
    /// 테이블을 만들 때 고르는 봇 수 (서버 ip_create의 p_bots)
    public static let botRange = 1...3
    /// 테이블을 만들 때 고르는 최대 인원 (나 + 봇). 서버엔 봇 수 = 최대 인원 − 1로 보낸다
    public static let seatRange = 2...4
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
    /// 사람 + 봇 자리 수 (2~4)
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
    /// 사람은 시작 + 11초(지나면 자동 폴드), 봇은 1~5초 뒤 행동
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
    /// nil = 봇
    public let playerId: UUID?
    public let name: String
    /// 사람의 지갑 칩. 봇은 nil (무한)
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

/// ip_lobby 결과: 열린 테이블 목록 (사람만 센다, 봇은 숨김)
public struct IPLobby: Decodable, Sendable, Equatable {
    public struct Table: Decodable, Sendable, Equatable, Identifiable {
        public let id: Int64
        public let capacity: Int
        /// 앉은 사람 수 (봇 제외). "2/4"의 2
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

    /// 끝난 판에서 팟을 받은 자리 (메인이든 사이드든). 환급만 받은 자리는 빼고, 자리 번호 순
    public var winners: [Int] {
        Array(Set(awards.filter { !$0.refund }.flatMap(\.seats))).sorted()
    }

    /// 끝난 판의 팟별 결과. 서버 정산(ip_settle)과 같은 단계 나눔: 접지 않은 자리가 낸 금액 단계마다 팟을 나누고,
    /// 그 단계까지 낸 접지 않은 자리 중 높은 카드가 가져간다(동점이면 나눔). 혼자만 낸 단계와
    /// 접지 않은 자리의 최고 금액 위로 접은 자리가 낸 칩은 낸 사람에게 환급(`refund`).
    /// 메인 팟이 맨 앞, 같은 사람이 가져간 이웃 단계는 합친다
    public var awards: [IPAward] {
        guard hand?.phase == .done else { return [] }
        let live = seats.filter { !$0.folded }
        let levels = Array(Set(live.map(\.put))).sorted()
        var out: [IPAward] = []
        func add(_ amount: Int64, _ who: [Int], refund: Bool) {
            guard amount > 0, !who.isEmpty else { return }
            if let last = out.last, last.seats == who, last.refund == refund {
                out[out.count - 1] = IPAward(amount: last.amount + amount, seats: who, refund: refund)
            } else {
                out.append(IPAward(amount: amount, seats: who, refund: refund))
            }
        }
        var prev: Int64 = 0
        for level in levels {
            let payers = seats.filter { $0.put > prev }
            let amount = payers.reduce(Int64(0)) { $0 + min($1.put, level) - prev }
            let eligible = live.filter { $0.put >= level }
            let top = eligible.compactMap(\.card).max()
            let takers = eligible.filter { $0.card == top }.map(\.seat)
            // 이 단계에 낸 사람이 가져가는 사람 하나뿐이면 이긴 게 아니라 돌려받은 것
            let refund = payers.count == 1 && takers == [payers[0].seat]
            add(amount, takers, refund: refund)
            prev = level
        }
        // 접지 않은 자리 최고 금액 위로 접은 자리가 낸 칩: 낸 만큼 환급
        for seat in seats where seat.folded && seat.put > prev {
            out.append(IPAward(amount: seat.put - prev, seats: [seat.seat], refund: true))
        }
        return out
    }

    /// 단조 증가하는 진행 위치. 늦게 도착한 오래된 응답(이전 판·이전 차례·끝나기 전)을 버리는 데 쓴다.
    /// 판·단계·차례가 같으면 서버 시각(`now`)으로 → 같은 차례 안의 다른 변경(입장·칩)도 역순으로 적용되지 않는다
    public var progress: IPProgress {
        IPProgress(hand: hand?.id ?? 0, phase: hand?.phase == .done ? 1 : 0, turn: hand?.turnNo ?? 0, at: now)
    }
}

/// 끝난 판에서 팟 하나(또는 환급)를 누가 얼마 받았는지
public struct IPAward: Sendable, Equatable {
    public let amount: Int64
    public let seats: [Int]
    /// 이긴 게 아니라 낸 칩을 돌려받음
    public let refund: Bool
}

/// (판 ID, 단계, 차례 번호, 서버 시각) 순서. 같은 테이블에서 이 값이 더 작은 상태는 이미 지나간 상태다
public struct IPProgress: Sendable, Comparable {
    public let hand: Int64
    public let phase: Int
    public let turn: Int
    /// 서버가 상태를 만든 시각 (같은 차례 안의 순서)
    public let at: Date

    public static func < (a: IPProgress, b: IPProgress) -> Bool {
        (a.hand, a.phase, a.turn, a.at.timeIntervalSince1970) < (b.hand, b.phase, b.turn, b.at.timeIntervalSince1970)
    }
}

/// 입장 요청(ip_create·ip_join)과 일어나기·종료가 겹칠 때의 판단.
/// 서버가 입장을 커밋했는데 응답이 늦거나 사라진 동안 일어나면, 응답(또는 `ip_lobby`의 `my_table` 조회)을
/// 기다렸다가 그 자리를 이탈한다. 이탈은 자리마다 한 번만 내고(`issued`), 조회가 실패하면 정해진 횟수만 다시 한다
public struct IPJoinGate: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        case none
        /// 그 테이블에 앉은 걸로 (평소 입장, 앱을 다시 켰을 때 되찾기)
        case sit(Int64)
        /// 그 테이블에서 일어나기 시작
        case leave(Int64)
        /// 입장 결과를 모르니 `after`초 뒤 ip_lobby로 서버 좌석을 조회
        case probe(after: TimeInterval)
    }

    /// 서버가 입장을 확실히 거절한 코드 (ip_join·ip_create가 RAISE하는 것. 예외면 트랜잭션이 롤백돼 자리가 없다).
    /// `already_at_table`은 다른 자리가 이미 있다는 뜻이라 넣지 않는다 → 조회해서 그 자리를 찾는다.
    /// 그 밖의 오류(5xx·네트워크·시간 초과·디코딩 실패·JSON 본문이 있는 5xx의 알 수 없는 메시지)는 결과를 모르는 것
    public static let rejections: Set<String> = [
        "not_authenticated", "not_named", "insufficient_chips", "invalid_bots", "no_table", "table_closed", "table_full",
    ]
    /// 조회 실패 뒤 다시 조회하는 횟수 상한 (1·2·4초 뒤, 합쳐 약 7초)
    public static let maxProbes = 4

    /// 입장 오류가 서버의 확실한 거절인지
    public static func isRejection(_ error: any Error) -> Bool {
        guard case LoungeError.server(let code) = error else { return false }
        return rejections.contains(code)
    }

    /// 입장 요청을 보냈고 응답을 아직 못 받음
    public private(set) var joining = false
    /// 입장 중에 일어나기·종료를 눌렀음 (결과가 나올 때까지 유지)
    public private(set) var cancelled = false
    /// 입장 결과를 모름 (조회로 확인할 때까지)
    public private(set) var unresolved = false
    /// 이번 입장에서 한 조회 횟수
    public private(set) var probes = 0
    /// 이번 입장에서 이미 이탈을 낸 테이블 (같은 자리에 두 번 내지 않게)
    public private(set) var issued: Int64?

    public init() {}

    /// 결과를 기다리는 취소가 있는지 (나가는 중 표시, 종료 대기)
    public var pending: Bool { cancelled }

    public mutating func start() {
        joining = true
        cancelled = false
        unresolved = false
        probes = 0
        issued = nil
    }

    /// 입장 중이거나 결과를 모르면 취소로 표시한다(결과가 나오면 이탈). 아니면 false
    public mutating func cancel() -> Bool {
        guard joining || unresolved else { return false }
        cancelled = true
        return true
    }

    /// 입장 응답. `table`은 앉은 테이블(거절이면 nil), `certain == false`는 결과를 모름 (`isRejection`이 아닌 오류)
    public mutating func finish(table: Int64?, certain: Bool) -> Step {
        joining = false
        if let table {
            defer { cancelled = false }
            if !cancelled { return .sit(table) }
            return issue(table)
        }
        if !certain {
            unresolved = true
            probes = 1
            return .probe(after: 0)
        }
        cancelled = false
        return .none
    }

    /// 조회가 실패했을 때: 횟수 안이면 1·2·4초 뒤 다시, 넘으면 포기(서버 규칙: 차례 11초 폴드, 연속 2판이면 자리에서 빠짐)
    public mutating func probeFailed() -> Step {
        guard unresolved else { return .none }
        guard probes < Self.maxProbes else {
            unresolved = false
            cancelled = false
            return .none
        }
        probes += 1
        return .probe(after: Double(1 << (probes - 2)))
    }

    /// 로비 조회 결과 (`my_table`)
    public mutating func lobby(myTable: Int64?) -> Step {
        guard let table = myTable else {
            // 입장 응답까지 끝났는데 서버에 자리가 없으면 취소할 것도 없다
            if !joining {
                cancelled = false
                unresolved = false
            }
            return .none
        }
        unresolved = false
        guard cancelled else { return .sit(table) }
        if !joining { cancelled = false }
        return issue(table)
    }

    private mutating func issue(_ table: Int64) -> Step {
        guard issued != table else { return .none }
        issued = table
        return .leave(table)
    }
}

/// 서버 시각 − 로컬 시각 추정. 응답마다 덮어쓰면 늦게 도착한 응답이 시계를 되감으므로
/// 왕복 시간이 가장 짧았던 표본을 믿는다(왕복의 절반을 빼서 보정). 시계가 흐를 수 있어
/// 30초가 지나면 허용 왕복 시간을 두 배로 늘려 새 표본을 받아들인다
public struct ClockSkew: Sendable, Equatable {
    public private(set) var offset: TimeInterval = 0
    private var bestRTT: TimeInterval = .infinity
    private var bestAt: Date = .distantPast

    public static let window: TimeInterval = 30

    public init() {}

    public mutating func add(server: Date, sent: Date, received: Date) {
        let rtt = max(0, received.timeIntervalSince(sent))
        if received.timeIntervalSince(bestAt) > Self.window {
            bestRTT = bestRTT.isFinite ? bestRTT * 2 : .infinity
            bestAt = received
        }
        guard rtt <= bestRTT else { return }
        offset = server.timeIntervalSince(sent.addingTimeInterval(rtt / 2))
        bestRTT = rtt
        bestAt = received
    }
}
