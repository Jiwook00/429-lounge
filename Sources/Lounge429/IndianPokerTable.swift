import AppKit
import Foundation
import LoungeCore
import LoungeNet
import Observation

/// 인디언 포커 (ADR-0023). 서버에 상주 프로세스가 없어 앉은 앱이 `ip_tick`을 불러 시간 초과·봇 행동·다음 판을 진행한다.
/// 그래서 이 객체는 화면이 아니라 `LoungeStore`가 들고 있고, 앉아 있는 동안은 팝오버를 닫아도 tick을 계속한다
/// (내 차례면 메뉴바 아이콘이 깜빡인다). 로비 목록은 포커 화면을 보고 있을 때만 읽는다.
@MainActor @Observable
final class IndianPokerTable {
    /// 판돈 패널 행동 알림 (1.5초, 겹치면 최근 하나만)
    struct Alert: Equatable {
        let seat: Int
        let name: String
        let action: IPSeat.Action
        let amount: Int64?
        let allIn: Bool
        let at: Date
    }

    static let alertSeconds: TimeInterval = 1.5
    /// 화면에 조용히 새 상태만 그리는 거절 (지난 차례, 딜 연출 중 등). 에러로 보이지 않는다
    static let quietRejections: Set<String> = ["stale_turn", "not_your_turn", "not_started"]

    weak var store: LoungeStore?
    /// 실행 중인 앱의 테이블 (앱 종료 때 일어나기). 스냅샷·도구는 nil
    static weak var current: IndianPokerTable?

    /// 열린 테이블 목록. 포커 화면(로비)을 볼 때와 팝오버를 열 때 읽는다
    private(set) var lobby: IPLobby?
    /// 앉아 있는 테이블
    private(set) var tableID: Int64?
    private(set) var state: IPState?
    private(set) var busy = false
    private(set) var message: String?
    /// 자리에서 빠진 이유 (로비 위 안내). 다시 앉으면 지운다
    private(set) var leftNotice: IPMe.LeftReason?
    private(set) var alert: Alert?
    /// 서버 시각 − 로컬 시각 (가장 짧은 왕복 표본 기준이라 늦게 온 응답이 시계를 되감지 않는다)
    private var clock = ClockSkew()
    var skew: TimeInterval { clock.offset }
    /// 일어나는 중인 테이블. 서버가 이탈(`me.member == false`)을 돌려줄 때까지 다시 시도하고,
    /// 그동안은 자리 칸·버튼을 막고 로비·tick 응답이 이 자리를 되살리지 못하게 한다
    private(set) var leaving: Int64?
    /// 이탈을 몇 번 시도했는지 (실패하면 백오프: 1·2·4·8초)
    private(set) var leaveAttempts = 0
    /// 마지막으로 이탈을 끝낸 테이블과 그 시각. 그 전에 보낸 로비 응답의 `my_table`은 무시한다
    private var leftTable: (id: Int64, at: Date)?
    /// 입장 요청과 일어나기·종료가 겹칠 때 (입장이 커밋됐는데 응답이 늦는 동안 취소)
    private var gate = IPJoinGate()
    /// 입장 요청이 진행 중이거나, 입장 중에 취소해서 결과(이탈)를 기다리는 중
    var joinPending: Bool { gate.joining || gate.pending || gate.unresolved }
    /// 입장 중에 일어나기·종료를 눌러 결과를 기다리는 중 (라운지 타일 "나가는 중")
    var cancellingJoin: Bool { gate.pending }
    /// 입장 응답(실패)을 받은 시각. 그 전에 보낸 로비 조회는 입장 결과 판단에 쓰지 않는다
    private var joinFinishedAt: Date?
    /// 메뉴바 깜빡임 (내 차례인데 포커 화면을 안 보고 있을 때)
    private(set) var flash = false
    /// 새 테이블 최대 인원 (2~4, 기본 4). 빈 자리는 봇이 채우고 사람이 오면 다음 판부터 비킨다
    var maxSeats = 4
    /// 로비에서 "새 테이블 만들기"를 눌러 만들기 화면을 보는 중
    var creating = false
    /// 레이즈(베팅) 패널을 펼쳤는지와 고른 금액 ("지금 베팅 위로 더 올리는 칩")
    var raising = false
    var raiseAmount: Int64 = 0
    /// 포커 화면을 보고 있는지 (RootView가 정한다). 팝오버가 열려 있는지는 store.viewing
    var watching = false {
        didSet {
            if watching { kick() }
            updateFlash()
        }
    }

