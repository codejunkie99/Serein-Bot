import AppKit
import SereinCore

extension BrowserModel {
  func macScript(_ source: String, taskID: String, operationID: UUID? = nil) async throws -> [String: Any] {
    try MacScriptPolicy.validate(source)
    guard tasks[taskID]?.allowMac == true else {
      throw SereinError.invalid("Mac automation is off for this task")
    }
    let context = behaviorContexts[taskID]
    // Relay's runs: Autopilot runs scripts that only read or create; the rest asks in its panel.
    if let relay = relayTask(taskID, tasks[taskID]) {
      let door = { (standing: ApprovalDoor.Standing) in
        ApprovalDoor.answer(
          .init(.script(source), standing, taskID: taskID),
          facts: .init(
            secureField: false, botCheck: false, pays: .no, covered: false, path: nil, hostKeyChanged: nil,
            runsAnything: false, ref: ""))
      }
      var decision = try door(relay.standing).decision()
      // The one-time consent card comes only before a routine step, and its answer may be
      // Ask before every step: judge the step again after it.
      if decision == .auto {
        guard await relay.settleConsent(thread: threadID(forTask: taskID)) else { throw SereinError.invalid(RelayOrchestrator.stoppedStep) }
        decision = try door(relay.standing).decision()
      }
      let routineScript: Bool = !relay.autopilot && door(relay.standing.atRiskyOnly).runs
      let card = ApprovalCopy.script(source)
      let app = ApprovalCopy.scriptApp(source) ?? "a Mac app"
      let scriptEffect = ApprovalGate.scriptEffect(source: source)
      let scriptStamp = macProcessStamp(app)
      let scriptIntent = ApprovalGate.record(
        ApprovalGate.GateAction(kind: "script", text: source, elementID: app, pageVersion: scriptStamp),
        effect: scriptEffect, mint: { UUID().uuidString })
      let slot = ScriptSlot.taskField()
      let checked = await MacScriptRun.perform(source: source, slot: slot) {
        if var task = tasks[taskID] {
          task.scriptToRun = slot.string
          tasks[taskID] = task
        }
        let human: ApprovalGate.HumanAnswer
        if decision == .auto {
          human = .yes
        } else {
          human = await relay.confirmAnswer(
            card.title, card.detail, button: "Allow", thread: threadID(forTask: taskID),
            more: String(source.prefix(1500)), app: card.app,
            routine: routineScript)
        }
        // The field may have been replaced while the card was up. A read-only slot would refuse this.
        _ = slot.rewrite(tasks[taskID]?.scriptToRun ?? "")
        return human
      }
      if var task = tasks[taskID] {
        task.scriptToRun = nil
        tasks[taskID] = task
      }
      let human = checked.answer
      let allowed = human == .yes
      if let context, !recordBehavior(context, .permissionAnswered, operationID: operationID, tool: .macScript,
                                      decision: decision == .auto ? .allowedByAutopilot : allowed ? .allowedOnce : .denied) {
        throw SereinError.invalid("The Mac script was not run because its approval could not be recorded.")
      }
      relay.note("Ran a \(app) script", decision == .auto ? .auto : allowed ? .allowed : .declined)
      guard allowed else {
        throw SereinError.invalid(ActionAdmission.blocked(answer: human, decision: decision, effectChanged: false))
      }
      let arguments = try MacScriptRun.requireUnchanged(checked)
      let liveStamp = macProcessStamp(app)
      let liveEffect = ApprovalGate.scriptEffect(source: checked.live)
      guard ApprovalGate.beforeInput(
        intent: scriptIntent, answer: human, liveElement: app, liveVersion: liveStamp, liveEffect: liveEffect)
      else {
        throw SereinError.invalid(ActionAdmission.blocked(
          answer: human, decision: decision, effectChanged: liveEffect != scriptEffect))
      }
      // What the run shows about Automation is what the next card for this app says while it
      // is closed (macOS cannot be asked then).
      do {
        let result = try await runScript(arguments, taskID: taskID)
        GuideCenter.shared.record(.macStepStarted)
        relay.learnAutomation(app: card.app, .allowed)
        return result
      } catch {
        let text = "\(error)"
        if text.contains("-1743") || text.localizedCaseInsensitiveContains("not authorized to send apple events") {
          relay.learnAutomation(app: card.app, .denied)
          throw SereinError.invalid(
            "macOS is not letting Serein control \(card.app ?? app). The user can turn it on in System Settings › Privacy & Security › Automation.")
        }
        // A script that did not compile ran nothing. Any other error can come after a change.
        if !text.contains("syntax error") { StepJournal.live?.cannotTell() }
        throw error
      }
    }
    let app = ApprovalCopy.scriptApp(source) ?? "a Mac app"
    let scriptEffect = ApprovalGate.scriptEffect(source: source)
    let scriptStamp = macProcessStamp(app)
    let scriptIntent = ApprovalGate.record(
      ApprovalGate.GateAction(kind: "script", text: source, elementID: app, pageVersion: scriptStamp),
      effect: scriptEffect, mint: { UUID().uuidString })
    let alert = NSAlert()
    alert.messageText = "Allow this Mac app action?"
    alert.informativeText =
      "Review the exact script requested by your agent. It may read or change Calendar, Reminders, Notes or Finder."
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 220))
    let text = NSTextView(frame: scroll.bounds)
    let slot = ScriptSlot.alertFallback()
    // The fallback shows the hashed source and does not accept edits. The hash is of this string.
    text.isEditable = slot.isEditable
    text.isSelectable = true
    text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    scroll.documentView = text
    scroll.hasVerticalScroller = true
    alert.accessoryView = scroll
    let checked = await MacScriptRun.perform(source: source, slot: slot) {
      text.string = slot.string
      let human = await MacApproval.ask(alert, button: "Run once")
      slot.observe(text.string)
      return human
    }
    let human = checked.answer
    let allowed = human == .yes
    if let context, !recordBehavior(context, .permissionAnswered, operationID: operationID, tool: .macScript,
                                    decision: allowed ? .allowedOnce : .denied) {
      throw SereinError.invalid("The Mac script was not run because its approval could not be recorded.")
    }
    guard human == .yes else {
      throw SereinError.invalid(human == .no ? "User declined Mac app action" : ActionAdmission.needsPerson)
    }
    let arguments = try MacScriptRun.requireUnchanged(checked)
    let liveStamp = macProcessStamp(app)
    let liveEffect = ApprovalGate.scriptEffect(source: checked.live)
    guard ApprovalGate.beforeInput(
      intent: scriptIntent, answer: human, liveElement: app, liveVersion: liveStamp, liveEffect: liveEffect)
    else {
      throw SereinError.invalid(liveEffect == scriptEffect ? ActionAdmission.pageChanged : ActionAdmission.effectChanged)
    }
    return try await runScript(arguments, taskID: taskID)
  }
  /// The app named in the script, as it is running now. Called again immediately before the script runs.
  private func macProcessStamp(_ name: String) -> String {
    let wanted = name.lowercased()
    let running = NSWorkspace.shared.runningApplications.first {
      ($0.localizedName ?? "").lowercased() == wanted
    }
    return ApprovalGate.processStamp(bundleID: running?.bundleIdentifier ?? "", pid: running?.processIdentifier ?? -1)
  }
  private func runScript(_ arguments: [String], taskID: String) async throws -> [String: Any] {
    let output = try await rawScript(arguments, taskID: taskID)
    return [
      "result": AgentPrivacy.redact(output, limit: 24_000),
      "verification": "Read back the affected item before reporting completion.",
    ]
  }
  /// osascript with these arguments, its output unredacted: an approved Mac script's output is
  /// redacted whole (`runScript`); the Notes connection's fixed scripts (NativeConnectionTools)
  /// split their answer into fields first and redact each, so a redaction cannot swallow a
  /// separator. Errors are redacted here. Only while the task may still use Mac apps.
  func rawScript(_ arguments: [String], taskID: String) async throws -> String {
    guard tasks[taskID]?.allowMac == true else {
      throw SereinError.invalid("The task ended while awaiting approval")
    }
    return try await Self.osascript(arguments)
  }
  /// The one osascript runner, for approved Mac scripts, the fixed Mail and Messages scripts
  /// (Connections) and the Notes connection's (NativeConnectionTools). The output comes back as
  /// written, for the caller to parse and redact; an error is redacted here.
  nonisolated static func osascript(_ arguments: [String], timeout: TimeInterval = 15) async throws -> String {
    try await Task.detached { () -> String in
      let process = Process()
      let out = Pipe()
      let err = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
      process.arguments = arguments
      process.standardOutput = out
      process.standardError = err
      try process.run()
      let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
      defer { timer.cancel() }
      // AppleScript output is bounded by the small approved operation or the fixed script's caps.
      let output = out.fileHandleForReading.readDataToEndOfFile()
      let errors = err.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw SereinError.invalid(AgentPrivacy.redact(String(decoding: errors, as: UTF8.self), limit: 3000))
      }
      return String(decoding: output, as: UTF8.self)
    }.value
  }
}

