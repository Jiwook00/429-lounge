import Foundation
import LoungeNet
import Observation

/// 슬롯 심볼. rawValue는 서버 값. 상태 코드 심볼은 429(잭팟)와 500(글리치)만.
enum SlotSymbol: String, CaseIterable {
    case cherry, bell, bar, seven, blank
    case s429 = "429", err500 = "500"
    /// 예전 결과(HTTP 기믹 v1) 호환용. 지금 릴에는 없다.
    case ok200 = "200", nf404 = "404"

    var sprite: PixelSprite {
        switch self {
        case .cherry: Sprites.cherry
        case .bell: Sprites.bell
        case .bar: Sprites.bar
        case .seven: Sprites.seven
        case .s429: Sprites.s429
        case .ok200: Sprites.ok200
        case .nf404: Sprites.nf404
        case .err500: Sprites.err500
        case .blank: Sprites.blank
        }
    }

    var label: String {
        switch self {
        case .cherry: "체리"
        case .bell: "벨"
        case .bar: "BAR"
        case .seven: "7"
        case .blank: "빈칸"
        default: rawValue
        }
    }

    /// 화면에 보이는 릴 띠 순서 (위아래 이웃 심볼 연출용, 확률과는 무관 — 확률은 서버가 정한다)
    static let reelStrip: [SlotSymbol] = [
        .cherry, .blank, .bell, .bar, .seven, .blank, .cherry, .err500, .bell, .s429,
        .blank, .cherry, .bar, .bell, .blank, .seven, .cherry, .bell,
    ]

    static func neighbors(of s: SlotSymbol) -> (above: SlotSymbol, below: SlotSymbol) {
        let i = reelStrip.firstIndex(of: s) ?? 0
        let n = reelStrip.count
        return (reelStrip[(i + n - 1) % n], reelStrip[(i + 1) % n])
    }
}

/// 슬롯머신 상태. 결과는 서버에서 바로 오지만, 화면에서는 릴이 차례로 멈추며 공개한다.
///
/// 타임라인 (revealAt 기준):
///   0.7 / 1.15 / 1.6초에 릴이 처음 결과로 멈춤
///   500이 있으면: +0.25초 뒤 글리치 0.55초 → 그 릴만 0.6초 다시 돌고 최종 심볼로 멈춤
@MainActor @Observable
final class SlotMachine {
    enum ReelState {
        case spinning
        /// 멈춤. settled: 멈춘 지 지난 시간 (튕김 연출용)
        case stopped(SlotSymbol, settled: TimeInterval)
        /// 500 글리치 중
        case glitching(SlotSymbol)
    }

    var stake: Int64 = 50
    var useGolden = false
    /// 최종 릴
    private(set) var reels: [SlotSymbol] = [.seven, .s429, .seven]
    /// 처음 멈춘 릴 (500 포함)
    private(set) var initialReels: [SlotSymbol] = [.seven, .s429, .seven]
    private(set) var result: SlotResult?
    private(set) var startedAt: Date?
    /// 결과를 받은 뒤 릴이 멈추기 시작하는 기준 시각
    private(set) var revealAt: Date?
    private(set) var message: String?
    /// 스핀 중 보여줄 잔액 (결과가 미리 드러나지 않게)
    private(set) var pendingChips: Int?

    static let stopDelays: [TimeInterval] = [0.7, 1.15, 1.6]
    static let glitchLead: TimeInterval = 0.25
    static let glitchNoise: TimeInterval = 0.55
    static let glitchRespin: TimeInterval = 0.6

    private let store: LoungeStore

    init(store: LoungeStore) {
        self.store = store
    }

    var glitched: [Int] { result?.glitched ?? [] }

    func stopTime(_ reel: Int) -> Date? { revealAt?.addingTimeInterval(Self.stopDelays[reel]) }

    var glitchStart: Date? {
        guard !glitched.isEmpty else { return nil }
        return stopTime(2)?.addingTimeInterval(Self.glitchLead)
    }

    var finishAt: Date? {
        if let g = glitchStart { return g.addingTimeInterval(Self.glitchNoise + Self.glitchRespin) }
        return stopTime(2)
    }

    func turningReels(at time: Date) -> Int {
        (0..<3).filter { index in
            if case .spinning = reelState(index, at: time) { return true }
            return false
        }.count
    }

    func isSpinning(at now: Date) -> Bool {
        guard startedAt != nil else { return false }
        guard let end = finishAt else { return true }
        return now < end
    }

    /// 500 글리치 ~ 리스핀 구간인지
    func isGlitching(at t: Date) -> Bool {
        guard let g = glitchStart, let end = finishAt else { return false }
        return t >= g && t < end
    }

    func reelState(_ i: Int, at t: Date) -> ReelState {
        guard startedAt != nil else { return .stopped(reels[i], settled: 1) }
        guard let stop = stopTime(i), t >= stop else { return .spinning }
        if glitched.contains(i), let g = glitchStart {
            if t < g { return .stopped(initialReels[i], settled: t.timeIntervalSince(stop)) }
            if t < g.addingTimeInterval(Self.glitchNoise) { return .glitching(initialReels[i]) }
            let respunAt = g.addingTimeInterval(Self.glitchNoise + Self.glitchRespin)
            if t < respunAt { return .spinning }
            return .stopped(reels[i], settled: t.timeIntervalSince(respunAt))
        }
        return .stopped(reels[i], settled: t.timeIntervalSince(stop))
    }

    /// 릴이 다 멈춘 뒤의 승리 연출 단계
    var tier: WinTier? { result.flatMap { WinTier(multiplier: $0.payoutMultiplier) } }

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
            apply(r)
            // 최소 0.25초는 돌게 해서 "당겼다"는 손맛을 남긴다
            revealAt = max(Date(), now.addingTimeInterval(0.25))
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

    private func apply(_ r: SlotResult) {
        result = r
        reels = r.reels.compactMap(SlotSymbol.init(rawValue:))
        initialReels = r.initialReels.compactMap(SlotSymbol.init(rawValue:))
    }

    // MARK: - Preview

    /// revealAt으로부터 `elapsed`초 지난 순간으로 맞춘다
    func preview(result r: SlotResult, elapsed: TimeInterval, pending: Bool = false) {
        apply(r)
        revealAt = Date().addingTimeInterval(-elapsed)
        startedAt = revealAt?.addingTimeInterval(-0.25)
        if pending { pendingChips = store.chips - 50 }
    }

    /// 다 멈추고 `ago`초 지난 순간
    func preview(result r: SlotResult, finishedAgo ago: TimeInterval) {
        apply(r)
        let total = Self.stopDelays[2] + (r.glitched.isEmpty ? 0 : Self.glitchLead + Self.glitchNoise + Self.glitchRespin)
        preview(result: r, elapsed: total + ago)
    }
}
