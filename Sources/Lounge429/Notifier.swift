import Foundation
import LoungeNet
import UserNotifications

/// macOS 알림. 지금은 다른 회원의 잭팟만 (DESIGN.md §9 알림)
/// 켜는 사람에게만 보낸다. 코딩 중인 사람을 먼저 부르는 일이라 기본은 꺼짐, 소리 없음
@MainActor
enum Notifier {
    /// 번들 없이(`swift run`, 스냅샷) 돌면 UNUserNotificationCenter가 죽는다
    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    /// 권한을 묻는다. 이미 정했으면 묻지 않고 그 결과를 돌려준다
    static func requestPermission() async -> Bool {
        guard available else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }

    /// 내가 참가한 소수결 결과
    static func minority(_ text: String, question: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = "소수결 결과 · \(question)"
        content.body = text
        let request = UNNotificationRequest(identifier: "minority-\(question)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func jackpot(_ event: LoungeEvent) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = "잭팟! 429 · 429 · 429"
        content.body = "\(event.name) +\(event.amount.formatted(.number))칩"
        let request = UNNotificationRequest(identifier: "jackpot-\(event.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
