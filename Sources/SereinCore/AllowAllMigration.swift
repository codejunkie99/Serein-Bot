import Foundation

/// The one-time move of every install to Allow all (owner 2026-11-25: "The default should be to
/// allow everything"), whatever level it held, a level the person chose included. `markerKey`
/// keeps the level it had before, for the receipt's Undo, and marks the move done: a later launch
/// changes nothing, so a person who goes back to a lower level stays there.
public enum AllowAllMigration {
  public static let markerKey = "serein.approvals.allowAllFrom"
  /// The receipt's Undo entry (`ReceiptCopy.allowAll`).
  public static let undoEntry = "setting:allow-all"

  /// Moves `gates` to Allow all unless it moved before. Returns the level it held when that was
  /// lower, so the shell shows the receipt; nil when nothing changed: it moved before, it was
  /// already Allow all (a fresh install), or the store keeps nothing (an unreadable gates file
  /// reads as Every step and takes no write, so it is tried again at the next launch).
  @discardableResult public static func run(_ gates: any SettingsStore) -> ApprovalLevel? {
    guard gates.object(forKey: markerKey) == nil, !gates.bool(forKey: ApprovalLevel.allowAllMigratedKey) else { return nil }
    let key = AssistantMigration.autopilotKey
    let before = ApprovalLevel.resolve(stored: gates.object(forKey: key))
    gates.set(before.rawValue, forKey: markerKey)
    guard gates.string(forKey: markerKey) == before.rawValue, before != .proactive else { return nil }
    gates.set(ApprovalLevel.proactive.storedValue, forKey: key)
    // The one-time Auto consent card is for a default never confirmed; Allow all has none.
    gates.removeObject(forKey: ApprovalLevel.defaultedKey)
    return ApprovalLevel.resolve(stored: gates.object(forKey: key)) == .proactive ? before : nil
  }

  /// The level the move replaced, which the receipt's Undo restores; nil before the move.
  public static func previous(_ gates: any SettingsStore) -> ApprovalLevel? {
    gates.string(forKey: markerKey).flatMap(ApprovalLevel.init(rawValue:))
  }
}
