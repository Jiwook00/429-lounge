import Foundation
import LoungeNet
import Observation

/// 효과음 신호. 테이블이 틱마다 내보내고, 소리는 `GameAudio`가 낸다
enum PlinkoSound: Equatable {
    case launch, good, perfect
    case pin(row: Int, x: Int), gold(x: Int), split
    case lose(x: Int), win(mult: Double, x: Int), big, max
    case pocket, reelTick, reelStop, reach, fever, refund, letter
    case chargeStart, chargeLevel(Int), chargeStop
}

/// 화면 색 이름 (뷰가 `Theme` 토큰으로 바꾼다)
enum PlinkoTone: Equatable {
    case cream, gold, goldLight, neon, cyan, muted, dim, green
}

/// 핀 좌표: 줄 r, 칸 j (x = 가운데 + j × 11pt)
struct PinPos: Hashable {
    let r: Int
    let j: Int
}

/// 429 드롭 테이블 (ADR-0018, ADR-0019). 서버가 정한 경로를 60ms 틱(칸마다 3틱)으로 재생한다.
/// 결과와 지갑은 서버가 정하고, 화면의 지갑·지급 표시·전광판은 공이 칸에 닿을 때 반영한다.
@MainActor @Observable
final class PlinkoTable {
    // MARK: 보드 기하 (pt). 팝오버 폭 340 안에 들어가는 308 × 249 안쪽 영역
    static let width = 308
    static let height = 249
    static let cx = 154
    /// 핀 가로 간격 (같은 줄 이웃 핀 사이). x = cx + j × 11
    static let hStep = 22
    static let vStep = 17
    static let top = 30
    static let bucketY = top + 11 * vStep + 12
    static let maxBalls = 5
    static let stakes: [Int64] = [10, 50, 100, 200]
    static let multipliers: [Double] = [16, 5, 2, 1.4, 0.8, 0.5, 0.3, 0.5, 0.8, 1.4, 2, 5, 16]
    static let bucketLabels = ["16", "5", "2", "1.4", ".8", ".5", ".3", ".5", ".8", "1.4", "2", "5", "16"]
    /// FEVER 공은 배수 ×1.5 (서버 `plinko_path`와 같다)
    static let feverMult = 1.5
    static let feverLabels = ["24", "7.5", "3", "2.1", "1.2", ".75", ".45", ".75", "1.2", "2.1", "3", "7.5", "24"]
    /// 4·2·9 = 보드 레벨 (ADR-0019). FEVER가 아닌 포켓마다 한 글자 켜지며 핀이 늘고, 셋 다 켜지면 HOT(다음 포켓까지)
    static let letterChars = ["4", "2", "9"]

    /// 지금 단계(켜진 글자 수)에서 다음에 무엇이 일어나는지 한 줄. 4·2·9 줄 옆에 늘 보인다
    static func stageHint(level: Int) -> String {
        switch level {
        case 0: "포켓 → 4"
        case 1: "포켓 → 2"
        case 2: "포켓 → 9"
        default: "포켓 끝"
        }
    }

    /// 글자가 켜질 때 새로 생기는 것을 알리는 짧은 문구 (레인 화살표 앞에서 끝나야 해서 짧게)
    static func stageGain(level: Int) -> String {
        switch level {
        case 1: "골드"
        case 2: "분열"
        default: "HOT"
        }
    }
    /// 레벨마다 새로 생기는 핀 (서버 `plinko_gold`·`plinko_split`과 같다). 앞 레벨 핀에 더해진다
    static let goldByLevel: [Set<PinPos>] = [
        [PinPos(r: 8, j: -4), PinPos(r: 8, j: 4)],
        [PinPos(r: 6, j: -6), PinPos(r: 6, j: 6)],
        [],
        [PinPos(r: 9, j: -5), PinPos(r: 9, j: 5), PinPos(r: 7, j: -3), PinPos(r: 7, j: 3)],
    ]
    static let splitByLevel: [Set<PinPos>] = [
        [PinPos(r: 10, j: -8), PinPos(r: 10, j: 8)],
        [],
        [PinPos(r: 9, j: -7), PinPos(r: 9, j: 7)],
        [],
    ]
    static func goldPins(level: Int) -> Set<PinPos> { goldByLevel.prefix(level + 1).reduce([]) { $0.union($1) } }
    static func splitPins(level: Int) -> Set<PinPos> { splitByLevel.prefix(level + 1).reduce([]) { $0.union($1) } }
    static let pocketPin = PinPos(r: 6, j: 0)
    static let reelSymbols = ["429", "7", "BAR", "200", "404"]
    static let tickInterval = Duration.milliseconds(60)

    static func x(_ j: Int) -> Int { cx + j * hStep / 2 }
    static func y(_ r: Int) -> Int { top + r * vStep }

