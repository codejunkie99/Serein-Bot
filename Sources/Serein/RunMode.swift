import Foundation
import SereinCore

/// How this process was started, read once from its arguments: a check (`--verify…`), a UI
/// preview (`--ui-preview`) or a stress run (`--stress`). Checks and previews never open a panel
/// or alert, and none of the three writes the person's settings or watches their sessions.
enum RunMode {
  #if DEBUG
  static let mode = LaunchMode(arguments: CommandLine.arguments, checksBuilt: true)
  #else
  static let mode = LaunchMode(arguments: CommandLine.arguments, checksBuilt: false)
  #endif
  static var checking: Bool { mode.checking }
  static var previewing: Bool { mode.previewing }
  static var stress: Bool { mode.stress }
  /// A check or a preview run: nobody is there to answer a panel or alert.
  static var automated: Bool { checking || previewing }
}
