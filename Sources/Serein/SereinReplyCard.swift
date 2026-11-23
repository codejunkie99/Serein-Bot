import AppKit
import SereinCore
import SwiftUI

/// The card under the ⌥Space bar (F6): Serein answers in place, and the window you were in stays
/// in front. Top-anchored, up to 360 points, scrolling past that. It holds the exchange asked from
/// the bar (your words, the streamed reply, any task it started), then whatever waits on you: an
/// approval (with Later), the one-time consent card, a question, a reminder. Its footer opens
/// Serein's chat (“Show in chat” for the in-window bar) and copies the reply. Reopened within two
/// minutes, the last exchange shows collapsed to one line; while its turn still runs behind a bar
/// that stepped aside (BarWork), it shows whole, with its progress and Stop.
struct SereinReplyCard: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject var controller: RelayController
  @ObservedObject private var hub: AgentHub
  @Environment(\.palette) private var p
  /// The card's content height, so the scroll view is only as tall as what it holds.
  @State private var contentHeight: CGFloat = 0
  static let maxHeight: CGFloat = 360

  init(relay: RelayOrchestrator, controller: RelayController) {
    self.relay = relay
    self.controller = controller
    hub = relay.agent.hub
  }

  /// Something waits on the user in the card.
  private var waiting: Bool {
    !relay.approvals.isEmpty || relay.consentWaiting || !relay.questionForms.isEmpty || !relay.dueReminders.isEmpty
      || !relay.missedRuns.isEmpty
  }
  private var shows: Bool { controller.barExchange != nil || waiting }

  var body: some View {
    if shows {
      VStack(spacing: 0) {
        if let exchange = controller.barExchange, exchange.collapsed, !waiting {
          collapsed(exchange)
        } else {
          ScrollView {
            content
              .padding(12)
              .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
          }
          .frame(height: min(max(contentHeight, 1), Self.maxHeight))
          Rectangle().fill(p.line).frame(height: 1)
          footer
        }
      }
      .barGlass(in: RoundedRectangle(cornerRadius: UIStyle.panelRadius, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: UIStyle.panelRadius, style: .continuous))
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Serein’s reply")
      // A bar opened only for an answer goes once nothing waits: `RelayController` watches that,
      // since this view leaves in the same update.
    }
  }

  // MARK: the exchange

  /// Your words, then the reply: the live turn while Serein replies, else the saved chat.
  @ViewBuilder private var content: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let exchange = controller.barExchange {
        let held = relay.held.last { $0.message.text == exchange.prompt && $0.message.at >= exchange.at.addingTimeInterval(-2) }
        HStack {
          Spacer(minLength: 60)
          VStack(alignment: .trailing, spacing: 4) {
            Text(exchange.prompt).font(UIStyle.meta).foregroundStyle(p.ink).lineLimit(4)
              .padding(.horizontal, 10).padding(.vertical, 6)
              .background(p.bubble, in: RoundedRectangle(cornerRadius: UIStyle.bubbleRadius))
            // Spoken words that found their assistant say who has them.
            if let to = exchange.to {
              Text("To \(to)").font(UIStyle.micro).foregroundStyle(p.secondary).lineLimit(1)
                .accessibilityLabel("Sent to \(to)")
            }
            // Held, as in the chat: the chip says it is kept and when it goes.
            if let held { heldChip(held.message.reason) }
          }
        }
        if let held {
          // Offline, the bar's Offline chip and the bubble's chip already say when it goes.
          if held.message.reason == .noAI { heldLine(held.message.reason) }
        } else if let run = relay.run {
          SereinBarRunReply(run: run, exchange: exchange, relay: relay, p: p)
        } else {
          SereinBarReply(messages: relay.transcript, exchange: exchange, working: relay.working, phase: nil,
                         relay: relay, p: p, openLabel: controller.openLabel)
        }
      }
      ForEach(relay.approvals) { approval in
        ApprovalCardSlot(approval: approval, relay: relay, controller: controller, p: p, later: { controller.later() })
      }
      if relay.consentWaiting { RelayConsentCard(relay: relay, p: p) }
      ForEach(relay.questionForms) { form in QuestionFormCard(form: form, relay: relay, p: p) }
      ForEach(relay.dueReminders, id: \.id) { reminder in
        HStack(spacing: 8) {
          InterfaceIcon(systemName: "bell", size: 12).foregroundStyle(p.warning)
          Text(reminder.text).font(UIStyle.meta).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button("Done") { relay.dueReminders.removeAll { $0.id == reminder.id } }.buttonStyle(QuietButton())
        }
      }
      // Scheduled runs that did not happen at their time, as Serein's chat lists them.
      ForEach(relay.missedRuns) { missed in
        HStack(spacing: 8) {
          InterfaceIcon(systemName: "moon", size: 12).foregroundStyle(p.warning).accessibilityHidden(true)
          Text(missed.line).font(UIStyle.meta).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button("Skip") { relay.skipMissed(missed) }.buttonStyle(QuietButton())
            .accessibilityLabel("Skip \(missed.name)")
          Button("Run now") { relay.runMissed(missed) }.buttonStyle(QuietButton())
            .disabled(relay.missedBlocked(missed))
            .help(RelayPanelView.missedHelp(relay))
            .accessibilityLabel("Run \(missed.name) now")
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The chip under a held bubble, as Serein's chat shows it.
  private func heldChip(_ reason: HeldMessage.Reason) -> some View {
    HStack(spacing: 5) {
      InterfaceIcon(systemName: reason == .offline ? "wifi.slash" : "clock", size: 10)
      Text(HeldMessage.chip(reason)).font(UIStyle.meta).lineLimit(1)
    }.foregroundStyle(p.secondary).padding(.horizontal, 8).frame(height: 22)
      .background(p.track, in: Capsule())
      .accessibilityElement(children: .combine)
  }
  /// A message held back: no AI app (with Connect), or offline.
  private func heldLine(_ reason: HeldMessage.Reason) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(HeldMessage.barLine(reason)).font(UIStyle.meta).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
      if reason == .noAI {
        Button { controller.openInSerein() } label: { Text("Connect").font(UIStyle.metaStrong).foregroundStyle(p.accent) }
          .buttonStyle(QuietButton()).fixedSize().help("Open Serein to connect an AI app")
      }
      Spacer(minLength: 0)
    }
  }

  /// The reply's words, for Copy.
  private var replyText: String {
    guard let exchange = controller.barExchange else { return "" }
    let messages = relay.run?.transcript ?? relay.transcript
    return SereinBarReply.replies(messages, exchange: exchange).map(\.text).joined(separator: "\n\n")
  }

  private var footer: some View {
    HStack(spacing: 8) {
      Button { controller.openInSerein() } label: {
        Text(controller.openLabel).font(UIStyle.metaStrong).foregroundStyle(p.ink)
      }.buttonStyle(QuietButton()).fixedSize()
        .help(controller.inWindow ? "Show this in Serein’s chat" : "Open Serein’s window on this chat")
      Spacer(minLength: 0)
      let text = replyText
      if !text.isEmpty {
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        } label: {
          Text("Copy").font(UIStyle.metaStrong).foregroundStyle(p.ink)
        }.buttonStyle(QuietButton()).fixedSize().help("Copy the reply")
      }
    }.padding(.horizontal, 8).frame(height: 36)
  }

  /// Reopened within two minutes: the last exchange on one line, with Open in Serein.
  private func collapsed(_ exchange: RelayController.BarExchange) -> some View {
    HStack(spacing: 8) {
      Button { controller.barExchange?.collapsed = false } label: {
        HStack(spacing: 6) {
          InterfaceIcon(systemName: "chevron.down", size: 9).foregroundStyle(p.secondary)
          Text(exchange.prompt).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.tail)
        }.contentShape(Rectangle())
      }.buttonStyle(AssistantPressStyle()).help("Show the last reply").accessibilityLabel("Show the last reply: \(exchange.prompt)")
      Spacer(minLength: 4)
      Button { controller.openInSerein() } label: {
        Text(controller.openLabel).font(UIStyle.metaStrong).foregroundStyle(p.ink)
      }.buttonStyle(QuietButton()).fixedSize()
    }.padding(.leading, 12).padding(.trailing, 8).frame(height: 36)
  }
}

