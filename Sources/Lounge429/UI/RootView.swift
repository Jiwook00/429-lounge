import SwiftUI

/// 팝오버 루트: 라운지(로비) ↔ 게임 테이블
struct RootView: View {
    let store: LoungeStore
    @State private var table: OddEvenTable?

    var body: some View {
        Group {
            if let table {
                OddEvenView(table: table, chips: store.chips) {
                    table.leave()
                    self.table = nil
                }
                .onAppear { table.enter() }
                .onDisappear { table.leave() } // 팝오버 닫으면 자리에서 일어남
            } else {
                LoungeView(
                    snapshot: store.snapshot,
                    lastScan: store.lastScan,
                    chips: store.chips,
                    online: store.me != nil,
                    onOddEven: { table = OddEvenTable(store: store) },
                    onRefresh: { Task { await store.refresh() } },
                    onQuit: { NSApp.terminate(nil) }
                )
            }
        }
        .task {
            if store.me == nil { await store.connect() }
        }
    }
}
