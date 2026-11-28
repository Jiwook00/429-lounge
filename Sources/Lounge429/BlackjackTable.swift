import Foundation
import LoungeCore
import LoungeNet
import Observation

/// 블랙잭 테이블 상태 (ADR-0014). 서버 tick 루프 + Realtime 신호로 갱신.
/// 서버는 카드를 한 번에 주지만 화면은 한 장씩 날려 보낸다 → 카드마다 "도착 시각"을 여기서 정한다.
/// 합계·스탬프는 도착한 카드만으로 계산해서 결과가 미리 드러나지 않게 한다.
@MainActor @Observable
final class BlackjackTable {
    /// 한 장이 슈에서 자리까지 날아가는 시간
    static let flight: TimeInterval = 0.35
    /// 딜 순서 사이 간격 (서버는 딜에 3초를 준다: 카드 9장 × 0.3 + 비행)
    static let dealGap: TimeInterval = 0.3
    /// 봇·딜러가 여러 장 칠 때 사이 간격 (서버 연출 시간 0.6초/장과 맞춤)
    static let drawGap: TimeInterval = 0.6
    static let stakes = BetStake.units

    let room: String
    private(set) var state: BJState?
    private(set) var message: String?
    private(set) var busy = false
    private(set) var betAcceptedAt: Date?
    private(set) var acceptedAction: BJSeat.Action?
    private(set) var actionRequestedAt: Date?
    private(set) var resultReceivedAt: Date?
    /// 이번 판 베팅액. 칩 단위를 반복해 눌러 늘린다 (상한 `BetStake.maxAmount`)
    var betStake = BetStake()
    var stake: Int64 { betStake.amount }
    var useGolden = false

    /// 서버 시각 - 로컬 시각
    private(set) var skew: TimeInterval = 0
    /// 카드별 도착(로컬) 시각. key: "s<자리>-<번째>" / "d-<번째>"
    private(set) var arrivals: [String: Date] = [:]
    /// 자리별 마지막 행동을 처음 본 시각 (말풍선)
    private(set) var actions: [Int: Seen] = [:]
    /// 내 차례가 시작된 때 (내 컷 확대 연출). 행동마다 다시 시작하지 않는다
    private(set) var myTurnSince: Date?

    struct Seen: Equatable {
        let action: BJSeat.Action
        let cards: Int
        let at: Date
    }

    private let store: LoungeStore
    private var tasks: [Task<Void, Never>] = []
    private var nap: Task<Void, Never>?
    private var settledSeen: Int64?

    init(store: LoungeStore, room: String = "LOUNGE") {
        self.store = store
        self.room = room
    }

    var myID: UUID? { store.me?.id }
    var round: BJRound? { state?.round }
    var seats: [BJSeat] { state?.seats ?? [] }
    var mySeat: BJSeat? { seats.first { $0.playerId != nil && $0.playerId == myID } }

    func local(_ server: Date) -> Date { server.addingTimeInterval(-skew) }

    // MARK: - Lifecycle

    func enter() {
        guard tasks.isEmpty else { return }
        let changes = store.net.bjChanges(room: room)
        tasks = [
            Task { [weak self] in await self?.loop() },
            Task { [weak self] in for await _ in changes { self?.nap?.cancel() } },
        ]
    }

    func leave() {
        tasks.forEach { $0.cancel() }
        tasks = []
        nap?.cancel()
    }

    // MARK: - 행동

    func bet() async {
        await run {
            let golden = self.useGolden && self.store.golden() > 0
            let s = try await self.store.net.bjBet(room: self.room, amount: golden ? 100 : self.stake, golden: golden)
            self.betAcceptedAt = .now
            if self.store.golden() <= 1 { self.useGolden = false }
            return s
        }
        await store.refreshMe()
    }

    func deal() async {
        await run { try await self.store.net.bjDeal(room: self.room) }
    }

    func act(_ action: BJSeat.Action) async {
        let requested = Date()
        await run {
            let state = try await self.store.net.bjAction(room: self.room, action)
            self.acceptedAction = action
            self.actionRequestedAt = requested
            return state
        }
        if action == .double { await store.refreshMe() }
    }

    private func run(_ call: @escaping @MainActor () async throws -> BJState) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            apply(try await call())
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: - Sync

    private func loop() async {
        while !Task.isCancelled {
            var wake: TimeInterval = 3
            do {
                apply(try await store.net.bjTick(room: room))
                wake = nextWake()
                if message == "연결이 끊겼어요" { message = nil }
            } catch {
                if Task.isCancelled { return }
                message = "연결이 끊겼어요"
            }
            let t = Task { _ = try? await Task.sleep(for: .seconds(wake)) }
            nap = t
            await t.value
        }
    }

    /// 다음 마감(베팅 마감, 차례 마감, 결과 끝) 조금 뒤에 다시 tick
    private func nextWake(now: Date = .now) -> TimeInterval {
        guard let r = round else { return 5 }
        let marks = [r.phase == .betting ? r.betClosesAt : nil, r.turnDeadline, r.phase == .done ? r.nextAt : nil]
            .compactMap { $0.map(local) }
            .filter { $0 > now }
        guard let next = marks.min() else { return r.phase == .done ? 5 : 1 }
        return min(3, max(0.25, next.timeIntervalSince(now) + 0.15))
    }

