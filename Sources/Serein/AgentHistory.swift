import AppKit
import SereinCore
import SwiftUI
import UniformTypeIdentifiers

extension BrowserModel {
  /// Serein assigns identity before a CLI starts; native session ids never carry authority.
  func beginBehaviorHistory(_ run: AgentRun) throws {
    guard behaviorHistory != nil, run.spec.provider.driver != nil,
      let id = UUID(uuidString: run.id), let mode = AgentHistoryRun.Mode(rawValue: run.spec.mode.runKey)
    else { throw SereinError.invalid("Agent history is unavailable. Open Settings › AI apps to review or clear it.") }
    do { try behaviorHistory?.checkIntegrity() }
    catch {
      behaviorHistoryIssue = "Agent history is incomplete or unreadable. Its files have been preserved."
      throw SereinError.invalid("The task was not started because agent history is unreadable.")
    }
    let context = try makeBehaviorContext(run, driver: run.spec.provider.driver, id: id, mode: mode)
    guard recordBehavior(context, .runStarted) else {
      throw SereinError.invalid("The task was not started because agent history could not be saved.")
    }
    bindBehaviorContext(context, run: run)
  }
  func makeBehaviorContext(
    _ run: AgentRun, driver: HarnessDriver? = nil, id: UUID? = nil, mode: AgentHistoryRun.Mode? = nil
  ) throws -> AgentHistoryRun {
    let spec = run.initialSpec
    let driver = driver ?? spec.provider.driver
    guard driver != nil, let id = id ?? UUID(uuidString: run.id),
      let mode = mode ?? AgentHistoryRun.Mode(rawValue: spec.mode.runKey) else {
      throw SereinError.invalid("Agent history is unavailable for this task.")
    }
    let grants = spec.grants
    return AgentHistoryRun(
      id: id, threadID: spec.threadID, projectID: spec.projectID,
      harness: driver,
      harnessVersion: HarnessRegistry.shared.snapshot(spec.provider)?.version,
      model: spec.model, mode: mode,
      permission: spec.permission,
      grants: .init(currentTab: grants.currentTab, actions: grants.actions, edits: grants.edits,
        mac: grants.mac, library: grants.library, signIns: grants.signIns),
      initiator: spec.initiator)
  }
  func bindBehaviorContext(_ context: AgentHistoryRun, run: AgentRun, active: Bool = true) {
    run.behaviorContext = context
    run.behaviorBrowser = self
    if active { behaviorContexts[run.taskID] = context }
  }
  func abandonPreparedStart(_ run: AgentRun, outcome: RunRecord.Outcome, message: String? = nil) {
    run.startTicket?.cancel()
    endTask(run.taskID)
    run.record.outcome = outcome
    run.record.endedAt = Date()
    run.error = message
    run.record.attentionDetail = run.attentionDetail
    if let detail = run.record.attentionDetail { run.record.summary = String(detail.prefix(280)) }
    run.recordBehavior(.runEnded, outcome: outcome)
    try? library.appendRun(run.record)
    ComposerContext.release(run.attachments)
    run.attachments = nil
    run.documents = []
    if let folder = run.libraryContext { RecallSandbox.remove(folder) }
    run.libraryContext = nil
    if let folder = run.runtimeDirectory { try? FileManager.default.removeItem(at: folder) }
    run.runtimeDirectory = nil
    EditReview.shared.end(run)
  }
  func reconcilePreparedStart(_ run: AgentRun, commit: AgentStartHistory.Commit) {
    // The original writer owns this transaction even if a defensive store-identity check
    // failed. A cancelled run never obtains an authenticated browser context.
    if behaviorHistory === commit.store { bindBehaviorContext(commit.context, run: run, active: false) }
    do {
      for (grant, enabled, effect) in run.pendingHistoryGrants {
        try commit.store.record(run: commit.context, kind: .grantChanged,
          grant: grant, enabled: enabled, effect: effect)
      }
      try commit.store.record(run: commit.context, kind: .capabilityRevoked)
      try commit.store.record(run: commit.context, kind: .runEnded,
        outcome: run.isActive ? .stopped : run.record.outcome)
    } catch { behaviorHistoryIssue = "Some agent activity could not be saved. The history may be incomplete." }
    run.pendingHistoryGrants.removeAll()
    run.startTicket = nil
  }
  @discardableResult func recordBehavior(
    _ context: AgentHistoryRun, _ kind: AgentHistoryEvent.Kind,
    source: AgentHistoryEvent.Source = .host, operationID: UUID? = nil,
    tool: AgentHistoryEvent.Tool? = nil, grant: AgentHistoryEvent.Grant? = nil,
    enabled: Bool? = nil, effect: AgentHistoryEvent.Effect? = nil,
    decision: AgentHistoryEvent.Decision? = nil, outcome: RunRecord.Outcome? = nil,
    sessionID: String? = nil, reportingHarness: HarnessDriver? = nil
  ) -> Bool {
    do {
      guard let history = behaviorHistory else { throw SereinError.invalid("Agent history is unavailable.") }
      try history.record(run: context, kind: kind, source: source, operationID: operationID,
                         tool: tool, grant: grant, enabled: enabled, effect: effect,
                         decision: decision, outcome: outcome, sessionID: sessionID, reportingHarness: reportingHarness)
      return true
    } catch {
      // Sticky: a later successful write does not make a missed record disappear.
      behaviorHistoryIssue = "Some agent activity could not be saved. The history may be incomplete."
      notice = behaviorHistoryIssue
      return false
    }
  }
  func clearBehaviorHistory() throws {
    guard tasks.isEmpty else { throw SereinError.invalid("Stop active tasks before clearing agent history.") }
    guard !behaviorHistoryPreparation.closed, !behaviorHistoryPreparing,
      behaviorHistoryPreparation.opening == nil, behaviorHistoryPreparation.pendingStarts == 0 else {
      throw SereinError.invalid("Wait for task preparation to finish before clearing agent history.")
    }
    if let history = behaviorHistory {
      try history.clear()
    } else {
      let folder = library.root.appendingPathComponent(AgentHistoryStore.directory)
      if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
      behaviorHistory = try AgentHistoryStore(library: library)
    }
    behaviorContexts.removeAll()
    behaviorHistoryPreparation.generation = UUID()
    behaviorHistoryIssue = nil
  }
}

