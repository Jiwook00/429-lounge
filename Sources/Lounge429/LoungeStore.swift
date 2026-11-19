import Foundation
import LoungeCore
import Observation

@MainActor @Observable
final class LoungeStore {
    private(set) var snapshot = UsageSnapshot()
    private(set) var lastScan: Date?
    private let scanner = UsageScanner()

    init() {
        Task { await poll() }
    }

    /// 임시 공식. 칩 경제(3단계)에서 확정.
    var chips: Int { Economy.provisionalChips(snapshot) }

    func refresh() async {
        let scanner = self.scanner
        snapshot = await Task.detached(priority: .utility) { scanner.scan() }.value
        lastScan = .now
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