/// The one way a Mac step asks the user: a sheet on the key window when it is a real window,
/// or a modal otherwise; true when the first button was chosen. Never a sheet on the ⌥Space bar
/// or another panel: a panel can hide when the sheet takes the keyboard, taking the sheet with
/// it, and the step would wait for an answer nobody can give.
@MainActor enum MacApproval {
  /// The alerts on screen now (and the window each is a sheet on), so Stop everything can
  /// decline them and the ⌥Space bar stays up while one is open.
  /// `thread` is the asking run's thread, when known, so stopping one reply declines only its own.
  private static var open: [(alert: NSAlert, window: NSWindow?, thread: String?)] = []
  static var isOpen: Bool { !open.isEmpty }

  static func ask(_ alert: NSAlert, button: String, decline: String = "Cancel", thread: String? = nil) async -> ApprovalGate.HumanAnswer {
    // Inside a socket call the alert closes before the caller stops waiting (SocketCall).
    let call = SocketCall.live
    let life: TimeInterval
    if let call {
      guard let left = call.life(RelayAsk.timeout) else { return .timeout }
      life = left
    } else {
      life = RelayAsk.timeout
    }
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: decline)
    final class Once { var done = false }
    let once = Once()
    let response: NSApplication.ModalResponse = await withCheckedContinuation { c in
      let finish: (NSApplication.ModalResponse) -> Void = { code in
        guard !once.done else { return }
        once.done = true
        c.resume(returning: code)
      }
      let timeout = DispatchWorkItem {
        guard !once.done else { return }
        let code = NSApplication.ModalResponse(rawValue: AlertVerdict.timeoutCode)
        if let parent = alert.window.sheetParent {
          parent.endSheet(alert.window, returnCode: code)
        } else if NSApp.modalWindow === alert.window {
          NSApp.stopModal(withCode: code)
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + life, execute: timeout)
      if let window = NSApp.keyWindow, !(window is NSPanel), window.isVisible, !window.isMiniaturized {
        open.append((alert, window, thread))
        alert.beginSheetModal(for: window) { code in
          timeout.cancel()
          finish(code)
        }
      } else {
        open.append((alert, nil, thread))
        let code = alert.runModal()
        timeout.cancel()
        finish(code)
      }
    }
    open.removeAll { $0.alert === alert }
    let human = AlertVerdict.human(response.rawValue)
    guard let call else { return human }
    if human == .timeout { call.closedUnanswered() }
    return call.settle(human)
  }
  /// Stop everything (`thread` nil): every open alert answers with its second button (Decline or
  /// Cancel). Stop on one reply (`thread`): only the alerts that thread's run asked.
  static func declineAll(thread: String? = nil) {
    for (alert, window, owner) in open.reversed() where thread == nil || owner == thread {
      if let window {
        window.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
      } else if NSApp.modalWindow === alert.window {
        NSApp.stopModal(withCode: .alertSecondButtonReturn)
      }
    }
  }
}
