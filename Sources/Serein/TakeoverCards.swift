import Foundation
import SereinCore
import SwiftUI

@MainActor final class TakeoverCards: ObservableObject {
  struct Card: Identifiable {
    let id = UUID()
    let task: String
    let thread: String?
    let host: String
    let reason: String
    let tab: BrowserTab
    var holder: ComputerHold.Holder = .assistant
  }
  @Published private(set) var open: [Card] = []
  weak var browser: BrowserModel?

  func raise(_ card: Card) {
    if !open.contains(where: { $0.tab === card.tab }) { open.append(card) }
  }
  func holds(_ tab: BrowserTab) -> Bool { open.contains { $0.tab === tab && $0.holder != .assistant } }
  func takeControl(_ id: UUID) {
    guard let index = open.firstIndex(where: { $0.id == id }) else { return }
    open[index].holder = ComputerHold.next(open[index].holder, .takeOver(stepInFlight: false))
  }
  func close(_ id: UUID, _ ending: TakeoverCard.Ending) {
    guard let card = open.first(where: { $0.id == id }) else { return }
    open.removeAll { $0.id == id }
    Task { await browser?.takeoverClosed(card, ending) }
  }
}

extension BrowserModel {
  func askPersonTakeover(_ tab: BrowserTab, task id: String, reason: String) -> [String: Any] {
    takeoverCards.raise(
      .init(task: id, thread: threadID(forTask: id), host: tab.verificationHost, reason: String(reason.prefix(200)), tab: tab))
    return ["tab": tab.id, "asked": TakeoverCard.asked]
  }

  func takeoverClosed(_ card: TakeoverCards.Card, _ ending: TakeoverCard.Ending) async {
    let tab = card.tab
    _ = try? await tab.script("globalThis.__serein.invalidate()")
    guard let thread = card.thread, let agent = intelligenceAgent else { return }
    let taskLetGo = tasks[card.task]?.tabs.contains(where: { $0 === tab }) != true
    if taskLetGo, agent.hub.run(for: thread) == nil, handBacks[thread] == nil {
      offerToNextRun(tab, task: card.task, thread: thread)
    }
    let text = TakeoverCard.followUp(host: card.host, tab: tab.id, ending: ending)
    if let refused = await agent.flow.replyToTask(thread, text: text, interrupt: false) { notice = refused }
    let unclaimed = handBacks[thread] === tab && agent.hub.run(for: thread) == nil
    if unclaimed { keepForPerson(tab, thread: thread) }
  }

  private func offerToNextRun(_ tab: BrowserTab, task: String, thread: String) {
    guard let info = agentTabs.release(tab.id) else { return }
    tab.agentMark = TabAgentMark(
      agent: info.agent, threadID: thread, taskID: task, title: info.title, summary: nil, status: nil,
      startedAt: info.startedAt, endedAt: info.endedAt ?? Date(), steps: info.steps)
    tab.owner = nil
    tabs.append(tab)
    handBacks[thread] = tab
  }

  private func keepForPerson(_ tab: BrowserTab, thread: String) {
    handBacks[thread] = nil
    attach(tab)
    PasswordCapture.adopt(tab)
    SiteFeatureBridge.adopt(tab)
  }
}

struct TakeoverCardStack: View {
  @ObservedObject var cards: TakeoverCards

  var body: some View {
    ForEach(cards.open) { card in
      TakeoverCardView(card: card, take: { cards.takeControl(card.id) }, close: { cards.close(card.id, $0) })
        .id(card.id)
    }
  }
}

struct TakeoverCardView: View {
  let card: TakeoverCards.Card
  let take: () -> Void
  let close: (TakeoverCard.Ending) -> Void
  @Environment(\.palette) private var p

  var body: some View {
    let person = card.holder == .person
    let screen = RoundedRectangle(cornerRadius: 12, style: .continuous)
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: "Needs you on \(card.host)").font(AssistantType.name).foregroundStyle(p.ink)
          if !card.reason.isEmpty {
            Text(verbatim: card.reason).font(AssistantType.meta).foregroundStyle(p.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
        Button { close(.dismissed) } label: {
          InterfaceIcon(systemName: "xmark", size: 12).frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.pressable).help("Close").accessibilityLabel("Close the takeover card")
      }
      // shortcut: a WKWebView has one parent, so the page leaves the browser view while it shows here.
      WebHost(web: card.tab.web).id(ObjectIdentifier(card.tab.web))
        .frame(height: 280).clipShape(screen)
        .allowsHitTesting(person)
        .overlay(screen.strokeBorder(person ? p.accent : p.line, lineWidth: person ? 2 : UIStyle.hairline))
        .accessibilityLabel("Live page on \(card.host)")
      ControlPill(holder: card.holder, heldName: "the page on \(card.host)", take: take, handBack: { close(.handedBack) })
        .frame(maxWidth: .infinity)
    }
    .padding(16)
    .frame(maxWidth: AssistantMetrics.cardWide)
    .assistantCard(p, radius: AssistantMetrics.signInRadius)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Needs you on \(card.host)")
  }
}
