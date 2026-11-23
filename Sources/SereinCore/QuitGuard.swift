import Foundation

/// What ⌘Q says while Serein still has something to do: work that quitting would stop, or a
/// request that cannot run while Serein is closed. Nil when quitting loses nothing.
public enum QuitGuard {
  public struct Reason: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
      /// Tasks or Serein's own reply would stop.
      case work
      /// Only a request coming up would be missed.
      case request
    }
    public let kind: Kind
    public let title: String
    public let detail: String
    /// The first button keeps Serein running; the second quits.
    public let keep: String
    public let quit: String
    /// A third button that only goes back (the request questions); nil for work.
    public let cancel: String?
  }
  /// A scheduled request Serein would run on its own.
  public struct Request: Equatable, Sendable {
    public let text: String
    public let due: Date
    /// The daily brief Settings turns on: the user never wrote its words (they are the model's
    /// instructions), so the questions name it instead of quoting it.
    public let brief: Bool
    public init(text: String, due: Date, brief: Bool = false) {
      self.text = text
      self.due = due
      self.brief = brief
    }
  }
  /// How far ahead a request still counts.
  public static let window: TimeInterval = 24 * 3600

  /// The request questions keep Serein running the one way that outlasts the window: the menu bar
  /// switch. ⌘Q and closing the window offer the same three buttons.
  public static let keepInMenuBar = "Keep Serein in the menu bar"

  /// ⌘Q. `live`: every task still working other than Serein's own run (AgentHub.slotted: the
  /// ones Serein started and the ones you started yourself, since quitting stops both);
  /// `replying`: Serein's own reply, counted once. `when` turns the request's time into words
  /// (“at 9:00”, “tomorrow at 9:00”).
  public static func reason(
    live: Int, replying: Bool, nextRequest: Request?, when: (Date) -> String = { QuitGuard.when($0) }
  ) -> Reason? {
    let things = live + (replying ? 1 : 0)
    if things > 0 {
      return Reason(
        kind: .work,
        title: "Serein is working on \(things == 1 ? "1 thing" : "\(things) things"). Quit anyway?",
        detail: things == 1 ? "Quitting stops it." : "Quitting stops them.",
        keep: "Keep working", quit: "Quit anyway", cancel: nil)
    }
    guard let nextRequest else { return nil }
    return requestReason(nextRequest, lead: "", verb: "Quit", when: when)
  }

  /// Closing the last window, which quits Serein once nothing keeps it running. Only a request
  /// coming up asks; `working`: work still runs, so Serein quits when it ends rather than now.
  /// Its own words: the button closes the window, which may not quit Serein yet.
  public static func closeReason(
    working: Bool, nextRequest: Request?, when: (Date) -> String = { QuitGuard.when($0) }
  ) -> Reason? {
    guard let nextRequest else { return nil }
    let lead = working
      ? "Closing this window quits Serein when its work is done. "
      : "Closing this window quits Serein. "
    return requestReason(nextRequest, lead: lead, verb: "Close", when: when)
  }

  /// `verb`: what the second button does, “Quit” (⌘Q) or “Close” (the window's close button).
  private static func requestReason(_ request: Request, lead: String, verb: String, when: (Date) -> String) -> Reason {
    if request.brief {
      return Reason(
        kind: .request,
        title: "Serein has your morning brief \(when(request.due)). \(verb) anyway?",
        detail: lead + "Serein cannot give your morning brief while it is closed. It tells you it missed it.",
        keep: keepInMenuBar, quit: "\(verb) anyway", cancel: "Cancel")
    }
    let text = request.text.count > 60 ? String(request.text.prefix(59)) + "…" : request.text
    return Reason(
      kind: .request,
      title: "Serein has a request \(when(request.due)). \(verb) anyway?",
      detail: lead + "Serein cannot do “\(text)” while it is closed. It tells you it missed it.",
      keep: keepInMenuBar, quit: "\(verb) anyway", cancel: "Cancel")
  }

  /// The soonest request (an action reminder that is not paused) due within the next 24 hours.
  /// `paused`: Stop Everything holds every request until the user resumes, so none counts.
  public static func nextRequest(_ reminders: [RelayReminder], now: Date, paused: Bool = false) -> Request? {
    guard !paused else { return nil }
    return reminders
      .filter { $0.action && $0.paused != true && $0.due > now && $0.due <= now.addingTimeInterval(window) }
      .min { $0.due < $1.due }
      .map { Request(text: $0.text, due: $0.due, brief: $0.id == RelayBriefing.reminderID) }
  }

  /// “at 9:00 AM”, “tomorrow at 9:00 AM”, or “on Oct 28 at 9:00 AM”, in the user's locale.
  public static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDate(date, inSameDayAs: now) { return "at " + time }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
      return "tomorrow at " + time
    }
    return "on " + date.formatted(.dateTime.month(.abbreviated).day()) + " at " + time
  }
}
