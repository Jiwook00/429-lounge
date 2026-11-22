import AppKit
import Foundation
import LoungeCore
import LoungeNet
import Observation

@MainActor @Observable
final class LoungeStore {
    struct Toast: Equatable {
        let text: String
        let golden: Bool
        let at: Date
    }

    private(set) var snapshot = UsageSnapshot()
    private(set) var lastScan: Date?
    /// 서버 지갑. 연결 전/오프라인이면 nil.
    private(set) var me: Player?
    private(set) var netError: String?
    /// 칩이 들어왔을 때 잠깐 보여주는 알림
    private(set) var toast: Toast?

    // MARK: 업데이트 (ADR-0010)

    /// GitHub 최신 릴리스
    private(set) var latestRelease: AppVersion?
    /// 서버가 요구하는 최소 버전
    private(set) var minVersion: AppVersion?
    /// 새 버전 안내. required면 테이블을 막는다
    var appUpdate: AppUpdate? {
        // 로컬 실행에서 업데이트 네온을 확인하는 명시적 미리보기 옵션.
        if ProcessInfo.processInfo.arguments.contains("--preview-update"),
           let current = AppVersion(AppInfo.version),
           let next = AppVersion("\(current.parts[0]).\(current.parts[1] + 1).0") {
            return AppUpdate.check(current: current, latest: next, minimum: nil)
        }
        return AppUpdate.check(current: AppVersion(AppInfo.version), latest: latestRelease, minimum: minVersion)
    }

    // MARK: 라운지 접속 (ADR-0008)

