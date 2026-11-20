import AppKit
import LoungeCore
import LoungeNet
import SwiftUI

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
        if table == "readme" {
            // README 대표 이미지: 라운지 · 홀짝 · 슬롯을 나란히 (--locked와 같이 쓰면 VIP HOUR)
            content = AnyView(HStack(alignment: .top, spacing: 20) {
                LoungeView(snapshot: usage, lastScan: .now, chips: store.chips, golden: store.golden(),
                           toast: store.toast, online: true, name: "새벽코더")
                OddEvenView(table: fakeTable(store: store, me: me, mode: "crowd-won"), chips: store.chips,
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
            // update: 새 버전 안내(카드 펼침) / update-required: 최소 버전 미달
            let required = table == "update-required"
            let cur = AppVersion(AppInfo.version) ?? AppVersion("0.3.0")!
            let next = AppVersion("\(cur.parts[0]).\(cur.parts[1] + 1).0")!
            content = AnyView(LoungeView(snapshot: usage, lastScan: .now, chips: store.chips, golden: store.golden(),
                                         online: true, name: "새벽코더", appUpdate: AppUpdate.check(current: cur, latest: next, minimum: required ? next : nil),
                                         showUpdate: !required))
        } else if let table, table.hasPrefix("lobby-") {
            // lobby-busy | lobby-quiet | lobby-ticker: 접속 현황 (가짜 회원)
            // lobby-board | lobby-board-me | lobby-board-empty: 카드 뒷면 큰손 / lobby-flip: 뒤집는 중(반쯤)
            let crowd = fakeCrowd(me: me, mode: table)
            let back = table.hasPrefix("lobby-board")
            content = AnyView(LoungeView(snapshot: usage, lastScan: .now, chips: store.chips, golden: store.golden(),
                                         online: true, crowd: crowd, board: fakeBoard(table),
                                         cardFace: back ? .back : .front, cardFrame: table == "lobby-flip" ? 1 : 0,
                                         name: "새벽코더",
                                         minority: .open(closesAt: Self.kst(hour: 17), picked: false)))
        } else if let table, table.hasPrefix("minority-result") {
            // minority-result-win | minority-result-lose | minority-result-void
            content = AnyView(MinorityResultView(result: fakeMinorityResult(table), shownAt: .now.addingTimeInterval(-0.5)))
        } else if let table, table.hasPrefix("minority") {
            // minority-open | minority-picked | minority-closed
            content = AnyView(MinorityView(screen: fakeMinority(table), chips: store.chips))
        } else if let table, table.hasPrefix("slot") {
            content = AnyView(SlotView(machine: fakeSlot(store: store, me: me, mode: table), chips: store.chips,
                                       golden: store.golden(), vip: locked))
        } else if let table {
            content = AnyView(OddEvenView(table: fakeTable(store: store, me: me, mode: table), chips: store.chips, golden: store.golden()))
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

    /// 실제 서버에 접속해 테이블에 앉은 뒤 `seconds` 후의 화면을 찍는다 (Realtime 검증용)
    static func renderLive(to path: String, seconds: Double) {
        Task { @MainActor in
            let store = LoungeStore(live: false)
            await store.connect()
            guard let me = store.me else {
                print("connect failed: \(store.netError ?? "?")")
                exit(1)
            }
            print("signed in as \(me.name) · chips \(me.chips) · toast \(store.toast?.text ?? "-")")
            await store.refresh() // 토큰 환전 + (LOUNGE_FAKE_429면) 황금 칩
            print("after claim · chips \(store.chips) · golden \(store.golden()) · toast \(store.toast?.text ?? "-")")
            let table = OddEvenTable(store: store)
            table.enter()
            // LOUNGE_E2E_BET=golden|chips → 베팅이 열리면 홀에 건다
            if let mode = ProcessInfo.processInfo.environment["LOUNGE_E2E_BET"] {
                while table.myBet == nil {
                    if case .betting(let left) = table.phase(at: .now), left > 1 {
                        table.useGolden = mode == "golden"
                        await table.place(.odd)
                        print("bet → \(table.myBet.map { "\($0.side) \($0.amount) golden=\($0.golden)" } ?? table.message ?? "?") · chips \(store.chips) · golden \(store.golden())")
                        if table.myBet == nil { break }
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            try? await Task.sleep(for: .seconds(seconds))
            print("round \(table.round?.id ?? -1) · bets \(table.bets.count) · seats \(table.seats.map(\.name)) · last \(table.last?.marbles ?? -1)")
            write(AnyView(OddEvenView(table: table, chips: store.chips, golden: store.golden())), to: path)
            table.leave()
            exit(0)
        }
        // ImageRenderer는 메인 런루프가 필요하다 (dispatchMain으론 멈춤)
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
                print("spin \(i): \(r?.initialReels.joined(separator: " ") ?? "-") → \(r?.reels.joined(separator: " ") ?? "-") glitched \(r?.glitched ?? []) vip \(r?.vip ?? false) ×\(r?.multiplier ?? -1) payout \(r?.payout ?? -1) · chips \(before) → \(store.chips) \(machine.message ?? "")")
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
                print("t+\(i)s total \(c.total) viewing \(c.viewing) oddEven \(c.oddEven) others \(names) events \(c.events.map { "\($0.name) \($0.kind) \($0.amount)" }) dot \(store.tableBusy)")
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

    /// mode: betting | reveal | crowd | crowd-reveal
    private static func fakeTable(store: LoungeStore, me: Player, mode: String) -> OddEvenTable {
        let now = Date()
        let crowd = mode.hasPrefix("crowd")
        let revealing = mode.hasSuffix("reveal") || mode.hasSuffix("won")
        // (이름, 쪽, 금액). 첫 줄은 나.
        let plan: [(String, Side, Int64)] = crowd
            ? [("나", .odd, 100), ("민수", .odd, 500), ("예린", .even, 500), ("지호", .odd, 380),
               ("서연", .even, 200), ("철수", .odd, 50), ("영희", .even, 100), ("하준", .odd, 100),
               ("도윤", .odd, 10), ("수아", .even, 10), ("우진", .odd, 100), ("지은", .even, 50)]
            : [("철수", .odd, 50), ("영희", .even, 100)]
        let seats = [Seat(id: me.id, name: me.name)] + plan.dropFirst(crowd ? 1 : 0).map { Seat(id: UUID(), name: $0.0) }
        let ids = crowd ? seats.map(\.id) : seats.dropFirst().map(\.id)

        func bets(round: Int64, settled: Side?) -> [Bet] {
            zip(plan, ids).map { p, id in
                Bet(roundId: round, roomCode: "LOUNGE", playerId: id, side: p.1, amount: p.2,
                    payout: settled.map { $0 == p.1 ? p.2 * 2 : 0 })
            }
        }

        let t = OddEvenTable(store: store)
        // "won": 구슬 7개가 다 나오고 0.5초 뒤 (승리 연출 중)
        let closedAgo = mode.hasSuffix("won") ? 7 * 0.18 + 0.6 : 3
        let last = Round(id: 41, roomCode: "LOUNGE", opensAt: now.addingTimeInterval(-15 - closedAgo),
                         closesAt: now.addingTimeInterval(-closedAgo), marbles: 7, settledAt: now.addingTimeInterval(-closedAgo))
        if revealing {
            let next = Round(id: 42, roomCode: "LOUNGE", opensAt: now.addingTimeInterval(2),
                             closesAt: now.addingTimeInterval(17), marbles: nil, settledAt: nil)
            t.preview(round: next, bets: [], last: last, lastBets: bets(round: 41, settled: .odd), seats: seats)
        } else {
            let current = Round(id: 42, roomCode: "LOUNGE", opensAt: now.addingTimeInterval(-9),
                                closesAt: now.addingTimeInterval(crowd ? 6 : 11), marbles: nil, settledAt: nil)
            t.preview(round: current, bets: bets(round: 42, settled: nil), last: last, lastBets: [], seats: seats)
        }
        return t
    }

    /// mode: slot-idle | slot-spinning | slot-glitch | slot-win | slot-big | slot-jackpot | slot-lose
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
                                  picks: [p("나", 0), p("예린", 0), p("민수", 0), p("지호", 1)], winner: 1, net: -500)
        case "minority-result-void":
            return MinorityResult(question: "아침 첫 잔", options: ("아아", "뜨아"),
                                  picks: [p("나", 0), p("예린", 0), p("지호", 0)], winner: nil, net: 0)
        default:
            return MinorityResult(question: "금요일 오후 배포", options: ("한다", "안 한다"),
                                  picks: [p("나", 1), p("예린", 0), p("민수", 0), p("철수", 0), p("영희", 0)],
                                  winner: 1, net: 2_000)
        }
    }

    private static func fakeMinority(_ mode: String) -> MinorityScreen {
        let deploy = MinorityScreen.Round(question: "금요일 오후 배포", options: ("한다", "안 한다"),
                                          closesAt: kst(hour: 17), participants: 4)
        switch mode {
        case "minority-picked":
            var r = deploy
            r.myPick = 1
            return MinorityScreen(round: r)
        case "minority-closed":
            // 금요일 17시 정산 뒤: 다음 판은 월요일 8시
            return MinorityScreen(round: nil, nextOpensAt: kst(hour: 8, weekday: 2),
                                  mine: .init(question: "금요일 오후 배포", winner: "안 한다", net: 1_000))
        default:
            return MinorityScreen(round: deploy)
        }
    }

    private static func fakeBoard(_ mode: String) -> [BoardRow]? {
        switch mode {
        case "lobby-board-empty": return []
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
            m("철수", viewing: true, place: .oddeven, .coding), m("영희", viewing: true, place: .oddeven),
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
