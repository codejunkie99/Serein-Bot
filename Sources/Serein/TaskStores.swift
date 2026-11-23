import Foundation
import os
import SereinCore
import WebKit

/// The persistent website data stores Serein makes for tasks that may use the person's sign-ins.
/// WebKit keeps such a store on disk until it is removed, so each identifier is written to a
/// ledger in the library (0600) before its store is used. A store is removed once no task and no
/// tab still uses it (`BrowserModel.taskStoresInUse`); one left by a crash or a quit goes at the
/// next launch. Only identifiers in the ledger are ever removed: a store Serein did not make is
/// never touched.
///
/// A kept sign-in (KeptSignIns) has a store of its own, made here and listed in GateSettings
/// instead of the ledger, so no release takes it. Sign out, Sign out of all and 30 days unused put
/// it back in the ledger, and the next release removes it.
@MainActor final class TaskStores {
  static let ledgerPath = "sessions/task-stores.json"
  private static let log = Logger(subsystem: "app.serein", category: "task-stores")
  /// Seconds before each removal attempt. WebKit refuses a store while a page still uses it, and a
  /// window holds a closed tab's view until it next draws, so the first attempts can fail.
  private static let retryDelays: [UInt64] = [1, 2, 4, 8, 16]
  private let library: Library
  /// Asked before each attempt; with no browser nothing is removed.
  weak var browser: BrowserModel?
  /// Made and not yet removed, as the ledger lists them.
  private var made: Set<UUID>
  private var removing: Set<UUID> = []
  /// The stores of sign-ins kept this launch, held open so a later task reads the very store the
  /// cookies just went into; none of them is released while held.
  private var keptOpen: [UUID: WKWebsiteDataStore] = [:]

  init(library: Library) {
    self.library = library
    let listed = library.load([String].self, from: Self.ledgerPath)
    // An unreadable ledger is overwritten by the next `make`; say so, since its stores stay behind.
    if listed == nil, FileManager.default.fileExists(atPath: library.root.appendingPathComponent(Self.ledgerPath).path) {
      Self.log.error("The task store ledger could not be read; the stores it listed stay on disk.")
    }
    made = Set((listed ?? []).compactMap(UUID.init(uuidString:)))
  }

  /// A new persistent store for one task, listed in the ledger before it is returned. A ledger
  /// that cannot be written does not stop the task: the store is still removed when it is free.
  func make() -> WKWebsiteDataStore {
    let id = UUID()
    made.insert(id)
    save()
    return WKWebsiteDataStore(forIdentifier: id)
  }

  /// Starts removing every listed store that nothing uses now. At launch no page uses any of
  /// them, so this also removes the stores a crash left behind.
  func release() {
    // A kept sign-in unused for 30 days ends here, at launch or when a task or tab lets go.
    let now = Date()
    let ended = KeptSignIns.listed().filter { $0.expired(now: now) }
    if !ended.isEmpty { end(ended) }
    // With nothing listed (no sign-ins task yet) no tab needs to be walked.
    let candidates = made.subtracting(removing)
    guard !candidates.isEmpty, let inUse = browser?.taskStoresInUse() else { return }
    // A kept sign-in's store stays while it is listed, even one a crash left in the ledger too.
    let kept = Set(KeptSignIns.listed().map(\.store)).union(keptOpen.keys)
    for id in candidates.subtracting(inUse).subtracting(kept) {
      removing.insert(id)
      Task { await remove(id) }
    }
  }

  private func remove(_ id: UUID) async {
    defer { removing.remove(id) }
    var failure = ""
    for delay in Self.retryDelays {
      try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
      // A page took the store again (a kept tab moved, a task began with it): the next release
      // decides once it is free.
      guard made.contains(id), keptOpen[id] == nil, let inUse = browser?.taskStoresInUse(), !inUse.contains(id),
        !KeptSignIns.listed().contains(where: { $0.store == id })
      else { return }
      do {
        WKWebsiteDataStore.startWebKit()
        try await WKWebsiteDataStore.remove(forIdentifier: id)
        forget(id)
        return
      } catch {
        // A store that never wrote anything has no folder, and one removed by hand is gone too.
        if !(await WKWebsiteDataStore.knownIdentifiers()).contains(id) {
          forget(id)
          return
        }
        failure = error.localizedDescription
      }
    }
    Self.log.error(
      "A task's website data store is still in use: \(failure, privacy: .public). It stays listed for the next release or launch."
    )
  }

