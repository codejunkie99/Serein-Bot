import Foundation
import SereinCore

/// `setting_change` in the app (owner 2026-11-25): a setting changes from the chat at once, through
/// the store its Settings page already reads, with a receipt whose Undo writes the value before back
/// (`SettingsLedger`). No card at any level; the guard is the person's own words (`ChatSettings.admit`).
extension RelayOrchestrator {
  static let settingPersonOnly = "Only the person changes settings, in their own message. Propose it to them instead."
  static func settingPays(_ who: String, _ model: String) -> String {
    "Moving \(who) to \(model) could change who pays, so the person picks it in the model list. Open it for them with app_open."
  }

  /// A setting as `setting_change` reads and writes it; nil for a name it does not take. A model
  /// is "model:<assistant id>", read as the assistant's own route (`RelayProfile.route`).
  func chatSetting(_ name: String) -> String? {
    if name == ChatSettings.approvalLevel { return level.title }
    if let toggle = ChatSettings.toggle(name) { return ChatSettings.show(Self.isOn(toggle)) }
    if let setting = AgentSetting(rawValue: name) { return AgentSettings.value(setting) }
    guard let id = Self.modelOwner(name), let who = team.profiles.first(where: { $0.id == id }) else { return nil }
    return Self.routeValue(who.route)
  }

  /// Writes `value` (in `chatSetting`'s words) through the setting's own store.
  func writeChatSetting(_ name: String, _ value: String) throws {
    if name == ChatSettings.approvalLevel {
      guard let next = ChatSettings.level(value) else { throw SereinError.invalid("approval_level takes every step, only risky steps or allow all.") }
      setLevel(next)
    } else if let toggle = ChatSettings.toggle(name) {
      guard let on = ChatSettings.flag(value) else { throw SereinError.invalid("\(name) takes on or off.") }
      Self.store(toggle).set(on, forKey: toggle.key)
    } else if AgentSetting(rawValue: name) != nil {
      _ = try AgentSettings.set(name, value)
    } else if let id = Self.modelOwner(name), team.profiles.contains(where: { $0.id == id }) {
      guard setProfileRoute(id, Self.route(value)) else { throw SereinError.invalid("That assistant's model did not change.") }
    } else {
      throw SereinError.invalid(ChatSettings.unknown(name))
    }
  }

  /// One change from the chat landed: kept for its Undo, and its receipt goes into `thread`.
  func settingChanged(_ change: SettingChange, title: String, shown: (String) -> String, into thread: String) -> Receipt {
    settingsLedger.landed(change)
    let receipt = ReceiptCopy.settingChanged(
      title: title, before: shown(change.before), after: shown(change.after), entry: ChatSettings.undoPrefix + change.id)
    deliver(receipt: receipt, into: thread)
    note("\(title): \(shown(change.after)), from the chat", .allowed)
    return receipt
  }

  /// Undo of a change from the chat: the value before goes back only while the setting still reads
  /// what the change wrote, and only once (`SettingsLedger.undo`).
  func undoSetting(_ entry: String) -> Result<Receipt, ChangeRefusal> {
    desk.undo.remove(entry)
    switch settingsLedger.undo(String(entry.dropFirst(ChatSettings.undoPrefix.count)), current: chatSetting) {
    case .refuse(let words): return .failure(ChangeRefusal(words))
    case .restore(let change):
      do { try writeChatSetting(change.name, change.before) } catch { return .failure(ChangeRefusal(error.localizedDescription)) }
      return .success(ReceiptCopy.undone())
    }
  }

  static func store(_ toggle: ChatSettings.Toggle) -> any SettingsStore {
    toggle.store == .gates ? GateSettings.shared : UserDefaults.standard
  }
  static func isOn(_ toggle: ChatSettings.Toggle) -> Bool { store(toggle).object(forKey: toggle.key) as? Bool ?? toggle.on }
  static func modelOwner(_ name: String) -> String? {
    let prefix = ChatSettings.model + ":"
    return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : nil
  }
  /// An assistant's own route as the ledger keeps it, exactly: "" is none (it thinks as Serein does).
  static func routeValue(_ route: AssistantRoute?) -> String {
    guard let route else { return "" }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return (try? encoder.encode(route)).map { String(decoding: $0, as: UTF8.self) } ?? ""
  }
  static func route(_ value: String) -> AssistantRoute? { try? JSONDecoder().decode(AssistantRoute.self, from: Data(value.utf8)) }
  static func routeWords(_ value: String) -> String { route(value).map(\.model).flatMap { $0.isEmpty ? nil : $0 } ?? "Serein's own" }
}