    private var loopTask: Task<Void, Never>?
    private var nap: Task<Void, Never>?
    private var changes: Task<Void, Never>?
    private var changesKey: Int64?
    private var flashTask: Task<Void, Never>?
    private var settledSeen: Int64?
    private var dealtSeen: Int64?
    private var turnAnnounced: String?

    /// 화면 효과음 (뷰가 붙인다. 스냅샷·라이브 도구에선 없음)
    var onSound: ((GameAudio.Effect) -> Void)?

    init() {}

    var myID: UUID? { store?.me?.id }
    var hand: IPHand? { state?.hand }
    var seats: [IPSeat] { state?.seats ?? [] }
    var mySeat: IPSeat? { state?.mySeat }
    var seated: Bool { tableID != nil }

    func local(_ server: Date) -> Date { server.addingTimeInterval(-skew) }
    func server(_ local: Date) -> Date { local.addingTimeInterval(skew) }

    /// 지금 내 차례(버튼을 켤 때)인지. 딜 연출 2초와 마감 뒤, 일어나는 중엔 false
    func myTurn(at now: Date) -> Bool { leaving == nil && (state?.isMyTurn(at: server(now)) ?? false) }
    func options(at now: Date) -> IPOptions? { leaving == nil ? state?.myOptions(at: server(now)) : nil }

    /// 딜 연출 중 (첫 차례 시작 전)
    func dealing(at now: Date) -> Bool {
        guard let h = hand, h.phase == .betting, let start = h.turnStartedAt else { return false }
        return now < local(start)
    }

    /// 이번 판에 내가 앉아 있지 않음 (판 도중에 들어왔거나 아직 판이 없음) → 대기 화면
    var waiting: Bool { seated && (hand == nil || mySeat == nil) }

    // MARK: - Lifecycle

    /// 앱을 켤 때: 앉아 있던 테이블이 있으면 다시 tick을 시작한다
    func resume() async {
        await refreshLobby()
    }

    /// 라운지 타일용 + 앉은 테이블 확인
    func refreshLobby() async {
        let sent = Date()
        guard let store, store.me != nil, let l = try? await store.net.ipLobby() else { return }
        applyLobby(l, sent: sent)
    }

    /// 로비 응답의 `my_table`로 앉은 테이블을 되찾는다 (앱을 다시 켰을 때). 일어나는 중이거나,
    /// 이탈을 끝내기 전에 보낸 요청의 응답이면 그 자리를 되살리지 않는다.
    /// 입장 중에 취소했으면 그 자리는 되찾지 않고 바로 이탈한다
    private func applyLobby(_ l: IPLobby, sent: Date) {
        lobby = l
        if let left = leftTable, left.id == l.myTable, sent <= left.at { return }
        guard tableID == nil || gate.pending, leaving == nil || gate.pending else { return }
        // 입장 결과를 모르는 동안엔 입장 응답(실패)을 받은 뒤에 보낸 조회만 믿는다 (그 전 조회는 커밋 전일 수 있음)
        if gate.unresolved, let finished = joinFinishedAt, sent < finished { return }
        follow(gate.lobby(myTable: l.myTable))
    }

    /// 입장 결과를 확인하는 조회. 실패하면 정해진 횟수 안에서 다시 (IPJoinGate.probeFailed)
    private func probeLobby() async {
        guard let store else { return }
        let sent = Date()
        do {
            applyLobby(try await store.net.ipLobby(), sent: sent)
        } catch {
            follow(gate.probeFailed())
        }
    }

    /// 입장 판단 결과를 따른다
    private func follow(_ step: IPJoinGate.Step) {
        switch step {
        case .none:
            break
        case .sit(let id):
            guard tableID == nil, leaving == nil else { return }
            tableID = id
            kick()
        case .leave(let id):
            // 커밋된 입장을 취소: 그 자리를 받아 바로 일어나기 (화면은 앉은 상태를 그리지 않는다)
            guard leaving != id else { return }
            tableID = id
            state = nil
            leaving = id
            leaveAttempts = 0
            kick()
        case .probe(let after):
            Task {
                if after > 0 { try? await Task.sleep(for: .seconds(after)) }
                await probeLobby()
            }
        }
    }

    /// 루프가 없으면 시작하고, 자고 있으면 깨운다
    private func kick() {
        if loopTask == nil {
            loopTask = Task { [weak self] in
                await self?.loop()
                self?.loopTask = nil
            }
        } else {
            nap?.cancel()
        }
    }

