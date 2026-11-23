import SereinCore
import SwiftUI

/// Project tasks written while offline and kept from an earlier session, in History › Chats: “Written
/// while offline. Not sent.” They never send by themselves after a restart: each row offers Send,
/// Edit and Discard, and Send or Edit opens the task's tab (through SereinRouter), never Serein.
struct ReadyToSendCard: View {
  @ObservedObject var agent: AgentModel
  @ObservedObject var browser: BrowserModel
  @ObservedObject private var flow: ComposerFlow
  @Environment(\.palette) var p
  init(agent: AgentModel, browser: BrowserModel) {
    self.agent = agent
    self.browser = browser
    _flow = ObservedObject(wrappedValue: agent.flow)
  }
  var body: some View {
    let tasks = flow.restoredTasks
    if !tasks.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text("Written while offline. Not sent.").font(UIStyle.meta).foregroundStyle(p.secondary)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
          Text("\(tasks.count)").font(UIStyle.microMono).foregroundStyle(p.faint)
          Spacer(minLength: 0)
        }.padding(.leading, 8).frame(height: 24)
        ForEach(tasks) { task in row(task) }
      }.padding(4)
        .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius, style: .continuous))
    }
  }
  func row(_ task: PendingTask) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(verbatim: task.prompt).font(UIStyle.bodyStrong).foregroundStyle(p.ink).lineLimit(1)
        .truncationMode(.tail)
      Text("Kept from your last session. Not sent.").font(UIStyle.meta).foregroundStyle(p.secondary)
        .lineLimit(1)
      HStack(spacing: 2) {
        Button("Send") { open(task) { flow.sendReady(task.id) } }.buttonStyle(QuietButton())
          .disabled(!flow.isOnline)
        Button("Edit") { open(task) { flow.editReady(task.id) } }.buttonStyle(QuietButton())
        Spacer(minLength: 0)
        Button("Discard") { flow.cancelOffline(task.id) }.buttonStyle(QuietButton())
          .foregroundStyle(p.danger)
      }.font(UIStyle.meta)
    }.padding(.horizontal, 6).padding(.vertical, 5)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Written while offline, not sent: \(task.prompt)")
  }
  /// Opens the task's tab (when its chat still exists), then acts there.
  func open(_ task: PendingTask, then action: () -> Void) {
    if agent.conversations.contains(where: { $0.id == task.threadID }), !agent.running {
      SereinRouter.open(threadID: task.threadID)
    }
    action()
  }
}
