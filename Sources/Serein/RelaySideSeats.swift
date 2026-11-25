import Foundation
import SereinCore

/// No queue (owner, 2026-11-25): a message to a chat whose turn is busy never waits behind it.
/// It posts at once and takes a side seat, a hidden seat thread of the chat's own assistant
/// (`AssistantHandoff.side`), whose answer posts back under it once (`postReport`, keyed). A turn
/// of the person's past `SideSeat.foregroundLimit` moves to a side seat the same way, so the chat
/// is free. Side seats share the delegated-run cap; past it the message says so and runs when a
/// seat frees.
extension RelayOrchestrator {
  /// Side seats running or starting, plus delegated runs working, are under the cap.
  var sideSeatFree: Bool {
    let seated = handoffLedger.records.filter {
      $0.side != nil && ($0.state == .running || ($0.state == .waiting && handoffsStarting.contains($0.threadID)))
    }
    return SideSeat.free(seated: seated.count, delegated: liveTasks)
  }

  /// The person's plain message to this chat while its turn is busy: in the chat now, answered
  /// by a side seat of this chat's assistant, or, with every seat taken, a line saying it runs
  /// when one frees.
  func startSideSeat(_ text: String) {
    let chat = threadID
    let me = profile(id: team.activeID)
    let bubble = AgentMessage(role: "you", text: text)
    deliverAnswer(bubble, into: chat)
    let record = sendHandoff(
      from: me, to: me, task: String(text.prefix(HandoffLedger.taskLimit)), team: "", teamName: "All assistants", how: .auto,
      mention: .byPerson(message: bubble.id), rootMessage: bubble.id, side: .busy, chat: chat)
    guard record.state == .waiting, !handoffsStarting.contains(record.threadID) else { return }
    var line = AgentMessage(role: "assistant", text: "", notice: true)
    line.id = "side-wait-" + record.id
    line.from = me.id
    line.re = bubble.id
    line.line = SideSeat.fullLine
    channelPost(line, into: chat)
  }

  /// From the sweep: the person's own turn on screen past the limit moves to the background.
  func moveLongTurn(now: Date) {
    guard startedByPerson, ownerRun == nil, let run else { return }
    moveLongTurn(run, now: now)
  }

  /// `run`, the person's turn, moves to a background side seat once it is past the limit: the
  /// seat takes its message, its steps so far (the packet's trail) and what it had written, a
  /// line says so, and the turn stops, so the chat is free. One that waits on a card, carries a
  /// page or files, or has no seat free stays. Moved once: its message's seat answers it.
  @discardableResult
  func moveLongTurn(_ run: AgentRun, now: Date) -> AssistantHandoff? {
    let chat = run.spec.threadID
    guard run.isActive, run.spec.relay, run.spec.initiator == .relay, run.attachments == nil,
      let asked = run.transcript.last(where: { $0.role == "you" }),
      SideSeat.moves(startedAt: run.record.startedAt, now: now, moved: handoffLedger.records.contains {
        $0.side == .background && $0.mention?.post == asked.id
      }),
      !(turnThread == chat && turnPage != nil),
      !approvals.contains(where: { ($0.threadID ?? turnThread) == chat }),
      !questionForms.contains(where: { ($0.threadID ?? turnThread) == chat }),
      sideSeatFree
    else { return nil }
    let me = profile(id: assistantOwning(thread: chat) ?? team.activeID)
    let partial = run.transcript.last { $0.role == "assistant" && $0.notice != true && !$0.text.isEmpty }?.text
    let task = asked.text + (partial.map { "\n\nWhat your reply there had said so far:\n" + String($0.suffix(1_500)) } ?? "")
    let record = sendHandoff(
      from: me, to: me, task: String(task.prefix(HandoffLedger.taskLimit)), team: "", teamName: "All assistants", how: .auto,
      mention: .byPerson(message: asked.id), rootMessage: asked.id, side: .background, chat: chat)
    var line = AgentMessage(role: "assistant", text: "", notice: true)
    line.id = "background-" + record.id
    line.from = me.id
    line.re = asked.id
    line.line = SideSeat.backgroundLine
    channelPost(line, into: chat)
    agent.hub.stop(run)
    return record
  }

  /// A stop for the side seats asked in `chat`: every one of them, or, `to`, those of that
  /// assistant (its side seats and the turns a tag gave it). Each ends with its "It was stopped."
  /// post. Returns how many it stopped.
  @discardableResult
  func stopSeats(askedIn chat: String, to id: String?) -> Int {
    let open = handoffLedger.records.filter { record in
      record.isOpen && record.askedIn == chat && record.parentID == nil
        && (id.map { record.to == $0 && (record.side != nil || record.mention != nil) } ?? (record.side != nil))
    }
    for record in open {
      if record.state == .running, let run = agent.hub.run(for: record.threadID), run.spec.initiator == .handoff {
        agent.hub.stop(run)
      } else {
        closeHandoff(record.id, .failed, result: HandoffLedger.stoppedWords)
      }
    }
    return open.count
  }
}
