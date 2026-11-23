import SereinCore
import SwiftUI
import WebKit

/// Placed after each message in a thread: the changes card and approval card of the turn that
/// ended on that message, if any.
struct TurnReviewSlot: View {
  @ObservedObject var agent: AgentModel
  /// The thread the reviews belong to (a task shown by id in Serein's surface); nil for the
  /// current chat. Answers are applied by the review's own thread either way (EditReview.resolve).
  var threadID: String? = nil
  var messageID: String
  @ObservedObject private var store = EditReview.shared
  init(agent: AgentModel, threadID: String? = nil, messageID: String) {
    self.agent = agent
    self.threadID = threadID
    self.messageID = messageID
  }
  var body: some View {
    if let review = store.review(for: messageID), threadID == nil || review.threadID == threadID {
      VStack(alignment: .leading, spacing: 10) {
        if !review.approvals.isEmpty { ApprovalCard(agent: agent, review: review) }
        TurnChangesCard(agent: agent, review: review)
      }
    }
  }
}

struct TurnChangesCard: View {
  @ObservedObject var agent: AgentModel
  var review: TurnReview
  @ObservedObject private var store = EditReview.shared
  @State private var expanded = Set<String>()
  @State private var patches: [String: (text: String, truncated: Bool)] = [:]
  @State private var showAll = false
  /// The file list opens from Review; the card is one line until then.
  @State private var open = false
  @Environment(\.palette) var p
  static let visibleFiles = 40

