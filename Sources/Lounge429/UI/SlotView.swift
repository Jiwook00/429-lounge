import LoungeNet
import SwiftUI

struct SlotView: View {
    @Bindable var machine: SlotMachine
    let chips: Int
    var golden: Int = 0
    /// VIP HOUR (429 리셋 전): 릴에 429가 더 많다
    var vip: Bool = false
    var onBack: () -> Void = {}

    /// 기계 안쪽 폭 292 = 릴 92 × 3 + 간격 8 × 2
    private static let reelWidth: CGFloat = 92
    private static let rowHeight: CGFloat = 40
    private static let rowsPerSecond = 12.0

    var body: some View {
        let now = Date()
        let busy = machine.isSpinning(at: now) || fxActive(at: now)
        TimelineView(.animation(minimumInterval: busy ? 1.0 / 30 : 0.1)) { context in
            let t = context.date
            VStack(spacing: 10) {
                topBar
                machineView(t)
                resultLine(t)
                paytable
                StakePicker(stake: $machine.stake, useGolden: $machine.useGolden,
                            chips: chips, golden: golden, disabled: machine.isSpinning(at: t))
                spinButton(t)
                bottomBar
            }
            .onChange(of: machine.startedAt) { _, start in
                GameAudio.shared.play(.lever, at: start)
            }
            .onChange(of: machine.turningReels(at: t), initial: true) { _, count in
                GameAudio.shared.setReelsTurning(count)
            }
            .onChange(of: (0..<3).compactMap(machine.stopTime).last { $0 <= t }) { _, stop in
                GameAudio.shared.play(.reel, at: stop)
            }
            .onChange(of: machine.finishAt.flatMap { $0 <= t ? $0 : nil }) { _, end in
                if !machine.glitched.isEmpty { GameAudio.shared.play(.reel, at: end) }
                if let tier = machine.tier {
                    let sound: GameAudio.Effect = switch tier {
                    case .win: .win
                    case .big: .bigWin
                    case .jackpot: .jackpot
                    }
                    GameAudio.shared.play(sound, at: end)
                }
            }
            .padding(14)
            .frame(width: LoungeView.width)
            .background(Theme.bg)
            .overlay {
                if let tier = machine.tier, let r = machine.result, let end = machine.finishAt {
                    WinBurst(tier: tier, amount: r.payout, start: end.addingTimeInterval(0.05),
                             origin: UnitPoint(x: 0.5, y: 0.26))
                }
            }
        }
        .foregroundStyle(Theme.cream)
    }

    private func fxActive(at now: Date) -> Bool {
        guard let tier = machine.tier, let end = machine.finishAt else { return false }
        return now < end.addingTimeInterval(tier.duration + 0.1)
    }

    /// 승리 연출 중인지 (릴이 다 멈춘 뒤 tier.duration 동안)
    private func celebrating(_ t: Date) -> WinTier? {
        guard let tier = machine.tier, let end = machine.finishAt, t >= end,
              t < end.addingTimeInterval(tier.duration) else { return nil }
        return tier
    }

    // MARK: - Top / bottom

    private var topBar: some View {
        HStack {
            Button(action: onBack) {
                Text("‹ 라운지").font(Fonts.small()).foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            GameSoundButton()
            Spacer()
            Text("429 슬롯").font(Fonts.bold()).foregroundStyle(Theme.neon).glow(Theme.neon)
            Spacer()
            if vip {
                Text("VIP · 429↑").font(Fonts.small()).foregroundStyle(Theme.gold).glow(Theme.gold)
            } else {
                Text("SOLO").font(Fonts.small()).foregroundStyle(Theme.muted)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 6) {
            PixelView(sprite: Sprites.chip, scale: 1)
            Text((machine.pendingChips ?? chips).formatted(.number)).font(Fonts.mono()).foregroundStyle(Theme.gold)
            if golden > 0 {
                PixelView(sprite: Sprites.goldChip, scale: 1).padding(.leading, 4)
                Text("×\(golden)").font(Fonts.mono()).foregroundStyle(Theme.gold)
            }
            Spacer()
            if let m = machine.message {
                Text(m).font(Fonts.small()).foregroundStyle(Theme.neon)
            }
        }
    }

    // MARK: - 기계

    private func machineView(_ t: Date) -> some View {
        let spinning = machine.isSpinning(at: t)
        let party = celebrating(t)
        let secs = t.timeIntervalSinceReferenceDate
        let chase = Int(secs / (spinning ? 0.08 : 0.5)) % 3
        let strobeOn = party.map { $0 != .win && Neon.strobe(at: secs) == .on } ?? false
        let bulbs = MarqueeBulbs.count(for: 292)
        return VStack(spacing: 8) {
            MarqueeBulbs(count: bulbs, offset: chase, allOn: strobeOn)
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in reel(i, t) }
            }
            .overlay { payline(party, secs) }
            MarqueeBulbs(count: bulbs, offset: chase + 1, allOn: strobeOn)
        }
        .padding(10)
        .pixelBox(fill: Theme.panel, border: party == nil ? Theme.gold : Theme.neon)
        .glow(party == nil ? .clear : Theme.neon)
    }

