import AppKit
import SereinCore
import SwiftUI

/// A post for X under the reply that drafted it (`post_draft`): each post as it will read on X,
/// with mentions, tags and links in the accent and X's weighted count, a thread's posts joined by
/// a rail. Copy puts the words on the clipboard; Open in X opens X's own composer with the first
/// post filled in. Serein never posts.
struct PostDraftCard: View {
  let draft: PostDraft
  @State private var copied: Int?
  @Environment(\.palette) private var p

  private var thread: Bool { draft.posts.count > 1 }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 6) {
        Text(verbatim: "𝕏").font(UIStyle.font(13, weight: .bold)).foregroundStyle(p.ink).accessibilityHidden(true)
        Text(verbatim: thread ? "Thread for X · \(draft.posts.count) posts" : "Post for X")
          .font(AssistantType.meta).foregroundStyle(p.secondary)
      }
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(draft.posts.enumerated()), id: \.offset) { index, text in
          row(text, index: index, last: index == draft.posts.count - 1)
        }
      }
      HStack(spacing: 10) {
        Text(verbatim: "Nothing is posted until you post it.").font(AssistantType.meta).foregroundStyle(p.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button { copy(draft.plain, as: -1) } label: {
          Text(copied == -1 ? "Copied" : (thread ? "Copy all" : "Copy")).font(AssistantType.meta).foregroundStyle(p.secondary)
            .monospacedDigit().linkTarget()
        }.buttonStyle(.pressable)
        if let url = PostDraft.composeURL(draft.posts[0]) {
          ChatCardSolidButton(title: "Open in X") { _ = NSWorkspace.shared.open(url) }
            .help(thread ? "Opens X with the first post; copy the others in after it." : "Opens X with the post filled in.")
        }
      }
    }
    .padding(14)
    .frame(maxWidth: AssistantMetrics.cardWide)
    .assistantCard(p)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(thread ? "Draft thread for X, \(draft.posts.count) posts" : "Draft post for X")
  }

  private func row(_ text: String, index: Int, last: Bool) -> some View {
    let count: Int = PostDraft.weightedCount(text)
    let over: Bool = count > PostDraft.limit
    return HStack(alignment: .top, spacing: 10) {
      VStack(spacing: 4) {
        InterfaceIcon(systemName: "person.fill", size: 14).foregroundStyle(p.secondary)
          .frame(width: 32, height: 32).background(p.track, in: Circle())
        if !last { Capsule().fill(p.line).frame(width: 2).frame(maxHeight: .infinity) }
      }
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(verbatim: "You").font(AssistantType.name).foregroundStyle(p.ink)
          Text(verbatim: thread ? "· \(index + 1)/\(draft.posts.count)" : "· draft").font(AssistantType.meta).foregroundStyle(p.secondary)
            .monospacedDigit()
          Spacer(minLength: 8)
          Text(verbatim: "\(count)/\(PostDraft.limit)").font(AssistantType.figures)
            .foregroundStyle(over ? p.danger : p.secondary)
            .help(over ? "Over X's limit by \(count - PostDraft.limit)." : "X's count: links are 23, emoji 2.")
            .accessibilityLabel(over ? "\(count) characters, over the limit of \(PostDraft.limit)" : "\(count) of \(PostDraft.limit) characters")
          if thread {
            Button { copy(text, as: index) } label: {
              InterfaceIcon(systemName: copied == index ? "checkmark" : "doc.on.doc", size: 12).foregroundStyle(p.secondary)
                .frame(width: 20, height: 20).contentShape(Rectangle())
            }.buttonStyle(AssistantPressStyle()).help("Copy post \(index + 1)").accessibilityLabel("Copy post \(index + 1)")
          }
        }
        Text(Self.styled(text, accent: p.accent)).font(UIStyle.font(14)).foregroundStyle(p.ink)
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          .padding(.bottom, last ? 0 : 14)
      }
    }
  }

  private func copy(_ text: String, as which: Int) {
    MessageActions.copy(text)
    copied = which
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      if copied == which { copied = nil }
    }
  }

  /// The words with @mentions, #tags and links in the accent, as X draws them.
  static func styled(_ text: String, accent: Color) -> AttributedString {
    var out = AttributedString(text)
    let pattern = #"(https?://[^\s]+|[@#][A-Za-z0-9_]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return out }
    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
      guard let range = Range(match.range, in: text), let found = Range(range, in: out) else { continue }
      out[found].foregroundColor = accent
    }
    return out
  }
}

