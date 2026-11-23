import Foundation
import LoungeNet
import Observation

/// 라운지 벽화 버킷 (ADR-0017). 서버 응답 시점의 개수에서 로컬 시각으로 충전을 계산한다
struct PixelBucket: Equatable {
    let left: Int
    /// 다음 픽셀이 차는 로컬 시각. 가득이면 nil
    let nextAt: Date?
    let cap: Int
    let refill: TimeInterval

    func left(at now: Date) -> Int {
        guard let next = nextAt, now >= next else { return left }
        return min(cap, left + 1 + Int(now.timeIntervalSince(next) / refill))
    }

    /// 다음 픽셀까지 남은 초. 가득이면 nil
    func untilNext(at now: Date) -> TimeInterval? {
        guard let next = nextAt, left(at: now) < cap else { return nil }
        if now < next { return next.timeIntervalSince(now) }
        return refill - now.timeIntervalSince(next).truncatingRemainder(dividingBy: refill)
    }

    /// 로비 타일 아랫줄
    func line(at now: Date) -> String {
        let n = left(at: now)
        if n > 0 { return "FREE · \(n)/\(cap)" }
        return "429 · \(Self.clock(untilNext(at: now) ?? 0))"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// 라운지 벽화 화면 상태. 이번 주 벽을 읽고, Realtime 신호가 오면 다시 읽는다.
/// 칩과 무관하다 (지갑·큰손에 안 들어감)
@MainActor @Observable
final class PixelWall {
    static let size = 32

    struct Cell: Hashable {
        let x: Int
        let y: Int
    }

    enum Response: Equatable {
        case idle
        case created(Cell)
        case same
        case limited
        case failed(String)
    }

    private(set) var state: PixelBoardState?
    /// 칸별 픽셀 (y * 32 + x)
    private(set) var pixels: [PixelBoardState.Pixel?] = Array(repeating: nil, count: size * size)
    private(set) var response: Response = .idle
    /// 마지막으로 칠한(누른) 칸
    private(set) var selected: Cell?
    var hover: Cell?
    var color = 1
    /// 서버 시각 - 로컬 시각
    private(set) var skew: TimeInterval = 0

    private let store: LoungeStore
    private var tasks: [Task<Void, Never>] = []
    private var nap: Task<Void, Never>?
    private var inFlight = 0

    init(store: LoungeStore) {
        self.store = store
    }

    var bucket: PixelBucket? { store.pixelBucket }

    func pixel(at cell: Cell) -> PixelBoardState.Pixel? {
        pixels[cell.y * Self.size + cell.x]
    }

    // MARK: - Lifecycle

    func enter() {
        guard tasks.isEmpty else { return }
        let changes = store.net.pixelChanges()
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

    // MARK: - 칠하기

    func paint(_ cell: Cell) {
        selected = cell
        if pixel(at: cell)?.c == color {
            response = .same
            return
        }
        // 버킷이 빈 게 확실하면 서버에 안 묻는다
        if let b = bucket, b.left(at: .now) <= 0 {
            response = .limited
            GameAudio.shared.play(.rouletteReject, at: nil)
            return
        }
        // 바로 칠해 보이고, 서버 응답으로 덮는다
        let painted = color
        pixels[cell.y * Self.size + cell.x] = .init(x: cell.x, y: cell.y, c: painted, p: store.me?.name ?? "나", at: .now)
        if let b = bucket {
            let now = Date.now
            let n = b.left(at: now)
            let next = n >= b.cap ? now.addingTimeInterval(b.refill) : b.untilNext(at: now).map { now.addingTimeInterval($0) }
            store.pixelBucket = PixelBucket(left: n - 1, nextAt: next, cap: b.cap, refill: b.refill)
        }
        response = .created(cell)
        GameAudio.shared.play(.betChip, at: nil)
        inFlight += 1
        Task {
            defer { inFlight -= 1 }
            do {
                let s = try await store.net.pixelPaint(x: cell.x, y: cell.y, color: painted)
                apply(s)
                switch s.status {
                case .limited:
                    response = .limited
                    GameAudio.shared.play(.rouletteReject, at: nil)
                case .same: if selected == cell { response = .same }
                default: break
                }
            } catch {
                response = .failed(error.localizedDescription)
                if let s = try? await store.net.pixelBoard() { apply(s) }
            }
        }
    }

    // MARK: - Sync

    private func loop() async {
        while !Task.isCancelled {
            if inFlight == 0 {
                do {
                    apply(try await store.net.pixelBoard())
                    if case .failed = response { response = .idle }
                } catch {
                    if Task.isCancelled { return }
                    response = .failed("연결이 끊겼어요")
                }
            }
            // 여러 칸이 한꺼번에 바뀌어도 0.3초에 한 번만 읽는다
            try? await Task.sleep(for: .seconds(0.3))
            let t = Task { _ = try? await Task.sleep(for: .seconds(30)) }
            nap = t
            await t.value
        }
    }

    func apply(_ s: PixelBoardState, at now: Date = .now) {
        skew = s.now.timeIntervalSince(now)
        state = s
        var grid = [PixelBoardState.Pixel?](repeating: nil, count: Self.size * Self.size)
        for p in s.pixels where (0..<Self.size).contains(p.x) && (0..<Self.size).contains(p.y) {
            grid[p.y * Self.size + p.x] = p
        }
        pixels = grid
        store.pixelBucket = PixelBucket(left: s.left, nextAt: s.nextAt.map { $0.addingTimeInterval(-skew) },
                                        cap: s.cap, refill: TimeInterval(s.refill))
    }

    /// 스냅샷용
    func preview(response: Response, selected: Cell?, hover: Cell? = nil, color: Int) {
        self.response = response
        self.selected = selected
        self.hover = hover
        self.color = color
    }
}
