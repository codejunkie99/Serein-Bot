import Foundation

/// Every word a bot reads about swarms and team calls, and the count line the person reads. The
/// free and paid apps both read this file; Peers and PeerTools hold none of this text
/// (scripts/check_swarm_prompts.py).
public enum SwarmPrompts {
  /// How bots write to each other on the board.
  public static let messaging =
    "Bots talk on the swarm board. Keep each message short. Start it with @name for the bot that must act next. Point to an earlier message by its #number instead of pasting it."

  /// How the lead talks to the person about the swarm.
  public static let person =
    "When you tell the person what happened, use plain words. Say what changed and where. Do not ask them anything; pick the safest reasonable choice yourself and say which one you picked."

  /// The peer_swarm tool text: what the lead reads before it decides to swarm.
  public static let swarmTool = """
    Start a swarm. Several agents work on one goal at once, each on its own slice, and you get one combined report. \
    Swarm when the work splits into parts that do not wait on each other, such as separate folders, modules or questions. \
    Do the work yourself when it is small or when each step needs the one before it. \
    Give each part one worker, as many workers as there are parts; there is no limit. \
    Name each worker after its slice, and give it a slice it can finish alone. \
    Set write only for workers that change files. Each writer gets its own git worktree. \
    Add a verifier when the result must be right, such as code that must build or facts that must hold. \
    The verifier reads every report and diff and asks workers for fixes, up to rounds times. \
    Serein merges a writer's changes into your folder when the verifier approves, or at once when there is no verifier. \
    The person can open the board and talk to any worker. \(messaging) \(person)
    """

  /// The board post that hands a worker its slice.
  public static func brief(goal: String, slice: String, to name: String) -> String {
    "@\(name) Goal: \(goal)\nYour slice: \(slice)"
  }

  /// The board post for a helper that a bot called with its own team tools.
  public static func ask(_ prompt: String, to name: String) -> String {
    "@\(name) \(prompt.prefix(400))"
  }

  /// A swarm worker's turn.
  public static func worker(goal: String, name: String, slice: String, workspace: SwarmWorkspaceMode) -> String {
    let folder: String
    switch workspace {
    case .worktree: folder = "Change files only in the folder you were given. It is your own git worktree, and Serein merges it when the swarm ends."
    case .readOnly: folder = "Read only. Do not change any file."
    case .inherit: folder = "Other writers share this folder and take turns. Change only the files of your slice."
    }
    return """
      Swarm goal: \(goal)
      You are @\(name), one worker in a swarm. Your slice: \(slice)
      \(folder)
      Do only your slice; other workers do the rest. Your last message is your report on the board. Start it with what you did, name the files you changed, and point to other messages by #number. \(messaging)
      """
  }

  /// The verifier's turn: the reports by #number, then each writer's diff.
  public static func verifier(round: Int, goal: String, posts: [SwarmPost], changes: String) -> String {
    let refs = posts.map { "#\($0.seq)" }.joined(separator: ", ")
    let shown = posts.map { "#\($0.seq) (@\($0.author)): \($0.text)" }.joined(separator: "\n\n")
    return """
      You are @verifier, the read-only verifier of a swarm, round \(round). Swarm goal: \(goal)
      Check these reports against the files: \(refs)

      \(shown)\(changes)

      If every claim and change holds, start your reply with \(PeerTools.approved). Otherwise list each fix as @worker and the exact change. \(messaging)
      """
  }

  /// A worker's turn after the verifier asked for fixes in `verdict`.
  public static func revise(goal: String, name: String, slice: String, verdict: SwarmPost) -> String {
    """
    Swarm goal: \(goal)
    You are @\(name). The verifier asked for fixes in #\(verdict.seq):
    \(verdict.text)

    Fix your slice (\(slice)) and report again. \(messaging)
    """
  }

  /// A new turn for a bot because the person spoke to it from the board.
  public static func followUp(goal: String, name: String, slice: String, last: String?, words: String) -> String {
    """
    Swarm goal: \(goal)
    You are @\(name). Your slice: \(slice)
    Your last report: \(last.map { String($0.prefix(4_000)) } ?? "none yet")

    \(personSays(words))
    Do that now. Their words come before your slice. Report on the board when you are done. \(messaging)
    """
  }

  /// The person's words added to a bot's brief before its turn starts.
  public static func personSays(_ words: String) -> String {
    "The person who started this swarm says: \(words)"
  }

  /// The stable prompt of every agent another agent calls.
  public static func callee(agent: String, caller: String, mayCall: Bool) -> String {
    var text = "You are \(agent), called by another agent (\(caller)) from inside a Serein task. You see only this message. Do the work in the folder you were given, then end with the result itself: your last message goes back to the caller as your answer."
    if !mayCall { text += " You cannot call other agents." }
    return text
  }

  /// At Allow all the caller does not stop to answer: a callee marks a question so Serein can
  /// send it back to work once (`keepGoing`).
  public static let askMark = "If you need your caller to decide something before you can go on, end your message with \(RelayUnattended.inputMark) followed by the question."

  public static func keepGoing(question: String, work: String) -> String {
    "Your caller does not answer questions here. Pick the safest reasonable default, say in one line which you picked, and continue the work.\n\nYour question: \(question.prefix(1_000))\n\nThe work: \(work)"
  }

  /// The chat's line for a swarm: "Created a swarm of 12 bots", then ", 5 done" as they settle.
  public static func countLine(bots: Int, done: Int) -> String {
    let line = "Created a swarm of \(bots) \(bots == 1 ? "bot" : "bots")"
    return done > 0 ? "\(line), \(done) done" : line
  }
}
