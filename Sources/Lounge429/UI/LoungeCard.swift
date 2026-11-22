import LoungeNet
import SwiftUI

/// 라운지 카드: 앞면은 "지금 라운지" 띠, 뒷면은 "이번 주 큰손" (DESIGN.md §9, ADR-0012)
/// 뒤집기는 금화처럼 도트로: 앞면 → 반쯤 → 옆면 → 반쯤 → 뒷면 (12fps). 부드러운 3D 회전은 도트가 번져서 안 쓴다
struct LoungeCard: View {
    enum Face { case front, back }

    let crowd: LoungeCrowd
    var now: Date = .now
    /// nil = 아직 못 읽음
    var board: [BoardRow]?
    /// 팝오버가 닫히면 다음엔 앞면부터
    var visible = true
    /// 뒷면으로 넘길 때 (큰손 다시 읽기)
    var onBoard: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var face: Face
    /// 뒤집는 중간 프레임. 0 = 없음, 1·3 = 반쯤, 2 = 옆면
    @State private var frame: Int
    @State private var flipping: Task<Void, Never>?

    /// 카드 폭: 팝오버 340 - 바깥 여백 28
    private static let width: CGFloat = LoungeView.width - 28
    private static let frameTime: Duration = .milliseconds(83)

    init(crowd: LoungeCrowd, now: Date = .now, board: [BoardRow]? = nil, visible: Bool = true,
         face: Face = .front, frame: Int = 0, onBoard: @escaping () -> Void = {}) {
        self.crowd = crowd
        self.now = now
        self.board = board
        self.visible = visible
        self.onBoard = onBoard
        _face = State(initialValue: face)
        _frame = State(initialValue: frame)
    }

    var body: some View {
        // 면마다 제 높이: 앞면은 띠 크기 그대로, 뒷면은 큰손 크기. 높이는 옆면 프레임(face가 바뀌는 순간)에 바뀐다
        Group {
            switch face {
            case .front: PresenceStrip(crowd: crowd, now: now, onFlip: flip)
            case .back: BoardCard(rows: board, onFlip: flip)
            }
        }
        .hidden(frame > 0)
        .overlay {
            if frame > 0 { edge }
        }
        .onChange(of: visible) { _, shown in
            guard !shown else { return }
            flipping?.cancel()
            face = .front
            frame = 0
        }
    }

