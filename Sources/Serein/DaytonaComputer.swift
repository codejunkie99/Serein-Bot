import Foundation
import SereinCore

/// The person's Daytona account on this Mac (HostedAccount): the key, sent only to Daytona's own
/// three hosts as a Bearer header (DaytonaWire.Call.urlRequest), which is the one way Daytona lets
/// anything into a sandbox. Daytona's keys reach every sandbox of their organization, so Settings
/// asks for a dedicated organization.
@MainActor final class DaytonaAccount: HostedAccount {
  static let shared = DaytonaAccount()

  private init() { super.init(provider: "Daytona", item: KeychainItem(service: "serein.computer.daytona", account: "api-key")) }

  /// The snapshot computers are made from (Settings › Serein's computer › Daytona).
  var snapshot: String {
    let saved = UserDefaults.standard.string(forKey: DaytonaWire.snapshotKey) ?? ""
    return DaytonaWire.validSnapshot(saved) ? saved : DaytonaWire.defaultSnapshot
  }

  /// Settings' Check: lists Serein's own computers on the organization, a call that starts nothing.
  func check() async {
    guard let key = self.key() else {
      status = "No Daytona key is saved."
      return
    }
    do {
      let answer = try await Self.send(DaytonaWire.listComputers(), key: key, session: session)
      guard answer.status == 200, let count = DaytonaWire.readListCount(answer.body) else {
        throw SereinError.invalid(DaytonaWire.errorText(status: answer.status, body: answer.body, secrets: [key]))
      }
      status = "The key works. Serein has \(count) computer\(count == 1 ? "" : "s") on Daytona."
    } catch {
      status = AgentPrivacy.redact(error.localizedDescription)
    }
  }

  /// One call with the key in its one header; an answer over the call's own cap is refused unread.
  nonisolated static func send(_ call: DaytonaWire.Call?, key: String, session: URLSession) async throws -> HostedAccount.Answer {
    guard let request = call?.urlRequest(key: key), let limit = call?.limit else {
      throw SereinError.invalid("Serein could not make the Daytona request.")
    }
    return try await HostedAccount.send(request, limit: limit, provider: "Daytona", session: session)
  }
}

/// Serein's computer on Daytona (HostedComputer): a Linux VM sandbox of its own (its own kernel,
/// and a pause that keeps its memory) made from the person's snapshot under their account. Its own
/// internet is blocked and Serein's proxy carried over a command stream ("through this Mac"), or,
/// when the person opted in for it, it has Daytona's own internet, held to their list of sites
/// (`domainAllowList`) or, after a Widening card, open, which Serein can't limit. Serein uses a
/// computer only after Daytona's own record confirms that network, its closed preview and its
/// toolbox host; where Daytona does not enforce the block or the list (its Tiers 1 and 2), the
/// computer is deleted or left unused, and the person can leave its internet open instead. Screen
/// and input are Cua Driver where the snapshot carries it, else Daytona's own computer-use calls
/// (NativeScreen); everything else, the driver too, goes through
/// Serein's helper, whose stdin and stdout ride the command's text log under the helper's armor
/// (DaytonaStream). A reset deletes it, and the next start makes a new one with the checkpoint put
/// back. What it cost is Daytona's own report where the key may read it (ReportsUsage), else
/// Serein's estimate.
@MainActor final class DaytonaComputer: HostedComputer, NativeScreen, ReportsUsage {
  let capabilities = ComputerCapabilities.daytona
  /// Run where its template carries the driver, through `openStream` like the helper.
  var driverCommand: [String]? { CuaDriverRelease.boxCommand }
  var network: HostedNetwork = .throughThisMac
  var mayWake = true
  private let account: DaytonaAccount
  private(set) var sandboxID: String?
  /// From Daytona's record, for its usage report.
  private var organization: String?
  private var createdAt: Date?
  /// When Daytona last confirmed the computer: a start within a minute of it trusts it still.
  private var checkedAt: Date?
  /// The network that confirmation was for: a start with another one asks Daytona again.
  private var confirmedNetwork: HostedNetwork?
  private var runningSince: Date?
  private var spent: HostedUsage.Spent
  /// Sessions of the streams Serein holds now; any other of Serein's sessions inside is left over.
  private var attached = Set<String>()
  private let saveID: (String?) -> Void
  private let saveSpent: (HostedUsage.Spent) -> Void

