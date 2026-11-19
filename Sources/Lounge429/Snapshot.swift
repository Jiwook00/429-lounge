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
        let me = Player(id: UUID(), name: "danny", chips: 1_250)
        let store = LoungeStore(live: false)
        store.preview(me: me, snapshot: usage)

        let content: AnyView
        if let table {
            content = AnyView(OddEvenView(table: fakeTable(store: store, me: me, mode: table), chips: store.chips))
        } else {
            content = AnyView(VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(nsImage: Sprites.menuBarIcon(gold: false))
                    Image(nsImage: Sprites.menuBarIcon(gold: true))
                    Text("메뉴바 아이콘").font(Fonts.small()).foregroundStyle(.white)
                }
                .padding(6)
                .background(Color(white: 0.75))
                LoungeView(snapshot: usage, lastScan: .now, chips: store.chips, online: true)
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
            print("signed in as \(me.name) · chips \(me.chips)")
            let table = OddEvenTable(store: store)
            table.enter()
            try? await Task.sleep(for: .seconds(seconds))
            print("round \(table.round?.id ?? -1) · bets \(table.bets.count) · seats \(table.seats.map(\.name)) · last \(table.last?.marbles ?? -1)")
            write(AnyView(OddEvenView(table: table, chips: store.chips)), to: path)
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

    private static func fakeTable(store: LoungeStore, me: Player, mode: String) -> OddEvenTable {
        let now = Date()
        let friends = [Seat(id: UUID(), name: "철수"), Seat(id: UUID(), name: "영희")]
        let seats = [Seat(id: me.id, name: me.name)] + friends
        let t = OddEvenTable(store: store)

        let last = Round(id: 41, roomCode: "LOUNGE", opensAt: now.addingTimeInterval(-18),
                         closesAt: now.addingTimeInterval(-3), marbles: 7, settledAt: now.addingTimeInterval(-3))
        let lastBets = [
            Bet(roundId: 41, roomCode: "LOUNGE", playerId: me.id, side: .odd, amount: 100, payout: 200),
            Bet(roundId: 41, roomCode: "LOUNGE", playerId: friends[0].id, side: .even, amount: 50, payout: 0),
            Bet(roundId: 41, roomCode: "LOUNGE", playerId: friends[1].id, side: .odd, amount: 10, payout: 20),
        ]
        if mode == "reveal" {
            let next = Round(id: 42, roomCode: "LOUNGE", opensAt: now.addingTimeInterval(2),
                             closesAt: now.addingTimeInterval(17), marbles: nil, settledAt: nil)
            t.preview(round: next, bets: [], last: last, lastBets: lastBets, seats: seats)
        } else {
            let current = Round(id: 42, roomCode: "LOUNGE", opensAt: now.addingTimeInterval(-4),
                                closesAt: now.addingTimeInterval(11), marbles: nil, settledAt: nil)
            let bets = [
                Bet(roundId: 42, roomCode: "LOUNGE", playerId: friends[0].id, side: .odd, amount: 50, payout: nil),
                Bet(roundId: 42, roomCode: "LOUNGE", playerId: friends[1].id, side: .even, amount: 100, payout: nil),
            ]
            t.preview(round: current, bets: bets, last: last, lastBets: lastBets, seats: seats)
        }
        return t
    }
}