  /// Whether `store` is one this ledger made for a task: never the person's own, a private
  /// window's, an isolated task's or a kept sign-in's.
  func isTaskStore(_ store: WKWebsiteDataStore) -> Bool {
    store !== WKWebsiteDataStore.default() && store.identifier.map { made.contains($0) } == true
  }

  /// Keep Serein signed in (Hand back): the cookies a page on one of `hosts` receives (the sign-in
  /// page's host and the tab's host now; each one's own and its parent domains', within `site`) go
  /// from a task's store into a new store of their own, listed in GateSettings (KeptSignIns) in
  /// place of the site's earlier one. A cookie the site keeps only for the session still ends when
  /// Serein quits. The number kept; 0 when there are none; nil when nothing could be kept (the
  /// store is not a task's, or the list could not be read or saved: the entry is then taken back
  /// and the new store removed).
  func keep(site: String, hosts: [String], from source: WKWebsiteDataStore) async -> Int? {
    guard !GateSettings.shared.unreadable, isTaskStore(source) else { return nil }
    let all: [HTTPCookie] = await source.httpCookieStore.allCookies()
    let cookies: [HTTPCookie] = all.filter { (cookie: HTTPCookie) -> Bool in
      guard KeptSignIns.covers(domain: cookie.domain, site: site) else { return false }
      return hosts.contains { (host: String) -> Bool in KeptSignIns.sent(domain: cookie.domain, to: host) }
    }
    guard !cookies.isEmpty else { return 0 }
    let store = make()
    guard let id = store.identifier else { return nil }
    // Held open from now: a release while the cookies go in never takes it.
    keptOpen[id] = store
    for cookie in cookies { await store.httpCookieStore.setCookie(cookie) }
    // The site's earlier kept store goes back in the ledger before the list stops naming it.
    if let earlier = KeptSignIns.listed().first(where: { $0.site == site }) {
      keptOpen[earlier.store] = nil
      made.insert(earlier.store)
      save()
    }
    let listed: Bool = KeptSignIns.save(KeptSignIn(site: site, store: id, lastUsed: Date()))
    guard listed else {
      // The failed save still holds in memory: take it back, so "couldn't keep" stays true.
      KeptSignIns.remove([site])
      keptOpen[id] = nil
      release()
      return nil
    }
    // Listed now: out of the ledger, so no release takes it.
    forget(id)
    release()
    return cookies.count
  }

  /// The kept store to read `signIn` from, when it is still there; nil for one removed by hand
  /// (opening it again would make an empty store nobody lists).
  private func keptSource(_ signIn: KeptSignIn) async -> WKWebsiteDataStore? {
    if let open = keptOpen[signIn.store] { return open }
    let present: [UUID] = await WKWebsiteDataStore.knownIdentifiers()
    guard present.contains(signIn.store) else { return nil }
    return WKWebsiteDataStore(forIdentifier: signIn.store)
  }

  /// Whether `signIn` can go into `target`: the target is a task's store (one this ledger made, or
  /// an isolated task's non-persistent one; never the person's or a kept one) and the kept store is
  /// still there. Checked before a use is recorded, so the record never names a copy that cannot happen.
  func canCopy(_ signIn: KeptSignIn, into target: WKWebsiteDataStore) async -> Bool {
    guard target !== WKWebsiteDataStore.default() else { return false }
    let targetID: UUID? = target.identifier
    if let targetID {
      guard targetID != signIn.store, made.contains(targetID) else { return false }
    } else {
      guard !target.isPersistent else { return false }
    }
    return await keptSource(signIn) != nil
  }

  /// A kept sign-in's cookies, its site's only, go into the store of the tab a task is about to load
  /// the site in (`canCopy`); how many.
  func copyKept(_ signIn: KeptSignIn, into target: WKWebsiteDataStore) async -> Int {
    guard await canCopy(signIn, into: target), let source = await keptSource(signIn) else { return 0 }
    let all: [HTTPCookie] = await source.httpCookieStore.allCookies()
    let cookies: [HTTPCookie] = all.filter { (cookie: HTTPCookie) -> Bool in
      KeptSignIns.covers(domain: cookie.domain, site: signIn.site)
    }
    for cookie in cookies { await target.httpCookieStore.setCookie(cookie) }
    return cookies.count
  }

