import Combine
import SereinCore
import SereinEngines
import SwiftUI

/// Small workflow pieces that hang off the agent model: interrupted-task recovery and saving a
/// thread's plan mode when it changes.
@MainActor enum WorkflowGaps {
  private static var cancellables = Set<AnyCancellable>()
  /// Called once from `AgentModel.init`, before any run starts.
  static func start(agent: AgentModel, browser: BrowserModel) {
    cancellables.removeAll()
    InterruptedRunCenter.shared.start(library: browser.library)
    // A new step in a thread answers its "stopped when Serein quit" note.
    agent.$running.removeDuplicates().filter { $0 }.sink { [weak agent] _ in
      guard let agent else { return }
      DispatchQueue.main.async {
        if agent.hub.run(for: agent.conversationID) != nil {
          InterruptedRunCenter.shared.resolve(thread: agent.conversationID)
        }
      }
    }.store(in: &cancellables)
    // Plan mode is kept with the thread; save it when the user turns it on or off.
    ComposerContext.shared.$planMode.dropFirst().removeDuplicates().sink { [weak agent] _ in
      DispatchQueue.main.async {
        guard let agent, agent.conversations.contains(where: { $0.id == agent.conversationID })
        else { return }
        agent.saveConversation()
      }
    }.store(in: &cancellables)
  }
}

/// Runs that were working when Serein quit or crashed. They are marked stopped in the run log
/// at launch and never restart by themselves; their threads offer Retry and Continue.
@MainActor final class InterruptedRunCenter: ObservableObject {
  static let shared = InterruptedRunCenter()
  @Published private(set) var runs: [InterruptedRun] = []
  private var library: Library?

  func start(library: Library) {
    self.library = library
    runs = InterruptedRuns.recover(library: library)
  }
  func note(thread: String, hub: AgentHub) -> InterruptedRun? {
    InterruptedRuns.pending(
      thread: thread, in: runs, newerRunStarted: hub.latest(for: thread) != nil)
  }
  func resolve(thread: String) {
    let left = InterruptedRuns.resolve(thread: thread, in: runs)
    guard left.count != runs.count else { return }
    runs = left
    try? library?.save(runs, to: InterruptedRuns.path)
  }
}

/// "This task stopped when Serein quit." in the thread it belongs to.
struct InterruptedRunBanner: View {
  @ObservedObject var agent: AgentModel
  @ObservedObject var center = InterruptedRunCenter.shared
  @ObservedObject var hub: AgentHub
  @Environment(\.palette) var p
  init(agent: AgentModel) {
    self.agent = agent
    _hub = ObservedObject(wrappedValue: agent.hub)
  }
  var body: some View {
    if !agent.running, let run = center.note(thread: agent.conversationID, hub: hub) {
      HStack(alignment: .center, spacing: 10) {
        InterfaceIcon(systemName: "pause.circle", size: 14).foregroundStyle(p.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text("This task stopped when Serein quit.").font(UIStyle.body).foregroundStyle(p.ink)
          Text("Reply to continue, or try it again. Stopped \(run.stoppedAt.formatted(date: .abbreviated, time: .shortened)).")
            .role(.meta)
        }
        Spacer(minLength: 8)
        Button("Retry") { retry() }.buttonStyle(QuietButton())
          .help("Send the last request again from the start")
        Button("Continue") { resend("Continue where you stopped.") }.buttonStyle(QuietButton())
          .help("Reply so the agent picks up where it stopped")
        Button {
          center.resolve(thread: agent.conversationID)
        } label: {
          InterfaceIcon(systemName: "xmark", size: 11)
        }.buttonStyle(QuietButton()).accessibilityLabel("Dismiss")
      }.padding(.horizontal, 14).padding(.vertical, 10)
        .background(p.panel, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
        .frame(maxWidth: UIStyle.composerWidth).padding(.horizontal, 16).padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }
  }
  /// Sends the interrupted request again without its unfinished reply.
  func retry() {
    guard
      let prompt = ThreadActions.lastRequest(agent.messages.map { ($0.role, $0.text) })
    else { return }
    let saved = agent.messages
    agent.messages = Array(saved.prefix(InterruptedRuns.retryTranscript(saved.map(\.role))))
    agent.error = nil
    resend(prompt)
    if !agent.running { agent.messages = saved }
  }
  /// Sends with no composer attachments: the interrupted turn's own context is already in the
  /// thread. Whatever the user has attached or typed stays in the composer.
  private func resend(_ prompt: String) {
    let draft = agent.draft
    agent.send(prompt, chips: .empty)
    if agent.draft != draft { agent.draft = draft }
  }
}

extension AgentHub {
  /// Quitting stops every run; each is remembered so its thread can offer Retry next time.
  func stopAllForQuit() {
    let running = active
    if let library = browser?.library {
      InterruptedRuns.remember(running.map(\.record), library: library)
    }
    for run in running { stop(run, message: InterruptedRuns.summary) }
    // Stop's ladder would finish after Serein has exited, so quitting waits up to 2 s for every
    // CLI group, warm ones too, then kills what is left. What still escapes is ended at the next
    // launch (Engines.sweepLeftovers).
    engines.endGroupsNow()
  }
}

extension BrowserModel {
  /// Removes a saved page or kept passage, with Undo in a toast.
  func removeMarkWithUndo(_ mark: Mark) {
    guard let index = marks.firstIndex(where: { $0.id == mark.id }) else { return }
    marks.remove(at: index)
    try? library.save(marks, to: "marks/saved.json")
    ToastCenter.shared.show(mark.quote.isEmpty ? "Removed the saved page." : "Removed the kept passage.")
    { [weak self] in
      guard let self, !self.marks.contains(where: { $0.id == mark.id }) else { return }
      self.marks.insert(mark, at: min(index, self.marks.count))
      try? self.library.save(self.marks, to: "marks/saved.json")
    }
  }
}