    private func payline(_ party: WinTier?, _ secs: TimeInterval) -> some View {
        let lit = party != nil && Neon.strobe(at: secs) == .on
        return Rectangle()
            .strokeBorder(lit ? Theme.neon : Theme.gold.opacity(0.55), lineWidth: 2)
            .frame(height: Self.rowHeight)
            .glow(lit ? Theme.neon : .clear, strong: true)
            .allowsHitTesting(false)
    }

    private func reel(_ i: Int, _ t: Date) -> some View {
        let strip = SlotSymbol.reelStrip
        let n = strip.count
        let rowH = Self.rowHeight
        var symbols: [SlotSymbol]
        var offset: CGFloat = -rowH
        var jitter: CGFloat = 0
        var dimmed = false
        var glitch = false

        switch machine.reelState(i, at: t) {
        case .spinning:
            // 굴러가는 중: 아래로 흐른다. 정수 pt 단위로만 움직인다.
            let started = machine.startedAt ?? t
            let p = t.timeIntervalSince(started) * Self.rowsPerSecond + Double(i) * 0.37
            let base = Int(p)
            offset = -rowH + ((p - Double(base)) * rowH).rounded()
            symbols = (0..<4).map { strip[(base + 3 - $0 + i * 5) % n] }
            dimmed = true
        case .stopped(let center, let settled):
            let (above, below) = SlotSymbol.neighbors(of: center)
            symbols = [below, above, center, below]
            if settled < 0.08 { offset += 4 } // 멈춘 직후 4pt 튕김
        case .glitching(let center):
            let (above, below) = SlotSymbol.neighbors(of: center)
            symbols = [below, above, center, below]
            jitter = CGFloat((Int(t.timeIntervalSinceReferenceDate * 30) % 3) - 1) * 2
            glitch = true
        }

        return VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { row in
                PixelView(sprite: symbols[row].sprite, scale: 3)
                    .frame(width: Self.reelWidth, height: rowH)
                    .opacity(row == 2 && !dimmed ? 1 : 0.4)
            }
        }
        .offset(x: jitter, y: offset)
        .frame(width: Self.reelWidth, height: rowH * 3, alignment: .top)
        .overlay { if glitch { GlitchNoise(seed: i, time: t) } }
        .clipped()
        .background(Theme.bg)
        .overlay(Rectangle().strokeBorder(glitch ? Theme.neon : Theme.line, lineWidth: 2))
    }

    // MARK: - 결과 / 배당표 / 버튼

    /// 결과를 HTTP 응답처럼: [상태 코드] [설명]
    private func resultLine(_ t: Date) -> some View {
        let (code, codeColor, detail, detailColor) = response(t)
        return HStack(spacing: 8) {
            Text(code).font(Fonts.bold()).foregroundStyle(codeColor).glow(codeColor == Theme.muted ? .clear : codeColor)
            Text(detail).font(Fonts.body()).foregroundStyle(detailColor)
        }
        .frame(maxWidth: .infinity, minHeight: 18)
    }

    private func response(_ t: Date) -> (String, Color, String, Color) {
        if machine.startedAt == nil { return ("GET /slot", Theme.muted, "체리 2개부터 200 OK", Theme.muted) }
        if machine.isGlitching(at: t) { return ("500", Theme.neon, "Internal Server Error · 재시도…", Theme.neon) }
        if machine.isSpinning(at: t) { return ("102", Theme.cyan, "Processing…", Theme.muted) }
        guard let r = machine.result else { return (" ", Theme.muted, " ", Theme.muted) }
        let won = "+\(r.payout.formatted(.number))"
        switch r.multiplier {
        case 429...: return ("429", Theme.neon, "JACKPOT · \(won)", Theme.gold)
        case 10...: return ("201 Created", Theme.gold, "\(won) · \(combo(r)) ×\(r.multiplier)", Theme.gold)
        case 2...: return ("200 OK", Theme.green, "\(won) · \(combo(r)) ×\(r.multiplier)", Theme.gold)
        case 1: return ("304", Theme.cyan, "Not Modified · 본전", Theme.cream)
        default: return ("404", Theme.dim, "Not Found · 꽝", Theme.muted)
        }
    }

    private func combo(_ r: SlotResult) -> String {
        let s = r.reels.compactMap(SlotSymbol.init(rawValue:))
        if Set(s).count == 1, let first = s.first { return Array(repeating: first.label, count: 3).joined(separator: " ") }
        if s.filter({ $0 == .cherry }).count == 2 { return "체리 2개" }
        if s.filter({ $0 == .s429 }).count == 2 { return "429 두 개" }
        return s.map(\.label).joined(separator: " ")
    }

    /// 배당표 3×3. count 0 = 개수 표시 없이 설명만 (기믹 심볼)
    private var paytable: some View {
        let rows: [[(SlotSymbol, Int, String)]] = [
            [(.s429, 3, "×429"), (.seven, 3, "×50"), (.bar, 3, "×20")],
            [(.bell, 3, "×10"), (.cherry, 3, "×5"), (.cherry, 2, "×3")],
            [(.s429, 2, "×3"), (.s429, 1, "×1 본전"), (.err500, 0, "리스핀")],
        ]
        return Grid(horizontalSpacing: 4, verticalSpacing: 6) {
            ForEach(0..<rows.count, id: \.self) { r in
                GridRow {
                    ForEach(0..<rows[r].count, id: \.self) { c in
                        let (symbol, count, pay) = rows[r][c]
                        let jackpot = symbol == .s429 && count == 3
                        HStack(spacing: 3) {
                            PixelView(sprite: symbol.sprite, scale: 1)
                            if count > 0 {
                                Text("\(count)").font(Fonts.small()).foregroundStyle(Theme.dim)
                            }
                            Text(pay).font(Fonts.small())
                                .foregroundStyle(jackpot ? Theme.gold : count == 0 ? Theme.muted : Theme.cream)
                                .glow(jackpot ? Theme.gold : .clear)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(8)
        .pixelBox()
    }

    private func spinButton(_ t: Date) -> some View {
        let spinning = machine.isSpinning(at: t)
        let golden = machine.useGolden && self.golden > 0
        let affordable = golden || Int64(machine.pendingChips ?? chips) >= machine.stake
        let enabled = !spinning && affordable
        return Button {
            Task { await machine.spin() }
        } label: {
            HStack(spacing: 8) {
                Text("SPIN").font(Fonts.bold(2))
                Text(golden ? "황금 칩" : "\(machine.stake.formatted(.number))칩").font(Fonts.small())
            }
            .foregroundStyle(Theme.cream)
            .frame(maxWidth: .infinity, minHeight: 44)
            .pixelBox(fill: Theme.neon, border: Theme.neonDeep)
            .glow(enabled ? Theme.neon : .clear)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .keyboardShortcut(.space, modifiers: [])
    }
}

/// 500 글리치: 릴 위로 번쩍이는 도트 노이즈 (프레임마다 바뀜)
private struct GlitchNoise: View {
    let seed: Int
    let time: Date

    var body: some View {
        Canvas { ctx, size in
            let frame = Int(time.timeIntervalSinceReferenceDate * 20)
            let colors = [Theme.neon, Theme.cyan, Theme.cream, Theme.green]
            for k in 0..<16 {
                var x = UInt64(truncatingIfNeeded: frame &* 2654435761 &+ k &* 40503 &+ seed &* 9973)
                x ^= x << 13; x ^= x >> 7; x ^= x << 17
                let px = Double(x % UInt64(max(1, size.width - 8))).rounded()
                let py = Double((x >> 16) % UInt64(max(1, size.height - 2))).rounded()
                let w = Double(2 + (x >> 32) % 10)
                let color = colors[Int((x >> 40) % UInt64(colors.count))]
                ctx.fill(Path(CGRect(x: px, y: py, width: w, height: 2)), with: .color(color.opacity(0.85)))
            }
        }
        .allowsHitTesting(false)
    }
}
