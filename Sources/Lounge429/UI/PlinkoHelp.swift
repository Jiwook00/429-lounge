import SwiftUI

/// 429 드롭 30초 설명. 4·2·9 단계를 보드와 같은 글자 칸으로 보여 준다 (DESIGN.md §9 429 드롭)
struct PlinkoHelp: View {
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("429 드롭 · 30초 설명").font(Fonts.bold()).foregroundStyle(Theme.gold)
                Spacer()
                Button(action: onClose) {
                    Text("닫기").font(Fonts.small()).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
            }

            Text("공이 가운데 [429] 포켓에 들어가면 글자가 하나 켜지고 건 칩의 20%가 돌아와요")
                .font(Fonts.body())
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                stage(0, "처음 · 다음 포켓이 4를 켜요")
                stage(1, "골드 핀 +1 (맞으면 ×+0.3)")
                stage(2, "파란 분열 핀 +1 (공이 둘로)")
                stage(3, "HOT · 골드 핀 +2, 다음 포켓까지")
            }

            VStack(alignment: .leading, spacing: 4) {
                line("HOT 다음 포켓은 뭐가 나와도 글자가 0부터 다시 시작해요")
                line("릴이 429 429 429면 FEVER. 공 40개가 ×1.5로 쏟아지고 글자는 0부터")
                line("PERFECT로 쏘면 포켓에 약 8% 더 자주 들어가요. AUTO는 파워가 랜덤이라 기본과 거의 같아요")
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

    /// 켜진 글자 수 `lit`일 때의 보드 (글자 칸은 보드와 같은 14×14)
    private func stage(_ lit: Int, _ text: String) -> some View {
        let hot = lit == 3
        return HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(0..<PlinkoTable.letterChars.count, id: \.self) { i in
                    Text(PlinkoTable.letterChars[i])
                        .font(Fonts.small())
                        .foregroundStyle(i < lit ? (hot ? Theme.neon : Theme.gold) : Theme.dim)
                        .frame(width: 14, height: 14)
                        .background(Theme.outline)
                        .overlay(Rectangle().strokeBorder(i < lit ? (hot ? Theme.neon : Theme.gold) : Theme.line, lineWidth: 2))
                }
            }
            .frame(width: 50, alignment: .leading)
            Text(text).font(Fonts.body())
        }
    }

    private func line(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Rectangle().fill(Theme.gold).frame(width: 4, height: 4).padding(.top, 5)
            Text(text).font(Fonts.small()).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
