import AppKit
import SereinCore
import UserNotifications

/// A value set from a notification callback and read after a wait.
private final class Locked<Value>: @unchecked Sendable {
  private var value: Value
  private let lock = NSLock()
  init(_ value: Value) { self.value = value }
  func set(_ new: Value) { lock.withLock { value = new } }
  func get() -> Value { lock.withLock { value } }
}

/// System notifications for finished runs while Serein is in the background.
/// Permission is asked in context (the card under the first task card in Serein's chat, or a
/// reminder's line), never at launch and never by a task's finish.
@MainActor final class TaskNotifications: NSObject, UNUserNotificationCenterDelegate {
  static let shared = TaskNotifications()
  /// Opens a thread by id when a notification is clicked.
  var open: ((String) -> Void)?
  /// UNUserNotificationCenter needs a bundled app; `swift run` builds have no bundle and would crash.
  var supported: Bool {
    Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
  }
  func install() {
    guard supported else { return }
    UNUserNotificationCenter.current().delegate = self
    refreshAuthorization()
    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in Task { @MainActor in TaskNotifications.shared.refreshAuthorization() } }
  }
  /// What macOS last said about Serein's notifications; nil until known (or without a bundle).
  private(set) var authorization: UNAuthorizationStatus?
  func refreshAuthorization() {
    guard supported else { return }
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let status = settings.authorizationStatus
      Task { @MainActor in TaskNotifications.shared.authorization = status }
    }
  }
  /// A notification could reach the person: this build can post, and macOS hasn't been told no.
  /// Unknown or not asked yet counts, since Serein's own post asks on its first use.
  var canReach: Bool { supported && authorization != .denied }
  /// Asks macOS once, from a button the user pressed.
  func requestAuthorization() {
    guard supported else { return }
    Task {
      _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
      refreshAuthorization()
    }
  }
  /// Notifications are allowed right now; waits up to `timeout` for macOS to say (used at quit,
  /// where nothing may ask for permission).
  func authorizedNow(timeout: TimeInterval) -> Bool {
    guard supported else { return false }
    let done = DispatchSemaphore(value: 0)
    let allowed = Locked(false)
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      allowed.set([.authorized, .provisional].contains(settings.authorizationStatus))
      done.signal()
    }
    _ = done.wait(timeout: .now() + timeout)
    return allowed.get()
  }
  /// Schedules `plan` as calendar notifications, each with its reminder's id; waits up to
  /// `timeout` for macOS to take them (the app is quitting).
  func schedule(_ plan: [ReminderHandoff.Request], timeout: TimeInterval) {
    guard supported, !plan.isEmpty else { return }
    let center = UNUserNotificationCenter.current()
    let group = DispatchGroup()
    for item in plan {
      let content = UNMutableNotificationContent()
      content.title = item.title
      content.body = item.body
      content.sound = .default
      let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: item.at)
      let request = UNNotificationRequest(
        identifier: item.id, content: content,
        trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
      group.enter()
      center.add(request) { _ in group.leave() }
    }
    _ = group.wait(timeout: .now() + timeout)
  }
  /// Takes back notifications handed off at the last quit that have not fired yet.
  func withdraw(_ ids: [String]) {
    guard supported, !ids.isEmpty else { return }
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
  }
  /// `always`: also while Serein is in front (Relay's reminders and notify). `asks`: Serein's own
  /// post (a reminder, notify, its reply, its approval waiting) may ask macOS on first use; a
  /// task's finish never does (`always` posts ask too).
  /// `result`: a finished task's notice, which also offers Show result (the reply where the
  /// person is) beside opening the chat. `kind`: during quiet hours only an ask and a reminder go
  /// out; anything else waits for one summary per chat at the brief hour (RelayOutbox).
  func post(
    threadID: String, title: String, body: String, always: Bool = false, asks: Bool = false, result: Bool = false,
    kind: RelayOutbox.Kind = .update
  ) {

    guard supported, always || !NSApp.isActive else { return }
    let now = Date()
    if RelayOutbox.holds(kind, hour: Calendar.current.component(.hour, from: now)) {
      hold(threadID: threadID, title: title, body: body, now: now)
      return
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.userInfo = ["thread": threadID]
    if result {
      Self.registerResultCategory()
      content.categoryIdentifier = Self.resultCategory
    }
    let request = UNNotificationRequest(
      identifier: RelayOutbox.identifier(kind, thread: threadID), content: content, trigger: nil)
    Task {
      let center = UNUserNotificationCenter.current()
      // A task's finish never asks macOS about notifications: the card under the first task card
      // asks in context. Serein's own posts (reminders, notify, its reply and its approvals) keep
      // asking on their first post.
      let allowed: Bool
      if always || asks {
        allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
      } else {
        let status = await center.notificationSettings().authorizationStatus
        allowed = status == .authorized || status == .provisional
      }
      // The system question may have just been answered while Serein stayed in front; the next
      // reminder's line reads this.
      refreshAuthorization()
      guard allowed else { return }
      try? await center.add(request)
    }
  }
  /// A quiet-hours post joins its chat's summary, scheduled for the brief hour. It never asks
  /// macOS for permission: nothing prompts at night.
  private func hold(threadID: String, title: String, body: String, now: Date) {
    let id = RelayOutbox.heldID(thread: threadID)
    let at = RelayOutbox.summaryTime(after: now)
    Task {
      let center = UNUserNotificationCenter.current()
      let status = await center.notificationSettings().authorizationStatus
      guard status == .authorized || status == .provisional else { return }
      let earlier = await center.pendingNotificationRequests().first { $0.identifier == id }?.content.body
      let content = UNMutableNotificationContent()
      content.title = RelayOutbox.summaryTitle
      content.body = RelayOutbox.merged(earlier, title: title, body: body)
      content.sound = .default
      content.userInfo = ["thread": threadID]
      let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
      let request = UNNotificationRequest(
        identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
      try? await center.add(request)
    }
  }
  static let resultCategory = "serein.finished"
  static let resultAction = "serein.finished.result"
  static let chatAction = "serein.finished.chat"
  private static var resultCategoryRegistered = false
  /// The finished notice's two buttons, made known to macOS once.
  private static func registerResultCategory() {
    guard !resultCategoryRegistered else { return }
    resultCategoryRegistered = true
    let category = UNNotificationCategory(
      identifier: resultCategory,
      actions: [
        UNNotificationAction(identifier: resultAction, title: "Show Result", options: []),
        UNNotificationAction(identifier: chatAction, title: "Open Chat", options: [.foreground]),
      ],
      intentIdentifiers: [], options: [])
    let center = UNUserNotificationCenter.current()
    center.getNotificationCategories { known in
      center.setNotificationCategories(known.filter { $0.identifier != resultCategory }.union([category]))
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let thread = response.notification.request.content.userInfo["thread"] as? String
    let action = response.actionIdentifier
    Task { @MainActor in
      // Show Result keeps the person where they are when the reply can be shown there.
      if action == TaskNotifications.resultAction, let thread, RelayController.shared?.showResult(thread: thread) == true {
        return
      }
      NSApp.activate(ignoringOtherApps: true)
      if let thread { TaskNotifications.shared.open?(thread) }
    }
    completionHandler()
  }
}
