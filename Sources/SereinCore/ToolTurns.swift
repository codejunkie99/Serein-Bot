import Foundation

/// The order of one task's browser calls when its helper sends several at the same time (an MCP
/// client runs tools marked read-only in parallel). A read-only call (ToolSchema.readOnlyTools)
/// runs beside read-only calls on other tabs. A second call on the same tab waits, because a read
/// replaces that tab's references. Any other call (an action, open, finish) waits for every
/// earlier call and then runs alone. A call never passes an earlier call on its own tab or an
/// earlier action. Pure state: the app's ToolGate resumes the waiting calls this returns.
public struct ToolTurns {
  struct Call {
    let id: Int
    let write: Bool
    let tab: String?
  }
  private var waiting: [Call] = []
  private var running: [Call] = []
  public init() {}

  /// How a browser call takes its turn: an action unless the tool is read-only, on the tab its
  /// arguments name. The app's ToolGate and the agent's helper both use this, so they agree.
  public static func turn(name: String, arguments: Any?) -> (write: Bool, tab: String?) {
    (!ToolSchema.readOnlyTools.union(PeerTools.readOnly).contains(name), (arguments as? [String: Any])?["tab"] as? String)
  }

  /// Adds a call. True when it may start now; otherwise it starts when a later
  /// `finish` or `cancel` returns its id.
  public mutating func request(id: Int, write: Bool, tab: String?) -> Bool {
    waiting.append(Call(id: id, write: write, tab: tab))
    return start().contains(id)
  }
  /// A running call ended. Returns the ids that may start now.
  public mutating func finish(id: Int) -> [Int] {
    running.removeAll { $0.id == id }
    return start()
  }
  /// A waiting call gave up (its time limit passed). Returns the ids that may start now.
  public mutating func cancel(id: Int) -> [Int] {
    waiting.removeAll { $0.id == id }
    return start()
  }
  /// No call runs or waits.
  public var isIdle: Bool { waiting.isEmpty && running.isEmpty }
  /// How many calls run now.
  public var runningCount: Int { running.count }

  /// Starts every waiting call the rules allow, in arrival order.
  private mutating func start() -> [Int] {
    var started: [Int] = []
    // Tabs with an earlier read still waiting: a later read of the same tab stays behind it.
    var heldTabs = Set<String>()
    var index = 0
    while index < waiting.count {
      let call = waiting[index]
      if call.write {
        // An action starts only first in line with nothing running; nothing passes it.
        guard index == 0, running.isEmpty else { break }
      } else {
        let free = !running.contains { $0.write }
          && (call.tab.map { tab in !heldTabs.contains(tab) && !running.contains { $0.tab == tab } } ?? true)
        guard free else {
          if let tab = call.tab { heldTabs.insert(tab) }
          index += 1
          continue
        }
      }
      running.append(waiting.remove(at: index))
      started.append(call.id)
      if call.write { break }
    }
    return started
  }
}
