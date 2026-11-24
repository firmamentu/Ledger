import Foundation
import UserNotifications

/// M7 通知（§14）：授权缺失 → 仅红点；卸载时提示「还有 N 处」。
enum NotificationService {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notifyUninstalled(appName: String, residualCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Ledger：检测到「\(appName)」已卸载"
        content.body = "还有 \(residualCount) 处残留，打开 Ledger 核对。"
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
