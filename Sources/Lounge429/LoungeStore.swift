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

    // MARK: 라운지 접속 (ADR-0008)

    /// 지금 라운지에 있는 회원 (나 포함)
    private(set) var members: [Member] = []
    /// 전광판 이벤트 (최근 것만 유지)
    private(set) var events: [LoungeEvent] = []
    /// 팝오버를 열어 보고 있는지. RootView가 창 상태로 갱신한다.
    var viewing = false { didSet { pushPresence() } }
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
        if let lock = s.activeLock(), let g = try? await net.claimGolden(resetsAt: lock.resetsAt, type: lock.type) {
            apply(g, "429! 황금 칩 +\(g.granted)", golden: true)
        }
    }

    private func apply(_ grant: Grant, _ message: String, golden: Bool = false) {
        me = grant.player
        guard grant.granted > 0 else { return }
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
                case .event(let e): addEvents([e])
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

    /// 바뀐 게 있을 때만 다시 알린다
    private func pushPresence() {
        guard let link, let state = presenceState(), state != pushed else { return }
        pushed = state
        Task { await link.update(state) }
    }

    /// 라운지 화면에 그릴 접속 현황
    func crowd(at now: Date = .now) -> LoungeCrowd {
        // 내 상태는 서버 왕복을 기다리지 않고 지금 값으로
        var list = members.filter { $0.id != me?.id }
        if let mine = presenceState() { list.append(mine) }
        return LoungeCrowd(members: list, me: me?.id, events: events.filter { now.timeIntervalSince($0.createdAt) < Self.tickerWindow })
    }

    /// 메뉴바 점: 다른 회원이 홀짝 테이블에 앉아 있다
    var tableBusy: Bool { crowd().oddEven > 0 }

    /// 스냅샷/프리뷰용
    func preview(members: [Member], events: [LoungeEvent]) {
        self.members = members
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
    /// 홀짝 테이블에 앉아 있는 다른 회원
    let oddEven: Int
    /// 슬롯을 돌리고 있는 다른 회원
    let slot: Int
    let events: [LoungeEvent]

    static let empty = LoungeCrowd(members: [], me: nil, events: [])

    init(members: [Member], me: UUID?, events: [LoungeEvent]) {
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
        oddEven = others.filter { $0.viewing && $0.place == .oddeven }.count
        slot = others.filter { $0.viewing && $0.place == .slot }.count
        self.events = events
    }
}
