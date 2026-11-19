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
        if let table, table.hasPrefix("slot") {
            content = AnyView(SlotView(machine: fakeSlot(store: store, me: me, mode: table), chips: store.chips,
                                       golden: store.golden(), vip: locked))
        } else if let table {
            content = AnyView(OddEvenView(table: fakeTable(store: store, me: me, mode: table), chips: store.chips, golden: store.golden()))
        } else {
            content = AnyView(VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(nsImage: Sprites.menuBarIcon(gold: false))
                    Image(nsImage: Sprites.menuBarIcon(gold: true))
                    Text("메뉴바 아이콘").font(Fonts.small()).foregroundStyle(.white)
                }
                .padding(6)
                .background(Color(white: 0.75))
                LoungeView(snapshot: usage, lastScan: .now, chips: store.chips, golden: store.golden(),
                           toast: store.toast, online: true)
            })
        }

        let renderer = ImageRenderer(content: content.padding(8).background(Color(white: 0.3)))
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

    private static func write(_ content: AnyView, to path: String) {
        let renderer = ImageRenderer(content: content.padding(8).background(Color(white: 0.3)))
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

    /// mode: slot-idle | slot-spinning | slot-glitch | slot-win | slot-wild | slot-found | slot-big | slot-jackpot | slot-lose
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
        case "slot-wild": m.preview(result: result(["bar", "200", "bar"], 20), finishedAgo: 0.35)
        case "slot-found": m.preview(result: result(["404", "404", "404"], 4), finishedAgo: 0.35)
        case "slot-big": m.preview(result: result(["seven", "seven", "seven"], 50), finishedAgo: 0.9)
        case "slot-jackpot": m.preview(result: result(["429", "429", "429"], 429), finishedAgo: 1.2)
        case "slot-lose": m.preview(result: result(["seven", "404", "bell"], 0), finishedAgo: 1)
        default: break
        }
        return m
    }
}
