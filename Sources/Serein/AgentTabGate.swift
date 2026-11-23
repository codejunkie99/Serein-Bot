import Foundation

/// Whether an agent may drive a tab, and whether the connect proxy may be written.
/// A tab the agent does not own is the user's. The default store is the user's.
/// not run on a real Mac. Mac run not verified.
enum AgentTabGate {
  static func mayDrive(owner: String?, task: String, defaultStore: Bool) -> Bool {
    owner == task && defaultStore == false
  }

  static func maySetProxy(owner: String?, openedWith: Bool, defaultStore: Bool) -> Bool {
    owner != nil && openedWith == false && defaultStore == false
  }
}
