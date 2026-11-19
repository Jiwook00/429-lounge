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
        if let table {
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
        let revealing = mode.hasSuffix("reveal")
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
        let last = Round(id: 41, roomCode: "LOUNGE", opensAt: now.addingTimeInterval(-18),
                         closesAt: now.addingTimeInterval(-3), marbles: 7, settledAt: now.addingTimeInterval(-3))
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
}
