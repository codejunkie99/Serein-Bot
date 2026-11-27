import Foundation
import SereinCore

/// The shell side of `FillGuard`: the person's words and rules, what is saved, and each value read
/// from Keychain only at the fill. No value leaves this file except into `secureFill`'s arguments
/// and `FilledValues`, which hides it everywhere after.
extension BrowserModel {
  /// What the person typed in task `id`'s chat, or the chat that started it, and every saved rule.
  /// A run nobody started has no words, so it fills sign-ins but never a card or a pay.
  func personWords(task id: String) async -> FillGuard.PersonWords {
    let thread = isUnattended(task: id) ? nil : chatThread(task: id)
    return PersonSaid.shared.words(thread: thread, rules: await RelayOrchestrator.shared?.savedRules())
  }
  private func chatThread(task id: String) -> String? {
    threadID(forTask: id) ?? tasks[id]?.caller.flatMap { chatThread(task: $0) }
  }

  /// Sign-ins and their codes from `PasswordVault`, keys and cards from the Vault's saved records.
  func savedItems() -> [FillGuard.Item] {
    let vault = PasswordVault.shared
    let signIns = vault.entries.flatMap { saved in
      [FillGuard.Item(id: saved.id, name: saved.username, kind: .password, origins: [saved.origin])]
        + (vault.codes.contains(saved.id)
          ? [FillGuard.Item(id: saved.id, name: saved.username, kind: .code, origins: [saved.origin])] : [])
    }
    let records = (RelayOrchestrator.shared?.desk.secrets ?? []).filter { $0.savedAt != nil }.map { record in
      FillGuard.Item(
        id: record.id, name: record.name, kind: record.kind == .card ? .card : .key,
        origins: record.hosts.map { "https://" + $0 })
    }
    return signIns + records
  }

  /// The values for `item`'s field, read now; nil when Keychain has none or they do not fit.
  func savedValues(_ item: FillGuard.Item, parts: [SecureCard.Part]) async -> [String: String]? {
    var entry = SecretEntry()
    switch item.kind {
    case .password, .code:
      guard let saved = PasswordVault.shared.entries.first(where: { $0.id == item.id }) else { return nil }
      let value = item.kind == .password
        ? try? PasswordVault.shared.secret(saved) : (try? PasswordVault.shared.oneTimeCode(for: saved))??.code(at: Date())
      guard let value else { return nil }
      entry.key = value
    case .key, .card:
      let id = item.id
      guard let value = await Task.detached(operation: { SecretKeys.item(id).read() }).value else { return nil }
      if item.kind == .key {
        entry.key = value
      } else {
        let lines = value.components(separatedBy: "\n")
        guard lines.count == 4 else { return nil }
        (entry.number, entry.expiry, entry.cvc, entry.holder) = (lines[0], lines[1], lines[2], lines[3])
      }
    }
    return SecureCard.values(item.kind, parts: parts, entry)
  }

  /// Fills `card`'s field from `item` with no card shown, covers the one press after it, and leaves
  /// a receipt in the task's chat. nil when it could not fill, so the caller asks instead.
  func fillFromSaved(_ card: SecureCards.Card, _ item: FillGuard.Item, parts: [SecureCard.Part]) async -> [String: String]? {
    guard let values = await savedValues(item, parts: parts), let tab = card.tab else { return nil }
    guard await secureFill(card, values) == .filled else { return nil }
    for value in values.values { FilledValues.shared.add(value, task: card.task) }
    // Below Allow all a saved card still asks before Pay: a card pass with no amount covers no press.
    tasks[card.task]?.securePasses[tab.id] = SecureCard.Pass(
      tab: tab.id, pageVersion: tab.pageVersion, kind: card.kind,
      amount: card.kind == .card && !allowsAll(task: card.task) ? nil : card.amount,
      field: card.kind == .card ? nil : card.ref)
    if let thread = card.thread {
      let entry = UUID().uuidString
      secureCards.filledFromSaved[FillGuard.undoPrefix + entry] = card
      RelayOrchestrator.shared?.deliver(receipt: FillGuard.filled(item, host: card.host, entry: entry), into: thread)
    }
    return FillGuard.filledFields(item, host: card.host)
  }

  /// Undo on a fill's receipt: the field is emptied while its page is the one filled, and the
  /// press the fill covered is no longer covered.
  func undoFill(_ entry: String) async -> Bool {
    guard let card = secureCards.filledFromSaved.removeValue(forKey: entry), let tab = card.tab else { return false }
    if tasks[card.task]?.securePasses[tab.id]?.pageVersion == card.pageVersion { tasks[card.task]?.securePasses[tab.id] = nil }
    return await secureFill(card, ["clear": "1"]) == .filled
  }
}

extension RelayOrchestrator {
  /// Every saved rule, every assistant's own included, for `FillGuard`: a rule only ever adds an
  /// ask, so none is left out. nil when memory cannot be read, and then every fill and pay asks.
  func savedRules() async -> [MemoryRecord]? {
    guard let memory = await memoryStore() else { return nil }
    let readers = team.profiles.map { memoryReader($0.id) }
    return try? await memory.run { (store: MemoryStore) -> [MemoryRecord] in
      var seen = Set<MemoryRecord.ID>()
      return try readers.flatMap { try store.rules(reader: $0) }.filter { seen.insert($0.id).inserted }
    }
  }
}
