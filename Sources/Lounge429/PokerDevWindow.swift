import AppKit
import LoungeNet
import SwiftUI

#if LOUNGE_DEV
/// 개발용 빌드에만 들어간다(`swift build` 디버그, `scripts/build-app.sh --dev`). `--dist` 배포 빌드엔 코드 자체가 없다.
/// `LOUNGE_POKER_WINDOW=1`로 띄운 앱에서 인디언 포커 화면을 일반 창에 연다.
/// 메뉴바 팝오버를 자동화로 누를 수 없을 때 실제 앱(같은 store, 같은 tick 루프, 같은 메뉴바 아이콘)으로 확인하기 위한 것.
/// 환경변수가 없으면 아무것도 하지 않는다 (Finder로 띄운 앱엔 환경변수가 없다).
/// `LOUNGE_E2E_BET=1`이면 자리를 잡고(앉은 테이블 → 자리 있는 테이블 → 새 테이블) 내 차례에 4초 기다렸다 체크·콜한다
/// (그 4초 동안 메뉴바 아이콘이 깜빡인다). 상태 줄을 표준 출력에 찍고, `LOUNGE_POKER_HANDS`(기본 2)판이 끝나면 일어난다.
@MainActor
enum PokerDevWindow {
    private static var window: NSWindow?

    static var enabled: Bool { ProcessInfo.processInfo.environment["LOUNGE_POKER_WINDOW"] == "1" }

    static func open(store: LoungeStore) {
        guard enabled, window == nil else { return }
        let table = store.poker
        let host = NSHostingView(rootView: PokerDevHost(store: store, table: table))
        let w = NSWindow(contentRect: NSRect(x: 200, y: 120, width: 340, height: 760),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "인디언 포커 (개발)"
        w.contentView = host
        w.makeKeyAndOrderFront(nil)
        window = w
        print("poker window \(w.windowNumber)")
        table.watching = true
        if ProcessInfo.processInfo.environment["LOUNGE_E2E_BET"] == "1" {
            Task { await autoplay(store: store, table: table) }
        }
    }

    private static func autoplay(store: LoungeStore, table: IndianPokerTable) async {
        while store.me == nil { try? await Task.sleep(for: .milliseconds(300)) }
        await table.refreshLobby()
        // LOUNGE_POKER_CANCEL_JOIN=초: 입장 요청을 보내고 그 초 뒤 ‹ 라운지와 같은 leave()를 부른다 (입장 응답 지연과 경합 재현)
        if let cancel = ProcessInfo.processInfo.environment["LOUNGE_POKER_CANCEL_JOIN"].flatMap(Double.init), !table.seated {
            let open = table.lobby?.tables.first(where: { !$0.full })
            let join = Task { if let open { await table.join(open.id) } else { await table.create() } }
            try? await Task.sleep(for: .seconds(cancel))
            print("cancel while joining · pending \(table.joinPending)")
            table.leave()
            await join.value
            let t0 = Date()
            while table.seated || table.joinPending, Date().timeIntervalSince(t0) < 30 { try? await Task.sleep(for: .milliseconds(100)) }
            print("after cancel · seated \(table.seated) · pending \(table.joinPending) · attempts \(table.leaveAttempts)")
            return
        }
        if !table.seated {
            if let open = table.lobby?.tables.first(where: { !$0.full }) { await table.join(open.id) } else { await table.create() }
        }
        print("seated at \(table.tableID.map(String.init) ?? "-") · \(table.message ?? "ok") · chips \(store.chips)")
        let hands = Int(ProcessInfo.processInfo.environment["LOUNGE_POKER_HANDS"] ?? "") ?? 2
        let start = store.chips
        var acted = "", last = "", finished: Set<Int64> = []
        while table.seated, finished.count < hands {
            try? await Task.sleep(for: .milliseconds(250))
            guard let s = table.state, let h = s.hand else { continue }
            if let o = table.options(at: .now), acted != "\(h.id):\(h.turnNo)", !table.busy {
                acted = "\(h.id):\(h.turnNo)"
                print("my turn · flash \(table.flash)")
                try? await Task.sleep(for: .seconds(4))
                await table.act(o.canCheck ? .check : .call)
                print("act → \(table.mySeat?.lastAction?.rawValue ?? "?") · \(table.message ?? "ok")")
            }
            let line = "#\(h.handNo) \(h.phase.rawValue) turn \(h.turnSeat.map(String.init) ?? "-") pot \(h.pot) | "
                + s.seats.map { "\($0.name) \($0.card.map(String.init) ?? "?")\($0.folded ? "✕" : "")\($0.net.map { " net \($0)" } ?? "")" }
                .joined(separator: ", ")
            if line != last { print(line); last = line }
            if h.phase == .done, s.mySeat != nil { finished.insert(h.id) }
        }
        try? await Task.sleep(for: .seconds(3))
        await store.refreshMe()
        print("hands \(finished.count) · chips \(start) → \(store.chips)")
        if ProcessInfo.processInfo.environment["LOUNGE_POKER_STAY"] == nil {
            // 서버가 이탈을 확인할 때까지 (실패하면 백오프로 다시 시도)
            let t0 = Date()
            let ok = await table.leaveAndWait(timeout: 120)
            print(ok ? "left table (시도 \(table.leaveAttempts)번, \(Int(Date().timeIntervalSince(t0)))초)" : "leave not confirmed")
        }
    }
}

private struct PokerDevHost: View {
    let store: LoungeStore
    let table: IndianPokerTable

    var body: some View {
        IndianPokerView(table: table, chips: store.chips) {
            table.leave()
        }
    }
}
#endif
