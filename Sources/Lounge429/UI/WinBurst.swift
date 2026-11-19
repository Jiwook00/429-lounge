import SwiftUI

/// 승리 연출 단계 (DESIGN.md §10)
enum WinTier: Equatable {
    case win, big, jackpot

    /// 슬롯 배수 기준. ×1(본전) 이하는 연출 없음.
    init?(multiplier: Int) {
        switch multiplier {
        case 429...: self = .jackpot
        case 10...: self = .big
        case 2...: self = .win
        default: return nil
        }
    }

    /// 홀짝: 지급액 기준
    init?(payout: Int64) {
        guard payout > 0 else { return nil }
        self = payout >= 1_000 ? .big : .win
    }

    var duration: TimeInterval {
        switch self {
        case .win: 1.6
        case .big: 2.6
        case .jackpot: 4.0
        }
    }

    var coins: Int {
        switch self {
        case .win: 10
        case .big: 28
        case .jackpot: 48
        }
    }
}

/// 금화가 튀어 오르거나 쏟아지고, 금액 배너가 뜨는 오버레이. 터치를 막지 않는다.
/// 시작 시각만 받아서 시간으로 그리므로 상태가 필요 없다.
struct WinBurst: View {
    let tier: WinTier
    let amount: Int64
    let start: Date
    /// 금화가 튀어 오르는 지점과 배너 위치 (뷰 크기 대비)
    var origin: UnitPoint = .center

    var body: some View {
        let active = Date() < start.addingTimeInterval(tier.duration)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { context in
            let e = context.date.timeIntervalSince(start)
            if e >= 0, e < tier.duration {
                GeometryReader { g in
                    ZStack {
                        Canvas { ctx, size in drawCoins(ctx, size: size, elapsed: e) }
                        banner(elapsed: e)
                            .position(x: (g.size.width * origin.x).rounded(), y: (g.size.height * origin.y).rounded())
                    }
                }
                .opacity(fade(e))
            }
        }
        .allowsHitTesting(false)
    }

    private func fade(_ e: TimeInterval) -> Double {
        let tail = tier.duration * 0.2
        return min(1, max(0, (tier.duration - e) / tail))
    }

    // MARK: - 배너

    @ViewBuilder
    private func banner(elapsed e: TimeInterval) -> some View {
        let figure = Text("+\(amount.formatted(.number))").font(Fonts.mono(2)).foregroundStyle(Theme.gold)
        switch tier {
        case .win:
            // 받침 상자째 정수 pt 단위로 떠오른다
            figure
                .glow(Theme.gold)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .pixelBox(fill: Theme.goldBg, border: Theme.gold)
                .offset(y: -min(16, (e * 24).rounded()))
        case .big:
            VStack(spacing: 4) {
                Text("BIG WIN").font(Fonts.bold(2))
                    .foregroundStyle(Theme.neon.opacity(Neon.strobe(at: e).opacity))
                    .glow(Theme.neon, radius: 5, strong: true)
                figure.glow(Theme.gold)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .pixelBox(fill: Theme.bg, border: Theme.neon)
        case .jackpot:
            let flip = Int(e / 0.15) % 2 == 0
            VStack(spacing: 4) {
                Text("JACKPOT").font(Fonts.bold(2))
                    .foregroundStyle(flip ? Theme.neon : Theme.gold)
                    .glow(flip ? Theme.neon : Theme.gold, radius: 6, strong: true)
                Text("429 · 429 · 429").font(Fonts.small()).foregroundStyle(Theme.cyan).glow(Theme.cyan)
                figure.glow(Theme.gold, strong: true)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .pixelBox(fill: Theme.bg, border: flip ? Theme.gold : Theme.neon)
        }
    }

    // MARK: - 금화

    /// 회전하는 도트 금화: 앞면 → 반쯤 → 옆면 → 반쯤
    private static let frames: [[(Int, Int, Color)]] = {
        let face = Sprites.goldChip
        func pixels(_ rows: [String]) -> [(Int, Int, Color)] {
            var out: [(Int, Int, Color)] = []
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    if let c = face.palette[ch] { out.append((x, y, c)) }
                }
            }
            return out
        }
        let full = face.rows
        // 반쯤 돈 모습: 짝수 열만 남겨 6칸 폭, 가운데 정렬
        let half = full.map { row in
            "...." + String(row.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)) + ".."
        }
        // 옆면: 2칸 폭 막대 (진한 금색 + 금색)
        let edge = (0..<12).map { y in y == 0 || y == 11 ? "............" : ".....WR....." }
        return [pixels(full), pixels(half), pixels(edge), pixels(half)]
    }()

    private func drawCoins(_ ctx: GraphicsContext, size: CGSize, elapsed e: TimeInterval) {
        let gravity = 520.0
        for i in 0..<tier.coins {
            let r1 = Self.rand(i, 1), r2 = Self.rand(i, 2), r3 = Self.rand(i, 3)
            var x: Double, y: Double
            if tier == .win || (tier == .jackpot && i % 3 == 0) {
                // 가운데에서 위로 튀어 오름
                let t = e - r3 * 0.12
                guard t > 0 else { continue }
                let vx = (r1 - 0.5) * 260
                let vy = -(170 + r2 * 150)
                x = size.width * origin.x + vx * t
                y = size.height * origin.y + vy * t + 0.5 * gravity * t * t
            } else {
                // 위에서 쏟아짐
                let t = e - r2 * tier.duration * 0.45
                guard t > 0 else { continue }
                x = r1 * (size.width - 12)
                y = -12 + (40 + r3 * 90) * t + 0.5 * gravity * t * t
            }
            guard y < size.height, y > -14 else { continue }
            let frame = Self.frames[(Int(e * 12) + i) % 4]
            let ox = x.rounded(), oy = y.rounded()
            for (px, py, color) in frame {
                ctx.fill(Path(CGRect(x: ox + Double(px), y: oy + Double(py), width: 1, height: 1)), with: .color(color))
            }
        }
    }

    /// 금화마다 고정된 난수 (프레임마다 같아야 궤적이 이어진다)
    private static func rand(_ i: Int, _ k: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: i &* 7919 &+ k &* 104_729 &+ 12_345)
        x ^= x << 13; x ^= x >> 7; x ^= x << 17
        return Double(x % 10_000) / 10_000
    }
}
