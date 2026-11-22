import LoungeNet
import SwiftUI

struct OddEvenView: View {
    @Bindable var table: OddEvenTable
    let chips: Int
    var golden: Int = 0
    var onBack: () -> Void = {}

    /// 판 현황 박스 안쪽 폭: 팝오버 340 - 바깥 여백 28 - 박스 여백 20
    private static let boardWidth: CGFloat = LoungeView.width - 28 - 20

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let phase = table.phase(at: context.date)
            let board = board(for: phase)
            VStack(spacing: 10) {
                topBar
                felt(phase)
                boardView(board)
                controls(phase, board: board)
                bottomBar
            }
            .padding(14)
            .frame(width: LoungeView.width)
            .background(Theme.bg)
            .overlay { winOverlay(phase) }
        }
        .foregroundStyle(Theme.cream)
    }

    /// 내가 이긴 판: 구슬이 다 나온 순간부터 승리 연출
    @ViewBuilder
    private func winOverlay(_ phase: OddEvenTable.Phase) -> some View {
        if case .reveal(let r, _, _) = phase,
           let mine = table.lastBets.first(where: { $0.playerId == table.myID }),
           let payout = mine.payout, let tier = WinTier(payout: payout) {
            let shownAt = r.closesAt.addingTimeInterval(Double(r.marbles ?? 0) * 0.18 + 0.1)
            // 펠트 오른쪽 빈자리에서 터진다 (구슬과 홀/짝 글자를 가리지 않게)
            WinBurst(tier: tier, amount: payout, start: shownAt, origin: UnitPoint(x: 0.8, y: 0.2))
        }
    }

    private func board(for phase: OddEvenTable.Phase) -> BetBoard {
        if case .reveal(let r, _, _) = phase {
            return BetBoard(bets: table.lastBets, result: r.result, myID: table.myID, name: table.name)
        }
        return BetBoard(bets: table.bets, result: nil, myID: table.myID, name: table.name)
    }

    // MARK: - Top / bottom

    private var topBar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Text("‹ 라운지").font(Fonts.small()).foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            GameSoundButton()
            Spacer()
            Text("구슬 홀짝").font(Fonts.bold()).foregroundStyle(Theme.neon).glow(Theme.neon)
            Spacer()
            HStack(spacing: 4) {
                Rectangle().fill(Theme.green).frame(width: 6, height: 6)
                Text("\(table.room) · \(max(table.seats.count, 1))명").font(Fonts.small())
            }
            .foregroundStyle(Theme.green)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 6) {
            PixelView(sprite: Sprites.chip, scale: 1)
            Text(chips.formatted(.number)).font(Fonts.mono()).foregroundStyle(Theme.gold)
            if golden > 0 {
                PixelView(sprite: Sprites.goldChip, scale: 1).padding(.leading, 4)
                Text("×\(golden)").font(Fonts.mono()).foregroundStyle(Theme.gold)
            }
            Spacer()
            if let m = table.message {
                Text(m).font(Fonts.small()).foregroundStyle(Theme.neon)
            }
        }
    }

    // MARK: - Felt (게임판)

    private func felt(_ phase: OddEvenTable.Phase) -> some View {
        Group {
            switch phase {
            case .connecting:
                Text("테이블에 앉는 중…").font(Fonts.body())

            case .betting(let remaining):
                HStack(spacing: 14) {
                    PixelView(sprite: Sprites.bowl, scale: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        let hurry = remaining < 4
                        Text("\(Int(remaining.rounded(.up)))")
                            .font(Fonts.mono(2))
                            .foregroundStyle(hurry ? Theme.neon : Theme.gold)
                            .glow(hurry ? Theme.neon : Theme.gold)
                        Text("구슬은 홀일까 짝일까").font(Fonts.body())
                        if let l = table.last, let m = l.marbles, let r = l.result {
                            Text("직전 판 · \(m)개 \(r.label)").font(Fonts.small()).foregroundStyle(Theme.cream.opacity(0.75))
                        }
                    }
                }

            case .settling:
                HStack(spacing: 14) {
                    PixelView(sprite: Sprites.bowl, scale: 3)
                    Text("구슬 세는 중…").font(Fonts.body())
                }

            case .reveal(let r, let elapsed, let nextIn):
                let m = r.marbles ?? 0
                let shown = min(m, max(0, Int(elapsed / 0.18)))
                HStack(spacing: 16) {
                    marbleGrid(count: shown)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(shown)개").font(Fonts.mono())
                        if shown == m, let side = r.result {
                            let color = side == .odd ? Theme.neon : Theme.cream
                            Text("\(side.label)!").font(Fonts.bold(2)).foregroundStyle(color).glow(color, strong: true)
                        } else {
                            Text(" ").font(Fonts.bold(2))
                        }
                        Text("다음 판 \(Int(nextIn.rounded(.up)))초").font(Fonts.small()).foregroundStyle(Theme.cream.opacity(0.75))
                    }
                }

            case .waiting(let nextIn):
                HStack(spacing: 14) {
                    PixelView(sprite: Sprites.bowl, scale: 3)
                    Text("다음 판 \(Int(nextIn.rounded(.up)))초").font(Fonts.body())
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .background(Theme.felt)
        .overlay(Rectangle().strokeBorder(Theme.feltLine, lineWidth: 2).padding(4))
        .pixelBox(fill: Theme.felt, border: Theme.gold)
    }

    /// 구슬 최대 12개: 4열 × 3줄
    private func marbleGrid(count: Int) -> some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<4, id: \.self) { col in
                        PixelView(sprite: Sprites.marble, scale: 3)
                            .opacity(row * 4 + col < count ? 1 : 0)
                    }
                }
            }
        }
    }

    // MARK: - 판 현황

    private func boardView(_ b: BetBoard) -> some View {
        let revealing = b.result != nil
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                sideHeader(.odd, b)
                Spacer()
                if !revealing {
                    Text(b.isEmpty ? "첫 베팅을 기다리는 중" : "판돈 \(b.pot.formatted(.number))")
                        .font(Fonts.small()).foregroundStyle(Theme.muted)
                }
                Spacer()
                sideHeader(.even, b)
            }
            tugBar(b)
            HStack {
                sideFigure(.odd, b)
                Spacer()
                sideFigure(.even, b)
            }
            chipFlow(b)
        }
        .padding(10)
        .pixelBox()
    }

    private func sideHeader(_ side: Side, _ b: BetBoard) -> some View {
        let t = b.tally(side)
        let lost = b.result.map { $0 != side } ?? false
        let won = b.result == side
        let color = lost ? Theme.dim : (side == .odd ? Theme.neon : Theme.cream)
        return Text("\(side.label) \(t.count)명\(won ? " 승" : "")")
            .font(Fonts.bold())
            .foregroundStyle(color)
            .glow(side == .odd && !lost ? Theme.neon : .clear)
    }

    private func sideFigure(_ side: Side, _ b: BetBoard) -> some View {
        let t = b.tally(side)
        let text: String
        let color: Color
        switch b.result {
        case .some(let r) where r == side:
            text = "+\(t.payout.formatted(.number))"; color = Theme.green
        case .some:
            text = "-\(t.cost.formatted(.number))"; color = Theme.dim
        case .none:
            text = t.total.formatted(.number); color = side == .odd ? Theme.neon : Theme.cream
        }
        return Text(text).font(Fonts.mono()).foregroundStyle(color)
    }

    private func tugBar(_ b: BetBoard) -> some View {
        let oddLost = b.result == .even
        let evenLost = b.result == .odd
        let oddColor = b.isEmpty || oddLost ? Theme.line : Theme.neon
        let evenColor = b.isEmpty || evenLost ? Theme.line : Theme.cream
        return GeometryReader { g in
            let inner = g.size.width - 4 - 2
            let oddWidth = (inner * b.oddRatio).rounded()
            HStack(spacing: 0) {
                Rectangle().fill(oddColor).frame(width: oddWidth)
                    .glow(oddColor == Theme.neon ? Theme.neon : .clear)
                Rectangle().fill(Theme.outline).frame(width: 2)
                Rectangle().fill(evenColor)
            }
            .padding(2)
            .background(Theme.outline)
        }
        .frame(height: 14)
    }

    private func chipFlow(_ b: BetBoard) -> some View {
        let shown = ChipFit.visibleCount(b.chips.map(\.label), width: Self.boardWidth)
        let hidden = b.chips.count - shown
        return FlowLayout {
            ForEach(b.chips.prefix(shown)) { chip in
                chipView(chip)
            }
            if hidden > 0 {
                Text(ChipFit.overflowLabel(hidden))
                    .font(Fonts.small())
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(Rectangle().strokeBorder(Theme.line, lineWidth: 2))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chipView(_ c: BetBoard.Chip) -> some View {
        let lost = c.won == false
        let fill: Color = lost ? Theme.panel : (c.side == .odd ? Theme.neon : Theme.cream)
        let text: Color = lost ? Theme.dim : (c.side == .odd ? Theme.cream : Theme.bg)
        let border: Color = c.mine ? Theme.gold : (lost ? Theme.line : fill)
        return Text(c.label)
            .font(Fonts.small())
            .foregroundStyle(text)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(fill)
            .overlay(Rectangle().strokeBorder(border, lineWidth: 2))
            .glow(c.mine ? Theme.gold : .clear)
    }

    // MARK: - Controls

    private func controls(_ phase: OddEvenTable.Phase, board: BetBoard) -> some View {
        let open: Bool = if case .betting = phase { true } else { false }
        let canBet = open && table.myBet == nil && !table.placing

        return VStack(spacing: 8) {
            stakeRow
            if case .reveal = phase {
                resultRow(board)
            } else if let mine = table.myBet {
                let left: String = if case .betting(let r) = phase { " · \(Int(r.rounded(.up)))초 뒤 공개" } else { "" }
                Text(mine.golden ? "황금 칩으로 \(mine.side.label)에 100\(left)" : "\(mine.side.label)에 \(mine.amount) 걸었어요\(left)")
                    .font(Fonts.small()).foregroundStyle(Theme.gold)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .pixelBox(fill: Theme.goldBg, border: Theme.gold)
            } else {
                HStack(spacing: 8) {
                    betButton(.odd, enabled: canBet)
                    betButton(.even, enabled: canBet)
                }
            }
        }
    }

    private var stakeRow: some View {
        StakePicker(stake: $table.stake, useGolden: $table.useGolden, chips: chips, golden: golden)
    }

    /// 결과 공개 중: 내 결과 + 이번 판 큰손
    private func resultRow(_ b: BetBoard) -> some View {
        let mine: String = {
            guard let bet = b.mine else { return "구경만 했어요" }
            if (bet.payout ?? 0) > 0 { return "나 +\((bet.payout ?? 0).formatted(.number))" }
            return bet.cost == 0 ? "나 ±0" : "나 -\(bet.cost.formatted(.number))"
        }()
        let won = (b.mine?.payout ?? 0) > 0
        let right: String = if let w = b.bigWinner { "이번 판 큰손 · \(w.name) +\(w.payout.formatted(.number))" }
            else if b.isEmpty { "아무도 안 걸었어요" } else { "이번 판은 하우스 승" }
        return HStack {
            Text(mine).font(Fonts.bold()).foregroundStyle(won ? Theme.gold : Theme.muted)
            Spacer()
            Text(right).font(Fonts.small()).foregroundStyle(Theme.gold.opacity(0.85))
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 38)
        .pixelBox(fill: Theme.goldBg, border: Theme.gold)
        .glow(won ? Theme.gold : .clear)
    }

    private func betButton(_ side: Side, enabled: Bool) -> some View {
        Button {
            Task { await table.place(side) }
        } label: {
            Text("\(side.label) \(side == .odd ? "ODD" : "EVEN")")
                .font(Fonts.bold())
                .foregroundStyle(side == .odd ? Theme.cream : Theme.bg)
                .frame(maxWidth: .infinity, minHeight: 38)
                .pixelBox(fill: side == .odd ? Theme.neon : Theme.cream,
                          border: side == .odd ? Theme.neonDeep : Theme.creamDeep)
                .glow(side == .odd && enabled ? Theme.neon : .clear)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}
