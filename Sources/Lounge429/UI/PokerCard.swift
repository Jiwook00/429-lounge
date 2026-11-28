import SwiftUI

/// 인디언 포커 카드 (DESIGN.md §인디언 포커). 카지노 pip형 88×108: 크림 종이, 골드 이중 테두리, 모서리 인덱스,
/// 숫자만큼 429 칩 pip을 트럼프 배치로. 둥근 모서리(6)는 픽셀 규칙의 예외로 카드에만 쓴다.
struct PokerCard: View {
    enum Face: Equatable {
        case front(Int)
        case back
        /// 대기 화면 자리 표시 ("나" / "봇")
        case seat(String, mine: Bool)
        /// 대기 화면에서 사람이 앉은 자리 (시안 실선)
        case person(String)
    }

    static let size = CGSize(width: 88, height: 108)
    static let radius: CGFloat = 6

    let face: Face
    var folded = false
    var winner = false
    /// 대기 화면 자리 칸 높이 (카드 앞·뒷면은 늘 88×108)
    var seatHeight: CGFloat = PokerCard.size.height

    var body: some View {
        Group {
            switch face {
            case .front(let n): front(n)
            case .back: back
            case .seat(let text, let mine): seat(text, mine: mine)
            case .person(let text): person(text)
            }
        }
        .saturation(folded ? 0.3 : 1)
        .opacity(folded ? 0.45 : 1)
        // 이긴 카드: 테두리 바깥만 은은히 (pip까지 번지지 않게 뒤에 깐 판에만 발광)
        .background { if winner { shape.fill(Theme.gold).glow(Theme.gold, radius: 5) } }
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    private var label: String {
        switch face {
        case .front(let n): "카드 \(n)"
        case .back: "뒷면 카드"
        case .seat(let text, _): text == "나" ? "내 자리" : "봇 자리"
        case .person(let text): "\(text) 자리"
        }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.radius) }

    // MARK: 앞면

    /// pip 자리 (가로·세로 0~1, 트럼프 배치). 시안 Cards와 같다
    static func pips(_ n: Int) -> [CGPoint] {
        let l: CGFloat = 0, c: CGFloat = 0.5, r: CGFloat = 1
        switch n {
        case 1: return [CGPoint(x: c, y: 0.5)]
        case 2: return [CGPoint(x: c, y: 0), CGPoint(x: c, y: 1)]
        case 3: return [CGPoint(x: c, y: 0), CGPoint(x: c, y: 0.5), CGPoint(x: c, y: 1)]
        case 4: return [CGPoint(x: l, y: 0), CGPoint(x: r, y: 0), CGPoint(x: l, y: 1), CGPoint(x: r, y: 1)]
        case 5: return pips(4) + [CGPoint(x: c, y: 0.5)]
        case 6: return pips(4) + [CGPoint(x: l, y: 0.5), CGPoint(x: r, y: 0.5)]
        case 7: return pips(6) + [CGPoint(x: c, y: 0.25)]
        case 8: return pips(7) + [CGPoint(x: c, y: 0.75)]
        case 9:
            return pips(4) + [CGPoint(x: l, y: 1.0 / 3), CGPoint(x: r, y: 1.0 / 3), CGPoint(x: l, y: 2.0 / 3),
                              CGPoint(x: r, y: 2.0 / 3), CGPoint(x: c, y: 0.5)]
        default:
            return pips(4) + [CGPoint(x: l, y: 1.0 / 3), CGPoint(x: r, y: 1.0 / 3), CGPoint(x: l, y: 2.0 / 3),
                              CGPoint(x: r, y: 2.0 / 3), CGPoint(x: c, y: 1.0 / 6), CGPoint(x: c, y: 5.0 / 6)]
        }
    }

    private func front(_ n: Int) -> some View {
        // pip 영역: 테두리 안쪽(84×104)에서 좌우 27, 위아래 24 들어간 30×56
        let area = CGRect(x: 2 + 27, y: 2 + 24, width: 30, height: 56)
        return ZStack(alignment: .topLeading) {
            shape.fill(Theme.cream)
            RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.goldDark, lineWidth: 1)
                .padding(4)
            ForEach(Array(Self.pips(n).enumerated()), id: \.offset) { _, p in
                Pip(size: n == 1 ? 26 : 11)
                    .position(x: area.minX + p.x * area.width, y: area.minY + p.y * area.height)
            }
            index(n).offset(x: 6, y: 7)
            index(n).rotationEffect(.degrees(180))
                .frame(width: Self.size.width - 12, height: Self.size.height - 14, alignment: .bottomTrailing)
                .offset(x: 6, y: 7)
            shape.strokeBorder(winner ? Theme.goldLight : Theme.gold, lineWidth: 2)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private func index(_ n: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(Fonts.bold()).foregroundStyle(Theme.neonDeep).fixedSize()
            Pip(size: 7)
        }
        .frame(width: 14)
    }

    // MARK: 뒷면

    private var back: some View {
        ZStack {
            Canvas { ctx, size in
                // 45도 줄무늬: 네온 4 · 진한 네온 4
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.neonDeep))
                let step: CGFloat = 8 * 2.squareRoot()
                var x: CGFloat = -size.height
                while x < size.width + size.height {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: size.height))
                    p.addLine(to: CGPoint(x: x + size.height, y: 0))
                    ctx.stroke(p, with: .color(Theme.neon), lineWidth: 4)
                    x += step
                }
            }
            .clipShape(shape)
            // 안쪽 크림 띠 3 + 진한 골드 선 1
            RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.cream, lineWidth: 3).padding(2)
            RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.goldDark, lineWidth: 1).padding(5)
            Circle().fill(Theme.bg).frame(width: 32, height: 32)
                .overlay(Circle().strokeBorder(Theme.gold, lineWidth: 2))
                .overlay(Text("429").font(Fonts.small()).foregroundStyle(Theme.gold))
            shape.strokeBorder(Theme.gold, lineWidth: 2)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    // MARK: 대기 자리

    private func seat(_ text: String, mine: Bool) -> some View {
        Text(text)
            .font(mine ? Fonts.bold(2) : Fonts.body())
            .foregroundStyle(mine ? Theme.gold : Theme.cream)
            .frame(maxWidth: .infinity)
            .frame(height: seatHeight)
            .background(shape.fill(Theme.outline.opacity(0.35)))
            .overlay {
                if mine {
                    shape.strokeBorder(Theme.gold, lineWidth: 2)
                } else {
                    shape.strokeBorder(Theme.feltLine, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                }
            }
    }

    private func person(_ text: String) -> some View {
        Text(text)
            .font(Fonts.bold())
            .foregroundStyle(Theme.cyan)
            .frame(maxWidth: .infinity)
            .frame(height: seatHeight)
            .background(shape.fill(Theme.bg))
            .overlay(shape.strokeBorder(Theme.cyan, lineWidth: 2))
    }
}

/// 429 칩 pip: 네온 가운데 · 크림 띠 · 진한 네온 바깥 · 검은 테두리
struct Pip: View {
    let size: CGFloat

    var body: some View {
        let border: CGFloat = size >= 20 ? 2 : 1
        let inner = size - border * 2
        ZStack {
            Circle().fill(Theme.outline)
            Circle().fill(Theme.neonDeep).frame(width: inner, height: inner)
            Circle().fill(Theme.cream).frame(width: (inner * 0.65).rounded(), height: (inner * 0.65).rounded())
            Circle().fill(Theme.neon).frame(width: max(2, (inner * 0.37).rounded()), height: max(2, (inner * 0.37).rounded()))
        }
        .frame(width: size, height: size)
    }
}