extension RelayToolHost {
  /// `setting_change {name, value, quote, assistant?}`: only in the person's own turn, with their
  /// words quoted exactly. The code floor, paying and secrets are refused by name before any lookup.
  func changeSetting(_ a: [String: Any]) async throws -> [String: Any] {
    let name = ((a["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let value = ((a["value"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let quote = (a["quote"] as? String) ?? ""
    guard !ChatSettings.refuses(name) else { throw SereinError.invalid(ChatSettings.floorWords) }
    guard frame.byPerson else { throw SereinError.invalid(RelayOrchestrator.settingPersonOnly) }
    guard !value.isEmpty else { throw SereinError.invalid("value is required.") }
    func admit(narrows: Bool) throws {
      let verdict = ChatSettings.admit(
        name: name, quote: quote, personMessages: [frame.typedWords], readOutside: frame.readOutside, narrows: narrows)
      if case .refuse(let words) = verdict { throw SereinError.invalid(words) }
    }
    let thread = frame.thread

    // "Ask me before you send mail": a rule every assistant obeys, with its own receipt and Undo.
    if name == ChatSettings.askBefore {
      try admit(narrows: true)
      let saved = try await relay.saveRule("Ask the person before \(value).", scope: "everyone", quote: quote, frame: frame)
      return ["rule": saved.record.text, "done": saved.receipt?.line ?? "That rule is already in force."]
    }

    if name == ChatSettings.model { return try await changeModel(a, value: value, admit: admit(narrows:)) }

    guard let before = relay.chatSetting(name) else { throw SereinError.invalid(ChatSettings.unknown(name)) }
    let narrows: Bool
    let title: String
    if name == ChatSettings.approvalLevel {
      guard let next = ChatSettings.level(value) else { throw SereinError.invalid("approval_level takes every step, only risky steps or allow all.") }
      narrows = ChatSettings.asks(next) >= ChatSettings.asks(relay.level)
      title = "How much Serein asks"
    } else if let toggle = ChatSettings.toggle(name) {
      narrows = ChatSettings.flag(value) == false
      title = toggle.title
    } else {
      narrows = name != AgentSetting.updateInstalls.rawValue || ChatSettings.flag(value) == false
      title = name.prefix(1).uppercased() + name.dropFirst().replacingOccurrences(of: "_", with: " ")
    }
    try admit(narrows: narrows)
    try relay.writeChatSetting(name, value)
    let after = relay.chatSetting(name) ?? value
    guard after != before else { return ["setting": name, "value": after, "note": "It already was \(after). Nothing changed."] }
    let receipt = relay.settingChanged(
      SettingChange(id: UUID().uuidString, name: name, before: before, after: after), title: title, shown: { $0 },
      into: thread)
    return ["setting": name, "value": after, "undo": receipt.undo?.entry ?? "", "done": receipt.line, "note": HostFacts.receiptNote]
  }

  /// An assistant's model, onto a listed route at the same cost only (`ModelFallback.sameCost`):
  /// a move that could change who pays stays the person's pick in the model list.
  private func changeModel(_ a: [String: Any], value: String, admit: (Bool) throws -> Void) async throws -> [String: Any] {
    let named = ((a["assistant"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback = acting ?? relay.team.profiles.first { $0.id == relay.team.activeID }
    guard let who = named.isEmpty ? fallback : relay.team.profile(named: named) else {
      throw SereinError.invalid(DeletePlan.Refusal.unknown.words)
    }
    let want = value.lowercased()
    let routes = relay.modelRegistry().rows.map(\.route).filter(\.selectable)
    guard let route = routes.first(where: { $0.id.lowercased() == want }) ?? routes.first(where: { $0.model.lowercased() == want })
    else { throw SereinError.invalid("No listed model is called \(String(value.prefix(60))). Use one the model list shows.") }
    let now = relay.assistantEngine(who)
    guard let from = relay.agent.routes(now.provider, models: [now.model]).first, from.id == route.id || ModelFallback.sameCost(from: from, to: route)
    else { throw SereinError.invalid(RelayOrchestrator.settingPays(who.name, route.model)) }
    try admit(false)
    let name = ChatSettings.model + ":" + who.id
    let before = RelayOrchestrator.routeValue(who.route)
    guard await relay.switchRoute(route, for: who.id) else {
      throw SereinError.invalid(RelayOrchestrator.assistantRouteRefusal(Provider(rawValue: route.provider)) ?? "\(who.name)'s model did not change.")
    }
    let after = relay.chatSetting(name) ?? ""
    guard after != before else { return ["model": route.model, "note": "\(who.name) already thinks with it. Nothing changed."] }
    let receipt = relay.settingChanged(
      SettingChange(id: UUID().uuidString, name: name, before: before, after: after), title: "\(who.name)'s model",
      shown: RelayOrchestrator.routeWords, into: frame.thread)
    return ["model": route.model, "assistant": who.name, "undo": receipt.undo?.entry ?? "", "done": receipt.line,
            "note": HostFacts.receiptNote]
  }
}
