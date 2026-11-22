import LoungeNet
import SwiftUI

/// 미니 룰렛 테이블 (ADR-0015, DESIGN.md §9). 펠트(고정 휠 + 상태) → 베팅 판 → 이번 판 회원 → 칩 고르기 → 지갑.
/// 칸을 누르면 바로 걸린다. 다른 회원 칩은 칸 위에 사람 수만, 이름과 금액은 이름 칩 줄에서.
struct RouletteView: View {
    @Bindable var table: RouletteTable
    let chips: Int
    var golden: Int = 0
    var onBack: () -> Void = {}
    /// 스냅샷용: 설명 카드를 펼친 상태로
    var showHelp = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var help = false

    // 펠트 안쪽 298pt: 0 칸 34 + 숫자 64 × 4, 바깥 칸 48 × 6 (간격 2, 정수 좌표만)
    private static let zeroWidth: CGFloat = 34
    private static let numberWidth: CGFloat = 64
    private static let outsideWidth: CGFloat = 48
    /// 판 위 숫자 배치: 위 줄부터 (3 6 9 12 / 2 5 8 11 / 1 4 7 10)
    private static let rows = [[3, 6, 9, 12], [2, 5, 8, 11], [1, 4, 7, 10]]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let now = context.date
            let phase = table.phase(at: now)
            VStack(spacing: 10) {
                topBar(phase)
                felt(phase, now: now)
                crowd(phase).frame(height: 52, alignment: .top)
                bottomArea(phase).frame(height: 76, alignment: .top)
                walletBar
            }
            .onChange(of: table.betAcceptedAt) { _, accepted in
                GameAudio.shared.play(.betChip, at: accepted)
            }
            .onChange(of: revealSound(phase)) { _, cue in
                if let cue { GameAudio.shared.play(cue, at: now) }
            }
            .padding(14)
            .frame(width: LoungeView.width)
            .background(Theme.bg)
            .overlay { winOverlay(phase) }
            .overlay(alignment: .top) {
                if help || showHelp {
                    RouletteHelp { help = false }
                        .padding(.top, 44)
                        .padding(.horizontal, 14)
                }
            }
        }
        .foregroundStyle(Theme.cream)
    }

    // MARK: - 판 흐름

    private func canBet(_ phase: RouletteTable.Phase) -> Bool {
        switch phase {
        case .idle, .betting: !table.busy
        default: false
        }
    }

    private var result: Int? {
        if let r = table.round?.result { return r }
        return nil
    }

    /// 결과가 화면에 나온 순간의 소리 (이겼으면 금화, 0이면 돌려받음)
    private func revealSound(_ phase: RouletteTable.Phase) -> GameAudio.Effect? {
        guard case .result(let n) = phase, let payout = table.myPayout else { return nil }
        if n == 0 { return .push }
        guard payout > table.myStaked else { return nil }
        return payout >= 1_000 ? .bigWin : .win
    }

    // MARK: - 위 / 아래 줄

    private func topBar(_ phase: RouletteTable.Phase) -> some View {
        let seated = phase == .idle ? 0 : table.players().count
        return HStack(spacing: 8) {
            Button(action: onBack) {
                Text("‹ 라운지").font(Fonts.small()).foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            GameSoundButton()
            Spacer()
            Text("미니 룰렛").font(Fonts.bold()).foregroundStyle(Theme.neon).glow(Theme.neon)
            Spacer()
            HStack(spacing: 4) {
                Rectangle().fill(seated > 0 ? Theme.green : Theme.muted).frame(width: 6, height: 6)
                Text(seated > 0 ? "TABLE · \(seated)명" : "TABLE · 비어 있음").font(Fonts.small())
            }
            .foregroundStyle(seated > 0 ? Theme.green : Theme.muted)
        }
    }

    private var walletBar: some View {
        HStack(spacing: 6) {
            PixelView(sprite: Sprites.chip, scale: 1)
            Text(chips.formatted(.number)).font(Fonts.mono()).foregroundStyle(Theme.gold)
            if golden > 0 {
                PixelView(sprite: Sprites.goldChip, scale: 1).padding(.leading, 4)
                Text("×\(golden)").font(Fonts.mono()).foregroundStyle(Theme.gold)
            }
            Spacer()
            if let m = table.message {
                Text(m).font(Fonts.small()).foregroundStyle(Theme.neon).lineLimit(1)
            }
            Button { help.toggle() } label: {
                Text("?").font(Fonts.bold()).foregroundStyle(help ? Theme.bg : Theme.gold)
                    .frame(width: 20, height: 20)
                    .pixelBox(fill: help ? Theme.gold : Theme.goldBg, border: Theme.gold)
            }
            .buttonStyle(.plain)
            .help("룰렛 방법")
        }
    }

    // MARK: - 펠트

    private func felt(_ phase: RouletteTable.Phase, now: Date) -> some View {
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                wheel(phase)
                feltInfo(phase)
                Spacer(minLength: 0)
            }
            .frame(height: 120)
            board(phase)
        }
        .padding(5)
        .pixelBox(fill: Theme.felt, border: Theme.gold)
        .overlay(alignment: .top) {
            if let at = table.closedAt, now < at.addingTimeInterval(3) { closedPopup.padding(.top, 150) }
        }
    }

    private func wheel(_ phase: RouletteTable.Phase) -> some View {
        let shown: Int? = if case .result(let n) = phase { n } else { nil }
        let spot = RouletteArt.ball(at: ballIndex(phase))
        return ZStack(alignment: .topLeading) {
            GridView(grid: RouletteArt.wheel(highlight: shown), scale: 2)
            PixelView(sprite: Sprites.marble, scale: 2)
                .offset(x: CGFloat(spot.x * 2), y: CGFloat(spot.y * 2))
        }
        .frame(width: 120, height: 120, alignment: .topLeading)
    }

    /// 공이 있는 휠 칸. 회전 중엔 직전 칸에서 출발해 세 바퀴 넘게 돌다 결과 칸에서 멈춘다 (점점 느리게, 칸 단위로)
    private func ballIndex(_ phase: RouletteTable.Phase) -> Int {
        let wheel = Roulette.wheel
        func index(_ n: Int) -> Int { wheel.firstIndex(of: n) ?? 0 }
        switch phase {
        case .idle, .betting:
            return index(table.restingNumber)
        case .result(let n):
            return index(n)
        case .spinning(let e):
            let start = index(table.state?.lastResult ?? 0)
            guard !reduceMotion else { return start }
            let target = result.map(index) ?? start
            let total = 3 * wheel.count + ((target - start) % wheel.count + wheel.count) % wheel.count
            let x = min(1, max(0, e / Roulette.spin))
            let eased = 1 - pow(1 - x, 3)
            return (start + Int((Double(total) * eased).rounded(.down))) % wheel.count
        }
    }

    @ViewBuilder
    private func feltInfo(_ phase: RouletteTable.Phase) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch phase {
            case .idle:
                Text("칩을 놓으면\n12초 뒤에 돌아요").font(Fonts.bold())
                lastLine
            case .betting(let left):
                let secs = Int(left.rounded(.up))
                Text("\(secs)").font(Fonts.mono(2))
                    .foregroundStyle(secs < 4 ? Theme.neon : Theme.gold)
                    .glow(secs < 4 ? Theme.neon : Theme.gold)
                if alone {
                    Text("혼자 앉았어요").font(Fonts.bold())
                    Text("기다리지 않고 돌려도 돼요").font(Fonts.small())
                } else {
                    Text("베팅 받는 중").font(Fonts.bold())
                    lastLine
                }
            case .spinning:
                Text("공 굴러가는 중").font(Fonts.bold())
                Text("마감 · \(table.players().count)명 \(totalStaked.formatted(.number))칩").font(Fonts.small())
            case .result(let n):
                Text("\(n)").font(Fonts.mono(2)).foregroundStyle(Theme.cream)
                    .padding(.horizontal, 6)
                    .pixelBox(fill: n == 0 ? Theme.felt : Roulette.red.contains(n) ? Theme.neonDeep : Theme.outline, border: Theme.gold)
                    .glow(Theme.gold)
                if n == 0 {
                    Text("무효 판").font(Fonts.bold())
                    Text("건 칩은 그대로 돌아가요").font(Fonts.small()).foregroundStyle(Theme.gold)
                } else {
                    Text(Roulette.describe(n).dropFirst().joined(separator: " · ")).font(Fonts.bold())
                    if let top = bigShot {
                        Text("이번 판 큰손 · \(top)").font(Fonts.small()).foregroundStyle(Theme.gold)
                    }
                }
            }
        }
        .foregroundStyle(Theme.cream)
    }

    @ViewBuilder
    private var lastLine: some View {
        if let n = table.lastResult(at: .now) {
            Text("직전 판 · \(n == 0 ? "0 무효" : "\(n) \(Roulette.red.contains(n) ? "빨강" : "검정")")").font(Fonts.small())
        }
    }

    private var alone: Bool {
        let players = table.players()
        return players.count == 1 && players[0].me
    }

    private var totalStaked: Int64 { table.bets.reduce(0) { $0 + $1.staked } }

    /// 이번 판에서 가장 많이 딴 회원 (딴 사람이 있을 때만)
    private var bigShot: String? {
        guard let top = table.players().filter({ ($0.net ?? 0) > 0 }).max(by: { ($0.net ?? 0) < ($1.net ?? 0) }) else { return nil }
        return top.me ? "나" : top.name
    }

    private var closedPopup: some View {
        VStack(spacing: 4) {
            Text("이번 판은 마감됐어요").font(Fonts.bold()).foregroundStyle(Theme.neon)
            Text("칩은 빠지지 않았어요 · 결과가 나오면 다음 판").font(Fonts.small()).foregroundStyle(Theme.cream)
        }
        .padding(10)
        .frame(width: 268)
        .pixelBox(fill: Theme.panel, border: Theme.neon)
        .background(alignment: .topLeading) { Rectangle().fill(Theme.outline).offset(x: 4, y: 4) }
        .glow(Theme.neon)
    }

    // MARK: - 베팅 판

    private func board(_ phase: RouletteTable.Phase) -> some View {
        let marks = table.marks()
        let open = canBet(phase)
        let dim = !open && phase != .idle && { if case .result = phase { false } else { true } }()
        return VStack(spacing: 4) {
            HStack(spacing: 2) {
                cell(nil, label: "0", width: Self.zeroWidth, height: 82, phase: phase, mark: nil, open: false)
                VStack(spacing: 2) {
                    ForEach(Self.rows, id: \.self) { row in
                        HStack(spacing: 2) {
                            ForEach(row, id: \.self) { n in
                                let spot = Roulette.Spot.number(n)
                                cell(spot, label: "\(n)", width: Self.numberWidth, height: 26, phase: phase, mark: marks[spot], open: open)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 2) {
                ForEach(Roulette.Spot.outside, id: \.self) { spot in
                    cell(spot, label: spot.label, width: Self.outsideWidth, height: 34, phase: phase, mark: marks[spot], open: open)
                }
            }
        }
        .opacity(dim ? 0.6 : 1)
    }

    private func cellFill(_ spot: Roulette.Spot?) -> Color {
        switch spot {
        case nil: Theme.felt
        case .number(let n): Roulette.red.contains(n) ? Theme.neonDeep : Theme.outline
        case .red: Theme.neonDeep
        case .black: Theme.outline
        default: Theme.felt
        }
    }

    private func cell(_ spot: Roulette.Spot?, label: String, width: CGFloat, height: CGFloat,
                      phase: RouletteTable.Phase, mark: RouletteTable.Mark?, open: Bool) -> some View {
        let shown: Int? = if case .result(let n) = phase { n } else { nil }
        let won = shown.map { n in spot.map { $0.wins(n) } ?? (n == 0) } ?? false
        let lost = shown != nil && !won
        let goldenOff = table.useGolden && golden > 0 && spot.map { !$0.outside } ?? true
        let outside = spot?.outside ?? false
        let content = Group {
            if spot == nil {
                VStack(spacing: 2) {
                    Text(label).font(Fonts.bold())
                    Text("무효").font(Fonts.small()).opacity(0.7)
                }
            } else if outside {
                VStack(spacing: 2) {
                    Text(label).font(Fonts.body())
                    markers(mark).frame(height: 12)
                }
            } else {
                HStack(spacing: 3) {
                    Text(label).font(Fonts.bold())
                    Spacer(minLength: 0)
                    markers(mark)
                }
                .padding(.horizontal, 3)
            }
        }
        .foregroundStyle(Theme.cream)
        .frame(width: width, height: height)
        .pixelBox(fill: cellFill(spot), border: won ? Theme.gold : Theme.feltLine)
        .modifier(GlowIf(on: won))
        .opacity(lost ? 0.45 : goldenOff && open ? 0.35 : 1)

        return Group {
            if let spot {
                Button { Task { await table.bet(spot) } } label: { content }
                    .buttonStyle(.plain)
                    .disabled(!open || goldenOff)
            } else {
                content
            }
        }
    }

    @ViewBuilder
    private func markers(_ mark: RouletteTable.Mark?) -> some View {
        if let m = mark {
            HStack(spacing: 2) {
                if m.mine > 0 || m.golden > 0 {
                    HStack(spacing: 2) {
                        GridView(grid: RouletteArt.chip(golden: m.mine == 0), scale: 2)
                        if m.mine > 0 {
                            Text(m.mine.formatted(.number)).font(Fonts.mono()).foregroundStyle(Theme.gold)
                        } else {
                            Text(m.golden > 1 ? "황금 \(m.golden)" : "황금").font(Fonts.small()).foregroundStyle(Theme.gold)
                        }
                    }
                    .padding(.horizontal, 2)
                    .background(Theme.outline)
                    .glow(Theme.gold)
                }
                if m.others > 0 {
                    HStack(spacing: 2) {
                        GridView(grid: RouletteArt.person, scale: 1)
                        Text("\(m.others)").font(Fonts.small())
                    }
                    .padding(.horizontal, 2)
                    .background(Theme.outline)
                }
            }
        }
    }

    // MARK: - 이번 판 회원

    private func crowd(_ phase: RouletteTable.Phase) -> some View {
        // 순수익은 공이 멈춘 뒤에만 (회전 중에 결과가 새지 않게)
        let players = phase == .idle ? [] : table.players(settled: { if case .result = phase { true } else { false } }())
        let goldenCount = players.reduce(0) { $0 + $1.golden }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                if players.isEmpty {
                    Text("아직 아무도 안 걸었어요")
                } else {
                    Text("\(players.count)명 · \(totalStaked.formatted(.number))칩\(goldenCount > 0 ? " + 황금 \(goldenCount)" : "")")
                }
                Spacer()
                if case .spinning = phase { Text("마감") }
                if case .result(0) = phase { Text("전부 돌려받음") }
            }
            .font(Fonts.small())
            .foregroundStyle(Theme.muted)
            nameChips(players)
        }
    }

    /// 이름 칩 최대 두 줄, 넘치면 +N명 (DESIGN.md §9 판 현황)
    private func nameChips(_ players: [RouletteTable.Player]) -> some View {
        let labels = players.map(chipText)
        let shown = ChipFit.visibleCount(labels, width: 312)
        let hidden = players.count - shown
        return FlowLayout {
            ForEach(Array(players.prefix(shown).enumerated()), id: \.offset) { i, p in nameChip(p, label: labels[i]) }
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

    private func chipText(_ p: RouletteTable.Player) -> String {
        "\(p.me ? "나" : p.name) \(amountText(p))"
    }

    private func amountText(_ p: RouletteTable.Player) -> String {
        if let net = p.net { return net > 0 ? "+\(net.formatted(.number))" : net < 0 ? net.formatted(.number) : "±0" }
        if p.staked == 0 { return "황금" }
        return p.staked.formatted(.number)
    }

    /// 나 먼저 골드 테두리 + 발광. 정산 뒤엔 딴 회원 초록, 잃은 회원 흐리게
    private func nameChip(_ p: RouletteTable.Player, label: String) -> some View {
        let net = p.net ?? 0
        let lost = p.net != nil && net < 0
        let color: Color = lost ? Theme.dim : net > 0 ? Theme.green : p.me ? Theme.gold : Theme.cream
        return Text(label)
            .font(Fonts.small())
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(p.me ? Theme.goldBg : Theme.bg)
            .overlay(Rectangle().strokeBorder(p.me ? Theme.gold : Theme.line, lineWidth: 2))
            .modifier(GlowIf(on: p.me))
    }

    // MARK: - 아래 영역

    @ViewBuilder
    private func bottomArea(_ phase: RouletteTable.Phase) -> some View {
        switch phase {
        case .idle, .betting:
            VStack(spacing: 6) {
                stakeRow(disabled: !canBet(phase))
                bettingInfo(phase)
            }
        case .spinning:
            if table.myBets.isEmpty {
                infoBox("다음 판을 기다리는 중", color: Theme.muted)
            } else {
                infoBox("\(myStakeText) 걸었어요 · 곧 나와요", color: Theme.gold, gold: true)
            }
        case .result(let n):
            if let payout = table.myPayout {
                resultBox(n, net: payout - table.myStaked)
            } else {
                infoBox("다음 판은 칩을 놓으면 12초 뒤에", color: Theme.muted)
            }
        }
    }

    private var myStakeText: String {
        let goldenCount = table.myBets.filter(\.golden).reduce(0) { $0 + Int($1.amount / 100) }
        let chips = table.myStaked
        switch (chips > 0, goldenCount > 0) {
        case (true, true): return "\(chips.formatted(.number)) + 황금 \(goldenCount)"
        case (false, true): return "황금 칩 \(goldenCount)"
        default: return chips.formatted(.number)
        }
    }

    private func stakeRow(disabled: Bool) -> some View {
        let goldenOn = table.useGolden && golden > 0
        return HStack(spacing: 6) {
            Text("칩").font(Fonts.body()).foregroundStyle(Theme.muted)
            ForEach(RouletteTable.stakes, id: \.self) { s in
                let selected = !goldenOn && table.stake == s
                let affordable = Int64(chips) >= s
                Button { table.stake = s; table.useGolden = false } label: {
                    Text(s.formatted(.number)).font(Fonts.mono())
                        .foregroundStyle(selected ? Theme.bg : Theme.cream)
                        .frame(width: 40, height: 26)
                        .pixelBox(fill: selected ? Theme.gold : Theme.bg, border: selected ? Theme.gold : Theme.line)
                }
                .buttonStyle(.plain)
                .disabled(!affordable)
                .opacity(affordable ? 1 : 0.4)
            }
            if golden > 0 {
                Button { table.useGolden.toggle() } label: {
                    HStack(spacing: 4) {
                        GridView(grid: RouletteArt.chip(golden: true), scale: 2)
                        Text("황금 ×\(golden)").font(Fonts.body())
                    }
                    .foregroundStyle(Theme.gold)
                    .padding(.horizontal, 6)
                    .frame(height: 26)
                    .pixelBox(fill: Theme.goldBg, border: goldenOn ? Theme.gold : Theme.line)
                    .modifier(GlowIf(on: goldenOn))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .opacity(disabled ? 0.6 : 1)
    }

    @ViewBuilder
    private func bettingInfo(_ phase: RouletteTable.Phase) -> some View {
        let left: Int? = if case .betting(let l) = phase { Int(l.rounded(.up)) } else { nil }
        let pick = table.useGolden && golden > 0 ? "황금 칩" : table.stake.formatted(.number)
        if table.useGolden && golden > 0 {
            infoBox("황금 칩은 바깥 칸에만 놓여요\(left.map { " · \($0)초" } ?? "")", color: Theme.gold, gold: true)
        } else if let left, !table.myBets.isEmpty {
            HStack(spacing: 6) {
                infoBox(alone ? "\(myStakeText) 걸었어요 · \(left)초" : "\(myStakeText) 걸었어요 · \(left)초 뒤 마감",
                        color: Theme.gold, gold: true)
                if alone {
                    Button { Task { await table.spin() } } label: {
                        Text("바로 돌리기").font(Fonts.bold())
                            .frame(width: 96, height: 40)
                            .pixelBox(fill: Theme.neon, border: Theme.neonDeep)
                            .glow(Theme.neon)
                    }
                    .buttonStyle(.plain)
                    .disabled(table.busy)
                }
            }
        } else {
            infoBox("칸을 누르면 \(pick)이 바로 걸려요\(left.map { " · \($0)초" } ?? "")", color: Theme.muted)
        }
    }

    private func resultBox(_ n: Int, net: Int64) -> some View {
        let hit = table.myBets.filter { $0.spot.wins(n) }.map(\.spot.label)
        let text = n == 0 ? "0 · 무효 판" : hit.isEmpty ? "\(n) · 이번엔 꽝" : "\(hit.joined(separator: " · ")) 맞힘"
        return VStack(spacing: 6) {
            HStack {
                Text(text).font(Fonts.body()).foregroundStyle(Theme.gold).lineLimit(1)
                Spacer()
                Text(net > 0 ? "+\(net.formatted(.number))" : net < 0 ? net.formatted(.number) : "±0")
                    .font(Fonts.mono(2))
                    .foregroundStyle(net > 0 ? Theme.green : net < 0 ? Theme.dim : Theme.cream)
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .pixelBox(fill: Theme.goldBg, border: Theme.gold)
            .glow(Theme.gold)
            Text(n == 0 && table.myBets.contains(where: \.golden) ? "황금 칩도 돌려받아요" : "다음 판은 칩을 놓으면 12초 뒤에")
                .font(Fonts.small()).foregroundStyle(Theme.muted)
        }
    }

    private func infoBox(_ text: String, color: Color, gold: Bool = false) -> some View {
        Text(text).font(Fonts.body()).foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: 40)
            .pixelBox(fill: gold ? Theme.goldBg : Theme.panel, border: gold ? Theme.gold : Theme.line)
    }

    // MARK: - 승리 연출

    @ViewBuilder
    private func winOverlay(_ phase: RouletteTable.Phase) -> some View {
        if case .result(let n) = phase, n != 0, let r = table.round, let payout = table.myPayout,
           payout > table.myStaked, let tier = WinTier(payout: payout) {
            WinBurst(tier: tier, amount: payout, start: table.local(r.betClosesAt).addingTimeInterval(Roulette.spin),
                     origin: UnitPoint(x: 0.72, y: 0.2))
        }
    }
}

private struct GlowIf: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on { content.glow(Theme.gold) } else { content }
    }
}
