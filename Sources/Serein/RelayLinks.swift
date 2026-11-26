import AppKit
import Foundation
import Security
import SereinCore

/// Links one assistant owns (`OwnedLink`, SereinCore/AssistantTools.swift): the specs in
/// relay/links.json, never a secret; each secret in Keychain (`LinkSecrets`), made by Serein
/// (192 bits) and never shown to a model. The receiver (RelayHookServer) checks each delivery with
/// `HookGate.admit`, writes it to the work ledger and answers 200 only after that row is on disk;
/// the owner's unattended turn then reads `HookGate.Admitted.prompt` (`enqueueLink`). A pause or a
/// delete of the owner pauses its links (`pauseWork`), and Undo turns them on again.
extension RelayOrchestrator {
  static let linksFile = "relay/links.json"
  /// Links removed in their Undo window when Serein last quit: their secrets go at the next launch.
  static let removedLinksFile = "relay/links-removed.json"

  /// Reads both files through the unreadable guard (`readState`, SPEC I13): a file that does not
  /// decode is kept as it is and never written over. While links.json cannot be read, no secret
  /// goes, since the links it holds are not known.
  func loadLinks() {
    desk.links = readState([OwnedLink].self, Self.linksFile) ?? []
    let left: [OwnedLink] = readState([OwnedLink].self, Self.removedLinksFile) ?? []
    guard !left.isEmpty, !isUnreadable(Self.linksFile) else { return }
    for link in left where !desk.links.contains(where: { $0.id == link.id }) { LinkSecrets.remove(link.id) }
    persist([OwnedLink](), Self.removedLinksFile)
  }
  func saveLinks() { persist(desk.links, Self.linksFile) }
  private func saveRemovedLinks() {
    let kept: [OwnedLink] = desk.removedLinks.values.map(\.link)
    persist(kept, Self.removedLinksFile)
  }

  /// Pauses or turns on one link. False when there is no such link, or it is that way already.
  @discardableResult func setLinkPaused(_ id: String, _ paused: Bool) -> Bool {
    guard let i = desk.links.firstIndex(where: { $0.id == id }), desk.links[i].isPaused != paused else { return false }
    desk.links[i].paused = paused ? true : nil
    saveLinks()
    restartHookServer()
    return true
  }

  /// Removes one link and its secret at once (Undo of a make); the receiver stops taking it.
  @discardableResult func removeOwnedLink(_ id: String) -> OwnedLink? {
    guard let i = desk.links.firstIndex(where: { $0.id == id }) else { return nil }
    let link = desk.links.remove(at: i)
    saveLinks()
    LinkSecrets.remove(id)
    restartHookServer()
    return link
  }

  /// `hook_remove`: the link stops at once, and its secret stays for the Undo window
  /// (`purgeRemovedLinks`). The receipt with a 10-second Undo; nil when there is no such link.
  func removeLinkForUndo(_ id: String, now: Date = Date()) -> Receipt? {
    guard let i = desk.links.firstIndex(where: { $0.id == id }) else { return nil }
    let link = desk.links.remove(at: i)
    desk.removedLinks[id] = AssistantDesk.RemovedLink(link: link, at: now)
    saveLinks()
    saveRemovedLinks()
    restartHookServer()
    let entry = "unlink:" + id
    desk.undoActions[entry] = .unlink(id)
    return ReceiptCopy.linkRemoved(title: link.spec.name, entry: entry, now: now)
  }
  /// Undo of a removal, while the secret is still kept.
  func restoreRemovedLink(_ id: String) -> Bool {
    guard let removed = desk.removedLinks.removeValue(forKey: id) else { return false }
    desk.links.append(removed.link)
    saveLinks()
    saveRemovedLinks()
    restartHookServer()
    return true
  }
  /// Removed links whose Undo window passed lose their secret.
  func purgeRemovedLinks(now: Date) {
    let over: [String] = desk.removedLinks.filter { now.timeIntervalSince($0.value.at) >= UndoToken.removalWindow }
      .map { $0.key }
    guard !over.isEmpty else { return }
    for id in over {
      desk.removedLinks[id] = nil
      LinkSecrets.remove(id)
    }
    saveRemovedLinks()
  }

