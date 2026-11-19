import Foundation
import LoungeCore

let started = Date()
let snapshot = UsageScanner().scan()
let elapsed = Date().timeIntervalSince(started)

func n(_ v: Int) -> String { v.formatted(.number) }
func line(_ label: String, _ t: TokenTotals) -> String {
    "\(label)  fresh \(n(t.fresh))  (in \(n(t.input)) · out \(n(t.output)) · cache-write \(n(t.cacheCreation)))"
        + "  cache-read \(n(t.cacheRead))  · \(t.messages) msgs"
}
let time = Date.FormatStyle(date: .abbreviated, time: .shortened)

print("429 Lounge · usage scan (\(String(format: "%.2f", elapsed))s)")
print(line("오늘   ", snapshot.today))
print(line("최근 5h", snapshot.last5h))
print("마지막 활동  \(snapshot.lastActivity.map { $0.formatted(time) } ?? "-")")

if let lock = snapshot.activeLock() {
    let left = Duration.seconds(lock.resetsAt.timeIntervalSinceNow)
        .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    print("리밋        🔒 \(lock.type) · \(lock.resetsAt.formatted(time)) 리셋 (\(left) 남음) → 황금 칩 타임")
} else if let hit = snapshot.lastLimitHit {
    print("리밋        없음 (마지막 429: \(hit.hitAt.formatted(time)), \(hit.type))")
} else {
    print("리밋        없음 (최근 7일 429 기록 없음)")
}
