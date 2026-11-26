import LoungeNet
import SwiftUI

/// 429 드롭 (ADR-0018). 공을 쏘면 핀에 튕기며 내려가 배수 칸에 들어간다.
/// 값은 `PlinkoTable`이 틱 단위로 재생한 결과를 그대로 그린다.
struct PlinkoView: View {
    @Bindable var table: PlinkoTable
    let chips: Int
    var golden: Int = 0
    var onBack: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressing = false

    /// 점멸 위상 (동작 줄이기면 늘 켠 상태)
    private func phase(_ t: Int, _ half: Int) -> Bool { table.reduced || t % (half * 2) < half }

    private var boardW: CGFloat { CGFloat(PlinkoTable.width) }
    private var boardH: CGFloat { CGFloat(PlinkoTable.height) }

    var body: some View {
        let t = table.tick
        let fever = table.fever != nil
        let flashBg = fever && !table.reduced && t % 8 < 4
        let shake = table.shakeOffset
        VStack(spacing: 10) {
            topBar(fever: fever)
            board(t: t, fever: fever)
            controls
            dropButton
            bottomBar
        }
        .offset(x: CGFloat(shake.x), y: CGFloat(shake.y))
        .padding(14)
        .frame(width: LoungeView.width)
        .background(flashBg ? Theme.panel : Theme.bg)
        .foregroundStyle(Theme.cream)
        .onChange(of: reduceMotion, initial: true) { _, value in table.reduced = value }
    }

    // MARK: - 상단 / 하단

