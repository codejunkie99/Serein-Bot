import Foundation
import SereinCore

/// The state behind `ApprovalLife`: which cards ended by themselves (for their collapsed line),
/// which were raised with nobody there, and what the person declined since their last message.
/// In memory only: a restart asks again.
@MainActor final class ApprovalEnds: ObservableObject {
  static let shared = ApprovalEnds()
  /// How a card ended, by the card's id, for `RelayAnsweredLine`.
  @Published private(set) var ends: [UUID: ApprovalLife.End] = [:]
  private(set) var background: Set<UUID> = []
  private(set) var denials = ApprovalLife.Denials()

  func end(_ id: UUID, _ end: ApprovalLife.End) {
    ends[id] = end
    background.remove(id)
  }
  func markBackground(_ id: UUID) { background.insert(id) }
  func deny(_ approval: RelayOrchestrator.Approval) {
    denials.deny(ApprovalLife.Denials.key(title: approval.title, detail: approval.detail, thread: approval.threadID))
  }
  func forgetDenial(title: String, detail: String, thread: String?) {
    denials.forget(ApprovalLife.Denials.key(title: title, detail: detail, thread: thread))
  }
  func personSpoke(in thread: String) {
    denials.personSpoke(in: thread)
  }
}

extension RelayOrchestrator {
  /// The person sent a new message in `thread`: the cards that chat was waiting on close as
  /// skipped (a no, so nothing runs), and what they declined before it no longer holds. Call once per message the person types, before its turn starts.
  func personSpoke(thread: String) {
    for approval in approvals
    where ApprovalLife.skips(
      cardThread: approval.threadID ?? threadID, background: ApprovalEnds.shared.background.contains(approval.id),
      messageThread: thread)
    {
      ApprovalEnds.shared.end(approval.id, .skipped)
      approval.answer(.no)
    }
    ApprovalEnds.shared.personSpoke(in: thread)
  }

  /// A card raised with nobody there (a routine, a check-in deferred it): the person's next
  /// message leaves it, and it waits for the day sweep like every card (`sweepApprovals`).
  func markBackground(_ id: UUID) { ApprovalEnds.shared.markBackground(id) }

  /// The person's Decline on a card: the same action is not asked again until they write.
  func decline(_ approval: Approval) {
    ApprovalEnds.shared.deny(approval)
    approval.answer(.no)
  }

  /// Whether this exact ask was declined since the person's last message: it gets no second card.
  func refusesRetry(title: String, detail: String, thread: String?) -> Bool {
    guard ApprovalEnds.shared.denials.blocks(ApprovalLife.Denials.key(title: title, detail: detail, thread: thread))
    else { return false }
    note("Declined earlier, so it was not asked again: \(title)", .declined)
    return true
  }
}