  init(sandboxID: String?, spent: HostedUsage.Spent, account: DaytonaAccount, saveID: @escaping (String?) -> Void,
       saveSpent: @escaping (HostedUsage.Spent) -> Void) {
    self.sandboxID = sandboxID.flatMap { HostedWire.validID($0) ? $0 : nil }
    self.spent = spent
    self.account = account
    self.saveID = saveID
    self.saveSpent = saveSpent
  }

  var usage: HostedUsage.Spent {
    var now = spent
    if let runningSince { now.seconds += Date().timeIntervalSince(runningSince) }
    return now
  }

  private func call(_ call: DaytonaWire.Call?, _ key: String) async throws -> HostedAccount.Answer {
    try await DaytonaAccount.send(call, key: key, session: account.session)
  }
  private func failure(_ answer: HostedAccount.Answer, _ key: String) -> Error {
    if answer.status == 401 {
      RelayOrchestrator.shared?.needsRepair(
        "daytona-key", "Daytona rejected the saved key, so the Daytona computer can't start. Fix: paste a new Daytona key in Settings.")
    }
    return SereinError.invalid(AgentPrivacy.redact(DaytonaWire.errorText(status: answer.status, body: answer.body, secrets: [key])))
  }
  private func forget() {
    closeRun()
    sandboxID = nil
    organization = nil
    createdAt = nil
    attached = []
    // A new computer starts a new report.
    spent.reported = nil
    saveSpent(spent)
    saveID(nil)
  }
  /// A running stretch ends (pause, delete, quit): its time is added to the estimate.
  private func closeRun() {
    checkedAt = nil
    confirmedNetwork = nil
    guard let since = runningSince else { return }
    runningSince = nil
    spent.seconds += Date().timeIntervalSince(since)
    saveSpent(spent)
  }
  private var notRunning: Error { SereinError.invalid("Serein's computer on Daytona is not running.") }

  /// Daytona's own record of the computer; nil when Daytona no longer knows it.
  private func record(_ id: String, _ key: String) async throws -> DaytonaWire.Detail? {
    let answer = try await call(DaytonaWire.info(id), key)
    if answer.status == 404 { return nil }
    guard answer.status == 200, let detail = DaytonaWire.readDetail(answer.body), detail.id == id else { throw failure(answer, key) }
    return detail
  }
  /// Reads Daytona's record every two seconds until the computer is in one of `states`, or gone
  /// (nil). A state in `failing` (and the time running out) throws with Daytona's reason.
  private func settle(_ id: String, _ key: String, until states: Set<String>, failing: Set<String> = ["error", "build_failed"],
                      seconds: Double) async throws -> DaytonaWire.Detail? {
    let deadline = Date().addingTimeInterval(seconds)
    while true {
      guard let now = try await record(id, key), now.state != "destroyed" || states.contains("destroyed") else { return nil }
      if states.contains(now.state) { return now }
      if failing.contains(now.state) {
        let reason: String = now.errorReason.map { ": \($0)" } ?? "."
        throw SereinError.invalid("Daytona says the computer failed\(reason)")
      }
      guard Date() < deadline else {
        throw SereinError.invalid("Daytona did not finish with the computer in time (it says \(now.state)).")
      }
      try await Task.sleep(nanoseconds: 2_000_000_000)
    }
  }

