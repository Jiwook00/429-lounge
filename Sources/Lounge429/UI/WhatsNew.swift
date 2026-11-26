import SwiftUI

/// 업데이트 뒤 한 번 보여 주는 "새로 들어온 것" (릴리스 노트는 앱 밖이라 잘 안 본다).
/// 문구는 버전별로 앱에 넣어 둔다. 새 버전을 처음 켜면 로비 게임 타일 자리에 카드가 뜨고, 닫거나 해보기를 누르면 다시 안 뜬다.
/// 버전에 적힌 게임의 타일에는 그 게임에 한 번 들어갈 때까지 `NEW` 라벨이 붙는다.
enum WhatsNew {
    enum Game: String, CaseIterable {
        case roulette, slot, plinko, blackjack, wall, minority
    }

    struct Note {
        let version: String
        let lines: [String]
        /// 해보기로 갈 게임
        let game: Game?
        /// `NEW` 라벨을 붙일 게임
        let newGames: Set<Game>
    }

    /// 새 버전을 낼 때 여기에 한 줄 더한다 (없으면 카드도 라벨도 없다). 카피 톤은 DESIGN.md §11
    static let notes: [Note] = [
        Note(version: "0.14.0",
             lines: [
                 "429 드롭: 꾹 눌렀다 떼면 공이 핀을 타고 내려가요",
                 "게이지 가운데서 떼면 포켓이 넓어져요",
                 "429 429 429면 공 15개가 쏟아져요",
             ],
             game: .plinko, newGames: [.plinko]),
    ]

    static func note(for version: String) -> Note? { notes.first { $0.version == version } }
}

/// 로비의 "새로 들어온 것" 카드. 업데이트 카드와 같은 골드 상자, 게임 타일 자리를 대신한다
struct WhatsNewCard: View {
    let note: WhatsNew.Note
    var onTry: (() -> Void)?
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("v\(note.version) 새로 들어온 것")
                .font(Fonts.bold())
                .foregroundStyle(Theme.gold)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(note.lines, id: \.self) { line in
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
