import Darwin
import SereinCore
import SwiftUI

/// A sub-thread the person clicked, with the task it belongs to.
struct ShownSubagent: Identifiable {
  let helper: ExternalSubagent
  let parentTitle: String
  let provider: Provider?
  let parent: AgentsByProject.Task
  var id: String { helper.id }
  /// A Codex helper is a thread of its own (its rollout file is `rollout-<time>-<thread id>.jsonl`),
  /// so the person can continue it directly; nil for Claude Code's, which only its parent reaches.
  var codexThread: String? {
    guard helper.id.hasPrefix("codex:"), let log = helper.log else { return nil }
    let thread = String(URL(fileURLWithPath: log).deletingPathExtension().lastPathComponent.suffix(36))
    return UUID(uuidString: thread) == nil ? nil : thread
  }
}

/// A sub-thread as a conversation, in the main view over its parent's chat (`SubThreadFocus`):
/// the window's header is the parent's, naming it. What it was asked on the right, what it did and
/// said on the left, following along while it works, with a box to continue it. A message to it goes through
/// the chat that can reach it (`continueWith`): Codex's own thread, or Claude Code's parent session,
/// which hands it on. Everything shown is untrusted text from the harness's file.
struct SubagentTranscriptView: View {
  let shown: ShownSubagent
  /// Sends the person's words on, then shows where the conversation continues.
  let continueWith: (String) -> Void
  @State private var draft = ""
  @FocusState private var typing: Bool
  @Environment(\.palette) private var p
  @State private var history: LinkedHistory?
  @State private var problem: String?
  @State private var isWorking: Bool
  private static let followEvery: Duration = .seconds(2)
  /// A file written this recently belongs to a sub-thread still at work.
  private static let workingWindow: TimeInterval = 30
  /// The parent's options line, shown under the box as the parent's composer shows it.
  let options: AnyView
  init<Options: View>(shown: ShownSubagent, continueWith: @escaping (String) -> Void, @ViewBuilder options: () -> Options) {
    self.shown = shown
    self.continueWith = continueWith
    self.options = AnyView(options())
    _isWorking = State(initialValue: shown.helper.state != nil)
  }
  var body: some View {
    VStack(spacing: 0) {
      content.frame(maxWidth: UIStyle.composerWidth).frame(maxWidth: .infinity, maxHeight: .infinity)
      inlineComposer.frame(maxWidth: UIStyle.composerWidth).padding(.horizontal, 16).padding(.bottom, 16)
    }
    .task(id: shown.id) { await follow() }
  }
  /// The parent's composer, as the task view draws it: the box, then the line under it.
  private var inlineComposer: some View {
    VStack(spacing: 4) {
      HStack(alignment: .bottom, spacing: 8) {
        TextField("Reply to \(shown.helper.title)", text: $draft, axis: .vertical)
          .textFieldStyle(.plain).font(UIStyle.body).lineLimit(1...8)
          .focused($typing).onSubmit(send).shiftReturnNewLine()
          .accessibilityLabel("Message \(shown.helper.title)")
        Button(action: send) {
          let ready = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          InterfaceIcon(systemName: "arrow.up", size: 15)
            .foregroundStyle(ready ? p.onSolid : p.faint).frame(width: 28, height: 28)
            .background(ready ? p.solid : p.track, in: Circle())
        }.buttonStyle(.pressable).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .help(shown.codexThread == nil ? "Goes to \(shown.parentTitle), which passes it on" : "Continues this sub-thread in Codex")
          .accessibilityLabel("Send")
      }.padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 10)
        .background(p.pill, in: RoundedRectangle(cornerRadius: UIStyle.composerRadius))
      options
    }
  }
  @ViewBuilder private var content: some View {
    if let problem {
      centered(problem)
    } else if let history, history.messages.isEmpty {
      centered("Nothing written yet.")
    } else if let history {
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: AssistantMetrics.bubbleGap * 2) {
            if history.omitsEarlier {
              Text("Earlier steps are left out of this long sub-thread.").font(UIStyle.meta).foregroundStyle(p.faint)
            }
            ForEach(Array(history.messages.enumerated()), id: \.offset) { _, message in row(message) }
            Color.clear.frame(height: 1).id(Self.end)
          }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        // A finished sub-thread reads from the top; one at work follows its newest step.
        .onChange(of: history.messages.count, initial: true) { _, _ in
          if isWorking { reader.scrollTo(Self.end, anchor: .bottom) }
        }
      }
    } else {
      ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
  private func centered(_ words: String) -> some View {
    Text(verbatim: words).font(UIStyle.body).foregroundStyle(p.secondary)
      .multilineTextAlignment(.center).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  /// What it was asked, on the right as a sent message; what it did and said on the left, its steps
  /// as one quiet line over its words, as the main chat shows them.
  @ViewBuilder private func row(_ message: LinkedHistory.Message) -> some View {
    if message.role == "you" {
      HStack(spacing: 0) {
        Spacer(minLength: 60)
        PersonBubble(text: message.text)
      }.accessibilityElement(children: .combine).accessibilityLabel("Asked: \(message.text)")
    } else {
      VStack(alignment: .leading, spacing: 4) {
        if !message.activities.isEmpty {
          Text(verbatim: TranscriptActivity.summary(message.activities)).font(UIStyle.meta).foregroundStyle(p.faint)
            .padding(.leading, 4)
            .help(message.activities.map(\.label).joined(separator: "\n"))
        }
        if !message.text.isEmpty {
          SereinReplyBubble(text: message.text) { MessageContent(text: message.text, showsCopyButton: false) }
        }
      }
    }
  }

  private func send() {
    let words = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !words.isEmpty else { return }
    draft = ""
    continueWith(words)
  }
  /// Reads the transcript, and again whenever its file changes, for as long as the sheet is open.
  /// Claude Code's transcripts do not say when a turn ends, so the file's last write says it is at work.
  private func follow() async {
    var lastRead: Date?
    // Kept for as long as this sub-thread is open: each change reads only the lines added.
    let tail = AppendedTail()
    while !Task.isCancelled {
      do {
        let written = try lastWrite()
        if written != lastRead {
          let next = try await read(tail)
          if next != history { history = next }
          lastRead = written
          problem = nil
        }
        let working = history?.working == true || Date().timeIntervalSince(written) < Self.workingWindow
        if working != isWorking { isWorking = working }
      } catch {
        if history == nil { problem = "Serein could not read this sub-thread. \(error.localizedDescription)" }
        if isWorking { isWorking = false }
      }
      try? await Task.sleep(for: Self.followEvery)
    }
  }
  /// When the transcript last changed. It must still be a plain file inside the harness's own
  /// folder: the scan found it there, but this runs later, and the folder is not Serein's.
  private func lastWrite() throws -> Date {
    guard let log = shown.helper.log, let driver = driver,
      RunMode.previewing || ExternalSessionReader.allowedLog(log, driver: driver, home: NSHomeDirectory())
    else { throw SereinError.invalid("Its transcript is no longer on this Mac.") }
    var info = stat()
    guard lstat(log, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      throw SereinError.invalid("Its transcript is no longer on this Mac.")
    }
    return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
  }
  private var driver: HarnessDriver? {
    shown.helper.id.split(separator: ":").first.flatMap { HarnessDriver(rawValue: String($0)) }
  }
  private func read(_ tail: AppendedTail) async throws -> LinkedHistory {
    guard let log = shown.helper.log else { throw SereinError.invalid("Its transcript is no longer on this Mac.") }
    if driver == .claude {
      return try await LinkedSessionMonitor.readTail(log, tail: tail) { LinkedHistory.claude($0, omitsEarlier: $1, helper: true) }
    }
    // A Codex rollout file is named `rollout-<time>-<thread id>.jsonl`.
    let name = URL(fileURLWithPath: log).deletingPathExtension().lastPathComponent
    let thread = String(name.suffix(Self.threadIDLength))
    guard UUID(uuidString: thread) != nil else { throw SereinError.invalid("This sub-thread's file has an unexpected name.") }
    return try await LinkedSessionMonitor.read(
      SessionLink(driver: HarnessDriver.codex.rawValue, nativeID: thread, file: nil),
      codex: HarnessRegistry.shared.executable(.codex), tail: tail)
  }
  private static let threadIDLength = 36
  private static let end = "end"
}

/// The sub-thread open in the main container. It shows at once, whether or not its parent's chat
/// has opened behind it; opening any other chat closes it.
@MainActor final class SubThreadFocus: ObservableObject {
  static let shared = SubThreadFocus()
  struct Open {
    let shown: ShownSubagent
    let continueWith: (String) -> Void
  }
  @Published var open: Open?

  /// The chat in front is this sub-thread's parent.
  func isParent(_ agent: AgentModel) -> Bool {
    guard let shown = open?.shown else { return false }
    if agent.conversationID == shown.parent.id { return true }
    if let link = agent.link, let parent = shown.parent.outside.flatMap(SessionOpen.link(for:)) {
      return link.driver == parent.driver && link.nativeID == parent.nativeID
    }
    return false
  }
  func close() { open = nil }
}
