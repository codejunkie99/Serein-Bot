import Foundation
import SereinCore

/// Serein's app tools (`AppPlaces`): the map, showing the person a place, a read-only snapshot of
/// a place no other tool reads, and moving a Board card. Every change still goes through the
/// tool `app_places` names for it; these add no way around an ask.
extension RelayToolHost {
  func appTool(_ name: String, _ a: [String: Any]) async throws -> [String: Any] {
    switch name {
    case AppPlaces.listTool:
      return ["places": AppPlaces.listing(),
              "note": "Open shows the person a place. Read with the tool named. Change with the tool named; a place whose change is only the person: open it for them."]
    case AppPlaces.openTool: return try openPlace(a)
    case AppPlaces.readTool:
      // History's count covers every saved day, not only the launch window.
      if (try? requestedPlace(a))?.id == "history" { await relay.browser.loadAllVisits() }
      return try readPlace(a)
    case AppPlaces.boardTool: return try await updateBoard(a)
    default: throw SereinError.invalid("Unknown tool \(name).")
    }
  }

  private func requestedPlace(_ a: [String: Any]) throws -> AppPlace {
    let raw = (a["place"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let place = AppPlaces.place(raw) else {
      throw SereinError.invalid("No place \(raw.isEmpty ? "given" : "named \(raw)"). Call app_places for the ids.")
    }
    return place
  }
  private func requestedID(_ a: [String: Any]) -> String? {
    guard let id = (a["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
    return id
  }
  /// The assistant an `id` names: its name, or its id.
  private func namedAssistant(_ a: [String: Any]) throws -> RelayProfile {
    let profiles: [RelayProfile] = relay.team.profiles
    let names: String = profiles.map(\.name).joined(separator: ", ")
    guard let id = requestedID(a) else { throw SereinError.invalid("Give id: the assistant's name. They are: \(names).") }
    guard let found = profiles.first(where: { $0.name.caseInsensitiveCompare(id) == .orderedSame || $0.id == id }) else {
      throw SereinError.invalid("No assistant is named \(id). They are: \(names).")
    }
    return found
  }

  // MARK: app_open

  /// Moves the window, never data, so it needs no ask; only while the person is answering.
  private func openPlace(_ a: [String: Any]) throws -> [String: Any] {
    if let refusal = AppPlaces.openRefusal(personStarted: frame.byPerson, unattended: frame.unattended) {
      throw SereinError.invalid(refusal)
    }
    let place = try requestedPlace(a)
    guard place.openable else {
      throw SereinError.invalid("app_open does not move the window to \(place.id). Read it with \(place.reads.first ?? "app_places") instead.")
    }
    let browser = relay.browser
    let shown: String
    switch place.opens {
    case .section(let routes):
      let section = routes.first ?? ShellSection.serein
      switch section {
      case ShellSection.serein:
        SereinRouter.showFull()
        shown = "Serein's chat, full in the window"
      case ShellSection.thread:
        guard let id = requestedID(a) else { throw SereinError.invalid("Give id: the chat or run to open (sessions_list has them).") }
        let known = id == relay.threadID || relay.isChild(id) || relay.knownThreadIDs.contains(id) || relay.agent.openThreadItem(id) != nil
        guard known else { throw SereinError.invalid("No chat or task has the id \(id).") }
        SereinRouter.open(threadID: id)
        shown = "that chat"
      default:
        browser.section = section
        shown = place.summary
      }
    case .settings(let id):
      guard let controller = RelayController.shared else { throw SereinError.invalid("Settings cannot open right now.") }
      controller.openSettings(id)
      shown = "Settings › " + (SettingsCategory.all.first { $0.id == id }?.label ?? id)
    case .assistant(let tab):
      let profile = try namedAssistant(a)
      if tab == AssistantInspector.Tab.details.rawValue {
        guard let controller = RelayController.shared else { throw SereinError.invalid("Settings cannot open right now.") }
        controller.openSettings(SettingsCategory.request("Relay", path: [profile.id]))
      } else {
        AssistantInspector.shared.show(profile.id, tab: AssistantInspector.Tab(rawValue: tab))
      }
      shown = "\(profile.name)'s \(tab)"
    case .connectApps:
      browser.showMarketplace = true
      shown = "Marketplace"
    case .search:
      SearchPaletteCenter.shared.open = true
      shown = "Search"
    }
    relay.note("Showed the person \(place.id)", .allowed)
    return ["opened": place.id, "on_screen": "On screen now: \(shown)."]
  }

  // MARK: app_read

  /// Read-only. The person's own data (History, Saved, Projects, a Board with personal cards)
  /// marks this chat as having read it first, as their files do, and is withheld if that fails.
  /// Words from pages or mail ride under keys ending `_untrusted`. Every string passes
  /// `AppPlaces.scrub`, so a value that looks like a key never leaves.
  private func readPlace(_ a: [String: Any]) throws -> [String: Any] {
    let place = try requestedPlace(a)
    guard AppPlaces.readable.contains(place.id) else {
      throw SereinError.invalid("Read \(place.id) with \(place.reads.first ?? "app_places") instead.")
    }
    var out: [String: Any] = ["place": place.id]
    switch place.id {
    case "board": try out.merge(readBoard()) { $1 }
    case "history":
      try markPersonal()
      let visits = relay.browser.visits.sorted { $0.date > $1.date }.prefix(30)
      out["pages"] = visits.map {
        ["title_untrusted": String($0.title.prefix(200)), "address_untrusted": AppPlaces.address($0.url), "when": Self.stamp($0.date)]
      }
      out["shown"] = "the newest \(visits.count) of \(relay.browser.visits.count)"
    case "saved":
      try markPersonal()
      let marks = relay.browser.marks.sorted { $0.date > $1.date }.prefix(30)
      out["saved"] = marks.map {
        ["title_untrusted": String($0.title.prefix(200)), "address_untrusted": AppPlaces.address($0.url),
         "quote_untrusted": String($0.quote.prefix(300)), "when": Self.stamp($0.date)]
      }
      out["shown"] = "the newest \(marks.count) of \(relay.browser.marks.count)"
    case "projects":
      try markPersonal()
      // The folder's name, never its path: the path names the person's home folder.
      out["projects"] = relay.browser.listedProjects.map {
        ["id": $0.id, "name": $0.name, "folder": URL(fileURLWithPath: $0.path).lastPathComponent]
      }
    case let id where id.hasPrefix("assistant/"):
      let profile = try namedAssistant(a)
      let listing = listAssistants()["assistants"] as? [[String: Any]] ?? []
      out["assistant"] = listing.first { ($0["name"] as? String) == profile.name } ?? ["name": profile.name]
      if id != "assistant/details" { out["note"] = "Its \(id.dropFirst("assistant/".count)) tab shows the rest: open it for the person." }
    default:
      let page = String(place.id.dropFirst("settings/".count))
      out.merge(readSettings(page)) { $1 }
    }
    return AppPlaces.scrub(out) as? [String: Any] ?? out
  }

  private func markPersonal() throws {
    guard relay.agent.markPersonalRead(thread: frame.thread) else {
      throw SereinError.invalid(BrowserModel.personalMarkWithheld)
    }
  }

  private func readBoard() throws -> [String: Any] {
    let book = TodoBook.shared
    if book.unreadable { throw SereinError.invalid(TodoBook.unreadableWords) }
    if book.cards.contains(where: { $0.personal == true }) { try markPersonal() }
    let names = Dictionary(relay.team.profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    let cards: [[String: Any]] = book.cards.map { card in
      var row: [String: Any] = ["id": card.id, "title_untrusted": card.title, "column": card.column.rawValue, "goal": card.goal != nil]
      if let due = card.deadline { row["due"] = Self.stamp(due) }
      if let who = card.assistantID.flatMap({ names[$0] }) { row["assistant"] = who }
      return row
    }
    var asks: [[String: Any]] = relay.approvals.map { ["title_untrusted": $0.title, "kind": "approval"] }
    asks += relay.questionForms.map { ["title_untrusted": $0.title, "kind": "question"] }
    return ["cards": cards, "waiting_on_you": asks, "tasks": "agent_status reads the running tasks",
            "columns": TodoCard.Column.allCases.map { "\($0.rawValue): \($0.title)" }]
  }

  /// What a Settings page shows, never a key, token, password, sign-in or code: connections and
  /// AI apps read as names with on or off.
  private func readSettings(_ page: String) -> [String: Any] {
    var out: [String: Any] = [:]
    switch page {
    case "General", "Appearance":
      out["values"] = AgentSettings.values(on: page)
    case "Relay":
      out["assistants"] = relay.team.profiles.map(\.name)
    case "Agents":
      out["ai_apps"] = Provider.allCases.filter(\.thinksForSerein).map {
        ["name": $0.name, "state": relay.agent.available[$0] != nil ? "ready" : "not set up"]
      }
    case "Connections":
      out["connections"] = NativeConnection.allCases.map { ["name": $0.label, "state": $0.isOn() ? "connected" : "not connected"] }
    case "Plugins":
      out["skills"] = PluginHost.shared.skills.map(\.name)
    default: break
    }
    let changes = AppPlaces.place("settings/" + page)?.changes ?? []
    out["change"] = changes.isEmpty
      ? "Only the person changes this page. Open it for them with app_open."
      : changes.joined(separator: ", ") + "; anything else on the page the person changes there."
    return out
  }

  // MARK: board_update

  /// Moves one of the person's Board cards. `Admission.decide(.board)` refuses any turn the
  /// person did not start; words that name the move apply it; otherwise the person decides on a
  /// card, whatever Serein asks before, as `todo_propose` does. Either way it lands as a receipt
  /// with Undo (`AssistantDesk.Undo.board`). Moving starts no task.
  private func updateBoard(_ a: [String: Any]) async throws -> [String: Any] {
    let book = TodoBook.shared
    guard let id = requestedID(a) else { throw SereinError.invalid("id is required: a card id from app_read board.") }
    let raw = (a["column"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let column = TodoCard.Column(rawValue: raw) else { throw SereinError.invalid("column is next, doing, waiting or done.") }
    if book.unreadable { throw SereinError.invalid(TodoBook.unreadableWords) }
    guard let card = book.cards.first(where: { $0.id == id }) else { throw TodoBook.gone }
    guard card.column != column else { return ["moved": false, "column": column.title, "note": "It is in \(column.title) already."] }
    let short = String(card.title.prefix(60))
    switch relay.admission(.board) {
    case .refuse(let why): throw SereinError.invalid(why)
    case .apply: break
    case .ask:
      let human = await relay.confirmAnswer(
        "Move “\(short)” to \(column.title)?", "On your Board. Moving it starts no work.", button: "Move",
        thread: frame.thread, effect: .change)
      guard human == .yes else {
        throw SereinError.invalid(human == .no ? "The person kept the card where it is." : ActionAdmission.needsPerson)
      }
    }
    if card.personal == true { try markPersonal() }
    // What the card showed is what moves: a card moved or deleted meanwhile stays as it is.
    guard let now = book.cards.first(where: { $0.id == id }), now.column == card.column else {
      throw SereinError.invalid("The card changed while Serein asked, so it did not move.")
    }
    try book.move(id, to: column)
    let entry = "board-" + UUID().uuidString
    relay.desk.undoActions[entry] = .board(card: id, column: card.column, task: card.taskID)
    relay.deliver(receipt: ReceiptCopy.boardMoved(title: card.title, to: column.title, entry: entry), into: frame.thread)
    relay.note("Moved “\(short)” to \(column.title) in Goals", .allowed)
    return ["moved": true, "id": id, "column": column.title, "undo": entry, "note": HostFacts.receiptNote]
  }
}