  /// `hook_make` after the admission rule: Serein makes the secret, Keychain keeps it, the spec
  /// is saved without it and the receiver starts again with the link. The receipt (Copy link,
  /// Undo), or nil when no secret could be made or kept.
  func addOwnedLink(_ spec: HookSpec) async -> Receipt? {
    guard let secret = Self.newLinkSecret(for: spec.auth) else { return nil }
    let id = spec.id
    let saved: Bool = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
      DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: LinkSecrets.save(secret, for: id)) }
    }
    guard saved else { return nil }
    desk.links.append(OwnedLink(spec: spec))
    saveLinks()
    openWorkLedger()
    restartHookServer()
    let entry = "link:" + id
    desk.undoActions[entry] = .link(id)
    var receipt = ReceiptCopy.linkMade(for: profileName(spec.owner), title: spec.name)
    receipt.item = id
    receipt.undo = UndoToken(entry: entry, kind: .hookMade)
    return receipt
  }

  /// 192 random bits: base64url for a bearer header or GitHub's signature, and "whsec_" with
  /// standard base64 for Standard Webhooks (`HookGate.standardKey`). nil when the system
  /// generator fails, so a link never gets a predictable secret.
  static func newLinkSecret(for auth: HookSpec.Auth) -> String? {
    var bytes = [UInt8](repeating: 0, count: 24)
    guard SecRandomCopyBytes(nil, bytes.count, &bytes) == errSecSuccess else { return nil }
    let data = Data(bytes)
    switch auth {
    case .standard:
      return "whsec_" + data.base64EncodedString()
    case .bearer, .github:
      let base = data.base64EncodedString()
      return base.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    }
  }

  /// Copy link, on a link's receipt (`Receipt.item`): the address and the secret go on the
  /// clipboard marked concealed, so clipboard managers skip them. The secret is read off the
  /// main thread and never shown in the chat or given to a model.
  func copyLink(_ id: String) {
    guard let link = desk.links.first(where: { $0.id == id }) else { return }
    let auth = link.spec.auth
    Task { [weak self] in
      let read: String? = await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
        DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: LinkSecrets.read(id)) }
      }
      guard let self else { return }
      guard let secret = read else {
        self.lastError = "Serein cannot read the link's secret now. Try again in a moment."
        return
      }
      Self.putConcealed(LinkAddress.copyText(id: id, auth: auth, secret: secret))
      ToastCenter.shared.show("Copied the link. Paste it in the other app.")
    }
  }
  private static func putConcealed(_ text: String) {
    let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    let board = NSPasteboard.general
    _ = board.clearContents()
    _ = board.declareTypes([.string, concealed], owner: nil)
    _ = board.setString(text, forType: .string)
    _ = board.setString("", forType: concealed)
  }

  /// A delivery the receiver admitted and wrote to the ledger: the link's last delivery time,
  /// then the owner's turn.
  func linkArrived(_ row: WorkLedger.Row, link id: String) {
    if let i = desk.links.firstIndex(where: { $0.id == id }) {
      desk.links[i].lastDelivery = row.created
      saveLinks()
    }
    enqueueLink(row)
  }
}

/// The secret of each owned link, in Keychain: service `LinkAddress.keychainService`, account the
/// link's id, readable after the first unlock, on this device only (so a delivery that comes while
/// the screen is locked can still be checked). No prompt, tool result, log or file holds one.
enum LinkSecrets {
  static func item(_ id: String) -> KeychainItem {
    KeychainItem(service: LinkAddress.keychainService, account: id, afterFirstUnlock: true)
  }
  /// The secret, or nil when there is none or Keychain refused. Call it off the main thread.
  static func read(_ id: String) -> String? { item(id).read() }
  /// Saves a secret. Call it off the main thread.
  static func save(_ secret: String, for id: String) -> Bool { item(id).replace(with: secret) }
  /// Removes a secret, off the main thread.
  static func remove(_ id: String) {
    let item = LinkSecrets.item(id)
    DispatchQueue.global(qos: .utility).async { _ = item.replace(with: nil) }
  }
}

/// Each link's runs of the last hour (`HookRate`), shared by the receiver's queue and kept across
/// its restarts.
final class LinkRates: @unchecked Sendable {
  private let lock = NSLock()
  private var rates: [String: HookRate] = [:]
  func rate(_ id: String) -> HookRate {
    lock.lock()
    defer { lock.unlock() }
    return rates[id] ?? HookRate()
  }
  func record(_ id: String, at time: Date) {
    lock.lock()
    defer { lock.unlock() }
    var rate = rates[id] ?? HookRate()
    rate.record(time)
    rates[id] = rate
  }
}

