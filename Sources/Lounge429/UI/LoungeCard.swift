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
        // 앞뒤 중 높은 쪽에 맞춰서 뒤집어도 팝오버 높이가 흔들리지 않게
        SameHeight {
            PresenceStrip(crowd: crowd, now: now, onFlip: flip)
                .hidden(face != .front || frame > 0)
            BoardCard(rows: board, onFlip: flip)
                .hidden(face != .back || frame > 0)
        }
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

/// 이번 주 큰손: 위 3명 + (그 밖이면) 내 줄. 순수익 = 지급액 - 건 칩, KST 월요일 00시에 새 장부
struct BoardCard: View {
    let rows: [BoardRow]?
    var onFlip: () -> Void = {}

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
            let shown = Self.lines(rows)
            if shown.isEmpty {
                Text("이번 주 첫 판은 아직이에요").font(Fonts.small()).foregroundStyle(Theme.dim)
            } else {
                VStack(spacing: 0) {
                    ForEach(shown) { Line(row: $0) }
                }
            }
        } else {
            Text("장부 넘기는 중…").font(Fonts.small()).foregroundStyle(Theme.dim)
        }
    }

    /// 늘 3줄까지: 내가 3위 안이면 위 3명, 밖이면 위 2명 + 내 줄 (순위 숫자가 건너뛰어서 사이가 있다는 게 보인다)
    static func lines(_ rows: [BoardRow]) -> [BoardRow] {
        let top = Array(rows.filter { $0.rank <= 3 }.prefix(3))
        guard let mine = rows.first(where: \.me), !top.contains(mine) else { return top }
        return Array(top.prefix(2)) + [mine]
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

/// 자식들을 겹쳐 놓고 가장 높은 자식의 높이로 맞춘다 (앞뒤 카드)
private struct SameHeight: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for s in subviews {
            s.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
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
