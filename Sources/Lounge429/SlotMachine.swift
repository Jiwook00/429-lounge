import Foundation
import LoungeNet
import Observation

/// 슬롯 심볼. rawValue는 서버 값.
enum SlotSymbol: String, CaseIterable {
    case cherry, bell, bar, seven, s429 = "429", blank

    var sprite: PixelSprite {
        switch self {
        case .cherry: Sprites.cherry
        case .bell: Sprites.bell
        case .bar: Sprites.bar
        case .seven: Sprites.seven
        case .s429: Sprites.s429
        case .blank: Sprites.blank
        }
    }

    var label: String {
        switch self {
        case .cherry: "체리"
        case .bell: "벨"
        case .bar: "BAR"
        case .seven: "7"
        case .s429: "429"
        case .blank: "빈칸"
        }
    }

    /// 화면에 보이는 릴 띠 순서 (위아래 이웃 심볼 연출용, 확률과는 무관 — 확률은 서버가 정한다)
    static let reelStrip: [SlotSymbol] = [
        .cherry, .bell, .bar, .seven, .cherry, .blank, .bell, .s429,
        .cherry, .bar, .bell, .blank, .seven, .cherry, .bell, .bar,
    ]

    static func neighbors(of s: SlotSymbol) -> (above: SlotSymbol, below: SlotSymbol) {
        let i = reelStrip.firstIndex(of: s) ?? 0
        let n = reelStrip.count
        return (reelStrip[(i + n - 1) % n], reelStrip[(i + 1) % n])
    }
}

/// 슬롯머신 상태. 결과는 서버에서 바로 오지만, 화면에서는 릴이 차례로 멈추며 공개한다.
@MainActor @Observable
final class SlotMachine {
    var stake: Int64 = 50
    var useGolden = false
    private(set) var reels: [SlotSymbol] = [.seven, .s429, .seven]
    private(set) var result: SlotResult?
    private(set) var startedAt: Date?
    /// 결과를 받은 뒤 릴이 멈추기 시작하는 기준 시각
    private(set) var revealAt: Date?
    private(set) var message: String?
    /// 스핀 중 보여줄 잔액 (결과가 미리 드러나지 않게)
    private(set) var pendingChips: Int?

    /// 각 릴이 멈추는 시각 (revealAt 기준)
    static let stopDelays: [TimeInterval] = [0.7, 1.15, 1.6]

    private let store: LoungeStore

    init(store: LoungeStore) {
        self.store = store
    }

    func stopTime(_ reel: Int) -> Date? { revealAt?.addingTimeInterval(Self.stopDelays[reel]) }
    var finishAt: Date? { stopTime(2) }

    func isSpinning(at now: Date) -> Bool {
        guard startedAt != nil else { return false }
        guard let end = finishAt else { return true }
        return now < end
    }

    /// 릴이 멈춘 뒤의 승리 연출 단계
    var tier: WinTier? { result.flatMap { WinTier(multiplier: $0.multiplier) } }

    func spin() async {
        let now = Date()
        guard !isSpinning(at: now) else { return }
        let golden = useGolden && store.golden() > 0
        let amount = golden ? 100 : stake
        startedAt = now
        revealAt = nil
        result = nil
        message = nil
        pendingChips = store.chips - (golden ? 0 : Int(amount))

        do {
            let r = try await store.net.spin(amount: amount, golden: golden)
            result = r
            // 최소 0.25초는 돌게 해서 "당겼다"는 손맛을 남긴다
            revealAt = max(Date(), now.addingTimeInterval(0.25))
            reels = r.reels.compactMap(SlotSymbol.init(rawValue:))
            if golden, store.golden() <= 1 { useGolden = false }
            let wait = finishAt?.timeIntervalSinceNow ?? 0
            try? await Task.sleep(for: .seconds(max(0, wait)))
            store.update(r.player)
            pendingChips = nil
        } catch {
            startedAt = nil
            pendingChips = nil
            message = error.localizedDescription
        }
    }

    // MARK: - Preview

    func preview(result: SlotResult, finishedAgo: TimeInterval) {
        self.result = result
        reels = result.reels.compactMap(SlotSymbol.init(rawValue:))
        let reveal = Date().addingTimeInterval(-finishedAgo - Self.stopDelays[2])
        startedAt = reveal.addingTimeInterval(-0.25)
        revealAt = reveal
    }

    func previewSpinning(stoppedReels: Int, result: SlotResult) {
        self.result = result
        reels = result.reels.compactMap(SlotSymbol.init(rawValue:))
        // stoppedReels개가 막 멈춘 순간
        let elapsed = stoppedReels == 0 ? 0.3 : Self.stopDelays[stoppedReels - 1] + 0.05
        revealAt = Date().addingTimeInterval(-elapsed)
        startedAt = revealAt?.addingTimeInterval(-0.25)
        pendingChips = store.chips - 50
    }
}
