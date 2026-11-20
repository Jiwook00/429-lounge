import SwiftUI

/// 팝오버 루트: 라운지(로비) ↔ 게임
struct RootView: View {
    enum Screen {
        case lounge
        case oddEven(OddEvenTable)
        case slot(SlotMachine)
    }

    let store: LoungeStore
    @State private var screen: Screen = .lounge

    var body: some View {
        Group {
            switch screen {
            case .lounge:
                LoungeView(
                    snapshot: store.snapshot,
                    lastScan: store.lastScan,
                    chips: store.chips,
                    golden: store.golden(),
                    toast: store.toast,
                    online: store.me != nil,
                    crowd: store.crowd(),
                    board: store.board,
                    visible: store.viewing,
                    name: store.me.flatMap { $0.named ? $0.name : nil },
                    onRename: { await store.rename($0) },
                    appUpdate: store.appUpdate,
                    onOddEven: { go(.oddEven(OddEvenTable(store: store))) },
                    onSlot: { go(.slot(SlotMachine(store: store))) },
                    onBoard: { Task { await store.loadBoard() } },
                    onRefresh: { Task { await store.refresh() } },
                    onQuit: { NSApp.terminate(nil) }
                )
            case .oddEven(let table):
                OddEvenView(table: table, chips: store.chips, golden: store.golden()) {
                    table.leave()
                    go(.lounge)
                }
                .onAppear { table.enter() }
                .onDisappear { table.leave() } // 팝오버 닫으면 자리에서 일어남
            case .slot(let machine):
                SlotView(machine: machine, chips: store.chips, golden: store.golden(),
                         vip: (store.me?.goldenUntil ?? .distantPast) > .now) {
                    go(.lounge)
                }
            }
        }
        // 팝오버가 실제로 화면에 보이는지 → "보는 중"
        .background(WindowVisibility { store.viewing = $0 })
        // 최소 버전에 못 미치면 테이블에서 일으켜 세운다 (ADR-0010)
        .onChange(of: store.appUpdate?.required == true, initial: true) { _, blocked in
            guard blocked else { return }
            if case .oddEven(let table) = screen { table.leave() }
            go(.lounge)
        }
        .task {
            if store.me == nil { await store.connect() }
        }
    }

    private func go(_ next: Screen) {
        screen = next
        switch next {
        case .lounge: store.place = .lounge
        case .oddEven: store.place = .oddeven
        case .slot: store.place = .slot
        }
    }
}

/// 이 뷰가 들어 있는 창(메뉴바 팝오버)이 화면에 보이는지 알려준다.
/// SwiftUI onAppear/onDisappear는 팝오버를 닫아도 안 불릴 때가 있어서 창 상태를 직접 본다.
private struct WindowVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onChange = onChange
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.onChange = onChange
    }

    final class Probe: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var observers: [NSObjectProtocol] = []
        private var last: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { report(false); return }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.willCloseNotification,
            ]
            for name in names {
                let closing = name == NSWindow.willCloseNotification
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.report(closing ? false : self.isShown)
                    }
                })
            }
            report(isShown)
        }

        private var isShown: Bool {
            guard let window else { return false }
            return window.isVisible && window.occlusionState.contains(.visible)
        }

        private func report(_ shown: Bool) {
            guard shown != last else { return }
            last = shown
            onChange(shown)
        }
    }
}
