import LoungeCore
import SwiftUI

/// 업데이트 뒤 한 번 보여 주는 "새로 들어온 것" (릴리스 노트는 앱 밖이라 잘 안 본다).
/// 문구는 버전별로 앱에 넣어 둔다. 새 버전을 처음 켜면 로비 게임 타일 자리에 카드가 뜨고, 닫거나 해보기를 누르면 다시 안 뜬다.
/// 버전을 건너뛰고 받았으면 그 사이 버전들의 문구를 모아 최신부터 4줄까지 보여 준다 (`ReleaseNotes.digest`).
/// 카드를 닫을 때 그 카드의 새 게임들을 기억해 두고, 그 게임에 들어갈 때까지 타일에 `NEW` 라벨을 붙인다.
enum WhatsNew {
    enum Game: String, CaseIterable {
        case roulette, slot, plinko, blackjack, wall
    }

    /// 새 버전을 낼 때 여기에 한 줄 더한다 (회원에게 알릴 게 없으면 안 더해도 된다). 카피 톤은 DESIGN.md §11
    static let notes: [ReleaseNote] = [
        ReleaseNote(version: "0.15.0",
                    lines: [
                        "429 드롭: 포켓마다 4·2·9가 켜지며 골드·분열 핀이 늘어요",
                        "4·2·9가 다 켜지면 HOT, 다음 포켓까지 잘 터져요",
                        "FEVER는 공 40개 · 칩은 10 · 50 · 100 · 200",
                        "429에 걸린 동안엔 포켓이 늘 열려 있어요",
                    ],
                    game: Game.plinko.rawValue),
        ReleaseNote(version: "0.14.0",
                    lines: [
                        "429 드롭: 꾹 눌렀다 떼면 공이 핀을 타고 내려가요",
                        "게이지 가운데서 떼면 포켓이 넓어져요",
                        "429 429 429면 공 15개가 쏟아져요",
                    ],
                    game: Game.plinko.rawValue, newGames: [Game.plinko.rawValue]),
    ]
}

/// 로비의 "새로 들어온 것" 카드. 업데이트 카드와 같은 골드 상자, 게임 타일 자리를 대신한다
struct WhatsNewCard: View {
    let digest: ReleaseDigest
    var onTry: (() -> Void)?
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(digest.from.map { "v\($0) ~ v\(digest.to) 새로 들어온 것" } ?? "v\(digest.to) 새로 들어온 것")
                .font(Fonts.bold())
                .foregroundStyle(Theme.gold)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(digest.lines, id: \.self) { line in
                    Text("· " + line)
                        .font(Fonts.small())
                        .foregroundStyle(Theme.cream)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                if let onTry {
                    Button(action: onTry) {
                        Text("해보기")
                            .font(Fonts.bold())
                            .foregroundStyle(Theme.bg)
                            .padding(.horizontal, 8)
                            .frame(minWidth: 84, minHeight: 26)
                            .pixelBox(fill: Theme.gold, border: Theme.gold)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button("닫기", action: onClose)
                    .buttonStyle(.plain)
                    .font(Fonts.small())
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelBox(border: Theme.gold)
    }
}
