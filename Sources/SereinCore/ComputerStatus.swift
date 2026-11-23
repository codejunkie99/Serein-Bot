import Foundation

/// Where one task stands while it waits for an assistant's computer (ComputerHost.wait): its place
/// in line and what holds the computer now. The task view, the sidebar's "Serein's computer" row
/// and the inspector's Computer tab show these lines, and VoiceOver reads the same words.
public struct ComputerWait: Equatable, Sendable {
  /// What keeps the computer from the task, in the order the person can act on it.
  public enum Holder: Equatable, Sendable {
    /// The person took over: Hand back lets the line move.
    case person
    /// A Throwaway reset between two tasks is running or owed.
    case clearing
    /// Another task holds it, by its title.
    case task(String)
    /// Nobody: the lease passes to the first in line at once.
    case free
  }
  /// 1 for the first in line.
  public var place: Int
  public var holder: Holder
  public init(place: Int, holder: Holder) {
    self.place = place
    self.holder = holder
  }

  /// The waiting task's own line: "Waiting for Scout's computer · 2nd in line · “Plan a trip” is using it".
  public func line(assistant: String) -> String {
    (["Waiting for \(assistant)'s computer"] + tail).joined(separator: " · ")
  }
  /// The same for the computer's own views, naming the task that waits: "“Book a table” is waiting · 1st in line · you have control".
  public func line(task: String) -> String {
    (["“\(task)” is waiting"] + tail).joined(separator: " · ")
  }
  private var tail: [String] {
    let standing = Self.ordinal(place) + " in line"
    switch holder {
    case .person: return [standing, "you have control"]
    case .clearing: return [standing, "being cleared"]
    case .task(let title): return [standing, "“\(title)” is using it"]
    case .free: return [standing]
    }
  }
  /// English ordinals: 1st, 2nd, 3rd, 4th, 11th, 12th, 13th, 21st, 112th.
  public static func ordinal(_ n: Int) -> String {
    let suffix: String
    switch (n % 100, n % 10) {
    case (11...13, _): suffix = "th"
    case (_, 1): suffix = "st"
    case (_, 2): suffix = "nd"
    case (_, 3): suffix = "rd"
    default: suffix = "th"
    }
    return "\(n)\(suffix)"
  }
}

/// Step pictures (StepPictures): after each computer step that succeeded, a small picture of the
/// computer's screen, kept for the person's step timeline only and never in a prompt or a tool's
/// answer. They follow task recordings' time in Settings › Privacy.
public enum StepPicturePolicy {
  /// Pictures are this many pixels wide (JPEG), whatever the screen.
  public static let width = 480
  public static let quality = 0.7
  /// Whether a step's picture is taken: never of the person's own machine used as it is (its
  /// screen can show private windows) unless they keep step pictures for that machine.
  public static func takes(personalScreen: Bool, keepForMachine: Bool) -> Bool {
    !personalScreen || keepForMachine
  }
  /// Task recordings' rule (TaskRecordings.sweepDue) for one task's pictures, `newest` being its
  /// latest picture: with a number of days they go once that is past; under "Until quit" (0) at
  /// launch and quit only. A task still running keeps them until then.
  public static func kept(newest: Date, now: Date, days: Int, launchOrQuit: Bool, running: Bool) -> Bool {
    if running && !launchOrQuit { return true }
    return days > 0 ? now.timeIntervalSince(newest) < Double(days) * 86_400 : !launchOrQuit
  }
  /// A task or step id as a file name: Serein's own ids are UUIDs, and nothing else names a file.
  public static func safeName(_ id: String) -> Bool { UUID(uuidString: id) != nil }
}

extension ComputerPlace {
  /// The person's own machine used as it is: its screen is theirs. Serein's own desktop on their
  /// machine (`ownDesktop`) is a computer of Serein's like any other.
  public var showsPersonalScreen: Bool { self == .ownMachine }
}
