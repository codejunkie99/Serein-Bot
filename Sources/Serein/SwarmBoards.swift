import Foundation
import SereinCore
import SereinEngines

/// The app's copy of every swarm board. Peers owns a board while its swarm runs and sends each
/// change here (`AppPeerHost.swarmChanged`); this store is the only writer of `swarms/` and of a
/// chat's count line. ACP stays the wire between Serein and each CLI; the board is the record the
/// person reads and speaks through.
@MainActor final class SwarmBoards: ObservableObject {
  static let shared = SwarmBoards()

  /// Boards sent in this launch, by id.
  @Published private(set) var live: [String: SwarmBoard] = [:]
  /// Boards read from disk, closed: no bot outlives a relaunch.
  private var saved: [String: SwarmBoard] = [:]
  /// The board open over the chat.
  @Published var open: SwarmLink?

  /// Keeps the newest copy, saves it in its chat, and puts or updates the chat's count line.
  func take(_ incoming: SwarmBoard, task: String, browser: BrowserModel) {
    var board = incoming
    if let held = live[board.id] {
      guard board.version > held.version else { return }
      board.room = held.room
    }
    let hub = browser.agentTabs.hub
    let run = hub?.runs.last { $0.taskID == task }
    if board.room.isEmpty, let run { board.room = run.spec.threadID }
    live[board.id] = board
    guard !board.room.isEmpty else { return }
    save(board, in: browser.library)
    guard let hub, let run else { return }
    let line = board.countLine
    if let i = run.transcript.firstIndex(where: { $0.swarm == board.link }) {
      guard run.transcript[i].line != line else { return }
      run.transcript[i].line = line
    } else {
      var message = AgentMessage(role: "assistant", text: "", notice: true)
      message.line = line
      message.swarm = board.link
      // Above the reply that is streaming, so the reply stays the last assistant message.
      if let last = run.transcript.indices.last, run.transcript[last].role == "assistant" {
        run.transcript.insert(message, at: last)
      } else {
        run.transcript.append(message)
      }
    }
    hub.onTranscript?(run)
  }

  func save(_ board: SwarmBoard, in library: Library) {
    let folder = library.root.appendingPathComponent(board.link.path).deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    library.saveSoon(board, to: board.link.path)
  }

  /// The board as it is now, or as saved when its swarm ran in an earlier launch.
  func board(_ link: SwarmLink, library: Library) -> SwarmBoard? {
    if let board = live[link.id] { return board }
    if let board = saved[link.id] { return board }
    let board = library.load(SwarmBoard.self, from: link.path)?.closedAfterRelaunch()
    saved[link.id] = board
    return board
  }

  /// The person's words to one bot. They show on the board and go straight into its seat; words
  /// to the lead go into the chat's own run the way the composer sends them.
  func tell(_ link: SwarmLink, member: String, words: String, agent: AgentModel) async {
    let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let delivery = await agent.hub.peers.command(board: link.id, member: member, words: text)
    if delivery == .lead, let run = agent.hub.run(for: link.room), run.isActive { agent.flow.steer(run, text) }
  }

  /// Stops one bot. Stopping the lead stops the chat's run, and with it every bot it started.
  func stop(_ link: SwarmLink, member: String, agent: AgentModel) async {
    let delivery = await agent.hub.peers.stopMember(board: link.id, member: member)
    if delivery == .lead, let run = agent.hub.run(for: link.room) { agent.hub.stop(run) }
  }

  #if DEBUG
  /// `--ui-swarm-line` and `--ui-swarm-board`: a swarm of 13 bots in chat `room`, helpers nested
  /// two deep, every state shown, as if Peers had sent it. Returns the chat's count line.
  func seedPreview(room: String, open: Bool) -> AgentMessage {
    let base = Date().addingTimeInterval(-600)
    var board = SwarmBoard(id: "preview-swarm", room: room, goal: "Move the swarm prompts into one file and add the live board")
    board.register(name: "coordinator", role: .coordinator, workspace: .inherit, at: base)
    let workers: [(String, String, String)] = [
      ("prompts", "codex", "Move every swarm prompt into SwarmPrompts"), ("board", "claude", "Give SwarmBoard ids, parents and states"),
      ("peers", "codex", "Publish each board change from Peers"), ("store", "claude", "Save boards per chat"),
      ("view", "claude", "Draw the board in house style"), ("tests", "opencode", "Write the swarm checks"),
      ("docs", "grok", "Write the cofounder note"), ("a11y", "claude", "Label every control"),
    ]
    for (name, agent, task) in workers {
      board.register(name: name, role: .worker, workspace: .worktree, parent: "coordinator", agent: agent, task: task, at: base)
    }
    board.register(name: "verifier", role: .verifier, workspace: .readOnly, parent: "coordinator", agent: "codex", task: "Check every report", at: base)
    for (name, parent, agent) in [("view-codex", "view", "codex"), ("view-codex-grok", "view-codex", "grok"),
                                  ("store-codex", "store", "codex"), ("tests-claude", "tests", "claude")] {
      board.register(name: name, role: .helper, workspace: .inherit, parent: parent, agent: agent, at: base)
    }
    let posts: [(String, String, SwarmPost.Kind)] = [
      ("coordinator", "@prompts Goal: one prompt file\nYour slice: Move every swarm prompt into SwarmPrompts", .brief),
      ("coordinator", "@board Goal: one prompt file\nYour slice: Give SwarmBoard ids, parents and states", .brief),
      ("coordinator", "@view Goal: live board\nYour slice: Draw the board in house style", .brief),
      ("view", "@view-codex List the palette colors the chat uses for states", .update),
      ("view-codex", "@view-codex-grok Check which of those pass contrast on the dark card", .update),
      ("view-codex-grok", "@view-codex [done] accent, success and warning pass; faint fails on dark, use it for text only", .done),
      ("view-codex", "@view [done] accent, success, warning, danger, faint. Contrast notes in #6", .done),
      ("prompts", "@coordinator [done] SwarmPrompts.swift holds all swarm text. Peers and PeerTools hold none, see #1", .done),
      ("board", "@coordinator [done] SwarmBoard has id, room, parent and stalled. Codable stays backward compatible", .done),
      ("store", "@store-codex Find where the library creates folders", .update),
      ("you", "@tests Skip the relay suite, it is flaky on main", .update),
      ("tests", "@you Skipping relay. Running swarmBoard and swarmWriters only", .update),
      ("store-codex", "@store [stall] Library.saveText does not create folders; waiting on #10", .stall),
      ("verifier", "@view Fix: the close control needs an accessibility label. See #3", .update),
      ("docs", "@coordinator [done] Cofounder note added to docs/harness-v2-views.md", .done),
    ]
    for (i, (author, text, kind)) in posts.enumerated() {
      board.post(author: author, text: text, kind: kind, at: base.addingTimeInterval(Double(i * 20)))
    }
    let states: [String: SwarmMemberState] = [
      "coordinator": .working, "prompts": .done, "board": .done, "peers": .working, "store": .waiting, "view": .working,
      "tests": .working, "docs": .done, "a11y": .stopped, "verifier": .working, "view-codex": .done, "view-codex-grok": .done,
      "store-codex": .stalled, "tests-claude": .waiting,
    ]
    for (name, state) in states { board.setState(name, to: state) }
    live[board.id] = board
    if open { self.open = board.link }
    var message = AgentMessage(role: "assistant", text: "", notice: true)
    message.line = board.countLine
    message.swarm = board.link
    return message
  }
  #endif
}
