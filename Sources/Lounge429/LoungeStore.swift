import Foundation
import LoungeCore
import LoungeNet
import Observation

@MainActor @Observable
final class LoungeStore {
    private(set) var snapshot = UsageSnapshot()
    private(set) var lastScan: Date?
    /// 서버 지갑. 연결 전/오프라인이면 nil.
    private(set) var me: Player?
    private(set) var netError: String?

    let net = LoungeClient()
    private let scanner = UsageScanner()

    init(live: Bool = true) {
        guard live else { return }
        Task { await poll() }
        Task { await connect() }
    }

    /// 서버 지갑이 있으면 그걸, 없으면 임시 공식(칩 경제 3단계에서 확정)
    var chips: Int { me.map { Int($0.chips) } ?? Economy.provisionalChips(snapshot) }

    func refresh() async {
        let scanner = self.scanner
        snapshot = await Task.detached(priority: .utility) { scanner.scan() }.value
        lastScan = .now
        await refreshMe()
    }

    func connect() async {
        do {
            me = try await net.signIn(name: String(NSUserName().prefix(16)))
            netError = nil
        } catch {
            netError = "라운지 서버에 연결할 수 없어요"
        }
    }

    func refreshMe() async {
        guard me != nil, let fresh = try? await net.me() else { return }
        me = fresh
    }

    func update(_ player: Player) {
        if player.id == me?.id { me = player }
    }

    /// 스냅샷/프리뷰용
    func preview(me: Player, snapshot: UsageSnapshot) {
        self.me = me
        self.snapshot = snapshot
    }

    private func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(30))
        }
    }
}

enum Economy {
    static func provisionalChips(_ s: UsageSnapshot) -> Int { s.today.fresh / 1_000 }
}
