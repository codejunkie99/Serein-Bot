import AppKit
import SereinCore
import SwiftUI
import UniformTypeIdentifiers

/// Drops on an assistant row, a team header or (in Assistants mode) the Serein row, and their
/// menu twins: files join the composer's attachments by its own rules (`acceptDocuments`), a link
/// or text from another app goes into the draft, a chat message is handed to that assistant, and a tab
/// from the Tabs list becomes the page chip by the path of choosing that tab. Each first opens
/// that chat as a click on the row does. Nothing is ever sent; the person presses Send.
///
/// A tab drag is the Tabs list's own gesture (SidebarTabDrag.swift), not an item-provider drag, so
/// it is followed here with a local mouse monitor: over the "Assistants" segment for 600 ms the
/// list springs to Assistants, and a release over a row or header asks about the tab there.
@MainActor final class AssistantDrop: ObservableObject {
  static let shared = AssistantDrop()
  /// Where a drop lands: an assistant (from its row under a team, or none) or a team, which its
  /// lead or first member answers.
  enum Target: Equatable {
    case assistant(String, team: String?)
    case team(String)
  }
  /// What a drop carries.
  enum Kind: Equatable {
    case message, files, link, text
    case tab(String)
  }
  /// The row a drop hovers: its trailing words (what the drop does, or why it is refused) and the
  /// sentence its accessibility value adds.
  struct Hover: Equatable {
    var key: String
    var words: String
    var spoken: String
    var refused = false
  }
  @Published private(set) var hover: Hover?
  /// A carried tab is on the "Assistants" segment, waiting for the list to spring open.
  @Published private(set) var springing = false
  /// The "Assistants" segment and every target's frame, in the shell's space
  /// (`AgentBubbleLayer.space`, the window's content flipped), where the mouse monitor looks.
  var switchFrame: CGRect = .zero
  /// The sidebar's scrolling list, so a row scrolled out of sight takes no tab.
  var listFrame: CGRect = .zero
  private var frames: [String: (frame: CGRect, target: Target)] = [:]
  private var carried: (tab: String, letGo: () -> Void)?
  private var sprung = false
  private var monitor: Any?
  private var spring: DispatchWorkItem?

  func hovering(_ key: String) -> Hover? { hover?.key == key ? hover : nil }

  // MARK: drops from the transcript and other apps

  static let types: [UTType] = [.fileURL, .url, .plainText]
  /// Files and links by their types. Plain text dragged inside Serein while it is in front is only
  /// ever a chat message's hand-off (MessageDrag), as before; from another app it is text.
  static func kind(_ info: DropInfo, takesHandOff: Bool) -> Kind? {
    if info.hasItemsConforming(to: [.fileURL]) { return .files }
    if info.hasItemsConforming(to: [.url]) { return .link }
    guard info.hasItemsConforming(to: [.plainText]) else { return nil }
    if NSApp.isActive { return takesHandOff ? .message : nil }
    return .text
  }
  func enter(_ key: String, kind: Kind, target: Target) {
    guard let relay = SereinSurface.controller?.relay else { return }
    hover = Self.describe(key, kind: kind, target: target, relay: relay)
  }
  func leave(_ key: String) {
    if hover?.key == key { hover = nil }
  }

  /// What a hover says on the row.
  static func describe(_ key: String, kind: Kind, target: Target, relay: RelayOrchestrator) -> Hover {
    let name = Self.title(target, relay: relay)
    if kind != .message, let line = busy(target, relay: relay) {
      return Hover(key: key, words: "Not now", spoken: line, refused: true)
    }
    switch kind {
    case .message: return Hover(key: key, words: "Hand off message", spoken: "Drop a chat message to hand it off to \(name)")
    case .files: return Hover(key: key, words: "Attach", spoken: "Drop to attach the files to a message to \(name). Nothing is sent")
    case .link: return Hover(key: key, words: "Add link", spoken: "Drop to put the link in a message to \(name). Nothing is sent")
    case .text: return Hover(key: key, words: "Add text", spoken: "Drop to put the text in a message to \(name). Nothing is sent")
    case .tab(let id):
      guard let tab = SereinRouter.browser?.tabs.first(where: { $0.id == id }) else {
        return Hover(key: key, words: "Closed", spoken: "That tab was closed", refused: true)
      }
      if let refusal = Self.refusal(tab) { return Hover(key: key, words: refusal.words, spoken: refusal.line, refused: true) }
      return Hover(key: key, words: "Ask about tab",
                   spoken: "Drop to ask \(name) about \(tab.title.isEmpty ? "this tab" : tab.title). Nothing is sent")
    }
  }
  private static func title(_ target: Target, relay: RelayOrchestrator) -> String {
    switch target {
    case .assistant(let id, _): return relay.profileName(id)
    case .team(let id): return relay.team.group(id)?.name ?? "the team"
    }
  }
  /// `openAssistant`'s refusal, said while hovering: mid-reply no other assistant takes over.
  private static func busy(_ target: Target, relay: RelayOrchestrator) -> String? {
    let who: String?
    switch target {
    case .assistant(let id, _): who = id
    case .team(let id): who = relay.team.group(id).flatMap { relay.responder(of: $0) }
    }
    guard let who, who != relay.team.activeID, !relay.canSwitchAssistant else { return nil }
    return "\(relay.team.activeName) is still replying. Wait for it to finish, then switch."
  }

