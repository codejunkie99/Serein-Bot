import Foundation
import SereinCore

/// One channel (owner, 2026-11-25): the person or any assistant tags assistants by name in the
/// chat, and each one tagged takes a turn there. A turn is a hand-off that answers its tag
/// (`AssistantHandoff.mention`), so the room, packet, seat and every cap apply, and its reply posts
/// once, under the tag (`postReport`). A tagged root never wakes its sender: the reply is the answer.
extension RelayOrchestrator {
  /// The person's message tags assistants other than this chat's own: it posts as their message
  /// and each one tagged takes a turn. False leaves it to the usual path: no tag, a bare tag, a stop.
  func startGroupTurn(_ text: String) -> Bool {
    let speakers = GroupTurn.speakers(of: text, in: team).filter { $0 != team.activeID }
    let words = GroupTurn.words(of: text, in: team)
    guard !speakers.isEmpty, !words.isEmpty, RelayStop.kind(words) == nil else { return false }
    if state.paused { resume() }
    var bubble = AgentMessage(role: "you", text: text)
    bubble.mentions = speakers
    deliverAnswer(bubble, into: threadID)
    let refused = tag(speakers, task: text, from: profile(id: team.activeID), parent: nil, chat: threadID, readOutside: false,
                      mention: .byPerson(message: bubble.id), rootMessage: bubble.id).refused
    for (id, words) in refused {
      var line = AgentMessage(role: "assistant", text: "", notice: true)
      line.from = id
      line.re = bubble.id
      line.line = String(words.prefix { $0 != "." }) + "."
      deliverAnswer(line, into: threadID)
    }
    return true
  }

  /// Each assistant in `speakers` takes a turn on `task`, as a hand-off from `sender` that answers
  /// `mention`. Never `sender` itself, nor, for an assistant's tag, one already working on a tag
  /// from `sender` here (its reply naming who it asked again); anyone
  /// `Staffing.decide` refuses (chain, depth, per-task and open caps) is returned with its words.
  @discardableResult
  func tag(_ speakers: [String], task: String, from sender: RelayProfile, parent: AssistantHandoff?, chat: String,
           readOutside: Bool, mention: AssistantHandoff.Mention, rootMessage: String? = nil)
    -> (seated: [String], refused: [(id: String, words: String)])
  {
    var seated: [String] = []
    var refused: [(id: String, words: String)] = []
    let asked = parent?.threadID ?? chat
    let byPerson = if case .byPerson = mention { true } else { false }
    for id in speakers where id != sender.id {
      guard byPerson || !handoffLedger.records.contains(where: {
        $0.isOpen && $0.mention != nil && $0.from == sender.id && $0.to == id && $0.parentID == parent?.id && $0.askedIn == asked
      }) else { continue }
      let staffed = staff(.teammate(id), sender: sender, parent: parent, chat: chat, readOutside: readOutside, message: rootMessage)
      switch staffed.verdict {
      case .seat:
        _ = sendHandoff(from: sender, to: profile(id: id), task: String(task.prefix(HandoffLedger.taskLimit)), team: "",
                        teamName: "All assistants", parent: parent, room: staffed.room, how: .auto, mention: mention,
                        rootMessage: rootMessage)
        seated.append(id)
      case .carryOn(let words), .retryClean(let words): refused.append((id, words))
      case .make, .makeTeam: refused.append((id, "That assistant can't take a turn now."))
      }
    }
    return (seated, refused)
  }