/// The reply to the bar's message in Serein's live turn, redrawn as it streams.
private struct SereinBarRunReply: View {
  @ObservedObject var run: AgentRun
  let exchange: RelayController.BarExchange
  let relay: RelayOrchestrator
  let p: Palette
  var body: some View {
    SereinBarReply(messages: run.transcript, exchange: exchange, working: true, phase: run.phase, relay: relay, p: p)
  }
}

/// Serein's words in the turn that answers the message asked from the bar (until the next
/// message of yours), the tasks that turn started, and while it works, what it is doing. When the
/// turn could not start or said nothing, the card says why instead of ending empty.
struct SereinBarReply: View {
  let messages: [AgentMessage]
  let exchange: RelayController.BarExchange
  let working: Bool
  let phase: String?
  @ObservedObject var relay: RelayOrchestrator
  let p: Palette
  /// The footer's button (“Open in Serein”, or “Show in chat” in Serein's own window), so the
  /// empty-reply line names the control under it.
  var openLabel = RelayController.openLabel(inWindow: false)

  /// The turn that answers the bar: your first message after those already there when it was
  /// sent. Its words may differ (sent while Serein worked, it rides with “I interrupted you…”).
  static func asked(_ messages: [AgentMessage], exchange: RelayController.BarExchange) -> Int? {
    messages.firstIndex { $0.role == "you" && !exchange.before.contains($0.id) }
  }
  /// Serein's messages answering it.
  static func replies(_ messages: [AgentMessage], exchange: RelayController.BarExchange) -> [AgentMessage] {
    guard let index = asked(messages, exchange: exchange) else { return [] }
    // The rest of a burst, if it was one, comes before the answer.
    return messages[(index + 1)...].drop { $0.role == "you" && $0.burstIndex != nil }.prefix { $0.role != "you" }.filter {
      $0.role == "assistant" && !$0.text.isEmpty
        && !RelayProactive.isNothing($0.text)
    }
  }

