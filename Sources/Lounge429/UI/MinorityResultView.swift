import SwiftUI

/// 소수결 결과 화면: 내가 건 판이 정산된 뒤 소수결에 처음 들어오면 먼저 보여준다 (DESIGN.md §9 소수결)
/// 누가 뭘 골랐는지 + 내 손익. 이겼으면 금화 연출. 확인을 누르면 지금 판으로
struct MinorityResult {
    struct Pick: Hashable {
        let name: String
        let choice: Int
        let me: Bool
    }

    let question: String
    let options: (String, String)
    let picks: [Pick]
    /// 이긴 쪽 0 / 1. nil = 무효
    let winner: Int?
    let amount: Int64?
    let net: Int64

    var counts: (Int, Int) { (picks.filter { $0.choice == 0 }.count, picks.filter { $0.choice == 1 }.count) }
    var winnerLabel: String? { winner.map { $0 == 0 ? options.0 : options.1 } }
    /// 무효인 이유
    var voidReason: String {
        let c = counts
        if c.0 + c.1 < 3 { return "3명이 안 모였어요" }
        return c.0 == 0 || c.1 == 0 ? "전원 일치" : "동점"
    }
}

struct MinorityResultView: View {
    let result: MinorityResult
    var onDone: () -> Void = {}
    var onBack: () -> Void = {}
    /// 스냅샷용: 연출 시작 시각
    var shownAt: Date?

    @State private var appeared = Date()

    private static let boardWidth: CGFloat = LoungeView.width - 28 - 20

    var body: some View {
        VStack(spacing: 10) {
            topBar
            felt
            board
            mine
            Button(action: onDone) {
                Text("확인 · 지금 판 보기")
                    .font(Fonts.bold()).foregroundStyle(Theme.bg)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .pixelBox(fill: Theme.gold, border: Theme.goldDark)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: LoungeView.width)
        .background(Theme.bg)
        .foregroundStyle(Theme.cream)
        .overlay {
            // 이긴 판: 슬롯·홀짝과 같은 금화 연출
            if result.net > 0, let tier = WinTier(payout: result.net + (result.amount ?? 200)) {
                WinBurst(tier: tier, amount: result.net, start: shownAt ?? appeared, origin: UnitPoint(x: 0.5, y: 0.25))
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Text("‹ 라운지").font(Fonts.small()).foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            GameSoundButton()
            Spacer()
            Text("소수결 결과").font(Fonts.bold()).foregroundStyle(Theme.neon).glow(Theme.neon)
            Spacer()
            Text("‹ 라운지").font(Fonts.small()).hidden()
        }
    }

    /// 질문 + 이긴 쪽
    private var felt: some View {
        VStack(spacing: 6) {
            Text(result.question).font(Fonts.bold(2)).foregroundStyle(Theme.cream).lineLimit(1)
            if let w = result.winnerLabel {
                Text("\(w) 승!").font(Fonts.bold()).foregroundStyle(Theme.gold).glow(Theme.gold)
            } else {
                Text("무효 · \(result.voidReason)").font(Fonts.bold()).foregroundStyle(Theme.cream.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 84)
        .background(Theme.felt)
        .overlay(Rectangle().strokeBorder(Theme.feltLine, lineWidth: 2).padding(4))
        .pixelBox(fill: Theme.felt, border: Theme.gold)
    }

    /// 누가 뭘 골랐는지: 인원 · 줄다리기 바 · 이름 칩
    private var board: some View {
        let c = result.counts
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("\(result.options.0) \(c.0)명").font(Fonts.bold())
                    .foregroundStyle(result.winner == 1 ? Theme.dim : Theme.neon)
                Spacer()
                Text("\(result.options.1) \(c.1)명").font(Fonts.bold())
                    .foregroundStyle(result.winner == 0 ? Theme.dim : Theme.cream)
            }
            tugBar(c)
            FlowLayout {
                ForEach(sortedPicks, id: \.self) { chip($0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .pixelBox()
    }

    /// 나 먼저, 그다음 이긴 쪽
    private var sortedPicks: [MinorityResult.Pick] {
        result.picks.sorted { a, b in
            if a.me != b.me { return a.me }
            return (a.choice == result.winner) && (b.choice != result.winner)
        }
    }

    private func tugBar(_ c: (Int, Int)) -> some View {
        let total = max(c.0 + c.1, 1)
        let a = result.winner == nil ? Theme.dim : (result.winner == 0 ? Theme.neon : Theme.line)
        let b = result.winner == nil ? Theme.dim : (result.winner == 1 ? Theme.cream : Theme.line)
        return GeometryReader { g in
            let inner = g.size.width - 4 - 2
            HStack(spacing: 0) {
                Rectangle().fill(a).frame(width: (inner * Double(c.0) / Double(total)).rounded())
                Rectangle().fill(Theme.outline).frame(width: 2)
                Rectangle().fill(b)
            }
            .padding(2)
            .background(Theme.outline)
        }
        .frame(height: 14)
    }

    /// 이긴 쪽은 그 쪽 색(1번 네온, 2번 크림), 진 쪽·무효는 흐리게. 나는 골드 테두리
    private func chip(_ p: MinorityResult.Pick) -> some View {
        let won = result.winner == p.choice
        let fill: Color = won ? (p.choice == 0 ? Theme.neon : Theme.cream) : Theme.panel
        let text: Color = won ? (p.choice == 0 ? Theme.cream : Theme.bg) : Theme.dim
        let label = (p.me ? "나" : p.name) + " · " + (p.choice == 0 ? result.options.0 : result.options.1)
        return Text(label)
            .font(Fonts.small())
            .foregroundStyle(text)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(fill)
            .overlay(Rectangle().strokeBorder(p.me ? Theme.gold : (won ? fill : Theme.line), lineWidth: 2))
    }

    /// 내 손익 크게
    private var mine: some View {
        let net = result.net
        let figure = net > 0 ? "+\(net.formatted(.number))" : net < 0 ? "-\((-net).formatted(.number))" : "±0"
        let refunded = result.amount.map { "\($0.formatted(.number))칩" } ?? "건 칩을"
        let note = result.winner == nil ? "\(refunded) 돌려받았어요" : net > 0 ? "소수파였어요" : "다수파였어요"
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("나").font(Fonts.bold()).foregroundStyle(Theme.muted)
            Text(figure).font(Fonts.mono(2))
                .foregroundStyle(net > 0 ? Theme.gold : net < 0 ? Theme.dim : Theme.muted)
                .glow(net > 0 ? Theme.gold : .clear)
            Spacer()
            Text(note).font(Fonts.small()).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 44)
        .pixelBox(fill: net > 0 ? Theme.goldBg : Theme.panel, border: net > 0 ? Theme.gold : Theme.line)
    }
}
