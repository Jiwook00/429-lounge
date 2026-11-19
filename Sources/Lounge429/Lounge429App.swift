import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        Fonts.register()
        // 개발용: `Lounge429 --snapshot out.png [--locked]` → 팝오버를 PNG로 렌더링하고 종료
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated {
                Snapshot.render(to: CommandLine.arguments[i + 1],
                                locked: CommandLine.arguments.contains("--locked"))
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
            LoungeView(
                snapshot: store.snapshot,
                lastScan: store.lastScan,
                onRefresh: { Task { await store.refresh() } },
                onQuit: { NSApp.terminate(nil) }
            )
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
