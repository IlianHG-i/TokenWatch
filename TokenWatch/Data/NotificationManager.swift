import Foundation
import UserNotifications

/// Envoie des notifications macOS locales. Utilisé pour prévenir des seuils
/// d'usage de la session Claude (5 h) sans avoir à garder l'œil sur la barre
/// de menu.
enum NotificationManager {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
