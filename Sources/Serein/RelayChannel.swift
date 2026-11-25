import Foundation
import SereinCore

/// One channel in the chat a task started in: each hand-off ("@Theo …" from its sender), each
/// report and each decision or question a seat notes posts there under its assistant's name
/// (`AgentMessage.from`), with what it answers (`re`) and whom it tags (`mentions`). Every post has a
/// fixed id, so a replay or a relaunch posts it once.
extension RelayOrchestrator {
  /// The most a channel post's words take; the packet's summary keeps its own 1,200.
  static let channelCap = 600
  static func handoffPostID(_ id: String) -> String { "handoff-post-" + id }

  /// The chat `record`'s task started in: its root's.
  func originChat(_ record: AssistantHandoff) -> String {
    guard let root = record.rootID else { return record.askedIn }
    return handoffLedger.records.first { $0.id == root }?.askedIn ?? record.askedIn
  }

  /// "@Theo Find three venues" from its sender, answering the person's message (`message`) or, for
  /// a part, the hand-off that sent it.
  func postHandoff(_ record: AssistantHandoff, answering message: String?) {
    let origin = originChat(record)
    var post = AgentMessage(role: "assistant", text: "", notice: true)
    post.id = Self.handoffPostID(record.id)
    post.from = record.from
    post.re = record.parentID.map(Self.handoffPostID) ?? message
    post.mentions = [record.to]
    let personal = record.personal == true || agent.readsPersonal(thread: record.askedIn)
    if let words = channelWords("@\(profileName(record.to)) " + record.task, personal: personal, into: origin) {
      post.text = words
    } else {
      post.line = AskPolicy.withheld(profileName(record.from))
    }
    channelPost(post, into: origin)
  }

  /// A closed hand-off's report, from its target to its sender, keyed by `HandoffReport.postID`.
  /// True once it is in the chat; false while that chat is busy or gone.
  @discardableResult
  func postReport(_ record: AssistantHandoff) -> Bool {
    guard !record.isOpen else { return false }
    let origin = originChat(record)
    var post = AgentMessage(role: "assistant", text: "", notice: true)
    post.id = HandoffReport.postID(record.id)
    post.from = record.to
    // A tagged turn answers the message that tagged it; the person who tagged is not a bot to tag.
    post.re = record.mention?.post ?? Self.handoffPostID(record.id)
    if case .byPerson = record.mention {} else { post.mentions = [record.from] }
    if let words = channelWords(record.result ?? "", personal: agent.readsPersonal(thread: record.threadID), into: origin) {
      post.text = words
      if let report = rooms.report(record.id), !report.byHost {
        let parts: [AgentMessage.Part] = [
          .init(kind: .decisions, items: report.decisions), .init(kind: .files, items: report.files.map(\.path)),
          .init(kind: .open, items: report.open.map(\.text)),
        ].filter { !$0.items.isEmpty }
        post.parts = parts.isEmpty ? nil : parts
      }
    } else {
      post.line = AskPolicy.withheld(profileName(record.to))
    }
    channelPost(post, into: origin)
    return chatHas(post.id, in: origin)
  }

  /// A decision or a question a seat noted for the team, about its hand-off's post.
  func postNote(_ note: RoomNote, room: Workroom.ID, record: AssistantHandoff) {
    guard note.kind == .decision || note.kind == .ask else { return }
    let origin = originChat(record)
    var post = AgentMessage(role: "assistant", text: "", notice: true)
    post.id = "room-note-\(room)-\(note.seq)"
    post.from = record.to
    post.re = Self.handoffPostID(record.id)
    if let words = channelWords(note.text, personal: agent.readsPersonal(thread: record.threadID), into: origin) {
      post.text = words
    } else {
      post.line = AskPolicy.withheld(profileName(record.to))
    }
    channelPost(post, into: origin)
  }

  /// `text` capped for the channel, or nil when it carries personal data and the chat's mark
  /// cannot be saved (its words are withheld).
  func channelWords(_ text: String, personal: Bool, into origin: String) -> String? {
    guard !personal || agent.markPersonalRead(thread: origin) else { return nil }
    return AgentPrivacy.redact(text, limit: Self.channelCap)
  }

  /// Writes `message` into `thread` once: a post whose id is in the chat, or waits to land there,
  /// changes nothing. Never makes a chat: one the person deleted stays gone.
  func channelPost(_ message: AgentMessage, into thread: String) {
    guard thread == agent.conversationID || agent.conversations.contains(where: { $0.id == thread }),
      !chatHas(message.id, in: thread),
      desk.facts[thread]?.above.contains(where: { $0.id == message.id }) != true,
      !desk.posts.contains(where: { $0.thread == thread && $0.message.id == message.id })
    else { return }
    deliverAnswer(message, into: thread)
  }

  /// `id` is saved in `thread`, or folded into one of its summaries (`ChatCondense`).
  func chatHas(_ id: String, in thread: String) -> Bool {
    let saved = thread == agent.conversationID ? agent.messages : agent.conversations.first { $0.id == thread }?.messages ?? []
    let live = agent.hub.latest(for: thread)?.transcript ?? []
    return (saved + live).contains { $0.id == id || $0.condensed?.originals.contains { $0.id == id } == true }
  }
}