  var body: some View {
    let replies = Self.replies(messages, exchange: exchange)
    VStack(alignment: .leading, spacing: 10) {
      ForEach(replies) { message in
        MessageContent(text: ChatBubbles.plain(ChatBubbles.withoutPartialTag(message.text)), showsCopyButton: false, read: message.read)
      }
      if let index = Self.asked(messages, exchange: exchange) {
        let id = messages[index].id
        ForEach(relay.state.children.filter { $0.messageID == id }.map(\.threadID), id: \.self) { thread in
          SereinTaskCard(threadID: thread, browser: relay.browser, agent: relay.agent)
        }
      }
      if working {
        HStack(spacing: 6) {
          ProgressView().controlSize(.mini).frame(width: 12, height: 12).accessibilityHidden(true)
          Text(phase.flatMap { $0.isEmpty || $0 == "Starting" ? nil : $0 } ?? "Replying…")
            .font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1)
          Spacer(minLength: 6)
          Button { relay.stopReply() } label: {
            HStack(spacing: 4) {
              Image(systemName: "stop.fill").font(.system(size: 8))
              Text("Stop").font(UIStyle.metaStrong)
            }.foregroundStyle(p.ink)
          }.buttonStyle(QuietButton()).fixedSize()
            .help("Stop this reply. Tasks it started keep going.").accessibilityLabel("Stop this reply")
        }
      } else if let error = relay.lastError {
        // The turn failed (no AI app for it, a sign-in that ran out, a failed start).
        Text(error).font(UIStyle.meta).foregroundStyle(p.danger).fixedSize(horizontal: false, vertical: true)
      } else if let notice = relay.stopNotice {
        // A Stop, or a bare “stop” while nothing ran.
        Text(notice.text).font(UIStyle.meta).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
      } else if replies.isEmpty {
        Text(openLabel == RelayController.openLabel(inWindow: true)
             ? "No reply came. Show it in the chat to see what happened."
             : "No reply came. \(openLabel) to see what happened.").font(UIStyle.meta).foregroundStyle(p.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