extension AgentRun {
  func recordBehavior(_ kind: AgentHistoryEvent.Kind, source: AgentHistoryEvent.Source = .host,
                      operationID: UUID? = nil, tool: AgentHistoryEvent.Tool? = nil,
                      grant: AgentHistoryEvent.Grant? = nil, enabled: Bool? = nil,
                      effect: AgentHistoryEvent.Effect? = nil,
                      decision: AgentHistoryEvent.Decision? = nil, outcome: RunRecord.Outcome? = nil,
                      sessionID: String? = nil, reportingHarness: HarnessDriver? = nil) {
    guard let context = behaviorContext else {
      if startTicket != nil, kind == .grantChanged, let grant, let enabled, let effect {
        pendingHistoryGrants.append((grant, enabled, effect))
      }
      return
    }
    behaviorBrowser?.recordBehavior(context, kind, source: source, operationID: operationID,
                                    tool: tool, grant: grant, enabled: enabled, effect: effect,
                                    decision: decision, outcome: outcome, sessionID: sessionID, reportingHarness: reportingHarness)
  }
  func reportBehaviorTool(_ activity: RunActivity, id: String?) {
    guard !activity.browser else { return }
    if let id, behaviorOperations[id] != nil { return }
    let operation = UUID()
    if let id { behaviorOperations[id] = operation }
    recordBehavior(.toolReported, source: .harness, operationID: operation,
                   tool: .activity(activity.tool))
  }
  func reportBehaviorSession(_ id: String) {
    guard behaviorSession != id else { return }
    behaviorSession = id
    recordBehavior(.sessionLinked, source: .harness, sessionID: id)
  }
  func reportBehaviorApprovals(_ approvals: [PendingApproval]) {
    for approval in approvals where behaviorApprovals.insert(approval.id).inserted {
      recordBehavior(.approvalRequested, source: .harness, operationID: UUID(), tool: .fileEdit)
    }
  }
  func reportBehaviorAssistantTools(_ event: [String: Any]) {
    guard event["type"] as? String == "assistant" else { return }
    let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    for use in content where use["type"] as? String == "tool_use" {
      guard let name = use["name"] as? String,
        let activity = RunNow.claudeTool(name, input: use["input"] as? [String: Any] ?? [:], folder: folder?.path)
      else { continue }
      reportBehaviorTool(activity, id: use["id"] as? String)
    }
  }
}

struct AgentHistorySettings: View {
  @ObservedObject var browser: BrowserModel
  @State private var open = false
  @Environment(\.palette) var p
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Agent history").font(UIStyle.font(14, weight: .semibold)).foregroundStyle(p.ink)
        .accessibilityHeading(.h2)
      Text("Serein keeps task, action and permission metadata on this Mac. View it across launches or export a copy for another installation.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      if let issue = browser.behaviorHistoryIssue {
        Text(issue).font(UIStyle.meta).foregroundStyle(p.danger).fixedSize(horizontal: false, vertical: true)
      }
      Button { open = true } label: { Text("Open agent history…") }
        .buttonStyle(QuietButton())
        .accessibilityLabel("Open agent history")
        .help("View, export, import or clear recorded agent activity")
    }.accessibilityElement(children: .contain)
      .sheet(isPresented: $open) { AgentHistoryView(browser: browser) }
  }
}

