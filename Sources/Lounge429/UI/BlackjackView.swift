import LoungeNet
import SwiftUI

/// 블랙잭 테이블 (ADR-0014, DESIGN.md §9). 위 1컷 딜러 + 아래 2×2 좌석 4컷.
/// 4컷은 U자 테이블 하나를 잘라 본 것: 왼쪽 위 → 왼쪽 아래(나) → 오른쪽 아래 → 오른쪽 위가 레일을 따라 이어진다.
struct BlackjackView: View {
    @Bindable var table: BlackjackTable
    let chips: Int
    var golden: Int = 0
    var onBack: () -> Void = {}
    /// 스냅샷용: 설명 카드를 펼친 상태로
    var showHelp = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var help = false

    // MARK: - 배치 (테이블 영역 312×344 안의 좌표)

    static let tableSize = CGSize(width: 312, height: 344)
    static let dealerRect = CGRect(x: 0, y: 0, width: 312, height: 104)
    /// 화면 칸: 0 오른쪽 위, 1 오른쪽 아래, 2 왼쪽 아래(나), 3 왼쪽 위
    static let slotRects = [
        CGRect(x: 160, y: 112, width: 152, height: 112), CGRect(x: 160, y: 232, width: 152, height: 112),
        CGRect(x: 0, y: 232, width: 152, height: 112), CGRect(x: 0, y: 112, width: 152, height: 112),
    ]
    /// 내 차례: 내 컷이 왼쪽 아래 모서리를 붙인 채 커진다
    static let zoomRect = CGRect(x: 0, y: 148, width: 211, height: 196)
    private static let slotArt = [
        BlackjackArt.Seat(phi: 68, ax: 37, ay: 47, w: 74, h: 54), BlackjackArt.Seat(phi: 76, ax: 37, ay: 35, w: 74, h: 54),
        BlackjackArt.Seat(phi: 90, ax: 37, ay: 35, w: 74, h: 54), BlackjackArt.Seat(phi: 112, ax: 37, ay: 47, w: 74, h: 54),
    ]
    private static let zoomArt = BlackjackArt.Seat(phi: 90, ax: 34, ay: 44, w: 69, h: 64)
    /// 카드 슈에서 카드가 나오는 자리 (테이블 좌표, 카드 왼쪽 위)
    private static let shoe = CGPoint(x: 269, y: 49)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let now = context.date
            VStack(spacing: 10) {
                topBar(now)
                tableArea(now)
                bottomArea(now).frame(height: 76, alignment: .top)
                walletBar
            }
            .padding(14)
            .frame(width: LoungeView.width)
            .background(Theme.bg)
            .overlay { winOverlay(now) }
            // 설명 카드: 테이블과 아래 영역 위에 (위 줄과 지갑 줄은 그대로 보이게)
            .overlay(alignment: .top) {
                if help || showHelp {
                    BlackjackHelp { help = false }
                        .padding(.top, 44)
                        .padding(.horizontal, 14)
                }
            }
        }
        .foregroundStyle(Theme.cream)
    }

    // MARK: - 판 흐름

    private var round: BJRound? { table.round }
    private var dealEnd: Date { round.map { table.local($0.betClosesAt).addingTimeInterval(3) } ?? .distantPast }

    private func betting(_ now: Date) -> Bool { round?.phase == .betting && !table.idle(at: now) }
    private func dealerKey(_ i: Int) -> String { "d-\(i)" }

    /// 결과를 보여도 되는 때: 정산됐고 딜러 카드가 다 도착한 뒤
    private func resultsShown(_ now: Date) -> Bool {
        guard let r = round, r.phase == .done else { return false }
        return now >= table.settledAt("d", total: r.dealerCards.count).addingTimeInterval(0.4)
    }

    private func myTurn(_ now: Date) -> Bool {
        guard let r = round, let me = table.mySeat else { return false }
        return r.phase == .playing && r.turnSeat == me.seat && me.state == .playing && now >= dealEnd
            && now >= table.settledAt("s\(me.seat)", total: me.cards.count)
    }

    /// 확대 진행: 0 / ⅓ / ⅔ / 1 (12fps로 끊어서, 동작 줄이기면 바로 1)
    private func zoomStep(_ now: Date) -> Double {
        guard myTurn(now), let since = table.myTurnSince else { return 0 }
        if reduceMotion { return 1 }
        let e = now.timeIntervalSince(max(since, dealEnd))
        return e < 1.0 / 12 ? 1.0 / 3 : e < 2.0 / 12 ? 2.0 / 3 : 1
    }

    // MARK: - 위 / 아래 줄

    private func topBar(_ now: Date) -> some View {
        let seated = table.idle(at: now) ? 0 : table.seats.filter { !$0.bot }.count
        return HStack(spacing: 8) {
            Button(action: onBack) {
                Text("‹ 라운지").font(Fonts.small()).foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("블랙잭").font(Fonts.bold()).foregroundStyle(Theme.neon).glow(Theme.neon)
            Spacer()
            HStack(spacing: 4) {
                Rectangle().fill(Theme.green).frame(width: 6, height: 6)
                Text("TABLE · \(seated)/4").font(Fonts.small())
            }
            .foregroundStyle(Theme.green)
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
                Text(m).font(Fonts.small()).foregroundStyle(Theme.neon)
            }
            Button { help.toggle() } label: {
                Text("?").font(Fonts.bold()).foregroundStyle(help ? Theme.bg : Theme.gold)
                    .frame(width: 20, height: 20)
                    .pixelBox(fill: help ? Theme.gold : Theme.goldBg, border: Theme.gold)
            }
            .buttonStyle(.plain)
            .help("블랙잭 방법")
        }
    }

    // MARK: - 테이블

    private func tableArea(_ now: Date) -> some View {
        let zoom = zoomStep(now)
        let dimOthers = zoom > 0
        return ZStack(alignment: .topLeading) {
            panel(border: dealerBorder(now), glow: round?.phase == .dealer ? Theme.neon : nil, rect: Self.dealerRect) {
                dealerContent(now)
            }
            ForEach(0..<4, id: \.self) { slot in
                let seat = table.seats.first { table.slot(of: $0.seat) == slot }
                let isMine = slot == 2
                panel(border: seatBorder(seat, now: now), glow: seatGlow(seat, now: now), rect: Self.slotRects[slot]) {
                    seatContent(seat, slot: slot, zoomed: false, now: now)
                }
                .opacity(dimOthers && !isMine ? 0.4 : 1)
            }
            if zoom > 0, let me = table.mySeat {
                let rect = zoomedRect(zoom)
                panel(border: Theme.gold, glow: Theme.gold, rect: rect, shadow: true) {
                    seatContent(me, slot: 2, zoomed: true, now: now)
                        .frame(width: Self.zoomRect.width - 4, height: Self.zoomRect.height - 4)
                        .frame(width: rect.width - 4, height: rect.height - 4, alignment: .bottomLeading)
                        .clipped()
                }
            }
            flyingCards(now, zoomed: zoom >= 1)
            if showPopup(now) { betPopup(now) }
        }
        .frame(width: Self.tableSize.width, height: Self.tableSize.height, alignment: .topLeading)
    }

    private func zoomedRect(_ p: Double) -> CGRect {
        let a = Self.slotRects[2], b = Self.zoomRect
        let w = (a.width + (b.width - a.width) * p).rounded(), h = (a.height + (b.height - a.height) * p).rounded()
        return CGRect(x: 0, y: a.maxY - h, width: w, height: h)
    }

    /// 픽셀 테두리 컷. 안쪽은 잘라서 카드가 컷 밖으로 안 나간다
    private func panel<C: View>(border: Color, glow: Color?, rect: CGRect, shadow: Bool = false,
                                @ViewBuilder content: () -> C) -> some View {
        content()
            .frame(width: rect.width - 4, height: rect.height - 4, alignment: .topLeading)
            .clipped()
            .padding(2)
            .pixelBox(fill: Theme.panel, border: border)
            .background(alignment: .topLeading) {
                if shadow { Rectangle().fill(Theme.outline).offset(x: 4, y: 4) }
            }
            .modifier(OptionalGlow(color: glow))
            .offset(x: rect.minX, y: rect.minY)
    }

    private func dealerBorder(_ now: Date) -> Color {
        round?.phase == .dealer ? Theme.neon : Theme.gold
    }

    private func active(_ seat: BJSeat?, now: Date) -> Bool {
        guard let seat, let r = round else { return false }
        return r.phase == .playing && r.turnSeat == seat.seat && now >= dealEnd
    }

    private func seatBorder(_ seat: BJSeat?, now: Date) -> Color {
        if active(seat, now: now) { return Theme.neon }
        if let seat, resultsShown(now), !seat.bot, seat.playerId == table.myID, (seat.net ?? 0) > 0 { return Theme.gold }
        return Theme.line
    }

    private func seatGlow(_ seat: BJSeat?, now: Date) -> Color? {
        if active(seat, now: now) { return Theme.neon }
        if let seat, resultsShown(now), seat.playerId == table.myID, (seat.net ?? 0) > 0 { return Theme.gold }
        return nil
    }

    // MARK: - 딜러 컷

    private func dealerCards(_ now: Date) -> [(Int, CGPoint)] {
        guard let r = round else { return [] }
        return r.dealerCards.enumerated().compactMap { i, c in
            table.arrival(dealerKey(i)) <= now || reduceMotion ? (c, dealerCardOrigin(i)) : nil
        }
    }

    private func dealerCardOrigin(_ i: Int) -> CGPoint {
        CGPoint(x: ((72 + (Double(i) - 0.5) * 9 - 6.5).rounded()) * 2, y: ((33 - 8.5).rounded()) * 2)
    }

    private func dealerContent(_ now: Date) -> some View {
        let r = round
        let shown = dealerCards(now)
        let all = r.map { shown.count == $0.dealerCards.count } ?? false
        let total = BJCard.total(shown.map { BJCard($0.0) })
        let focus = r?.phase == .dealer
        return ZStack(alignment: .topLeading) {
            GridView(grid: BlackjackArt.dealer(focus: focus))
            ForEach(Array(shown.enumerated()), id: \.offset) { _, card in
                GridView(grid: BlackjackArt.card(card.0)).offset(x: card.1.x, y: card.1.y)
            }
            tag("딜러", color: Theme.muted).offset(x: 4, y: 4)
            if !(table.idle(at: now) || betting(now)) {
                Text("블랙잭 3:2 · 딜러는 17에서 멈춤")
                    .font(Fonts.small()).foregroundStyle(Theme.gold.opacity(0.7))
                    .frame(width: 308).offset(y: 86)
            }
            if !shown.isEmpty {
                let last = dealerCardOrigin(shown.count - 1)
                badge(total.value, soft: total.soft && !all, gold: false, big: false)
                    .offset(x: last.x + 32, y: 58)
            }
            if table.idle(at: now) || betting(now) {
                dealerCenter(now)
            }
            if let r, all, r.phase == .dealer || r.phase == .done, r.dealerCards.count > 1 {
                bubble(dealerLine(total.value, cards: r.dealerCards.count), quiet: false).offset(x: 196, y: 6)
            }
        }
    }

    private func dealerLine(_ t: Int, cards: Int) -> String {
        if t == 21 && cards == 2 { return "블랙잭" }
        return t > 21 ? "\(t) · 버스트" : "\(t) · 멈춤"
    }

    private func dealerCenter(_ now: Date) -> some View {
        VStack(spacing: 4) {
            if let r = round, betting(now) {
                let left = max(0, table.local(r.betClosesAt).timeIntervalSince(now))
                Text("\(Int(left.rounded(.up)))").font(Fonts.mono(2)).foregroundStyle(Theme.gold).glow(Theme.gold)
                Text("베팅 받는 중").font(Fonts.small())
            } else {
                Text("누가 걸면 10초 뒤에 딜").font(Fonts.small()).foregroundStyle(Theme.muted)
            }
        }
        .frame(width: 308).offset(y: betting(now) ? 46 : 56)
    }

    // MARK: - 좌석 컷

    private struct Geo {
        let art: BlackjackArt.Seat
        let scale: CGFloat
        let frame: BlackjackArt.Frame

        init(_ art: BlackjackArt.Seat, scale: CGFloat) {
            self.art = art
            self.scale = scale
            frame = BlackjackArt.frame(art)
        }

        func point(n: Double, t: Double = 0) -> CGPoint {
            CGPoint(x: frame.anchor.x + frame.n.dx * n + frame.t.dx * t, y: frame.anchor.y + frame.n.dy * n + frame.t.dy * t)
        }

        /// k번째 카드 왼쪽 위 (컷 안쪽 좌표, pt). 첫 두 장 가운데에서 레일을 따라 오른쪽으로
        func card(_ k: Int) -> CGPoint {
            let c = point(n: 17, t: (Double(k) - 0.5) * 8)
            return CGPoint(x: (c.x - 6.5).rounded() * scale, y: (c.y - 8.5).rounded() * scale)
        }

        func center(n: Double) -> CGPoint {
            let c = point(n: n)
            return CGPoint(x: (c.x * scale).rounded(), y: (c.y * scale).rounded())
        }
    }

    private func geo(slot: Int, zoomed: Bool) -> Geo {
        zoomed ? Geo(Self.zoomArt, scale: 3) : Geo(Self.slotArt[slot], scale: 2)
    }

    private func seatContent(_ seat: BJSeat?, slot: Int, zoomed: Bool, now: Date) -> some View {
        let g = geo(slot: slot, zoomed: zoomed)
        let inner = zoomed
            ? CGSize(width: Self.zoomRect.width - 4, height: Self.zoomRect.height - 4)
            : CGSize(width: Self.slotRects[slot].width - 4, height: Self.slotRects[slot].height - 4)
        let right = !zoomed && slot < 2
        let focus = !zoomed && active(seat, now: now) && seat?.playerId != table.myID
        return ZStack(alignment: .topLeading) {
            GridView(grid: BlackjackArt.felt(g.art, focus: focus), scale: g.scale)
            if let seat {
                seatHand(seat, g: g, inner: inner, zoomed: zoomed, now: now)
                nameTag(seat, inner: inner, right: right)
                seatBubble(seat, inner: inner, right: right, now: now)
            } else {
                emptySeat(slot: slot, inner: inner, right: right, now: now)
            }
        }
    }

    @ViewBuilder
    private func seatHand(_ seat: BJSeat, g: Geo, inner: CGSize, zoomed: Bool, now: Date) -> some View {
        let prefix = "s\(seat.seat)"
        let shown = seat.cards.enumerated().filter { i, _ in reduceMotion || table.arrival("\(prefix)-\(i)") <= now }
        let all = shown.count == seat.cards.count
        let total = BJCard.total(shown.map { BJCard($0.element) })
        let stamp = stamp(seat, all: all, now: now)
        if seat.amount > 0 || seat.golden {
            let chips = BlackjackArt.chips(stacks: seat.doubled ? 2 : 1)
            let c = g.center(n: 5)
            GridView(grid: chips, scale: g.scale)
                .offset(x: c.x - (CGFloat(chips.width) * g.scale / 2).rounded(), y: c.y - 4 * g.scale)
        }
        ForEach(shown, id: \.offset) { i, code in
            let p = g.card(i)
            GridView(grid: BlackjackArt.card(code), scale: g.scale).offset(x: p.x, y: p.y)
        }
        if !shown.isEmpty, stamp == nil {
            let c = g.center(n: 30)
            badge(total.value, soft: total.soft, gold: total.value == 21, big: zoomed)
                .position(x: c.x, y: c.y)
        }
        if let stamp {
            let c = g.center(n: 17)
            stampView(stamp, big: zoomed).position(x: c.x, y: c.y)
            if resultsShown(now), let net = seat.net {
                money(net).position(x: c.x, y: c.y + (zoomed ? 34 : 24))
            }
        } else if resultsShown(now), let net = seat.net {
            let c = g.center(n: 17)
            money(net).position(x: c.x, y: c.y + 20)
        }
    }

    private enum Stamp: String {
        case blackjack = "BLACKJACK", bj = "BJ", bust = "BUST", win = "WIN", push = "PUSH"
    }

    private func stamp(_ seat: BJSeat, all: Bool, now: Date) -> Stamp? {
        guard all, !seat.cards.isEmpty else { return nil }
        if resultsShown(now), let result = seat.result {
            switch result {
            case .blackjack: return .blackjack
            case .win: return .win
            case .push: return .push
            case .lose: return seat.state == .bust ? .bust : nil
            }
        }
        if seat.state == .bust { return .bust }
        if seat.state == .blackjack {
            let at = table.settledAt("s\(seat.seat)", total: seat.cards.count)
            return now < at.addingTimeInterval(2.5) ? .blackjack : .bj
        }
        return nil
    }

    private func stampView(_ s: Stamp, big: Bool) -> some View {
        let (rx, ry, fill, edge, text): (Int, Int, Ink, Ink, Color) = switch s {
        case .blackjack: (30, 12, .gold, .goldDark, Theme.bg)
        case .bj: (14, 9, .gold, .goldDark, Theme.bg)
        case .bust: (22, 12, .neon, .neonDeep, Theme.cream)
        case .win: (20, 12, .gold, .goldDark, Theme.bg)
        case .push: (18, 10, .creamDeep, .dim, Theme.bg)
        }
        let label = Text(s.rawValue).font(Fonts.bold()).foregroundStyle(text)
        return ZStack {
            GridView(grid: BlackjackArt.burst(rx: rx, ry: ry, fill: fill, edge: edge), scale: 2)
            if s == .win || s == .blackjack { label.glow(Theme.gold) } else { label }
        }
    }

    private func money(_ net: Int64) -> some View {
        let text = net > 0 ? "+\(net.formatted(.number))" : net < 0 ? "-\((-net).formatted(.number))" : "±0"
        let color = net > 0 ? Theme.green : net < 0 ? Theme.dim : Theme.muted
        return Text(text).font(Fonts.mono()).foregroundStyle(color)
            .padding(.horizontal, 3)
            .background(Theme.outline)
            .overlay(Rectangle().strokeBorder(Theme.line, lineWidth: 2))
    }

    private func badge(_ value: Int, soft: Bool, gold: Bool, big: Bool) -> some View {
        let text = soft && value < 21 ? "\(value - 10)/\(value)" : "\(value)"
        return Text(text)
            .font(big ? Fonts.mono(2) : Fonts.mono())
            .foregroundStyle(gold ? Theme.gold : Theme.cream)
            .padding(.horizontal, 3)
            .background(Theme.outline)
            .overlay(Rectangle().strokeBorder(gold ? Theme.gold : Theme.line, lineWidth: 2))
    }

    private func tag(_ text: String, color: Color, border: Color = Theme.line, fill: Color = Theme.bg) -> some View {
        Text(text).font(Fonts.body()).foregroundStyle(color)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(fill)
            .overlay(Rectangle().strokeBorder(border, lineWidth: 2))
            .fixedSize()
    }

    @ViewBuilder
    private func nameTag(_ seat: BJSeat, inner: CGSize, right: Bool) -> some View {
        let mine = seat.playerId != nil && seat.playerId == table.myID
        HStack(spacing: 2) {
            if seat.bot {
                Text("AI").font(Fonts.small()).foregroundStyle(Theme.bg)
                    .padding(.horizontal, 3).padding(.vertical, 2).background(Theme.dim)
            }
            if mine {
                tag("\(seat.name) (나)", color: Theme.gold, border: Theme.gold, fill: Theme.goldBg)
            } else {
                tag(seat.name, color: seat.bot ? Theme.muted : Theme.cream)
            }
        }
        .fixedSize()
        .frame(width: inner.width - 8, alignment: right ? .trailing : .leading)
        .offset(x: 4, y: inner.height - 22)
    }

    @ViewBuilder
    private func emptySeat(slot: Int, inner: CGSize, right: Bool, now: Date) -> some View {
        let mine = slot == 2 && table.mySeat == nil
        tag(mine ? "나" : "빈 자리", color: mine ? Theme.gold : Theme.dim, border: mine ? Theme.gold : Theme.line,
            fill: mine ? Theme.goldBg : Theme.bg)
            .frame(width: inner.width - 8, alignment: right ? .trailing : .leading)
            .offset(x: 4, y: inner.height - 22)
        if !mine, betting(now) || table.idle(at: now) {
            Text("딜 때 AI가 앉아요").font(Fonts.small()).foregroundStyle(Theme.muted)
                .frame(width: inner.width).offset(y: 36)
        }
    }

    /// 마지막 행동 말풍선: 처음 본 때부터, 그 손 카드가 다 도착하고 1.4초 뒤까지
    @ViewBuilder
    private func seatBubble(_ seat: BJSeat, inner: CGSize, right: Bool, now: Date) -> some View {
        if let seen = table.actions[seat.seat] {
            let done = table.settledAt("s\(seat.seat)", total: seat.cards.count)
            let until = max(seen.at, done).addingTimeInterval(1.4)
            if now >= seen.at, now < until {
                let text: String = switch seen.action {
                case .hit: (seat.bot && seat.state == .stood && now >= done) ? "스탠드" : "히트!"
                case .stand: "스탠드"
                case .double: "더블!"
                case .timeout: "…스탠드"
                }
                bubble(text, quiet: !active(seat, now: now))
                    .frame(width: inner.width - 12, alignment: right ? .trailing : .leading)
                    .offset(x: 6, y: inner.height - 52)
            }
        }
    }

    private func bubble(_ text: String, quiet: Bool) -> some View {
        let fill = quiet ? Theme.creamDeep : Theme.cream
        return Text(text).font(Fonts.bold()).foregroundStyle(Theme.outline)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(fill)
            .overlay(Rectangle().strokeBorder(Theme.outline, lineWidth: 2))
            .overlay(alignment: .bottomLeading) {
                GridView(grid: BlackjackArt.tail(fill: quiet ? .creamDeep : .cream), scale: 2)
                    .offset(x: 10, y: 6)
            }
            .fixedSize()
    }

    // MARK: - 날아가는 카드 (컷 사이 틈에선 안 보인다)

    private func flyingCards(_ now: Date, zoomed: Bool) -> some View {
        var flights: [(code: Int, from: CGPoint, to: CGPoint, scale: CGFloat, p: Double)] = []
        if !reduceMotion, let r = round {
            func add(_ code: Int, key: String, to: CGPoint, scale: CGFloat) {
                let end = table.arrival(key), start = end.addingTimeInterval(-BlackjackTable.flight)
                guard now >= start, now < end else { return }
                let t = now.timeIntervalSince(start) / BlackjackTable.flight
                flights.append((code, Self.shoe, to, scale, 1 - pow(1 - t, 3)))
            }
            for (i, c) in r.dealerCards.enumerated() {
                let o = dealerCardOrigin(i)
                add(c, key: dealerKey(i), to: CGPoint(x: o.x + 2, y: o.y + 2), scale: 2)
            }
            for seat in table.seats {
                let slot = table.slot(of: seat.seat)
                let big = zoomed && slot == 2
                let rect = big ? Self.zoomRect : Self.slotRects[slot]
                let g = geo(slot: slot, zoomed: big)
                for (i, c) in seat.cards.enumerated() {
                    let o = g.card(i)
                    add(c, key: "s\(seat.seat)-\(i)", to: CGPoint(x: rect.minX + 2 + o.x, y: rect.minY + 2 + o.y), scale: g.scale)
                }
            }
        }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(flights.enumerated()), id: \.offset) { _, f in
                GridView(grid: BlackjackArt.card(f.code), scale: f.scale)
                    .offset(x: (f.from.x + (f.to.x - f.from.x) * f.p).rounded(),
                            y: (f.from.y + (f.to.y - f.from.y) * f.p).rounded())
            }
        }
        .frame(width: Self.tableSize.width, height: Self.tableSize.height, alignment: .topLeading)
        .mask(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(([Self.dealerRect] + Self.slotRects + (zoomed ? [Self.zoomRect] : [])).enumerated()), id: \.offset) { _, rect in
                    Rectangle().frame(width: rect.width - 4, height: rect.height - 4).offset(x: rect.minX + 2, y: rect.minY + 2)
                }
            }
            .frame(width: Self.tableSize.width, height: Self.tableSize.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }

    // MARK: - 베팅 팝업 (말풍선)

    private func showPopup(_ now: Date) -> Bool {
        guard table.mySeat == nil || table.idle(at: now) else { return false }
        if table.idle(at: now) { return true }
        return betting(now) && table.seats.count < 4
    }

    private func betPopup(_ now: Date) -> some View {
        let canGolden = golden > 0
        return VStack(spacing: 8) {
            HStack {
                Text("얼마 걸까요?").font(Fonts.bold()).foregroundStyle(Theme.gold)
                Spacer()
                if let r = round, betting(now) {
                    let left = max(0, table.local(r.betClosesAt).timeIntervalSince(now))
                    Text("\(Int(left.rounded(.up)))").font(Fonts.mono()).foregroundStyle(Theme.neon)
                }
            }
            HStack(spacing: 6) {
                ForEach(BlackjackTable.stakes, id: \.self) { s in
                    let selected = table.stake == s
                    let affordable = Int64(chips) >= s
                    Button { table.stake = s } label: {
                        Text("\(s)").font(Fonts.mono())
                            .foregroundStyle(selected ? Theme.bg : Theme.cream)
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .pixelBox(fill: selected ? Theme.gold : Theme.bg, border: selected ? Theme.gold : Theme.line)
                    }
                    .buttonStyle(.plain)
                    .disabled(!affordable || table.busy)
                    .opacity(affordable ? 1 : 0.4)
                }
            }
            HStack(spacing: 6) {
                Button {
                    table.useGolden = false
                    Task { await table.bet() }
                } label: {
                    Text("\(table.stake) 걸기").font(Fonts.bold())
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .pixelBox(fill: Theme.neon, border: Theme.neonDeep)
                        .glow(Theme.neon)
                }
                .buttonStyle(.plain)
                .disabled(table.busy || Int64(chips) < table.stake)
                if canGolden {
                    Button {
                        table.useGolden = true
                        Task { await table.bet() }
                    } label: {
                        Text("황금 칩").font(Fonts.body()).foregroundStyle(Theme.gold)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .pixelBox(fill: Theme.goldBg, border: Theme.gold)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 70)
                    .disabled(table.busy)
                }
            }
        }
        .padding(10)
        .frame(width: 244)
        .pixelBox(fill: Theme.panel, border: Theme.gold)
        .background(alignment: .topLeading) { Rectangle().fill(Theme.outline).offset(x: 4, y: 4) }
        .glow(Theme.gold)
        .overlay(alignment: .bottomLeading) {
            GridView(grid: BlackjackArt.tail(fill: .panel, edge: .gold), scale: 3).offset(x: 26, y: 10)
        }
        .offset(x: 34, y: 150)
    }

    // MARK: - 아래 영역

    @ViewBuilder
    private func bottomArea(_ now: Date) -> some View {
        if let r = round, !table.idle(at: now) {
            switch r.phase {
            case .betting:
                bettingInfo(now)
            case .playing, .dealer:
                VStack(spacing: 6) {
                    orderLine(r, now: now)
                    if myTurn(now) { actionBar(r, now: now) } else { waitBox(r, now: now) }
                }
            case .done:
                if resultsShown(now) { resultBox } else { orderLine(r, now: now) }
            }
        } else {
            infoBox("걸면 10초 뒤에 딜 · 혼자면 바로", color: Theme.muted)
        }
    }

    @ViewBuilder
    private func bettingInfo(_ now: Date) -> some View {
        let left = round.map { Int(max(0, table.local($0.betClosesAt).timeIntervalSince(now)).rounded(.up)) } ?? 0
        if let me = table.mySeat {
            let alone = table.seats.allSatisfy { $0.playerId == me.playerId }
            HStack(spacing: 6) {
                infoBox(me.golden ? "황금 칩 걸었어요 · \(left)초 뒤 딜" : "\(me.amount) 걸었어요 · \(left)초 뒤 딜", color: Theme.gold, gold: true)
                if alone {
                    Button { Task { await table.deal() } } label: {
                        Text("바로 딜").font(Fonts.bold())
                            .frame(width: 80, height: 40)
                            .pixelBox(fill: Theme.neon, border: Theme.neonDeep)
                    }
                    .buttonStyle(.plain)
                    .disabled(table.busy)
                }
            }
        } else if table.seats.count >= 4 {
            infoBox("자리가 다 찼어요 · 다음 판에", color: Theme.muted)
        } else if let first = table.seats.first {
            infoBox("\(first.name)가 \(first.golden ? "황금 칩" : "\(first.amount)") 걸었어요 · \(left)초 뒤 딜", color: Theme.muted)
        }
    }

    private func infoBox(_ text: String, color: Color, gold: Bool = false) -> some View {
        Text(text).font(Fonts.body()).foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: 40)
            .pixelBox(fill: gold ? Theme.goldBg : Theme.panel, border: gold ? Theme.gold : Theme.line)
    }

    private func orderLine(_ r: BJRound, now: Date) -> some View {
        let seats = table.seats.sorted { $0.seat < $1.seat }
        let clock: String = {
            if r.phase == .dealer || r.phase == .done { return "딜러 차례" }
            guard now >= dealEnd, let turn = r.turnSeat, let s = seats.first(where: { $0.seat == turn }),
                  let deadline = r.turnDeadline else { return "딜 중" }
            let left = Int(max(0, table.local(deadline).timeIntervalSince(now)).rounded(.up))
            if s.bot { return "\(s.name) 차례" }
            return s.playerId == table.myID ? "내 차례 \(left)초" : "\(s.name) \(left)초"
        }()
        return HStack(spacing: 4) {
            Text("순서").foregroundStyle(Theme.dim)
            ForEach(Array(seats.enumerated()), id: \.offset) { i, s in
                let name = s.playerId != nil && s.playerId == table.myID ? "나" : s.name
                let isTurn = r.phase == .playing && r.turnSeat == s.seat && now >= dealEnd
                let done = r.phase != .playing || (r.turnSeat ?? 0) > s.seat
                Text((i > 0 ? "› " : "") + name)
                    .foregroundStyle(isTurn ? Theme.neon : done ? Theme.dim : Theme.cream)
            }
            Spacer()
            Text(clock).font(Fonts.mono()).foregroundStyle(myTurn(now) ? Theme.neon : Theme.muted)
        }
        .font(Fonts.small())
    }

    private func actionBar(_ r: BJRound, now: Date) -> some View {
        let left = r.turnDeadline.map { max(0, table.local($0).timeIntervalSince(now)) } ?? 0
        let lit = Int(left.rounded(.up))
        let me = table.mySeat
        let canDouble = me.map { $0.cards.count == 2 && !$0.golden && Int64(chips) >= $0.amount } ?? false
        return VStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(0..<11, id: \.self) { i in
                    Rectangle().fill(i < lit ? (lit <= 4 ? Theme.neon : Theme.gold) : Theme.line).frame(height: 8)
                }
            }
            HStack(spacing: 6) {
                actionButton("스탠드", fill: Theme.cream, border: Theme.creamDeep, text: Theme.bg) { .stand }
                actionButton("히트", fill: Theme.neon, border: Theme.neonDeep, text: Theme.cream, glow: true) { .hit }
                actionButton("더블 +\(me?.amount ?? 0)", fill: Theme.goldBg, border: Theme.gold, text: Theme.gold) { .double }
                    .disabled(!canDouble)
                    .opacity(canDouble ? 1 : 0.4)
            }
        }
    }

    private func actionButton(_ title: String, fill: Color, border: Color, text: Color, glow: Bool = false,
                              action: @escaping () -> BJSeat.Action) -> some View {
        Button { Task { await table.act(action()) } } label: {
            Text(title).font(Fonts.bold()).foregroundStyle(text)
                .frame(maxWidth: .infinity, minHeight: 38)
                .pixelBox(fill: fill, border: border)
                .modifier(OptionalGlow(color: glow ? fill : nil))
        }
        .buttonStyle(.plain)
        .disabled(table.busy)
    }

    @ViewBuilder
    private func waitBox(_ r: BJRound, now: Date) -> some View {
        if let me = table.mySeat {
            let t = BJCard.total(me.cards.map(BJCard.init)).value
            let text: String = switch me.state {
            case .waiting, .playing:
                "\(me.golden ? "황금 칩" : "\(me.amount)") 걸었어요 · 내 차례는 \(table.seats.sorted { $0.seat < $1.seat }.firstIndex { $0.seat == me.seat }.map { $0 + 1 } ?? 1)번째"
            case .blackjack: "블랙잭! 딜러를 기다리는 중"
            case .bust: "버스트 · \(t)"
            case .stood: me.doubled ? "더블 \(me.amount * 2) · \(t)에서 멈췄어요" : "\(t)에서 멈췄어요"
            }
            infoBox(text, color: Theme.gold, gold: true)
        } else {
            infoBox("구경 중 · 다음 판에 앉을 수 있어요", color: Theme.muted)
        }
    }

    @ViewBuilder
    private var resultBox: some View {
        VStack(spacing: 6) {
            if let me = table.mySeat, let net = me.net {
                HStack {
                    Text(resultLine(me)).font(Fonts.body()).foregroundStyle(Theme.gold)
                    Spacer()
                    Text(net > 0 ? "+\(net.formatted(.number))" : net < 0 ? "-\((-net).formatted(.number))" : "±0")
                        .font(Fonts.mono(2))
                        .foregroundStyle(net > 0 ? Theme.green : net < 0 ? Theme.dim : Theme.muted)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .pixelBox(fill: Theme.goldBg, border: Theme.gold)
                .modifier(OptionalGlow(color: net > 0 ? Theme.gold : nil))
            }
            Text("다음 판은 누가 걸면 10초 뒤에 딜").font(Fonts.small()).foregroundStyle(Theme.muted)
        }
    }

    private func resultLine(_ s: BJSeat) -> String {
        let t = BJCard.total(s.cards.map(BJCard.init)).value
        switch s.result {
        case .blackjack: return "블랙잭! 3:2"
        case .win: return s.doubled ? "\(t) · 더블 성공" : "\(t) · 이겼어요"
        case .push: return s.golden ? "무승부 · 황금 칩 돌려받음" : "무승부 · 그대로"
        case .lose: return s.state == .bust ? "버스트" : "딜러가 이겼어요"
        case nil: return ""
        }
    }

    // MARK: - 승리 연출

    @ViewBuilder
    private func winOverlay(_ now: Date) -> some View {
        if let r = round, resultsShown(now), let me = table.mySeat, let payout = me.payout, (me.net ?? 0) > 0,
           let tier = WinTier(payout: payout) {
            let start = table.settledAt("d", total: r.dealerCards.count).addingTimeInterval(0.4)
            WinBurst(tier: tier, amount: payout, start: start, origin: UnitPoint(x: 0.27, y: 0.6))
        }
    }
}

private struct OptionalGlow: ViewModifier {
    let color: Color?

    func body(content: Content) -> some View {
        if let color { content.glow(color) } else { content }
    }
}
