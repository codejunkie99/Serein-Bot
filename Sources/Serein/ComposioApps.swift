import AppKit
import Foundation
import SereinCore

/// Connected apps through Composio: the person's Composio key in this Mac's Keychain and the
/// calls Serein makes with it (REST API v3.1, `x-api-key`; docs.composio.dev/reference). The key
/// goes only into the request header: never into a prompt, a tool result, a log or a file.
/// Composio holds the app sign-ins; Serein lists the accounts under one user id of its own.
@MainActor final class ComposioApps: ObservableObject {
  static let shared = ComposioApps()
  nonisolated static let switchKey = "serein.composio"
  /// The switch stands for the key: on only after a pasted key answered, off when it is removed.
  /// So no launch, turn or tool listing reads the Keychain.
  nonisolated static var available: Bool { GateSettings.shared.bool(forKey: switchKey) }
  /// "Read and change": off means Serein only reads; every change still asks when it is on.
  nonisolated static let changesKey = "serein.composio.changes"
  /// "Scheduled tasks may use this": off by default; on, scheduled runs may only read.
  nonisolated static let unattendedKey = "serein.connections.connectedApps.scheduled"
  /// Tool slugs the person blocked; they are not listed and are refused.
  nonisolated static let blockedKey = "serein.composio.blocked"
  nonisolated static var changesAllowed: Bool { GateSettings.shared.bool(forKey: changesKey) }
  nonisolated static var unattendedAllowed: Bool { GateSettings.shared.bool(forKey: unattendedKey) }
  nonisolated static var blocked: [String] {
    Array(Set((GateSettings.shared.stringArray(forKey: blockedKey) ?? []).compactMap(ConnectedApps.toolSlug))).sorted()
  }
  nonisolated static func setBlocked(_ slugs: [String]) {
    GateSettings.shared.set(Array(Set(slugs.compactMap(ConnectedApps.toolSlug))).sorted(), forKey: blockedKey)
  }
  static let base = "https://backend.composio.dev/api/v3.1"
  /// The user id Serein's connections live under in the person's Composio project.
  static let userID = "serein"
  private static let item = KeychainItem(service: "serein.composio", account: "api-key")
  /// No cookies, no cache, no redirect: the key header never reaches another host.
  private static let session = EphemeralHTTP.session(resourceTimeout: 90)

  @Published private(set) var on = ComposioApps.available
  @Published private(set) var accounts: [ConnectedApps.Account] = []
  /// The app whose hosted sign-in is open in the person's browser.
  @Published private(set) var waitingFor: String?
  /// The key once read or saved; `.some(nil)` is a failed read, kept until Settings opens again.
  private var key: String??
  /// Bumped by Turn off, so a Keychain read still in flight then does not cache the key again.
  private var generation = 0

  // MARK: the key

