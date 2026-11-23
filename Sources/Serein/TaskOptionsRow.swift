import SereinCore
import SwiftUI

/// The line under a task's composer, always showing, as in the AI apps' own windows. A new task
/// shows where it runs first, fixed to this Mac and its project's folder, and an Own copy box when
/// the folder is a git checkout. Every task shows its model and effort (the model dropdown), what
/// it asks before (permission menu, with Record this task) and how full its context is.
struct TaskOptionsRow: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  /// The composer's ComposerDropdown owner, so the model dropdown anchors to this composer.
  var owner: String
  /// Over a sub-thread: the parent's settings, shown and not changed there.
  var readOnly = false
  @ObservedObject private var recordings = TaskRecordings.shared
  @ObservedObject private var tray = SereinTray.shared
  @Environment(\.palette) private var p

  private var project: Project? { browser.projects.first { $0.id == agent.projectID } }
  /// Before its first message: where it runs can still be set up.
  private var isNew: Bool { agent.messages.isEmpty && !agent.running && agent.link == nil && !readOnly }

  var body: some View {
    HStack(spacing: 14) {
      if isNew {
        place("laptopcomputer", "This computer", help: "Runs on this Mac")
        if agent.mode == .project, let project {
          place("folder", project.name, help: project.path)
          if TaskWorktree.isRepository(project.path) {
            Toggle("Own copy", isOn: $agent.useWorktree).toggleStyle(.checkbox)
              .help("Works in its own copy of the folder. Your files stay as they are.")
          }
        }
      } else if let worktree = agent.worktree {
        place("arrow.triangle.branch", URL(fileURLWithPath: worktree).lastPathComponent, help: worktree)
      }
      Spacer(minLength: 8)
      if readOnly {
        modelLabel
        if agent.mode == .project {
          Text(access.title).foregroundStyle(access == .full ? p.warning : p.ink).lineLimit(1)
        }
      } else {
        DropdownPill(kind: .modelAndTraits, owner: owner, help: "Model and reasoning") { modelLabel }
          .accessibilityLabel("Model and reasoning")
          .accessibilityValue([modelName, EffortLadder.shown(agent)].compactMap { $0 }.joined(separator: ", "))
        if agent.mode == .project { permissionMenu }
      }
      if let meter = tray.record(agent.conversationID)?.context { ContextRing(meter: meter) }
    }
    .font(UIStyle.meta).foregroundStyle(p.secondary)
    .padding(.horizontal, 12).frame(height: 28)
  }

  private var modelLabel: some View {
    HStack(spacing: 6) {
      Text(modelName).foregroundStyle(p.ink).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180)
      if let effort = EffortLadder.shown(agent) { Text(effort).foregroundStyle(p.secondary).lineLimit(1) }
    }
  }

  /// A fixed fact about where the task runs: it shows, it does not change.
  private func place(_ icon: String, _ title: String, help: String) -> some View {
    HStack(spacing: 5) {
      InterfaceIcon(systemName: icon, size: 12)
      Text(Self.short(title)).foregroundStyle(p.ink).lineLimit(1).fixedSize()
    }.help(help).accessibilityElement(children: .combine)
  }

  private var access: ProjectAccess { ProjectAccess(edits: agent.allowProjectEdits, permission: agent.permission) }

  private var permissionMenu: some View {
    Menu {
      Picker(Self.askBefore, selection: Binding(get: { access }, set: choose)) {
        ForEach(ProjectAccess.allCases) { Text($0.title).tag($0) }
      }.pickerStyle(.inline)
      Divider()
      Toggle("Record this task", isOn: Binding(get: { recordings.threads.contains(agent.conversationID) },
                                               set: { recordings.set($0, thread: agent.conversationID) }))
    } label: {
      Text(access.title).foregroundStyle(access == .full ? p.warning : p.ink).lineLimit(1)
    }.composerMenu().fixedSize().disabled(agent.running)
      .help(access.permission.detail).accessibilityLabel(Self.askBefore).accessibilityValue(access.title)
  }

  /// Full access asks once per project, as the project chip does.
  private func choose(_ level: ProjectAccess) {
    if level == .full {
      guard FullAccessConsent.request(projectID: agent.projectID, projectName: project?.name) else { return }
    }
    agent.allowProjectEdits = level.edits
    AgentModel.remember(.edits, level.edits)
    agent.permission = level.permission
  }

  /// A long name keeps its start and end, so the line keeps its spacing.
  static func short(_ name: String, limit: Int = 28) -> String {
    guard name.count > limit else { return name }
    return String(name.prefix(limit / 2 - 1)) + "…" + String(name.suffix(limit / 2 - 1))
  }

  /// The task's permission reads as one more “asks before”, in `ProjectAccess`'s own words.
  static let askBefore = "This task asks before"

  private var modelName: String {
    let id = ClaudeModelID.split(agent.model)
    if let choice = HarnessRegistry.shared.models(agent.provider).first(where: { $0.id == id.base }), !choice.name.isEmpty {
      return choice.name + (id.longContext ? " 1M" : "")
    }
    if agent.model.isEmpty, let listed = HarnessRegistry.shared.chosen(agent.provider, agent.model) { return listed.name }
    return agent.model.isEmpty ? agent.provider.name : agent.model
  }
}

/// How full the task's context is, as a small ring; its label says the share.
struct ContextRing: View {
  let meter: ContextMeter
  @Environment(\.palette) private var p
  var body: some View {
    ZStack {
      Circle().stroke(p.line, lineWidth: 2)
      Circle().trim(from: 0, to: CGFloat(meter.percent) / 100)
        .stroke(meter.warns ? p.warning : p.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }.frame(width: 13, height: 13).help(meter.label)
      .accessibilityElement().accessibilityLabel("Context").accessibilityValue(meter.label)
  }
}
