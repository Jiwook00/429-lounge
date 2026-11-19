import SwiftUI

/// 베팅 금액 선택 + 황금 칩(공짜 100칩) 토글. 홀짝, 슬롯 공용.
struct StakePicker: View {
    @Binding var stake: Int64
    @Binding var useGolden: Bool
    let chips: Int
    let golden: Int
    var disabled = false

    static let stakes: [Int64] = [10, 50, 100, 500]

    private var goldenSelected: Bool { useGolden && golden > 0 }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.stakes, id: \.self) { s in
                let selected = !goldenSelected && stake == s
                let affordable = Int64(chips) >= s
                Button { stake = s; useGolden = false } label: {
                    Text(s.formatted(.number))
                        .font(Fonts.mono())
                        .foregroundStyle(selected ? Theme.bg : Theme.cream)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .pixelBox(fill: selected ? Theme.gold : Theme.panel, border: selected ? Theme.gold : Theme.line)
                }
                .buttonStyle(.plain)
                .disabled(!affordable || disabled)
                .opacity(affordable ? 1 : 0.4)
            }
            if golden > 0 {
                Button { useGolden.toggle() } label: {
                    HStack(spacing: 3) {
                        PixelView(sprite: Sprites.goldChip, scale: 1)
                        Text("×\(golden)").font(Fonts.mono())
                    }
                    .foregroundStyle(goldenSelected ? Theme.bg : Theme.gold)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .pixelBox(fill: goldenSelected ? Theme.gold : Theme.goldBg, border: Theme.gold)
                }
                .buttonStyle(.plain)
                .disabled(disabled)
            }
        }
    }
}
