import SwiftUI

/// 팝오버 루트: 라운지(로비) ↔ 게임
struct RootView: View {
    enum Screen {
        case lounge
        case roulette(RouletteTable)
        case slot(SlotMachine)
        case blackjack(BlackjackTable)
        case minority
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
                    onRoulette: { go(.roulette(RouletteTable(store: store))) },
                    onSlot: { go(.slot(SlotMachine(store: store))) },
                    blackjackSeated: store.blackjackSeated,
                    onBlackjack: { go(.blackjack(BlackjackTable(store: store))) },
                    onBoard: { Task { await store.loadBoard() } },
                    minority: store.minorityTile,
                    onMinority: { go(.minority) },
                    notify: store.notify,
                    onNotify: { Task { await store.toggleNotify() } },
                    onRefresh: { Task { await store.refresh() } },
                    onQuit: { NSApp.terminate(nil) }
                )
            case .roulette(let table):
                RouletteView(table: table, chips: store.chips, golden: store.golden()) {
                    table.leave()
                    go(.lounge)
                }
                .onAppear { table.enter() }
                .onDisappear { table.leave() } // 팝오버 닫으면 자리에서 일어남
            case .minority:
                if let result = store.minorityUnseen {
                    MinorityResultView(result: result, onDone: { store.ackMinorityResult() }, onBack: { go(.lounge) })
                } else {
                MinorityView(screen: store.minorityScreen, chips: store.chips, picking: store.minorityPicking,
                             message: store.minorityMessage,
                             onPick: { c in Task { await store.pickMinority(c) } },
                             onBack: { go(.lounge) })
                    .task { await store.tickMinority() }
                }
            case .blackjack(let table):
                BlackjackView(table: table, chips: store.chips, golden: store.golden()) {
                    table.leave()
                    go(.lounge)
                }
                .onAppear { table.enter() }
                .onDisappear { table.leave() }
            case .slot(let machine):
                SlotView(machine: machine, chips: store.chips, golden: store.golden(),
                         vip: (store.me?.goldenUntil ?? .distantPast) > .now) {
                    go(.lounge)
                }
            }
        }
        // 팝오버가 실제로 화면에 보이는지 → "보는 중"
        .background(WindowVisibility { visible in
            store.viewing = visible
            if visible, case .slot(let machine) = screen {
                GameAudio.shared.setReelsTurning(machine.turningReels(at: .now))
            }
            GameAudio.shared.setVisible(visible)
        })
        // 최소 버전에 못 미치면 테이블에서 일으켜 세운다 (ADR-0010)
        .onChange(of: store.appUpdate?.required == true, initial: true) { _, blocked in
            guard blocked else { return }
            if case .roulette(let table) = screen { table.leave() }
            if case .blackjack(let table) = screen { table.leave() }
            go(.lounge)
        }
        .task {
            if store.me == nil { await store.connect() }
        }
    }

    private func go(_ next: Screen) {
        switch next {
        case .slot: GameAudio.shared.enter(.floor)
        case .blackjack: GameAudio.shared.enter(.felt)
        case .roulette: GameAudio.shared.enter(.marbles)
        case .minority: GameAudio.shared.enter(.ballot)
        case .lounge: GameAudio.shared.enter(.lounge)
        }
        screen = next
        switch next {
        case .lounge:
            store.place = .lounge
            Task { await store.countBlackjack() }
        // 룰렛은 홀짝 자리를 이어받아 Presence 값도 같다 (Member.Place.roulette = "oddeven")
        case .roulette: store.place = .roulette
        case .slot: store.place = .slot
        // 옛 앱이 모르는 위치 값을 보내면 회원 목록이 깨진다 → 소수결은 라운지로
        case .minority: store.place = .lounge
        // 블랙잭도 같은 이유로 라운지. 인원은 Presence가 아니라 서버 좌석에서 센다 (ADR-0014)
        case .blackjack: store.place = .lounge
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