  private func apiKey() async throws -> String {
    switch key {
    case .some(.some(let cached)): return cached
    case .some(.none): throw SereinError.invalid(Self.unreadable)
    case .none: break
    }
    let item = Self.item
    let started = generation
    // Off the main thread: the Keychain can show a dialog, and nothing may wait on one here.
    let read: String? = await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
      DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: item.read()) }
    }
    guard generation == started else { throw SereinError.invalid(ConnectedApps.offMessage) }
    if key == nil { key = .some(read) }
    guard let value = key ?? nil else { throw SereinError.invalid(Self.unreadable) }
    return value
  }
  static let unreadable =
    "Serein could not read the Composio key from the Keychain. The user can paste it again in Settings › Connections."
  /// Settings › Connections opened: the next call reads the Keychain again after a failed read.
  func forgetFailedRead() {
    if case .some(nil) = key { key = nil }
  }
  /// Checks the pasted key with one listing, then keeps it in the Keychain (this device only) and
  /// turns connected apps on. A key that does not answer is not saved.
  func turnOn(key raw: String) async throws {
    let pasted = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pasted.isEmpty, !pasted.contains(where: \.isWhitespace) else {
      throw SereinError.invalid("Paste the whole key, without spaces.")
    }
    let listed = try await call("GET", "/connected_accounts", query: accountQuery, key: pasted)
    guard Self.item.replace(with: pasted) else { throw SereinError.invalid("The key could not be saved in the Keychain.") }
    key = .some(pasted)
    accounts = Self.accounts(listed)
    GateSettings.shared.set(true, forKey: Self.switchKey)
    on = true
  }
  /// Forgets the key on this Mac and sets its permissions back to read only, never unattended.
  /// The apps stay connected at Composio until disconnected there or here.
  /// False when the Keychain kept the item; everything else is off either way.
  @discardableResult func turnOff() -> Bool {
    let removed = Self.item.replace(with: nil)
    generation += 1
    GateSettings.shared.set(false, forKey: Self.changesKey)
    GateSettings.shared.set(false, forKey: Self.unattendedKey)
    key = nil
    accounts = []
    waitingFor = nil
    GateSettings.shared.set(false, forKey: Self.switchKey)
    on = false
    return removed
  }

  // MARK: accounts

  private var accountQuery: [URLQueryItem] {
    [URLQueryItem(name: "user_ids", value: Self.userID), URLQueryItem(name: "limit", value: "100")]
  }
  private static func accounts(_ listed: [String: Any]) -> [ConnectedApps.Account] {
    (listed["items"] as? [[String: Any]] ?? []).compactMap(ConnectedApps.Account.init)
  }
  func refresh() async throws {
    let listed = try await call("GET", "/connected_accounts", query: accountQuery)
    accounts = Self.accounts(listed)
    for account in accounts where account.status == "EXPIRED" || account.status == "FAILED" {
      RelayOrchestrator.shared?.needsRepair(
        "composio-\(account.id)-\(account.status)",
        "The connected app \(account.app) says “\(account.statusWords)”. Fix: connect it again in Settings › Connections.")
    }
  }
  /// Connects one app: finds or makes its auth config, asks Composio for a hosted sign-in link,
  /// opens it in the person's default browser (never an agent tab), and watches the new account
  /// for up to five minutes.
  func connect(app raw: String) async throws {
    guard let app = ConnectedApps.appSlug(raw) else {
      throw SereinError.invalid("Type the app's name as Composio writes it, such as linear or googledrive.")
    }
    guard waitingFor == nil else { return }
    waitingFor = app
    defer { if waitingFor == app { waitingFor = nil } }
    let config = try await authConfig(app)
    let body = try JSONSerialization.data(withJSONObject: ["auth_config_id": config, "user_id": Self.userID])
    let link = try await call("POST", "/connected_accounts/link", body: body)
    guard let address = link["redirect_url"] as? String, let url = URL(string: address),
      url.scheme?.lowercased() == "https", url.host != nil
    else { throw SereinError.invalid("Composio did not send a sign-in link for \(ConnectedApps.name(app)).") }
    let created = ConnectedApps.accountID(link["connected_account_id"] as? String)
    guard NSWorkspace.shared.open(url) else { throw SereinError.invalid("Serein could not open your browser.") }
    for _ in 0..<100 {
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      guard on, waitingFor == app else { return }
      try? await refresh()
      if let created, let account = accounts.first(where: { $0.id == created }), !account.pending { return }
    }
  }
  /// The person's own enabled auth config for the app, else a new Composio-managed one.
  private func authConfig(_ app: String) async throws -> String {
    let listed = try await call(
      "GET", "/auth_configs", query: [URLQueryItem(name: "toolkit_slug", value: app), URLQueryItem(name: "limit", value: "50")])
    let ready = (listed["items"] as? [[String: Any]] ?? []).first {
      ($0["status"] as? String)?.uppercased() == "ENABLED"
        && ConnectedApps.appSlug(($0["toolkit"] as? [String: Any])?["slug"] as? String) == app
    }
    if let id = ConnectedApps.accountID(ready?["id"] as? String) { return id }
    let body = try JSONSerialization.data(withJSONObject: [
      "toolkit": ["slug": app], "auth_config": ["type": "use_composio_managed_auth"],
    ])
    let made = try await call("POST", "/auth_configs", body: body)
    guard let id = ConnectedApps.accountID((made["auth_config"] as? [String: Any])?["id"] as? String) else {
      throw SereinError.invalid("Composio has no ready sign-in for \(ConnectedApps.name(app)). Set one up in Composio's dashboard, then connect again.")
    }
    return id
  }
  /// Disconnect: Composio deletes the account and revokes its sign-in at the app.
  func disconnect(_ account: ConnectedApps.Account) async throws {
    _ = try await call(
      "DELETE", "/connected_accounts/\(account.id)", query: [URLQueryItem(name: "revoke_on_delete", value: "true")])
    accounts.removeAll { $0.id == account.id }
    try? await refresh()
  }
  /// The account a call uses: the one named, else the app's only connected one.
  func account(app: String, id: String?) async throws -> ConnectedApps.Account {
    try await refresh()
    let mine = accounts.filter { $0.app == app }
    if let id {
      guard let named = mine.first(where: { $0.id == id }) else {
        throw SereinError.invalid("That account is not one of the user's \(ConnectedApps.name(app)) accounts. List them with connected_app_tools.")
      }
      guard named.active else { throw SereinError.invalid("That \(ConnectedApps.name(app)) account is not ready: \(named.statusWords).") }
      return named
    }
    let ready = mine.filter(\.active)
    guard ready.count == 1, let only = ready.first else {
      throw SereinError.invalid(ready.isEmpty
        ? ConnectedApps.noAccountMessage(app)
        : "The user has \(ready.count) \(ConnectedApps.name(app)) accounts. Pass account, from connected_app_tools.")
    }
    return only
  }

  // MARK: tools

  func tools(app: String, query: String?) async throws -> (tools: [ConnectedApps.Tool], total: Int) {
    var items = [URLQueryItem(name: "toolkit_slug", value: app), URLQueryItem(name: "limit", value: String(ConnectedApps.listLimit))]
    if let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
      items.append(URLQueryItem(name: "query", value: String(query.prefix(200))))
    }
    let listed = try await call("GET", "/tools", query: items)
    let blocked = Set(Self.blocked)
    let tools = (listed["items"] as? [[String: Any]] ?? []).compactMap(ConnectedApps.Tool.init)
      .filter { $0.app == app && !blocked.contains($0.slug) }
    return (tools, max(listed["total_items"] as? Int ?? tools.count, tools.count))
  }
  /// Composio's current definition of one tool: what the classifier and the card read.
  func tool(_ slug: String) async throws -> ConnectedApps.Tool {
    let raw = try await call("GET", "/tools/\(slug)")
    guard let tool = ConnectedApps.Tool(raw) else {
      throw SereinError.invalid("Composio has no tool \(slug).")
    }
    return tool
  }
  /// Runs a tool for one account, at the version that was checked, with `exact` (the JSON text
  /// the card showed) spliced in as the arguments byte for byte.
  func execute(_ tool: ConnectedApps.Tool, account: ConnectedApps.Account, exact: String, authorize: @escaping @MainActor () throws -> Void) async throws -> [String: Any] {
    var head: [String: Any] = ["connected_account_id": account.id, "user_id": Self.userID]
    if !tool.version.isEmpty { head["version"] = tool.version }
    let body = String(jsonString(head).dropLast()) + ",\"arguments\":" + exact + "}"
    return try await call("POST", "/tools/execute/\(tool.slug)", body: Data(body.utf8), authorize: authorize)
  }

  // MARK: requests

  /// One request with the key in its header. Paths are built only from checked slugs and ids.
  /// Errors name the status and Composio's message, redacted, with the key scrubbed out.
  private func call(
    _ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, key given: String? = nil, authorize: (@MainActor () throws -> Void)? = nil
  ) async throws -> [String: Any] {
    // Failures before the request leaves are status 0: nothing was sent.
    let key: String
    if let given {
      key = given
    } else {
      do { key = try await apiKey() } catch { throw Refusal(status: 0, message: error.localizedDescription) }
    }
    guard var parts = URLComponents(string: Self.base + path) else { throw Refusal(status: 0, message: "Bad Composio address.") }
    if !query.isEmpty { parts.queryItems = query }
    guard let url = parts.url else { throw Refusal(status: 0, message: "Bad Composio address.") }
    var request = URLRequest(url: url, timeoutInterval: 60)
    request.httpMethod = method
    request.setValue(key, forHTTPHeaderField: "x-api-key")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    // After credential awaits, immediately before transport dispatch. A step stopped here was
    // never sent: it did not run (`Refusal.turnedDown`), not an unknown outcome.
    do {
      try Task.checkCancellation()
      try authorize?()
    } catch is CancellationError {
      throw Refusal(status: 0, message: "Stopped before it was sent.")
    }
    let reply: (Data, URLResponse)
    do {
      reply = try await Self.session.data(for: request)
    } catch {
      throw SereinError.invalid("Serein could not reach Composio: \(error.localizedDescription)")
    }
    let (data, response) = reply
    guard let http = response as? HTTPURLResponse else { throw SereinError.invalid("No answer from Composio.") }
    guard data.count <= 8 * 1_048_576 else { throw SereinError.invalid("Composio's answer was too large.") }
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    guard (200..<300).contains(http.statusCode) else {
      let said = ((object["error"] as? [String: Any])?["message"] as? String) ?? ""
      let shown = AgentPrivacy.redact(said.replacingOccurrences(of: key, with: AgentPrivacy.replacement), limit: 300)
      switch http.statusCode {
      case 401:
        if given == nil {
          RelayOrchestrator.shared?.needsRepair(
            "composio-key", "Composio no longer accepts the saved key, so connected apps stop working. Fix: paste a new key in Settings › Connections.")
        }
        throw Refusal(status: 401, message: "Composio did not accept the key.")
      case 429: throw Refusal(status: 429, message: "Composio is limiting requests right now. Try again in a minute.")
      default:
        // Composio's message can echo the app's own words: fenced as untrusted.
        let echoed: String = shown.isEmpty ? "." : ": \(UntrustedText.outside("connected_app", shown))"
        throw Refusal(status: http.statusCode, message: "Composio answered \(http.statusCode)\(echoed)")
      }
    }
    return object
  }
  /// Composio answered with an error status, or (status 0) the request never left. A 4xx other
  /// than a timeout means it was turned down, so a write it carried did not run; anything else
  /// leaves that unknown.
  struct Refusal: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
    var turnedDown: Bool { status == 0 || ((400..<500).contains(status) && status != 408) }
  }
}

