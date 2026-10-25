import Cocoa
import FlutterMacOS
import Network
import UserNotifications

/// Local-only, one-shot system boundary. Successful add is acceptance, not proof
/// that the OS displayed an alert. No remote/push registration is performed.
final class NativeNotifications: NSObject, UNUserNotificationCenterDelegate {
  private let center = UNUserNotificationCenter.current()
  private var channel: FlutterMethodChannel?
  private let interactionKey = "noteAgent.notificationInteractions.v1"
  private let acceptedKey = "noteAgent.notificationAcceptedIDs.v1"
  private let reminderCategory = "noteAgent.actionReminder"
  // Same `networkAvailable` signal as the Android and Windows adapters: the
  // App re-checks reminders and sends to-do operations queued while offline.
  private let pathMonitor = NWPathMonitor()
  private var networkWasUnavailable = false

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    center.delegate = self
    // Background actions are recorded durably and applied by the workspace,
    // which decides whether a completion or snooze still matches the lifecycle.
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: reminderCategory,
        actions: [
          UNNotificationAction(identifier: "complete", title: "完成", options: []),
          UNNotificationAction(identifier: "snooze", title: "稍后提醒", options: []),
        ],
        intentIdentifiers: [],
        options: [])
    ])
    let channel = FlutterMethodChannel(name: "dev.noteagent/notifications", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    self.channel = channel
    pathMonitor.pathUpdateHandler = { [weak self] path in
      DispatchQueue.main.async { self?.networkPathChanged(path.status == .satisfied) }
    }
    pathMonitor.start(queue: DispatchQueue(label: "dev.noteagent.network"))
  }

  /// Reports only a return after an outage; the initial satisfied path is
  /// already covered by the App's startup checks.
  private func networkPathChanged(_ available: Bool) {
    if !available {
      networkWasUnavailable = true
      return
    }
    guard networkWasUnavailable else { return }
    networkWasUnavailable = false
    channel?.invokeMethod("networkAvailable", arguments: nil)
  }

  private func permission(_ settings: UNNotificationSettings) -> String {
    switch settings.authorizationStatus {
    case .authorized, .provisional: return "allowed"
    case .notDetermined: return "notDetermined"
    case .denied: return "denied"
    @unknown default: return "unknown"
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "inspect":
      center.getNotificationSettings { settings in
        self.center.getPendingNotificationRequests { pending in
          self.center.getDeliveredNotifications { delivered in
            DispatchQueue.main.async {
              result(["permission": self.permission(settings),
                      "pending": pending.map(\.identifier),
                      "delivered": delivered.map { $0.request.identifier },
                      "accepted": UserDefaults.standard.stringArray(forKey: self.acceptedKey) ?? []])
            }
          }
        }
      }
    case "takeInteractions":
      guard let values = call.arguments as? [String: String], let kind = values["kind"] else {
        result(FlutterError(code: "notification_arguments", message: "通知类型无效。", details: nil)); return
      }
      let responses = UserDefaults.standard.array(forKey: interactionKey) as? [[String: Any]] ?? []
      func matches(_ response: [String: Any]) -> Bool {
        guard let payload = response["payload"] as? [String: String] else { return false }
        return payload["kind"] == kind && (values["vault"] == nil || payload["vault"] == values["vault"])
      }
      UserDefaults.standard.set(responses.filter { !matches($0) }, forKey: interactionKey)
      result(responses.filter { matches($0) })
    case "requestPermission":
      // This method is invoked only by the explicit App button.
      center.requestAuthorization(options: [.alert, .sound]) { _, error in
        if let error = error {
          DispatchQueue.main.async { result(FlutterError(code: "notification_permission", message: error.localizedDescription, details: nil)) }
          return
        }
        self.center.getNotificationSettings { settings in
          DispatchQueue.main.async { result(self.permission(settings)) }
        }
      }
    case "schedule":
      guard let values = call.arguments as? [String: Any],
            let id = values["id"] as? String, id.hasPrefix("note-agent:"),
            let title = values["title"] as? String,
            let body = values["body"] as? String,
            let millis = values["timeMs"] as? NSNumber,
            let immediate = values["immediate"] as? Bool,
            let payload = values["payload"] as? [String: String] else {
        result(FlutterError(code: "notification_arguments", message: "提醒计划无效。", details: nil)); return
      }
      center.getNotificationSettings { settings in
        guard self.permission(settings) == "allowed" else {
          DispatchQueue.main.async { result(FlutterError(code: "notification_denied", message: "系统通知未允许，计划仍保留在 App。", details: nil)) }; return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = payload
        if payload["kind"] == "actionReminder" { content.categoryIdentifier = self.reminderCategory }
        let date = Date(timeIntervalSince1970: millis.doubleValue / 1000)
        let trigger: UNNotificationTrigger
        if immediate || date <= Date() {
          trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        } else {
          var calendar = Calendar(identifier: .gregorian)
          calendar.timeZone = TimeZone(secondsFromGMT: 0)!
          var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
          components.timeZone = calendar.timeZone
          trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        }
        self.center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger)) { error in
          DispatchQueue.main.async {
            if let error = error {
              result(FlutterError(code: "notification_schedule", message: error.localizedDescription, details: nil)); return
            }
            var ids = Set(UserDefaults.standard.stringArray(forKey: self.acceptedKey) ?? [])
            ids.insert(id)
            UserDefaults.standard.set(Array(ids), forKey: self.acceptedKey)
            result(nil)
          }
        }
      }
    case "cancel":
      guard let values = call.arguments as? [String: String], let id = values["id"], id.hasPrefix("note-agent:") else {
        result(FlutterError(code: "notification_arguments", message: "提醒标识无效。", details: nil)); return
      }
      center.removePendingNotificationRequests(withIdentifiers: [id])
      center.removeDeliveredNotifications(withIdentifiers: [id])
      let ids = (UserDefaults.standard.stringArray(forKey: acceptedKey) ?? []).filter { $0 != id }
      UserDefaults.standard.set(ids, forKey: acceptedKey)
      result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                              withCompletionHandler completionHandler: @escaping () -> Void) {
    let request = response.notification.request
    guard request.identifier.hasPrefix("note-agent:"),
          let payload = request.content.userInfo as? [String: String], payload["kind"] != nil else {
      completionHandler(); return
    }
    DispatchQueue.main.async {
      var responses = UserDefaults.standard.array(forKey: self.interactionKey) as? [[String: Any]] ?? []
      let action = response.actionIdentifier == UNNotificationDefaultActionIdentifier ? "default" : response.actionIdentifier
      responses.append(["id": request.identifier, "payload": payload, "actionIdentifier": action])
      UserDefaults.standard.set(responses, forKey: self.interactionKey)
      self.channel?.invokeMethod("interactionAvailable", arguments: nil)
      completionHandler()
    }
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                              withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .list, .sound])
  }
}
