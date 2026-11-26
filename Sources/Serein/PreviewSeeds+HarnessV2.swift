import Foundation
import SereinCore

/// `--ui-preview --ui-harness-v2 [seed]`: Serein's chat as harness v2 leaves it, for the views that
/// draw it (docs/harness-v2-views.md). With no seed, every one in order. Data only: the
/// messages carry the ids and fields the real builders give them (RelayChannel, RelayGroupTurn,
/// RelaySideSeats, RelaySwarm), and the receipts and the archive go through the real calls, so
/// their Undo works. No hand-off row is made, so nothing starts a run. Previews write only to their
/// throwaway library and keep GateSettings in memory.
extension RelayOrchestrator {
  enum HarnessV2Seed: String, CaseIterable {
    /// The person tags Writer; Writer's reply answers the tag.
    case mention
    /// Serein's channel_say to Scout, its hand-off to Planner, a room note, and both reports
    /// (Scout's with decisions, files and open parts).
    case channel
    /// A side answer to a busy chat, a side-wait line, and a turn moved to the background with
    /// its stopped partial reply and its later answer.
    case side
    /// A swarm's line and its one merged answer.
    case swarm
    /// One tag Planner refused: its refusal line under the person's message.
    case refusal
    /// The Allow all receipt and a setting_change receipt, each with Undo.
    case receipts
    /// Coach archived at Allow all, with its receipt.
    case archived
  }

  func previewHarnessV2() {
    let arguments = CommandLine.arguments
    guard let flag = arguments.firstIndex(of: "--ui-harness-v2"), let me = team.main,
      let scout = team.profile(named: "Scout"), let planner = team.profile(named: "Planner"),
      let writer = team.profile(named: "Writer")
    else { return }
    let named = arguments.dropFirst(flag + 1).first.flatMap(HarnessV2Seed.init(rawValue:))
    let seeds = named.map { [$0] } ?? HarnessV2Seed.allCases
    let messages = seeds.flatMap { Self.harnessV2Messages($0, me: me.id, scout: scout.id, planner: planner.id, writer: writer.id) }
    var chat = Conversation(
      id: threadID, title: "Harness v2", messages: messages, provider: .claude, mode: .anywhere, projectID: nil, remoteID: nil,
      scope: "", updatedAt: Date())
    chat.lastMessageAt = Date()
    agent.conversations.removeAll { $0.id == threadID }
    agent.conversations.insert(chat, at: 0)
    if seeds.contains(.receipts) {
      deliver(receipt: ReceiptCopy.allowAll(entry: AllowAllMigration.undoEntry), into: threadID)
      let name = ChatSettings.approvalLevel
      if let before = chatSetting(name), (try? writeChatSetting(name, ApprovalLevel.riskyOnly.title)) != nil, let after = chatSetting(name) {
        _ = settingChanged(SettingChange(id: UUID().uuidString, name: name, before: before, after: after),
                           title: "How much Serein asks", shown: { $0 }, into: threadID)
      }
    }
    if seeds.contains(.archived), let coach = team.profile(named: "Coach"), case .success(let plan) = deletePlan(for: coach.id),
      let deleted = applyDelete(plan, actor: "relay")
    {
      deliver(receipt: ReceiptCopy.archived(name: coach.name, entry: deleted.undo?.entry ?? ""), into: threadID)
    }
  }