  func start() async throws -> Bool {
    guard let key = account.key() else { throw SereinError.invalid(HostedCard.noKey("Daytona")) }
    if runningSince != nil, confirmedNetwork == network, let at = checkedAt, Date().timeIntervalSince(at) < 60 { return false }
    var created = false
    var desktopDown = false
    var known: DaytonaWire.Detail?
    if let id = sandboxID {
      // Deleted on Daytona's side (by the person, or another Mac): a new one is made below.
      known = try await settle(id, key, until: ["started", "paused", "stopped", "archived"], seconds: 180)
      if known == nil { forget() }
    }
    if let id = sandboxID, let now = known, !now.running {
      // Paused, stopped or archived (by Serein, by Daytona's own idle pause, or before a relaunch):
      // woken only when this start may, with new streams. Only a pause keeps the desktop running.
      closeRun()
      try wakeAllowed(provider: "Daytona")
      let answer = try await call(DaytonaWire.start(id), key)
      guard (200..<300).contains(answer.status) else { throw failure(answer, key) }
      desktopDown = now.state != "paused"
      known = try await settle(id, key, until: ["started"], seconds: 300)
      if known == nil { forget() }
    }
    if sandboxID == nil {
      try wakeAllowed(provider: "Daytona")
      guard let request = DaytonaWire.create(snapshot: account.snapshot, network: network) else {
        throw SereinError.invalid("The Daytona snapshot name in Settings › Serein's computer is not valid.")
      }
      let answer = try await call(request, key)
      guard (200..<300).contains(answer.status), let made = DaytonaWire.readDetail(answer.body) else {
        // Daytona's Tiers 1 and 2 refuse a block on a sandbox's own internet; any other refusal
        // (a wrong snapshot, a key without the right) is said as Daytona says it.
        let said = AgentPrivacy.redact(DaytonaWire.errorText(status: answer.status, body: answer.body, secrets: [key]))
        let words = said.lowercased()
        if network != .providerOpen, [400, 403].contains(answer.status),
          words.contains("network") || (network != .throughThisMac && words.contains("domain"))
        {
          throw SereinError.invalid((network == .throughThisMac ? Self.blockRefused : Self.listRefused) + " Daytona said: " + said)
        }
        throw failure(answer, key)
      }
      sandboxID = made.id
      saveID(made.id)
      created = true
      desktopDown = true
      // Kept until it started, so a computer that fails on the way stays listed and Delete can remove it.
      known = try await settle(made.id, key, until: ["started"], seconds: 300)
    }
    guard let id = sandboxID, var detail = known else { throw SereinError.invalid("Daytona removed the computer before it started.") }
    if let problem = refusal(detail) {
      if created { try await discard(id, key, because: problem) }
      // A computer that had Daytona's own internet is never moved in place to through this Mac:
      // Daytona's record can show the block before it is in force, and agent code that ran there
      // could fake the inside check. A Reset makes a new one, blocked from its creation.
      if network == .throughThisMac {
        let paused = (try? await call(DaytonaWire.pause(id), key)).map { (200..<300).contains($0.status) } ?? false
        if paused { closeRun() }
        throw SereinError.invalid(
          problem == Self.blockRefused || problem == HostedCard.notConfirmed("Daytona")
            ? "This computer used Daytona's own internet. Reset it in Settings › Serein's computer to make a new one that goes through this Mac."
            : problem + " Reset it in Settings › Serein's computer to make it again.")
      }
      // Nor is one moved in place into a list: it may have run agent code with its internet open
      // (so the inside check could be faked), or its block may stay beside the list. Only a
      // computer made with its list is held to one; edits to that list are applied in place.
      if case .provider = network, detail.domainAllow.isEmpty {
        let paused = (try? await call(DaytonaWire.pause(id), key)).map { (200..<300).contains($0.status) } ?? false
        if paused { closeRun() }
        throw SereinError.invalid(
          "This computer was made with another internet setting. Reset it in Settings › Serein's computer to make a new one held to your list of sites.")
      }
      // A computer made with an earlier internet setting gets Daytona's own internet, or a new
      // list, and Daytona must confirm it before anything runs; otherwise it is paused again and
      // not used. A removed site can stay reachable until Daytona applies the new list.
      let set = try await call(DaytonaWire.setNetwork(id, network), key)
      if (200..<300).contains(set.status), let read = try await record(id, key) { detail = read }
      if let still = refusal(detail) {
        let paused = (try? await call(DaytonaWire.pause(id), key)).map { (200..<300).contains($0.status) } ?? false
        if paused { closeRun() }
        throw SereinError.invalid(still + (still == Self.listRefused ? "" : " Reset it in Settings › Serein's computer to make it again."))
      }
    }
    spent.cpuCount = detail.cpu ?? spent.cpuCount
    spent.memoryMB = detail.memoryGB.map { $0 * 1024 } ?? spent.memoryMB
    organization = detail.organization ?? organization
    createdAt = detail.createdAt ?? createdAt
    if runningSince == nil { runningSince = Date() }
    checkedAt = Date()
    confirmedNetwork = network
    if !created { await endLeftovers(id, key) }
    if desktopDown { try await startDesktop(id, key) }
    return created
  }