  var body: some View {
    switch review.state {
    case .none, .snapshotting, .running: EmptyView()
    case .finishing:
      line(icon: nil, "Saving this turn's changes…", progress: true)
    case .refused(let copy), .failed(let copy):
      line(icon: "exclamationmark.triangle", copy)
        .accessibilityLabel(copy)
    case .notGit:
      VStack(alignment: .leading, spacing: 8) {
        line(icon: "info.circle", EditTrackingCopy.notGit)
        Text(EditTrackingCopy.notGitHelp).role(.meta).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          Button("Initialize git here") { store.initializeGit(reviewID: review.id) }
            .buttonStyle(QuietButton()).disabled(store.busy.contains(review.id))
          if let note = store.notes[review.id] { Text(note).role(.meta) }
        }
      }.padding(12).card(p)
    case .ready:
      if review.files.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          line(icon: "checkmark", DiffStat.headline([]))
          if let skipped = SnapshotSkips.note(review.skipped ?? []) { Text(skipped).role(.meta) }
        }
      } else {
        changes
      }
    }
  }

  private func line(icon: String?, _ text: String, progress: Bool = false) -> some View {
    HStack(spacing: 8) {
      if progress {
        ProgressView().controlSize(.small)
      } else if let icon {
        InterfaceIcon(systemName: icon, size: 12).foregroundStyle(p.secondary)
      }
      Text(text).role(.meta).fixedSize(horizontal: false, vertical: true)
    }.accessibilityElement(children: .combine)
  }

  private var changes: some View {
    let totals = DiffStat.totals(review.files)
    let busy = store.busy.contains(review.id)
    let files = showAll ? review.files : Array(review.files.prefix(Self.visibleFiles))
    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        InterfaceIcon(systemName: "doc.text", size: 13).foregroundStyle(p.secondary)
        Text(DiffStat.headline(review.files)).font(UIStyle.body.weight(.medium)).lineLimit(1).fixedSize()
        counts(totals.added, totals.removed).fixedSize()
        if review.undone {
          Text("Undone").font(UIStyle.micro).foregroundStyle(p.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(p.track, in: Capsule())
        }
        Spacer(minLength: 8)
        if busy { ProgressView().controlSize(.small) }
        Button(open ? "Hide" : "Review") { open.toggle() }.buttonStyle(QuietButton())
          .accessibilityValue(open ? "Files shown" : "Files hidden")
        if review.undone {
          Button("Redo") { store.perform(.redo, reviewID: review.id, hub: agent.hub) }
            .buttonStyle(QuietButton()).disabled(busy)
            .help("Apply this turn's changes again")
        } else {
          Button("Undo") { store.perform(.undo, reviewID: review.id, hub: agent.hub) }
            .buttonStyle(QuietButton()).disabled(busy)
            .help("Restore these files to how they were before this turn")
            .accessibilityLabel("Undo this turn")
        }
      }.padding(.horizontal, 12).padding(.vertical, 10)
      if let note = store.notes[review.id] {
        Text(note).role(.meta).fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 12).padding(.bottom, 8)
          .accessibilityAddTraits(.updatesFrequently)
      }
      if review.overlapped == true {
        Text(EditTrackingCopy.sharedProject).role(.meta).fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 12).padding(.bottom, 8)
      }
      if let skipped = SnapshotSkips.note(review.skipped ?? []) {
        Text(skipped).role(.meta).fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 12).padding(.bottom, 8)
      }
      if open {
        Divider().overlay(p.line)
        ForEach(files, id: \.path) { file in fileRow(file) }
        if review.files.count > Self.visibleFiles && !showAll {
          Button("Show \(review.files.count - Self.visibleFiles) more files") { showAll = true }
            .buttonStyle(QuietButton()).padding(8)
        }
      }
    }.card(p).accessibilityElement(children: .contain)
      .accessibilityLabel("Changes in this turn")
  }

  private func counts(_ added: Int, _ removed: Int) -> some View {
    HStack(spacing: 6) {
      Text("+\(added)").foregroundStyle(p.success)
      Text("−\(removed)").foregroundStyle(p.danger)
    }.font(UIStyle.microMono)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(added) lines added, \(removed) removed")
  }

  private func fileRow(_ file: DiffFile) -> some View {
    let open = expanded.contains(file.path)
    return VStack(alignment: .leading, spacing: 0) {
      Button {
        toggle(file)
      } label: {
        HStack(spacing: 8) {
          InterfaceIcon(systemName: open ? "chevron.down" : "chevron.right", size: 10)
            .foregroundStyle(p.faint).frame(width: 12)
          Text(verbatim: file.path).font(UIStyle.monoMeta).lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 8)
          if file.isBinary {
            Text("Binary").font(UIStyle.micro).foregroundStyle(p.faint)
          } else {
            counts(file.added ?? 0, file.removed ?? 0)
          }
        }.padding(.horizontal, 12).padding(.vertical, 7).contentShape(Rectangle())
      }.buttonStyle(.pressable)
        .accessibilityLabel("\(file.path), \(open ? "hide" : "show") changes")
      if open { diff(file) }
    }
  }

  @ViewBuilder private func diff(_ file: DiffFile) -> some View {
    if file.isBinary {
      Text("This is a binary file, so there is no text diff.").role(.meta)
        .padding(.horizontal, 32).padding(.bottom, 8)
    } else if let patch = patches[file.path] {
      VStack(alignment: .leading, spacing: 0) {
        ScrollView(.horizontal) {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(patch.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
              Text(verbatim: String(line)).font(UIStyle.monoMeta)
                .foregroundStyle(color(line))
                .fixedSize(horizontal: true, vertical: false)
            }
          }.padding(.horizontal, 12).padding(.vertical, 10)
        }.textSelection(.enabled)
        if patch.truncated {
          Text("The rest of this file's diff isn't shown.").role(.meta)
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
      }.background(p.background).overlay(alignment: .top) { Divider().overlay(p.line) }
    } else {
      ProgressView().controlSize(.small).padding(.horizontal, 32).padding(.bottom, 8)
    }
  }

  private func color(_ line: Substring) -> Color {
    if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ")
      || line.hasPrefix("index ")
    {
      return p.faint
    }
    if line.hasPrefix("+") { return p.success }
    if line.hasPrefix("-") { return p.danger }
    if line.hasPrefix("@@") { return p.accent }
    return p.secondary
  }

  private func toggle(_ file: DiffFile) {
    if expanded.remove(file.path) != nil { return }
    expanded.insert(file.path)
    guard patches[file.path] == nil, !file.isBinary else { return }
    let id = review.id
    Task {
      let patch = await store.patch(reviewID: id, path: file.path)
      patches[file.path] = patch ?? ("This file's diff couldn't be read.", false)
    }
  }
}

/// "Codex wants to change files in Signal": what it wants to do, then Allow once, Always in
/// <project>, or Decline with a reply. The buttons are never disabled: an answer given while the
/// task works is held and applied when its current step ends (EditReview.resolve).
struct ApprovalCard: View {
  @ObservedObject var agent: AgentModel
  var review: TurnReview
  @ObservedObject private var store = EditReview.shared
  @State private var denying = Self.previewReply
  @State private var reply = Self.previewReply ? "Keep the strings where they are." : ""
  @State private var replyFocused = false
  @Environment(\.palette) var p

  /// `--ui-edit-held reply`: the Decline reply open, with words in it.
  static let previewReply: Bool = {
    let arguments = CommandLine.arguments
    guard arguments.contains("--ui-preview"), let i = arguments.firstIndex(of: "--ui-edit-held") else { return false }
    return arguments.indices.contains(i + 1) && arguments[i + 1] == "reply"
  }()

