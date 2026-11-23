import SwiftUI

/// Edit and rerun on a message of the user's: Edit opens its words in place, and Save rewinds the
/// chat to before it (`AgentModel.rewind`) and sends the new words as a new run, which asks for
/// every step again.
@MainActor enum MessageEdit {
  static let note = "Approvals from the earlier run do not carry over."
  /// The line after Save, with the waiting messages Save dropped.
  static func announce(cleared: Int) {
    let queued = cleared == 0 ? "" : cleared == 1
      ? " 1 queued message was cleared." : " \(cleared) queued messages were cleared."
    ToastCenter.shared.show(note + queued)
  }
  /// Whether a turn Save replaces (the edited message's or a later one's) left project file
  /// changes its card could still undo: the card goes with the rewind, the changes stay on disk.
  /// Folded messages count, since `ChatCondense.before` drops the summaries after the message.
  static func laterFileChanges(from messageID: String, in transcript: [AgentMessage]) -> Bool {
    let all = ChatCondense.expanded(transcript)
    guard let at = all.firstIndex(where: { $0.id == messageID }) else { return false }
    let replaced = Set(all[at...].map(\.id))
    return EditReview.shared.reviews.contains { review in
      review.tracked && !review.undone && !review.files.isEmpty && review.messageID.map(replaced.contains) == true
    }
  }
}

/// Edit, beside Copy on a message of the user's, shown when Copy is.
struct MessageEditButton: View {
  var isVisible = true
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      InterfaceIcon(systemName: "pencil", size: 14).frame(width: 18, height: 18)
    }.buttonStyle(QuietButton())
      .help("Edit and send again")
      .accessibilityLabel("Edit message")
      .accessibilityHint("Saving replaces the replies after this message and asks for every approval again.")
      .opacity(isVisible ? 1 : 0)
      .allowsHitTesting(isVisible)
      .accessibilityHidden(!isVisible)
  }
}

/// The words being edited in place of the bubble, with Cancel and Save. Return saves and
/// Shift-Return adds a line, as in the composer.
struct MessageEditor: View {
  @State var text: String
  /// The message carried attachments: they rode only with its own turn, so the rerun goes without.
  var attached = false
  /// A replaced turn changed project files (MessageEdit.laterFileChanges): they stay after Save.
  var changedFiles = false
  /// Gives back why the words were refused, when they were: the editor stays open and says it.
  let save: (String) -> String?
  let cancel: () -> Void
  @State private var focused = true
  @State private var refusal: String?
  @Environment(\.palette) private var p
  private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  private func send() {
    refusal = save(text)
    // Said each time: a second Save on the same words is refused again.
    if let refusal { ChatAnnouncement.post(refusal, priority: .high) }
  }
  var body: some View {
    VStack(alignment: .trailing, spacing: 8) {
      ComposerInput(placeholder: "Your message", text: $text, focused: $focused, maxHeight: 200,
        label: "Edit your message") { _ in if !empty { send() } }
        .textInputCursor().padding(10)
        .background(p.background, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: UIStyle.controlRadius).stroke(p.borderStrong))
      Text(MessageEdit.note + (attached ? " Its attachments are not sent again." : "")
        + (changedFiles ? " File changes from the later replies stay in the project; undo them from their cards first if you need to." : ""))
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      if let refusal {
        Text(refusal).font(UIStyle.meta).foregroundStyle(p.danger).fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 8) {
        Button("Cancel", action: cancel).buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
          .accessibilityLabel("Cancel editing")
        Button("Save") { send() }.buttonStyle(PrimaryButton()).disabled(empty)
          .accessibilityLabel("Save and send again")
      }
    }.accessibilityElement(children: .contain).accessibilityLabel("Editing your message")
      .onChange(of: text) { refusal = nil }
  }
}