  /// Sign out (Settings › Privacy, Clear browsing data): `site`'s kept sign-in, or every one for
  /// nil, ends now and its store is removed. False when the change could not be saved (it then
  /// holds until Serein quits).
  @discardableResult func signOut(_ site: String?) -> Bool {
    let ending = KeptSignIns.listed().filter { site == nil || $0.site == site }
    guard !ending.isEmpty else { return true }
    let saved = end(ending)
    release()
    return saved
  }

  /// Back in the ledger first, so a crash before the list changes leaves the store listed, never
  /// lost. Then no scheduled request names the sites any more (keeping one again later never
  /// revives an old request's), and every task a copy went into ends, with its run and its store.
  @discardableResult private func end(_ ending: [KeptSignIn]) -> Bool {
    for signIn in ending {
      keptOpen[signIn.store] = nil
      made.insert(signIn.store)
    }
    save()
    let sites: Set<String> = Set(ending.map(\.site))
    let saved: Bool = KeptSignIns.remove(sites)
    RelayOrchestrator.shared?.forgetSignInSites(sites)
    browser?.endTasks(usingKept: sites)
    return saved
  }

  private func forget(_ id: UUID) {
    made.remove(id)
    save()
  }

  private func save() {
    do { try library.save(made.map(\.uuidString).sorted(), to: Self.ledgerPath) } catch {
      Self.log.error("The task store ledger could not be written: \(error.localizedDescription, privacy: .public)")
    }
  }
}

extension BrowserModel {
  /// The site Hand back may offer to keep Serein signed in to: a tab taken over at a sign-in page,
  /// in this window (never a private one), still on that HTTPS site, whose store a task with
  /// sign-ins had (never the person's own or an isolated task's), on a site no Never rule covers.
  func keepableSite(_ tab: BrowserTab) -> String? {
    guard !tab.privateMode, tab.owner == nil, tabs.contains(where: { $0 === tab }),
      let host = tab.agentMark?.signIn, let site = KeptSignIns.site(tab.address),
      KeptSignIns.named(host) == site, SiteRules.rule(for: tab.address) != .never,
      taskStores.isTaskStore(tab.web.configuration.websiteDataStore)
    else { return nil }
    return site
  }

  /// The kept sign-ins a run nobody watches may use: those named on the creation card of the
  /// scheduled request Serein's own chat is running now (RelayReminder.signInSites). Every other
  /// unattended task (a watch, a webhook, a run Serein started) uses none.
  func unattendedSignIns(task id: String) -> Set<String> {
    guard tasks[id]?.allowRelay == true, let relay = RelayOrchestrator.shared, relay.runsUnattended else { return [] }
    return relay.scheduledSignInSites
  }