  /// The text of the refusal through this Mac gets where Daytona does not block the internet.
  static let blockRefused =
    "Daytona did not switch off this computer's own internet (its Tiers 1 and 2 do not allow that), so it cannot go through this Mac and Serein did not use it. The user can give it Daytona's own internet in Settings › Serein's computer (on those tiers only with Only these sites off, which Serein can't limit), or run it somewhere else."
  /// The refusal Daytona's own internet held to a list gets where Daytona does not hold it there.
  static let listRefused =
    "Daytona did not hold this computer's internet to your list of sites (its Tiers 1 and 2 do not allow that), so Serein did not use it. The user can turn off Only these sites for it in Settings › Serein's computer, which gives it Daytona's own internet that Serein can't limit, or turn Daytona's internet off so it goes through this Mac."
  /// Why Serein may not use the computer Daytona's record describes, or nil.
  private func refusal(_ detail: DaytonaWire.Detail) -> String? {
    guard detail.sandboxClass == DaytonaWire.vmClass else {
      return "The Daytona snapshot \(account.snapshot) is not a Linux VM snapshot, which Serein's computer needs there (its own kernel, and a pause that keeps its memory)."
    }
    guard detail.toolboxKnown else {
      return "Daytona named a toolbox address for this computer that Serein does not send your key to, so Serein did not use it."
    }
    guard DaytonaWire.confirms(detail, network) else {
      guard detail.isPublic == false, !detail.outboundProxy else { return HostedCard.notConfirmed("Daytona") }
      switch network {
      case .throughThisMac: return Self.blockRefused
      // A list Daytona says it does not enforce; any other mismatch is not confirmed.
      case .provider: return detail.policyError != nil ? Self.listRefused : HostedCard.notConfirmed("Daytona")
      case .providerOpen: return HostedCard.notConfirmed("Daytona")
      }
    }
    return nil
  }
  /// A new computer Serein will not use goes at once. Its id is kept until Daytona confirms the
  /// delete, so Delete can retry it.
  private func discard(_ id: String, _ key: String, because reason: String) async throws -> Never {
    let gone = await deleted(id, key)
    if gone { forget() } else { closeRun() }
    throw SereinError.invalid(reason + (gone ? "" : " It is still on Daytona: Delete it in Settings › Serein's computer."))
  }
  /// Asks Daytona to delete the computer and reads its record until it is gone.
  private func deleted(_ id: String, _ key: String) async -> Bool {
    guard let answer = try? await call(DaytonaWire.delete(id), key) else { return false }
    if answer.status == 404 { return true }
    guard (200..<300).contains(answer.status) else { return false }
    do {
      // nil: Daytona no longer knows it. A throw: not gone in time, or the record could not be read.
      let after = try await settle(id, key, until: ["destroyed"], failing: [], seconds: 120)
      return after == nil || after?.state == "destroyed"
    } catch {
      return false
    }
  }

