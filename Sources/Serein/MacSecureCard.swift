import Foundation
import SereinCore

extension BrowserModel {
  /// A Mac `type` into a password, code or card field (MacControl.act): a card in the task's chat.
  /// The person's value goes from the card into the field and is dropped.
  func macSecureCard(_ target: MacControl.SecureTarget, kind: SecureCard.Kind, task id: String) async throws -> [String: Any] {
    let card = SecureCards.Card(
      kind: kind, parts: kind == .card ? [target.part] : [], host: target.appName, amount: nil, task: id,
      thread: threadID(forTask: id), tab: nil, ref: target.ref, document: target.identity, origin: target.task.bundleID,
      pageVersion: "", mac: target)
    // Like the web card (secureType): the card opens and the call answers at once; the person's
    // answer reaches the task later through secureCardAnswered.
    return PersonStep.fields(secureCards.raise(card))
  }

  /// A parked Mac card was answered after its task's turn ended: one follow-up turn in the chat
  /// when it is idle; otherwise the result stands in the app for the person.
  func parkedMacCardAnswered(_ card: SecureCards.Card, _ result: SecureCard.Result) async {
    guard tasks[card.task] == nil, let thread = card.thread, let agent = intelligenceAgent,
      agent.hub.run(for: thread) == nil, agent.flow.queue.items(for: thread).isEmpty
    else { return }
    if let refused = await agent.flow.replyToTask(
      thread, text: SecureCard.followUp(result, host: card.host, tab: nil), interrupt: false)
    {
      notice = refused
    }
  }
}
