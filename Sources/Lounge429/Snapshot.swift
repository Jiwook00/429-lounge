import AppKit
import LoungeCore
import LoungeNet
import SwiftUI

/// 개발용: 실제 창에 띄운 429 드롭 (지갑 값이 바뀌면 다시 그린다)
private struct PlinkoLiveHost: View {
    let table: PlinkoTable
    let store: LoungeStore
    var body: some View { PlinkoView(table: table, chips: store.chips, golden: store.golden()) }
}

@MainActor private var plinkoWindow: NSWindow?

/// 개발용: 화면을 PNG로 렌더링 (2x). 테이블 화면은 가짜 데이터로.
@MainActor
enum Snapshot {
    static func render(to path: String, locked: Bool, table: String?) {
        var usage = UsageScanner().scan()
        if locked {
            usage.lastLimitHit = RateLimitHit(
                hitAt: .now, resetsAt: .now.addingTimeInterval(2 * 3600 + 13 * 60), type: "five_hour")
        }
        let me = Player(id: UUID(), name: "guest", chips: 1_250,
                        goldenChips: locked ? 3 : 0, goldenUntil: usage.lastLimitHit?.resetsAt)
        let store = LoungeStore(live: false)
        store.preview(me: me, snapshot: usage, toast: locked ? "429! 황금 칩 +3" : "토큰 환전 +12칩")

        let content: AnyView
        if let table, ["ticket-ready", "ticket-result", "ticket-429"].contains(table) {
            let amount = table == "ticket-ready" ? nil : table == "ticket-429" ? 429 : 50
            content = AnyView(LuckyDrawView(chips: 120 + (amount ?? 0), number: 1, amount: amount))
        } else if table == "settings" {
            content = AnyView(LoungeView(snapshot: usage, lastScan: .now, chips: store.chips,
                                         online: true, name: "새벽코더", showSettings: true))
        } else if table == "readme" {
            // README 대표 이미지: 라운지 · 룰렛 · 슬롯을 나란히 (--locked와 같이 쓰면 VIP HOUR)
            content = AnyView(HStack(alignment: .top, spacing: 20) {
                LoungeView(snapshot: usage, lastScan: .now, chips: store.chips, golden: store.golden(),
                           toast: store.toast, online: true, name: "새벽코더")
                RouletteView(table: fakeRoulette(store: store, me: me, mode: "roulette-win"), chips: store.chips,
                             golden: store.golden())
                SlotView(machine: fakeSlot(store: store, me: me, mode: "slot-jackpot"), chips: store.chips,
                         golden: store.golden(), vip: locked)
            }
            .padding(24)
            .background(Theme.outline))
        } else if let table, table.hasPrefix("nickname") {
            // nickname: 처음 온 회원 / nickname-taken: 이름 바꾸다 중복
            let taken = table == "nickname-taken"
            content = AnyView(LoungeView(snapshot: usage, lastScan: .now, chips: store.chips, online: true,
                                         name: taken ? "새벽코더" : nil,
                                         nicknameDraft: taken ? ("danny", "누가 벌써 쓰는 이름이에요") : nil))
        } else if let table, table.hasPrefix("update") {
            // update: 카드 펼침 / update-notice: 네온 안내 / update-required: 최소 버전 미달
            // update-sparkle: 앱에서 바로 설치할 수 있는 카드
            let required = table == "update-required"
            let cur = AppVersion(AppInfo.version) ?? AppVersion("0.3.0")!
            let next = AppVersion("\(cur.parts[0]).\(cur.parts[1] + 1).0")!
            content = AnyView(LoungeView(snapshot: usage, lastScan: .now, chips: store.chips, golden: store.golden(),
                                         online: true, name: "새벽코더", appUpdate: AppUpdate.check(current: cur, latest: next, minimum: required ? next : nil),
                                         onInstallUpdate: table == "update-sparkle" ? {} : nil,
                                         showUpdate: table == "update" || table == "update-sparkle"))
        } else if let table, table.hasPrefix("lobby-") {
            // lobby-busy | lobby-quiet | lobby-ticker: 접속 현황 (가짜 회원)
            // lobby-board | lobby-board-me | lobby-board-empty: 카드 뒷면 큰손 / lobby-flip: 뒤집는 중(반쯤)
            // lobby-daily: 지갑의 오늘의 칩 버튼
            let crowd = fakeCrowd(me: me, mode: table)
            let back = table.hasPrefix("lobby-board")
            let daily = table == "lobby-daily"
            content = AnyView(LoungeView(snapshot: usage, lastScan: .now, chips: store.chips, golden: store.golden(),
                                         online: true, crowd: crowd, board: fakeBoard(table),
                                         lastWeekRank: table.hasPrefix("lobby-board-10") || daily ? 3 : nil,
                                         dailyChipsAvailableAt: daily ? store.dailyChipsAvailableAt : nil,
                                         cardFace: back ? .back : .front, cardFrame: table == "lobby-flip" ? 1 : 0,
                                         name: "새벽코더", blackjackSeated: table == "lobby-busy" ? 2 : 0,
                                         minority: .open(closesAt: Self.kst(hour: 17), picked: false)))
        } else if let table, table.hasPrefix("wall-") {
            // wall-idle | wall-painted | wall-same | wall-limited | wall-empty: 라운지 벽화 (ADR-0017)
            content = AnyView(PixelWallView(wall: fakeWall(store: store, mode: table)))
        } else if let table, table.hasPrefix("minority-result") {
            // minority-result-win | minority-result-lose | minority-result-void
            content = AnyView(MinorityResultView(result: fakeMinorityResult(table), shownAt: .now.addingTimeInterval(-0.5)))
        } else if let table, table.hasPrefix("minority") {
            // minority-open | minority-picked | minority-closed
            content = AnyView(MinorityView(screen: fakeMinority(table), chips: store.chips))
        } else if let table, table.hasPrefix("bj-") {
            // bj-idle | bj-betting | bj-full | bj-dealing | bj-deal | bj-myturn | bj-turn | bj-dealer | bj-result
            // bj-help: 설명 카드 (뒤는 내 차례 판)
            content = AnyView(BlackjackView(table: fakeBlackjack(store: store, me: me, mode: table == "bj-help" ? "bj-myturn" : table),
                                            chips: store.chips, golden: store.golden(), showHelp: table == "bj-help"))
        } else if let table, table.hasPrefix("roulette-") {
            // roulette-idle | -betting | -golden | -alone | -spin | -cut-near | -cut-edge | -cut-land | -closed | -win | -void | -help
            content = AnyView(RouletteView(table: fakeRoulette(store: store, me: me, mode: table == "roulette-help" ? "roulette-betting" : table),
                                           chips: store.chips, golden: table == "roulette-golden" ? 3 : store.golden(),
                                           showHelp: table == "roulette-help"))
        } else if let table, table.hasPrefix("plinko") {
            // plinko-idle | -charging | -flying | -win | -big | -max | -pocket | -fever
            content = AnyView(PlinkoView(table: fakePlinko(store: store, me: me, mode: table), chips: store.chips,
                                         golden: store.golden()))
        } else if let table, table.hasPrefix("slot") {
            content = AnyView(SlotView(machine: fakeSlot(store: store, me: me, mode: table), chips: store.chips,
                                       golden: store.golden(), vip: locked))
        } else {
            content = AnyView(VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(nsImage: Sprites.menuBarIcon(vip: locked))
                    Image(nsImage: Sprites.menuBarIcon(vip: locked, busy: true))
                    Text("메뉴바 아이콘").font(Fonts.small()).foregroundStyle(.white)
                }
                .padding(6)
                .background(Color(white: 0.75))
                LoungeView(snapshot: usage, lastScan: .now, chips: store.chips, golden: store.golden(),
                           toast: store.toast, online: true, name: "새벽코더")
            })
        }

        let framed = table == "readme" ? content : AnyView(content.padding(8).background(Color(white: 0.3)))
        let renderer = ImageRenderer(content: framed.environment(\.snapshotting, true))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("snapshot failed\n".utf8))
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }

    /// 블랙잭 가짜 판: 시안과 같은 판 (린트봇 블랙잭, 나는 11에서 더블, 영희 버스트, 딜러 18)
    static func fakeBlackjack(store: LoungeStore, me: Player, mode: String) -> BlackjackTable {
        let table = BlackjackTable(store: store)
        let now = Date()
        let yhID = UUID()
        // 카드: 무늬 × 13 + 숫자 (0 스페이드, 1 하트, 2 다이아, 3 클럽 / 0 = A, 9 = 10, 12 = K)
        let ah = 13, kc = 51, td = 35, s8 = 7, h6 = 18, c5 = 43, tc = 48, d6 = 31, s9 = 8, ks = 12, c7 = 45, d2 = 27, qd = 37
        func seat(_ n: Int, _ name: String, id: UUID?, amount: Int64 = 0, cards: [Int], state: BJSeat.State,
                  action: BJSeat.Action? = nil, doubled: Bool = false, result: BJSeat.Result? = nil, payout: Int64? = nil) -> BJSeat {
            BJSeat(seat: n, playerId: id, name: name, amount: amount, doubled: doubled, cards: cards, state: state,
                   lastAction: action, result: result, payout: payout)
        }
        let lint = seat(1, "린트봇", id: nil, cards: [ah, kc], state: .blackjack)
        let build = seat(2, "빌드봇", id: nil, cards: [td, s8], state: .stood, action: .stand)
        func mine(_ cards: [Int], _ state: BJSeat.State, doubled: Bool = false, result: BJSeat.Result? = nil, payout: Int64? = nil) -> BJSeat {
            seat(3, "새벽코더", id: me.id, amount: 100, cards: cards, state: state, action: doubled ? .double : nil,
                 doubled: doubled, result: result, payout: payout)
        }
        func yh(_ cards: [Int], _ state: BJSeat.State, action: BJSeat.Action? = nil, result: BJSeat.Result? = nil, payout: Int64? = nil) -> BJSeat {
            seat(4, "영희", id: yhID, amount: 50, cards: cards, state: state, action: action, result: result, payout: payout)
        }
        func round(_ phase: BJRound.Phase, closed: TimeInterval, turn: Int? = nil, deadline: TimeInterval? = nil,
                   dealer: [Int], next: TimeInterval? = nil) -> BJRound {
            BJRound(id: 1, phase: phase, betClosesAt: now.addingTimeInterval(closed), turnSeat: turn,
                    turnDeadline: deadline.map { now.addingTimeInterval($0) }, dealerCards: dealer,
                    nextAt: next.map { now.addingTimeInterval($0) })
        }
        let at = { (s: TimeInterval) in now.addingTimeInterval(s) }
        switch mode {
        case "bj-idle":
            table.apply(BJState(now: now, round: nil, seats: []))
        case "bj-betting":
            table.apply(BJState(now: now, round: round(.betting, closed: 7, dealer: []),
                                seats: [seat(1, "영희", id: yhID, amount: 50, cards: [], state: .waiting)]))
        case "bj-full":
            let names = ["영희", "철수", "민수", "지호"]
            table.apply(BJState(now: now, round: round(.betting, closed: 5, dealer: []),
                                seats: names.enumerated().map { seat($0 + 1, $1, id: UUID(), amount: 50, cards: [], state: .waiting) }))
        case "bj-dealing":
            // 딜 1.3초째: 둘째 장이 날아가는 중
            table.apply(BJState(now: now, round: round(.playing, closed: -1.55, dealer: [s9]),
                                seats: [lint, seat(2, "빌드봇", id: nil, cards: [td, s8], state: .playing),
                                        mine([h6, c5], .playing), yh([tc, d6], .playing)]))
        case "bj-deal":
            table.apply(BJState(now: now, round: round(.playing, closed: -3.1, deadline: 0, dealer: [s9]),
                                seats: [lint, seat(2, "빌드봇", id: nil, cards: [td, s8], state: .playing),
                                        mine([h6, c5], .playing), yh([tc, d6], .playing)]))
        case "bj-myturn":
            table.apply(BJState(now: now, round: round(.playing, closed: -20, turn: 3, deadline: 7, dealer: [s9]),
                                seats: [lint, build, mine([h6, c5], .playing), yh([tc, d6], .playing)]))
            table.preview(actions: [2: .init(action: .stand, cards: 2, at: at(-1))], myTurnSince: at(-1))
        case "bj-turn":
            // 영희가 히트: 카드가 날아가는 중 (서버는 이미 버스트지만 화면은 도착해야 안다)
            table.apply(BJState(now: now, round: round(.playing, closed: -40, turn: 4, deadline: 0.6, dealer: [s9]),
                                seats: [lint, build, mine([h6, c5, ks], .stood, doubled: true), yh([tc, d6, qd], .bust, action: .hit)]))
            table.preview(arrivals: ["s4-2": at(0.12)], actions: [4: .init(action: .hit, cards: 3, at: at(-0.2))])
        case "bj-dealer":
            table.apply(BJState(now: now, round: round(.dealer, closed: -50, deadline: 1, dealer: [s9, c7, d2]),
                                seats: [lint, build, mine([h6, c5, ks], .stood, doubled: true), yh([tc, d6, qd], .bust, action: .hit)]))
            table.preview(arrivals: ["d-1": at(-0.7), "d-2": at(0.15)])
        default: // bj-result
            table.apply(BJState(now: now, round: round(.done, closed: -60, dealer: [s9, c7, d2], next: 4),
                                seats: [seat(1, "린트봇", id: nil, cards: [ah, kc], state: .blackjack, result: .blackjack),
                                        seat(2, "빌드봇", id: nil, cards: [td, s8], state: .stood, result: .push),
                                        mine([h6, c5, ks], .stood, doubled: true, result: .win, payout: 400),
                                        yh([tc, d6, qd], .bust, result: .lose, payout: 0)]))
            table.preview(arrivals: ["d-2": at(-1.0)])
        }
        return table
    }

    /// 미니 룰렛 가짜 판: 시안과 같은 판 (나 7에 50 · 빨강 50, 철수 홀 100, 영희 9 50 · 빨강 50)
    static func fakeRoulette(store: LoungeStore, me: Player, mode: String) -> RouletteTable {
        let table = RouletteTable(store: store)
        let now = Date()
        let cs = UUID(), yh = UUID()
        func bet(_ id: UUID, _ name: String, _ spot: Roulette.Spot, _ amount: Int64, golden: Bool = false, result: Int? = nil) -> RouletteBet {
            RouletteBet(playerId: id, name: name, spot: spot, amount: amount, golden: golden,
                        payout: result.map { r in golden && r == 0 ? 0 : amount * Int64(spot.multiplier(r)) })
        }
        func crowd(_ mine: [(Roulette.Spot, Int64, Bool)], others: Bool = true, result: Int? = nil) -> [RouletteBet] {
            mine.map { bet(me.id, me.name, $0.0, $0.1, golden: $0.2, result: result) }
                + (others ? [bet(cs, "철수", .odd, 100, result: result), bet(yh, "영희", .number(9), 50, result: result),
                             bet(yh, "영희", .red, 50, result: result)] : [])
        }
        let mine: [(Roulette.Spot, Int64, Bool)] = [(.number(7), 50, false), (.red, 50, false)]
        func round(closesIn: TimeInterval, result: Int? = nil) -> RouletteRound {
            RouletteRound(id: 2, betClosesAt: now.addingTimeInterval(closesIn), result: result)
        }
        switch mode {
        case "roulette-idle":
            // 지난 판(9)에 건 칩이 남아 있어도 칸 위엔 안 보여야 한다
            table.apply(RouletteState(now: now, round: round(closesIn: -20, result: 9), bets: crowd(mine, result: 9), lastResult: 4))
        case "roulette-golden":
            table.useGolden = true
            table.apply(RouletteState(now: now, round: round(closesIn: 8.6), bets: crowd([(.black, 100, true)]), lastResult: 9))
        case "roulette-alone":
            table.apply(RouletteState(now: now, round: round(closesIn: 9.6), bets: crowd([(.red, 50, false)], others: false), lastResult: 9))
        case "roulette-spin":
            table.apply(RouletteState(now: now, round: round(closesIn: -2.4, result: 7), bets: crowd(mine), lastResult: 9))
        case "roulette-closed":
            table.apply(RouletteState(now: now, round: round(closesIn: -1.5, result: 7), bets: crowd([]), lastResult: 9))
            table.preview(closedAt: now.addingTimeInterval(-0.3))
        case "roulette-win":
            table.apply(RouletteState(now: now, round: round(closesIn: -Roulette.spin - 0.8, result: 7), bets: crowd(mine, result: 7), lastResult: 9))
        case "roulette-void":
            table.apply(RouletteState(now: now, round: round(closesIn: -Roulette.spin - 0.8, result: 0), bets: crowd(mine, result: 0), lastResult: 9))
        case "roulette-cut-near", "roulette-cut-edge", "roulette-cut-land":
            // 클로즈업 컷: 결과 6. 나 6에 10 + 빨강 50 (9에서 다음 칸을 기다림 / 칸막이 위 / 6에 멈춤)
            let e: TimeInterval = mode == "roulette-cut-near" ? 5.0 : mode == "roulette-cut-edge" ? 5.8 : 6.3
            table.apply(RouletteState(now: now, round: round(closesIn: -e, result: 6),
                                      bets: crowd([(.number(6), 10, false), (.red, 50, false)], result: 6), lastResult: 9))
        default: // roulette-betting
            table.apply(RouletteState(now: now, round: round(closesIn: 8.6), bets: crowd(mine), lastResult: 9))
        }
        return table
    }

    /// 실서버 룰렛 테이블에 앉아 `seconds` 동안 상태를 찍고 마지막 화면을 저장한다 (Realtime 검증용).
    /// LOUNGE_E2E_BET=golden|chips면 판이 열려 있을 때 한 번 건다 (chips: 빨강 50 + 7에 10, golden: 홀에 황금 칩)
    static func renderRouletteLive(to path: String, seconds: Int) {
        Task { @MainActor in
            let store = LoungeStore(live: false)
            await store.connect()
            guard let me = store.me else {
                print("connect failed: \(store.netError ?? "?")")
                exit(1)
            }
            print("signed in as \(me.name) · chips \(me.chips)")
            await store.refresh() // 토큰 환전 + (LOUNGE_FAKE_429면) 황금 칩
            print("after claim · chips \(store.chips) · golden \(store.golden())")
            let table = RouletteTable(store: store)
            table.enter()
            let mode = ProcessInfo.processInfo.environment["LOUNGE_E2E_BET"]
            var placed = false
            var last = ""
            for _ in 0..<(seconds * 2) {
                try? await Task.sleep(for: .milliseconds(500))
                let phase = table.phase(at: .now)
                if let mode, !placed, table.state != nil, phase == .idle || { if case .betting(let l) = phase { l > 2 } else { false } }() {
                    placed = true
                    if mode == "golden" {
                        table.useGolden = true
                        await table.bet(.odd)
                    } else {
                        table.stake = 50
                        await table.bet(.red)
                        table.stake = 10
                        await table.bet(.number(7))
                    }
                    print("bet → \(table.myBets.map { "\($0.spot.rawValue) \($0.amount)\($0.golden ? " golden" : "")" }) · \(table.message ?? "ok") · chips \(store.chips) · golden \(store.golden())")
                }
                let line = "#\(table.round?.id ?? -1) \(phase) · bets \(table.players().map { "\($0.name) \($0.staked)\($0.net.map { " net \($0)" } ?? "")" })"
                if line != last { print(line); last = line }
            }
            print("chips \(store.chips) · golden \(store.golden())")
            write(AnyView(RouletteView(table: table, chips: store.chips, golden: store.golden())), to: path)
            table.leave()
            exit(0)
        }
        // ImageRenderer는 메인 런루프가 필요하다 (dispatchMain으론 멈춤)
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
    }

    /// 실서버 라운지 벽화를 열고 `seconds` 동안 새 칸이 들어올 때마다 찍는다 (Realtime 검증용).
    /// 대체 갱신은 30초라, 지연이 몇 초 안이면 Realtime으로 받은 것
    static func renderWallLive(to path: String, seconds: Int) {
        Task { @MainActor in
            let store = LoungeStore(live: false)
            await store.connect()
            guard let me = store.me else { print("connect failed: \(store.netError ?? "?")"); exit(1) }
            print("signed in as \(me.name)")
            let wall = PixelWall(store: store)
            wall.enter()
            var seen: Date?
            for _ in 0..<(seconds * 4) {
                try? await Task.sleep(for: .milliseconds(250))
                guard let s = wall.state else { continue }
                guard let newest = s.pixels.max(by: { $0.at < $1.at }) else { continue }
                if seen == nil { print("board · \(s.pixels.count)칸 · 내 버킷 \(s.left)/\(s.cap)") }
                if let seen, newest.at <= seen { continue }
                if seen != nil {
                    let lag = Date.now.timeIntervalSince(newest.at.addingTimeInterval(-wall.skew))
                    print(String(format: "+ %@ %d,%d 색%d · 지연 %.1f초 · 총 %d칸", newest.p, newest.x + 1, newest.y + 1, newest.c, lag, s.pixels.count))
                }
                seen = newest.at
            }
            write(AnyView(PixelWallView(wall: wall)), to: path)
            wall.leave()
            exit(0)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
    }

    /// 실서버 블랙잭 테이블에 앉아 `seconds` 동안 매초 상태를 찍고 마지막 화면을 저장한다.
    /// LOUNGE_E2E_BET=1이면 앱 계정도 걸고, 내 차례엔 12 미만 히트 · 그 외 스탠드
    static func renderBlackjackLive(to path: String, seconds: Int) {
        Task { @MainActor in
            let store = LoungeStore(live: false)
            await store.connect()
            guard let me = store.me else { print("connect failed"); exit(1) }
            print("signed in as \(me.name) · chips \(me.chips)")
            let table = BlackjackTable(store: store)
            table.enter()
            let play = ProcessInfo.processInfo.environment["LOUNGE_E2E_BET"] != nil
            table.stake = 30
            var last = ""
            for _ in 0..<(seconds * 2) {
                try? await Task.sleep(for: .milliseconds(500))
                let now = Date()
                if play, table.mySeat == nil, !table.busy, table.idle(at: now) || table.round?.phase == .betting {
                    await table.bet()
                    print("bet → seat \(table.mySeat?.seat ?? 0) · \(table.message ?? "ok") · chips \(store.chips)")
                }
                if play, let r = table.round, let mine = table.mySeat, r.phase == .playing, r.turnSeat == mine.seat,
                   mine.state == .playing, !table.busy, now >= table.local(r.betClosesAt).addingTimeInterval(3.5) {
                    let t = BJCard.total(mine.cards.map(BJCard.init)).value
                    await table.act(t < 12 ? .hit : .stand)
                    print("act \(t < 12 ? "hit" : "stand") at \(t) → \(table.message ?? "ok")")
                }
                guard let r = table.round else { continue }
                let seats = table.seats.map { s in
                    "\(s.seat):\(s.name)\(s.bot ? "(AI)" : "") \(BJCard.total(s.cards.map(BJCard.init)).value)/\(s.state.rawValue)\(s.result.map { "=" + $0.rawValue } ?? "")"
                }.joined(separator: " ")
                let line = "#\(r.id) \(r.phase.rawValue) turn \(r.turnSeat.map(String.init) ?? "-") dealer \(BJCard.total(r.dealerCards.map(BJCard.init)).value) | \(seats)"
                if line != last { print(line); last = line }
            }
            print("chips \(store.chips)")
            write(AnyView(BlackjackView(table: table, chips: store.chips, golden: store.golden())), to: path)
            table.leave()
            exit(0)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
    }

    /// 실서버 429 드롭에 앉아 `seconds` 동안 상태를 찍고 마지막 화면을 저장한다 (착지 때 지갑이 바뀌는지 확인용).
    /// LOUNGE_E2E_BET=1: 앱 계정도 1.5초마다 한 번 누르고 뗀다(눌림 0.1~1.2초) / auto: AUTO로 / golden: 황금 칩 한 번
    /// 끝나면 떠 있는 공이 다 내려올 때까지 기다린 뒤 서버에 기록된 판 수와 칩을 비교한다
    static func renderPlinkoLive(to path: String, seconds: Int) {
        Task { @MainActor in
            let store = LoungeStore(live: false)
            await store.connect()
            guard let me = store.me else { print("connect failed: \(store.netError ?? "?")"); exit(1) }
            print("signed in as \(me.name) · chips \(me.chips) · golden \(store.golden())")
            let table = PlinkoTable(store: store)
            table.log = { print("  \($0)") }
            table.enter()
            // LOUNGE_PLINKO_WINDOW=1: 실제 창에 띄워 그리면서 잰다 (화면 그리기가 틱을 미는지 확인용)
            if ProcessInfo.processInfo.environment["LOUNGE_PLINKO_WINDOW"] == "1" {
                NSApplication.shared.setActivationPolicy(.accessory)
                let host = NSHostingView(rootView: PlinkoLiveHost(table: table, store: store))
                let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 340, height: 560),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                plinkoWindow = window
                if ProcessInfo.processInfo.environment["LOUNGE_PLINKO_SOUND"] == "1" {
                    let was = GameAudio.shared.enabled
                    GameAudio.shared.enabled = true
                    GameAudio.shared.setVisible(true)
                    GameAudio.shared.enter(.floor)
                    table.onSound = { GameAudio.shared.plinko($0) }
                    GameAudio.shared.warmPlinko()
                    atexit_b { MainActor.assumeIsolated { GameAudio.shared.enabled = was } }
                }
            }
            let mode = ProcessInfo.processInfo.environment["LOUNGE_E2E_BET"]
            table.stake = 10
            let start = store.chips
            var presses = 0
            if mode == "auto" { table.auto = true }
            if mode == "golden", store.golden() > 0 {
                table.useGolden = true
                table.press(at: .now)
                table.release(at: .now.addingTimeInterval(0.9))
                presses += 1
                print("golden drop · 보이는 칩 \(table.shown(chips: store.chips))")
            }
            var last = ""
            for i in 0..<(seconds * 4) {
                try? await Task.sleep(for: .milliseconds(250))
                if mode == "1", i % 6 == 0, !table.charging {
                    let held = Double.random(in: 0.1...1.2)
                    let t0 = Date()
                    table.lane = Int.random(in: -1...1)
                    table.press(at: t0)
                    if table.charging {
                        table.release(at: t0.addingTimeInterval(held))
                        presses += 1
                        print("drop #\(presses) 레인 \(table.lane) 눌림 \(String(format: "%.2f", held))초 → 파워 \(table.lastPower) \(PlinkoGauge.grade(power: table.lastPower).rawValue)")
                    } else {
                        print("drop 막힘 · \(table.blockReason(chips: store.chips, golden: store.golden()) ?? "?") \(table.message ?? "")")
                    }
                }
                let line = "공 \(table.inFlight)/5 fever \(table.feverActive) · 보이는 칩 \(table.shown(chips: store.chips)) / 서버 \(store.chips)\(table.message.map { " · \($0)" } ?? "")"
                if line != last { print(line); last = line }
            }
            table.auto = false
            // 떠 있는 공이 다 닿을 때까지
            for _ in 0..<120 where table.inFlight > 0 || table.feverActive || table.shown(chips: store.chips) != store.chips {
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .milliseconds(500))
            print("끝 · 보이는 칩 \(table.shown(chips: store.chips)) / 서버 \(store.chips) · 시작 \(start) → 변화 \(store.chips - start)")
            write(AnyView(PlinkoView(table: table, chips: store.chips, golden: store.golden())), to: path)
            table.leave()
            exit(0)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
    }

    /// 실서버에서 슬롯을 `spins`번 돌리고 마지막 화면을 찍는다
    static func renderSlotLive(to path: String, spins: Int) {
        Task { @MainActor in
            let store = LoungeStore(live: false)
            await store.connect()
            guard store.me != nil else { print("connect failed"); exit(1) }
            let machine = SlotMachine(store: store)
            machine.stake = 10
            for i in 1...spins {
                let before = store.chips
                await machine.spin()
                let r = machine.result
                print("spin \(i): \(r?.initialReels.joined(separator: " ") ?? "-") → \(r?.reels.joined(separator: " ") ?? "-") glitched \(r?.glitched ?? []) vip \(r?.vip ?? false) ×\(r?.payoutMultiplier ?? -1) payout \(r?.payout ?? -1) · chips \(before) → \(store.chips) \(machine.message ?? "")")
            }
            try? await Task.sleep(for: .seconds(0.4))
            write(AnyView(SlotView(machine: machine, chips: store.chips, golden: store.golden())), to: path)
            exit(0)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
    }

    /// 실서버 라운지에 접속해 `seconds`초 동안 회원 목록을 지켜보고 화면을 찍는다
    static func renderLobbyLive(to path: String, seconds: Int) {
        Task { @MainActor in
            let store = LoungeStore(live: false)
            await store.connect()
            guard store.me != nil else { print("connect failed"); exit(1) }
            store.viewing = true
            for i in 1...seconds {
                try? await Task.sleep(for: .seconds(1))
                let c = store.crowd()
                let names = c.others.map { "\($0.name)\($0.viewing ? "👁" : "")\($0.status.map { "·" + $0.rawValue } ?? "")" }
                print("t+\(i)s total \(c.total) viewing \(c.viewing) roulette \(c.roulette) others \(names) events \(c.events.map { "\($0.name) \($0.kind) \($0.amount)" }) dot \(store.tableBusy)")
            }
            await store.loadBoard()
            await store.tickMinority()
            print("minority \(store.minority.map { "round \($0.round.map { "\($0.question) \($0.optionA)/\($0.optionB) 참가 \($0.participants) 내 선택 \($0.myPick.map(String.init) ?? "-")" } ?? "-") · next \($0.nextOpensAt.map { "\($0)" } ?? "-") · mine \($0.mine.map { "\($0.question) win \($0.winner.map(String.init) ?? "무효") net \($0.net)" } ?? "-")" } ?? "nil") · toast \(store.toast?.text ?? "-")")
            print("board \(store.board.map { $0.map { "\($0.rank). \($0.name) \($0.net)\($0.me ? " (나)" : "")" } } ?? ["-"])")
            write(AnyView(LoungeView(snapshot: store.snapshot, lastScan: .now, chips: store.chips, online: true,
                                     crowd: store.crowd(), board: store.board, name: store.me?.name)), to: path)
            exit(0)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
    }

    private static func write(_ content: AnyView, to path: String) {
        let renderer = ImageRenderer(content: content.padding(8).background(Color(white: 0.3)).environment(\.snapshotting, true))
        renderer.scale = 2
        if let tiff = renderer.nsImage?.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
    }

    /// mode: slot-idle | slot-spinning | slot-glitch | slot-win | slot-big | slot-jackpot | slot-lose
    private static func fakeWall(store: LoungeStore, mode: String) -> PixelWall {
        let rows = [
            "",
            "..n.n.nnn.nnn.............gg",
            "..n.n...n.n.n............g",
            "..nnn.nnn.nnn............g",
            "....n.n.....n............g",
            "....n.nnn.nnn.............gg",
            "",
            ".......c..............y.........c",
            "",
            "...yyyyyyyyy",
            "....ynnnnny......c.......c",
            ".....ynnny.......cc.....cc",
            "......yny........ccccccccc.nn.nn",
            ".......y.........cckccckcc.nnnnn",
            ".......y.........ccccncccc..nnn",
            ".......y.........ccckckccc...n",
            ".....yyyyy.......ccccccccc",
            "",
            "..c..........................y",
            "",
            "..e.e.e.....mmmmmmmmmm",
            "..eeeee.....mkkkkkkkkm..g",
            "...eee......mkyykccckm",
            "....e.......mkkggkyykm",
            "....e.......mkkkkkkkkm",
            ".ffffff.....mmmmmmmmmm",
            "fffffffff.......mm",
            "fffffffff....mmmmmmmm",
            "",
            "...c.........n.......y.....g",
        ]
        let colors: [Character: Int] = ["c": 0, "n": 1, "g": 2, "y": 3, "e": 4, "f": 5, "m": 6, "k": 7]
        func owner(_ x: Int, _ y: Int) -> String {
            if y <= 5 { return "영희" }
            if (9...16).contains(y) && x <= 12 { return "철수" }
            if (10...16).contains(y) && (17...25).contains(x) { return "민수" }
            if y >= 12 && x >= 26 { return "예린" }
            if (20...27).contains(y) { return "새벽코더" }
            return "우진"
        }
        let now = Date.now
        var pixels: [PixelBoardState.Pixel] = []
        if mode != "wall-empty" {
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let c = colors[ch] else { continue }
                    pixels.append(.init(x: x, y: y, c: c, p: owner(x, y), at: now.addingTimeInterval(-Double((x * 7 + y * 13) % 50) * 60)))
                }
            }
        }
        let counts = Dictionary(grouping: pixels, by: \.p).mapValues(\.count).sorted { $0.value > $1.value }
        let painters = counts.map { PixelBoardState.Painter(name: $0.key, count: $0.value, me: $0.key == "새벽코더") }
        let limited = mode == "wall-limited"
        let left = limited ? 0 : mode == "wall-painted" ? 6 : mode == "wall-empty" ? 10 : 7
        let wall = PixelWall(store: store)
        wall.apply(PixelBoardState(now: now, left: left, nextAt: left == 10 ? nil : now.addingTimeInterval(24),
                                   pixels: pixels, painters: painters))
        switch mode {
        case "wall-painted": wall.preview(response: .created(.init(x: 24, y: 21)), selected: .init(x: 24, y: 21), color: 2)
        case "wall-same": wall.preview(response: .same, selected: .init(x: 20, y: 14), color: 1)
        case "wall-limited": wall.preview(response: .limited, selected: .init(x: 24, y: 21), color: 2)
        case "wall-empty": wall.preview(response: .idle, selected: nil, color: 1)
        default: wall.preview(response: .idle, selected: nil, hover: .init(x: 20, y: 13), color: 1)
        }
        return wall
    }

    /// 429 드롭 가짜 장면: 시드를 고정해 서버 규칙대로 뽑은 한 판을 틱으로 되감아 재생한다
    static func fakePlinko(store: LoungeStore, me: Player, mode: String) -> PlinkoTable {
        let table = PlinkoTable(store: store, seed: 429)
        func drop(_ lane: Int, grade: PlinkoDrop.Grade = .none, amount: Int64 = 100, forceCatch: Bool = false,
                  reels: [String]? = nil, fever: Bool = false, matching: (PlinkoBall) -> Bool = { _ in true }) {
            let player = Player(id: me.id, name: me.name, chips: Int64(store.chips), goldenChips: me.goldenChips, goldenUntil: me.goldenUntil)
            table.preview(drop: PlinkoFake.drop(player: player, lane: lane, amount: amount, grade: grade,
                                                forceCatch: forceCatch, reels: reels, fever: fever, matching: matching))
        }
        switch mode {
        case "plinko-charging":
            // 앞서 쏜 공 둘: 먼저 것은 한참 내려갔고, 나중 것은 PERFECT라 포켓이 열려 있다
            drop(0) { $0.bucket != nil }
            table.advance(24)
            drop(1, grade: .perfect) { $0.bucket != nil && $0.split == nil }
            table.advance(8)
            table.lane = 1
            table.previewCharging(power: 850)
            table.advance(6)
        case "plinko-flying":
            // 분열: 오른쪽 레인 공이 (10, 8) 분열 핀을 맞고 둘로 갈라진 직후. 다른 공은 왼쪽 레인
            drop(1, grade: .good) { $0.split != nil && $0.clone != nil }
            table.advance(10)
            drop(-1) { $0.bucket != nil && $0.split == nil }
            table.advance(24)
        case "plinko-win":
            drop(0) { $0.bucket == 2 && $0.gold == 0 && $0.split == nil }
            table.advance(43)
        case "plinko-big":
            drop(0, grade: .perfect) { ($0.bucket == 1 || $0.bucket == 11) && $0.split == nil && $0.gold == 0 }
            table.advance(41)
        case "plinko-max":
            drop(0) { $0.bucket == 0 && $0.split == nil }
            table.advance(41)
        case "plinko-pocket":
            drop(0, forceCatch: true) { $0.pocket }
            table.advance(38)
        case "plinko-fever":
            drop(0, forceCatch: true, fever: true) { $0.pocket }
            table.advance(118)
        default: break
        }
        return table
    }

    private static func fakeSlot(store: LoungeStore, me: Player, mode: String) -> SlotMachine {
        let m = SlotMachine(store: store)
        func result(_ reels: [String], _ mult: Int, initial: [String]? = nil, glitched: [Int] = []) -> SlotResult {
            SlotResult(reels: reels, initialReels: initial, glitched: glitched, vip: true,
                       multiplier: mult, payout: 50 * Int64(mult), player: me)
        }
        switch mode {
        case "slot-spinning": m.preview(result: result(["bar", "bar", "bar"], 20), elapsed: 0.75, pending: true)
        case "slot-glitch":
            // 세 릴이 멈추고 500 글리치가 한창인 순간
            m.preview(result: result(["cherry", "bell", "cherry"], 3, initial: ["cherry", "bell", "500"], glitched: [2]),
                      elapsed: 1.6 + 0.25 + 0.25, pending: true)
        case "slot-win": m.preview(result: result(["cherry", "bell", "cherry"], 3), finishedAgo: 0.35)
        case "slot-single-429":
            m.preview(result: SlotResult(reels: ["bell", "429", "blank"], multiplier: 1,
                                         payoutMultiplier: 1.8, payout: 90, player: me), finishedAgo: 0.35)
        case "slot-big": m.preview(result: result(["seven", "seven", "seven"], 50), finishedAgo: 0.9)
        case "slot-jackpot": m.preview(result: result(["429", "429", "429"], 429), finishedAgo: 1.2)
        case "slot-lose": m.preview(result: result(["seven", "blank", "bell"], 0), finishedAgo: 1)
        default: break
        }
        return m
    }

    /// 오늘(지났으면 다음 날) KST hour시 정각
    private static func kst(hour: Int, weekday: Int? = nil) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        var c = DateComponents(hour: hour, minute: 0, second: 0)
        c.weekday = weekday
        return cal.nextDate(after: .now, matching: c, matchingPolicy: .nextTime)!
    }

    private static func fakeMinorityResult(_ mode: String) -> MinorityResult {
        func p(_ n: String, _ c: Int) -> MinorityResult.Pick { .init(name: n, choice: c, me: n == "나") }
        switch mode {
        case "minority-result-lose":
            return MinorityResult(question: "금요일 오후 배포", options: ("한다", "안 한다"),
                                  picks: [p("나", 0), p("예린", 0), p("민수", 0), p("지호", 1)], winner: 1, amount: 50, net: -50)
        case "minority-result-void":
            return MinorityResult(question: "아침 첫 잔", options: ("아아", "뜨아"),
                                  picks: [p("나", 0), p("예린", 0), p("지호", 0)], winner: nil, amount: 50, net: 0)
        default:
            return MinorityResult(question: "금요일 오후 배포", options: ("한다", "안 한다"),
                                  picks: [p("나", 1), p("예린", 0), p("민수", 0), p("철수", 0), p("영희", 0)],
                                  winner: 1, amount: 50, net: 200)
        }
    }

    private static func fakeMinority(_ mode: String) -> MinorityScreen {
        let deploy = MinorityScreen.Round(question: "금요일 오후 배포", options: ("한다", "안 한다"),
                                          closesAt: kst(hour: 17), stake: 50, participants: 4)
        switch mode {
        case "minority-picked":
            var r = deploy
            r.myPick = 1
            return MinorityScreen(round: r)
        case "minority-closed":
            // 금요일 17시 정산 뒤: 다음 판은 월요일 8시
            return MinorityScreen(round: nil, nextOpensAt: kst(hour: 8, weekday: 2),
                                  mine: .init(question: "금요일 오후 배포", winner: "안 한다", amount: 50, net: 200))
        default:
            return MinorityScreen(round: deploy)
        }
    }

    private static func fakeBoard(_ mode: String) -> [BoardRow]? {
        switch mode {
        case "lobby-board-empty": return []
        case "lobby-board-10", "lobby-board-10-me":
            // 열 명이 꽉 찬 판. -me는 내가 14위 (10위 밖이라 아래에 고정)
            let names = ["지호", "예린", "민수", "서연", "madman", "하루", "도윤", "채원", "리안", "준"]
            var rows = names.enumerated().map { i, n in
                BoardRow(rank: i + 1, name: n, net: Int64(21_450 - i * 2_300), me: mode == "lobby-board-10" && i == 3)
            }
            if mode == "lobby-board-10-me" { rows.append(BoardRow(rank: 14, name: "새벽코더", net: -600, me: true)) }
            return rows
        case "lobby-board-me":
            // 내가 4위 밖
            return [BoardRow(rank: 1, name: "지호", net: 21_450), BoardRow(rank: 2, name: "예린", net: 1_850),
                    BoardRow(rank: 3, name: "민수", net: 320), BoardRow(rank: 7, name: "새벽코더", net: -600, me: true)]
        default:
            return [BoardRow(rank: 1, name: "지호", net: 21_450), BoardRow(rank: 2, name: "새벽코더", net: 1_850, me: true),
                    BoardRow(rank: 3, name: "madman", net: 0)]
        }
    }

    private static func fakeCrowd(me: Player, mode: String) -> LoungeCrowd {
        func m(_ name: String, viewing: Bool = false, place: Member.Place = .lounge, _ status: Member.Status? = nil) -> Member {
            Member(id: UUID(), name: name, viewing: viewing, place: place, status: status)
        }
        let mine = Member(id: me.id, name: "새벽코더", viewing: true)
        let busy = [
            mine,
            m("철수", viewing: true, place: .roulette, .coding), m("영희", viewing: true, place: .roulette),
            m("예린", .vip), m("민수", .coding), m("지호", .coding), m("하준", .coding),
            m("서연", .resting), m("도윤", .resting), m("수아"), m("우진", .coding), m("지은", .resting),
        ]
        let now = Date()
        func r(_ name: String, _ ago: TimeInterval) -> Regular { Regular(id: UUID(), name: name, lastSeenAt: now.addingTimeInterval(-ago)) }
        // 오프라인 명부 회원 (ADR-0011)
        let away = [r("논스탁", 40), r("madman", 12 * 60), r("집산다", 3 * 3600), r("조곽철", 2 * 86_400)]
        switch mode {
        case "lobby-quiet":
            return LoungeCrowd(members: [mine, m("예린", .vip)], roster: away, me: me.id, events: [])
        case "lobby-alone":
            return LoungeCrowd(members: [mine], me: me.id, events: [])
        case "lobby-ticker":
            let events = [
                LoungeEvent(id: 1, kind: "bigwin", game: "slot", name: "민수", amount: 1_000, createdAt: now.addingTimeInterval(-40)),
                LoungeEvent(id: 2, kind: "jackpot", game: "slot", name: "지호", amount: 21_450, createdAt: now.addingTimeInterval(-5)),
            ]
            return LoungeCrowd(members: busy, me: me.id, events: events)
        default:
            return LoungeCrowd(members: busy, roster: away, me: me.id, events: [])
        }
    }
}