  /// Helper and shim processes from before a pause, a quit or a dropped stream would hold the
  /// shim's port: Serein's sessions it no longer holds are deleted, and while it holds none, any
  /// helper process left inside is ended.
  private func endLeftovers(_ id: String, _ key: String) async {
    if let answer = try? await call(DaytonaWire.sessions(id), key), answer.status == 200,
      let sessions = DaytonaWire.readSessions(answer.body)
    {
      for session in sessions where !attached.contains(session) {
        _ = try? await call(DaytonaWire.closeSession(id, session: session), key)
      }
    }
    guard attached.isEmpty else { return }
    // `[h]` keeps the pattern from matching the shell that runs it.
    _ = try? await call(DaytonaWire.execute(id, command: "pkill -f '/opt/serein/[h]elper.py'; true", seconds: 15), key)
  }
  /// The desktop Daytona runs itself (Xvfb and XFCE), and the mark the helper's ping waits for,
  /// which Serein's own start script leaves on its other places.
  private func startDesktop(_ id: String, _ key: String) async throws {
    let answer = try await call(DaytonaWire.startDesktop(id), key)
    guard (200..<300).contains(answer.status) else { throw failure(answer, key) }
    let marked = try await call(DaytonaWire.execute(id, command: "mkdir -p /tmp/serein && echo ready > /tmp/serein/ready", seconds: 15), key)
    guard (200..<300).contains(marked.status) else { throw failure(marked, key) }
  }

  private func open(_ command: [String], stdin: Bool, onStdout: @escaping (Data) -> Void, onEnd: @escaping () -> Void) async throws
    -> DaytonaStream
  {
    guard let id = sandboxID, runningSince != nil, let key = account.key() else { throw notRunning }
    let session = DaytonaWire.sessionPrefix + UUID().uuidString.lowercased()
    let stream = try await DaytonaStream.open(
      sandbox: id, session: session, key: key, http: account.session, command: command,
      environment: HostedWire.environment(network), stdin: stdin, onStdout: onStdout,
      onEnd: { [weak self] in
        Task { @MainActor in
          self?.attached.remove(session)
          // The next start asks Daytona again instead of trusting the last answer.
          self?.checkedAt = nil
        }
        onEnd()
      })
    if !stream.isClosed { attached.insert(session) }
    return stream
  }

  func openStream(_ command: [String], stdin: Bool, onStdout: @escaping (Data) -> Void, onEnd: @escaping () -> Void)
    async throws -> ComputerStream
  {
    try await open(command, stdin: stdin, onStdout: onStdout, onEnd: onEnd)
  }

  /// One command to its end. Its input, when there is one, is uploaded first under a name of
  /// Serein's own and given to it as stdin, then removed.
  func runOnce(_ command: [String], input: URL?, sink: @escaping (Data) -> Void) async throws -> Int {
    var command = command
    if let input {
      let path = "/tmp/serein/input-" + UUID().uuidString.lowercased()
      try await putFile(input, at: path)
      command = ["/bin/sh", "-c", "\"$0\" \"$@\" < '\(path)'; code=$?; rm -f '\(path)'; exit $code"] + command
    }
    let stream = try await open(command, stdin: false, onStdout: sink, onEnd: {})
    return await stream.finished()
  }

  func putFile(_ file: URL, at path: String) async throws {
    guard let id = sandboxID, runningSince != nil, let key = account.key() else { throw notRunning }
    guard let request = DaytonaWire.upload(id, path: path)?.urlRequest(key: key) else {
      throw SereinError.invalid("Serein could not make the Daytona request.")
    }
    let (body, response) = try await account.session.upload(for: request, fromFile: file)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    // The answer comes from the computer's toolbox: an oversized one is refused, not parsed.
    guard body.count <= DaytonaWire.answerLimit else { throw SereinError.invalid("Daytona sent a longer answer than Serein reads.") }
    guard (200..<300).contains(status) else {
      throw SereinError.invalid(AgentPrivacy.redact(DaytonaWire.errorText(status: status, body: body, secrets: [key])))
    }
  }

  func keepAlive() async {
    guard runningSince != nil, let id = sandboxID, let key = account.key() else { return }
    _ = try? await call(DaytonaWire.keepRunning(id), key)
  }

  /// Paused with its memory (a VM): its apps carry on after a resume; only its disk is billed.
  func pause() async throws {
    guard let id = sandboxID else { return }
    // Without the key it cannot be paused: it is not shown as paused while it runs and bills.
    guard let key = account.key() else { throw SereinError.invalid(HostedCard.noKey("Daytona")) }
    let answer = try await call(DaytonaWire.pause(id), key)
    guard let now = try await record(id, key) else {
      forget()
      return
    }
    // Daytona pauses in the background: its yes, or its record already pausing, is enough.
    guard (200..<300).contains(answer.status) || ["pausing", "paused"].contains(now.state) else { throw failure(answer, key) }
    closeRun()
    await refreshUsage()
  }

