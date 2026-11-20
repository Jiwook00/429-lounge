import AppKit
import LoungeCore
import SwiftUI

/// 새 버전 안내. 게임 타일 자리를 대신한다 (닉네임 카드와 같은 자리, ADR-0010)
/// - 선택: 버전 라벨을 눌렀을 때. 닫을 수 있다
/// - 필수: 서버 최소 버전 미달. 테이블에 못 앉고 닫을 수 없다
struct UpdateCard: View {
    let update: AppUpdate
    var onClose: (() -> Void)?

    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(update.required ? "이 버전으론 테이블에 못 앉아요" : "새 버전 v\(update.target.description)이 들어왔어요")
                .font(Fonts.bold())
                .foregroundStyle(Theme.gold)
            Text(update.required
                 ? "라운지 규칙이 바뀌었어요 · v\(update.target.description)부터 입장"
                 : "v\(update.current.description) → v\(update.target.description) · 터미널에 한 줄이면 끝나요")
                .font(Fonts.small())
                .foregroundStyle(Theme.muted)
            Text(AppInfo.installCommand)
                .font(Fonts.small())
                .foregroundStyle(Theme.cream)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .pixelBox(fill: Theme.bg, border: Theme.line)
            HStack(spacing: 8) {
                Button(action: copy) {
                    Text(copied ? "복사했어요" : "명령 복사")
                        .font(Fonts.bold())
                        .foregroundStyle(Theme.bg)
                        .frame(width: 84, height: 26)
                        .pixelBox(fill: Theme.gold, border: Theme.gold)
                }
                .buttonStyle(.plain)
                Text("붙여 넣으면 껐다 다시 켜져요")
                    .font(Fonts.small())
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
            }
            HStack {
                Button("바뀐 점") { openURL(AppInfo.releaseURL(update.target)) }
                Spacer()
                if let onClose { Button("닫기", action: onClose) }
            }
            .buttonStyle(.plain)
            .font(Fonts.small())
            .foregroundStyle(Theme.muted)
        }
        .padding(12)
        .pixelBox(border: Theme.gold)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AppInfo.installCommand, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