    // MARK: 화면 상태
    var stake: Int64 = 50
    var useGolden = false
    var lane = 0
    var auto = false {
        didSet { if auto { lastAutoAt = .now } }
    }
    private(set) var message: String?
    private(set) var tick = 0
    private(set) var balls: [SimBall] = []
    private(set) var pinFlash: [PinPos: Flash] = [:]
    private(set) var bucketFlash: [Int: BucketFlash] = [:]
    private(set) var pops: [Pop] = []
    private(set) var coins: [Coin] = []
    private(set) var banner: Banner?
    private(set) var beam: Beam?
    private(set) var reel: Reel?
    private(set) var fever: FeverRun?
    /// 화면의 4·2·9 글자 수 = 보드 레벨 (0~3). 서버 값은 응답에 먼저 오지만 포켓 릴이 멈출 때 켠다
    private(set) var letters = 0
    /// 방금 켜진 글자 (반짝임용): 몇 번째 글자, 언제까지
    private(set) var letterFlash: (index: Int, until: Int)?
    /// VIP HOUR (황금 칩 유효 시간): 포켓 입구가 넓다. 뷰가 넣어 준다
    var vip = false
    /// 이 화면에 들어온 뒤 순이익 (건 칩을 뺀 값). 화면에는 안 보인다 (손익을 띄우면 그만두게 돼서 뺐다). `--table plinko-live` 확인용
    private(set) var sessionNet: Int64 = 0
    private(set) var streak = 0
    var charging = false
    /// 누른 이벤트의 시각 (뗀 이벤트 시각과 비교해 보낼 파워를 정한다)
    private(set) var pressedAt: Date?
    /// 누른 순간의 지금 시계 (게이지 그리기용). 이벤트 시각은 시계 기준이 달라 화면 시각과 바로 비교하면 안 된다
    @ObservationIgnored private var pressedWall: Date?
    private(set) var lastPower = 500
    private(set) var gradeShown: PlinkoDrop.Grade = .none
    private(set) var gradeUntil = -1
    private(set) var perfectUntil = -1
    private var shakeUntil = -1
    /// 스냅샷용: 눌러서 모으는 중인 파워를 고정
    var fixedPower: Int?
    /// 동작 줄이기: 흔들림·배경 점멸 끔
    var reduced = false

    struct SimBall: Identifiable {
        let id: Int
        let drop: Int
        /// 지나는 핀 (옆 레인이면 첫 칸이 가이드 핀)
        let stops: [PinPos]
        let originX: Int
        let originY: Int
        let fromTop: Bool
        let source: PlinkoBall
        let fever: Bool
        let grade: PlinkoDrop.Grade
        /// 서버가 이 공에 쓴 보드 레벨 (FEVER 공은 0)
        let level: Int
        var seg = 0
        var sub = 0
        var trail: [(x: Int, y: Int)] = []
        var goldHits = 0
        var split = false
        var done = false
        var isPocket: Bool { source.pocket }
        var golden: Bool { goldHits > 0 || fever }
        /// 지금 어느 줄에 있나 (포켓 열림 판정)
        var row: Int { stops[min(max(seg - 1, 0), stops.count - 1)].r }
    }

    struct Flash { let until: Int; let tone: PlinkoTone }
    struct BucketFlash { let until: Int; let tier: Tier }
    struct Pop: Identifiable { let id: Int; let x: Int; let y: Int; let text: String; let tone: PlinkoTone; let born: Int }
    struct Coin: Identifiable { let id: Int; var x: Double; var y: Double; var vx: Double; var vy: Double; let born: Int }
    struct Banner { let kind: Kind; let until: Int; let big: String; let sub: String; enum Kind { case big, max, fever, feverEnd } }
    struct Beam { let x: Int; let until: Int }
    struct Reel {
        let start: Int
        let result: [String]
        let stops: [Int]
        let fever: Bool
        let reach: Bool
        let drop: Int
        var doneAt: Int?
        /// HOT 보드가 이 포켓으로 끝났다 (FEVER가 아니고 글자가 0으로)
        var hotEnd = false
        /// 이 포켓 뒤 글자 수 (1~3). 릴 제목에 "4 켜짐"처럼 어느 글자가 켜졌는지 쓴다
        var letter = 0
    }
    struct FeverRun {
        var total: Int64 = 0
        var spawned = 0
        let n: Int
        var next: Int
        let drop: Int
        var endAt: Int?
    }
    enum Tier: Equatable { case lose, win, big, max }

    /// 서버 응답 하나(공 하나)의 진행. 지갑에 아직 안 보인 지급액을 들고 있다
    private struct DropRec {
        let id: Int
        let response: PlinkoDrop
        var unlanded: Int64
        var liveBalls = 0
        var reelPending: Bool
        var feverPending: Bool
        var feverLeft: Int
        /// 이번 판 손익에서 건 칩을 이미 뺐나 (그 판의 첫 결과 때 한 번만)
        var charged = false
    }

