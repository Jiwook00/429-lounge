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
                    onOddEven: { screen = .oddEven(OddEvenTable(store: store)) },
                    onSlot: { screen = .slot(SlotMachine(store: store)) },
                    onRefresh: { Task { await store.refresh() } },
                    onQuit: { NSApp.terminate(nil) }
                )
            case .oddEven(let table):
                OddEvenView(table: table, chips: store.chips, golden: store.golden()) {
                    table.leave()
                    screen = .lounge
                }
                .onAppear { table.enter() }
                .onDisappear { table.leave() } // 팝오버 닫으면 자리에서 일어남
            case .slot(let machine):
                SlotView(machine: machine, chips: store.chips, golden: store.golden()) {
                    screen = .lounge
                }
            }
        }
        .task {
            if store.me == nil { await store.connect() }
        }
    }
}
