import SereinCore
import SwiftUI

/// Research runs in isolated tabs by default. The user can allow signing in for the next run of
/// one thread: its tabs share a store of their own, empty at the start, so a sign-in made in one
/// holds for that run. The user's browser cookies never go in. The approval is used up when that
/// run starts.
@MainActor final class WebTaskGrant: ObservableObject {
  static let shared = WebTaskGrant()
  @Published private(set) var granted: Set<String> = []
  func grant(thread: String) { granted.insert(thread) }
  func revoke(thread: String) { granted.remove(thread) }
  func isGranted(thread: String) -> Bool { granted.contains(thread) }
  /// True once, for a research run in a thread the user approved.
  func consume(thread: String, mode: TaskMode) -> Bool {
    guard mode == .research, granted.contains(thread) else { return false }
    granted.remove(thread)
    return true
  }
}

/// Confirmation shown before a web task's tabs may hold a sign-in the user makes in them.
struct WebTaskGrantSheet: View {
  @ObservedObject var agent: AgentModel
  var close: () -> Void
  @Environment(\.palette) var p
  var name: String { agent.provider.shortName }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        InterfaceIcon(systemName: "person.badge.key", size: 18).foregroundStyle(p.accent)
        Text("Allow signing in for this task?").font(UIStyle.section)
      }
      VStack(alignment: .leading, spacing: 8) {
        point("eye", "\(name) works in tabs with their own cookies. They start signed out, without your browser’s sign-ins.")
        point("person.badge.key", "If a site needs you, it asks you to sign in in its tab. That site sees you for the rest of this task.")
        point("sidebar.left", "Every tab it opens shows in the sidebar. You can take one over at any time.")
        point("hand.raised", "It stops before paying, ordering or sending unless your request says to.")
        point("lock", "Passwords, card details, codes and CAPTCHAs stay yours. It hands those steps back.")
        point("arrow.uturn.backward", "This covers the next task only. Later tasks are isolated again.")
      }
      Toggle("Let it click and type on sites", isOn: $agent.allowActions)
        .font(UIStyle.meta).toggleStyle(.checkbox)
      HStack {
        Spacer()
        Button("Cancel", action: close).buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
        Button("Allow signing in") {
          WebTaskGrant.shared.grant(thread: agent.conversationID)
          agent.autoRouting = false
          agent.mode = .research
          agent.projectID = nil
          close()
        }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
      }
    }.padding(20).frame(width: UIStyle.wide(420)).background(p.panel).foregroundStyle(p.ink)
  }
  func point(_ icon: String, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      InterfaceIcon(systemName: icon, size: 12).foregroundStyle(p.secondary).frame(width: 16)
      Text(text).font(UIStyle.meta).foregroundStyle(p.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }.accessibilityElement(children: .combine)
  }
}

/// A quiet line in the composer while an approval is waiting for the next run.
struct WebTaskGrantChip: View {
  @ObservedObject var agent: AgentModel
  @ObservedObject private var grant = WebTaskGrant.shared
  @Environment(\.palette) var p
  var body: some View {
    if grant.isGranted(thread: agent.conversationID) {
      HStack(spacing: 6) {
        InterfaceIcon(systemName: "person.badge.key", size: 11).foregroundStyle(p.accent)
        Text("You can sign in during the next task").font(UIStyle.micro).foregroundStyle(p.secondary)
        Button("Undo") { grant.revoke(thread: agent.conversationID) }
          .buttonStyle(QuietButton()).font(UIStyle.micro)
          .accessibilityLabel("Keep the next task isolated")
      }.padding(.horizontal, 14).padding(.bottom, 8)
    }
  }
}
