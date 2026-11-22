import LoungeNet
import SwiftUI

/// 공이 멈추기 직전 마지막 5칸을 크게 보여주는 클로즈업 컷 (DESIGN.md §9 미니 룰렛, 시안 R3c~R3e).
/// 결과는 마감 직후 이미 와 있지만 화면은 공을 따라가기만 한다: 띠는 공이 있는 칸을 가운데 두고 한 칸씩 밀려온다.
enum RouletteSpin {
    /// 큰 휠에서 빠르게 돌다 결과 4칸 앞에 닿는 시각 (마감부터)
    static let fastEnd: TimeInterval = 3.3
    /// 컷이 열리고 닫히는 시각. 결과(6초) 뒤 0.8초 동안 번쩍인 다음 접힌다
    static let cutOpen: TimeInterval = 3.05
    static let cutClose: TimeInterval = Roulette.spin + 0.8
    /// 한 단계 = 1/12초 (블랙잭 확대와 같은 리듬)
    static let frame: TimeInterval = 1.0 / 12
    /// 한 칸 미끄러지는 시간
    static let slide: TimeInterval = 0.12

    /// (도착 시각, 결과 칸 기준 위치). -1 = 결과 한 칸 앞, -0.5 = 그 사이 칸막이 위(머뭇거림)
    static let stops: [(TimeInterval, Double)] = [
        (fastEnd, -4), (3.6, -3), (4.05, -2), (4.7, -1), (5.6, -0.5), (Roulette.spin, 0),
    ]

    /// 결과 칸 기준 공 위치 (컷 띠와 큰 휠이 함께 쓴다)
    static func position(at e: TimeInterval) -> Double {
        guard e > stops[0].0 - slide else { return stops[0].1 }
        var prev = stops[0]
        for stop in stops.dropFirst() {
            if e < stop.0 - slide { return prev.1 }
            if e < stop.0 {
                let p = (e - (stop.0 - slide)) / slide
                // 정수 pt로 끊기는 건 뷰에서 반올림한다
                return prev.1 + (stop.1 - prev.1) * (1 - (1 - p) * (1 - p))
            }
            prev = stop
        }
        return 0
    }

    /// 컷이 보이는 정도: 0 없음, 1/3, 2/3, 1 (12fps 세 단계)
    static func reveal(at e: TimeInterval) -> Double {
        if e < cutOpen || e >= cutClose + 3 * frame { return 0 }
        if e < cutClose {
            let k = Int((e - cutOpen) / frame)
            return min(1, Double(k + 1) / 3)
        }
        let k = Int((e - cutClose) / frame)
        return Double(2 - k) / 3
    }
}

struct RouletteCloseUp: View {
    let result: Int
    /// 마감부터 지난 시간
    let elapsed: TimeInterval
    let marks: [Roulette.Spot: RouletteTable.Mark]

    static let size = CGSize(width: 298, height: 120)
    private static let cell = CGSize(width: 52, height: 44)
    private static let step: CGFloat = 54
    private static let inner: CGFloat = 294

    private var landed: Bool { elapsed >= Roulette.spin }

    var body: some View {
        let reveal = RouletteSpin.reveal(at: elapsed)
        let w = (Self.size.width * reveal / 2).rounded() * 2
        let h = (Self.size.height * reveal / 2).rounded() * 2
        cut
            .frame(width: Self.size.width, height: Self.size.height)
            .mask(Rectangle().frame(width: w, height: h))
            .opacity(reveal > 0 ? 1 : 0)
            .allowsHitTesting(false)
    }

