import Foundation

/// When a task held while offline may go out without the user pressing Send.
///
/// Reconnecting within the same app session sends a held task in the thread it was written in.
/// A task that survived a quit never sends by itself: after a restart the user may have changed
/// their mind, so it waits as a "Ready to send" row with Send, Edit and Discard.
public enum HeldTaskPolicy {
  /// `heldThisSession`: ids of tasks held since Serein launched.
  public static func autoSends(
    _ task: PendingTask, heldThisSession: Set<String>, online: Bool, openThread: String
  ) -> Bool {
    online && task.threadID == openThread && heldThisSession.contains(task.id)
  }
  /// Tasks kept from an earlier session, oldest first.
  public static func restored(_ queue: OfflineQueue, heldThisSession: Set<String>) -> [PendingTask] {
    queue.tasks.filter { !heldThisSession.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
  }
}