/// One mail send card's draft while the card waits: what Serein wrote, and the fields as the
/// person has them now. Mail sends `draft` when they allow it.
@MainActor final class EditableEmail: ObservableObject {
  let original: EmailDraft
  @Published var draft: EmailDraft
  fileprivate let key: String
  fileprivate init(_ draft: EmailDraft, key: String) {
    original = draft
    self.draft = draft
    self.key = key
  }
  var edited: Bool { draft != original }
  /// Why Mail could not send the fields as they are, or nil when it can.
  var problem: String? {
    do { _ = try draft.mail(); return nil } catch { return error.localizedDescription }
  }
}

/// The drafts of the mail send cards that wait. mail_send offers one before it asks and closes it
/// after; the card finds it by what it shows (its title, detail and chat, as `ApprovalLife.Denials`
/// keys a card).
/// shortcut: keyed by the card's words because the approval has no draft field yet; move it onto
/// `RelayOrchestrator.Approval` (as `handoff` is) when that file is open to this change.
@MainActor final class EmailDrafts {
  static let shared = EmailDrafts()
  private var open: [String: EditableEmail] = [:]

  /// nil while an identical card already waits: that card keeps its draft, and this one sends
  /// exactly what it shows.
  func offer(_ draft: EmailDraft, title: String, detail: String, thread: String?) -> EditableEmail? {
    let key = ApprovalLife.Denials.key(title: title, detail: detail, thread: thread)
    guard open[key] == nil else { return nil }
    let email = EditableEmail(draft, key: key)
    open[key] = email
    return email
  }
  func draft(for approval: RelayOrchestrator.Approval) -> EditableEmail? {
    open[ApprovalLife.Denials.key(title: approval.title, detail: approval.detail, thread: approval.threadID)]
  }
  func close(_ email: EditableEmail) {
    if open[email.key] === email { open[email.key] = nil }
  }
}

/// A mail send card's draft, editable in place (affectUI Email Draft): Subject and the message,
/// each a plain field. To, Cc and Bcc stay the card's own rows, as plain text with their
/// new-recipient marks: an edited address would skip that check. An edit says so, with Undo edits;
/// a field Mail could not send says why. Esc leaves a field. `typing` tells the dock a field has
/// the keyboard, so a number typed there never answers the card.
struct EmailDraftFields: View {
  @ObservedObject var email: EditableEmail
  @Binding var typing: Bool
  @FocusState private var at: Field?
  @Environment(\.palette) private var p
  private enum Field { case subject, body }

  var body: some View {
    let problem = email.problem
    VStack(alignment: .leading, spacing: 8) {
      line("Subject", .subject, $email.draft.subject)
      TextField("Message", text: $email.draft.body, axis: .vertical).textFieldStyle(.plain)
        .font(UIStyle.font(14)).foregroundStyle(p.ink).lineSpacing(3).lineLimit(3...12)
        .focused($at, equals: .body).onExitCommand { at = nil }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(p.track, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Message")
      if let problem {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          InterfaceIcon(systemName: "exclamationmark.triangle", size: 11).foregroundStyle(p.warning)
          Text(problem).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
        }.font(UIStyle.meta).accessibilityElement(children: .combine)
      } else if email.edited {
        HStack(spacing: 8) {
          Text("Edited. Mail sends your words.").font(UIStyle.meta).foregroundStyle(p.secondary)
          Button("Undo edits") { email.draft = email.original }
            .buttonStyle(.pressable).font(UIStyle.meta).foregroundStyle(p.accent).fixedSize()
        }
      }
    }
    .onChange(of: at) { _, field in typing = field != nil }
    .onDisappear { typing = false }
  }

  private func line(_ label: String, _ field: Field, _ text: Binding<String>) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label).foregroundStyle(p.secondary).frame(width: 96, alignment: .leading)
      TextField(label, text: text).textFieldStyle(.plain).foregroundStyle(p.ink)
        .focused($at, equals: field).onExitCommand { at = nil }
        .accessibilityLabel(label)
    }.font(UIStyle.font(14))
  }
}