    private func loop() async {
        while !Task.isCancelled {
            guard let store else { return }
            var wake: TimeInterval = 5
            if let id = leaving {
                // 일어나기: 서버가 확인할 때까지 tick 대신 이탈만 다시 보낸다
                listen(table: nil)
                wake = await tryLeave(id)
                if leaving == nil { continue }
            } else if let id = tableID {
                listen(table: id)
                do {
                    let sent = Date()
                    apply(try await store.net.ipTick(table: id), sent: sent)
                    wake = nextWake()
                    if message == "연결이 끊겼어요" { message = nil }
                } catch {
                    message = "연결이 끊겼어요"
                    wake = 2
                }
            } else if watching {
                listen(table: 0)
                do {
                    let sent = Date()
                    applyLobby(try await store.net.ipLobby(), sent: sent)
                    if message == "연결이 끊겼어요" { message = nil }
                } catch {
                    message = "연결이 끊겼어요"
                }
                if tableID != nil { continue }
            } else {
                break
            }
            let t = Task { _ = try? await Task.sleep(for: .seconds(wake)) }
            nap = t
            await t.value
        }
        listen(table: nil)
    }

    /// Realtime "바뀌었다" 신호: 앉은 테이블(id) / 로비(0) / 끊기(nil). 받으면 바로 tick
    private func listen(table: Int64?) {
        guard changesKey != table else { return }
        changes?.cancel()
        changesKey = table
        guard let table, let store else { changes = nil; return }
        let stream = table == 0 ? store.net.ipLobbyChanges() : store.net.ipChanges(table: table)
        changes = Task { [weak self] in for await _ in stream { self?.nap?.cancel() } }
    }

    /// 1~2초마다(내 차례·판 진행 중이면 1초), 그리고 다음 마감(차례 시작·마감, 다음 판) 조금 뒤에
    private func nextWake(now: Date = .now) -> TimeInterval {
        guard let h = hand else { return 2 }
        let base: TimeInterval = h.phase == .betting ? 1 : 2
        let marks = [h.turnStartedAt, h.turnDeadline, h.phase == .done ? h.nextAt : nil]
            .compactMap { $0.map(local) }
            .filter { $0 > now }
        guard let next = marks.min() else { return base }
        return min(base, max(0.2, next.timeIntervalSince(now) + 0.15))
    }

    // MARK: - 상태 반영

    /// 서버 상태를 반영한다. `sent`는 요청을 보낸 시각(시계 보정용, 없으면 왕복 0으로 본다).
    /// 같은 테이블에서 지금 보이는 것보다 오래된 상태(이전 판·이전 차례·끝나기 전)는 버린다 → 결과·차례·판돈이 되감기지 않음
    @discardableResult
    func apply(_ s: IPState, sent: Date? = nil, at now: Date = .now) -> Bool {
        // 지금 앉은 테이블의 응답만 (일어난 뒤 늦게 온 행동 응답 등은 버린다)
        guard tableID == s.table.id else { return false }
        if let old = state, old.table.id == s.table.id, s.progress < old.progress { return false }
        // 일어나는 중이면 아직 앉아 있다는 응답으로 되살리지 않는다 (이탈 응답은 tryLeave가 처리)
        if leaving != nil, s.me.member { return false }
        clock.add(server: s.now, sent: sent ?? now, received: now)
        let old = state
        let fresh = s.hand?.id != old?.hand?.id
        state = s

        if !s.me.member || s.table.status == .closed {
            detach(reason: s.me.member ? nil : s.me.leftReason)
            return true
        }

        if fresh {
            alert = nil
            raising = false
            if let h = s.hand, dealtSeen != h.id, h.phase == .betting, s.mySeat != nil, old != nil {
                dealtSeen = h.id
                onSound?(.card)
            }
        } else if let prev = old {
            noticeActions(from: prev, to: s, at: now)
        }

        // 내 차례가 끝났으면 레이즈 패널을 접는다
        if raising, !(s.isMyTurn(at: s.now) || dealing(at: now)) { raising = false }
        if let h = s.hand, s.turn?.seat == s.mySeat?.seat, h.phase == .betting, turnAnnounced != "\(h.id):\(h.turnNo)",
           s.isMyTurn(at: s.now) {
            turnAnnounced = "\(h.id):\(h.turnNo)"
            onSound?(.yourTurn)
        }

        // 내 판이 정산되면 지갑 다시 읽기 (메뉴바 숫자)
        if let h = s.hand, h.phase == .done, settledSeen != h.id, let mine = s.mySeat {
            settledSeen = h.id
            if old?.hand?.id == h.id {
                // 사이드 팟만 받아 순수익이 마이너스여도 팟을 받았으면 이긴 소리
                if s.winners.contains(mine.seat) { onSound?(s.winners.count > 1 && (mine.net ?? 0) == 0 ? .push : .collect) }
            }
            Task { await store?.refreshMe() }
        }
        updateFlash()
        return true
    }

