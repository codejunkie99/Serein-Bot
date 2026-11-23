import Foundation
import SereinCore
import SereinEngines

/// Execution on this computer (`mac_run`, LocalExecution): a shell command on the person's own
/// Mac. The person's choice decides whether it asks; the card shows the command whole; it runs as
/// them in their home folder, inside the sandbox that closes their secrets and Serein's data
/// (`AgentFileGuard.shellProfile`), its HTTPS through the task thread's pay guard
/// (`ShellNetwork`), off the main thread; its output is fenced as untrusted.
extension BrowserModel {
  /// Bytes a command may have: enough for any real command, short enough for the card.
  static let macRunCommandLimit = 8_000

  func macRun(_ arguments: [String: Any], id: String, task: BrowserTask) async throws -> [String: Any] {
    guard let raw = arguments["command"] as? String else { throw SereinError.invalid("command is required.") }
    let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty, command.utf8.count <= Self.macRunCommandLimit, !command.contains("\0") else {
      throw SereinError.invalid("command is required, at most \(Self.macRunCommandLimit) bytes, with no NUL.")
    }
    let mode = LocalExecution.mode()
    let standing = RelayOrchestrator.standing(relayTask(id, task), present: !isUnattended(task: id))
    // The person's own switch: Never is off, as a connection turned off is; Ask shows the card
    // at every level, as a site set to Ask every step does.
    if mode == .never { throw SereinError.invalid(LocalExecution.offRefusal) }
    let decision = try ApprovalDoor.answer(
      .init(.command(command, mode: mode), standing, taskID: id),
      facts: .init(
        secureField: false, botCheck: false, pays: .no, covered: false, path: nil, hostKeyChanged: nil,
        runsAnything: false, ref: "")
    ).decision()
    if decision == .ask || mode == .ask { try await askToRun(command, id: id, task: task) }
    // Whatever the Mac holds can come back in the output: the chat is marked before it runs.
    guard notePersonalRead(task: id) else { throw SereinError.invalid(Self.personalMarkWithheld) }
    let result = try await macShell(command, task: id)
    let redacted: String = AgentPrivacy.redact(result.output)
    let output: String = PageFence.fence(UntrustedText.escape(UntrustedText.capped(redacted)))
    let code: Int = Int(result.code)
    return ["output": output, "code": code, "cut": result.cut || !UntrustedText.fits(redacted), "untrusted": true]
  }

  /// The command under the file guard with the proxy environment, its payment calls asking the
  /// task's cards. A task with no chat thread gets a guard of its own, closed when the task ends.
  func macShell(_ command: String, task id: String) async throws -> ShellRunner.Result {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let port = try await Engines.shared.shellPort(thread: threadID(forTask: id).map(ThreadKey.init), task: id, command: command)
    let profile = AgentFileGuard.shellProfile(home: home, library: AgentAccess.defaultRoot)
    return try await Task.detached(priority: .userInitiated) {
      try ShellRunner.run(
        command, home: home.path, timeout: LocalExecution.timeout, sandbox: profile, environment: ShellNetwork.environment(port: port))
    }.value
  }

  /// The card: the command whole in its open box, Run or Decline.
  private func askToRun(_ command: String, id: String, task: BrowserTask) async throws {
    guard let asker = relayTask(id, task) ?? RelayOrchestrator.shared else {
      throw SereinError.invalid(ActionAdmission.needsPerson)
    }
    let card = LocalExecution.card(command)
    let answer = await asker.confirmAnswer(
      card.title, card.detail, button: "Run", thread: threadID(forTask: id), more: command, moreName: "the command",
      moreOpen: true, effect: .change)
    guard answer == .yes else {
      throw SereinError.invalid(answer == .no ? LocalExecution.declined : ActionAdmission.needsPerson)
    }
    guard tasks[id]?.finished == false else { throw SereinError.invalid("The task ended while awaiting approval") }
  }
}
