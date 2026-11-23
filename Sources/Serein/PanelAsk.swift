import SereinCore
import SwiftUI

// Ask about this page, inside the task panel's composer: the "Include this page?" offer when the
// page changes, the "Ask about these tabs" picker and the page thread's empty state. The page
// and selection chips and "Show what will be sent" are the composer's own.

/// "Include this page?" after the page in a page thread changed. A new page is never attached on
/// its own; the user confirms it.
struct PanelPageOffer: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @ObservedObject private var context = ComposerContext.shared
  @Environment(\.palette) var p
  var body: some View {
    if agent.mode == .page, context.askThreadID == agent.conversationID, let tab = browser.active,
      !tab.privateMode, !tab.hiddenFromAgents, let offer = context.pageOffer, offer == tab.address,
      context.page == nil
    {
      HStack(spacing: 8) {
        SiteIcon(tab: tab, size: 14)
        Text("Include this page?").font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1)
        Spacer(minLength: 4)
        Button("Not now") { context.pageOffer = nil }.buttonStyle(QuietButton()).font(UIStyle.micro)
        Button("Include") { Task { await context.attachPage(tab, browser: browser) } }
          .buttonStyle(QuietButton()).font(UIStyle.micro)
          .help("Adds this page's text and your selection to the next message")
      }.padding(.horizontal, 12).padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Include this page: \(tab.title)")
    }
  }
}

/// Watches the active tab while the panel shows a page thread: after the page changes, the old
/// page chip is dropped and the new page is only offered.
struct PageOfferWatcher: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @ObservedObject var tab: BrowserTab
  var body: some View {
    Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
      .onChange(of: tab.address) { _, _ in offer(tab) }
      .onChange(of: tab.loading) { _, loading in if !loading { offer(tab) } }
  }
  func offer(_ tab: BrowserTab) {
    let context = ComposerContext.shared
    guard agent.mode == .page, context.askOpen, context.askThreadID == agent.conversationID,
      !tab.privateMode, !tab.hiddenFromAgents, !tab.loading, !tab.address.isEmpty,
      context.attachedURL != tab.address
    else { return }
    context.page = nil
    context.selection = nil
    context.attachedURL = nil
    context.pageOffer = tab.address
  }
}

extension PanelComposer {
  /// The page thread follows the selected tab: switching tabs offers the new page.
  static func tabChanged(browser: BrowserModel, agent: AgentModel) {
    let context = ComposerContext.shared
    guard agent.mode == .page, context.askOpen, context.askThreadID == agent.conversationID,
      let active = browser.active, !active.privateMode, !active.hiddenFromAgents
    else { return }
    context.page = nil
    context.selection = nil
    context.attachedURL = nil
    if !active.loading, !active.address.isEmpty { context.pageOffer = active.address }
  }
}

/// The empty page thread in the panel: what Ask does, before the first question.
struct PageThreadEmpty: View {
  @ObservedObject var browser: BrowserModel
  @Environment(\.palette) var p
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Nothing on the page is changed. The page and your selection go with your question; the eye shows exactly what is sent.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      if let tab = browser.active, !tab.privateMode {
        HStack(spacing: 6) {
          SiteIcon(tab: tab, size: 14)
          Text(tab.title).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.middle)
        }.padding(.top, 2)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
