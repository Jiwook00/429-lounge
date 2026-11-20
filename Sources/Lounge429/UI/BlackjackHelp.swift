import LoungeNet
import SwiftUI

/// 블랙잭 30초 설명. 테이블과 같은 도트 카드로 핵심만 (DESIGN.md §9 블랙잭)
struct BlackjackHelp: View {
    var onClose: () -> Void = {}

    // 카드: 무늬 × 13 + 숫자 (0 스페이드, 1 하트, 2 다이아, 3 클럽 / 0 = A, 9 = 10, 10~12 = J Q K)
    private static let k = 12, h7 = 19, c5 = 43, d9 = 34, hj = 23, dq = 37, ck = 51, ha = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("블랙잭 · 30초 설명").font(Fonts.bold()).foregroundStyle(Theme.gold)
                Spacer()
                Button(action: onClose) {
                    Text("닫기").font(Fonts.small()).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
            }

            row("21에 가깝게. 넘으면 버스트") {
                HStack(spacing: 10) {
                    hand([Self.k, Self.h7], "17", color: Theme.cream)
                    hand([Self.k, Self.c5, Self.d9], "24", color: Theme.neon)
                }
            }
            row("J · Q · K는 10, A는 1 또는 11") {
                HStack(spacing: 10) {
                    hand([Self.hj, Self.dq, Self.ck], "10", color: Theme.cream)
                    hand([Self.ha], "1/11", color: Theme.cream)
                }
            }
            row("첫 두 장이 21이면 블랙잭 · 3:2") {
                hand([Self.ha, Self.k], "21", color: Theme.gold)
            }

            VStack(alignment: .leading, spacing: 4) {
                move("히트", "한 장 더", fill: Theme.neon, border: Theme.neonDeep, text: Theme.cream)
                move("스탠드", "여기서 멈춤", fill: Theme.cream, border: Theme.creamDeep, text: Theme.bg)
                move("더블", "두 배 걸고 딱 한 장 (첫 두 장일 때)", fill: Theme.goldBg, border: Theme.gold, text: Theme.gold)
            }

            Text("딜러는 17이 될 때까지 쳐요. 딜러보다 높거나 딜러가 버스트면 2배. 같으면 그대로.")
                .font(Fonts.small()).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

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

    private func row<C: View>(_ text: String, @ViewBuilder cards: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(Fonts.body())
            cards()
        }
    }

    /// 테이블처럼 겹쳐 놓은 카드 + 합계 배지
    private func hand(_ codes: [Int], _ total: String, color: Color) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: -10) {
                ForEach(Array(codes.enumerated()), id: \.offset) { _, c in
                    GridView(grid: BlackjackArt.card(c), scale: 2)
                }
            }
            Text(total).font(Fonts.mono()).foregroundStyle(color)
                .padding(.horizontal, 3)
                .background(Theme.outline)
                .overlay(Rectangle().strokeBorder(color == Theme.cream ? Theme.line : color, lineWidth: 2))
        }
    }

    private func move(_ name: String, _ what: String, fill: Color, border: Color, text: Color) -> some View {
        HStack(spacing: 8) {
            Text(name).font(Fonts.bold()).foregroundStyle(text)
                .frame(width: 58, height: 22)
                .pixelBox(fill: fill, border: border)
            Text(what).font(Fonts.body())
        }
    }
}