  private static func harnessV2Messages(_ seed: HarnessV2Seed, me: String, scout: String, planner: String, writer: String)
    -> [AgentMessage]
  {
    func you(_ text: String, mentions: [String]? = nil) -> AgentMessage {
      var message = AgentMessage(role: "you", text: text)
      message.mentions = mentions
      return message
    }
    func said(_ id: String, _ text: String, from: String, re: String?, mentions: [String]? = nil, notice: Bool = true,
              line: String? = nil, parts: [AgentMessage.Part]? = nil) -> AgentMessage
    {
      var message = AgentMessage(role: "assistant", text: text, notice: notice)
      message.id = id
      message.from = from
      message.re = re
      message.mentions = mentions
      message.line = line
      message.parts = parts
      return message
    }
    switch seed {
    case .mention:
      let ask = you("@Writer draft a two-line toast for Sam's leaving party.", mentions: [writer])
      return [ask, said(HandoffReport.postID("preview-hv2-mention"),
                        "To Sam: five years of fixing what the rest of us broke. Lisbon is lucky to have you.", from: writer, re: ask.id)]
    case .channel:
      let ask = you("Find a dinner spot for six near the office on Friday, and check who can come.")
      let say = said("channel-say-preview-hv2", "@Scout find three places with a table for six on Friday at 7:30.",
                     from: me, re: ask.id, mentions: [scout])
      let handoff = said(handoffPostID("preview-hv2-planner"), "@Planner check who can make Friday at 7:30.",
                         from: me, re: ask.id, mentions: [planner])
      let note = said("room-note-preview-hv2-room-1", "Ana is away Friday, so it is five, not six.", from: planner,
                      re: handoffPostID("preview-hv2-planner"))
      let scoutReport = said(HandoffReport.postID("preview-hv2-scout"),
                             "Three places have a table for six at 7:30: Tasca Rosa, Okra and The Long Room.", from: scout,
                             re: say.id, mentions: [me], parts: [
                               .init(kind: .decisions, items: ["Kept to a 10-minute walk from the office"]),
                               .init(kind: .files, items: ["dinner-options.md"]),
                               .init(kind: .open, items: ["Okra wants a deposit for six"]),
                             ])
      let plannerReport = said(HandoffReport.postID("preview-hv2-planner"), "Five of six can come. Ana is away.",
                               from: planner, re: handoffPostID("preview-hv2-planner"), mentions: [me])
      return [ask, say, handoff, note, scoutReport, plannerReport]
    case .side:
      let busy = you("Summarise this week's board notes.")
      let side = you("Also, what time is the dentist on Thursday?")
      let full = you("Book a table for two somewhere quiet tonight.")
      let long = you("Compare the three laptop quotes in my mail.")
      return [
        busy, side,
        said(HandoffReport.postID("preview-hv2-side"), "Thursday at 9:40, with Dr Patel on Elm Street.", from: me, re: side.id,
             notice: false),
        full, said("side-wait-preview-hv2-full", "", from: me, re: full.id, line: SideSeat.fullLine),
        long, AgentMessage(role: "assistant", text: "The Dell quote is the cheapest so far, but I still need to read"),
        said("background-preview-hv2-long", "", from: me, re: long.id, line: SideSeat.backgroundLine),
        said(HandoffReport.postID("preview-hv2-long"), "The Lenovo quote is best value: $1,180 with three years of cover.",
             from: me, re: long.id, notice: false),
      ]
    case .swarm:
      let ask = you("Which of the two job offers pays more over four years?")
      return [
        ask,
        said("swarm-preview-hv2-seat-1", Swarm.line(models: ["opus", "gpt-5.5"], asked: 3, waiting: 0), from: me, re: ask.id),
        said(HandoffReport.postID("preview-hv2-swarm-lead"),
             "The Northwind offer pays about $38,000 more over four years once the vesting is counted. Both models agree.",
             from: me, re: ask.id, notice: false),
      ]
    case .refusal:
      let ask = you("@Scout @Planner look at the Lisbon budget.", mentions: [scout, planner])
      let refused = "That assistant can't take a turn now."
      return [
        ask,
        said(HandoffReport.postID("preview-hv2-refusal"), "The budget has $860 left for three nights.", from: scout, re: ask.id),
        said(UUID().uuidString, "", from: planner, re: ask.id, line: String(refused.prefix { $0 != "." }) + "."),
      ]
    case .receipts:
      return [you("Only ask me about risky steps.")]
    case .archived:
      return [you("Delete Coach, I don't use it.")]
    }
  }
}
