import SereinCore
import SwiftUI

/// The middle of a new task, before its first message: the folders it can work in, the chosen
/// one checked, as the AI apps' own windows open a new session. A click picks one; Choose another
/// folder opens the full list. The box stays at the bottom (TaskComposer), with its line.
struct NewTaskFolders: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @State private var hovered: String?
  @Environment(\.palette) private var p
  /// The most folders listed here; the rest are one click away.
  static let shown = 6

  /// A new task waits for its first message here.
  static func applies(_ agent: AgentModel, panel: Bool) -> Bool {
    !panel && agent.messages.isEmpty && !agent.running && agent.link == nil && agent.mode == .project
  }

  var body: some View {
    let projects = Array(browser.listedProjects.prefix(Self.shown))
    VStack(spacing: 0) {
      ForEach(projects) { project in
        row(icon: "folder", title: project.name, help: project.path, checked: project.id == agent.projectID) {
          if agent.projectID != project.id { agent.selectProject(project.id) }
          ComposerContext.shared.focusComposer += 1
        }
      }
      if !projects.isEmpty { Rectangle().fill(p.line).frame(height: 1).padding(.vertical, 4).accessibilityHidden(true) }
      row(icon: "plus", title: "Choose another folder…", help: "All your projects, or add a folder", checked: false) {
        DestinationPicker.show(browser: browser, agent: agent)
      }
    }
    .padding(6).frame(width: 340)
    .background(p.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(p.line, lineWidth: 1))
    .accessibilityElement(children: .contain).accessibilityLabel("Where this task works")
  }

  private func row(icon: String, title: String, help: String, checked: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 10) {
        InterfaceIcon(systemName: icon, size: 13).foregroundStyle(p.secondary).frame(width: 16)
        Text(title).font(UIStyle.body).foregroundStyle(p.ink).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 8)
        if checked { InterfaceIcon(systemName: "checkmark", size: 12).foregroundStyle(p.ink) }
      }
      .padding(.horizontal, 10).frame(height: 34)
      .background(hovered == title ? p.hover : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain).onHover { hovered = $0 ? title : (hovered == title ? nil : hovered) }
    .help(help).accessibilityLabel(title).accessibilityAddTraits(checked ? .isSelected : [])
  }
}

extension DestinationPicker {
  /// New task: a fresh task in the folder last worked in (or the first project), opened at once
  /// with its folders in the middle and the box at the bottom. With no project yet, the full list.
  static func newTaskHere(browser: BrowserModel, agent: AgentModel) {
    guard !agent.choosingDestination else { ToastCenter.shared.show(AgentModel.choosingWords); return }
    let current = agent.mode == .project ? browser.listedProjects.first { $0.id == agent.projectID } : nil
    guard let project = current ?? browser.listedProjects.first else {
      return show(browser: browser, agent: agent, newTask: true)
    }
    startTask(in: project, agent: agent, browser: browser)
  }
}