  /// The computer is deleted; the next start makes a new one from the snapshot.
  func restart() async throws { try await delete() }

  /// Deleted on Daytona; only its record being gone forgets it, so an unconfirmed delete stays
  /// visible and can be tried again.
  func delete() async throws {
    guard let id = sandboxID else { return }
    guard let key = account.key() else { throw SereinError.invalid(HostedCard.noKey("Daytona")) }
    guard await deleted(id, key) else {
      throw SereinError.invalid("Daytona did not confirm that it deleted the computer.")
    }
    forget()
  }

  func stopForQuit(paused: Bool) {
    guard !paused, runningSince != nil, let id = sandboxID, let key = account.key(),
      let request = DaytonaWire.pause(id)?.urlRequest(key: key)
    else { return }
    closeRun()
    // If this does not land in time, Daytona pauses it on its own after `idleMinutes`.
    HostedAccount.sendBlocking(request, session: account.session, seconds: 5)
  }

  /// Daytona's own report of what this computer cost so far, when the key may read it; otherwise
  /// the line stays Serein's estimate.
  func refreshUsage() async {
    guard let id = sandboxID, let key = account.key() else { return }
    if organization == nil || createdAt == nil, let known = try? await record(id, key) {
      organization = known.organization
      createdAt = known.createdAt
    }
    guard let organization, let createdAt,
      let answer = try? await call(DaytonaWire.usage(organization: organization, sandbox: id, from: createdAt, to: Date()), key),
      answer.status == 200, let dollars = DaytonaWire.readUsage(answer.body)
    else { return }
    spent.reported = dollars
    saveSpent(spent)
  }

  /// Daytona's computer-use calls for the helper's screen and input ops (NativeScreen). Every
  /// argument is checked here as the helper checks it; nothing Daytona answers is used unread.
  func screen(_ op: String, _ a: [String: Any]) async throws -> [String: Any] {
    guard let id = sandboxID, runningSince != nil, let key = account.key() else { throw notRunning }
    func number(_ value: Any?, _ name: String) throws -> Int {
      if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
        abs(value.doubleValue) < 1_000_000
      {
        return Int(value.doubleValue)
      }
      if let text = value as? String, let parsed = Double(text), parsed.isFinite, abs(parsed) < 1_000_000 { return Int(parsed) }
      throw SereinError.invalid("\(name) must be a number")
    }
    func send(_ request: DaytonaWire.Call?, _ refusal: String) async throws -> HostedAccount.Answer {
      guard let request else { throw SereinError.invalid(refusal) }
      let answer = try await call(request, key)
      guard (200..<300).contains(answer.status) else { throw failure(answer, key) }
      return answer
    }
    switch op {
    case "screenshot":
      let answer = try await send(DaytonaWire.screenshot(id), "No computer.")
      guard let png = DaytonaWire.readScreenshot(answer.body) else { throw SereinError.invalid("Daytona sent no picture.") }
      return ["png": png]
    case "click":
      let button = String(describing: a["button"] ?? "left").lowercased()
      _ = try await send(
        DaytonaWire.click(id, x: try number(a["x"], "x"), y: try number(a["y"], "y"), button: button, double: a["double"] as? Bool ?? false),
        "x and y must be on the screen, and button is left, middle or right.")
      return [:]
    case "type":
      guard let text = a["text"] as? String, !text.isEmpty else { throw SereinError.invalid("text is required") }
      _ = try await send(DaytonaWire.type(id, text: text), "text is required")
      return [:]
    case "key":
      guard let presses = DaytonaWire.keyPresses(String(describing: a["key"] ?? "")) else {
        throw SereinError.invalid("key is a key name or chord like Return, Tab, ctrl+l")
      }
      for press in presses { _ = try await send(DaytonaWire.press(id, press), "No computer.") }
      return [:]
    case "scroll":
      let direction = String(describing: a["direction"] ?? "down").lowercased() == "up" ? "up" : "down"
      _ = try await send(
        DaytonaWire.scroll(id, x: try number(a["x"], "x"), y: try number(a["y"], "y"), direction: direction,
                           amount: try number(a["amount"] ?? 3, "amount")),
        "x and y must be on the screen.")
      return [:]
    case "windows":
      let answer = try await send(DaytonaWire.windows(id), "No computer.")
      guard let windows = DaytonaWire.readWindows(answer.body) else { throw SereinError.invalid("Daytona sent windows Serein could not read.") }
      return ["windows": windows]
    case "tree":
      let depth = try number(a["depth"] ?? 6, "depth")
      let answer = try await send(DaytonaWire.tree(id, depth: depth), "No computer.")
      guard let tree = DaytonaWire.renderTree(answer.body, window: a["window"] as? String, depth: depth) else {
        throw SereinError.invalid("The accessibility tree is not available in this computer.")
      }
      return ["tree": tree.text, "cut": tree.cut, "privacy_complete": !tree.cut && a["window"] == nil]
    default:
      throw SereinError.invalid("unknown op")
    }
  }
}