    private struct Request {
        let amount: Int64
        let lane: Int
        let power: Int
        let golden: Bool
    }

    // MARK: 내부
    private let store: LoungeStore
    private var drops: [DropRec] = []
    private var queue: [Request] = []
    @ObservationIgnored private var pumping = false
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var driver: Task<Void, Never>?
    @ObservationIgnored private var lastAutoAt = Date.distantPast
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var reelQueue: [Int] = []
    @ObservationIgnored private var pinSounds = 0
    @ObservationIgnored private var rng: SplitMix

    /// 개발용 로그 (`--table plinko-live`가 착지·릴·FEVER를 줄로 찍는다)
    var log: ((String) -> Void)?

    /// 소리 신호를 받는 쪽 (뷰가 `GameAudio`에 연결)
    var onSound: ((PlinkoSound) -> Void)?

    init(store: LoungeStore, seed: UInt64? = nil) {
        self.store = store
        rng = SplitMix(seed: seed ?? UInt64.random(in: 1...UInt64.max))
    }

    // MARK: - 입력

    /// 칩 표시: 서버가 이미 반영한 지갑에서 아직 닿지 않은 지급액을 뺀다. 보낸 판의 건 칩은 바로 뺀다
    func shown(chips: Int) -> Int {
        let held = drops.reduce(Int64(0)) { $0 + $1.unlanded }
        let charge = queue.reduce(Int64(0)) { $0 + ($1.golden ? 0 : $1.amount) }
        return chips - Int(held) - Int(charge)
    }

    /// 떠 있는 공 수 (분열·FEVER 공은 한 판으로 센다). 최대 5
    var inFlight: Int { queue.count + drops.filter { $0.liveBalls > 0 || $0.reelPending }.count }
    var feverActive: Bool { fever != nil || drops.contains { $0.feverPending } }

    func blockReason(chips: Int, golden: Int) -> String? {
        if feverActive { return "FEVER 중 · 자동으로 쏟아져요" }
        if inFlight >= Self.maxBalls { return "공 5/5 · 잠깐만요" }
        let useG = useGolden && golden > 0
        if !useG, shown(chips: chips) < Int(stake) { return "칩이 모자라요" }
        return nil
    }

    func power(at now: Date) -> Int {
        if let fixedPower { return fixedPower }
        guard charging, let pressedWall else { return lastPower }
        return PlinkoGauge.power(held: now.timeIntervalSince(pressedWall))
    }

    /// 눌렀다. 시각은 이벤트 타임스탬프 (프레임이 아니라)
    func press(at time: Date) {
        guard !charging, !closed, blockReason(chips: store.chips, golden: store.golden()) == nil else { return }
        charging = true
        pressedAt = time
        pressedWall = .now
        message = nil
        onSound?(.chargeStart)
    }

    /// 뗐다. 누른 시각과 뗀 시각으로 파워를 정하고 던진다
    func release(at time: Date) {
        guard charging, let pressedAt else { return }
        // 두 이벤트 시각의 차이 (같은 시계). 어긋나 보이면(음수·지나치게 김) 화면 시계로 잰다
        var held = time.timeIntervalSince(pressedAt)
        if !(0...30).contains(held), let pressedWall { held = Date.now.timeIntervalSince(pressedWall) }
        let p = PlinkoGauge.power(held: held)
        charging = false
        self.pressedAt = nil
        pressedWall = nil
        onSound?(.chargeStop)
        submit(power: p)
    }

    /// 팝오버가 닫히는 등 뗌 없이 끝났을 때: 던지지 않고 취소
    func cancelCharge() {
        guard charging else { return }
        charging = false
        pressedAt = nil
        pressedWall = nil
        onSound?(.chargeStop)
    }

    private func submit(power p: Int) {
        let golden = useGolden && store.golden() > 0
        guard blockReason(chips: store.chips, golden: store.golden()) == nil else { return }
        let r = Request(amount: golden ? 100 : stake, lane: lane, power: p, golden: golden)
        lastPower = p
        queue.append(r)
        syncHold()
        onSound?(.launch)
        let grade = PlinkoGauge.grade(power: p)
        if grade != .none {
            gradeShown = grade
            gradeUntil = tick + 10
            if grade == .perfect { perfectUntil = tick + 10 }
            addPop(x: Self.x(2 * lane), y: 16, text: grade == .perfect ? "PERFECT" : "GOOD",
                   tone: grade == .perfect ? .gold : .cream)
            onSound?(grade == .perfect ? .perfect : .good)
        }
        if golden, store.golden() <= 1 { useGolden = false }
        Task { await pump() }
    }

