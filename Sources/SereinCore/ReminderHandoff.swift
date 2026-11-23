import Foundation

/// Plain reminders outlive a quit: at quit Serein hands each one still to come to macOS as a
/// scheduled notification (id = the reminder id), and at the next launch it takes back the ones
/// that have not fired, so nothing fires twice. Requests (reminders that make Serein do
/// something) stay with Serein, because macOS cannot run them.
public enum ReminderHandoff {
  public struct Request: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let at: Date
  }
  /// macOS keeps 64 pending notifications per app; the soonest go first.
  public static let limit = 60

  /// The notifications to schedule at `now`: plain, unpaused reminders still to come. A
  /// repeating one that is already due gets its next time; macOS shows each once.
  /// `paused`: Serein's own pause (Stop Everything) holds every reminder, so nothing is handed off.
  public static func plan(
    reminders: [RelayReminder], now: Date, paused: Bool = false, calendar: Calendar = .current
  ) -> [Request] {
    guard !paused else { return [] }
    let planned = reminders.compactMap { reminder -> Request? in
      guard !reminder.action, reminder.paused != true else { return nil }
      let at = reminder.due > now ? reminder.due : reminder.next(after: now, calendar: calendar)
      guard let at, at > now else { return nil }
      return Request(id: reminder.id, title: "Reminder", body: String(reminder.text.prefix(200)), at: at)
    }
    return Array(planned.sorted { $0.at < $1.at }.prefix(limit))
  }

  /// Of what was handed off, the reminders macOS has already shown by `now`, each with the time
  /// it showed. Serein marks that occurrence done without a second notification; any other
  /// occurrence of the same reminder (one already due at quit, say) still notifies.
  public static func delivered(_ handedOff: [Request], now: Date) -> [String: Date] {
    Dictionary(handedOff.filter { $0.at <= now }.map { ($0.id, $0.at) }) { first, _ in first }
  }

  /// Whether the reminder occurrence due at `due` is one macOS already showed.
  public static func alreadyShown(_ shown: [String: Date], id: String, due: Date) -> Bool {
    guard let at = shown[id] else { return false }
    return abs(at.timeIntervalSince(due)) < 1
  }
}
