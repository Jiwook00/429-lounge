import AppKit
import Foundation
import LoungeCore
import LoungeNet
import Observation

/// 인디언 포커 (ADR-0023). 서버에 상주 프로세스가 없어 앉은 앱이 `ip_tick`을 불러 시간 초과·컴퓨터 행동·다음 판을 진행한다.
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
    /// 서버 시각 − 로컬 시각
    private(set) var skew: TimeInterval = 0
    /// 메뉴바 깜빡임 (내 차례인데 포커 화면을 안 보고 있을 때)
    private(set) var flash = false
    /// 새 테이블 컴퓨터 수
    var bots = 2
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

    /// 지금 내 차례(버튼을 켤 때)인지. 딜 연출 2초와 마감 뒤엔 false
    func myTurn(at now: Date) -> Bool { state?.isMyTurn(at: server(now)) ?? false }
    func options(at now: Date) -> IPOptions? { state?.myOptions(at: server(now)) }

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
        guard let store, store.me != nil, let l = try? await store.net.ipLobby() else { return }
        applyLobby(l)
    }

    private func applyLobby(_ l: IPLobby) {
        lobby = l
        if tableID == nil, let mine = l.myTable {
            tableID = mine
            kick()
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
            if let id = tableID {
                listen(table: id)
                do {
                    apply(try await store.net.ipTick(table: id))
                    wake = nextWake()
                    if message == "연결이 끊겼어요" { message = nil }
                } catch {
                    message = "연결이 끊겼어요"
                    wake = 2
                }
            } else if watching {
                listen(table: 0)
                do {
                    applyLobby(try await store.net.ipLobby())
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

    func apply(_ s: IPState, at now: Date = .now) {
        skew = s.now.timeIntervalSince(now)
        let old = state
        let fresh = s.hand?.id != old?.hand?.id
        state = s

        if !s.me.member || s.table.status == .closed {
            detach(reason: s.me.member ? nil : s.me.leftReason)
            return
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
                if (mine.net ?? 0) > 0 { onSound?(.collect) } else if (mine.net ?? 0) == 0, !mine.folded { onSound?(.push) }
            }
            Task { await store?.refreshMe() }
        }
        updateFlash()
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
        tableID = nil
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
        await enter { try await $0.ipCreate(bots: self.bots) }
    }

    func join(_ table: Int64) async {
        await enter { try await $0.ipJoin(table: table) }
    }

    private func enter(_ call: @escaping @MainActor (LoungeClient) async throws -> IPState) async {
        guard let store, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let s = try await call(store.net)
            leftNotice = nil
            message = nil
            tableID = s.table.id
            state = nil
            apply(s)
            kick()
        } catch {
            message = error.localizedDescription
            await refreshLobby()
        }
        await store.refreshMe()
    }

    /// 일어나기. 진행 중인 판이면 폴드 (낸 칩은 판돈에 남음)
    func leave() async {
        guard let store, let id = tableID else { return }
        tableID = nil
        state = nil
        raising = false
        alert = nil
        listen(table: nil)
        updateFlash()
        _ = try? await store.net.ipLeave(table: id)
        await store.refreshMe()
        await refreshLobby()
    }

    /// 내 차례 행동. 판 ID·차례 번호를 같이 보내 지난 차례로 늦게 도착하면 서버가 거절한다 (그땐 새 상태만 조용히)
    func act(_ action: IPSeat.Action, amount: Int64? = nil) async {
        guard let store, let id = tableID, let h = hand, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let s = try await store.net.ipAction(table: id, hand: h.id, turn: h.turnNo, action, amount: amount)
            apply(s)
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

    /// 내 차례인데 포커 화면을 보고 있지 않으면 0.3초마다 깜빡인다 (동작 줄이기면 켠 채로). 차례가 끝나면 멈춘다
    func updateFlash() {
        let looking = watching && (store?.viewing ?? false)
        let should = seated && !looking && myTurn(at: .now)
        guard should != (flashTask != nil) else { return }
        flashTask?.cancel()
        flashTask = nil
        flash = false
        guard should else { return }
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        flashTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.myTurn(at: .now), !(self.watching && (self.store?.viewing ?? false)) {
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
                 leftNotice: IPMe.LeftReason? = nil, raising: Int64? = nil) {
        if let lobby { self.lobby = lobby }
        if let state {
            tableID = state.me.member ? state.table.id : nil
            self.state = state
            skew = 0
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