    /// 지난 상태와 비교해 새로 행동한 자리를 알림으로. 한 번에 여럿이면 지금 차례 바로 앞 자리(가장 최근)
    private func noticeActions(from prev: IPState, to s: IPState, at now: Date) {
        let before = Dictionary(uniqueKeysWithValues: prev.seats.map { ($0.seat, $0) })
        let changed = s.seats.filter { seat in
            guard seat.lastAction != nil, let b = before[seat.seat] else { return false }
            return b.lastAction != seat.lastAction || b.bet != seat.bet || b.folded != seat.folded || b.allIn != seat.allIn
        }
        guard !changed.isEmpty else { return }
        let cap = max(1, s.table.capacity)
        var pick = changed[changed.count - 1]
        if let turn = s.hand?.turnSeat {
            // 지금 차례 바로 앞 자리가 가장 최근에 행동했다 (지금 차례 자리는 한 바퀴 전)
            func recency(_ seat: Int) -> Int {
                let d = (turn - seat + cap) % cap
                return d == 0 ? cap : d
            }
            pick = changed.min { recency($0.seat) < recency($1.seat) } ?? pick
        }
        guard let action = pick.lastAction else { return }
        alert = Alert(seat: pick.seat, name: pick.name, action: action, amount: pick.lastAmount, allIn: pick.allIn, at: now)
        let mine = pick.seat == s.mySeat?.seat
        switch action {
        case .bet, .raise, .call: onSound?(mine ? .betChip : .chips)
        case .check: onSound?(.stand)
        default: break
        }
    }

    /// 지금 보여 줄 행동 알림
    func currentAlert(at now: Date) -> Alert? {
        guard let alert, now.timeIntervalSince(alert.at) < Self.alertSeconds else { return nil }
        return alert
    }

    private func detach(reason: IPMe.LeftReason?) {
        if let id = tableID { leftTable = (id, Date()) }
        tableID = nil
        leaving = nil
        if reason == .away || reason == .broke { leftNotice = reason }
        raising = false
        alert = nil
        listen(table: nil)
        Task { await store?.refreshMe() }
        updateFlash()
        if watching { kick() }
    }

    // MARK: - 행동

    func create() async {
        // 서버는 봇 수를 받는다: 최대 인원 − 나
        let bots = min(max(maxSeats - 1, IndianPoker.botRange.lowerBound), IndianPoker.botRange.upperBound)
        await enter { try await $0.ipCreate(bots: bots) }
    }

    func join(_ table: Int64) async {
        await enter { try await $0.ipJoin(table: table) }
    }

    private func enter(_ call: @escaping @MainActor (LoungeClient) async throws -> IPState) async {
        guard let store, !busy, leaving == nil, tableID == nil, !joinPending else { return }
        busy = true
        defer { busy = false }
        gate.start()
        do {
            let s = try await call(store.net)
            let step = gate.finish(table: s.me.member ? s.table.id : nil, certain: true)
            if case .sit = step {
                leftNotice = nil
                message = nil
                creating = false
                tableID = s.table.id
                state = nil
                leftTable = nil
                apply(s)
                kick()
            } else {
                // 응답을 기다리는 동안 일어나기·종료를 눌렀다 → 앉은 화면 없이 바로 이탈
                follow(step)
            }
        } catch {
            // 서버가 확실히 거절한 코드만 "자리 없음". 그 밖(JSON 본문이 있는 5xx 포함)은 결과를 모르니 좌석 조회
            joinFinishedAt = Date()
            let step = gate.finish(table: nil, certain: IPJoinGate.isRejection(error))
            if !gate.pending { message = error.localizedDescription }
            if case .probe(after: 0) = step { await probeLobby() } else { follow(step) }
        }
        await store.refreshMe()
    }

    /// 일어나기 시작. 진행 중인 판이면 폴드 (낸 칩은 판돈에 남음).
    /// 서버가 이탈을 확인해야 끝난다: 실패하면 루프가 백오프로 다시 보내고, 그동안 화면은 "나가는 중"
    func leave() {
        // 입장 응답을 기다리는 중이면: 응답(또는 좌석 조회)을 받은 뒤 그 자리를 이탈한다
        if tableID == nil {
            if gate.cancel() { updateFlash() }
            return
        }
        guard let id = tableID, leaving == nil else { return }
        leaving = id
        leaveAttempts = 0
        raising = false
        alert = nil
        updateFlash()
        kick()
    }