  // MARK: what a drop does

  /// Opens the target's chat as a click on its row does (the pill goes there). False when it is
  /// refused mid-reply, with its toast.
  @discardableResult
  static func open(_ target: Target, relay: RelayOrchestrator) -> Bool {
    switch target {
    case .assistant(let id, let team):
      AssistantSidebarState.shared.lastClicked = (team, id)
      return relay.openAssistant(id, team: team)
    case .team(let id):
      AssistantSidebarState.shared.lastClicked = (id, nil)
      return relay.openTeam(id)
    }
  }
  /// Attach Files… on a row's menu: that chat opens, then the composer's own open panel.
  static func attachFiles(_ target: Target) {
    guard let relay = SereinSurface.controller?.relay, open(target, relay: relay) else { return }
    DispatchQueue.main.async { SereinSurface.main.chooseDocuments() }
  }
  /// Why a tab cannot be the page chip, by the chip's own rule (`SereinPageChip.slot`): the short
  /// words a row shows and the line a toast says. nil when it can.
  static func refusal(_ tab: BrowserTab) -> (words: String, line: String)? {
    let slot = SereinPageChip.slot(
      section: ShellSection.browser, active: SereinPageChip.page(tab), removed: [], left: nil,
      sharing: SereinPageChip.sharing, now: Date())
    switch slot {
    case .page: return nil
    case .privateTab: return ("Private tab", "Private tabs are never shared with agents.")
    case .none:
      if !SereinPageChip.sharing {
        return ("Sharing off", "Settings › Privacy › The page you're viewing is off.")
      }
      if tab.isSourceView { return ("Source view", "Source views are never shared with agents.") }
      if tab.hiddenFromAgents {
        return ("Not shared", SiteRules.personLine(SiteRules.site(tab.address) ?? "this site", verb: "read"))
      }
      return ("Not a web page", "Only web pages can be shared with an assistant.")
    }
  }
  /// A tab dropped on a row or header, or Ask About This Tab › on a tab's menu: that chat opens
  /// with the page chip on this tab, by the path of choosing the tab (it becomes the tab in view,
  /// and the chip follows it, its × undone as ⌥⌘E does), so the chip's rules and page reads stay
  /// as they are. A tab the chip would refuse is refused here with its line.
  static func ask(about tab: BrowserTab, _ target: Target) {
    guard let relay = SereinSurface.controller?.relay, let browser = SereinRouter.browser,
      browser.tabs.contains(where: { $0.id == tab.id })
    else { return }
    if let refusal = Self.refusal(tab) {
      ToastCenter.shared.show(refusal.line)
      return
    }
    guard open(target, relay: relay) else { return }
    SereinPageChip.shared.restore(tab.id)
    browser.show(tab)
    // Choosing a tab ends a peek and leaves Serein full, and the shell places Serein again only
    // on its next layout: ask from this tab as ⌘E does, by the place it is about to have.
    let surface = SereinSurface.main
    let place: SereinPlace = !SereinRouter.besideOn && !surface.peek ? .hidden : surface.fits ? .beside : .noRoom
    SereinRouter.apply(SereinLayout.askFromHidden(place: place, fits: surface.fits))
  }

  // MARK: a tab carried from the Tabs list