  /// The AI app that asks: this chat's when it is open, else the task's own.
  var asker: String {
    if agent.conversationID == review.threadID { return agent.provider.name }
    return agent.conversations.first { $0.id == review.threadID }?.provider.name ?? "Your AI app"
  }
  var body: some View {
    let open = review.resolution == nil
    VStack(alignment: .leading, spacing: 10) {
      Text(open ? "\(asker) wants to change files in \(review.projectName)" : "Approval").font(UIStyle.body.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityValue(ApprovalEvents.summary(review.approvals.count))
      VStack(alignment: .leading, spacing: 4) {
        ForEach(review.approvals.prefix(6)) { approval in
          HStack(spacing: 6) {
            Text(verbatim: approval.label).font(UIStyle.monoMeta).foregroundStyle(p.secondary)
              .lineLimit(1).truncationMode(.middle)
            if ApprovalEvents.isOutsideProject(approval.target) {
              Text("Outside \(review.projectName)").font(UIStyle.micro).foregroundStyle(p.danger)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(p.track, in: Capsule())
                .help("This file is outside the project. Allowing doesn't cover it.")
            }
          }.accessibilityElement(children: .combine)
        }
        if review.approvals.count > 6 {
          Text("and \(review.approvals.count - 6) more").role(.micro)
        }
      }
      if let resolution = review.resolution {
        Text(resolved(resolution)).role(.meta)
      } else if denying {
        HStack(spacing: 8) {
          ComposerInput(placeholder: "Tell \(asker) what to do instead", text: $reply,
            focused: $replyFocused, maxHeight: 120, label: "Reply to \(asker)’s approval request") { _ in deny() }
            .textInputCursor().padding(8)
            .background(p.track, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
          Button("Send") { deny() }.buttonStyle(PrimaryButton())
          Button("Cancel") { denying = false }.buttonStyle(QuietButton())
        }
        if let held = store.held.held(reviewID: review.id) { Text(heldLine(held.resolution)).role(.meta) }
      } else {
        Text(ApprovalEvents.scope(project: review.projectName)).role(.meta)
          .fixedSize(horizontal: false, vertical: true)
        if review.approvals.contains(where: { ApprovalEvents.isOutsideProject($0.target) }) {
          Text("Files outside \(review.projectName) stay off limits either way.").role(.meta)
            .fixedSize(horizontal: false, vertical: true)
        }
        // While an answer is held, its button is the marked one, so the card shows what was chosen.
        let chosen = store.held.held(reviewID: review.id)?.resolution
        // “Always in <project>” names a lasting scope, so it never truncates: the row breaks
        // into two, then three, and on the narrowest card the name wraps inside its button.
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) {
            allowOnce(chosen)
            always(chosen, name: review.projectName)
            Spacer(minLength: 0)
            decline(chosen)
          }
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) { allowOnce(chosen); always(chosen, name: review.projectName) }
            decline(chosen)
          }
          VStack(alignment: .leading, spacing: 8) {
            allowOnce(chosen)
            always(chosen, name: review.projectName)
            decline(chosen)
          }
          VStack(alignment: .leading, spacing: 8) {
            allowOnce(chosen)
            always(chosen, name: review.projectName, wraps: true)
            decline(chosen)
          }
        }
        if let chosen {
          Text(heldLine(chosen)).role(.meta).fixedSize(horizontal: false, vertical: true)
        }
        if let note = store.answerNotes[review.id] {
          Text(note).role(.meta).foregroundStyle(p.danger).fixedSize(horizontal: false, vertical: true)
        }
      }
    }.padding(12)
      .background(open ? p.warning.opacity(0.1) : p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Needs your approval")
  }

  private func allowOnce(_ chosen: TurnReview.Resolution?) -> some View {
    choice("Allow once", .allowedOnce, chosen: chosen, primary: chosen == nil) {
      EditReview.shared.resolve(reviewID: review.id, .allowedOnce, agent: agent)
    }.help("The next reply may edit any file in \(review.projectName). Only that reply.")
  }
  /// “Always in <project>”, with the full name in the help and for VoiceOver.
  /// One line while the card tries its rows (so a row that would cut the name is passed over);
  /// `wraps` on the narrowest card, where the name goes onto a second line instead.
  @ViewBuilder private func always(_ chosen: TurnReview.Resolution?, name: String, wraps: Bool = false) -> some View {
    if review.projectID != nil {
      choice("Always in \(name)", .alwaysAllowed, chosen: chosen, primary: false) {
        EditReview.shared.resolve(reviewID: review.id, .alwaysAllowed, agent: agent)
      }.lineLimit(wraps ? nil : 1).fixedSize(horizontal: false, vertical: wraps)
        .help("Stop asking before edits in \(review.projectName): any file in it. Take it back with Ask again under Serein asks before.")
        .accessibilityLabel("Always allow in \(review.projectName)")
    }
  }
  private func decline(_ chosen: TurnReview.Resolution?) -> some View {
    choice("Decline…", .denied, chosen: chosen, primary: false) { denying = true }
  }

  /// One answer button: the primary style for the suggested answer, or for the answer that is
  /// held (with a checkmark); otherwise the quiet style with a hairline edge, so a choice on a
  /// row of its own still reads as a button, its box on the same leading edge as the primary.
  @ViewBuilder private func choice(_ title: String, _ resolution: TurnReview.Resolution,
                                   chosen: TurnReview.Resolution?, primary: Bool,
                                   action: @escaping () -> Void) -> some View {
    let marked = chosen == resolution
    let label = HStack(spacing: 4) {
      if marked { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true) }
      Text(title)
    }
    if marked || primary {
      Button(action: action) { label }.buttonStyle(PrimaryButton())
        .accessibilityAddTraits(marked ? .isSelected : [])
    } else {
      Button(action: action) { label }.buttonStyle(QuietButton())
        .background(p.track, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
    }
  }

  private func deny() {
    EditReview.shared.resolve(reviewID: review.id, .denied, agent: agent, reply: reply)
    denying = false
  }

  /// An answer given while the task works, waiting for its current step to end.
  private func heldLine(_ resolution: TurnReview.Resolution) -> String {
    switch resolution {
    case .allowedOnce: return "Allowed once. Serein applies this when the current step ends."
    case .alwaysAllowed: return "Always allowed in \(review.projectName). Serein applies this when the current step ends."
    case .denied: return "Declined. Your reply is sent when the current step ends."
    }
  }

  private func resolved(_ resolution: TurnReview.Resolution) -> String {
    switch resolution {
    case .allowedOnce: return "Allowed edits anywhere in \(review.projectName) for one reply."
    case .alwaysAllowed: return "Always allowed in \(review.projectName). Ask again under Serein asks before."
    case .denied: return "Declined. Your reply was sent."
    }
  }
}

