#if DEBUG
import Foundation
import SereinCore

/// Serein's app tools (AppPlaces.swift, AppPlaceTools.swift): the map covers every view, Settings
/// page and assistant tab, names only real tools, rides in every relay turn, and keeps its rules.
extension AssistantCoreChecks {
  static func appTools(_ check: Check) throws {
    let routes: Set<String> = Set(AppPlaces.all.flatMap { place -> [String] in
      if case .section(let list) = place.opens { return list }
      return []
    })
    let missing = ShellSection.all.filter { !routes.contains($0) }
    try check(missing.isEmpty, "Every main view has a place in app_places [none for: \(missing.joined(separator: ", "))]")
    try check(SettingsCategory.all.allSatisfy { page in AppPlaces.all.contains { $0.opens == .settings(page.id) } },
              "Every Settings page has a place in app_places")
    let tabs = AssistantInspector.Tab.allCases.map(\.rawValue)
    try check(Set(tabs) == Set(AppPlaces.inspectorTabs) && tabs.allSatisfy { AppPlaces.place("assistant/" + $0) != nil },
              "Every tab of an assistant's panel has a place in app_places")
    try check(Set(AppPlaces.all.map(\.id)).count == AppPlaces.all.count, "Each place has its own id")
    try check(AppPlaces.all.filter { $0.id.hasPrefix("settings/") }.allSatisfy { $0.summary.contains("open it for them") },
              "Each Settings place says the person changes the rest there")

    let registry = Set(ToolSchema.everyTool(["--relay", "--settings", "--connected-apps", "--team"]).compactMap { $0["name"] as? String })
    let unknown = Set(AppPlaces.all.flatMap { $0.reads + $0.changes }).subtracting(registry).sorted()
    try check(unknown.isEmpty, "Every tool app_places names is a real tool [unknown: \(unknown.joined(separator: ", "))]")
    let relayTurn = Set(ToolSchema.offered(["--relay"]).compactMap { $0["name"] as? String })
    try check(relayTurn.isSuperset(of: AppPlaces.toolNames) && RelayTools.names.isSuperset(of: AppPlaces.toolNames),
              "The app tools are offered in every relay turn, so Codex's approve list carries them too")
    try check(AppPlaces.toolNames.allSatisfy { AgentStep.label(tool: $0, arguments: [:]) != "Used a tool" },
              "Each app tool reads in words in the steps")

    try check(AppPlaces.openRefusal(personStarted: true, unattended: false) == nil
              && AppPlaces.openRefusal(personStarted: false, unattended: false) != nil
              && AppPlaces.openRefusal(personStarted: true, unattended: true) != nil
              && AppPlaces.openRefusal(personStarted: false, unattended: true) != nil,
              "app_open moves the window only in a turn the person started, never in an unattended one")

    for refused in ["serein.relay.autopilot", "approval_level", "serein.fullAccessProjects", "mac_access", "kept_sign_ins",
                    "pairings", "private_mode", "passwords", "api_key", "accessToken"] {
      try check(SettingsDenylist.refuses(refused), "The settings denylist refuses \(refused)")
    }
    let allowed = AgentSetting.allCases.map(\.rawValue)
      + ["serein.darkPages", "serein.compact", "serein.searchEngine", "serein.sleepMinutes"]
    try check(allowed.allSatisfy { !SettingsDenylist.refuses($0) }, "Every setting a tool may change passes the denylist")

    // The rule (AppPlaces.looksLikeKey): a known key prefix, or a piece of 32 or more characters
    // with at least 6 digits and 6 letters. Words, addresses and dates pass.
    let fixture: [String: Any] = [
      "place": "settings/Connections",
      "connections": [["name": "Calendar", "state": "connected"]],
      "pages": [["title_untrusted": "Pricing · Acme", "address_untrusted": "https://acme.example/pricing", "when": "2026-11-15T10:00:00Z"],
                ["title_untrusted": "sk-live-abcdef0123456789", "address_untrusted": "https://x.example/cb/9f8e7d6c5b4a39281706f5e4d3c2b1a0ffee1234"]],
      "note": "Bearer abc.def.ghi",
    ]
    func strings(_ value: Any) -> [String] {
      switch value {
      case let text as String: return [text]
      case let list as [Any]: return list.flatMap(strings)
      case let map as [String: Any]: return map.values.flatMap(strings)
      default: return []
      }
    }
    let read = strings(AppPlaces.scrub(fixture))
    try check(!read.contains(where: AppPlaces.looksLikeKey) && read.contains("Pricing · Acme")
              && read.contains("https://acme.example/pricing") && read.filter { $0 == AppPlaces.hidden }.count == 3,
              "app_read hides every value that looks like a key and keeps plain words")
    try check(AppPlaces.address("https://a.example/path?code=123456#t") == "https://a.example/path",
              "An address read back loses its query, where sign-in codes ride")

    typealias A = Admission
    try check(A.decide(.board, turn: .person, wordsNameIt: true) == .apply
              && A.decide(.board, turn: .person, wordsNameIt: false) == .ask,
              "A Board move the person's words name applies; otherwise the person decides on a card")
    if case .refuse = A.decide(.board, turn: .assistant, wordsNameIt: true) {} else { try check(false, "Another assistant's turn cannot move a card") }
    try check(TypedConsent.names(.board, in: "Move the dentist card to done")
              && TypedConsent.names(.board, in: "mark taxes as finished")
              && !TypedConsent.names(.board, in: "What is on my board?"),
              "Move and mark name a Board move; a question does not")
    let receipt = ReceiptCopy.boardMoved(title: "Book the dentist", to: TodoCard.Column.done.title, entry: "board-1")
    try check(ReceiptCopy.lint(receipt.line).isEmpty && receipt.undo?.entry == "board-1",
              "A Board move lands as a plain receipt with Undo")
  }
}
#endif