  /// Before Serein's own task opens `address` (open, go): the site's kept sign-in goes into the
  /// task's own store, once per task and site, after the site itself was allowed (authorizeSite).
  /// It is access to the person's account, so it always asks (`.access`); with nobody watching
  /// there is no card, and only a site the scheduled request's own creation card named is used.
  /// Never on a Never site, and never for a paired outside app (it has no agent history). Each use
  /// is a line in the task's steps and in agent history, recorded before the cookies go in. A no
  /// leaves the page signed out; only a task that ended while the card waited throws.
  func useKeptSignIn(
    _ address: String, taskID id: String, into target: WKWebsiteDataStore, tool: String, operationID: UUID
  ) async throws {
    guard let task = tasks[id], let site = KeptSignIns.site(address), !task.keptAsked.contains(site),
      KeptSignIns.kept(site) != nil, SiteRules.rule(for: address) != .never,
      let context = behaviorContexts[id]
    else { return }
    tasks[id]?.keptAsked.insert(site)
    let unattended = isUnattended(task: id)
    let relay = relayTask(id, task)
    var answer = ApprovalGate.HumanAnswer.no
    // The person's own sign-in: their card, at every level.
    if unattended {
      // The yes is the creation card's (RelayToolHost.createReminder), which named the site.
      if unattendedSignIns(task: id).contains(site) { answer = .yes }
    } else if let asker = relay ?? RelayOrchestrator.shared {
      answer = await asker.confirmAnswer(
        "Serein wants to use your sign-in on \(site)",
        "You kept Serein signed in to \(site). A yes lets this task act there signed in to your account, for this task only. A no opens the page signed out.",
        button: "Use sign-in", thread: threadID(forTask: id), site: site, effect: .access)
    }
    guard tasks[id]?.store === task.store else { throw SereinError.invalid("The task ended during this operation") }
    // Read again after the card: a Sign out or a Never rule set while it waited wins.
    guard answer == .yes, let signIn = KeptSignIns.kept(site), SiteRules.rule(for: address) != .never else {
      let why = unattended ? ": this scheduled request didn't name it" : ""
      agentTabs.noteBefore(AgentStep(tool: "kept_sign_in", label: "Stayed signed out of \(site)\(why)"), task: id)
      return
    }
    // Only a copy that can happen is recorded: the tab's store is a task's, the kept store is there.
    let possible: Bool = await taskStores.canCopy(signIn, into: target)
    guard tasks[id]?.store === task.store else { throw SereinError.invalid("The task ended during this operation") }
    guard possible else {
      agentTabs.noteBefore(AgentStep(tool: "kept_sign_in", label: "Your kept sign-in on \(site) is gone; stayed signed out"), task: id)
      return
    }
    // A Sign out while that check waited found no mark on this task yet: it wins here.
    guard KeptSignIns.kept(site)?.store == signIn.store else {
      agentTabs.noteBefore(AgentStep(tool: "kept_sign_in", label: "Stayed signed out of \(site)"), task: id)
      return
    }
    let decision: AgentHistoryEvent.Decision = unattended ? .alwaysAllowed : .allowedOnce
    guard recordBehavior(context, .keptSignInUsed, operationID: operationID, tool: .browser(tool), decision: decision) else {
      agentTabs.noteBefore(
        AgentStep(tool: "kept_sign_in", label: "Stayed signed out of \(site): agent history could not be saved"), task: id)
      return
    }
    // Marked before the copy: from here the task holds the sign-in, so it never carries into
    // another turn and a Sign out ends it.
    keptUsed[id, default: []].insert(site)
    let copied: Int = await taskStores.copyKept(signIn, into: target)
    guard tasks[id]?.store === task.store else { throw SereinError.invalid("The task ended during this operation") }
    KeptSignIns.touch(site)
    let label: String = copied > 0
      ? "Used your kept sign-in on \(site)" : "Your kept sign-in on \(site) had nothing left; stayed signed out"
    agentTabs.noteBefore(AgentStep(tool: "kept_sign_in", label: label), task: id)
  }

  /// Sign out, Sign out of all, Clear browsing data and the 30-day end reach running tasks: every
  /// task a copy of one of `sites` went into ends now, its run stopped, its kept result tab closed
  /// and its store released, as Stop does. A parked chat task ends with its warm process, so no
  /// later turn adopts it.
  func endTasks(usingKept sites: Set<String>) {
    var ids: [String] = []
    for (id, used) in keptUsed where !used.isDisjoint(with: sites) { ids.append(id) }
    for id in ids {
      if let hub = agentTabs.hub, let run = hub.runs.first(where: { $0.taskID == id && $0.isActive }) {
        hub.stop(run, message: "You signed Serein out of a site this task used.")
      }
      endTask(id)
      // Its kept result tab goes too: its page and store hold the signed-out site.
      let shown: [String] = agentTabs.entries.filter { $0.taskID == id }.map { $0.id }
      for tabID in shown { agentTabs.dismiss(tabID) }
    }
    taskStores.release()
  }
}

extension WKWebsiteDataStore {
  /// WebKit's class-level store calls crash in its run loop until something has started WebKit, and
  /// with no browser tabs nothing else may have by then.
  @MainActor static func startWebKit() { _ = WKWebsiteDataStore.default() }
  /// Every persistent store's identifier, safe to ask at any time.
  @MainActor static func knownIdentifiers() async -> [UUID] {
    startWebKit()
    return await allDataStoreIdentifiers
  }
}