    private func pump() async {
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }
        while let r = queue.first, !closed {
            do {
                let d = try await store.net.plinkoDrop(amount: r.amount, lane: r.lane, power: r.power, golden: r.golden)
                queue.removeFirst()
                receive(d)
            } catch {
                queue.removeAll()
                auto = false
                message = error.localizedDescription
                syncHold()
            }
        }
        if closed { queue.removeAll() }
        syncHold()
    }

    /// 응답이 왔다: 지갑은 서버 값으로 바꾸되 화면에는 공이 닿을 때까지 지급액을 뺀 값을 보여준다
    func receive(_ d: PlinkoDrop) {
        store.update(d.player)
        guard !closed else { return }
        let id = nextID
        nextID += 1
        let rec = DropRec(id: id, response: d, unlanded: d.payout, reelPending: false,
                          feverPending: d.fever, feverLeft: d.feverBalls.count)
        drops.append(rec)
        spawn(PlinkoBallSpawn(ball: d.ball, drop: id, fever: false, grade: d.grade, lane: d.lane, level: d.level))
        syncHold()
    }

    // MARK: - 공 만들기

    private struct PlinkoBallSpawn {
        let ball: PlinkoBall
        let drop: Int
        let fever: Bool
        let grade: PlinkoDrop.Grade
        /// 옆 레인이면 가이드 핀을 앞에 둔다 (nil이면 분열 공: 분열 핀에서 시작)
        let lane: Int?
        var level = 0
        var originPin: PinPos?
        /// FEVER 공 비: 출발점을 첫 핀 위에서 이만큼 옮긴다
        var rain: (dx: Int, dy: Int)? = nil
    }

    private func spawn(_ s: PlinkoBallSpawn) {
        var stops: [PinPos] = []
        if s.ball.from == 1, let lane = s.lane {
            stops.append(PinPos(r: 0, j: 2 * lane))
        }
        for (i, j) in s.ball.js.enumerated() { stops.append(PinPos(r: s.ball.from + i, j: j)) }
        guard let first = stops.first else { return }
        let originX: Int, originY: Int, fromTop: Bool
        if let origin = s.originPin {
            originX = Self.x(origin.j)
            originY = Self.y(origin.r) - 4
            fromTop = false
        } else {
            originX = Self.x(first.j) + (s.rain?.dx ?? 0)
            originY = s.rain?.dy ?? -4
            fromTop = true
        }
        let id = nextID
        nextID += 1
        balls.append(SimBall(id: id, drop: s.drop, stops: stops, originX: originX, originY: originY, fromTop: fromTop,
                             source: s.ball, fever: s.fever, grade: s.grade, level: s.fever ? 0 : s.level))
        if !s.fever, let i = drops.firstIndex(where: { $0.id == s.drop }) { drops[i].liveBalls += 1 }
    }

    /// 지금 위치 (pt). 칸마다 3틱: 핀 위 → 옆으로 튕김 → 다음 핀 쪽
    func position(of b: SimBall) -> (x: Int, y: Int) {
        let a: (x: Int, y: Int) = b.seg == 0 ? (b.originX, b.originY) : hitPoint(b.stops[b.seg - 1])
        if b.sub == 0 { return a }
        let end: (x: Int, y: Int)
        if b.seg >= b.stops.count {
            end = (Self.x(2 * (b.source.bucket ?? 6) - 12), Self.bucketY + 6)
        } else {
            end = hitPoint(b.stops[b.seg])
        }
        let dx = Double(end.x - a.x), dy = Double(end.y - a.y)
        if b.sub == 1 {
            return (Int((Double(a.x) + dx * 0.35).rounded()), Int((Double(a.y) + (b.seg == 0 && b.fromTop ? dy * 0.4 : -2)).rounded()))
        }
        return (Int((Double(a.x) + dx * 0.75).rounded()), Int((Double(a.y) + dy * 0.55).rounded()))
    }

    private func hitPoint(_ pin: PinPos) -> (x: Int, y: Int) { (Self.x(pin.j), Self.y(pin.r) - 4) }

    // MARK: - 틱

    func enter() {
        closed = false
        sessionNet = 0
        if drops.isEmpty, fever == nil { letters = store.me?.plinkoLetters ?? 0 }
        guard driver == nil else { return }
        // 정해진 시각마다 (sleep 길이만큼 기다리면 작업 시간만큼 틱이 조금씩 늘어진다). 많이 밀리면 몰아서 돌지 않고 다시 맞춘다
        driver = Task { [weak self] in
            let clock = ContinuousClock()
            var next = clock.now
            while !Task.isCancelled {
                next += Self.tickInterval
                if next < clock.now - Self.tickInterval { next = clock.now + Self.tickInterval }
                try? await Task.sleep(until: next, tolerance: .milliseconds(2), clock: clock)
                guard let self else { return }
                self.driverTick()
            }
        }
    }

    /// 팝오버가 닫혔다: 연출을 그대로 멈춰 두고, 다시 열면(`enter`) 이어서 재생한다.
    /// 접어 버리면 포켓으로 가던 공의 FEVER를 못 보고 4·2·9만 0이 된 것처럼 보인다
    func pause() {
        cancelCharge()
        auto = false
        driver?.cancel()
        driver = nil
    }

    /// 화면을 떠난다. 서버에 이미 간 판의 지갑은 `store`가 갖고 있으니 연출만 접는다.
    /// 아직 못 보여 준 FEVER가 있으면 라운지 알림으로 알린다
    func leave() {
        if !closed {
            let unseen = drops.filter { $0.response.fever && $0.feverPending }
            if !unseen.isEmpty {
                let total = unseen.reduce(Int64(0)) { $0 + $1.response.payout }
                store.announce("429 429 429 · FEVER +\(Self.fmt(total))칩", golden: true)
            }
        }
        closed = true
        cancelCharge()
        driver?.cancel()
        driver = nil
        balls = []
        drops = []
        reel = nil
        fever = nil
        reelQueue = []
        syncHold()
    }

    /// 개발용: 틱 간격 측정 (log가 있을 때만)
    @ObservationIgnored private var perfLast: Date?
    @ObservationIgnored private var perfGaps: [Double] = []

    private func perfMark() {
        guard let log else { return }
        let now = Date()
        if let last = perfLast { perfGaps.append(now.timeIntervalSince(last) * 1000) }
        perfLast = now
        if perfGaps.count >= 100 {
            let s = perfGaps.sorted()
            log(String(format: "perf 틱 간격 ms p50 %.1f p95 %.1f max %.1f", s[50], s[95], s[99]))
            perfGaps = []
        }
    }

    @ObservationIgnored private var perfWork: [Double] = []

    private func driverTick() {
        perfMark()
        let began = Date()
        defer {
            if log != nil {
                perfWork.append(Date().timeIntervalSince(began) * 1000)
                if perfWork.count >= 100 {
                    let s = perfWork.sorted()
                    log?(String(format: "perf 틱 작업 ms p50 %.2f p95 %.2f max %.2f", s[50], s[95], s[99]))
                    perfWork = []
                }
            }
        }
        if charging { onSound?(.chargeLevel(power(at: .now))) }
        if auto, !charging, Date().timeIntervalSince(lastAutoAt) >= 0.6 {
            lastAutoAt = .now
            if blockReason(chips: store.chips, golden: store.golden()) == nil {
                submit(power: Int.random(in: 0...1000, using: &rng))
            }
        }
        guard needsStep else { return }
        step()
    }

    private var needsStep: Bool {
        !balls.isEmpty || reel != nil || fever != nil || !pops.isEmpty || !coins.isEmpty || banner != nil || beam != nil
            || !pinFlash.isEmpty || !bucketFlash.isEmpty || shakeUntil >= tick || gradeUntil >= tick || perfectUntil >= tick
            || !reelQueue.isEmpty
    }

    /// 스냅샷용: 틱을 n번 돌린다
    func advance(_ n: Int) { for _ in 0..<n { step() } }

    /// 4·2·9가 다 켜진 HOT 보드 (다음 포켓까지)
    var hot: Bool { letters >= Self.letterChars.count && fever == nil }

    /// 그릴 보드 레벨: 화면의 글자와, 아직 날고 있는 공이 쓴 레벨 중 큰 것 (FEVER 중엔 기본 핀)
    var boardLevel: Int {
        let flying = balls.lazy.filter { !$0.fever && !$0.done }.map(\.level).max() ?? 0
        return max(fever == nil ? letters : 0, flying)
    }

    /// 스냅샷용: 이미 모은 글자 수
    func previewLetters(_ n: Int) { letters = n }

    private func step() {
        tick += 1
        let t = tick
        pinSounds = 0
        var born: [SimBall] = []
        var order: [Int] = []
        for i in balls.indices where !balls[i].done {
            let p = position(of: balls[i])
            balls[i].trail.insert(p, at: 0)
            if balls[i].trail.count > 3 { balls[i].trail.removeLast(balls[i].trail.count - 3) }
            balls[i].sub += 1
            if balls[i].sub > 2 {
                balls[i].sub = 0
                balls[i].seg += 1
                if balls[i].seg > balls[i].stops.count {
                    order.append(i)
                } else {
                    hit(ball: i, stopIndex: balls[i].seg - 1, born: &born)
                }
            }
        }
        for i in order { land(ball: i) }
        balls.removeAll { $0.done }
        balls.append(contentsOf: born)

        stepReel()
        stepFever()
        finishDrops()

        pinFlash = pinFlash.filter { $0.value.until >= t }
        bucketFlash = bucketFlash.filter { $0.value.until >= t }
        pops.removeAll { t - $0.born >= 14 }
        coins.removeAll { t - $0.born >= 16 }
        for i in coins.indices {
            coins[i].x += coins[i].vx
            coins[i].y += coins[i].vy
            coins[i].vy += 0.9
        }
        if let b = banner, b.until < t { banner = nil }
        if let b = beam, b.until < t { beam = nil }
    }

    // MARK: 핀에 닿음

    private func hit(ball i: Int, stopIndex: Int, born: inout [SimBall]) {
        let b = balls[i]
        let pin = b.stops[stopIndex]
        let p = hitPoint(pin)
        if b.isPocket, stopIndex == b.stops.count - 1 {
            balls[i].done = true
            if let d = drops.firstIndex(where: { $0.id == b.drop }) {
                drops[d].liveBalls -= 1
                drops[d].reelPending = true
                // 포켓에 잡힌 것도 그 판의 결과: 건 칩을 여기서 뺀다 (환급·FEVER는 나중에 더해진다)
                sessionNet -= chargeStake(d)
            }
            pinFlash[pin] = Flash(until: tick + 30, tone: .gold)
            addPop(x: p.x, y: p.y - 16, text: "POCKET!", tone: .gold)
            onSound?(.pocket)
            reelQueue.append(b.drop)
            startReelIfPossible()
            return
        }
        var tone: PlinkoTone = fever != nil ? .gold : .neon
        var plain = true
        if Self.goldPins(level: b.level).contains(pin) {
            balls[i].goldHits += 1
            tone = .goldLight
            plain = false
            addPop(x: p.x, y: p.y - 12, text: "+0.3", tone: .gold)
            onSound?(.gold(x: p.x))
        } else if Self.splitPins(level: b.level).contains(pin), !b.fever, !b.split, let clone = b.source.split == pin.r ? b.source.clone : nil {
            tone = .cyan
            plain = false
            balls[i].split = true
            addPop(x: p.x, y: p.y - 12, text: "SPLIT", tone: .cyan)
            onSound?(.split)
            let spawnBall = PlinkoBallSpawn(ball: clone, drop: b.drop, fever: false, grade: b.grade, lane: nil, originPin: pin)
            spawnLater(spawnBall, born: &born, splitFrom: b)
        }
        if plain, pinSounds < 4 {
            pinSounds += 1
            onSound?(.pin(row: pin.r, x: p.x))
        }
        pinFlash[pin] = Flash(until: tick + 4, tone: tone)
    }

    /// 분열 공은 같은 틱에 태어나서 다음 틱부터 움직인다
    private func spawnLater(_ s: PlinkoBallSpawn, born: inout [SimBall], splitFrom parent: SimBall) {
        var stops: [PinPos] = []
        for (i, j) in s.ball.js.enumerated() { stops.append(PinPos(r: s.ball.from + i, j: j)) }
        guard let pin = s.originPin, !stops.isEmpty else { return }
        var clone = SimBall(id: nextID, drop: s.drop, stops: stops, originX: Self.x(pin.j), originY: Self.y(pin.r) - 4,
                            fromTop: false, source: s.ball, fever: false, grade: s.grade, level: parent.level)
        clone.goldHits = parent.goldHits
        clone.split = true
        nextID += 1
        born.append(clone)
        if let d = drops.firstIndex(where: { $0.id == s.drop }) { drops[d].liveBalls += 1 }
    }

    // MARK: 칸에 닿음

    private func land(ball i: Int) {
        let b = balls[i]
        balls[i].done = true
        let t = tick
        guard let bucket = b.source.bucket else { return }
        let rec = drops.firstIndex(where: { $0.id == b.drop })
        let pay = b.source.payout
        let mult = b.source.mult
        let x = Self.x(2 * bucket - 12)
        // FEVER 공은 배수가 1.5배라 같은 칸이면 같은 등급이 되게 나눠서 본다
        let base = b.fever ? mult / Self.feverMult : mult
        let tier: Tier = base >= 16 ? .max : base >= 4 ? .big : base >= 1.1 ? .win : .lose
        // 순이익: 그 판의 첫 결과면 건 칩을 뺀다 (분열한 판은 먼저 닿은 공이, FEVER 공은 이미 낸 판이라 지급액 그대로)
        var gain = pay
        if !b.fever, let rec { gain -= chargeStake(rec) }
        sessionNet += gain
        if let rec {
            drops[rec].unlanded -= pay
            if !b.fever { drops[rec].liveBalls -= 1 }
        }
        log?("land 칸 \(bucket) ×\(Self.mt(mult)) 지급 \(pay)\(b.fever ? " (FEVER)" : "")\(b.source.gold > 0 ? " 골드 +\(Self.mt(b.source.gold))" : "") · 표시 칩 \(shown(chips: store.chips))")
        bucketFlash[bucket] = BucketFlash(until: t + 8, tier: tier)
        switch tier {
        case .max: onSound?(.max)
        case .big: onSound?(.big)
        case .win: onSound?(.win(mult: mult, x: x))
        case .lose: onSound?(.lose(x: x))
        }
        // FEVER 공 40개가 다 숫자를 띄우면 칸이 안 보인다: ×2 이상만
        if !b.fever || mult >= 2 {
            addPop(x: x, y: Self.bucketY - 12, text: Self.signed(gain),
                   tone: gain < 0 ? .neon : gain == 0 ? .dim : tier == .max ? .neon : tier == .big ? .gold : .green)
        }
        if b.fever {
            fever?.total += pay
        } else {
            streak = mult >= 1.1 ? streak + 1 : 0
        }
        if tier == .big || tier == .max {
            let isMax = tier == .max
            shake(isMax ? 14 : 8)
            burst(x: x, y: Self.bucketY, n: isMax ? 20 : 10)
            if fever == nil || isMax {
                banner = isMax
                    ? Banner(kind: .max, until: t + 36, big: "×" + Self.mt(mult), sub: "MAX DROP · +\(Self.fmt(gain))칩")
                    : Banner(kind: .big, until: t + 24, big: "×" + Self.mt(mult), sub: "BIG DROP · +\(Self.fmt(gain))칩")
            }
            if isMax { beam = Beam(x: x, until: t + 30) }
        }
    }

    // MARK: 스타트 포켓 릴

    private func startReelIfPossible() {
        guard reel == nil, fever == nil, let id = reelQueue.first,
              let rec = drops.first(where: { $0.id == id }), let pocket = rec.response.pocket else { return }
        reelQueue.removeFirst()
        let t = tick
        let reach = pocket.reach
        reel = Reel(start: t, result: pocket.reels,
                    stops: [t + 8, t + 14, t + (reach ? 34 : 22)],
                    fever: pocket.fever, reach: reach, drop: id, doneAt: nil,
                    hotEnd: !pocket.fever && rec.response.letters == 0, letter: rec.response.letters)
        log?("reel \(pocket.reels.joined(separator: " ")) \(pocket.fever ? "FEVER" : "환급 \(pocket.refund)")\(reach ? " 리치" : "")")
    }

    private func stepReel() {
        let t = tick
        if reel == nil { startReelIfPossible() }
        guard var r = reel else { return }
        if r.doneAt == nil {
            if r.stops.contains(t) { onSound?(.reelStop) } else if t % 2 == 0 { onSound?(.reelTick) }
            if r.reach, t >= r.stops[1], t < r.stops[2], (t - r.stops[1]) % 8 == 0 { onSound?(.reach) }
            if t >= r.stops[2] {
                r.doneAt = t
                reel = r
                finishReel(r)
                return
            }
        }
        if let done = r.doneAt, t > done + (r.fever ? 20 : 16) { reel = nil }
    }

    private func finishReel(_ r: Reel) {
        let t = tick
        guard let d = drops.firstIndex(where: { $0.id == r.drop }) else { return }
        drops[d].reelPending = false
        let pocket = drops[d].response.pocket
        if r.fever {
            let n = drops[d].response.feverBalls.count
            fever = FeverRun(n: n, next: t + 10, drop: r.drop)
            // 글자는 FEVER 줄로 옮겨 가 있다가 FEVER가 끝나면 하나씩 꺼지고 0부터 (보드는 FEVER 동안 기본 핀)
            letterFlash = nil
            banner = Banner(kind: .fever, until: t + 24, big: "429 429 429",
                            sub: "FEVER · 공 \(n)개 · ×1.5")
            shake(10)
            burst(x: Self.cx, y: Self.top + 6 * Self.vStep, n: 16)
            onSound?(.fever)
        } else {
            let refund = pocket?.refund ?? 0
            drops[d].unlanded -= refund
            sessionNet += refund
            if refund > 0 {
                addPop(x: Self.cx, y: Self.y(Self.pocketPin.r) - 16, text: "+" + Self.fmt(refund), tone: .green)
            }
            onSound?(.refund)
            let next = min(drops[d].response.letters, Self.letterChars.count)
            if next > letters {
                // 글자가 켜지고 그 레벨의 새 핀이 반짝이며 생긴다
                letterFlash = (next - 1, t + 20)
                for pin in Self.goldByLevel[next] { pinFlash[pin] = Flash(until: t + 24, tone: .goldLight) }
                for pin in Self.splitByLevel[next] { pinFlash[pin] = Flash(until: t + 24, tone: .cyan) }
                if next == Self.letterChars.count {
                    // HOT: 다음 포켓까지 보드가 달아오른다
                    shake(6)
                    onSound?(.reach)
                } else {
                    onSound?(.letter)
                }
            } else if next < letters {
                letterFlash = nil
            }
            letters = next
        }
    }

    // MARK: FEVER

    private func stepFever() {
        let t = tick
        guard var f = fever else { return }
        if f.endAt == nil {
            if f.spawned < f.n, t >= f.next, let d = drops.first(where: { $0.id == f.drop }) {
                let ball = d.response.feverBalls[f.spawned]
                // 서버는 FEVER 공의 레인을 따로 알리지 않는다. 첫 줄이 1이면 첫 핀 j(±1)가 곧 레인
                let lane = ball.from == 1 ? (ball.js.first ?? 0) : 0
                // 공 비: 위쪽 여기저기서 쏟아져 입구 핀으로 모인다
                let rain = (dx: Int.random(in: -40...40, using: &rng), dy: -Int.random(in: 4...24, using: &rng))
                spawn(PlinkoBallSpawn(ball: ball, drop: f.drop, fever: true, grade: .none, lane: lane, rain: rain))
                f.spawned += 1
                f.next = t + 2
                if let i = drops.firstIndex(where: { $0.id == f.drop }) { drops[i].feverLeft -= 1 }
            }
            if f.spawned >= f.n, !balls.contains(where: { $0.fever }) {
                f.endAt = t
                banner = Banner(kind: .feverEnd, until: t + 40, big: "+" + Self.fmt(f.total), sub: "FEVER 끝 · 공 \(f.n)개 합계")
                letterFlash = nil
                shake(12)
                burst(x: Self.cx, y: Self.bucketY, n: 24)
                onSound?(.max)
                if let i = drops.firstIndex(where: { $0.id == f.drop }) { drops[i].feverPending = false }
            }
        }
        if let end = f.endAt, t > end + 40 {
            fever = nil
            letters = 0
            startReelIfPossible()
        } else {
            fever = f
        }
    }

    /// 다 끝난 판을 치운다. 남은 지급액이 있으면(서버·연출 차이) 지갑에 그대로 보여준다
    private func finishDrops() {
        let before = drops.count
        drops.removeAll { $0.liveBalls <= 0 && !$0.reelPending && !$0.feverPending }
        if drops.count != before { syncHold() }
        if drops.isEmpty && queue.isEmpty { syncHold() }
    }

    private func syncHold() {
        store.holdDropEvents(!drops.isEmpty || !queue.isEmpty)
    }

    // MARK: 효과

    private func addPop(x: Int, y: Int, text: String, tone: PlinkoTone) {
        pops.append(Pop(id: nextID, x: x, y: y, text: text, tone: tone, born: tick))
        nextID += 1
    }

    private func burst(x: Int, y: Int, n: Int) {
        for _ in 0..<n {
            let vx = (Double.random(in: 0..<1, using: &rng) * 2 - 1) * 5
            let vy = -(3 + Double.random(in: 0..<1, using: &rng) * 5)
            coins.append(Coin(id: nextID, x: Double(x), y: Double(y), vx: vx, vy: vy, born: tick))
            nextID += 1
        }
    }

    private func shake(_ n: Int) {
        if !reduced { shakeUntil = max(shakeUntil, tick + n) }
    }

    /// 화면 흔들림 (pt). 4틱 주기
    var shakeOffset: (x: Int, y: Int) {
        guard tick <= shakeUntil else { return (0, 0) }
        return [(2, 0), (-2, 1), (1, -1), (-1, 0)][tick % 4]
    }

    /// 포켓이 열린 걸로 보여야 하나: VIP HOUR이거나 GOOD·PERFECT 공이 포켓 줄을 지나기 전
    var pocketOpen: Bool {
        vip || balls.contains { !$0.done && !$0.fever && $0.grade != .none && $0.row <= Self.pocketPin.r }
    }

    static func fmt(_ n: Int64) -> String { max(0, n).formatted(.number) }

    /// +15 / −20 / ±0 (빼기는 진짜 마이너스 기호)
    static func signed(_ n: Int64) -> String {
        n > 0 ? "+" + fmt(n) : n < 0 ? "−" + fmt(-n) : "±0"
    }

    /// 그 판의 건 칩을 이번 판 손익에서 한 번만 뺀다. 뺀 금액을 돌려준다 (황금 칩은 0)
    private func chargeStake(_ i: Int) -> Int64 {
        guard !drops[i].charged else { return 0 }
        drops[i].charged = true
        return drops[i].response.golden ? 0 : drops[i].response.amount
    }

    /// 소수 첫째 자리까지 (정수면 소수점 없이)
    static func mt(_ m: Double) -> String {
        let r = (m * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(r)
    }
}

/// 연출용 난수 (스냅샷에서 같은 그림이 나오게 시드를 줄 수 있다)
struct SplitMix: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
