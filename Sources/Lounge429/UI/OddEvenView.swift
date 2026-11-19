import LoungeNet
import SwiftUI

struct OddEvenView: View {
    @Bindable var table: OddEvenTable
    let chips: Int
    var onBack: () -> Void = {}

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let phase = table.phase(at: context.date)
            VStack(spacing: 10) {
                topBar
                felt(phase)
                betList(phase)
                controls(phase)
                bottomBar
            }
            .padding(14)
            .frame(width: LoungeView.width)
            .background(Theme.bg)
        }
        .foregroundStyle(Theme.cream)
    }

    // MARK: - Top / bottom

    private var topBar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Text("‹ 라운지").font(Fonts.small()).foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("구슬 홀짝").font(Fonts.bold())
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
            Spacer()
            if let m = table.message {
                Text(m).font(Fonts.small()).foregroundStyle(Theme.neon)
            }
        }
    }

    // MARK: - Felt (게임판)

    private func felt(_ phase: OddEvenTable.Phase) -> some View {
        VStack(spacing: 8) {
            switch phase {
            case .connecting:
                Text("테이블에 앉는 중…").font(Fonts.body())

            case .betting(let remaining):
                HStack(alignment: .center, spacing: 14) {
                    PixelView(sprite: Sprites.bowl, scale: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Int(remaining.rounded(.up)))")
                            .font(Fonts.mono(2))
                            .foregroundStyle(remaining < 4 ? Theme.neon : Theme.gold)
                        Text("구슬은 홀일까 짝일까").font(Fonts.small())
                    }
                }
                if let l = table.last, let m = l.marbles {
                    Text("직전 판 · \(m)개 \(l.result!.label)").font(Fonts.small()).foregroundStyle(Theme.muted)
                }

            case .settling:
                PixelView(sprite: Sprites.bowl, scale: 3)
                Text("구슬 세는 중…").font(Fonts.small())

            case .reveal(let r, let elapsed, let nextIn):
                let m = r.marbles ?? 0
                let shown = min(m, max(0, Int(elapsed / 0.18)))
                marbleGrid(count: shown)
                HStack(spacing: 6) {
                    Text("\(shown)개").font(Fonts.mono())
                    if shown == m {
                        Text(r.result!.label)
                            .font(Fonts.bold(2))
                            .foregroundStyle(r.result == .odd ? Theme.neon : Theme.cream)
                            .shadow(color: Theme.neon.opacity(r.result == .odd ? 0.5 : 0), radius: 4)
                    }
                }
                Text("다음 판 \(Int(nextIn.rounded(.up)))초").font(Fonts.small()).foregroundStyle(Theme.muted)

            case .waiting(let nextIn):
                PixelView(sprite: Sprites.bowl, scale: 3)
                Text("다음 판 \(Int(nextIn.rounded(.up)))초").font(Fonts.small())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 112)
        .padding(.vertical, 8)
        .pixelBox(fill: Theme.felt, border: Color(hex: 0x1C6B52))
    }

    private func marbleGrid(count: Int) -> some View {
        let columns = Array(repeating: GridItem(.fixed(20), spacing: 2), count: 6)
        return LazyVGrid(columns: columns, spacing: 2) {
            ForEach(0..<12, id: \.self) { i in
                PixelView(sprite: Sprites.marble, scale: 3)
                    .opacity(i < count ? 1 : 0)
            }
        }
        .frame(width: 6 * 20 + 5 * 2)
    }

    // MARK: - Bets

    private func betList(_ phase: OddEvenTable.Phase) -> some View {
        let showingResult: Bool = if case .reveal = phase { true } else { false }
        let list = showingResult ? table.lastBets : table.bets
        return VStack(spacing: 4) {
            if list.isEmpty {
                Text(showingResult ? "아무도 안 걸었어요" : "아직 아무도 안 걸었어요")
                    .font(Fonts.small()).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(list.prefix(5), id: \.playerId) { bet in
                HStack(spacing: 8) {
                    Text(bet.playerId == table.myID ? "나" : table.name(bet.playerId))
                        .font(Fonts.body())
                        .foregroundStyle(bet.playerId == table.myID ? Theme.gold : Theme.cream)
                        .lineLimit(1)
                    Spacer()
                    sideTag(bet.side)
                    Text(bet.amount.formatted(.number)).font(Fonts.mono()).frame(width: 44, alignment: .trailing)
                    if showingResult, let payout = bet.payout {
                        Text(payout > 0 ? "+\(payout)" : "-\(bet.amount)")
                            .font(Fonts.mono())
                            .foregroundStyle(payout > 0 ? Theme.green : Theme.muted)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
        .padding(10)
        .frame(minHeight: 60, alignment: .top)
        .pixelBox()
    }

    private func sideTag(_ side: Side) -> some View {
        Text(side.label)
            .font(Fonts.small())
            .foregroundStyle(side == .odd ? Theme.cream : Theme.bg)
            .padding(.horizontal, 4)
            .background(side == .odd ? Theme.neon : Theme.cream)
    }

    // MARK: - Controls

    private func controls(_ phase: OddEvenTable.Phase) -> some View {
        let open: Bool = if case .betting = phase { true } else { false }
        let canBet = open && table.myBet == nil && !table.placing

        return VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(OddEvenTable.stakes, id: \.self) { s in
                    Button { table.stake = s } label: {
                        Text(s.formatted(.number))
                            .font(Fonts.mono())
                            .foregroundStyle(table.stake == s ? Theme.bg : Theme.cream)
                            .frame(maxWidth: .infinity, minHeight: 22)
                            .pixelBox(fill: table.stake == s ? Theme.gold : Theme.panel,
                                      border: table.stake == s ? Theme.gold : Theme.line)
                    }
                    .buttonStyle(.plain)
                    .disabled(Int64(chips) < s)
                    .opacity(Int64(chips) < s ? 0.4 : 1)
                }
            }
            if let mine = table.myBet {
                Text("\(mine.side.label)에 \(mine.amount) 걸었어요 · 결과를 기다리는 중")
                    .font(Fonts.small()).foregroundStyle(Theme.gold)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .pixelBox(fill: Color(hex: 0x2E2412), border: Theme.gold)
            } else {
                HStack(spacing: 8) {
                    betButton(.odd, enabled: canBet)
                    betButton(.even, enabled: canBet)
                }
            }
        }
    }

    private func betButton(_ side: Side, enabled: Bool) -> some View {
        Button {
            Task { await table.place(side) }
        } label: {
            Text("\(side.label) \(side == .odd ? "ODD" : "EVEN")")
                .font(Fonts.bold())
                .foregroundStyle(side == .odd ? Theme.cream : Theme.bg)
                .frame(maxWidth: .infinity, minHeight: 36)
                .pixelBox(fill: side == .odd ? Theme.neon : Theme.cream,
                          border: side == .odd ? Color(hex: 0xB82A40) : Color(hex: 0xBFB497))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}