    /// 일어나고 서버가 확인할 때까지 기다린다 (앱 종료·개발 도구). 시간 안에 못 끝내면 false.
    /// 입장 응답을 기다리는 중이면 그 응답을 기다리고, 2초가 지나도 안 오면 ip_lobby로 서버 좌석을 한 번 조회한다
    @discardableResult
    func leaveAndWait(timeout: TimeInterval) async -> Bool {
        let start = Date()
        leave()
        let end = start.addingTimeInterval(timeout)
        var probed = false
        while leaving != nil || gate.pending, Date() < end {
            if gate.joining, !probed, Date().timeIntervalSince(start) > 2 {
                probed = true
                Task { await probeLobby() }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return leaving == nil && !gate.pending
    }

    /// 이탈 한 번 시도. 성공하면 자리를 비우고 0, 실패하면 다음 시도까지 기다릴 초
    private func tryLeave(_ id: Int64) async -> TimeInterval {
        guard let store else { return 2 }
        leaveAttempts += 1
        do {
            let s = try await store.net.ipLeave(table: id)
            if !s.me.member || s.table.status == .closed {
                leaving = nil
                tableID = nil
                state = nil
                leftTable = (id, Date())
                message = nil
                Task {
                    await store.refreshMe()
                    await refreshLobby()
                }
                updateFlash()
                return 0
            }
        } catch {
            if case LoungeError.server("no_table") = error {
                leaving = nil
                tableID = nil
                state = nil
                return 0
            }
        }
        message = "나가는 중 · 연결이 돌아오면 바로 일어나요"
        return min(8, pow(2, Double(leaveAttempts - 1)))
    }

    /// 내 차례 행동. 판 ID·차례 번호를 같이 보내 지난 차례로 늦게 도착하면 서버가 거절한다 (그땐 새 상태만 조용히)
    func act(_ action: IPSeat.Action, amount: Int64? = nil) async {
        guard let store, let id = tableID, let h = hand, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let sent = Date()
            let s = try await store.net.ipAction(table: id, hand: h.id, turn: h.turnNo, action, amount: amount)
            apply(s, sent: sent)
            if let code = s.rejected, !Self.quietRejections.contains(code) {
                message = s.rejectedError?.localizedDescription
            } else {
                message = nil
                raising = false
            }
        } catch {
            message = error.localizedDescription
        }
    }

    /// 레이즈(베팅) 패널 열기: 최소 폭으로 시작
    func openRaise(at now: Date) {
        guard let o = options(at: now), o.canRaise else { return }
        raiseAmount = o.raiseIsAllInOnly ? o.allInAmount : o.minRaise
        raising = true
    }

    /// 패널 금액을 허용 범위로 (최소 폭 ~ 올인). 최소 폭만큼 없으면 올인만
    func clampRaise(_ amount: Int64, _ o: IPOptions) -> Int64 {
        if o.raiseIsAllInOnly { return o.allInAmount }
        return min(max(amount, o.minRaise), o.allInAmount)
    }

    func confirmRaise(at now: Date) async {
        guard let o = options(at: now) else { raising = false; return }
        await act(o.opened ? .raise : .bet, amount: clampRaise(raiseAmount, o))
    }

    // MARK: - 메뉴바 깜빡임

    /// 내 차례인데 팝오버가 닫혀 있으면 0.3초마다 깜빡인다 (동작 줄이기면 켠 채로). 차례가 끝나거나 팝오버를 열면 멈춘다
    func updateFlash() {
        let should = seated && !(store?.viewing ?? false) && myTurn(at: .now)
        guard should != (flashTask != nil) else { return }
        flashTask?.cancel()
        flashTask = nil
        flash = false
        guard should else { return }
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        flashTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.myTurn(at: .now), !(self.store?.viewing ?? false) {
                self.flash = still || !self.flash
                try? await Task.sleep(for: .seconds(0.3))
            }
            self?.flash = false
            self?.flashTask = nil
        }
    }

    // MARK: - Preview

    /// 스냅샷: 서버 없이 상태를 넣는다
    func preview(lobby: IPLobby? = nil, state: IPState? = nil, alert: Alert? = nil, message: String? = nil,
                 leftNotice: IPMe.LeftReason? = nil, raising: Int64? = nil, leaving attempts: Int? = nil) {
        if let attempts, let state {
            leaving = state.table.id
            leaveAttempts = attempts
        }
        if let lobby { self.lobby = lobby }
        if let state {
            tableID = state.me.member ? state.table.id : nil
            self.state = state
        }
        self.alert = alert
        self.message = message
        self.leftNotice = leftNotice
        if let raising {
            raiseAmount = raising
            self.raising = true
        }
    }
}
