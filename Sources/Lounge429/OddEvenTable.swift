import Foundation
import LoungeNet
import Observation

/// 구슬 홀짝 테이블 상태. 서버 tick 루프 + Realtime 이벤트로 갱신.
@MainActor @Observable
final class OddEvenTable {
    enum Phase {
        case connecting
        case betting(remaining: TimeInterval)
        case settling
        /// 직전 판 결과 연출 중. elapsed: 마감 후 경과 시간
        case reveal(Round, elapsed: TimeInterval, nextIn: TimeInterval)
        case waiting(nextIn: TimeInterval)
    }

    let room: String
    private(set) var round: Round?
    private(set) var bets: [Bet] = []
    private(set) var last: Round?
    private(set) var lastBets: [Bet] = []
    private(set) var seats: [Seat] = []
    private(set) var names: [UUID: String] = [:]
    private(set) var message: String?
    private(set) var placing = false
    var stake: Int64 = 50
    /// 황금 칩(공짜 100칩)으로 걸기
    var useGolden = false


    private let store: LoungeStore
    private var tasks: [Task<Void, Never>] = []

    init(store: LoungeStore, room: String = "LOUNGE") {
        self.store = store
        self.room = room
    }

    var myID: UUID? { store.me?.id }
    var myBet: Bet? { bets.first { $0.playerId == myID } }

    func phase(at now: Date) -> Phase {
        guard let r = round else { return .connecting }
        if now >= r.closesAt { return .settling }
        if now >= r.opensAt { return .betting(remaining: r.closesAt.timeIntervalSince(now)) }
        if let l = last, l.marbles != nil {
            return .reveal(l, elapsed: now.timeIntervalSince(l.closesAt), nextIn: r.opensAt.timeIntervalSince(now))
        }
        return .waiting(nextIn: r.opensAt.timeIntervalSince(now))
    }

    func name(_ id: UUID) -> String { names[id] ?? "?" }

    // MARK: - Lifecycle

    func enter() {
        guard tasks.isEmpty, let me = store.me else { return }
        names[me.id] = me.name
        let events = store.net.tableEvents(room: room, seat: Seat(id: me.id, name: me.name))
        tasks = [
            Task { [weak self] in await self?.loop() },
            Task { [weak self] in
                for await event in events { self?.handle(event) }
            },
        ]
    }

    func leave() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    func place(_ side: Side) async {
        guard !placing else { return }
        placing = true
        defer { placing = false }
        do {
            let golden = useGolden && store.golden() > 0
            let bet = try await store.net.bet(room: room, side: side, amount: golden ? 100 : stake, golden: golden)
            if store.golden() <= 1 { useGolden = false }
            upsert(bet)
            message = nil
            await store.refreshMe()
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: - Sync

    /// 서버 tick: 마감된 판은 이때 정산되고 다음 판이 열린다. 모든 클라이언트가 부르지만 서버가 직렬화.
    private func loop() async {
        while !Task.isCancelled {
            var wake: TimeInterval = 2
            do {
                let r = try await store.net.tick(room: room)
                try await sync(r)
                let target = Date() < r.opensAt ? r.opensAt : r.closesAt.addingTimeInterval(0.2)
                wake = min(5, max(0.3, target.timeIntervalSinceNow))
                if message == "연결이 끊겼어요" { message = nil }
            } catch {
                if Task.isCancelled { return }
                message = "연결이 끊겼어요"
            }
            try? await Task.sleep(for: .seconds(wake))
        }
    }

    private func sync(_ r: Round) async throws {
        guard r.id != round?.id else { round = r; return }
        round = r
        bets = try await store.net.bets(roundID: r.id)
        if let settled = try await store.net.lastSettled(room: room), settled.id != last?.id || lastBets.isEmpty {
            last = settled
            lastBets = try await store.net.bets(roundID: settled.id)
        }
        await resolveNames()
        await store.refreshMe()
    }

    private func handle(_ event: TableEvent) {
        if ProcessInfo.processInfo.environment["LOUNGE_DEBUG"] != nil { print("[realtime] \(event)") }
        switch event {
        case .round(let r):
            if r.id == round?.id { round = r }
            if r.marbles != nil, r.id != last?.id, r.id >= (last?.id ?? 0) {
                last = r
                lastBets = bets.filter { $0.roundId == r.id }
            }
        case .bet(let b):
            upsert(b)
            if names[b.playerId] == nil { Task { await resolveNames() } }
        case .player(let p):
            names[p.id] = p.name
            store.update(p)
        case .seats(let s):
            seats = s
            for seat in s { names[seat.id] = seat.name }
        }
    }

    private func upsert(_ b: Bet) {
        func put(_ list: inout [Bet]) {
            if let i = list.firstIndex(where: { $0.playerId == b.playerId }) { list[i] = b } else { list.append(b) }
        }
        if b.roundId == round?.id { put(&bets) }
        if b.roundId == last?.id { put(&lastBets) }
    }

    private func resolveNames() async {
        let missing = Set((bets + lastBets).map(\.playerId)).filter { names[$0] == nil }
        guard !missing.isEmpty, let players = try? await store.net.players(Array(missing)) else { return }
        for p in players { names[p.id] = p.name }
    }

    // MARK: - Preview

    func preview(round: Round, bets: [Bet], last: Round?, lastBets: [Bet], seats: [Seat]) {
        self.round = round
        self.bets = bets
        self.last = last
        self.lastBets = lastBets
        self.seats = seats
        for s in seats { names[s.id] = s.name }
    }
}