  /// A row or header's frame in the shell's space; nil when it leaves the screen.
  func place(_ key: String, frame: CGRect?, target: Target) {
    frames[key] = frame.map { (frame: $0, target: target) }
  }
  /// A tab row's drag began in the sidebar: follow the pointer until the button comes up.
  /// `letGo` makes the Tabs list drop its drag when the list springs to Assistants.
  func carry(_ tabID: String, letGo: @escaping () -> Void) {
    end()
    guard SereinSurface.controller?.relay != nil else { return }
    carried = (tab: tabID, letGo: letGo)
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .leftMouseDown]) {
      [weak self] event in
      MainActor.assumeIsolated {
        guard let self else { return }
        guard event.type != .leftMouseDown else { return self.end() }
        guard let content = event.window?.contentView else {
          if event.type == .leftMouseUp { self.end() }
          return
        }
        let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        if event.type == .leftMouseUp { self.release(at: point) } else { self.moved(to: point) }
      }
      return event
    }
  }
  private func moved(to point: CGPoint) {
    guard let carried else { return }
    guard sprung else {
      let on = switchFrame.contains(point)
      guard on != springing else { return }
      springing = on
      spring?.cancel()
      guard on else { return }
      let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.springOpen() } }
      spring = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
      return
    }
    guard let entry = target(at: point) else {
      if hover != nil { hover = nil }
      return
    }
    guard hover?.key != entry.key, let relay = SereinSurface.controller?.relay else { return }
    hover = Self.describe(entry.key, kind: .tab(carried.tab), target: entry.value.target, relay: relay)
  }
  /// 600 ms on the segment: the Tabs list lets go (nothing reorders) and Assistants shows.
  private func springOpen() {
    guard let carried, !sprung, springing else { return }
    sprung = true
    springing = false
    carried.letGo()
    NotificationCenter.default.post(name: SidebarModeSwitch.showAssistants, object: nil)
  }
  /// Before the list sprang, the Tabs list's own release does what it always did. After, a
  /// release on a row or header asks about the tab there; anywhere else the tabs come back as
  /// they were.
  private func release(at point: CGPoint) {
    defer { end() }
    guard let carried, sprung else { return }
    guard let entry = target(at: point) else { return }
    guard let tab = SereinRouter.browser?.tabs.first(where: { $0.id == carried.tab }) else { return }
    Self.ask(about: tab, entry.value.target)
  }
  /// The row or header under the pointer: the Serein row ("main") sits above the list.
  private func target(at point: CGPoint) -> (key: String, value: (frame: CGRect, target: Target))? {
    frames.first { $0.value.frame.contains(point) && ($0.key == "main" || listFrame.contains(point)) }
  }
  private func end() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    spring?.cancel()
    spring = nil
    carried = nil
    sprung = false
    if springing { springing = false }
    if hover != nil { hover = nil }
  }
}

/// Makes a row or header a drop target: drops from the transcript and other apps through the
/// delegate, and a carried tab through its frame in the shell's space.
struct AssistantDropModifier: ViewModifier {
  var key: String
  var target: AssistantDrop.Target
  /// A chat message's id dropped here hands it off; nil where no hand-off is taken (the row of
  /// the assistant whose chat it is, a team header, the Serein row).
  var handOff: (@MainActor (String) -> Void)? = nil
  func body(content: Content) -> some View {
    content
      .onDrop(of: AssistantDrop.types, delegate: AssistantDropDelegate(key: key, target: target, handOff: handOff))
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(AgentBubbleLayer.space)) } action: {
        AssistantDrop.shared.place(key, frame: $0, target: target)
      }
      .onDisappear { AssistantDrop.shared.place(key, frame: nil, target: target) }
  }
}

private struct AssistantDropDelegate: DropDelegate {
  let key: String
  let target: AssistantDrop.Target
  let handOff: (@MainActor (String) -> Void)?
  private func kind(_ info: DropInfo) -> AssistantDrop.Kind? {
    let takesHandOff = handOff != nil
    return MainActor.assumeIsolated { AssistantDrop.kind(info, takesHandOff: takesHandOff) }
  }
  func validateDrop(info: DropInfo) -> Bool { kind(info) != nil }
  func dropEntered(info: DropInfo) {
    guard let kind = kind(info) else { return }
    MainActor.assumeIsolated { AssistantDrop.shared.enter(key, kind: kind, target: target) }
  }
  func dropUpdated(info: DropInfo) -> DropProposal? {
    let refused = MainActor.assumeIsolated { AssistantDrop.shared.hovering(key)?.refused == true }
    return DropProposal(operation: refused ? .forbidden : .copy)
  }
  func dropExited(info: DropInfo) {
    MainActor.assumeIsolated { AssistantDrop.shared.leave(key) }
  }
  func performDrop(info: DropInfo) -> Bool {
    guard let kind = kind(info) else { return false }
    return MainActor.assumeIsolated {
      AssistantDrop.shared.leave(key)
      guard let relay = SereinSurface.controller?.relay else { return false }
      switch kind {
      case .message:
        // The drag carries only the message's id; its words come from the chat on screen.
        guard let handOff, let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { item, _ in
          guard let text = (item as? NSString).map({ $0 as String }) else { return }
          guard let id = MessageDrag.id(text) else {
            DispatchQueue.main.async { ToastCenter.shared.show("Only a chat message can be handed off.") }
            return
          }
          DispatchQueue.main.async { handOff(id) }
        }
        return true
      case .files:
        guard AssistantDrop.open(target, relay: relay) else { return false }
        return SereinSurface.main.acceptDocuments(info.itemProviders(for: [.fileURL]))
      case .link:
        guard let provider = info.itemProviders(for: [.url]).first, AssistantDrop.open(target, relay: relay) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
          // Web links only, as the composer's own link drop takes.
          guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
          DispatchQueue.main.async { SereinRouter.show(draft: url.absoluteString) }
        }
        return true
      case .text:
        guard let provider = info.itemProviders(for: [.plainText]).first, AssistantDrop.open(target, relay: relay) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { item, _ in
          // Untrusted words for the draft only; a stray hand-off marker is never one.
          guard let text = (item as? NSString).map({ $0 as String }), MessageDrag.id(text) == nil else { return }
          DispatchQueue.main.async { SereinRouter.show(draft: text) }
        }
        return true
      case .tab:
        return false
      }
    }
  }
}
