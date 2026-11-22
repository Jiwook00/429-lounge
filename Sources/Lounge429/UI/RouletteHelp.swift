import LoungeNet
import SwiftUI

/// 미니 룰렛 30초 설명. 테이블과 같은 칸 모양으로 핵심만 (DESIGN.md §9 미니 룰렛)
struct RouletteHelp: View {
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("미니 룰렛 · 30초 설명").font(Fonts.bold()).foregroundStyle(Theme.gold)
                Spacer()
                Button(action: onClose) {
                    Text("닫기").font(Fonts.small()).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
            }

            Text("공은 0~12 중 한 칸에 멈춰요").font(Fonts.body())

            pays([cell("7", fill: Theme.outline)], "숫자 하나 · 12배")
            pays([cell("빨강", fill: Theme.neonDeep), cell("홀", fill: Theme.felt), cell("1–6", fill: Theme.felt)],
                 "색 · 홀짝 · 절반 · 2배")
            pays([cell("0", fill: Theme.felt)], "무효 판 · 전부 돌려받음")

            VStack(alignment: .leading, spacing: 4) {
                line("칸을 누르면 바로 걸려요. 또 누르면 더해지고, 건 칩은 못 물러요")
                line("첫 칩이 12초 판을 열어요. 혼자면 바로 돌리기")
                line("황금 칩은 2배 칸에만. 이기면 200, 져도 잃는 건 없어요")
            }

            Button(action: onClose) {
                Text("알겠어요").font(Fonts.bold()).foregroundStyle(Theme.bg)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .pixelBox(fill: Theme.gold, border: Theme.gold)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .pixelBox(fill: Theme.panel, border: Theme.gold)
        .background(alignment: .topLeading) { Rectangle().fill(Theme.outline).offset(x: 4, y: 4) }
    }

    private func pays(_ cells: [AnyView], _ text: String) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) { ForEach(Array(cells.enumerated()), id: \.offset) { $0.element } }
                .frame(width: 124, alignment: .leading)
            Text(text).font(Fonts.body())
        }
    }

    private func cell(_ label: String, fill: Color) -> AnyView {
        AnyView(Text(label).font(Fonts.bold()).foregroundStyle(Theme.cream)
            .frame(width: label.count > 1 ? 44 : 28, height: 24)
            .pixelBox(fill: fill, border: Theme.feltLine))
    }

    private func line(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Rectangle().fill(Theme.gold).frame(width: 4, height: 4).padding(.top, 5)
            Text(text).font(Fonts.small()).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
