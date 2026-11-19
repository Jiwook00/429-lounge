import SwiftUI

/// 닉네임 정하기 / 바꾸기. 처음 온 회원은 이걸 통과해야 테이블에 앉는다.
struct NicknameCard: View {
    /// 지금 이름. 처음이면 nil (서버가 붙인 손님 이름은 보여주지 않는다)
    let current: String?
    /// 저장. 실패하면 보여줄 문구를 돌려준다.
    let onSave: (String) async -> String?
    /// 바꾸기 모드에서만
    let onCancel: (() -> Void)?

    @State private var text: String
    @State private var error: String?
    @State private var saving = false
    @FocusState private var focused: Bool
    @Environment(\.snapshotting) private var snapshotting

    /// initialText / initialError: 스냅샷용
    init(current: String?, onSave: @escaping (String) async -> String? = { _ in nil },
         onCancel: (() -> Void)? = nil, initialText: String = "", initialError: String? = nil) {
        self.current = current
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: initialText)
        _error = State(initialValue: initialError)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespaces) }
    private var valid: Bool { (1...12).contains(trimmed.count) && trimmed != current }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(current == nil ? "입구에서 이름을 적어 주세요" : "새 이름을 적어 주세요")
                .font(Fonts.bold())
                .foregroundStyle(Theme.gold)
            Text("테이블에서 다른 회원에게 보여요 · 1~12자")
                .font(Fonts.small())
                .foregroundStyle(Theme.muted)
            HStack(spacing: 6) {
                field
                    .font(Fonts.body())
                    .foregroundStyle(Theme.cream)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 26)
                    .pixelBox(fill: Theme.bg, border: focused ? Theme.gold : Theme.line)
                Button(action: save) {
                    Text(current == nil ? "입장" : "변경")
                        .font(Fonts.bold())
                        .foregroundStyle(valid ? Theme.bg : Theme.dim)
                        .frame(width: 56, height: 26)
                        .pixelBox(fill: valid ? Theme.gold : Theme.panel, border: valid ? Theme.gold : Theme.line)
                }
                .buttonStyle(.plain)
                .disabled(!valid || saving)
            }
            HStack {
                if let error {
                    Text(error).font(Fonts.small()).foregroundStyle(Theme.neon)
                }
                Spacer()
                if let onCancel {
                    Button("취소", action: onCancel)
                        .buttonStyle(.plain)
                        .font(Fonts.small())
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(12)
        .pixelBox(border: Theme.gold)
        .onAppear { focused = true }
    }

    /// ImageRenderer는 TextField를 못 그려서 스냅샷에선 글자만
    @ViewBuilder private var field: some View {
        if snapshotting {
            Text(text.isEmpty ? (current ?? "닉네임") : text)
                .foregroundStyle(text.isEmpty ? Theme.dim : Theme.cream)
        } else {
            TextField("", text: $text, prompt: Text(current ?? "닉네임").foregroundStyle(Theme.dim))
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(save)
                .onChange(of: text) { error = nil }
        }
    }

    private func save() {
        guard valid, !saving else { return }
        saving = true
        Task {
            error = await onSave(trimmed)
            saving = false
        }
    }
}

extension EnvironmentValues {
    /// Snapshot.render 중이면 true
    @Entry var snapshotting = false
}
