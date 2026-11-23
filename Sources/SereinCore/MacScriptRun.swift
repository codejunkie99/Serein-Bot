import CryptoKit
import Foundation

/// The bytes `/usr/bin/osascript` actually receives. The digest is of this list, after the
/// source has been split into `-e` lines, not of the script text before that rewrite.
public enum ScriptPayload {
  public static func arguments(_ source: String) -> [String] {
    source.components(separatedBy: "\n").flatMap { ["-e", $0] }
  }

  public static func digest(_ source: String) -> String {
    digest(of: arguments(source))
  }

  /// SHA-256 of the argument list. Each argument's UTF-8 bytes are preceded by its length,
  /// so two different lists cannot hash the same.
  public static func digest(of arguments: [String]) -> String {
    var hasher = SHA256()
    for argument in arguments {
      let bytes = Data(argument.utf8)
      var count = UInt64(bytes.count).bigEndian
      withUnsafeBytes(of: &count) { hasher.update(bufferPointer: $0) }
      hasher.update(data: bytes)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

/// The text the person is shown, and the bytes the hash is taken from after they answer.
/// The alert fallback is not editable. A task field is, so a write during the ask is visible
/// to the hash. `MacTasks` uses these two slots. A caller does not pass its own read closure.
@MainActor
public final class ScriptSlot {
  public private(set) var string: String = ""
  /// False on the alert fallback. `MacTasks` copies this onto the text view.
  public let isEditable: Bool
  public init(isEditable: Bool) { self.isEditable = isEditable }
  /// The script shown in the alert. The view stays read-only.
  public static func alertFallback() -> ScriptSlot { ScriptSlot(isEditable: false) }
  /// The task's `scriptToRun` field. A change during the ask is a different script.
  public static func taskField() -> ScriptSlot { ScriptSlot(isEditable: true) }
  public func present(_ source: String) { string = source }
  /// A read-only slot refuses, and the approved bytes stay.
  @discardableResult
  public func rewrite(_ next: String) -> Bool {
    guard isEditable else { return false }
    string = next
    return true
  }
  /// The string the alert or the task field holds after the ask. The hash is of this.
  public func observe(_ shown: String) { string = shown }
}

/// The Mac script gate `MacTasks` calls. The approved digest is taken from `source` before the
/// ask. The second digest is taken from the slot after the ask.
public enum MacScriptRun {
  public static let changed = "The script changed after it was approved, so it was not run."

  public struct Checked: Sendable {
    public var answer: ApprovalGate.HumanAnswer
    /// The script read back after the ask.
    public var live: String
    /// The osascript arguments of `live` when they still match the approved bytes.
    public var arguments: [String]?
    public var changed: Bool
  }

  /// Runs on the main actor. `answer` is the alert or the relay card. The slot is what was hashed
  /// and what is read back. `MacTasks` presents that string in a read-only text view for the fallback.
  @MainActor
  public static func perform(
    source: String,
    slot: ScriptSlot,
    answer: @MainActor () async -> ApprovalGate.HumanAnswer
  ) async -> Checked {
    let approved = ScriptPayload.digest(source)
    slot.present(source)
    let human = await answer()
    let live = slot.string
    let arguments = ScriptPayload.arguments(live)
    let changed = ScriptPayload.digest(of: arguments) != approved
    return Checked(answer: human, live: live, arguments: changed ? nil : arguments, changed: changed)
  }

  /// The arguments to hand to the run step. A mismatch refuses, and returns nothing to run.
  public static func requireUnchanged(_ checked: Checked) throws -> [String] {
    guard !checked.changed, let arguments = checked.arguments else {
      throw SereinError.invalid(changed)
    }
    return arguments
  }
}