/// A short toast after a turn that changed files; ⌘Z or the button undoes it. Shown through the
/// shared toast stack (ToastCenter.swift), only while its thread is open.
struct TurnUndoToast: View {
  @ObservedObject var agent: AgentModel
  @ObservedObject private var store = EditReview.shared
  static let toastID = "turn-undo"
  var body: some View {
    Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
      .onAppear {
        ToastCenter.shared.visibleThread = agent.conversationID
        sync()
      }
      .onDisappear { ToastCenter.shared.visibleThread = nil }
      .onChange(of: store.toast) { _, _ in sync() }
      .onChange(of: agent.conversationID) { _, id in ToastCenter.shared.visibleThread = id }
  }
  func sync() {
    guard let toast = store.toast else {
      ToastCenter.shared.dismiss(Self.toastID)
      return
    }
    let hub = agent.hub
    ToastCenter.shared.show(
      toast.text, id: Self.toastID, actionTitle: "Undo", thread: toast.threadID, commandZ: true,
      duration: nil
    ) { EditReview.shared.perform(.undo, reviewID: toast.reviewID, hub: hub) }
  }
}

/// Settings › AI apps: projects where edits are always allowed, each revocable.
struct EditApprovalSettings: View {
  @ObservedObject var browser: BrowserModel
  @State private var allowed = ProjectEditApprovals.all()
  @Environment(\.palette) var p
  var body: some View {
    SettingsGroup("Project edits") {
      if allowed.isEmpty {
        Text("No project is always allowed. Choose Always allow on an approval card to add one.")
          .foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      }
      ForEach(allowed, id: \.self) { id in
        HStack {
          Text(browser.projects.first { $0.id == id }?.name ?? "Removed project")
          Spacer()
          Button("Ask again") {
            ProjectEditApprovals.revoke(id)
            allowed = ProjectEditApprovals.all()
          }.buttonStyle(QuietButton()).accessibilityLabel("Ask again before edits")
        }
      }
      SettingsNote(
        "Before each turn that may edit a project, Serein saves a private git snapshot so you can review and undo the changes. It never commits, pushes or changes git settings."
      )
    }
  }
}

/// ⌘Z for the undo toast, only while no text field, text view or web page has keyboard focus,
/// so the composer and web forms keep their own undo.
struct UndoKeyMonitor: NSViewRepresentable {
  var action: () -> Void
  func makeNSView(context: Context) -> MonitorView { MonitorView(action: action) }
  func updateNSView(_ view: MonitorView, context: Context) { view.action = action }
  static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

  final class MonitorView: NSView {
    var action: () -> Void
    private var monitor: Any?
    init(action: @escaping () -> Void) {
      self.action = action
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stop()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, let window = self.window, event.window === window,
          event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
          event.charactersIgnoringModifiers?.lowercased() == "z",
          !UndoKeyMonitor.textHasFocus(window.firstResponder)
        else { return event }
        self.action()
        return nil
      }
    }
    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
  /// Text fields, text views and web pages (which may hold a focused form field) keep ⌘Z.
  static func textHasFocus(_ responder: NSResponder?) -> Bool {
    var current = responder
    while let view = current {
      if view is NSText || view is NSTextField || view is WKWebView { return true }
      current = view.nextResponder
    }
    return false
  }
}
