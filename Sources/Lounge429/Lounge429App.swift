import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        Fonts.register()
        setvbuf(stdout, nil, _IOLBF, 0)
        // 개발용: `Lounge429 --snapshot out.png [--locked | --table betting|reveal|nickname|...]` → PNG로 렌더링하고 종료
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let table = args.firstIndex(of: "--table").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            MainActor.assumeIsolated {
                if table == "live" { Snapshot.renderLive(to: args[i + 1], seconds: 8) }
                if table == "slot-live" { Snapshot.renderSlotLive(to: args[i + 1], spins: 8) }
                Snapshot.render(to: args[i + 1], locked: args.contains("--locked"), table: table)
            }
            return
        }
        Lounge429App.main()
    }
}

struct Lounge429App: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var store = LoungeStore()

    var body: some Scene {
        MenuBarExtra {
            RootView(store: store)
        } label: {
            Image(nsImage: Sprites.menuBarIcon(gold: store.snapshot.activeLock() != nil))
            Text(store.chips.formatted(.number))
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run`으로 띄울 때도 Dock 아이콘 없이 메뉴바 전용으로
        NSApp.setActivationPolicy(.accessory)
    }
}