    /// 지금 라운지에 있는 회원 (나 포함)
    private(set) var members: [Member] = []
    /// 회원 명부: 접속 중이 아닌 회원도 보여주기 위해 (ADR-0011)
    private(set) var roster: [Regular] = []
    private var rosterAt: Date?
    private var seenAt: Date?
    /// 전광판 이벤트 (최근 것만 유지)
    private(set) var events: [LoungeEvent] = []
    /// 다른 회원이 잭팟을 터뜨리면 잠깐 켜졌다 꺼졌다 한다 → 메뉴바 아이콘이 VIP ↔ 평소로 깜빡임
    private(set) var jackpotFlash = false
    private var flashing: Task<Void, Never>?
    /// 잭팟 시스템 알림 (켜는 사람만)
    private(set) var notify = UserDefaults.standard.bool(forKey: "notifyJackpot") {
        didSet { UserDefaults.standard.set(notify, forKey: "notifyJackpot") }
    }
    /// 소수결 (ADR-0013). 30초마다 같이 부른다 → 정각이 지나면 누군가의 앱이 정산한다
    private(set) var minority: MinorityState?
    private(set) var minorityMessage: String?
    private(set) var minorityPicking = false
    /// 결과를 알린 마지막 판 (같은 결과를 두 번 알리지 않게)
    private var minorityNotified: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: "minorityNotified")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "minorityNotified") }
    }
    /// 결과 화면을 본 마지막 판. 이보다 새 판이 정산돼 있으면 소수결에 들어올 때 결과부터
    private(set) var minoritySeen = Int64(UserDefaults.standard.integer(forKey: "minoritySeen")) {
        didSet { UserDefaults.standard.set(Int(minoritySeen), forKey: "minoritySeen") }
    }
    /// 이번 주 큰손 (ADR-0012). 라운지 카드를 뒤집을 때 읽는다. 아직 못 읽었으면 nil
    private(set) var board: [BoardRow]?
    private var boardAt: Date?
    /// 지난주 내 순위. 기록이 없으면 nil (ADR-0012)
    private(set) var lastWeekRank: Int?
    private var lastWeekAt: Date?
    /// 팝오버를 열어 보고 있는지. RootView가 창 상태로 갱신한다.
    var viewing = false {
        didSet {
            pushPresence()
            if viewing && !oldValue {
                Task { await countBlackjack() }
                Task { await loadLastWeekRank() }
            }
        }
    }
    /// 블랙잭 테이블에 앉은 회원 수 (AI 제외, ADR-0014). 라운지 타일에 N/4로
    private(set) var blackjackSeated = 0
    /// 보고 있는 화면
    var place: Member.Place = .lounge { didSet { pushPresence() } }
    private var link: LoungeLink?
    private var pushed: Member?

    /// 전광판은 이벤트 후 이 시간 동안만 나타난다
    static let tickerWindow: TimeInterval = 180

    let net = LoungeClient()
    private let scanner = UsageScanner()

    /// 개발용: LOUNGE_FAKE_429=1 이면 가짜 429 상태. 실제 로그처럼 리셋 시각이 고정돼야
    /// 재실행해도 황금 칩이 중복 지급되지 않으므로 "2시간 뒤 정각"으로 맞춘다.
    private static let fakeLock: RateLimitHit? = {
        guard ProcessInfo.processInfo.environment["LOUNGE_FAKE_429"] != nil else { return nil }
        let hour: TimeInterval = 3600
        let reset = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 / hour).rounded(.down) * hour + 2 * hour)
        return RateLimitHit(hitAt: .now, resetsAt: reset, type: "five_hour")
    }()

    init(live: Bool = true) {
        guard live else { return }
        Task {
            await connect()
            await poll()
        }
        Task { await watchUpdates() }
    }

    /// 앱을 켤 때, 그 뒤로 30분마다 최신 릴리스와 최소 버전을 본다. 실패하면 이전 값을 둔다
    private func watchUpdates() async {
        while !Task.isCancelled {
            await checkUpdates()
            try? await Task.sleep(for: .seconds(30 * 60))
        }
    }

    func checkUpdates() async {
        async let latest = AppInfo.latestRelease()
        async let minimum = try? net.minClientVersion()
        if let v = await latest { latestRelease = v }
        if let v = await minimum.flatMap(AppVersion.init) { minVersion = v }
    }

    var chips: Int { Int(me?.chips ?? 0) }
    func golden(at now: Date = .now) -> Int { me?.golden(at: now) ?? 0 }

    func refresh() async {
        let scanner = self.scanner
        var s = await Task.detached(priority: .utility) { scanner.scan() }.value
        if let fake = Self.fakeLock { s.lastLimitHit = fake }
        snapshot = s
        lastScan = .now
        await claim()
        pushPresence()
        await keepRoster()
        await tickMinority()
        await countBlackjack()
    }

    func countBlackjack() async {
        guard me != nil, let n = try? await net.bjSeated(room: "LOUNGE") else { return }
        blackjackSeated = n
    }

    // MARK: - 소수결

    func tickMinority() async {
        guard me != nil, let state = try? await net.minorityTick() else { return }
        setMinority(state)
    }

    func pickMinority(_ choice: Int) async {
        guard !minorityPicking else { return }
        minorityPicking = true
        defer { minorityPicking = false }
        do {
            setMinority(try await net.minorityPick(choice))
            minorityMessage = nil
            await refreshMe()
        } catch {
            minorityMessage = error.localizedDescription
        }
    }

    /// 내가 참가한 판이 새로 정산됐으면 토스트 + (켰으면) 알림
    private func setMinority(_ state: MinorityState) {
        minority = state
        guard let m = state.mine, m.id > minorityNotified else { return }
        minorityNotified = m.id
        let text: String
        if let w = m.winnerLabel {
            text = m.net > 0 ? "\(w) 승 · 나 +\(m.net.formatted(.number))칩" : "\(w) 승 · 나 -\((-m.net).formatted(.number))칩"
        } else {
            text = "무효 · 200칩 돌려받았어요"
        }
        showToast("소수결 \(text)", golden: m.net > 0)
        if notify { Notifier.minority(text, question: m.question) }
        Task { await refreshMe() }
    }

    /// 아직 결과 화면을 안 본 내 판
    var minorityUnseen: MinorityResult? {
        guard let m = minority?.mine, m.id > minoritySeen else { return nil }
        return MinorityResult(question: m.question, options: (m.optionA, m.optionB),
                              picks: m.picks.map { .init(name: $0.name, choice: $0.choice, me: $0.me) },
                              winner: m.winner, net: m.net)
    }

    func ackMinorityResult() {
        if let m = minority?.mine { minoritySeen = m.id }
    }

    /// 로비 5번째 타일
    var minorityTile: MinorityTileState? {
        guard let m = minority else { return nil }
        if let r = m.round { return .open(closesAt: r.closesAt, picked: r.myPick != nil) }
        return m.nextOpensAt.map { .closed(nextOpensAt: $0) }
    }

    /// 소수결 화면에 그릴 값
    var minorityScreen: MinorityScreen {
        let r = minority?.round.map {
            MinorityScreen.Round(question: $0.question, options: ($0.optionA, $0.optionB), closesAt: $0.closesAt,
                                 participants: $0.participants, myPick: $0.myPick)
        }
        let mine = minority?.mine.map { MinorityScreen.Mine(question: $0.question, winner: $0.winnerLabel, net: $0.net) }
        return MinorityScreen(round: r, nextOpensAt: minority?.nextOpensAt, mine: mine)
    }

    /// 마지막으로 본 시각은 2분마다, 명부는 3분마다 (새 회원이 라운지에 들어오면 바로)
    private func keepRoster(at now: Date = .now) async {
        guard me != nil else { return }
        if seenAt.map({ now.timeIntervalSince($0) >= 120 }) ?? true {
            if (try? await net.touchSeen()) != nil { seenAt = now }
        }
        let known = Set(roster.map(\.id))
        let newcomer = members.contains { !known.contains($0.id) && $0.id != me?.id }
        if newcomer || rosterAt.map({ now.timeIntervalSince($0) >= 180 }) ?? true {
            if let list = try? await net.roster() {
                roster = list
                rosterAt = now
            }
        }
    }

    func connect() async {
        do {
            me = try await net.signIn()
            netError = nil
        } catch {
            netError = "라운지 서버에 연결할 수 없어요"
            return
        }
        joinLounge()
        await keepRoster()
        if let g = try? await net.dailyBonus() {
            apply(g, g.granted >= 300 ? "파산 구제 +\(g.granted)칩" : "출근 도장 +\(g.granted)칩")
        }
        await claim()
    }

    /// 로그에서 읽은 토큰/429를 서버에 보내서 칩으로 받는다 (서버가 차액만 지급하므로 자주 불러도 안전)
    private func claim() async {
        guard me != nil else { return }
        let s = snapshot
        if lastScan != nil, let g = try? await net.claimTokens(day: .now, fresh: s.today.fresh) {
            apply(g, "토큰 환전 +\(g.granted.formatted(.number))칩")
        }
        for lock in s.activeLocks() {
            if let g = try? await net.claimGolden(resetsAt: lock.resetsAt, type: lock.type) {
                apply(g, "429! 황금 칩 +\(g.granted)", golden: true)
            }
        }
    }

    private func apply(_ grant: Grant, _ message: String, golden: Bool = false) {
        me = grant.player
        guard grant.granted > 0 else { return }
        showToast(message, golden: golden)
    }

    private func showToast(_ message: String, golden: Bool = false) {
        let t = Toast(text: message, golden: golden, at: .now)
        toast = t
        Task {
            try? await Task.sleep(for: .seconds(5))
            if toast == t { toast = nil }
        }
    }

    /// 닉네임 저장. 실패하면 보여줄 문구
    func rename(_ name: String) async -> String? {
        do {
            me = try await net.setNickname(name)
            pushPresence()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshMe() async {
        guard me != nil, let fresh = try? await net.me() else { return }
        me = fresh
    }

    func update(_ player: Player) {
        if player.id == me?.id { me = player }
    }

    // MARK: - 라운지 접속

    /// 로그에서 계산한 대략적인 Claude 상태 (프로젝트, 토큰 양은 보내지 않는다)
    private func claudeStatus(at now: Date = .now) -> Member.Status? {
        guard lastScan != nil else { return nil } // 아직 로그를 안 읽었으면 모른다
        if snapshot.activeLock(at: now) != nil { return .vip }
        guard let last = snapshot.lastActivity else { return .resting }
        let idle = now.timeIntervalSince(last)
        if idle <= 5 * 60 { return .coding }
        if idle >= 30 * 60 { return .resting }
        return nil
    }

    private func presenceState() -> Member? {
        guard let me else { return nil }
        return Member(id: me.id, name: me.name, viewing: viewing, place: place, status: claudeStatus())
    }

    private func joinLounge() {
        guard link == nil, let state = presenceState() else { return }
        let link = net.joinLounge(as: state)
        self.link = link
        pushed = state
        Task {
            for await signal in link.signals {
                switch signal {
                case .members(let m): members = m
                case .event(let e):
                    addEvents([e])
                    celebrate(e)
                }
            }
            // 연결이 끊겼다 (구독 실패 등) → 잠시 뒤 다시
            if self.link === link {
                self.link = nil
                try? await Task.sleep(for: .seconds(15))
                joinLounge()
            }
        }
        Task {
            if let recent = try? await net.recentEvents(within: Self.tickerWindow) { addEvents(recent) }
        }
    }

    private func addEvents(_ new: [LoungeEvent]) {
        let cutoff = Date().addingTimeInterval(-Self.tickerWindow)
        var byID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        for e in new { byID[e.id] = e }
        events = byID.values.filter { $0.createdAt > cutoff }.sorted { $0.id < $1.id }
    }

    /// 다른 회원의 잭팟: 메뉴바 깜빡임 + (켰으면) 시스템 알림.
    /// Realtime으로 방금 들어온 것만. 앱을 켤 때 받아 오는 지난 이벤트로는 알리지 않는다
    private func celebrate(_ e: LoungeEvent) {
        guard e.kind == "jackpot", e.name != me?.name, Date().timeIntervalSince(e.createdAt) < 60 else { return }
        if notify { Notifier.jackpot(e) }
        flashing?.cancel()
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        flashing = Task {
            // 0.3초마다 바뀌며 5초. 동작 줄이기면 깜빡이지 않고 5초 동안 켜 둔다
            for i in 0..<(still ? 1 : 16) {
                jackpotFlash = still || i % 2 == 0
                try? await Task.sleep(for: .seconds(still ? 5 : 0.3))
                if Task.isCancelled { return }
            }
            jackpotFlash = false
        }
    }

    /// 바닥 줄 알림 켬/끔. 켤 때 권한을 묻고, 막혀 있으면 안내
    func toggleNotify() async {
        if notify { notify = false; return }
        if await Notifier.requestPermission() {
            notify = true
        } else {
            showToast("시스템 설정 > 알림에서 429 Lounge를 허용해 주세요")
        }
    }

    /// 바뀐 게 있을 때만 다시 알린다
    private func pushPresence() {
        guard let link, let state = presenceState(), state != pushed else { return }
        pushed = state
        Task { await link.update(state) }
    }

    /// 큰손 카드를 볼 때 부른다. 1분 안에 읽었으면 다시 안 읽는다
    func loadBoard(at now: Date = .now) async {
        guard me != nil, boardAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
        if let rows = try? await net.weeklyBoard() {
            board = rows
            boardAt = now
        }
    }

    /// 칩 화면의 "지난주 N위". 팝오버를 열 때 부르고 1분 안에 읽었으면 다시 안 읽는다
    func loadLastWeekRank(at now: Date = .now) async {
        guard me != nil, lastWeekAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
        if let rank = try? await net.lastWeekRank() {
            lastWeekRank = rank
            lastWeekAt = now
        }
    }

    /// 라운지 화면에 그릴 접속 현황
    func crowd(at now: Date = .now) -> LoungeCrowd {
        // 내 상태는 서버 왕복을 기다리지 않고 지금 값으로
        var list = members.filter { $0.id != me?.id }
        if let mine = presenceState() { list.append(mine) }
        return LoungeCrowd(members: list, roster: roster, me: me?.id, events: events.filter { now.timeIntervalSince($0.createdAt) < Self.tickerWindow })
    }

    /// 메뉴바 점: 다른 회원이 룰렛 테이블에 앉아 있다
    var tableBusy: Bool { crowd().roulette > 0 }
    /// 429에 걸려 리셋 전인지 (메뉴바 아이콘이 VIP로 바뀐다)
    var vip: Bool { snapshot.activeLock() != nil }

    /// 스냅샷/프리뷰용
    func preview(members: [Member], events: [LoungeEvent], roster: [Regular] = []) {
        self.members = members
        self.roster = roster
        self.events = events
    }

    /// 스냅샷/프리뷰용
    func preview(me: Player, snapshot: UsageSnapshot, toast: String? = nil) {
        self.me = me
        self.snapshot = snapshot
        self.toast = toast.map { Toast(text: $0, golden: snapshot.activeLock() != nil, at: .now) }
    }

    private func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(30))
        }
    }
}

