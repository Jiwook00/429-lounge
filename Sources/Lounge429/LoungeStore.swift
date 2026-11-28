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
    private(set) var claimingDailyChips = false
    /// 라운지 벽화 버킷 (ADR-0017). 벽을 한 번 열기 전엔 nil → 타일은 "FREE"
    var pixelBucket: PixelBucket?

    private static let dailyChipsCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }()
    private static let dailyChipsDate = Date.ISO8601FormatStyle(timeZone: dailyChipsCalendar.timeZone)
        .year().month().day().dateSeparator(.dash)

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
                Task { await poker.refreshLobby() }
            }
            poker.updateFlash()
        }
    }
    /// 블랙잭 테이블에 앉은 회원 수 (AI 제외, ADR-0014). 라운지 타일에 N/4로
    private(set) var blackjackSeated = 0
    /// 인디언 포커 (ADR-0023). 앉아 있는 동안은 팝오버를 닫아도 tick을 이어 가서 여기서 들고 있는다
    let poker = IndianPokerTable()
    /// 보고 있는 화면
    var place: Member.Place = .lounge { didSet { pushPresence() } }
    private var link: LoungeLink?
    private var pushed: Member?
    /// 429 드롭에서 공이 떠 있는 동안 내 전광판 이벤트를 숨긴다 (공이 닿기 전에 결과가 먼저 뜨지 않게)
    private var holdOwnDrops = false
    private var heldEvents: [LoungeEvent] = []

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
        poker.store = self
        guard live else { return }
        IndianPokerTable.current = poker
        Task {
            await connect()
            await poll()
        }
        #if LOUNGE_DEV
        // 개발용 빌드만: LOUNGE_POKER_WINDOW=1이면 포커 화면을 일반 창에 (환경변수가 없으면 아무것도 안 함)
        if PokerDevWindow.enabled { Task { PokerDevWindow.open(store: self) } }
        #endif
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

    var dailyChipsAvailableAt: Date? {
        guard let me else { return nil }
        guard let day = me.lastDaily, let receivedAt = try? Self.dailyChipsDate.parse(day) else { return .distantPast }
        return Self.dailyChipsCalendar.date(byAdding: .day, value: 1, to: receivedAt)
    }

    private(set) var latestTicket: LuckyTicket?
    private(set) var ticketsLoaded = false
    private(set) var scratching = false
    var ticketError: String?
    private var acknowledgedTicket: Date? {
        didSet {
            if let id = me?.id { UserDefaults.standard.set(acknowledgedTicket, forKey: "ticketSeen-\(id)") }
        }
    }

    var ticketResult: LuckyTicket? {
        guard let latestTicket, acknowledgedTicket != latestTicket.claimedAt else { return nil }
        return latestTicket
    }

    func acknowledgeTicket() { acknowledgedTicket = latestTicket?.claimedAt }

    func ticketCount(at now: Date) -> Int {
        guard latestTicket?.day == Self.dailyChipsDate.format(now) else { return 0 }
        return latestTicket?.number ?? 0
    }

    func ticketAvailable(at now: Date) -> Bool {
        guard ticketsLoaded, me != nil else { return false }
        let count = ticketCount(at: now)
        return count == 0 || (count < 3 && now >= (latestTicket?.claimedAt ?? .distantPast).addingTimeInterval(7200))
    }

    func ticketLabel(at now: Date) -> String {
        if ticketResult != nil { return "티켓 결과 보기 ›" }
        if ticketAvailable(at: now) { return "티켓 긁기 ›" }
        if ticketCount(at: now) >= 3 { return "오늘 3장 완료" }
        guard ticketsLoaded, let latestTicket else { return "티켓 확인 중" }
        let time = latestTicket.claimedAt.addingTimeInterval(7200)
        return "다음 티켓 " + time.formatted(date: .omitted, time: .shortened)
    }

    func loadTicket() async {
        guard let id = me?.id else { return }
        do {
            let ticket = try await net.latestTicket()
            guard me?.id == id else { return }
            if (ticket?.claimedAt ?? .distantPast) >= (latestTicket?.claimedAt ?? .distantPast) { latestTicket = ticket }
            ticketsLoaded = true
        } catch { }
    }

    func scratch() async {
        let now = Date.now
        guard !scratching, ticketResult == nil, ticketAvailable(at: now) else { return }
        scratching = true
        ticketError = nil
        defer { scratching = false }
        do {
            let result = try await net.scratchTicket(day: Self.dailyChipsDate.format(now), number: ticketCount(at: now) + 1)
            update(result.player)
            latestTicket = result.ticket
            GameAudio.shared.play(.collect, at: .now)
        } catch {
            await loadTicket()
            await refreshMe()
            if ticketResult == nil { ticketError = "티켓을 확인하지 못했어요. 다시 시도해 주세요." }
        }
    }

    func claimDailyChips() async {
        guard !claimingDailyChips, let dailyChipsAvailableAt, dailyChipsAvailableAt <= .now else { return }
        claimingDailyChips = true
        defer { claimingDailyChips = false }
        do {
            let grant = try await net.dailyBonus()
            apply(grant, "오늘의 칩 +\(grant.granted.formatted(.number))칩")
        } catch {
            showToast("오늘의 칩을 못 받았어요 · 다시 시도해 주세요")
        }
    }

    func refresh() async {
        let scanner = self.scanner
        var s = await Task.detached(priority: .utility) { scanner.scan() }.value
        if let fake = Self.fakeLock { s.lastLimitHit = fake }
        snapshot = s
        lastScan = .now
        await claim()
        pushPresence()
        await keepRoster()
        await loadTicket()
        await countBlackjack()
    }

    func countBlackjack() async {
        guard me != nil, let n = try? await net.bjSeated(room: "LOUNGE") else { return }
        blackjackSeated = n
    }

    /// 마지막으로 본 시각은 2분마다, 명부는 3분마다 (새 회원이 라운지에 들어오면 바로)
    private func keepRoster(at now: Date = .now) async {
        guard me != nil else { return }
        if seenAt.map({ now.timeIntervalSince($0) >= 120 }) ?? true {
            if (try? await net.touchSeen(appVersion: AppInfo.version)) != nil { seenAt = now }
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
            let player = try await net.signIn()
            if me?.id == player.id { update(player) } else { me = player }
            netError = nil
        } catch {
            netError = "라운지 서버에 연결할 수 없어요"
            return
        }
        if let id = me?.id {
            acknowledgedTicket = UserDefaults.standard.object(forKey: "ticketSeen-\(id)") as? Date
        }
        await loadTicket()
        joinLounge()
        await keepRoster()
        await claim()
        // 앉아 있던 포커 테이블이 있으면 다시 tick (앱을 다시 켰을 때)
        await poker.resume()
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
        update(grant.player)
        guard grant.granted > 0 else { return }
        showToast(message, golden: golden)
    }

    /// 게임 화면이 못 보여 준 결과를 라운지 알림으로 (429 드롭 FEVER를 보기 전에 나갔을 때)
    func announce(_ message: String, golden: Bool = false) { showToast(message, golden: golden) }

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
            update(try await net.setNickname(name))
            pushPresence()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshMe() async {
        guard me != nil, let fresh = try? await net.me() else { return }
        update(fresh)
    }

    func update(_ player: Player) {
        guard let me, player.id == me.id else { return }
        // 먼저 보낸 지갑 요청이 늦게 와도 오늘의 칩 수령 기록은 되돌리지 않는다.
        guard (player.lastDaily ?? "") >= (me.lastDaily ?? "") else { return }
        self.me = player
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
                    if holdOwnDrops, e.game == "plinko", e.name == me?.name {
                        heldEvents.append(e)
                    } else {
                        addEvents([e])
                        celebrate(e)
                    }
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

    /// 429 드롭: 공이 떠 있는 동안 켜 두고, 다 닿으면 끈다. 끄면 숨겼던 내 이벤트가 전광판에 오른다
    func holdDropEvents(_ hold: Bool) {
        guard hold != holdOwnDrops else { return }
        holdOwnDrops = hold
        guard !hold, !heldEvents.isEmpty else { return }
        addEvents(heldEvents)
        heldEvents = []
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
