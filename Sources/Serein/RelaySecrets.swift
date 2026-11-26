import Foundation
import SereinCore

/// A saved secret's value: one Keychain item per record id, device-only. Never in a file, a prompt
/// or a tool answer. `service_request` reads keys (`SecretVault.plan` refuses a card); a page fill reads
/// a key or a card only for its own site (`SavedFills.swift`).
/// Settings › Vault lists the records and deletes one (`forgetSecret`); it never reads a value.
enum SecretKeys {
  static let service = "local.serein.secrets"
  static func item(_ id: String) -> KeychainItem { KeychainItem(service: service, account: id) }
  /// Each value by id; nil for one Keychain did not give. Call it off the main thread.
  static func read(_ ids: [String]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: ids.compactMap { id in item(id).read().map { (id, $0) } })
  }
}

extension RelayOrchestrator {
  static let secretsFile = "relay/secrets.json"
  func loadSecrets() { desk.secrets = readState([SecretRecord].self, Self.secretsFile) ?? [] }
  func saveSecrets() { persist(desk.secrets, Self.secretsFile) }

  func keepSecret(_ record: SecretRecord) {
    if let at = desk.secrets.firstIndex(where: { $0.id == record.id }) {
      desk.secrets[at] = record
    } else {
      desk.secrets.append(record)
    }
    saveSecrets()
  }

  /// Save from a secret card: the value to Keychain, then the record with its date. The words to
  /// show when it was not saved, or nil.
  func saveSecret(_ record: SecretRecord, _ entry: SecretEntry) -> String? {
    guard !isUnreadable(Self.secretsFile) else { return RelayStateFile.words(for: Self.secretsFile) }
    guard let value = SecretVault.value(record.kind, entry) else {
      return record.kind == .key ? SecretVault.notAKey : SecretVault.notACard
    }
    guard SecretKeys.item(record.id).replace(with: value) else { return "Keychain did not save it." }
    var saved = record
    saved.savedAt = Date()
    keepSecret(saved)
    return nil
  }

  /// Settings › Vault › Delete on a saved key or card: its value leaves the Keychain first, then its
  /// record. The words to show when it could not be removed, or nil. A placeholder a chat still holds
  /// stops working: `service_request` finds no record for it, and asks for the key again.
  func forgetSecret(_ record: SecretRecord) -> String? {
    guard !isUnreadable(Self.secretsFile) else { return RelayStateFile.words(for: Self.secretsFile) }
    guard SecretKeys.item(record.id).replace(with: nil) else { return "Keychain did not remove it." }
    desk.secrets.removeAll { $0.id == record.id }
    saveSecrets()
    return nil
  }

  /// Save from the card a pasted key opened: the person names the service and its address. The Vault's
  /// New item saves a key the same way.
  func savePastedSecret(_ entry: SecretEntry) -> String? {
    let raw = entry.address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let host = SecretVault.host(URLComponents(string: raw)?.host ?? raw) else { return "Type the address, such as api.stripe.com." }
    switch SecretVault.record(name: entry.service, hosts: [host], kind: .key, records: desk.secrets) {
    case .failure: return "Type the service's name, such as Stripe."
    case .success(let record): return saveSecret(record, entry)
    }
  }
}

extension RelayToolHost {
  /// `secret_ask {name, hosts, kind}`: the placeholder when it is saved, else the secret card
  /// under this reply. Only in a turn the person started.
  func secretAsk(_ a: [String: Any]) throws -> [String: Any] {
    switch SecretVault.ask(a, personStarted: frame.byPerson, records: relay.desk.secrets) {
    case .refused(let words):
      throw SereinError.invalid(words)
    case .saved(let record):
      return SecretVault.answer(record, saved: true)
    case .show(let record):
      guard !relay.isUnreadable(RelayOrchestrator.secretsFile) else {
        throw SereinError.invalid(RelayStateFile.words(for: RelayOrchestrator.secretsFile))
      }
      guard let link = ConnectLink(app: record.id, name: record.name, kind: .secret) else {
        throw SereinError.invalid(SecretVault.badName)
      }
      relay.keepSecret(record)
      let thread = frame.thread
      let shown: [ConnectLink] = relay.desk.facts[thread]?.connect ?? []
      if !shown.contains(link) { relay.deliver(receipt: nil, connect: [link], into: thread) }
      return SecretVault.answer(record, saved: false)
    }
  }

  /// `service_request {method, url, headers, body}`: checked with every placeholder still in,
  /// asked like a connected app's write unless it only reads, filled from Keychain, sent with no
  /// cookies or redirects, and read back with each value replaced by its marker.
  func serviceRequest(_ a: [String: Any]) async throws -> [String: Any] {
    let plan: SecretVault.Plan
    switch SecretVault.plan(a, records: relay.desk.secrets) {
    case .failure(let refusal): throw SereinError.invalid(refusal.words)
    case .success(let checked): plan = checked
    }
    let answer = SecretVault.decision(plan.effect, standing(present: frame.admission != .unattended))
    // A payment goes only on the person's yes to this exact request: the card below is its pay step.
    if try answer == .blocked(.pay(ref: "")) || answer.decision() == .ask {
      let human = await relay.confirmAnswer(
        "Send a request to \(plan.host)?", ApprovalGate.askLine(plan.effect), button: "Send", decline: "Don't send",
        thread: frame.thread, more: plan.shown, moreName: "the request", moreOpen: true, effect: plan.effect)
      relay.note("A request to \(plan.host)", human == .yes ? .allowed : .declined)
      guard human == .yes else {
        throw SereinError.invalid(human == .no ? ActionAdmission.declined : ActionAdmission.needsPerson)
      }
    }
    let ids = plan.secrets.map(\.id)
    let values = await Task.detached { SecretKeys.read(ids) }.value
    let request: URLRequest
    switch SecretVault.fill(plan, values: values) {
    case .failure(let refusal): throw SereinError.invalid(refusal.words)
    case .success(let filled): request = filled
    }
    do {
      let (body, response) = try await EphemeralHTTP.session().data(for: request)
      let http = response as? HTTPURLResponse
      return SecretVault.answer(
        status: http?.statusCode ?? 0, contentType: http?.value(forHTTPHeaderField: "Content-Type"), body: body, values: values)
    } catch {
      throw SereinError.invalid(SecretVault.scrub("The request did not go through: \(error.localizedDescription)", values: values))
    }
  }
}