/// A read-only snapshot. Imported archives are visibly separate from locally observed history.
struct AgentHistoryView: View {
  @ObservedObject var browser: BrowserModel
  @Environment(\.palette) var p
  @Environment(\.dismiss) var dismiss
  @State private var local: AgentHistoryArchive?
  @State private var imports: [AgentHistoryArchive] = []
  @State private var selected = 0
  @State private var selectedRun = ""
  @State private var status: String?
  @State private var busy = false
  @State private var confirmClear = false
  var archive: AgentHistoryArchive? {
    selected == 0 ? local : (imports.indices.contains(selected - 1) ? imports[selected - 1] : nil)
  }
  var events: [AgentHistoryEvent] {
    (archive?.events ?? []).filter { selectedRun.isEmpty || $0.run.id.uuidString == selectedRun }
  }
  var runIDs: [String] { Array(Set(archive?.events.map { $0.run.id.uuidString } ?? [])).sorted() }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Button { dismiss() } label: { Label("Back to Settings", systemImage: "chevron.left") }
          .buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
          .help("Return to Agent settings")
        Text("Agent history").font(UIStyle.font(20, weight: .semibold)).accessibilityHeading(.h1)
        Spacer()
      }
      Text("Only metadata is kept: no prompts, typed text, page contents, cookies, file paths or credentials. These archives are unsigned. A returned tool call does not confirm its effect on a website.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      SettingsPopUp("History source", selection: $selected, choices: [SettingsChoice(value: 0, label: "This installation")]
        + imports.indices.map { index in
          SettingsChoice(value: index + 1, label: "Imported · \(imports[index].issuerID.uuidString.prefix(8)) · \(imports[index].exportedAt.formatted(date: .abbreviated, time: .shortened))")
        }, menuWidth: 320)
      SettingsPopUp("Task", selection: $selectedRun, choices: [SettingsChoice(value: "", label: "All recorded tasks")]
        + runIDs.map { SettingsChoice(value: $0, label: "Run " + String($0.prefix(8))) })
        .onChange(of: selected) { _, _ in selectedRun = "" }
      if selected != 0 {
        Text("Imported evidence is untrusted. It never resumes a task or restores permissions.")
          .font(UIStyle.meta).foregroundStyle(p.warning)
      }
      if let issue = browser.behaviorHistoryIssue {
        Text(issue).font(UIStyle.meta).foregroundStyle(p.danger)
      }
      if let status { Text(status).font(UIStyle.meta).foregroundStyle(p.secondary) }
      HStack(spacing: 12) {
        Button("Refresh") { refresh() }.buttonStyle(QuietButton())
        Button("Export…") { exportHistory() }.buttonStyle(QuietButton()).disabled(archive == nil)
        Button("Import…") { importHistory() }.buttonStyle(QuietButton())
        Spacer()
        Button("Clear history…") { confirmClear = true }.buttonStyle(QuietButton())
          .disabled(!browser.tasks.isEmpty)
      }.disabled(busy)
      Divider().overlay(p.line)
      if let archive {
        Text("\(events.count) event\(events.count == 1 ? "" : "s") · snapshot \(archive.exportedAt.formatted(date: .abbreviated, time: .shortened))")
          .font(UIStyle.meta).foregroundStyle(p.faint)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(events.reversed()) { event in
              VStack(alignment: .leading, spacing: 3) {
                HStack {
                  Text((event.reportingHarness?.displayName ?? event.run.harness.displayName)).font(UIStyle.font(12, weight: .medium))
                  Text(event.kind.label).font(UIStyle.meta).foregroundStyle(p.secondary)
                  Spacer()
                  Text(event.time.formatted(date: .abbreviated, time: .standard)).font(UIStyle.micro).foregroundStyle(p.faint)
                }
                Text(detail(event)).font(UIStyle.micro).foregroundStyle(p.faint).textSelection(.enabled)
              }.accessibilityElement(children: .combine)
              Divider().overlay(p.line)
            }
          }
        }
        if events.isEmpty { Text("No agent activity recorded yet.").role(.meta) }
      } else if busy {
        ProgressView().controlSize(.small)
      }
      Spacer(minLength: 0)
    }.padding(24).frame(minWidth: 680, minHeight: 480).frame(width: 760, height: 580)
      .foregroundStyle(p.ink).background(p.panel)
      .onAppear { refresh() }
      .onChange(of: browser.behaviorHistoryPreparing) { _, preparing in if !preparing { refresh() } }
      .alert("Clear agent history?", isPresented: $confirmClear) {
        Button("Cancel", role: .cancel) {}
        Button("Clear", role: .destructive) {
          do { try browser.clearBehaviorHistory(); selected = 0; selectedRun = ""; refresh() }
          catch { status = error.localizedDescription }
        }
      } message: {
        Text("This removes local event records and imported copies. Conversations and existing exports remain. Stop active tasks first.")
      }
  }
  func detail(_ event: AgentHistoryEvent) -> String {
    var parts = ["Run " + String(event.run.id.uuidString.prefix(8)), event.source.rawValue]
    if let tool = event.tool { parts.append(tool.rawValue) }
    if let grant = event.grant {
      parts.append(grant.rawValue + (event.enabled == true ? " on" : " off"))
      if let effect = event.effect { parts.append(effect == .nextTurn ? "next turn" : "current run") }
    }
    if let decision = event.decision { parts.append(decision.rawValue) }
    if let outcome = event.outcome { parts.append(outcome.rawValue) }
    if event.kind == .runStarted {
      parts.append("actor " + String(event.issuerID.uuidString.prefix(8)))
      if let version = event.run.harnessVersion { parts.append("CLI " + version) }
      if let initiator = event.run.initiator { parts.append("started by " + initiator.label) }
      parts.append(event.run.permission.label)
      parts.append(event.run.modelFingerprint == nil ? "default model" : "selected model fingerprinted")
    }
    return parts.joined(separator: " · ")
  }
  func refresh() {
    if browser.behaviorHistoryPreparing {
      status = "Opening agent history…"
      return
    }
    guard let store = browser.behaviorHistory else {
      status = "Agent history could not be opened. Clear it to start a new history."
      return
    }
    busy = true
    Task {
      let result = await Task.detached { (Result { try store.archive() }, Result { try store.importedArchives() }) }.value
      busy = false
      status = nil
      switch result.0 {
      case .success(let archive): local = archive
      case .failure: local = nil; status = "Local agent history is incomplete or unreadable. Its files have been preserved."
      }
      switch result.1 {
      case .success(let archives): imports = archives
      case .failure: imports = []; status = "An imported archive is unreadable. Its files have been preserved."
      }
      if selected > imports.count { selected = 0 }
      if !runIDs.contains(selectedRun) { selectedRun = "" }
    }
  }
  func exportHistory() {
    guard let archive else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "serein-agent-history.json"
    panel.message = "Export this metadata snapshot. It contains installation and run identifiers; review before sharing."
    guard panel.runModal() == .OK, let file = panel.url else { return }
    do {
      let snapshot = try AgentHistoryArchive(issuerID: archive.issuerID, events: events, exportedAt: archive.exportedAt)
      try AgentHistoryStore.export(snapshot, to: file)
      status = "Agent history exported."
    } catch { status = "Agent history could not be exported. Archives are limited to 64 MB; select one task for a smaller export." }
  }
  func importHistory() {
    guard let store = browser.behaviorHistory else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
    panel.message = "Open a Serein agent history archive as a separate, read-only copy."
    guard panel.runModal() == .OK, let file = panel.url else { return }
    busy = true
    Task {
      let result = await Task.detached { Result { try store.importArchive(from: file) } }.value
      busy = false
      switch result {
      case .success: selected = 0; refresh()
      case .failure: status = "This file is not a supported, intact Serein agent history archive."
      }
    }
  }
}

extension AgentHistoryEvent.Kind {
  var label: String {
    switch self {
    case .runStarted: return "Started a task"
    case .toolRequested: return "Requested a tool"
    case .toolReturned: return "Tool returned"
    case .toolFailed: return "Tool failed or was refused"
    case .toolReported: return "Harness reported a tool"
    case .toolFailureReported: return "Harness reported a failure"
    case .grantChanged: return "Changed a grant"
    case .permissionAnswered: return "Answered a permission request"
    case .approvalRequested: return "Harness reported an edit approval"
    case .approvalResolved: return "Resolved an edit approval"
    case .capabilityRevoked: return "Revoked browser access"
    case .runEnded: return "Ended a task"
    case .sessionLinked: return "Linked a native session"
    case .outcomeReported: return "Agent reported an outcome"
    case .outcomeClassified: return "Classifier reported an outcome"
    case .interrupted: return "Found an interrupted task"
    case .keptSignInUsed: return "Used a kept sign-in"
    }
  }
}