extension BrowserModel {
  /// connected_app_tools and connected_app_call, for Serein's own run only.
  /// - Unattended: nothing in a webhook run; nothing at all unless "Scheduled tasks may use this"
  ///   is on, and then reads only.
  /// - Reads run like a page read.
  /// - A write needs "Read and change", the main assistant acting and a pinned tool version. Its
  ///   arguments must pass redaction unchanged, and it follows the run's own level: a card binds
  ///   the account, tool, version and exact arguments, and is deferred when nobody is there.
  ///   Every write counts first; past `ConnectedApps.writeLimit` a level that asks allows more first.
  ///   Both answers go to agent history, failing closed. A write is never retried; a lost answer
  ///   reports that it is unknown whether it ran.
  func connectedApp(
    _ name: String, task id: String, operationID: UUID, arguments a: [String: Any]
  ) async throws -> [String: Any] {
    guard ComposioApps.available else { throw SereinError.invalid(ConnectedApps.offMessage) }
    let unattended = isUnattended(task: id)
    let authorityRelay = relayTask(id, tasks[id]) ?? RelayOrchestrator.shared
    let actionEpoch = authorityRelay?.actionEpoch
    // Serein reuses a task across turns; a still-present task is not the original run.
    guard let dispatchRun = agentTabs.hub?.runs.first(where: { $0.taskID == id && $0.isActive }) else {
      throw SereinError.invalid("The task has no active run")
    }
    if unattended {
      guard !webhookRun(task: id) else { throw SereinError.invalid(ConnectedApps.webhookMessage) }
      guard ComposioApps.unattendedAllowed else { throw SereinError.invalid(ConnectedApps.unattendedOffMessage) }
    }
    let apps = ComposioApps.shared
    if name == ConnectedApps.listTool {
      guard let rawApp = a["app"] as? String, !rawApp.trimmingCharacters(in: .whitespaces).isEmpty else {
        try await apps.refresh()
        return ConnectedApps.accountListing(assistantAccounts(apps.accounts, taskID: id))
      }
      guard let app = ConnectedApps.appSlug(rawApp) else { throw SereinError.invalid("app is a slug from connected_app_tools.") }
      if let refusal = assistantAppRefusal(key: AssistantScope.composioAppKey(app), app: ConnectedApps.name(app), taskID: id) {
        throw SereinError.invalid(refusal)
      }
      if let rawTool = a["tool"] as? String, !rawTool.isEmpty {
        guard let slug = ConnectedApps.toolSlug(rawTool) else { throw SereinError.invalid("tool is a tool's slug.") }
        guard !ComposioApps.blocked.contains(slug) else { throw SereinError.invalid(ConnectedApps.blockedMessage(slug)) }
        let tool = try await apps.tool(slug)
        guard tool.app == app else { throw SereinError.invalid("\(slug) is not one of \(ConnectedApps.name(app))'s tools.") }
        return ConnectedApps.toolDetail(tool)
      }
      let listed = try await apps.tools(app: app, query: a["query"] as? String)
      return ConnectedApps.toolListing(listed.tools, total: listed.total)
    }
    guard let app = ConnectedApps.appSlug(a["app"] as? String), let slug = ConnectedApps.toolSlug(a["tool"] as? String) else {
      throw SereinError.invalid("app and tool are slugs from connected_app_tools.")
    }
    if let refusal = assistantAppRefusal(key: AssistantScope.composioAppKey(app), app: ConnectedApps.name(app), taskID: id) {
      throw SereinError.invalid(refusal)
    }
    guard !ComposioApps.blocked.contains(slug) else { throw SereinError.invalid(ConnectedApps.blockedMessage(slug)) }
    guard let exact = PageTools.exactArguments(a["arguments"]) else {
      throw SereinError.invalid("arguments must be a JSON object of at most \(PageTools.argumentLimit) bytes.")
    }
    let named = (a["account"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    if named != nil, ConnectedApps.accountID(named) == nil { throw SereinError.invalid("account is an id from connected_app_tools.") }
    let tool = try await apps.tool(slug)
    guard tool.app == app else { throw SereinError.invalid("\(slug) is not one of \(ConnectedApps.name(app))'s tools.") }
    let account = try await apps.account(app: app, id: named)
    appRunState(id)
    let thread = threadID(forTask: id)

    if tool.kind == .read {
      // Asked again: the assistant's app list may have changed while a lookup waited.
      if let refusal = assistantAppRefusal(key: AssistantScope.composioAppKey(app), app: ConnectedApps.name(app), taskID: id) {
        throw SereinError.invalid(refusal)
      }
      tasks[id]?.appsUsed.insert(app)
      // What a connected app returns is the person's data: the chat loses Serein's computer.
      guard notePersonalRead(task: id) else { throw SereinError.invalid(Self.personalMarkFailed) }
      let response = try await apps.execute(tool, account: account, exact: exact) { [self] in
        try Task.checkCancellation()
        guard tasks[id]?.finished == false, dispatchRun.isActive,
          agentTabs.hub?.runs.first(where: { $0.taskID == id && $0.isActive }) === dispatchRun,
          (relayTask(id, tasks[id]) ?? RelayOrchestrator.shared) === authorityRelay,
          ComposioApps.available, !ComposioApps.blocked.contains(slug),
          isUnattended(task: id) == unattended, !unattended || ComposioApps.unattendedAllowed,
          actionEpoch == authorityRelay?.actionEpoch,
          assistantAppRefusal(key: AssistantScope.composioAppKey(app), app: ConnectedApps.name(app), taskID: id) == nil
        else { throw ComposioApps.Refusal(status: 0, message: ConnectedApps.offMessage) }
      }
      guard tasks[id] != nil else { throw SereinError.invalid("The task ended during this operation") }
      return ConnectedApps.result(tool, response: response)
    }

    // A write's card, unattended, reaches confirmAnswer, which defers an exact approval: it
    // neither runs nor disappears before the person can answer.
    let parsed: Any? = try? JSONSerialization.jsonObject(with: Data(exact.utf8))
    // The person's level, then the assistant's: an assistant with a scope of its own only reads.
    guard ComposioApps.changesAllowed else { throw SereinError.invalid(ConnectedApps.readOnlyMessage) }
    if let scoped = assistantScope(forTask: id) { throw SereinError.invalid(ConnectedApps.assistantReadOnly(scoped.profile.name)) }
    // Without a pinned version Composio runs its latest, which may not be what the card showed.
    guard !tool.version.isEmpty, tool.version.lowercased() != "latest" else {
      throw SereinError.invalid(ConnectedApps.unversionedMessage)
    }
    // A secret, a token or a link's query details are never sent to a connected app.
    guard AgentPrivacy.redact(exact) == exact else { throw SereinError.invalid(ConnectedApps.hiddenMessage) }
    if HandBack.containsCardNumber(exact) { throw SereinError.invalid(HandBack.message) }
    guard let relay = relayTask(id, tasks[id]) ?? RelayOrchestrator.shared else {
      throw SereinError.invalid(ActionAdmission.needsPerson)
    }
    // Until each assistant has its own level, only the main assistant changes anything (an older
    // assistant without a scope included).
    guard let acting = relay.actingProfile, acting.id == relay.team.mainProfileID else {
      throw SereinError.invalid(ConnectedApps.assistantReadOnly(relay.actingProfile?.name ?? "This assistant"))
    }
    // Counted before any card, so calls made side by side cannot pass the limit together.
    let count = (tasks[id]?.appWrites ?? 0) + 1
    tasks[id]?.appWrites = count
    var counted = true
    defer { if counted { tasks[id]?.appWrites -= 1 } }
    // The door at the run's standing; Allow all and Auto go on past the limit with no card.
    let door = { (effect: ApprovalGate.Effect) throws -> RelayAutonomy.Decision in
      try ApprovalDoor.answer(
        .init(.effect(effect), relay.standing(present: !unattended), taskID: id),
        facts: .init(
          secureField: false, botCheck: false, pays: .no, covered: false,
          path: nil, hostKeyChanged: nil, runsAnything: false, ref: "")
      ).decision()
    }
    if count > ConnectedApps.writeLimit {
      if try door(.change) == .ask {
        let more = await relay.confirmAnswer(
          ConnectedApps.limitTitle(), ConnectedApps.limitDetail, button: "Allow \(ConnectedApps.writeLimit) more",
          thread: thread, effect: .change)
        try recordAppAnswer(more, task: id, operationID: operationID)
        relay.note(ConnectedApps.limitTitle(), more == .yes ? .allowed : .declined)
        guard more == .yes else { throw SereinError.invalid(more == .no ? ConnectedApps.limitMessage : ActionAdmission.needsPerson) }
      }
      // A new allowance; writes counted side by side meanwhile stay counted.
      if (tasks[id]?.appWrites ?? 0) > ConnectedApps.writeLimit { tasks[id]?.appWrites -= ConnectedApps.writeLimit }
    }
    let stamp = "\(app)/\(slug)/\(account.id)"
    let gate = ApprovalGate.GateAction(kind: "connected_app", elementID: stamp, pageVersion: tool.version)
    let intent = ApprovalGate.record(gate, effect: tool.effect, mint: { UUID().uuidString })
    if let pending = tasks[id]?.pendingApprovals {
      tasks[id]?.pendingApprovals = ApprovalGate.mergePending(pending, intent)
    }
    let decision = try door(tool.effect)
    let recipients = parsed.map(ConnectedApps.recipients) ?? 0
    let answer: ApprovalGate.HumanAnswer
    if decision == .auto {
      answer = .yes
    } else {
      answer = await relay.confirmAnswer(
        ConnectedApps.cardTitle(app: ConnectedApps.name(app)),
        ConnectedApps.cardDetail(tool, account: account, recipients: recipients),
        thread: thread, more: ConnectedApps.approvalIdentity(app: app, tool: slug, version: tool.version,
          account: account.id, arguments: exact), moreName: "the exact action", moreOpen: true, effect: tool.effect)
    }
    try recordAppAnswer(answer, task: id, operationID: operationID)
    relay.note("\(ConnectedApps.name(app)): \(tool.name)", decision == .auto ? .auto : answer == .yes ? .allowed : .declined)
    guard tasks[id]?.finished == false else { throw SereinError.invalid("The task ended while awaiting approval") }
    // Still on, still allowed, attended or not as it was judged, and the same account and tool
    // definition as the card.
    guard ComposioApps.available, ComposioApps.changesAllowed, !ComposioApps.blocked.contains(slug),
      isUnattended(task: id) == unattended, (!unattended || ComposioApps.unattendedAllowed)
    else { throw SereinError.invalid(ConnectedApps.offMessage) }
    let live = try await apps.tool(slug)
    let liveAccount = try await apps.account(app: app, id: account.id)
    guard ApprovalGate.beforeInput(
      intent: intent, answer: answer, liveElement: "\(live.app)/\(live.slug)/\(liveAccount.id)",
      liveVersion: live.version, liveEffect: live.effect)
    else {
      throw SereinError.invalid(ActionAdmission.blocked(
        answer: answer, decision: decision, effectChanged: live.effect != intent.effect))
    }
    // What a connected app returns is the person's data: the chat loses Serein's computer.
    guard notePersonalRead(task: id) else { throw SereinError.invalid(Self.personalMarkFailed) }
    // Called after all lookups AND after execute's credential await. Once dispatched,
    // a remote write cannot be recalled; ambiguous responses must never be retried.
    @MainActor func authorizeDispatch() throws {
      try Task.checkCancellation()
      guard tasks[id]?.finished == false, dispatchRun.isActive,
        agentTabs.hub?.runs.first(where: { $0.taskID == id && $0.isActive }) === dispatchRun,
        (relayTask(id, tasks[id]) ?? RelayOrchestrator.shared) === authorityRelay,
        ComposioApps.available, ComposioApps.changesAllowed,
        !ComposioApps.blocked.contains(slug), isUnattended(task: id) == unattended,
        !unattended || ComposioApps.unattendedAllowed,
        authorityRelay === relay, actionEpoch == relay.actionEpoch,
        assistantScope(forTask: id) == nil,
        relay.actingProfile?.id == relay.team.mainProfileID,
        assistantAppRefusal(key: AssistantScope.composioAppKey(app), app: ConnectedApps.name(app), taskID: id) == nil
      else { throw ComposioApps.Refusal(status: 0, message: ConnectedApps.offMessage) }
    }
    try authorizeDispatch()
    counted = false
    tasks[id]?.appsUsed.insert(app)
    // Sent once. Turned down by Composio, or never sent, means it did not run; any other failure,
    // or an answer without a verdict, leaves it unknown, and nothing is resent.
    let response: [String: Any]
    do {
      response = try await apps.execute(tool, account: liveAccount, exact: exact, authorize: authorizeDispatch)
    } catch let refusal as ComposioApps.Refusal where refusal.turnedDown {
      tasks[id]?.appWrites -= 1
      throw SereinError.invalid(refusal.message + " It did not run.")
    } catch {
      StepJournal.live?.cannotTell()
      throw SereinError.invalid(ConnectedApps.unknownOutcome(app: app, reason: error.localizedDescription))
    }
    guard response["successful"] is Bool else {
      StepJournal.live?.cannotTell()
      throw SereinError.invalid(ConnectedApps.unknownOutcome(app: app, reason: "Composio's answer had no result."))
    }
    return ConnectedApps.result(tool, response: response)
  }

  /// A connected-app card's answer in agent history, as plugin tools record theirs. Fails closed:
  /// an answer that cannot be recorded runs nothing.
  private func recordAppAnswer(_ answer: ApprovalGate.HumanAnswer, task id: String, operationID: UUID) throws {
    guard let context = behaviorContexts[id] else { return }
    guard recordBehavior(
      context, .permissionAnswered, operationID: operationID, tool: .plugin,
      decision: answer == .yes ? .allowedOnce : .denied)
    else { throw SereinError.invalid("The connected app was not used because its approval could not be recorded.") }
  }

  /// The apps a run already called belong to that run: a new run on the task (Serein's chat
  /// reuses its task across turns) starts with none. Outside content is kept per thread instead.
  func appRunState(_ id: String) {
    let run = agentTabs.hub?.runs.first { $0.taskID == id && $0.isActive }?.id ?? ""
    guard let task = tasks[id], task.appRun != run else { return }
    tasks[id]?.appRun = run
    tasks[id]?.appsUsed = []
  }
}
