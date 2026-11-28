import AppKit
import Sparkle
import SwiftUI
import UserNotifications

@main
enum Entry {
    static func main() {
        Fonts.register()
        setvbuf(stdout, nil, _IOLBF, 0)
        // 개발용: `Lounge429 --snapshot out.png [--locked | --table roulette-betting|nickname|...]` → PNG로 렌더링하고 종료
        let args = CommandLine.arguments
        // 빌드용: `Lounge429 --app-icon out.png` → 1024px 앱 아이콘 PNG
        if let i = args.firstIndex(of: "--app-icon"), i + 1 < args.count {
            let ok = MainActor.assumeIsolated { AppIcon.write(to: args[i + 1]) }
            exit(ok ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let table = args.firstIndex(of: "--table").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            MainActor.assumeIsolated {
                if table == "roulette-live" { Snapshot.renderRouletteLive(to: args[i + 1], seconds: 25) }
                if table == "lobby-live" { Snapshot.renderLobbyLive(to: args[i + 1], seconds: 20) }
                if table == "bj-live" { Snapshot.renderBlackjackLive(to: args[i + 1], seconds: 25) }
                if table == "ip-live" { Snapshot.renderPokerLive(to: args[i + 1], seconds: 40) }
                if table == "wall-live" { Snapshot.renderWallLive(to: args[i + 1], seconds: 25) }
                if table == "plinko-live" { Snapshot.renderPlinkoLive(to: args[i + 1], seconds: 25) }
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
            RootView(store: store, onInstallUpdate: delegate.updater.map { updater in
                { updater.checkForUpdates(nil) }
            })
        } label: {
            // 다른 회원의 잭팟, 인디언 포커 내 차례(포커 화면을 안 보고 있을 때)면 VIP ↔ 평소로 깜빡인다
            Image(nsImage: Sprites.menuBarIcon(vip: store.vip != (store.jackpotFlash || store.poker.flash), busy: store.tableBusy))
            Text(store.chips.formatted(.number))
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// App Nap 막기. 팝오버를 닫아 두면 macOS가 앱을 재워 타이머가 밀리고,
    /// Realtime 하트비트가 늦어 서버가 연결을 끊는다 → 다른 회원 화면에서 사라진다.
    /// 맥 자체의 잠자기는 막지 않는다 (잠들면 라운지에서 빠지는 게 맞다)
    private var activity: NSObjectProtocol?
    private(set) lazy var updater: SPUStandardUpdaterController? = {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              !ProcessInfo.processInfo.arguments.contains("--preview-update") else { return nil }
        return SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run`으로 띄울 때도 Dock 아이콘 없이 메뉴바 전용으로
        NSApp.setActivationPolicy(.accessory)
        updater?.startUpdater()
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "라운지 접속 유지")
        if Notifier.available { UNUserNotificationCenter.current().delegate = self }
    }

    /// 종료 전에 인디언 포커 자리에서 일어난다. 서버가 이탈을 확인할 때까지 최대 5초 기다리고,
    /// 그래도 안 되면(오프라인) 그냥 종료한다 → 서버 규칙대로 차례 11초가 지나면 폴드, 연속 2판이면 자리에서 빠진다
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let poker = IndianPokerTable.current, poker.seated else { return .terminateNow }
        Task { @MainActor in
            _ = await poker.leaveAndWait(timeout: 5)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 팝오버를 열어 둔 상태(앱이 앞)에서도 배너를 띄운다
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
