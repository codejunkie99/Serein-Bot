import AppKit
import SereinCore
import SwiftUI

/// Shared state for the History routes. Selecting a segment does not change Back's target.
@MainActor final class HistoryNavigation: ObservableObject {
  static let shared = HistoryNavigation()
  @Published var projectID: String?
  private(set) var returnSection = ShellSection.serein
  func changed(from old: String, to new: String) {
    if HistorySegment(section: new) != nil, HistorySegment(section: old) == nil { returnSection = old }
    if new != ShellSection.chats { projectID = nil }
  }
  func open(_ segment: HistorySegment, browser: BrowserModel, projectID: String? = nil) {
    if HistorySegment(section: browser.section) == nil { returnSection = browser.section }
    self.projectID = nil
    browser.section = segment.displayed.section
  }
  func back(_ browser: BrowserModel) {
    let route = returnSection
    if route == ShellSection.browser || route == ShellSection.start {
      if let tab = browser.active { browser.show(tab) } else { browser.section = ShellSection.serein }
    } else if route == ShellSection.agent, browser.agentTabs.focused == nil {
      browser.section = ShellSection.serein
    } else { browser.section = route }
  }
}

struct ChatSearchField: View {
  @Binding var query: String
  var prompt = "Find a chat"
  @Environment(\.palette) private var p
  var body: some View {
    HStack(spacing: 8) {
      InterfaceIcon(systemName: "magnifyingglass", size: 13).foregroundStyle(p.secondary)
      TextField(prompt, text: $query).textFieldStyle(.plain).font(UIStyle.body)
        .accessibilityLabel(prompt)
      if !query.isEmpty {
        Button { query = "" } label: { InterfaceIcon(systemName: "xmark.circle.fill", size: 12) }
          .buttonStyle(.pressable).help("Clear search").accessibilityLabel("Clear search")
      }
    }.padding(.horizontal, 12).frame(height: 36).background(p.card, in: Capsule())
  }
}

/// Inspecting a saved chat never redirects the assistant's active turn. Resuming remains an
/// explicit action after that turn finishes, and the current chat is one click away.
struct SereinPastChatView: View {
  let id: String
  let style: RelayPanelView.Style
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @ObservedObject var relay: RelayOrchestrator
  let controller: RelayController
  @ObservedObject private var hub: AgentHub
  @Environment(\.palette) private var p
  init(id: String, style: RelayPanelView.Style, browser: BrowserModel, agent: AgentModel,
       relay: RelayOrchestrator, controller: RelayController) {
    self.id = id; self.style = style; self.browser = browser; self.agent = agent
    self.relay = relay; self.controller = controller; hub = agent.hub
  }
  var chat: Conversation? { agent.openThreadItem(id) }
  var body: some View {
    VStack(spacing: 0) {
      if style == .side {
        SereinFullHeader(relay: relay, agent: agent, controller: controller, style: .side)
          .padding(.horizontal, 12).frame(height: 44)
        Divider().overlay(p.line)
      }
      VStack(alignment: .leading, spacing: 8) {
        Text(chat.map(ProjectChatIndex.title) ?? "Chat unavailable").font(UIStyle.bodyStrong).lineLimit(2)
        if relay.working {
          Text("Serein is still replying in your current chat.").role(.meta)
        }
        HStack(spacing: 12) {
          // Serein keeps one conversation: an earlier chat is read here, never continued.
          Button("Back to Serein") { SereinRouter.backToChat() }.buttonStyle(QuietButton())
        }
      }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(p.card)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: AssistantMetrics.turnInnerGap) {
          if let chat {
            let breaks = ChatTurns.breaks(chat.messages)
            ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
              TurnLead(message: message, after: index > 0 ? chat.messages[index - 1] : nil, breaks: breaks)
              let next = index + 1 < chat.messages.count ? chat.messages[index + 1] : nil
              let quiet = next.map { $0.role == "assistant" && RelayAutomatic.isQuiet(reply: $0.text) } ?? false
              // As the current chat shows them: a turn Serein started itself is its short line
              // (nothing when it had nothing to say, or when it was a check-in or the brief), and a
              // reply with nothing in it is hidden.
              if let range = message.condensed {
                // Read only here: Show, but Undo belongs to the chat once it is continued.
                CondensedDivider(summary: message, range: range, userWidth: style == .full ? 560 : 280)
              } else if message.role == "you", let automatic = RelayAutomatic.kind(of: message.text) {
                if !quiet, RelayAutomatic.showsLine(automatic) { AutomaticTurnLine(prompt: message.text, kind: automatic) }
              } else if !(message.role == "assistant" && RelayAutomatic.hidesReply(message, after: chat.messages[..<index])) {
                VStack(alignment: .leading, spacing: AssistantMetrics.turnInnerGap) {
                  ThreadMessageContent(message: message, placeholder: "", userWidth: style == .full ? 560 : 280,
                                       showsCopy: true, palette: p, showsActivities: true).equatable()
                  if let attached = message.attached, !attached.isEmpty {
                    Text(attached.joined(separator: " · ")).font(UIStyle.meta).foregroundStyle(p.secondary)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                }
              }
            }
          } else { Text("This chat is no longer available.").role(.meta) }
        }.padding(16).frame(maxWidth: UIStyle.composerWidth).frame(maxWidth: .infinity)
      }
    }.background(p.background).accessibilityLabel("Past chat, read only")
  }
}
