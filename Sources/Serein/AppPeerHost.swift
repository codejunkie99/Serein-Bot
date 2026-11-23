import Foundation
import SereinCore
import SereinEngines

/// The app's side of the team tools (Peers): the callee's binary and model, and a browser task of
/// its own made like its caller's.
struct AppPeerHost: PeerHost {
  let browser: BrowserModel
  let engines: Engines

  func request(for callee: PeerCallee) async throws -> TurnRequest {
    try await MainActor.run {
      let provider = Provider(callee.cli)
      guard let executable = HarnessRegistry.shared.executable(provider) else {
        throw SereinError.invalid("\(provider.name) is not installed or is turned off.")
      }
      if HarnessRegistry.shared.snapshot(provider)?.signedIn == false {
        throw SereinError.invalid(ConnectNeed.signedOut(provider))
      }
      let access = try Self.access(provider, within: callee.access, projects: browser.projects)
      guard let helper = AgentModel.browserHelper else {
        throw SereinError.invalid("Browser helper missing. Run scripts/build.sh to package both executables.")
      }
      // shortcut: a secure card the callee opens shows under its own task, not its caller's, until
      // the card list reads `BrowserTask.caller`.
      let caller = browser.tasks[callee.callerTask]
      let task = try browser.beginTask(
        isolated: caller?.isolated ?? true, allowActions: caller?.allowActions ?? false, includeCurrent: false,
        allowMac: caller?.allowMac ?? false)
      // M7: the callee stands at its caller task's standing and level, never the global one.
      browser.tasks[task.capability.task]?.caller = callee.callerTask
      let level: ApprovalLevel = browser.taskStandsProactive(task.capability.task) ? .proactive : RelayOrchestrator.shared?.level ?? .everyStep
      var arguments = [task.file.path]
      if task.isolated { arguments.append("--isolated") }
      if task.allowActions { arguments.append("--click-point") }
      // Every task is served the settings tools (R31).
      arguments.append("--settings")
      if callee.mayCall { arguments.append(PeerTools.flag) }
      let addition = engines.promptAddition(for: callee.cli, allowsAll: browser.allowsAll(task: task.capability.task))
      let tools = ToolSchema.offered(arguments).compactMap { $0["name"] as? String }
      var request = TurnRequest(
        thread: callee.thread, cli: callee.cli, executable: URL(fileURLWithPath: executable), access: access,
        prompt: TurnPrompt(
          stable: [TaskPrompt.core(served: Set(tools)), addition, callee.prompt.stable].filter { !$0.isEmpty }.joined(separator: "\n\n"),
          volatile: callee.prompt.volatile, message: callee.prompt.message, recovery: nil),
        model: HarnessRegistry.shared.chosen(provider, "")?.id, effort: nil, resume: nil,
        browser: BrowserServer(
          command: URL(fileURLWithPath: helper), arguments: arguments,
          tools: tools),
        taskID: task.capability.task, level: level)
      try HarnessRegistry.shared.prepare(&request, ownSetup: false)
      return request
    }
  }

  func keepsGoing(task: String) async -> Bool {
    await MainActor.run {
      let today = RelayOrchestrator.standing(browser.relayTask(task, browser.tasks[task]), present: !browser.isUnattended(task: task))
      let standing = browser.standing(task: task, else: today)
      return standing.level == .proactive && standing.levelStands
    }
  }

  func holdsCard(task: String) async -> Bool {
    await MainActor.run { browser.secureCards.holdsCard(task: task) || browser.secureCards.openHost(task: task) != nil }
  }

  /// What the hub gives a project turn of `provider` in the caller's folder, at most the caller's
  /// level: the same refusals, and Full only in a project the person confirmed it for.
  @MainActor static func access(_ provider: Provider, within ceiling: Access, projects: [Project]) throws -> Access {
    let folder: URL
    var level: ProjectLevel
    switch ceiling {
    case .task(let path): (folder, level) = (path, .full)
    case .project(let path, let at): (folder, level) = (path, at)
    case .answer, .web, .library, .ownSetup: throw SereinError.invalid("Other agents can be called only from a project task.")
    }
    let project = projects.first { URL(fileURLWithPath: $0.path).standardizedFileURL == folder.standardizedFileURL }
    if level == .full && !FullAccessConsent.confirmed(project?.id) { level = .commands }
    let permission: RunPermissionMode =
      switch level {
      case .full: .fullAccess
      case .commands: .auto
      case .edits: .autoAcceptEdits
      case .review: .supervised
      }
    let grant = HarnessGrant(mode: TaskMode.project.runKey, edits: level != .review, permission: permission)
    if case .refused(let reason) = HarnessRegistry.shared.verdict(provider, mode: grant.mode, edits: grant.edits, permission: permission) {
      throw SereinError.invalid(reason)
    }
    return AgentModel.engineAccess(mode: .project, grant: grant, initiator: nil, folder: folder)
  }

  func release(task: String) async {
    await MainActor.run { browser.endTask(task) }
  }
}
