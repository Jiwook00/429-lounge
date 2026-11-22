import Foundation
import LoungeNet
import Observation

/// 미니 룰렛 테이블 상태 (ADR-0015). 서버 tick 루프 + Realtime 신호로 갱신.
/// 칸을 누르면 바로 걸린다 (놓기·걸기를 나누지 않음). 결과는 마감 뒤 서버가 뽑고, 화면은 6초 동안 공을 굴린 뒤 보여준다.
@MainActor @Observable
final class RouletteTable {
    static let stakes: [Int64] = [10, 50, 100]

    enum Phase: Equatable {
        /// 판이 없거나 지난 판 연출이 끝남. 칩을 놓으면 새 판
        case idle
        case betting(left: TimeInterval)
        /// 마감 뒤 공이 도는 중. elapsed = 마감부터 지난 시간
        case spinning(elapsed: TimeInterval)
        case result(Int)
    }

    let room: String
    private(set) var state: RouletteState?
    private(set) var message: String?
    /// 마감 뒤에 걸려다 거절당한 때 (팝업 3초)
    private(set) var closedAt: Date?
    private(set) var busy = false
    private(set) var betAcceptedAt: Date?
    var stake: Int64 = 10
    var useGolden = false

    /// 서버 시각 - 로컬 시각
    private(set) var skew: TimeInterval = 0

    private let store: LoungeStore
    private var tasks: [Task<Void, Never>] = []
    private var nap: Task<Void, Never>?
    private var settledSeen: Int64?

    init(store: LoungeStore, room: String = "LOUNGE") {
        self.store = store
        self.room = room
    }

    var myID: UUID? { store.me?.id }
    var round: RouletteRound? { state?.round }
    var bets: [RouletteBet] { state?.bets ?? [] }
    var myBets: [RouletteBet] { bets.filter { $0.playerId == myID } }

    func local(_ server: Date) -> Date { server.addingTimeInterval(-skew) }

    func phase(at now: Date) -> Phase {
        guard let r = round, now < local(r.nextAt) else { return .idle }
        let closes = local(r.betClosesAt)
        if now < closes { return .betting(left: closes.timeIntervalSince(now)) }
        let e = now.timeIntervalSince(closes)
        if e < Roulette.spin || r.result == nil { return .spinning(elapsed: e) }
        return .result(r.result!)
    }

    /// 공이 마지막으로 멈춰 있던 칸 (대기·베팅 중 휠에 보이는 자리)
    var restingNumber: Int {
        round?.result ?? state?.lastResult ?? 0
    }

    /// "직전 판": 지금 판이 끝났으면 그 판, 아니면 그 앞 판
    func lastResult(at now: Date) -> Int? {
        if phase(at: now) == .idle, let r = round?.result { return r }
        return state?.lastResult
    }

    // MARK: - Lifecycle

    func enter() {
        guard tasks.isEmpty else { return }
        let changes = store.net.rouletteChanges(room: room)
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

    /// 칸에 칩을 놓는다. 황금 칩은 바깥 칸에만
    func bet(_ spot: Roulette.Spot) async {
        let golden = useGolden && store.golden() > 0 && spot.outside
        if useGolden && !spot.outside { message = LoungeError.server("golden_outside_only").errorDescription; return }
        await run {
            let s = try await self.store.net.rouletteBet(room: self.room, spot: spot, amount: golden ? 100 : self.stake, golden: golden)
            self.betAcceptedAt = .now
            if golden, self.store.golden() <= 1 { self.useGolden = false }
            return s
        }
        await store.refreshMe()
    }

    func spin() async {
        await run { try await self.store.net.rouletteSpin(room: self.room) }
    }

    private func run(_ call: @escaping @MainActor () async throws -> RouletteState) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            apply(try await call())
            message = nil
        } catch LoungeError.server("betting_closed") {
            closedAt = .now
            message = nil
            if let s = try? await store.net.rouletteTick(room: room) { apply(s) }
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: - Sync

    private func loop() async {
        while !Task.isCancelled {
            var wake: TimeInterval = 3
            do {
                apply(try await store.net.rouletteTick(room: room))
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

    /// 마감 직후(결과 받기), 결과 연출이 끝날 때 다시 tick
    private func nextWake(now: Date = .now) -> TimeInterval {
        guard let r = round else { return 5 }
        if r.result == nil, local(r.betClosesAt) <= now { return 0.3 }
        let marks = [local(r.betClosesAt), local(r.nextAt)].filter { $0 > now }
        guard let next = marks.min() else { return 5 }
        return min(3, max(0.25, next.timeIntervalSince(now) + 0.15))
    }

    func apply(_ s: RouletteState, at now: Date = .now) {
        skew = s.now.timeIntervalSince(now)
        state = s
        // 내 판이 정산되면 지갑 다시 읽기 (공이 멈춘 뒤에 바뀌게 결과 연출 시작 때)
        if let r = s.round, r.result != nil, settledSeen != r.id, !myBets.isEmpty {
            settledSeen = r.id
            let reveal = local(r.betClosesAt).addingTimeInterval(Roulette.spin)
            Task { [store] in
                let wait = reveal.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                await store.refreshMe()
            }
        }
    }

    // MARK: - 화면용 계산

    struct Mark: Equatable {
        /// 내가 건 칩 (일반)
        var mine: Int64 = 0
        /// 내가 건 황금 칩 개수
        var golden = 0
        /// 이 칸에 건 다른 회원 수
        var others = 0
    }

    func marks() -> [Roulette.Spot: Mark] {
        var out: [Roulette.Spot: Mark] = [:]
        var seen: [Roulette.Spot: Set<UUID>] = [:]
        for b in bets {
            var m = out[b.spot] ?? Mark()
            if b.playerId == myID {
                if b.golden { m.golden += Int(b.amount / 100) } else { m.mine += b.amount }
            } else if seen[b.spot, default: []].insert(b.playerId).inserted {
                m.others += 1
            }
            out[b.spot] = m
        }
        return out
    }

    struct Player: Equatable {
        let id: UUID
        let name: String
        let me: Bool
        let staked: Int64
        let golden: Int
        /// 정산 뒤 순수익
        let net: Int64?
    }

    /// 이번 판에 건 회원 (나 먼저, 그다음 건 칩 큰 순). settled가 false면 순수익을 비워 둔다 (회전 중)
    func players(settled show: Bool = true) -> [Player] {
        let grouped = Dictionary(grouping: bets, by: \.playerId)
        return grouped.map { id, list in
            let settled = list.allSatisfy { $0.payout != nil }
            let staked = list.reduce(0) { $0 + $1.staked }
            return Player(id: id, name: list[0].name, me: id == myID, staked: staked,
                          golden: list.filter(\.golden).reduce(0) { $0 + Int($1.amount / 100) },
                          net: settled && show ? list.reduce(0) { $0 + ($1.payout ?? 0) } - staked : nil)
        }
        .sorted { a, b in a.me != b.me ? a.me : a.staked != b.staked ? a.staked > b.staked : a.name < b.name }
    }

    var myStaked: Int64 { myBets.reduce(0) { $0 + $1.staked } }
    var myPayout: Int64? {
        let mine = myBets
        guard !mine.isEmpty, mine.allSatisfy({ $0.payout != nil }) else { return nil }
        return mine.reduce(0) { $0 + ($1.payout ?? 0) }
    }

    // MARK: - Preview

    func preview(closedAt: Date? = nil) {
        if let closedAt { self.closedAt = closedAt }
    }
}