/// 라운지 접속 현황 (화면용 값)
struct LoungeCrowd {
    /// 나를 뺀 회원. 보는 중 → 429 VIP → 코딩 중 → 표시 없음 → 쉬는 중 순
    let others: [Member]
    /// 나 포함 인원
    let total: Int
    /// 보는 중 (나 포함)
    let viewing: Int
    /// 나를 뺀 보는 중
    let othersViewing: Int
    /// 룰렛 테이블에 앉아 있는 다른 회원
    let roulette: Int
    /// 슬롯을 돌리고 있는 다른 회원
    let slot: Int
    /// 접속 중이 아닌 명부 회원 (나 빼고), 최근에 본 순
    let offline: [Regular]
    let events: [LoungeEvent]

    /// 라운지 전체 인원: 접속 중 + 오프라인
    var everyone: Int { total + offline.count }

    static let empty = LoungeCrowd(members: [], me: nil, events: [])

    init(members: [Member], roster: [Regular] = [], me: UUID?, events: [LoungeEvent]) {
        func rank(_ m: Member) -> Int {
            if m.viewing { return 0 }
            switch m.status {
            case .vip: return 1
            case .coding: return 2
            case nil: return 3
            case .resting: return 4
            }
        }
        let others = members.filter { $0.id != me }
        self.others = others.sorted { (rank($0), $0.name) < (rank($1), $1.name) }
        total = max(members.count, me == nil ? 0 : 1)
        viewing = members.filter(\.viewing).count
        othersViewing = others.filter(\.viewing).count
        roulette = others.filter { $0.viewing && $0.place == .roulette }.count
        slot = others.filter { $0.viewing && $0.place == .slot }.count
        let online = Set(members.map(\.id))
        offline = roster
            .filter { !online.contains($0.id) && $0.id != me }
            .sorted { ($0.lastSeenAt ?? .distantPast) > ($1.lastSeenAt ?? .distantPast) }
        self.events = events
    }
}