    private func topBar(fever: Bool) -> some View {
        HStack {
            Button(action: onBack) {
                Text("‹ 라운지").font(Fonts.small()).foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            GameSoundButton()
            Spacer()
            Text("429 드롭").font(Fonts.bold()).foregroundStyle(Theme.neon).glow(Theme.neon)
            Spacer()
            Text(fever ? "FEVER" : "공 \(table.inFlight)/\(PlinkoTable.maxBalls)")
                .font(Fonts.mono())
                .foregroundStyle(fever ? Theme.neon : Theme.muted)
        }
        .frame(height: 20)
    }

    private var bottomBar: some View {
        HStack(spacing: 6) {
            PixelView(sprite: Sprites.chip, scale: 1)
            Text(table.shown(chips: chips).formatted(.number)).font(Fonts.mono()).foregroundStyle(Theme.gold)
            if let pop = table.walletPop {
                Text(pop.text).font(Fonts.bold()).foregroundStyle(Theme.green)
            }
            Spacer()
            if let m = table.message {
                Text(m).font(Fonts.small()).foregroundStyle(Theme.neon)
            } else if golden > 0 {
                PixelView(sprite: Sprites.goldChip, scale: 1)
                Text("×\(golden)").font(Fonts.mono()).foregroundStyle(Theme.gold)
            }
        }
        .frame(height: 16)
    }

    // MARK: - 보드

    private func board(t: Int, fever: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in drawBoard(ctx, t: t, fever: fever) }
                .frame(width: boardW, height: boardH)
            if !fever { laneButtons }
            pocket(t: t)
            ForEach(0..<13, id: \.self) { i in bucket(i, t: t, fever: fever) }
            ForEach(table.pops) { pop in popView(pop, t: t) }
            if let f = table.fever { feverBar(f, t: t) }
            if table.streak >= 2, !fever {
                Text("\(table.streak)연속")
                    .font(Fonts.small()).foregroundStyle(Theme.cyan)
                    .position(x: boardW - 6 - 30, y: 8)
            }
            if let reel = table.reel { reelView(reel, t: t).position(x: 96 + 60 - 2, y: 146 + 20) }
            if let banner = table.banner { bannerView(banner, t: t) }
        }
        .frame(width: boardW, height: boardH)
        .clipped()
        .padding(2)
        .background(fever ? Theme.outline : Theme.panel)
        .overlay(Rectangle().strokeBorder(boardBorder(t: t, fever: fever), lineWidth: 2))
        .glow(fever || table.beam != nil ? (phase(t, 3) ? Theme.neon : Theme.gold) : .clear)
    }

    private func boardBorder(t: Int, fever: Bool) -> Color {
        if fever { return phase(t, 3) ? Theme.neon : Theme.gold }
        return table.beam != nil ? Theme.neon : Theme.line
    }

    private func tone(_ tone: PlinkoTone) -> Color {
        switch tone {
        case .cream: Theme.cream
        case .gold: Theme.gold
        case .goldLight: Theme.goldLight
        case .neon: Theme.neon
        case .cyan: Theme.cyan
        case .muted: Theme.muted
        case .dim: Theme.dim
        case .green: Theme.green
        }
    }

    private func drawBoard(_ ctx: GraphicsContext, t: Int, fever: Bool) {
        func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: Color) {
            ctx.fill(Path(CGRect(x: x, y: y, width: w, height: h)), with: .color(color))
        }
        // 맥스 빔
        if let beam = table.beam {
            rect(beam.x - 10, 0, 20, PlinkoTable.bucketY, Theme.neon.opacity(phase(t, 2) ? 0.24 : 0.12))
        }
        // 핀
        for r in 0..<12 {
            for j in stride(from: -(r + 2), through: r + 2, by: 2) {
                let pin = PinPos(r: r, j: j)
                if pin == PlinkoTable.pocketPin { continue }
                let x = PlinkoTable.x(j), y = PlinkoTable.y(r)
                var size = 2
                var color = fever ? Theme.goldDark : Theme.dim
                let guide = r == 0 && abs(j) == 2
                if PlinkoTable.goldPins.contains(pin) { size = 4; color = Theme.gold }
                else if PlinkoTable.splitPins.contains(pin) { size = 4; color = Theme.cyan }
                else if guide { size = 4; color = Theme.muted }
                if let f = table.pinFlash[pin] { size += 2; color = tone(f.tone) }
                rect(x - size / 2, y - size / 2, size, size, color)
                if guide {
                    // 안쪽으로 미는 턱
                    rect(j < 0 ? x + 2 : x - 4, y - 1, 2, 2, color)
                }
            }
        }
        // 꼬리
        for b in table.balls {
            let color: Color = b.grade == .perfect || b.golden ? Theme.gold : b.split ? Theme.cyan : Theme.muted
            for (k, q) in b.trail.enumerated() {
                rect(q.x - 2, q.y - 2, 4, 4, color.opacity([0.5, 0.3, 0.15][k]))
            }
        }
        // 공
        for b in table.balls {
            let p = table.position(of: b)
            drawSprite(ctx, Sprites.plinkoBall(golden: b.golden), x: p.x - 3, y: p.y - 3)
        }
        // 동전 파편
        for c in table.coins {
            drawSprite(ctx, Sprites.plinkoCoin, x: Int(c.x.rounded()) - 3, y: Int(c.y.rounded()) - 3)
        }
    }

    private func drawSprite(_ ctx: GraphicsContext, _ sprite: PixelSprite, x: Int, y: Int) {
        for (row, line) in sprite.rows.enumerated() {
            for (col, ch) in line.enumerated() {
                guard let color = sprite.palette[ch] else { continue }
                ctx.fill(Path(CGRect(x: x + col, y: y + row, width: 1, height: 1)), with: .color(color))
            }
        }
    }

    private var laneButtons: some View {
        ForEach([-1, 0, 1], id: \.self) { l in
            let on = table.lane == l
            Button { if !table.charging { table.lane = l } } label: {
                PixelView(sprite: Sprites.laneArrow(on ? Theme.neon : Theme.dim), scale: 2)
                    .frame(width: 20, height: 12)
                    .glow(on ? Theme.neon : .clear, radius: 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(l == -1 ? .leftArrow : l == 1 ? .rightArrow : .downArrow, modifiers: [])
            .accessibilityLabel(l == -1 ? "왼쪽 레인" : l == 1 ? "오른쪽 레인" : "가운데 레인")
            .position(x: CGFloat(PlinkoTable.x(2 * l)), y: 10)
        }
    }

    /// 스타트 포켓 [429]. GOOD·PERFECT 공이 날아오면 위가 열린다 (전동 튤립)
    private func pocket(t: Int) -> some View {
        let flashing = table.pinFlash[PlinkoTable.pocketPin] != nil
        let on = flashing && phase(t, 2)
        let open = table.pocketOpen
        let rim = open && phase(t, 2) ? Theme.goldLight : Theme.gold
        return Text("429")
            .font(Fonts.small())
            .foregroundStyle(on ? Theme.outline : Theme.gold)
            .frame(width: 28, height: 14)
            .background(on ? Theme.gold : Theme.outline)
            .overlay(Rectangle().strokeBorder(rim, lineWidth: 2))
            .overlay(alignment: .top) {
                if open { Rectangle().fill(Theme.outline).frame(width: 12, height: 2) }
            }
            .overlay(alignment: .topLeading) {
                if open { Rectangle().fill(Theme.goldLight).frame(width: 2, height: 6).offset(x: -4, y: -4) }
            }
            .overlay(alignment: .topTrailing) {
                if open { Rectangle().fill(Theme.goldLight).frame(width: 2, height: 6).offset(x: 4, y: -4) }
            }
            .glow(flashing || open ? Theme.gold : .clear)
            .position(x: CGFloat(PlinkoTable.cx), y: CGFloat(PlinkoTable.y(6)))
    }

    private func bucketTone(_ i: Int, fever: Bool) -> Color {
        if fever { return i == 0 || i == 12 ? Theme.neon : Theme.gold }
        switch i {
        case 0, 12: return Theme.neon
        case 1, 11: return Theme.gold
        case 2, 3, 9, 10: return Theme.cream
        case 4, 8: return Theme.muted
        default: return Theme.dim
        }
    }

    private func bucket(_ i: Int, t: Int, fever: Bool) -> some View {
        let tc = bucketTone(i, fever: fever)
        let f = table.bucketFlash[i]
        let edge = i == 0 || i == 12 || i == 1 || i == 11
        let hot = f.map { $0.tier == .big || $0.tier == .max } ?? false
        let label = fever ? PlinkoTable.mt(PlinkoTable.multipliers[i] * 2) : PlinkoTable.bucketLabels[i]
        return Text(label)
            .font(Fonts.small())
            .foregroundStyle(f != nil ? Theme.outline : tc)
            .frame(width: 20, height: 20)
            .background(f != nil ? tc : Theme.outline)
            .overlay(Rectangle().strokeBorder(f != nil || edge ? tc : Theme.line, lineWidth: 2))
            .glow(hot ? tc : .clear)
            .position(x: CGFloat(PlinkoTable.x(2 * i - 12)), y: CGFloat(PlinkoTable.bucketY + 10))
    }

    private func popView(_ pop: PlinkoTable.Pop, t: Int) -> some View {
        let age = t - pop.born
        let half = max(12, pop.text.count * 3 + 4)
        let x = min(max(pop.x, half), PlinkoTable.width - half)
        return Text(pop.text)
            .font(Fonts.bold())
            .foregroundStyle(tone(pop.tone))
            .shadow(color: Theme.outline, radius: 0, x: 1, y: 1)
            .opacity(age > 10 ? 0.5 : 1)
            .fixedSize()
            .position(x: CGFloat(x), y: CGFloat(pop.y - age + 6))
    }

    private func feverBar(_ f: PlinkoTable.FeverRun, t: Int) -> some View {
        let c = phase(t, 3) ? Theme.neon : Theme.gold
        return HStack {
            Text("FEVER ×2 · 공 \(f.spawned)/\(f.n)")
            Spacer()
            Text("+" + PlinkoTable.fmt(f.total))
        }
        .font(Fonts.bold())
        .foregroundStyle(c)
        .glow(c)
        .padding(.horizontal, 6)
        .frame(width: boardW, height: 12)
        .position(x: boardW / 2, y: 9)
    }

    private func reelView(_ r: PlinkoTable.Reel, t: Int) -> some View {
        var title = "스타트 포켓"
        var titleTone = Theme.gold
        if r.reach, t >= r.stops[1], t < r.stops[2] {
            title = "리치!"
            titleTone = phase(t, 2) ? Theme.neon : Theme.gold
        }
        if r.doneAt != nil {
            title = r.fever ? "FEVER!" : "아쉽다 · 20% 환급"
            titleTone = r.fever ? Theme.neon : Theme.muted
        }
        return VStack(spacing: 4) {
            Text(title).font(Fonts.small()).foregroundStyle(titleTone)
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    let stopped = t >= r.stops[i]
                    let sym = stopped ? r.result[i] : PlinkoTable.reelSymbols[(t + i * 2) % PlinkoTable.reelSymbols.count]
                    let hot = stopped && r.doneAt != nil && r.fever
                    let slow = i == 2 && r.reach && !stopped
                    Text(sym)
                        .font(Fonts.bold())
                        .foregroundStyle(hot ? Theme.outline : stopped ? (sym == "429" ? Theme.neon : Theme.cream) : Theme.dim)
                        .frame(width: 32, height: 22)
                        .background(hot ? Theme.gold : Theme.panel)
                        .overlay(Rectangle().strokeBorder(hot ? Theme.gold : slow ? Theme.neon : Theme.line, lineWidth: 2))
                        .glow(slow ? Theme.neon : .clear)
                        .offset(y: stopped ? 0 : (t % 2 == 0 ? -2 : 2))
                }
            }
        }
        .padding(4)
        .frame(width: 120)
        .background(Theme.outline)
        .overlay(Rectangle().strokeBorder(Theme.gold, lineWidth: 2))
        .glow(Theme.gold)
    }

    private func bannerView(_ b: PlinkoTable.Banner, t: Int) -> some View {
        let blink = phase(t, 3)
        let col: Color = switch b.kind {
        case .max: blink ? Theme.neon : Theme.gold
        case .fever: blink ? Theme.neon : Theme.cream
        default: Theme.gold
        }
        return VStack(spacing: 4) {
            Text(b.big).font(Fonts.bold(2)).foregroundStyle(col).glow(col)
            Text(b.sub).font(Fonts.small()).foregroundStyle(Theme.cream)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.outline)
        .overlay(Rectangle().strokeBorder(col, lineWidth: 2))
        .glow(col, radius: 6, strong: true)
        .position(x: boardW / 2, y: 64 + 24)
    }

    // MARK: - 조작

    private var controls: some View {
        VStack(spacing: 8) {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !table.charging)) { context in
                gaugeRow(power: table.power(at: context.date))
            }
            stakeRow
        }
        .padding(8)
        .pixelBox()
    }

    private func gaugeRow(power: Int) -> some View {
        let t = table.tick
        let charging = table.charging
        let cell = PlinkoGauge.cell(power: power)
        let lit = cell + 1
        let perfectFlash = t <= table.perfectUntil
        let grade: PlinkoDrop.Grade = charging ? PlinkoGauge.grade(power: power) : (t <= table.gradeUntil ? table.gradeShown : .none)
        return HStack(spacing: 6) {
            Text("파워").font(Fonts.small()).foregroundStyle(Theme.muted).frame(width: 24, alignment: .leading)
            HStack(spacing: 1) {
                ForEach(0..<PlinkoGauge.cells, id: \.self) { i in
                    let pz = i == 20
                    let gz = (18...22).contains(i) && !pz
                    let base: Color = pz ? Theme.goldDark : gz ? Theme.bulbOff : Theme.line
                    let litColor: Color = perfectFlash ? Theme.gold : charging ? (pz ? Theme.gold : gz ? Theme.goldDark : Theme.neon) : Theme.dim
                    Rectangle().fill(i < lit ? litColor : base).frame(width: 8, height: 10)
                }
            }
            .glow(perfectFlash ? Theme.gold : .clear, radius: 2)
            Spacer(minLength: 0)
            Text(grade == .good ? "GOOD" : "PERFECT")
                .font(Fonts.small())
                .foregroundStyle(grade == .perfect ? Theme.gold : grade == .good ? Theme.cream : Theme.goldDark)
                .glow(grade == .perfect ? Theme.gold : .clear)
                .frame(width: 40, alignment: .trailing)
        }
        .frame(height: 12)
    }

    private var stakeRow: some View {
        let goldenSelected = table.useGolden && golden > 0
        let shown = table.shown(chips: chips)
        return HStack(spacing: 4) {
            ForEach(PlinkoTable.stakes, id: \.self) { s in
                let selected = !goldenSelected && table.stake == s
                let affordable = Int64(shown) >= s
                Button { table.stake = s; table.useGolden = false } label: {
                    Text(s.formatted(.number))
                        .font(Fonts.mono())
                        .foregroundStyle(selected ? Theme.bg : Theme.cream)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .pixelBox(fill: selected ? Theme.gold : Theme.panel, border: selected ? Theme.gold : Theme.line)
                }
                .buttonStyle(.plain)
                .disabled(table.charging)
                .opacity(affordable ? 1 : 0.4)
            }
            if golden > 0 {
                Button { table.useGolden.toggle() } label: {
                    HStack(spacing: 3) {
                        PixelView(sprite: Sprites.goldChip, scale: 1)
                        Text("×\(golden)").font(Fonts.mono())
                    }
                    .foregroundStyle(goldenSelected ? Theme.bg : Theme.gold)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .pixelBox(fill: goldenSelected ? Theme.gold : Theme.goldBg, border: Theme.gold)
                }
                .buttonStyle(.plain)
                .disabled(table.charging)
            }
            Button { table.auto.toggle() } label: {
                HStack(spacing: 4) {
                    Rectangle().fill(table.auto ? Theme.cyan : Theme.line).frame(width: 6, height: 6)
                    Text("AUTO").font(Fonts.body())
                }
                .foregroundStyle(table.auto ? Theme.cyan : Theme.muted)
                .frame(width: 64, height: 24)
                .pixelBox(fill: Theme.outline, border: table.auto ? Theme.cyan : Theme.line)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - DROP

    private var dropButton: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !table.charging)) { context in
            let reason = table.blockReason(chips: chips, golden: golden)
            let charging = table.charging
            let power = table.power(at: context.date)
            let grade = PlinkoGauge.grade(power: power)
            let blocked = reason != nil && !charging
            let fill: Color = charging ? Theme.gold : reason != nil ? Theme.line : Theme.neon
            let label = charging ? "떼면 발사!" : "DROP"
            let sub = charging
                ? "파워 \(power / 10)" + (grade == .perfect ? " · 지금!" : grade == .good ? " · 거의!" : "")
                : reason ?? (table.auto ? "AUTO · 레인 유지 · 파워 랜덤"
                    : table.useGolden && golden > 0 ? "꾹 눌렀다 떼기 · 황금 칩" : "꾹 눌렀다 떼기 · \(table.stake)칩")
            // 글자 줄 높이를 고정해서 24pt 제목과 10pt 설명이 버튼 안에서 잘리지 않게
            VStack(spacing: 4) {
                Text(label).font(Fonts.bold(2)).lineLimit(1).frame(height: 28)
                Text(sub).font(Fonts.small()).lineLimit(1).frame(height: 14)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
            .foregroundStyle(charging ? Theme.outline : reason != nil ? Theme.dim : Theme.cream)
            .frame(maxWidth: .infinity, minHeight: 54)
            .pixelBox(fill: fill, border: charging ? Theme.goldDark : reason != nil ? Theme.line : Theme.neonDeep)
            .glow(blocked ? .clear : fill)
            .offset(y: charging ? 2 : 0)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard !pressing else { return }
                        pressing = true
                        table.press(at: v.time)
                    }
                    .onEnded { v in
                        pressing = false
                        table.release(at: v.time)
                    }
            )
            .allowsHitTesting(!blocked)
            .opacity(blocked ? 0.6 : 1)
            .accessibilityLabel("DROP")
            .accessibilityAddTraits(.isButton)
        }
    }
}
