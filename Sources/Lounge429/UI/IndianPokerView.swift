import LoungeCore
import LoungeNet
import SwiftUI

/// 인디언 포커 (ADR-0023, DESIGN.md §인디언 포커). 로비(열린 테이블) → 대기(다음 판부터) → 테이블.
/// 내 카드는 판이 끝날 때까지 뒷면, 상대 카드만 보인다. 결과와 칩은 서버(`ip_*`)가 정하고 여기선 그리기만 한다.
struct IndianPokerView: View {
    @Bindable var table: IndianPokerTable
    /// 지갑 칩 (앉아 있으면 서버가 준 자리 칩을 먼저 쓴다)
    let chips: Int
    var onBack: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.snapshotting) private var snapshotting
    @State private var raiseText = ""
    @FocusState private var raiseFocused: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let now = context.date
            VStack(spacing: 10) {
                topBar
                if !table.seated {
                    if table.creating { createScreen } else { lobby }
                } else if table.leaving != nil {
                    leavingScreen
                } else if table.waiting {
                    waitingRoom(now)
                } else {
                    tableScreen(now)
                }
            }
            .padding(14)
            .frame(width: LoungeView.width)
            .background(Theme.bg)
        }
        .foregroundStyle(Theme.cream)
    }

    // MARK: - 위 줄

    private var walletChips: Int64 { table.mySeat?.chips ?? Int64(chips) }
    private var broke: Bool { !table.seated && chips < Int(IndianPoker.ante) }

    private var topBar: some View {
        HStack(spacing: 8) {
            if table.creating && !table.seated {
                Button { table.creating = false } label: {
                    Text("‹ 로비").font(Fonts.small()).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .help("열린 테이블 목록으로")
            } else {
                Button(action: onBack) {
                    Text("‹ 라운지").font(Fonts.small()).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .help(table.seated ? "자리에서 일어나 라운지로 (이번 판은 폴드)" : "라운지로")
            }
            GameSoundButton()
            Spacer()
            Text("인디언 포커").font(Fonts.bold()).foregroundStyle(Theme.neon).glow(Theme.neon)
            Spacer()
            if let s = table.state, table.seated {
                pill("TABLE · \(s.members.count)/\(s.table.capacity)", color: Theme.cyan, dot: true)
            } else {
                pill(chips.formatted(.number), color: broke ? Theme.neon : Theme.gold, dot: true)
            }
        }
    }

    private func pill(_ text: String, color: Color, dot: Bool = false, border: Color? = nil) -> some View {
        HStack(spacing: 4) {
            if dot { Rectangle().fill(color).frame(width: 6, height: 6) }
            Text(text).font(Fonts.small())
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Theme.bg)
        .overlay(Rectangle().strokeBorder(border ?? color, lineWidth: 2))
    }

    // MARK: - 나가는 중

    /// 서버가 이탈을 확인할 때까지. 실패하면 앱이 1·2·4·8초 간격으로 다시 보낸다
    private var leavingScreen: some View {
        VStack(spacing: 10) {
            notice(title: "나가는 중이에요",
                   text: "서버가 자리 정리를 확인하면 로비로 돌아가요. 연결이 끊겼으면 돌아오는 대로 다시 일어나요.",
                   color: Theme.gold)
            if table.leaveAttempts > 1 {
                Text("다시 시도 \(table.leaveAttempts - 1)번째 · 확인될 때까지 계속").font(Fonts.small()).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            note("확인되기 전에 다음 판이 시작되면 앤티가 빠지고 시간이 지나 폴드될 수 있어요.")
        }
    }

    // MARK: - 로비

    @ViewBuilder
    private var lobby: some View {
        let tables = Array((table.lobby?.tables ?? []).prefix(4))
        if let reason = table.leftNotice {
            notice(title: "자리에서 빠졌어요",
                   text: reason == .away ? "두 판 연속 시간이 지나 자동으로 일어났어요. 낸 칩은 판돈에 남았어요."
                       : "다음 판 앤티 10칩이 없어서 일어났어요.")
        }
        if broke {
            notice(title: "칩이 부족해요",
                   text: "앤티 10칩이 있어야 앉을 수 있어요. 지금 \(chips)칩이에요. 라운지에서 오늘의 칩을 받아 오세요.")
        }
        HStack {
            Text("열린 테이블").font(Fonts.bold())
            Spacer()
            Text("앤티 10칩 · 카드 1~10").font(Fonts.small()).foregroundStyle(Theme.muted)
        }
        if tables.isEmpty {
            emptyLobby
        } else {
            ForEach(tables) { t in lobbyRow(t) }
        }
        if broke {
            brokeCreateBox
        } else if !tables.isEmpty {
            moreBox
        }
        if let m = table.message {
            Text(m).font(Fonts.small()).foregroundStyle(Theme.neon).frame(maxWidth: .infinity, alignment: .leading)
        }
        note("입장하면 판마다 앤티 10칩이 자동으로 빠져요. 나가도 괜찮아요.")
    }

    private func notice(title: String, text: String, color: Color = Theme.neon) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Fonts.bold()).foregroundStyle(color)
            Text(text).font(Fonts.body()).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelBox(fill: Theme.panel, border: color)
    }

    private func lobbyRow(_ t: IPLobby.Table) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(t.names.first ?? "누군가")의 테이블").font(Fonts.bold()).lineLimit(1)
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        ForEach(0..<t.capacity, id: \.self) { i in
                            if i < t.humans {
                                Rectangle().fill(Theme.gold).frame(width: 8, height: 8)
                            } else {
                                Rectangle().strokeBorder(Theme.line, lineWidth: 2).frame(width: 8, height: 8)
                            }
                        }
                    }
                    Text("\(t.humans)/\(t.capacity)").font(Fonts.bold()).foregroundStyle(t.full ? Theme.muted : Theme.gold)
                    Text(t.handNo == nil ? "곧 시작" : "판 진행 중").font(Fonts.small())
                        .foregroundStyle(t.handNo == nil ? Theme.cyan : Theme.muted)
                }
            }
            Spacer(minLength: 0)
            let open = !t.full && !broke
            Button { Task { await table.join(t.id) } } label: {
                Text(t.full ? "만석" : "입장").font(Fonts.bold())
                    .foregroundStyle(open ? Theme.bg : Theme.muted)
                    .frame(width: 64, height: 44)
                    .pixelBox(fill: open ? Theme.gold : Theme.panel, border: open ? Theme.goldDark : Theme.line)
            }
            .buttonStyle(.plain)
            .disabled(!open || table.busy)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .pixelBox()
    }

    private var emptyLobby: some View {
        VStack(spacing: 8) {
            PokerCard(face: .back)
            Text("열린 테이블이 없어요").font(Fonts.bold())
            Text("만들면 혼자여도 바로 시작해요")
                .font(Fonts.body()).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            if !broke {
                createButton("새 테이블 만들기", fill: Theme.neon, border: Theme.neonDeep).padding(.top, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .overlay(Rectangle().strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 2, dash: [4, 4])))
    }

    /// 로비 아래: 자리가 없으면 새 테이블로 (만들기 화면을 연다)
    private var moreBox: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("자리가 없나요?").font(Fonts.bold()).foregroundStyle(Theme.gold)
                Text("혼자여도 바로 시작해요").font(Fonts.small()).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            Button { table.creating = true } label: {
                Text("새 테이블 만들기").font(Fonts.bold()).foregroundStyle(Theme.bg)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .pixelBox(fill: Theme.gold, border: Theme.goldDark)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .pixelBox(fill: Theme.goldBg, border: Theme.gold)
    }

    private var brokeCreateBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("새 테이블 만들기").font(Fonts.bold()).foregroundStyle(Theme.muted)
            Text("칩이 부족해요 · 앤티 10칩 필요").font(Fonts.bold()).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, minHeight: 44)
                .pixelBox()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .pixelBox()
    }

    private func createButton(_ title: String, fill: Color, border: Color) -> some View {
        Button { table.creating = true } label: {
            Text(title).font(Fonts.bold()).foregroundStyle(Theme.bg)
                .frame(maxWidth: .infinity, minHeight: 44)
                .pixelBox(fill: fill, border: border)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 새 테이블 만들기

    /// 최대 인원 2·3·4(기본 4)를 고르면 자리 미리보기(나 + 봇 칸)가 바뀐다. 만들면 혼자여도 바로 시작
    private var createScreen: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                Text("새 테이블 만들기").font(Fonts.bold()).foregroundStyle(Theme.gold)
                VStack(alignment: .leading, spacing: 6) {
                    Text("최대 인원").font(Fonts.body())
                    HStack(spacing: 6) {
                        ForEach(Array(IndianPoker.seatRange), id: \.self) { n in
                            let on = table.maxSeats == n
                            Button { table.maxSeats = n } label: {
                                Text("\(n)명").font(Fonts.bold()).foregroundStyle(on ? Theme.gold : Theme.cream)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .pixelBox(fill: on ? Theme.goldBg : Theme.panel, border: on ? Theme.gold : Theme.line)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("최대 \(n)명")
                        }
                    }
                }
                HStack(spacing: 8) {
                    ForEach(0..<table.maxSeats, id: \.self) { i in seatPreview(mine: i == 0) }
                }
                .frame(maxWidth: .infinity, minHeight: 84)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("나와 봇 \(table.maxSeats - 1)자리")
                Text("혼자여도 바로 시작해요").font(Fonts.bold()).frame(maxWidth: .infinity)
                Button { Task { await table.create() } } label: {
                    Text("만들고 앉기").font(Fonts.bold()).foregroundStyle(Theme.bg)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .pixelBox(fill: Theme.neon, border: Theme.neonDeep)
                }
                .buttonStyle(.plain)
                .disabled(table.busy || broke)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .pixelBox(fill: Theme.goldBg, border: Theme.gold)
            if let m = table.message {
                Text(m).font(Fonts.small()).foregroundStyle(Theme.neon).frame(maxWidth: .infinity, alignment: .leading)
            }
            note("입장하면 판마다 앤티 10칩이 자동으로 빠져요.")
        }
    }

    /// 만들기 미리보기 칸 64×72: 나(골드 실선) / 봇(흐린 점선)
    private func seatPreview(mine: Bool) -> some View {
        Text(mine ? "나" : "봇")
            .font(mine ? Fonts.bold(2) : Fonts.bold())
            .foregroundStyle(mine ? Theme.gold : Theme.muted)
            .frame(width: 64, height: 72)
            .background(mine ? Theme.goldBg : Theme.bg)
            .overlay {
                if mine {
                    Rectangle().strokeBorder(Theme.gold, lineWidth: 2)
                } else {
                    Rectangle().strokeBorder(Theme.dim, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                }
            }
    }

    private func note(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DashLine(color: Theme.line)
            Text(text).font(Fonts.small()).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 대기 (다음 판부터)

    private struct WaitSeat: Identifiable {
        let id: Int
        let name: String
        let mine: Bool
        let bot: Bool
        /// 이번 판엔 없고 다음 판부터 앉는 사람 (봇 자리를 받음)
        let joining: Bool
    }

    /// 대기 화면 자리: 앉은 사람은 사람으로(다음 판부터 앉는 사람은 "합류"), 나머지는 이번 판 봇
    private var waitSeats: [WaitSeat] {
        guard let s = table.state else { return [] }
        let inHand = Set(s.seats.compactMap(\.playerId))
        return (1...max(1, s.table.capacity)).map { n in
            if let m = s.members.first(where: { $0.seat == n }) {
                let mine = m.playerId == table.myID
                return WaitSeat(id: n, name: m.name, mine: mine, bot: false, joining: !mine && !inHand.contains(m.playerId))
            }
            let name = s.seats.first { $0.seat == n && $0.bot }?.name ?? "봇"
            return WaitSeat(id: n, name: name, mine: false, bot: true, joining: false)
        }
    }

    /// 대기 화면 한 줄: 혼자면 봇과 먼저 친다, 사람이 합류했으면 그 사람이 봇 자리를 받았다
    private var waitLine: String {
        let seats = waitSeats
        if let joined = seats.last(where: \.joining) { return "\(Josa.subject(joined.name)) 앉았어요 · 봇 한 자리를 내줬어요" }
        if seats.filter({ !$0.bot }).count <= 1 { return "봇과 먼저 치는 중 · 사람이 오면 다음 판부터 자리를 비켜요" }
        return "다음 판부터 봇 한 자리에 앉아요"
    }

    @ViewBuilder
    private func waitingRoom(_ now: Date) -> some View {
        let s = table.state
        let humans = s?.members.count ?? 1
        let cap = s?.table.capacity ?? 2
        let next = s?.hand.flatMap { $0.phase == .done ? $0.nextAt : nil }.map { table.local($0).timeIntervalSince(now) }
        felt {
            HStack(alignment: .top, spacing: 6) {
                ForEach(waitSeats) { seat in
                    VStack(spacing: 4) {
                        nameRow(seat.name, bot: seat.bot)
                        PokerCard(face: seat.mine ? .seat("나", mine: true) : seat.bot ? .seat("봇", mine: false) : .person("사람"),
                                  seatHeight: 84)
                        if seat.joining { tag("합류", .joined) }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            VStack(spacing: 2) {
                if let next {
                    Text("\(max(1, Int(next.rounded(.up))))").font(Fonts.bold(2)).foregroundStyle(Theme.neon).glow(Theme.neon)
                    caption("다음 판 시작 · 앤티 10칩 자동")
                } else if s?.hand == nil {
                    caption("곧 시작 · 앤티 10칩 자동")
                } else {
                    caption("판 진행 중 · 끝나면 다음 판부터 앉아요")
                }
            }
            .frame(maxWidth: .infinity)
        }
        Text(waitLine).font(Fonts.bold()).foregroundStyle(Theme.cyan)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pixelBox(fill: Theme.panel, border: Theme.cyan)
        HStack(spacing: 6) {
            pill("사람 \(humans)/\(cap)", color: Theme.cyan, dot: true)
            Spacer()
            Text("앤티 10 · 카드 1~10").font(Fonts.small()).foregroundStyle(Theme.muted)
        }
        walletRow(right: "앤티 10 · 판 시작 때 빠져요", now: now)
        Button { table.leave() } label: {
            Text("나가기").font(Fonts.bold()).frame(maxWidth: .infinity, minHeight: 44).pixelBox()
        }
        .buttonStyle(.plain)
        note("사람이 모두 나가면 하던 판을 마치고 테이블이 닫혀요.")
    }

    // MARK: - 테이블

    private func felt<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 8, content: content)
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(Theme.felt)
            .overlay(Rectangle().strokeBorder(Theme.feltLine, lineWidth: 2).padding(2))
            .overlay(Rectangle().strokeBorder(Theme.gold, lineWidth: 2))
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(Fonts.small()).foregroundStyle(Theme.cream)
            .padding(.horizontal, 6)
            .background(Theme.outline.opacity(0.55))
    }

    private func nameRow(_ name: String, bot: Bool) -> some View {
        HStack(spacing: 4) {
            Text(name).font(Fonts.bold()).lineLimit(1)
            if bot {
                Text("봇").font(Fonts.small())
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .background(Theme.outline.opacity(0.6))
                    .overlay(Rectangle().strokeBorder(Theme.muted, lineWidth: 1))
                    .fixedSize()
            }
        }
    }

    private func done(_ now: Date) -> Bool { table.hand?.phase == .done }

    @ViewBuilder
    private func tableScreen(_ now: Date) -> some View {
        let s = table.state
        let opponents = (s?.seats ?? []).filter { $0.seat != table.mySeat?.seat }
        felt {
            HStack(alignment: .top, spacing: 6) {
                ForEach(opponents) { seat in opponentCell(seat, now: now) }
            }
            .frame(maxWidth: .infinity)
            potPanel(now)
            myPanel(now)
        }
        if let mine = table.mySeat, mine.lastAction == .timeout, !done(now) {
            notice(title: "시간이 지나 폴드했어요",
                   text: "11초 안에 고르지 못했어요. 낸 칩 \(mine.put)칩은 판돈에 남아요. 앱을 닫거나 연결이 끊겨도 같게 처리돼요.")
        }
        clockSection(now)
        if table.myTurn(at: now) || (table.dealing(at: now) && table.hand?.turnSeat == table.mySeat?.seat) {
            if table.raising, let o = table.options(at: now) {
                raisePanel(o, now: now)
            } else {
                actionButtons(now)
            }
        }
        if let m = table.message {
            Text(m).font(Fonts.small()).foregroundStyle(Theme.neon).frame(maxWidth: .infinity, alignment: .leading)
        }
        walletRow(right: walletNote(now), now: now)
        if let text = tableNote(now) { note(text) }
    }

    // MARK: 상대 자리

    private func opponentCell(_ seat: IPSeat, now: Date) -> some View {
        let turn = isTurn(seat, now: now)
        let winner = table.state?.winners.contains(seat.seat) ?? false
        return VStack(spacing: 4) {
            nameRow(seat.name, bot: seat.bot)
            PokerCard(face: seat.card.map { .front($0) } ?? .back, folded: seat.folded, winner: winner)
            statusTag(seat, now: now)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
        .frame(width: 92)
        .background(turn ? Theme.outline.opacity(0.35) : .clear)
        .overlay(Rectangle().strokeBorder(turn ? Theme.neon : .clear, lineWidth: 2))
        .background { if turn { Rectangle().strokeBorder(Theme.neon, lineWidth: 2).glow(Theme.neon, radius: 3) } }
    }

    private func isTurn(_ seat: IPSeat, now: Date) -> Bool {
        guard let h = table.hand, h.phase == .betting, h.turnSeat == seat.seat, !table.dealing(at: now) else { return false }
        return true
    }

    private enum TagStyle { case gold, cream, dashed, allIn, turn, wait, up, down, joined }

    private func statusTag(_ seat: IPSeat, now: Date) -> some View {
        let (text, style) = status(seat, now: now)
        return tag(text, style)
    }

    private func status(_ seat: IPSeat, now: Date) -> (String, TagStyle) {
        if done(now) {
            let net = seat.net ?? 0
            let money = net > 0 ? "+\(net.formatted(.number))" : net < 0 ? "−\((-net).formatted(.number))" : "±0"
            if seat.folded { return ("\(money) · 폴드", .dashed) }
            return (money, net > 0 ? .up : .down)
        }
        if isTurn(seat, now: now) {
            if seat.bot { return ("차례", .turn) }
            let left = table.hand?.turnDeadline.map { max(0, table.local($0).timeIntervalSince(now)) } ?? 0
            return ("차례 0:\(String(format: "%02d", Int(left.rounded(.up))))", .turn)
        }
        if seat.allIn { return ("올인 \((seat.lastAmount ?? seat.bet).formatted(.number))", .allIn) }
        switch seat.lastAction {
        case .bet: return ("베팅 \((seat.lastAmount ?? 0).formatted(.number))", .gold)
        case .raise: return ("레이즈 \((seat.lastAmount ?? 0).formatted(.number))", .gold)
        case .call: return ("콜 \((seat.lastAmount ?? 0).formatted(.number))", .cream)
        case .check: return ("체크", .cream)
        case .fold: return ("폴드", .dashed)
        case .timeout: return ("폴드 · 시간 초과", .dashed)
        case .leave: return ("폴드 · 나감", .dashed)
        case nil: return ("대기", .wait)
        }
    }

    private func tag(_ text: String, _ style: TagStyle) -> some View {
        let (fg, border, fill, bold, dashed): (Color, Color, Color, Bool, Bool) = switch style {
        case .gold: (Theme.gold, Theme.gold, Theme.outline.opacity(0.7), false, false)
        case .cream: (Theme.cream, Theme.creamDeep, Theme.outline.opacity(0.7), false, false)
        case .dashed: (Theme.muted, Theme.dim, Theme.outline.opacity(0.7), false, true)
        case .allIn: (Theme.bg, Theme.neon, Theme.neon, true, false)
        case .turn: (Theme.neon, Theme.neon, Theme.outline.opacity(0.7), true, false)
        case .wait: (Theme.muted, .clear, Theme.outline.opacity(0.7), false, false)
        case .up: (Theme.green, Theme.green, Theme.outline.opacity(0.7), true, false)
        case .down: (Theme.muted, Theme.dim, Theme.outline.opacity(0.7), false, false)
        case .joined: (Theme.cyan, Theme.cyan, Theme.outline.opacity(0.7), false, false)
        }
        return Text(text)
            .font(bold ? Fonts.bold() : Fonts.small())
            .foregroundStyle(fg)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(fill)
            .overlay(Rectangle().strokeBorder(border, style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : [])))
            .fixedSize()
    }

    // MARK: 판돈

    private func potPanel(_ now: Date) -> some View {
        let s = table.state
        // 판을 끝낸 마지막 행동(콜·체크·폴드)도 1.5초 보여 준 뒤 결과 문구로
        let alert = table.currentAlert(at: now)
        let won = done(now) ? (s?.awards.filter { !$0.refund } ?? []) : []
        return VStack(alignment: .leading, spacing: 4) {
            if let s, won.count > 1 {
                // 사이드 팟이 따로 나간 판: 팟마다 누가 가져갔는지
                ForEach(Array(won.enumerated()), id: \.offset) { i, award in
                    if i > 0 { DashLine(color: Theme.feltLine).padding(.vertical, 2) }
                    potRow(label: i == 0 ? "메인 팟" : "사이드 팟", value: award.amount, color: i == 0 ? Theme.gold : Theme.cyan,
                           alert: i == 0 ? alert : nil, now: now)
                    if i == 0, let alert { alertChip(alert).frame(minHeight: 22) } else { detail(takers(award, in: s)) }
                }
            } else if let s, let pots = s.pots, !done(now) {
                potRow(label: "메인 팟", value: pots.main, color: Theme.gold, alert: alert, now: now)
                if let alert { alertChip(alert).frame(minHeight: 22) } else {
                    detail(eligible(pots.mainSeats, in: s) + " 가져갈 수 있어요")
                }
                DashLine(color: Theme.feltLine).padding(.vertical, 2)
                potRow(label: "사이드 팟", value: pots.side, color: Theme.cyan, alert: nil, now: now)
                detail(sideLine(pots, in: s))
            } else {
                potRow(label: "판돈", value: s?.hand?.pot ?? 0, color: Theme.gold, alert: alert, now: now)
                Group {
                    if let alert { alertChip(alert) } else { detail(potDetail(now)) }
                }
                .frame(minHeight: 22, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.outline.opacity(0.6))
        .overlay(Rectangle().strokeBorder(Theme.feltLine, lineWidth: 2))
    }

    private func potRow(label: String, value: Int64, color: Color, alert: IndianPokerTable.Alert?, now: Date) -> some View {
        // 행동 알림 때 판돈 숫자가 한 번 반짝인다 (1.5초에 걸쳐 밝은 골드 → 골드). 동작 줄이기면 반짝임 없음
        let p = alert.map { min(1, now.timeIntervalSince($0.at) / IndianPokerTable.alertSeconds) } ?? 1
        let spark = reduceMotion ? 0 : 1 - p
        return HStack(spacing: 8) {
            potIcon(color)
            Text(label).font(Fonts.small()).foregroundStyle(Theme.muted)
            Spacer()
            Text(value.formatted(.number)).font(Fonts.bold(2)).foregroundStyle(color)
                .overlay(Text(value.formatted(.number)).font(Fonts.bold(2)).foregroundStyle(Theme.goldLight).opacity(spark))
                .glow(Theme.gold.opacity(spark))
        }
    }

    private func potIcon(_ color: Color) -> some View {
        Rectangle().fill(color).frame(width: 4, height: 4)
            .padding(2).background(color == Theme.cyan ? Theme.cream : Theme.goldLight)
            .padding(2).background(color == Theme.cyan ? Theme.cyan.opacity(0.6) : Theme.goldDark)
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(Fonts.small()).foregroundStyle(Theme.cream).fixedSize(horizontal: false, vertical: true)
    }

    private func displayName(_ seat: Int, in s: IPState) -> String {
        seat == s.mySeat?.seat ? "나" : s.seats.first { $0.seat == seat }?.name ?? "?"
    }

    /// "철수 · 민지 · 나가"
    private func eligible(_ seats: [Int], in s: IPState) -> String {
        let names = seats.map { displayName($0, in: s) }
        guard let last = names.last else { return "" }
        return (names.dropLast() + [Josa.subject(last)]).joined(separator: " · ")
    }

    /// "민지 · 나만 · 철수는 올인이라 못 가져가요"
    private func sideLine(_ pots: IPPots, in s: IPState) -> String {
        let who = pots.sideSeats.map { displayName($0, in: s) }.joined(separator: " · ")
        let capped = pots.cappedSeats.map { displayName($0, in: s) }
        guard let last = capped.last else { return "\(who)만 가져갈 수 있어요" }
        let cappedText = (capped.dropLast() + [Josa.topic(last)]).joined(separator: " · ")
        return "\(who)만 · \(cappedText) 올인이라 못 가져가요"
    }

    private func potDetail(_ now: Date) -> String {
        guard let s = table.state, let h = s.hand else { return "" }
        if h.phase == .done { return resultLine(s) }
        if table.dealing(at: now) { return "앤티 \(IndianPoker.ante) × \(s.seats.count) · 카드 나눠 주는 중" }
        let bets = max(0, h.pot - s.anteTotal)
        return "앤티 \(s.anteTotal.formatted(.number)) · 베팅 \(bets.formatted(.number))"
    }

    /// "철수 10이 가져가요" / "나 · 민지 6 동점 · 나눠 가져요"
    private func takers(_ award: IPAward, in s: IPState) -> String {
        let cards = award.seats.compactMap { w in s.seats.first { $0.seat == w }?.card }
        let names = award.seats.map { displayName($0, in: s) }.joined(separator: " · ")
        guard let card = cards.first else { return "" }
        if award.seats.count > 1 { return "\(names) \(card) 동점 · 나눠 가져요" }
        return "\(names) \(Josa.subject("\(card)")) 가져가요"
    }

    /// 결과 한 줄: 접어서 못 이긴 더 높은 카드가 있으면 그걸, 아니면 누가 무엇으로 가져갔는지
    private func resultLine(_ s: IPState) -> String {
        let top = s.winners.compactMap { w in s.seats.first { $0.seat == w }?.card }.max() ?? 0
        if let folded = s.seats.filter({ $0.folded && ($0.card ?? 0) > top }).max(by: { ($0.card ?? 0) < ($1.card ?? 0) }),
           let card = folded.card {
            return "\(Josa.topic(displayName(folded.seat, in: s))) \(Josa.pick("\(card)", "이었지만", "였지만")) 폴드해서 못 이겨요"
        }
        let names = s.winners.map { displayName($0, in: s) }
        if names.count > 1 { return "\(names.joined(separator: " · ")) \(top) 동점 · 판돈을 나눠요" }
        guard let name = names.first else { return "" }
        return name == "나" ? "내 \(Josa.subject("\(top)")) 제일 높았어요" : "\(name) \(Josa.subject("\(top)")) 이겼어요"
    }

    private func alertText(_ a: IndianPokerTable.Alert) -> String {
        let amount = (a.amount ?? 0).formatted(.number)
        if a.allIn, a.action != .fold { return "\(a.name) 올인 \(amount)" }
        return switch a.action {
        case .bet: "\(a.name) 베팅 \(amount)"
        case .raise: "\(a.name) 레이즈 → \(amount)"
        case .call: "\(a.name) 콜 \(amount)"
        case .check: "\(a.name) 체크"
        case .fold: "\(a.name) 폴드"
        case .timeout: "\(a.name) 폴드 · 시간 초과"
        case .leave: "\(a.name) 폴드 · 나감"
        }
    }

    /// 행동 알림 한 줄: 베팅·레이즈 노랑 채움, 콜 흰 실선, 폴드 점선, 체크 흐린 실선, 올인 핑크 채움
    private func alertChip(_ a: IndianPokerTable.Alert) -> some View {
        let quiet = !a.allIn && [.fold, .timeout, .leave, .check].contains(a.action)
        let (fg, border, fill, dashed): (Color, Color, Color, Bool) =
            if a.allIn { (Theme.bg, Theme.neon, Theme.neon, false) }
            else {
                switch a.action {
                case .bet, .raise: (Theme.gold, Theme.gold, Theme.gold.opacity(0.14), false)
                case .call: (Theme.cream, Theme.cream, .clear, false)
                case .check: (Theme.cream, Theme.dim, .clear, false)
                default: (Theme.muted, Theme.dim, .clear, true)
                }
            }
        return Text(alertText(a))
            .font(quiet ? Fonts.body() : Fonts.bold())
            .foregroundStyle(fg)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(fill)
            .overlay(Rectangle().strokeBorder(border, style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : [])))
            .fixedSize()
    }

    // MARK: 내 자리

    private func myPanel(_ now: Date) -> some View {
        let mine = table.mySeat
        let isDone = done(now)
        let winner = mine.map { table.state?.winners.contains($0.seat) ?? false } ?? false
        let face: PokerCard.Face = isDone ? (mine?.card.map { .front($0) } ?? .back) : .back
        return HStack(spacing: 10) {
            PokerCard(face: face, folded: mine?.folded == true && !isDone, winner: isDone && winner)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(mine?.name ?? "나") (나)").font(Fonts.bold()).foregroundStyle(Theme.gold).lineLimit(1)
                myLines(mine, now: now)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.outline.opacity(0.35))
        .overlay(Rectangle().strokeBorder(Theme.gold, lineWidth: 2))
    }

    @ViewBuilder
    private func myLines(_ mine: IPSeat?, now: Date) -> some View {
        if let mine, done(now), let s = table.state {
            let net = mine.net ?? 0
            Text(net > 0 ? "+\(net.formatted(.number))" : net < 0 ? "−\((-net).formatted(.number))" : "±0")
                .font(Fonts.bold(2))
                .foregroundStyle(net > 0 ? Theme.green : net < 0 ? Theme.dim : Theme.muted)
            caption(myResult(mine, in: s))
        } else if let mine, mine.folded {
            tag(mine.lastAction == .timeout ? "폴드 · 시간 초과" : mine.lastAction == .leave ? "폴드 · 나감" : "폴드", .dashed)
            caption("내 카드는 판이 끝나야 보여요")
        } else if table.raising {
            pill(table.options(at: now)?.opened == false ? "베팅 고르는 중" : "레이즈 고르는 중", color: Theme.neon)
        } else {
            caption(myCaption(now))
            if table.myTurn(at: now) {
                pill("내 차례", color: Theme.neon)
            } else if let mine {
                let (text, style) = status(mine, now: now)
                if mine.lastAction != nil || mine.allIn { tag(text, style) }
            }
        }
    }

    private func myCaption(_ now: Date) -> String {
        guard let s = table.state else { return "" }
        if table.myTurn(at: now),
           let shove = s.seats.first(where: { $0.allIn && !$0.folded && $0.seat != s.mySeat?.seat }) {
            return "\(Josa.subject(shove.name)) 올인했어요"
        }
        return "내 카드는 나만 못 봐요"
    }

    /// 내 결과 문구는 내가 받은 금액(서버 지급) 기준. 사이드 팟만 받았으면 그렇게 말한다
    private func myResult(_ mine: IPSeat, in s: IPState) -> String {
        let card = mine.card.map(String.init) ?? "?"
        if mine.folded { return "폴드했어요 · 내 카드는 \(card)" }
        let won = s.awards.filter { !$0.refund }
        let mineWon = won.enumerated().filter { $0.element.seats.contains(mine.seat) }
        let got = (mine.payout ?? 0).formatted(.number)
        if let first = mineWon.first {
            if won.count > 1, mineWon.count == 1 {
                return "\(first.offset == 0 ? "메인 팟" : "사이드 팟")을 받았어요 · \(got)칩"
            }
            if first.element.seats.count > 1 { return "\(card) 동점 · 나눠서 \(got)칩" }
            return "\(Josa.subject(card)) 제일 높았어요 · \(got)칩"
        }
        if let w = won.first?.seats.first, let top = s.seats.first(where: { $0.seat == w }) {
            return "\(top.name) \(top.card.map(String.init) ?? "?")에 졌어요 · 내 카드 \(card)"
        }
        return "내 카드 \(card)"
    }

    // MARK: 시계

    private func clockSection(_ now: Date) -> some View {
        let (title, left, cells) = clock(now)
        let lit = left.map { Int($0.rounded(.up)) } ?? 0
        return VStack(spacing: 6) {
            HStack {
                Text(title).font(Fonts.body())
                Spacer()
                if let left {
                    Text("0:\(String(format: "%02d", Int(left.rounded(.up))))").font(Fonts.bold())
                        .foregroundStyle(cells == 11 && lit <= 4 ? Theme.neon : Theme.gold)
                }
            }
            HStack(spacing: 2) {
                ForEach(0..<cells, id: \.self) { i in
                    Rectangle()
                        .fill(i < lit ? (cells == 11 && lit <= 4 ? Theme.neon : Theme.gold) : Theme.line)
                        .frame(height: 8)
                }
            }
        }
    }

    /// (제목, 남은 초, 칸 수): 사람 차례는 서버 마감까지 11칸, 결과는 다음 판까지 5칸
    private func clock(_ now: Date) -> (String, TimeInterval?, Int) {
        guard let s = table.state, let h = s.hand else { return ("곧 시작", nil, 11) }
        if h.phase == .done {
            let left = h.nextAt.map { max(0, table.local($0).timeIntervalSince(now)) }
            return ("다음 판 자동 시작", left, 5)
        }
        if table.dealing(at: now) { return ("카드 나눠 주는 중", nil, 11) }
        guard let turn = s.turn else { return ("카드 여는 중", nil, 11) }
        let left = h.turnDeadline.map { max(0, table.local($0).timeIntervalSince(now)) }
        if turn.seat == s.mySeat?.seat { return ("내 차례 · 11초 안에", left, 11) }
        if turn.bot { return ("\(turn.name) 차례 · 고르는 중", nil, 11) }
        return ("\(turn.name) 차례 · 모두에게 같은 시계", left, 11)
    }

    // MARK: 행동 버튼

    private func actionButtons(_ now: Date) -> some View {
        let o = table.options(at: now)
        let ready = o != nil && !table.busy
        let callTitle: String = {
            guard let o else { return "체크" }
            if o.canCheck { return "체크" }
            if o.callIsAllIn { return "올인 \(o.stack.formatted(.number))" }
            return "콜 \(o.toCall.formatted(.number))"
        }()
        return HStack(spacing: 6) {
            bigButton("폴드", fill: Theme.cream, border: Theme.creamDeep) { await table.act(.fold) }
            bigButton(callTitle, fill: Theme.neon, border: Theme.neonDeep) {
                await table.act(o?.canCheck == true ? .check : .call)
            }
            bigButton(o?.opened == false ? "베팅" : "레이즈", fill: Theme.gold, border: Theme.goldDark) {
                table.openRaise(at: .now)
                raiseText = "\(table.raiseAmount)"
            }
            .disabled(!(o?.canRaise ?? false))
            .opacity(o?.canRaise ?? false ? 1 : 0.4)
        }
        .disabled(!ready)
        .opacity(ready ? 1 : 0.4)
    }

    private func bigButton(_ title: String, fill: Color, border: Color, text: Color = Theme.bg,
                           action: @escaping @MainActor () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Text(title).font(Fonts.bold()).foregroundStyle(text).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 44)
                .pixelBox(fill: fill, border: border)
        }
        .buttonStyle(.plain)
    }

    // MARK: 레이즈 패널

    private func raisePanel(_ o: IPOptions, now: Date) -> some View {
        let amount = table.clampRaise(table.raiseAmount, o)
        let verb = o.opened ? "레이즈" : "베팅"
        let allIn = amount >= o.allInAmount
        let presets: [(String, String, Int64, Bool)] = [
            ("최소", "+\(o.minRaise.formatted(.number))", o.minRaise, !o.raiseIsAllInOnly),
            ("2배", "+\((o.minRaise * 2).formatted(.number))", o.minRaise * 2, o.minRaise * 2 < o.allInAmount),
            ("올인", o.stack.formatted(.number), o.allInAmount, true),
        ]
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(verb).font(Fonts.bold()).foregroundStyle(Theme.gold)
                Text(o.opened ? "직전 올린 폭 \(o.minRaise.formatted(.number)) 이상 · 횟수 제한 없음" : "\(o.minRaise) 이상 · 누가 올리면 다시 차례")
                    .font(Fonts.small()).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer(minLength: 0)
                Button("취소") { table.raising = false }
                    .font(Fonts.body()).foregroundStyle(Theme.muted).buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                ForEach(presets, id: \.0) { title, sub, value, enabled in
                    let on = amount == value
                    Button { setRaise(value, o) } label: {
                        VStack(spacing: 0) {
                            Text(title).font(Fonts.bold())
                            Text(sub).font(Fonts.small())
                        }
                        .foregroundStyle(on ? Theme.gold : Theme.cream)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .pixelBox(fill: on ? Theme.goldBg : Theme.panel, border: on ? Theme.gold : Theme.line)
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.4)
                }
            }
            HStack(spacing: 6) {
                stepButton("−10") { setRaise(amount - 10, o) }
                raiseField(amount, o)
                stepButton("+10") { setRaise(amount + 10, o) }
            }
            Text(raiseSummary(o, amount: amount, allIn: allIn)).font(Fonts.small()).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity)
            Button { Task { await table.confirmRaise(at: .now) } } label: {
                Text(allIn ? "올인 \(o.stack.formatted(.number))" : o.opened ? "\(verb) \((o.toCall + amount).formatted(.number))" : "\(verb) \(amount.formatted(.number))")
                    .font(Fonts.bold()).foregroundStyle(Theme.bg)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .pixelBox(fill: Theme.gold, border: Theme.goldDark)
            }
            .buttonStyle(.plain)
            .disabled(table.busy)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .pixelBox(fill: Theme.goldBg, border: Theme.gold)
    }

    private func raiseSummary(_ o: IPOptions, amount: Int64, allIn: Bool) -> String {
        let total = o.toCall + amount
        let rest = max(0, o.stack - total).formatted(.number)
        if allIn { return "가진 칩 \(o.stack.formatted(.number)) 전부 · 올인은 낸 만큼만 가져가요" }
        if o.opened {
            return "콜 \(o.toCall.formatted(.number)) + 올림 \(amount.formatted(.number)) = \(total.formatted(.number)) 걸기 · 남는 칩 \(rest)"
        }
        return "\(amount.formatted(.number)) 걸기 · 남는 칩 \(rest)"
    }

    private func setRaise(_ value: Int64, _ o: IPOptions) {
        table.raiseAmount = table.clampRaise(value, o)
        raiseText = "\(table.raiseAmount)"
    }

    private func stepButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Fonts.bold()).frame(width: 44, height: 44).pixelBox()
        }
        .buttonStyle(.plain)
    }

    /// 직접 입력. 엔터나 다른 곳을 누르면 허용 범위로 맞춘다. 스냅샷은 TextField를 못 그려서 글자만
    @ViewBuilder
    private func raiseField(_ amount: Int64, _ o: IPOptions) -> some View {
        Group {
            if snapshotting {
                Text(amount.formatted(.number)).font(Fonts.bold(2)).foregroundStyle(Theme.gold)
            } else {
                TextField("", text: $raiseText)
                    .textFieldStyle(.plain)
                    .font(Fonts.bold(2))
                    .foregroundStyle(Theme.gold)
                    .multilineTextAlignment(.center)
                    .focused($raiseFocused)
                    .onAppear { raiseText = "\(amount)" }
                    .onChange(of: raiseText) { _, text in
                        let digits = text.filter(\.isNumber)
                        if digits != text { raiseText = digits }
                        if let v = Int64(digits) { table.raiseAmount = v }
                    }
                    .onSubmit { setRaise(table.raiseAmount, o) }
                    .onChange(of: raiseFocused) { _, focused in if !focused { setRaise(table.raiseAmount, o) } }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(Theme.bg)
        .overlay(Rectangle().strokeBorder(Theme.gold, lineWidth: 2))
    }

    // MARK: 지갑 줄 · 안내

    private func walletRow(right: String, now: Date) -> some View {
        HStack(spacing: 8) {
            Text("내 칩").font(Fonts.body()).foregroundStyle(Theme.muted)
            Text(walletChips.formatted(.number)).font(Fonts.bold()).foregroundStyle(Theme.gold)
            Spacer()
            Text(right).font(Fonts.small()).foregroundStyle(Theme.muted).lineLimit(1)
        }
    }

    private func walletNote(_ now: Date) -> String {
        guard let mine = table.mySeat else { return "" }
        if done(now), let payout = mine.payout, let net = mine.net {
            let sign = net > 0 ? "+\(net.formatted(.number))" : net < 0 ? "−\((-net).formatted(.number))" : "±0"
            return payout > 0 ? "\(sign) · 낸 칩 \(mine.put.formatted(.number)), 받은 칩 \(payout.formatted(.number))"
                : "\(sign) · 낸 칩 \(mine.put.formatted(.number))"
        }
        return "이번 판 낸 칩 \(mine.put.formatted(.number))"
    }

    private func tableNote(_ now: Date) -> String? {
        guard let s = table.state else { return nil }
        if done(now) { return "동점이면 판돈을 똑같이 나눠요. 결과는 5초 동안 보여 줘요." }
        if s.pots != nil { return "올인한 사람은 자기가 낸 만큼만 각자에게서 가져가요. 나머지는 사이드 팟으로." }
        if let o = table.options(at: now), o.canCheck {
            return "아무도 안 걸었으면 체크할 수 있어요. 모두 체크하면 바로 카드를 열어요."
        }
        return "라운지로 나가면 자리에서 일어나요. 진행 중인 판은 폴드돼요."
    }
}

/// 2pt 가로 점선 (안내 줄 위, 사이드 팟 구분)
private struct DashLine: View {
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            p.move(to: CGPoint(x: 0, y: 1))
            p.addLine(to: CGPoint(x: size.width, y: 1))
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        }
        .frame(height: 2)
    }
}