// MARK: - The tools

extension RelayToolHost {
  /// `hook_make`: the person's words that name it ("when GitHub opens a pull request, tell
  /// Release") make it at once; other words in their turn ask on a card, or at Allow all make it
  /// with the receipt's Undo; other turns are refused.
  func makeLink(_ a: [String: Any]) async throws -> [String: Any] {
    try requireReadableLinks()
    let actingID: String = frame.acting ?? relay.team.activeID
    let parsed = LinkDraft.parse(
      a, actingID: actingID, team: relay.team, existing: relay.desk.links.count, id: LinkAddress.newID(), now: Date())
    let spec: HookSpec
    switch parsed {
    case .success(let made): spec = made
    case .failure(let problem): throw SereinError.invalid(problem.words)
    }
    let owner = relay.profileName(spec.owner)
    let named = TypedConsent.names(.makeLink, in: frame.typedWords)
    let verdict = Admission.decide(.makeLink, turn: frame.admission, wordsNameIt: named)
    switch Admission.atLevel(verdict, turn: frame.admission, level: relay.level) {
    case .refuse(let why):
      throw SereinError.invalid(why)
    case .apply:
      break
    case .ask:
      let human = await relay.confirmAnswer(
        LinkDraft.cardTitle(owner: owner), LinkDraft.cardDetail(owner: owner, instruction: spec.instruction),
        button: LinkDraft.confirm, decline: LinkDraft.decline, thread: frame.thread, effect: .settings)
      guard human == .yes else {
        throw SereinError.invalid(human == .no ? "The person said not now. No link was made." : ActionAdmission.needsPerson)
      }
    }
    guard let receipt = await relay.addOwnedLink(spec) else {
      throw SereinError.invalid("Serein could not make and keep a secure secret, so no link was made. Try again.")
    }
    relay.deliver(receipt: receipt, into: frame.thread)
    return [
      "made": spec.name, "wakes": owner, "undo": receipt.undo?.entry ?? "",
      "note": HostFacts.receiptNote
        + " The person copies the link from the receipt. It works on this Mac only. Never ask for, repeat or guess a secret.",
    ]
  }

  /// Links change nothing while relay/links.json could not be read (SPEC I13): a new link's
  /// spec could not be kept, and a removal would write over the file.
  private func requireReadableLinks() throws {
    let path = RelayOrchestrator.linksFile
    if relay.isUnreadable(path) { throw SereinError.invalid(RelayStateFile.words(for: path)) }
  }

  /// `hook_list`: name, owner and the last delivery of each link. Never the address or the secret.
  func listLinks() -> [String: Any] {
    let links: [[String: Any]] = relay.desk.links.map { link in
      var out: [String: Any] = [
        "name": link.spec.name, "wakes": relay.profileName(link.spec.owner), "takes": LinkDraft.takes(link.spec.filter),
      ]
      out["last_delivery"] = link.lastDelivery.map { RelayToolHost.stamp($0) } ?? "never"
      if link.isPaused { out["paused"] = true }
      return out
    }
    return ["links": links, "max": LinkDraft.maxLinks]
  }

  /// `hook_remove {name}`: the person's turn removes it at once, with a 10-second Undo.
  func removeLink(_ a: [String: Any]) throws -> [String: Any] {
    if case .refuse(let why) = Admission.decide(.ownChange, turn: frame.admission, wordsNameIt: true) {
      throw SereinError.invalid(why)
    }
    try requireReadableLinks()
    let wanted = (a["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let found = relay.desk.links.first { link in
      link.id == wanted || link.spec.name.caseInsensitiveCompare(wanted) == .orderedSame
    }
    guard let link = found, let receipt = relay.removeLinkForUndo(link.id) else {
      throw SereinError.invalid("No link is called \(String(wanted.prefix(80))). hook_list lists them.")
    }
    relay.deliver(receipt: receipt, into: frame.thread)
    return ["removed": link.spec.name, "undo": receipt.undo?.entry ?? "", "note": HostFacts.receiptNote]
  }
}
