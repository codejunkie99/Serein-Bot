import AppKit
import SereinCore
import SwiftUI

/// How a row's title reads. Nearly every task is quiet grey with no mark, one at work has moving
/// words, and only one that wants the person gets full ink and a coloured word.
enum AgentRowInk {
  case working, attention, quiet
}

/// The Agents list's and Agents at work's text: regular weight, a size up from the sidebar's.
enum AgentsType {
  static var title: Font { UIStyle.font(14) }
  static var detail: Font { UIStyle.font(13) }
  static var caption: Font { UIStyle.font(12) }
}

/// A task's title in that ink: full ink while selected, a step up while hovered.
struct AgentRowTitle: View {
  let text: String
  let ink: AgentRowInk
  var selected = false
  var hovered = false
  var font: Font = AgentsType.title
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.palette) private var p
  var body: some View {
    Group {
      if ink == .working {
        ShimmerText(text: text, font: font).lineLimit(1).truncationMode(.tail)
      } else {
        Text(verbatim: text).font(font).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private var color: Color {
    if selected || ink == .attention { return p.ink }
    return hovered || contrast == .increased ? p.secondary : p.faint
  }
}

/// A row's coloured word, in place of a status dot: the only colour most of the list ever shows.
struct AgentRowWord: View {
  let text: String
  let color: Color
  var body: some View {
    Text(verbatim: text).font(AgentsType.caption).foregroundStyle(color).lineLimit(1).fixedSize().accessibilityHidden(true)
  }
}

extension AgentsByProject.Task {
  /// Opens it where it lives, from its row or from one of its sub-threads.
  @MainActor func open(agent: AgentModel, memory: AgentListMemory) {
    if status == .failed { memory.markFailureSeen(keys) }
    if let outside {
      SessionOpen.openRunning(outside, agent: agent)
    } else if let past {
      SessionOpen.openPast(past, agent: agent)
    } else if serein {
      SereinRouter.openTask(id)
    } else if let chat = agent.conversations.first(where: { $0.id == id }) {
      agent.openConversation(chat)
    } else {
      SereinRouter.open(threadID: id)
    }
  }
}

/// One task. A click opens it: a direct task's chat, a helper of Serein's in Serein's surface, or an
/// outside session's thread or app. Its sub-thread chevron sits beside the row's button, not inside
/// it, so each takes its own click. Hover state lives here, so moving the pointer redraws one row.
struct AgentTaskRow: View {
  let task: AgentsByProject.Task
  var nested = false
  /// Its project, shown on hover in Recents, which has no project headings.
  var place: String? = nil
  let selected: Bool
  let selection: Namespace.ID
  let browser: BrowserModel
  let agent: AgentModel
  let hub: AgentHub
  @ObservedObject private var pulls = PullRequestStore.shared
  @ObservedObject private var memory = AgentListMemory.shared
  @State private var hovered = false
  @Environment(\.palette) private var p
  private static let failureLinger: TimeInterval = 86_400
  private static let toggleRoom: CGFloat = 36
  private var title: String { memory.title(task.keys) ?? task.title }
  /// A failure asks for the person until they open it, and for a day at most.
  private var failureShows: Bool {
    task.status == .failed && !selected && !memory.failureSeen(task.keys)
      && Date().timeIntervalSince(task.when) < Self.failureLinger
  }
  private func ink(_ status: AgentsByProject.Status) -> AgentRowInk {
    if status == .working { return .working }
    return status == .needsYou || failureShows ? .attention : .quiet
  }
  var body: some View {
    let pull = task.pullKey.flatMap(pulls.info)
    let status = task.shown(pull)
    let number = pull?.number ?? task.pullRequest?.number
    let pr = number.map { " · PR #\($0)" + (pull.map { " " + $0.state.word.lowercased() } ?? "") } ?? ""
    let app = (task.provider?.name ?? "Serein") + (task.outside != nil ? ", outside Serein" : "")
      + (task.subagents.isEmpty ? "" : ", \(task.subagents.count) sub-thread\(task.subagents.count == 1 ? "" : "s")")
    ZStack(alignment: .trailing) {
      Button(action: open) {
        HStack(spacing: 7) {
          AgentRowTitle(text: title, ink: ink(status), selected: selected, hovered: hovered)
          trailing(status: status, number: number, state: pull?.state)
        }.padding(.leading, nested ? 14 : 10).padding(.trailing, task.subagents.isEmpty ? 8 : Self.toggleRoom)
      }.buttonStyle(SidebarRowStyle(selected: selected, hovered: hovered, selection: selection,
                                    selectedWash: p.accent.opacity(0.2),
                                    restingWash: status == .needsYou ? p.warning.opacity(0.1) : nil))
        .help("\(title) · \(status.word) · \(app)\(pr)")
        .accessibilityLabel(title).accessibilityValue("\(status.word), \(app)\(pr)")
        .accessibilityAddTraits(selected ? .isSelected : [])
      if !task.subagents.isEmpty { toggle.padding(.trailing, 4) }
    }
    .agentListProbe(title)
    .onHover { hovered = $0 }
    .task(id: task.pullKey) { if let pullKey = task.pullKey { pulls.want(pullKey) } }
    .contextMenu { menu(number: number, link: pull?.url ?? task.pullRequest?.url.absoluteString) }
  }
  @ViewBuilder private func trailing(status: AgentsByProject.Status, number: Int?, state: PullRequestLookup.State?) -> some View {
    if hovered, let place {
      Text(verbatim: place).font(AgentsType.caption).foregroundStyle(p.faint).lineLimit(1).truncationMode(.tail)
        .frame(maxWidth: 110, alignment: .trailing)
    } else {
      if memory.isPinned(task.keys) {
        Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(p.faint).accessibilityHidden(true)
      }
      if number != nil { AgentPullMark(state: state) }
      if status == .needsYou {
        AgentRowWord(text: "Needs you", color: p.warning)
      } else if failureShows {
        AgentRowWord(text: "Failed", color: p.danger)
      } else if let provider = task.provider {
        HarnessGlyph(provider: provider, size: 11).opacity(0.45)
      }
    }
  }
  private var toggle: some View {
    let open = memory.showsSubagents(task.keys)
    return Button { memory.toggleSubagents(task.keys) } label: {
      HStack(spacing: 3) {
        Text(verbatim: "\(task.subagents.count)").font(UIStyle.microMono)
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
          .rotationEffect(.degrees(open ? 0 : -90))
      }.foregroundStyle(p.faint).frame(width: 30, height: UIStyle.sidebarRowHeight).contentShape(Rectangle())
    }.buttonStyle(.pressable)
      .agentListProbe(open ? "Hide sub-threads" : "Show \(task.subagents.count) sub-threads")
      .help(open ? "Hide its sub-threads" : "Show its \(task.subagents.count) sub-threads")
      .accessibilityLabel(open ? "Hide sub-threads" : "Show \(task.subagents.count) sub-threads")
  }
  private func open() {
    // The task's own row shows the task, not a sub-thread over it.
    SubThreadFocus.shared.close()
    task.open(agent: agent, memory: memory)
  }
  @ViewBuilder private func menu(number: Int?, link: String?) -> some View {
    Button("Open", action: open)
    if let session = task.outside, session.pid != nil {
      Button("Take Me There") { AgentsCard.reveal(session) }
    }
    if let run = hub.run(for: task.id), run.isActive {
      Button("Stop") { hub.stop(run) }
    }
    Divider()
    Button("Rename…", action: rename)
    Button(memory.isPinned(task.keys) ? "Unpin" : "Pin to Top") { memory.togglePin(task.keys) }
    Button(memory.isHidden(task.keys) ? "Show in List" : "Hide from List") { memory.toggleHidden(task.keys) }
    if let folder = task.outside?.cwd ?? browser.projects.first(where: { $0.id == task.projectKey })?.path {
      Button("Copy Folder Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(folder, forType: .string)
      }
    }
    if let link, let number {
      Button("Open Pull Request #\(number)") { browser.openInDefaultBrowser(link) }
    }
  }
  /// The name shows only in this list; the chat and the app it runs in keep theirs.
  private func rename() {
    guard !RunMode.automated else { return }
    let alert = NSAlert()
    alert.messageText = "Rename this task"
    alert.informativeText = "The new name shows in this list. Leave it empty to go back to the task's own."
    let field = NSTextField(string: title)
    field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    memory.rename(task.keys, to: field.stringValue)
  }
}

/// A job of Serein's: the request that started its helpers, Serein's mark, and a chevron beside the
/// row's button. A click opens Serein's chat, where its card is.
struct AgentJobRow: View {
  let job: AgentsByProject.Job
  var place: String? = nil
  let selection: Namespace.ID
  let browser: BrowserModel
  @ObservedObject private var memory = AgentListMemory.shared
  @State private var hovered = false
  @Environment(\.palette) private var p
  var body: some View {
    let folded = memory.foldedJobs.contains(job.id)
    let status = job.status
    let ink: AgentRowInk = status == .working ? .working : status == .needsYou ? .attention : .quiet
    ZStack(alignment: .trailing) {
      Button { SidebarPlaces.show(.serein, browser: browser) } label: {
        HStack(spacing: 7) {
          AgentRowTitle(text: job.title, ink: ink, hovered: hovered)
          if hovered, let place {
            Text(verbatim: place).font(AgentsType.caption).foregroundStyle(p.faint).lineLimit(1).truncationMode(.tail)
              .frame(maxWidth: 110, alignment: .trailing)
          } else if status == .needsYou {
            AgentRowWord(text: "Needs you", color: p.warning)
          } else {
            SereinHologramMark(size: 14).opacity(0.6)
          }
        }.padding(.leading, 10).padding(.trailing, 28)
      }.buttonStyle(SidebarRowStyle(selected: false, hovered: hovered, selection: selection,
                                    restingWash: status == .needsYou ? p.warning.opacity(0.1) : nil))
        .help("\(job.title) · \(status.word) · Serein asked \(job.helpers.count) helper\(job.helpers.count == 1 ? "" : "s")")
        .accessibilityLabel("Serein: \(job.title)")
        .accessibilityValue("\(status.word), \(job.helpers.count) helper\(job.helpers.count == 1 ? "" : "s")")
      Button {
        if folded { memory.foldedJobs.remove(job.id) } else { memory.foldedJobs.insert(job.id) }
      } label: {
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(p.faint)
          .rotationEffect(.degrees(folded ? -90 : 0))
          .frame(width: 24, height: UIStyle.sidebarRowHeight).contentShape(Rectangle())
      }.buttonStyle(.pressable).padding(.trailing, 2)
        .help(folded ? "Show its helpers" : "Hide its helpers")
        .accessibilityLabel(folded ? "Show helpers" : "Hide helpers")
    }.onHover { hovered = $0 }
  }
}

/// A sub-thread on its parent's tree line. A click opens its own transcript; one with no transcript
/// to read opens its parent.
struct AgentSubagentRow: View {
  let helper: ExternalSubagent
  let parentTitle: String
  /// Its transcript is open.
  let showing: Bool
  let selection: Namespace.ID
  let open: () -> Void
  @State private var hovered = false
  @Environment(\.palette) private var p
  var body: some View {
    let status = AgentsByProject.status(helper.state)
    let ink: AgentRowInk = status == .working ? .working : status == .needsYou ? .attention : .quiet
    Button(action: open) {
      HStack(spacing: 7) {
        AgentRowTitle(text: helper.title, ink: ink, selected: showing, hovered: hovered)
        if status == .needsYou {
          AgentRowWord(text: "Needs you", color: p.warning)
        }
      }.padding(.leading, 14).padding(.trailing, 8)
    }.buttonStyle(SidebarRowStyle(selected: false, hovered: hovered, selection: selection,
                                  restingWash: showing ? p.accent.opacity(0.2) : nil))
      .onHover { hovered = $0 }
      .agentListProbe("Sub-thread: \(helper.title)")
      .help("Sub-thread of \(parentTitle): \(helper.title) · \((status ?? .done).word)")
      .accessibilityLabel("Sub-thread: \(helper.title)").accessibilityValue((status ?? .done).word)
      .accessibilityAddTraits(showing ? .isSelected : [])
  }
}

/// The tree line beside a job's helpers or a session's sub-threads: down from the row above to the
/// last one, with a short branch to each.
struct AgentTreeLine: View {
  let count: Int
  @Environment(\.palette) private var p
  var body: some View {
    let row = UIStyle.sidebarRowHeight + 2
    Path { path in
      guard count > 0 else { return }
      path.move(to: CGPoint(x: 4.5, y: 0))
      path.addLine(to: CGPoint(x: 4.5, y: row * CGFloat(count - 1) + row / 2))
      for i in 0..<count {
        let y = row * CGFloat(i) + row / 2
        path.move(to: CGPoint(x: 4.5, y: y))
        path.addLine(to: CGPoint(x: 11, y: y))
      }
    }.stroke(p.borderStrong, lineWidth: 1).allowsHitTesting(false).accessibilityHidden(true)
  }
}

/// The pull request mark, quiet unless it needs something: amber with a badge on a conflict, faint
/// otherwise (its state is in the row's help and VoiceOver).
struct AgentPullMark: View {
  let state: PullRequestLookup.State?
  @Environment(\.palette) private var p
  var body: some View {
    PullGlyph(merged: state == .merged)
      .stroke(state == .conflict ? p.warning : p.faint, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
      .frame(width: 10, height: 11)
      .overlay(alignment: .topTrailing) {
        if state == .conflict {
          Image(systemName: "exclamationmark").font(.system(size: 6, weight: .heavy)).foregroundStyle(p.warning)
            .offset(x: 4, y: -3)
        }
      }
      .frame(width: 14).accessibilityHidden(true)
  }
}

/// GitHub's pull request mark, drawn: two commits on a line and a branch curving into the third
/// (open), or the third joined by a curve from the top commit (merged).
private struct PullGlyph: Shape {
  var merged = false
  func path(in rect: CGRect) -> Path {
    let w = rect.width, h = rect.height, r = w * 0.17
    func dot(_ x: CGFloat, _ y: CGFloat, _ path: inout Path) {
      path.addEllipse(in: CGRect(x: rect.minX + x - r, y: rect.minY + y - r, width: r * 2, height: r * 2))
    }
    var path = Path()
    let left = w * 0.22, right = w * 0.78, top = h * 0.17, bottom = h * 0.83
    dot(left, top, &path)
    dot(left, bottom, &path)
    path.move(to: CGPoint(x: rect.minX + left, y: rect.minY + top + r))
    path.addLine(to: CGPoint(x: rect.minX + left, y: rect.minY + bottom - r))
    if merged {
      dot(right, h * 0.6, &path)
      path.move(to: CGPoint(x: rect.minX + left, y: rect.minY + top + r))
      path.addQuadCurve(to: CGPoint(x: rect.minX + right - r, y: rect.minY + h * 0.6),
                        control: CGPoint(x: rect.minX + left, y: rect.minY + h * 0.6))
    } else {
      dot(right, bottom, &path)
      path.move(to: CGPoint(x: rect.minX + right, y: rect.minY + bottom - r))
      path.addLine(to: CGPoint(x: rect.minX + right, y: rect.minY + h * 0.42))
      path.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.5, y: rect.minY + top),
                        control: CGPoint(x: rect.minX + right, y: rect.minY + top))
      // The arrowhead on the branch.
      path.move(to: CGPoint(x: rect.minX + w * 0.62, y: rect.minY + top - h * 0.12))
      path.addLine(to: CGPoint(x: rect.minX + w * 0.5, y: rect.minY + top))
      path.addLine(to: CGPoint(x: rect.minX + w * 0.62, y: rect.minY + top + h * 0.12))
    }
    return path
  }
}