    private var cut: some View {
        let pos = RouletteSpin.position(at: elapsed)
        let wheel = Roulette.wheel
        let target = wheel.firstIndex(of: result) ?? 0
        let base = Int(pos.rounded(.down))
        let border = landed ? Theme.gold : Theme.neon
        return ZStack(alignment: .topLeading) {
            Theme.panel
            Canvas { ctx, _ in
                for p in Self.rays { ctx.fill(Path(CGRect(x: p.x, y: p.y, width: 2, height: 2)), with: .color(Theme.cream.opacity(0.22))) }
            }
            // 공이 떨어질 자리 표시
            GridView(grid: PixelGrid(rows: ["XXXXXX", ".XXXX.", "..XX.."], map: ["X": .gold]), scale: 2)
                .offset(x: Self.inner / 2 - 6, y: 2)
            ForEach(-3...4, id: \.self) { k in
                let i = ((target + base + k) % wheel.count + wheel.count) % wheel.count
                let n = wheel[i]
                let x = (Self.inner / 2 - Self.cell.width / 2 + (CGFloat(base + k) - CGFloat(pos)) * Self.step).rounded()
                if x > -Self.cell.width, x < Self.inner {
                    pocket(n, center: landed && n == result, dim: landed && n != result)
                        .offset(x: x, y: 12)
                }
            }
            PixelView(sprite: Sprites.marble, scale: 4)
                .offset(x: Self.inner / 2 - 12, y: 62)
        }
        .frame(width: Self.inner, height: Self.size.height - 4)
        .clipped()
        .padding(2)
        .pixelBox(fill: Theme.panel, border: border)
        // 발광은 테두리에만 (컨테이너에 걸면 안쪽 칸마다 그림자가 생긴다)
        .background(Rectangle().fill(Theme.panel).glow(border))
    }

    private func pocket(_ n: Int, center: Bool, dim: Bool) -> some View {
        let mark = n == 0 ? nil : marks[.number(n)]
        return VStack(spacing: 38) {
            Text("\(n)").font(Fonts.mono(2)).foregroundStyle(Theme.cream)
                .frame(width: Self.cell.width, height: Self.cell.height)
                .pixelBox(fill: n == 0 ? Theme.felt : Roulette.red.contains(n) ? Theme.neonDeep : Theme.outline,
                          border: center ? Theme.gold : Theme.line)
                .glow(center ? Theme.gold : .clear)
            tag(mark, landed: center).frame(width: Self.cell.width, height: 12)
        }
        .opacity(dim ? 0.4 : 1)
    }

    @ViewBuilder
    private func tag(_ m: RouletteTable.Mark?, landed: Bool) -> some View {
        if let m, m.mine > 0 {
            Text(landed ? "나 \(m.mine) → \(m.mine * 12)" : "나 \(m.mine)")
                .font(Fonts.small()).foregroundStyle(Theme.gold).fixedSize()
        } else if let m, m.others > 0 {
            HStack(spacing: 2) {
                GridView(grid: RouletteArt.person, scale: 1)
                Text("\(m.others)").font(Fonts.small())
            }
            .foregroundStyle(Theme.cream)
        }
    }

    /// 테두리 쪽에서 안쪽으로 뻗는 도트 집중선 (네 모서리 + 위아래 + 양옆)
    private static let rays: [CGPoint] = {
        let w = inner, h = size.height - 4, cx = w / 2, cy = h / 2
        let from: [CGPoint] = [.init(x: 0, y: 0), .init(x: w, y: 0), .init(x: 0, y: h), .init(x: w, y: h),
                               .init(x: 70, y: 0), .init(x: w - 70, y: 0), .init(x: 70, y: h), .init(x: w - 70, y: h),
                               .init(x: 0, y: cy), .init(x: w, y: cy)]
        return from.flatMap { p -> [CGPoint] in
            let dx = cx - p.x, dy = cy - p.y, len = (dx * dx + dy * dy).squareRoot()
            return (0..<9).map { k in
                let t = CGFloat(k) * 4.4 / len
                return CGPoint(x: ((p.x + dx * t) / 2).rounded() * 2, y: ((p.y + dy * t) / 2).rounded() * 2)
            }
        }
    }()
}
