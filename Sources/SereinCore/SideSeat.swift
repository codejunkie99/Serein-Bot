import Foundation

/// No queue (TEAMS-V2 §4, owner 2026-11-25): the person's message to a chat whose turn is busy
/// takes a side seat at once, a hidden seat thread of the chat's own assistant, and its answer
/// posts back into that chat. A turn of the person's that runs past `foregroundLimit` moves to a
/// side seat too, so the chat is free again. The shell (RelaySideSeats.swift) and the `seats`
/// formal machine both decide with these.
public enum SideSeat {
  /// Side seats share "At most three delegated runs work at once" (`agent_start`, Relay.swift).
  public static let cap = 3
  /// How long the person's own turn holds its chat before it moves to the background.
  public static let foregroundLimit: TimeInterval = 150

  /// Whether one more side seat may start: those running or starting, plus the delegated runs
  /// working now, stay under `cap`.
  public static func free(seated: Int, delegated: Int) -> Bool { seated + delegated < cap }

  /// Whether the turn that started at `startedAt` moves to the background now: past the limit,
  /// and not moved already (`moved`: a background seat answers its message).
  public static func moves(startedAt: Date, now: Date, moved: Bool) -> Bool {
    !moved && now.timeIntervalSince(startedAt) >= foregroundLimit
  }

  /// The line under a message when every side seat is taken. It runs when one frees.
  public static let fullLine = "A side seat isn't free, so this runs when one frees."
  /// The line under a message whose turn moved to the background.
  public static let backgroundLine = "Still working on this in the background. The answer will show here."
}