  /// `text` posts in the chat the person sees, from `sender`, and each assistant it tags takes a
  /// turn answering it (`tag`). `parent`: the hand-off whose run posts, whose results wait for those
  /// turns. `addressed`: words from a reply, where only a tag with words after it counts, and
  /// nothing posts unless someone was tagged (its report is its post).
  @discardableResult
  func channelSay(_ text: String, from sender: RelayProfile, parent: AssistantHandoff?, chat: String, readOutside: Bool,
                  addressed: Bool = false) -> (post: String, seated: [String], refused: [(id: String, words: String)])
  {
    let speakers = GroupTurn.speakers(of: text, in: team, addressed: addressed)
    if addressed && speakers.isEmpty { return ("", [], []) }
    let id = "channel-say-" + UUID().uuidString
    let turns = tag(speakers, task: text, from: sender, parent: parent, chat: chat, readOutside: readOutside, mention: .byBot(post: id))
    if addressed && turns.seated.isEmpty { return ("", [], turns.refused) }
    let origin = parent.map(originChat) ?? chat
    var post = AgentMessage(role: "assistant", text: "", notice: true)
    post.id = id
    post.from = sender.id
    post.re = parent.map { $0.mention?.post ?? Self.handoffPostID($0.id) } ?? lastPersonMessage(chat)
    post.mentions = turns.seated.isEmpty ? nil : turns.seated
    let personal = parent?.personal == true || agent.readsPersonal(thread: parent?.threadID ?? chat)
    if let words = channelWords(text, personal: personal, into: origin) {
      post.text = words
    } else {
      post.line = AskPolicy.withheld(sender.name)
    }
    channelPost(post, into: origin)
    return (id, turns.seated, turns.refused)
  }

  /// The chat's own assistant ended its reply tagging others ("@Writer can you…"): each takes a
  /// turn answering that reply. Only a turn with no tool call, which would have tagged with
  /// channel_say, and only a tag with words after it (TEAMS-V2).
  func tagFromReply(_ run: AgentRun) {
    guard run.record.outcome == .done, run.steps.isEmpty, team.profiles.count > 1,
      let reply = run.transcript.last(where: { $0.role == "assistant" && $0.notice != true && !$0.text.isEmpty })
    else { return }
    let sender = profile(id: team.activeID)
    let speakers = GroupTurn.speakers(of: reply.text, in: team, addressed: true)
    guard !speakers.isEmpty else { return }
    let seated = tag(speakers, task: reply.text, from: sender, parent: nil, chat: run.spec.threadID, readOutside: false,
                     mention: .byBot(post: reply.id)).seated
    guard !seated.isEmpty else { return }
    agent.amendThread(run.spec.threadID) { messages in
      guard let i = messages.lastIndex(where: { $0.id == reply.id }) else { return }
      messages[i].from = sender.id
      messages[i].mentions = seated
    }
  }
}

extension RelayToolHost {
  /// `channel_say {text}`: posts in the chat the person sees, as the calling assistant (a
  /// hand-off's target from its run, else the turn's own), and tags take turns (`channelSay`).
  func channelSay(_ a: [String: Any], handoffChat: String? = nil) async throws -> [String: Any] {
    let parent = handoffChat.flatMap { relay.handoffLedger.running(thread: $0) }
    let sender: RelayProfile
    let readOutside: Bool
    if let handoffChat {
      guard let target = relay.team.profiles.first(where: { $0.id == parent?.to }) else {
        throw SereinError.invalid("That hand-off is no longer open, so nothing was posted.")
      }
      sender = target
      readOutside = relay.agent.hub.run(for: handoffChat)?.steps.isEmpty == false
    } else {
      sender = relay.profile(id: frame.profile)
      readOutside = frame.readOutside
    }
    guard let text = (a["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
      throw SereinError.invalid("text is required: the message to post.")
    }
    let said = relay.channelSay(text, from: sender, parent: parent, chat: parent?.threadID ?? frame.thread, readOutside: readOutside)
    var out: [String: Any] = ["posted": said.post, "tagged": said.seated.map(relay.profileName)]
    if !said.refused.isEmpty {
      out["not_tagged"] = Dictionary(said.refused.map { (relay.profileName($0.id), $0.words) }, uniquingKeysWith: { a, _ in a })
    }
    out["note"] = said.seated.isEmpty ? "Posted. Nobody was tagged, so nobody takes a turn."
      : parent == nil ? "Posted. Their replies show in the chat. End this turn in one line."
      : "Posted. Their replies come back to you here before you finish. Do what you can of the rest now, then end this turn in one line."
    return out
  }
}