/// A command inside a Daytona computer kept open as a stream (HostedStream), in a session of its
/// own under the helper's armor. Its output is the command's log, followed over a WebSocket read
/// by a session of the stream's own on a serial queue (never the shared cooperative pool), one
/// message at a time: a slow reader, such as the proxy writing to a slow site, holds back only
/// this stream. Its stdin goes through HostedInput as ordered input calls of one base64 line each.
/// The session is deleted when the stream ends.
final class DaytonaStream: HostedStream, URLSessionWebSocketDelegate {
  private let onStdout: (Data) -> Void
  private let onEnd: () -> Void
  private let sandbox: String
  private let sessionID: String
  private let key: String
  /// The account's session, for the input and cleanup calls.
  private let http: URLSession
  /// Only on the stream's own queue: the log so far, why it ended, and whether it did.
  private var buffer = Data()
  private var failure: String?
  private var sawExit = false
  private var over = false

  private init(sandbox: String, sessionID: String, key: String, http: URLSession, onStdout: @escaping (Data) -> Void,
               onEnd: @escaping () -> Void) {
    self.sandbox = sandbox
    self.sessionID = sessionID
    self.key = key
    self.http = http
    self.onStdout = onStdout
    self.onEnd = onEnd
    super.init()
  }

  private static func send(_ call: DaytonaWire.Call?, key: String, http: URLSession) async throws -> HostedAccount.Answer {
    try await DaytonaAccount.send(call, key: key, session: http)
  }

  /// Starts `command` and returns once Daytona took it. Throws when it did not; then `onEnd` never
  /// fires. Otherwise `onEnd` fires once, when the stream ends.
  static func open(
    sandbox: String, session: String, key: String, http: URLSession, command: [String], environment: [String: String],
    stdin: Bool, onStdout: @escaping (Data) -> Void, onEnd: @escaping () -> Void
  ) async throws -> DaytonaStream {
    guard let line = DaytonaWire.armoredLine(command, environment: environment) else {
      throw SereinError.invalid("Serein could not start the command in its computer.")
    }
    let made = try await send(DaytonaWire.openSession(sandbox, session: session), key: key, http: http)
    guard (200..<300).contains(made.status) else {
      throw SereinError.invalid(AgentPrivacy.redact(DaytonaWire.errorText(status: made.status, body: made.body, secrets: [key])))
    }
    let ran: HostedAccount.Answer
    do {
      ran = try await send(DaytonaWire.run(sandbox, session: session, line: line), key: key, http: http)
    } catch {
      _ = try? await send(DaytonaWire.closeSession(sandbox, session: session), key: key, http: http)
      throw error
    }
    guard (200..<300).contains(ran.status), let commandID = DaytonaWire.readCommandID(ran.body),
      let logs = DaytonaWire.logs(sandbox, session: session, command: commandID)?.webSocketRequest(key: key)
    else {
      _ = try? await send(DaytonaWire.closeSession(sandbox, session: session), key: key, http: http)
      throw SereinError.invalid(AgentPrivacy.redact(DaytonaWire.errorText(status: ran.status, body: ran.body, secrets: [key])))
    }
    let stream = DaytonaStream(sandbox: sandbox, sessionID: session, key: key, http: http, onStdout: onStdout, onEnd: onEnd)
    if stdin {
      stream.attach(HostedInput(
        batchLimit: DaytonaWire.inputLimit,
        send: { batch in
          let answer = try await send(DaytonaWire.input(sandbox, session: session, command: commandID, data: batch), key: key, http: http)
          guard (200..<300).contains(answer.status) else { throw SereinError.invalid("Daytona refused the input.") }
        },
        end: { _ = try? await send(DaytonaWire.endInput(sandbox, session: session, command: commandID), key: key, http: http) },
        failed: { [weak stream] reason in
          // Fail closed: input that did not arrive ends the whole stream.
          stream?.note("Input to the computer failed: " + reason)
          stream?.close()
        }))
    }
    stream.begin(logs)
    return stream
  }

