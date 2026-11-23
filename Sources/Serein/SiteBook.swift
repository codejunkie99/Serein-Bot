import Foundation
import SereinCore

/// Native trackers and saved pages, persisted before the tool reports success.
@MainActor final class SiteBook: ObservableObject {
  static let shared = SiteBook()
  @Published private(set) var saved: [SavedSite] = []
  @Published private(set) var problem: String?
  private var library: Library?
  static let path = "sites.json"
  func attach(_ library: Library) {
    self.library = library
    if let sites = library.load([SavedSite].self, from: Self.path) { saved = sites }
    else if FileManager.default.fileExists(atPath: library.root.appendingPathComponent(Self.path).path) {
      problem = "Your saved sites could not be read. The file has been kept unchanged."
    }
  }
  var items: [SavedSite] {
    let trackers = TodoBook.shared.cards.map { card in
      SavedSite(id: "goal-" + card.id, title: card.title, goalID: card.id, updatedAt: card.createdAt, personal: card.personal)
    }
    return (saved + trackers).sorted { $0.updatedAt > $1.updatedAt }
  }
  func find(_ id: String) -> SavedSite? { items.first { $0.id == id } }
  @discardableResult func keep(_ site: SavedSite) throws -> SavedSite {
    guard problem == nil, let library else { throw SereinError.invalid(problem ?? "Pages is not ready.") }
    guard !site.title.isEmpty, site.title.count <= 200,
      site.url.map({ SavedSite.safeURL($0) != nil }) ?? true,
      site.dashboard.map({ $0.isValid }) ?? true else { throw SereinError.invalid("This site has an invalid title, address or dashboard.") }
    var next = saved
    if let index = next.firstIndex(where: { $0.id == site.id }) { next[index] = site }
    else {
      guard next.count < 500 else { throw SereinError.invalid("Serein keeps up to 500 pages.") }
      next.append(site)
    }
    try library.save(next, to: Self.path)
    saved = next
    return site
  }
  @discardableResult func dashboard(_ spec: DashboardSpec) throws -> SavedSite {
    let existing = saved.first { $0.dashboard != nil && $0.title == spec.title }
    return try keep(SavedSite(id: existing?.id ?? UUID().uuidString, title: spec.title,
      dashboard: spec, personal: spec.personal))
  }
}

extension RelayOrchestrator {
  func showSite(_ id: String, into thread: String) {
    if agent.hub.run(for: thread) != nil || (thread == threadID && sending) {
      var facts = desk.facts[thread] ?? AssistantDesk.Facts(); facts.siteID = id; desk.facts[thread] = facts
    } else {
      var message = AgentMessage(role: "assistant", text: "", notice: true); message.siteID = id
      post(message, into: thread)
    }
  }
}
