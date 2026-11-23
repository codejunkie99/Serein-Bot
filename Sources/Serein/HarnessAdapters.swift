import AppKit
import Foundation
import SereinCore

/// A running adapter the hub can stop.
@MainActor protocol HarnessTurn: AnyObject {
  func start()
  /// Asks the harness to stop, then ends its process group. The hub has already revoked the
  /// browser capability.
  func interrupt()
  /// Waits until the turn's process has stopped writing, so Edit Review's "after" snapshot holds
  /// the writes a stopped CLI makes on its way out.
  func settled(timeout: TimeInterval) async
}
extension HarnessTurn {
  func settled(timeout: TimeInterval) async {}
}

extension AgentRun {
  /// The harness's own session id, kept for the next turn.
  func noteSession(_ id: String, hub: AgentHub) {
    record.lastEventAt = Date()
    guard remoteID != id else { return }
    remoteID = id
    reportBehaviorSession(id)
    hub.onSession?(self)
  }
  /// Text from the harness (untrusted). After a new message starts, earlier text was narration.
  func noteText(_ text: String) {
    record.lastEventAt = Date()
    if messageStarted, !text.isEmpty {
      messageStarted = false
      startNewMessage()
    }
    append(text)
    if phase != "Writing" { phase = "Writing" }
  }
  /// A piece of the model's reasoning; empty when the harness only signals that it thinks.
  func noteThinking(_ text: String) {
    record.lastEventAt = Date()
    phase = "Thinking"
    think(text)
  }
  /// The harness tries the turn again by itself: that attempt's error and half answer no longer count.
  func noteRetry() {
    record.lastEventAt = Date()
    error = nil
    startNewMessage()
  }
}