  /// The log is read by a session of this stream's own (EphemeralHTTP's settings, no redirect) on
  /// a serial queue; the session holds the stream until the log ends, then is let go. A ping every
  /// 30 seconds keeps an idle stream from being cut on the way, and ends it when the link is gone.
  private func begin(_ request: URLRequest) {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.name = "serein.computer.daytona-stream"
    let session = URLSession(configuration: EphemeralHTTP.configuration(), delegate: self, delegateQueue: queue)
    let task = session.webSocketTask(with: request)
    task.maximumMessageSize = 1 << 20
    state.lock()
    cancelReading = { task.cancel(with: .goingAway, reason: nil) }
    let gone = closed
    state.unlock()
    task.resume()
    if gone { task.cancel(with: .goingAway, reason: nil) }
    receive(task, session)
    Task.detached { [weak task] in
      while true {
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        guard let task, task.state == .running else { return }
        // A ping that fails means the link is gone: the stream ends (fail closed), and the next
        // call opens a new one, instead of every call waiting on a dead link.
        task.sendPing { error in if error != nil { task.cancel(with: .goingAway, reason: nil) } }
      }
    }
  }

  /// One message at a time: the next is asked for only after this one was handed on.
  private func receive(_ task: URLSessionWebSocketTask, _ session: URLSession) {
    task.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let message):
        let bytes: Data
        switch message {
        case .data(let data): bytes = data
        case .string(let text): bytes = Data(text.utf8)
        @unknown default: bytes = Data()
        }
        // The armor's last line ends the stream, whether or not Daytona closes the log.
        if self.take(bytes) && !self.sawExit {
          self.receive(task, session)
        } else {
          task.cancel(with: .goingAway, reason: nil)
          self.end(session)
        }
      case .failure(let error):
        if self.failure == nil, !self.sawExit { self.failure = AgentPrivacy.redact(error.localizedDescription) }
        self.end(session)
      }
    }
  }
  /// Hands on the output in the bytes so far; false when the stream is out of step.
  private func take(_ bytes: Data) -> Bool {
    buffer.append(bytes)
    do {
      for piece in try DaytonaWire.unarmor(&buffer) {
        switch piece {
        case .data(let data):
          if !sawExit { onStdout(data) }
        case .exit(let code):
          state.lock()
          exitCode = code
          state.unlock()
          sawExit = true
        }
      }
      return true
    } catch {
      failure = AgentPrivacy.redact(error.localizedDescription)
      return false
    }
  }
  /// The log ended: waiters get the exit code, the end fires once, and the session goes with its
  /// command, so nothing of it is left inside.
  private func end(_ session: URLSession) {
    guard !over else { return }
    over = true
    session.invalidateAndCancel()
    endReading()
    if let failure, !sawExit { note(failure) }
    let (sandbox, sessionID, key, http) = (self.sandbox, self.sessionID, self.key, self.http)
    Task { _ = try? await DaytonaStream.send(DaytonaWire.closeSession(sandbox, session: sessionID), key: key, http: http) }
    onEnd()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}