    /// 뒤집는 중인 카드: 반쯤은 폭 절반의 빈 카드, 옆면은 골드 세로선
    private var edge: some View {
        Group {
            if frame == 2 {
                Rectangle().fill(Theme.gold).frame(width: 2)
            } else {
                Color.clear.pixelBox(border: Theme.gold).frame(width: Self.width / 2)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func flip() {
        let next: Face = face == .front ? .back : .front
        if next == .back { onBoard() }
        flipping?.cancel()
        guard !reduceMotion else {
            face = next
            return
        }
        flipping = Task { @MainActor in
            for f in 1...3 {
                frame = f
                if f == 2 { face = next }
                try? await Task.sleep(for: Self.frameTime)
                if Task.isCancelled { return }
            }
            frame = 0
        }
    }
}

/// 이번 주 큰손: 위 10명(5줄씩 스크롤) + (10위 밖이면) 아래에 내 줄 고정. 순수익 = 지급액 - 건 칩, KST 월요일 00시에 새 장부
struct BoardCard: View {
    let rows: [BoardRow]?
    var onFlip: () -> Void = {}

    /// 한 번에 보이는 줄 수와 줄 높이
    static let visibleLines = 5
    static let lineHeight: CGFloat = 20

    /// 맨 위에 보이는 줄 (스크롤·화살표 공용)
    @State private var topID: String?
    /// ImageRenderer는 ScrollView를 못 그린다 → 스냅샷에선 앞 5줄만 그냥 쌓는다
    @Environment(\.snapshotting) private var snapshotting

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onFlip) {
                HStack(spacing: 6) {
                    Rectangle().fill(Theme.gold).frame(width: 6, height: 6)
                    Text("이번 주 큰손").font(Fonts.bold())
                    Text("월요일 초기화").font(Fonts.small()).foregroundStyle(Theme.dim)
                    Spacer()
                    Text("◂ 라운지").font(Fonts.small()).foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .pixelBox()
    }

    @ViewBuilder private var content: some View {
        if let rows {
            let top = Self.top(rows)
            if top.isEmpty && Self.outside(rows) == nil {
                Text("이번 주 첫 판은 아직이에요").font(Fonts.small()).foregroundStyle(Theme.dim)
            } else {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 4) {
                        list(top)
                        if top.count > Self.visibleLines { arrows(top) }
                    }
                    // 10위 밖이면 어디를 보고 있든 내 줄은 아래에 (순위 숫자가 건너뛴다)
                    if let mine = Self.outside(rows) { Line(row: mine).frame(height: Self.lineHeight) }
                }
            }
        } else {
            Text("장부 넘기는 중…").font(Fonts.small()).foregroundStyle(Theme.dim)
        }
    }

    @ViewBuilder private func list(_ top: [BoardRow]) -> some View {
        if snapshotting {
            VStack(spacing: 0) {
                ForEach(top.prefix(Self.visibleLines)) { Line(row: $0).frame(height: Self.lineHeight) }
            }
        } else {
            scrolling(top)
        }
    }

    private func scrolling(_ top: [BoardRow]) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(top) { Line(row: $0).frame(height: Self.lineHeight) }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $topID, anchor: .top)
        .frame(height: CGFloat(min(top.count, Self.visibleLines)) * Self.lineHeight)
    }

    /// 스크롤이 어려운 환경을 위한 화살표. 한 번에 한 줄
    private func arrows(_ top: [BoardRow]) -> some View {
        let index = top.firstIndex { $0.id == topID } ?? 0
        let last = top.count - Self.visibleLines
        return VStack(spacing: 0) {
            arrow("▲", enabled: index > 0) { topID = top[max(index - 1, 0)].id }
            Spacer(minLength: 0)
            arrow("▼", enabled: index < last) { topID = top[min(index + 1, last)].id }
        }
        .frame(width: 18, height: CGFloat(Self.visibleLines) * Self.lineHeight)
    }

    private func arrow(_ glyph: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(nil) { action() }
        } label: {
            Text(glyph).font(Fonts.small())
                .foregroundStyle(enabled ? Theme.gold : Theme.dim.opacity(0.5))
                .frame(width: 18, height: Self.lineHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// 10위까지 (서버가 위 10명 + 내 줄을 준다)
    static func top(_ rows: [BoardRow]) -> [BoardRow] {
        rows.filter { $0.rank <= 10 }
    }

    /// 10위 밖의 내 줄
    static func outside(_ rows: [BoardRow]) -> BoardRow? {
        rows.first { $0.me && $0.rank > 10 }
    }

    private struct Line: View {
        let row: BoardRow

        var body: some View {
            HStack(spacing: 8) {
                Text("\(row.rank)").font(Fonts.mono()).foregroundStyle(row.rank == 1 ? Theme.gold : Theme.muted)
                    .frame(width: 14, alignment: .trailing)
                Text(row.me ? "\(row.name) (나)" : row.name).font(Fonts.body())
                    .foregroundStyle(row.rank == 1 ? Theme.gold : Theme.cream)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Self.signed(row.net)).font(Fonts.mono()).foregroundStyle(Self.color(row.net))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Rectangle().strokeBorder(row.me ? Theme.gold : .clear, lineWidth: 2))
        }

        /// +4,200 / -600 / 0. 색만으로 구분하지 않게 부호를 같이 쓴다
        static func signed(_ n: Int64) -> String {
            (n > 0 ? "+" : "") + n.formatted(.number)
        }

        static func color(_ n: Int64) -> Color {
            n > 0 ? Theme.green : n < 0 ? Theme.dim : Theme.muted
        }
    }
}

private extension View {
    /// 자리는 차지하되 안 보이고 눌리지 않게
    func hidden(_ hide: Bool) -> some View {
        opacity(hide ? 0 : 1)
            .allowsHitTesting(!hide)
            .accessibilityHidden(hide)
    }
}