    func apply(_ s: BJState, at now: Date = .now) {
        skew = s.now.timeIntervalSince(now)
        let fresh = s.round?.id != state?.round?.id
        if fresh {
            arrivals = [:]
            actions = [:]
        }
        if fresh {
            resultReceivedAt = nil
        } else if s.round?.phase == .done, state?.round?.phase != .done {
            resultReceivedAt = now
        }
        state = s
        guard let r = s.round else { return }

        // 딜: 자리 1~4 첫 장 → 딜러 → 자리 1~4 둘째 장
        let dealStart = local(r.betClosesAt)
        let inDeal = now < dealStart.addingTimeInterval(3.2)
        let seats = s.seats.sorted { $0.seat < $1.seat }
        let order = seats.map { "s\($0.seat)-0" } + ["d-0"] + seats.map { "s\($0.seat)-1" }
        for (i, key) in order.enumerated() where arrivals[key] == nil && exists(key, in: s) {
            arrivals[key] = (fresh && !inDeal)
                ? .distantPast
                : dealStart.addingTimeInterval(0.15 + Double(i) * Self.dealGap + Self.flight)
        }
        // 그 뒤로 친 카드: 앞 장이 도착하고 drawGap 뒤, 빨라도 지금부터 비행 시간 뒤
        func schedule(_ prefix: String, count: Int, from: Int) {
            guard count > from else { return }
            for i in from..<count where arrivals["\(prefix)-\(i)"] == nil {
                let prev = arrivals["\(prefix)-\(i - 1)"] ?? now
                arrivals["\(prefix)-\(i)"] = fresh
                    ? .distantPast
                    : max(now.addingTimeInterval(Self.flight), prev.addingTimeInterval(Self.drawGap))
            }
        }
        for seat in seats { schedule("s\(seat.seat)", count: seat.cards.count, from: 2) }
        schedule("d", count: r.dealerCards.count, from: 1)

        for seat in seats {
            guard let a = seat.lastAction else { continue }
            let seen = actions[seat.seat]
            if seen?.action != a || seen?.cards != seat.cards.count {
                actions[seat.seat] = Seen(action: a, cards: seat.cards.count, at: fresh ? .distantPast : now)
            }
        }

        let mine = seats.first { $0.playerId != nil && $0.playerId == myID }
        if r.phase == .playing, let mine, r.turnSeat == mine.seat, mine.state == .playing {
            if myTurnSince == nil { myTurnSince = now }
        } else {
            myTurnSince = nil
        }

        // 내 판이 정산되면 지갑 다시 읽기
        if r.phase == .done, settledSeen != r.id, mySeat != nil {
            settledSeen = r.id
            Task { await store.refreshMe() }
        }
    }

    private func exists(_ key: String, in s: BJState) -> Bool {
        if key == "d-0" { return !(s.round?.dealerCards.isEmpty ?? true) }
        let parts = key.dropFirst().split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let seat = s.seats.first(where: { $0.seat == parts[0] }) else { return false }
        return seat.cards.count > parts[1]
    }

    // MARK: - 화면용 계산

    /// 카드 도착 시각 (없으면 이미 놓여 있음)
    func arrival(_ key: String) -> Date { arrivals[key] ?? .distantPast }

    /// 지금 보이는(도착한) 카드 수
    func visibleCount(_ prefix: String, total: Int, at now: Date) -> Int {
        (0..<total).filter { arrival("\(prefix)-\($0)") <= now }.count
    }

    /// 그 손의 마지막 카드가 도착하는 시각
    func settledAt(_ prefix: String, total: Int) -> Date {
        (0..<total).map { arrival("\(prefix)-\($0)") }.max() ?? .distantPast
    }

    /// 자리 번호 → 화면 칸. 나는 늘 왼쪽 아래(2), 나머지는 U자 순서로 (0 오른쪽 위, 1 오른쪽 아래, 2 왼쪽 아래, 3 왼쪽 위)
    func slot(of seat: Int) -> Int {
        let taken = Set(seats.map(\.seat))
        let anchor = mySeat?.seat ?? (1...4).first { !taken.contains($0) } ?? 1
        return ((seat - anchor + 2) % 4 + 4) % 4
    }

    /// 판이 없거나 끝난 판의 결과 연출도 지났으면 쉬는 중 (걸면 새 판)
    func idle(at now: Date) -> Bool {
        guard let r = round else { return true }
        return r.phase == .done && local(r.nextAt ?? r.betClosesAt) <= now
    }

    // MARK: - Preview

    /// apply 뒤에 말풍선·도착 시각을 덮어쓴다 (스냅샷은 처음 받은 판이라 apply가 지난 일로 친다)
    func preview(arrivals: [String: Date] = [:], actions: [Int: Seen] = [:], myTurnSince: Date? = nil) {
        self.arrivals.merge(arrivals) { $1 }
        self.actions.merge(actions) { $1 }
        if let myTurnSince { self.myTurnSince = myTurnSince }
    }
}
