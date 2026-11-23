import Foundation
import SereinCore

/// The person's E2B account on this Mac (HostedAccount): the key, sent only to E2B's platform
/// host as `X-API-Key` (E2BWire.Call.urlRequest); calls into a computer carry that computer's own
/// access token instead.
@MainActor final class E2BAccount: HostedAccount {
  static let shared = E2BAccount()

  private init() { super.init(provider: "E2B", item: KeychainItem(service: "serein.computer.e2b", account: "api-key")) }

  /// The template computers are made from (Settings › Serein's computer › E2B).
  var template: String {
    let saved = UserDefaults.standard.string(forKey: E2BWire.templateKey) ?? ""
    return E2BWire.validTemplate(saved) ? saved : E2BWire.defaultTemplate
  }

  /// Settings' Check: lists Serein's own computers on the account, a call that starts nothing.
  func check() async {
    guard let key = self.key() else {
      status = "No E2B key is saved."
      return
    }
    do {
      let answer = try await Self.send(E2BWire.listComputers(), secret: key, session: session)
      guard answer.status == 200, let count = E2BWire.readListCount(answer.body) else {
        throw SereinError.invalid(E2BWire.errorText(status: answer.status, body: answer.body, secrets: [key]))
      }
      status = "The key works. Serein has \(count) computer\(count == 1 ? "" : "s") on E2B."
    } catch {
      status = AgentPrivacy.redact(error.localizedDescription)
    }
  }

  /// One call with its secret in its one header; an answer over `E2BWire.answerLimit` is refused unread.
  nonisolated static func send(_ call: E2BWire.Call, secret: String, session: URLSession) async throws -> HostedAccount.Answer {
    guard let request = call.urlRequest(secret: secret) else { throw SereinError.invalid("Serein could not make the E2B request.") }
    return try await HostedAccount.send(request, limit: E2BWire.answerLimit, provider: "E2B", session: session)
  }
}

/// Serein's computer on E2B (HostedComputer): a computer of its own made from Serein's own
/// template under the person's account, with its own internet switched off and Serein's proxy
/// carried over a process stream ("through this Mac"), or, when the person opted in for it, E2B's
/// own internet held to their allowlist. Serein uses a computer only after E2B's own account of it
/// confirms that network and that its public addresses need its token. Pause keeps its memory;
/// a reset deletes it, and the next start makes a new one with the checkpoint put back.
@MainActor final class E2BComputer: HostedComputer, OwnedHomeCheckpoint {
  let capabilities = ComputerCapabilities.e2b
  /// Run where its template carries the driver, through `openStream` like the helper.
  var driverCommand: [String]? { CuaDriverRelease.boxCommand }
  var network: HostedNetwork = .throughThisMac
  var mayWake = true
  private let account: E2BAccount
  private(set) var sandboxID: String?
  /// The computer's access token, in memory only; every connect brings a fresh one.
  private var token: String?
  /// When E2B last confirmed the computer: a start within a minute of it trusts it still.
  private var checkedAt: Date?
  /// The network that confirmation was for: a start with another one asks E2B again.
  private var confirmedNetwork: HostedNetwork?
  private var runningSince: Date?
  private var spent: HostedUsage.Spent
  /// Pids of the long streams Serein holds now; any other helper process inside is left over.
  private var attached = Set<Int>()
  private(set) var previousID: String?
  private(set) var createAttempt: String?
  private var starting = false
  private let saveIDs: (String?, String?, String?) throws -> Void
  private let saveSpent: (HostedUsage.Spent) -> Void
  private let prepareDesktop: (() async throws -> Void)?
  private let accountKey: () -> String?
  private let send: (E2BWire.Call, String) async throws -> HostedAccount.Answer

  init(sandboxID: String?, previousID: String?, createAttempt: String?, spent: HostedUsage.Spent, account: E2BAccount, saveIDs: @escaping (String?, String?, String?) throws -> Void,
       saveSpent: @escaping (HostedUsage.Spent) -> Void, accountKey: (() -> String?)? = nil,
       send: ((E2BWire.Call, String) async throws -> HostedAccount.Answer)? = nil,
       prepareDesktop: (() async throws -> Void)? = nil) {
    self.prepareDesktop = prepareDesktop
    self.accountKey = accountKey ?? { account.key() }
    self.send = send ?? { call, key in try await E2BAccount.send(call, secret: key, session: account.session) }
    self.sandboxID = sandboxID.flatMap { HostedWire.validID($0) ? $0 : nil }
    self.spent = spent
    self.account = account
    self.previousID = previousID.flatMap { HostedWire.validID($0) && $0 != sandboxID ? $0 : nil }
    self.createAttempt = createAttempt
    self.saveIDs = saveIDs
    self.saveSpent = saveSpent
  }

  var usage: HostedUsage.Spent {
    var now = spent
    if let runningSince { now.seconds += Date().timeIntervalSince(runningSince) }
    return now
  }

  private func call(_ call: E2BWire.Call?, _ key: String) async throws -> HostedAccount.Answer {
    guard let call else { throw SereinError.invalid("Serein could not make the E2B request.") }
    return try await send(call, key)
  }
  private func failure(_ answer: HostedAccount.Answer, _ key: String) -> Error {
    if answer.status == 401 {
      RelayOrchestrator.shared?.needsRepair(
        "e2b-key", "E2B rejected the saved key, so the E2B computer can't start. Fix: paste a new E2B key in Settings.")
    }
    var secrets: [String] = [key]
    if let attempt = createAttempt, let proof = E2BWire.privateVerifier(attempt) { secrets.append(proof) }
    if let token { secrets.append(token) }
    return SereinError.invalid(AgentPrivacy.redact(E2BWire.errorText(status: answer.status, body: answer.body, secrets: secrets)))
  }
  private func forget(removalConfirmed: Bool = false) throws {
    let retained = removalConfirmed ? nil : createAttempt
    try saveIDs(nil, previousID, retained)
    createAttempt = retained
    closeRun()
    sandboxID = nil
    token = nil
    attached = []
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
  /// E2B's own account of the computer.
  private func confirmed(_ id: String, _ key: String) async throws -> E2BWire.Detail {
    let answer = try await call(E2BWire.info(id), key)
    guard answer.status == 200, let detail = E2BWire.readDetail(answer.body), detail.id == id else { throw failure(answer, key) }
    return detail
  }

  /// A rotated key may claim a positive match only when E2B returns this operation's
  /// private verifier and, when already known, the same immutable sandbox identity.
  private func resolveCreate(_ createAttempt: String, key: String) async throws -> String {
    let answer = try await call(E2BWire.findCreate(createAttempt), key)
    guard answer.status == 200 else { throw failure(answer, key) }
    guard let id = E2BWire.recoveredID(answer.body, attempt: createAttempt, hasMore: answer.hasNextPage),
      sandboxID == nil || sandboxID == id,
      E2BWire.matchesCreateKey(createAttempt, key: key) || E2BWire.privateVerifier(createAttempt) != nil || sandboxID == id else {
      throw SereinError.invalid("E2B has not confirmed one sandbox for creation " + E2BWire.createTag(createAttempt)
        + ". Check that E2B account for the serein-create tag. Resume checks again without ordering another computer.")
    }
    return id
  }

  private func acceptRecovered(_ id: String) throws {
    // Keep the receipt through desktop setup and checkpoint restore. A relaunch still owes
    // initialization until ComputerHost acknowledges the verified, restored machine.
    try saveIDs(id, previousID, createAttempt)
    sandboxID = id
  }

  /// Only the person's Settings confirmation calls this. An absent row alone cannot establish
  /// that the order failed, and another account's empty response cannot release this receipt.
  func clearVerifiedUncreatedAttempt(_ expected: String) async throws {
    try beginChange()
    defer { starting = false }
    guard createAttempt == expected, sandboxID == nil, let key = accountKey(),
      E2BWire.matchesCreateKey(expected, key: key) else {
      throw SereinError.invalid("Use the original E2B key and check the current creation before clearing it.")
    }
    let answer = try await call(E2BWire.findCreate(expected), key)
    guard answer.status == 200 else { throw failure(answer, key) }
    guard !answer.hasNextPage, E2BWire.readListCount(answer.body) == 0 else {
      throw SereinError.invalid("E2B still lists a match or could not confirm an empty result. The creation record is kept.")
    }
    try saveIDs(nil, previousID, nil)
    createAttempt = nil
  }

  private func beginChange() throws {
    guard !starting else { throw SereinError.invalid("E2B setup is already in progress.") }
    starting = true
  }

  func start() async throws -> Bool {
    try beginChange()
    defer { starting = false }
    guard let key = accountKey() else { throw SereinError.invalid(HostedCard.noKey("E2B")) }
    var rotatedMatch: String?
    if let createAttempt, !E2BWire.matchesCreateKey(createAttempt, key: key) {
      rotatedMatch = try await resolveCreate(createAttempt, key: key)
    }
    if createAttempt == nil, token != nil, runningSince != nil, confirmedNetwork == network, let at = checkedAt, Date().timeIntervalSince(at) < 60 {
      return false
    }
    var created = createAttempt != nil && sandboxID != nil
    var woke = false
    var sandbox: E2BWire.Sandbox?
    var detail: E2BWire.Detail?
    // Running as far as Serein knows: E2B says whether it still is, and no new token is asked for.
    if let id = sandboxID, token != nil, runningSince != nil {
      let answer = try await call(E2BWire.info(id), key)
      if answer.status == 404 {
        // Deleted on E2B's side (by the person, or another Mac): a new one is made.
        try forget()
      } else {
        guard answer.status == 200, let known = E2BWire.readDetail(answer.body), known.id == id else { throw failure(answer, key) }
        if known.running {
          detail = known
          _ = try? await call(E2BWire.keepRunning(id), key)
        } else {
          // E2B paused it on its own (its timeout): it is woken below, with new streams.
          closeRun()
          token = nil
        }
      }
    }
    var attachID = sandboxID
    if let createAttempt, sandboxID == nil {
      try wakeAllowed(provider: "E2B")
      if let rotatedMatch { attachID = rotatedMatch } else { attachID = try await resolveCreate(createAttempt, key: key) }
    }
    if let id = attachID, detail == nil {
      try wakeAllowed(provider: "E2B")
      let answer = try await call(E2BWire.connect(id), key)
      switch answer.status {
      case 200, 201:
        guard let known = E2BWire.readSandbox(answer.body), known.id == id else { throw SereinError.invalid("E2B sent an answer Serein could not read.") }
        if createAttempt != nil && sandboxID == nil {
          try acceptRecovered(id)
          created = true
        }
        sandbox = known
        woke = answer.status == 201
      case 404:
        if createAttempt != nil {
          throw SereinError.invalid("E2B listed the previous creation but could not connect it yet. Resume to check again.")
        }
        try forget()
      default:
        throw failure(answer, key)
      }
    }
    if sandboxID == nil {
      try wakeAllowed(provider: "E2B")
      let attempt = E2BWire.createAttempt(key: key)
      guard let request = E2BWire.create(template: account.template, network: network, attempt: attempt) else {
        throw SereinError.invalid("The E2B template name in Settings › Serein's computer is not valid.")
      }
      try saveIDs(nil, previousID, attempt)
      createAttempt = attempt
      let answer: HostedAccount.Answer
      do { answer = try await call(request, key) } catch {
        throw SereinError.invalid("E2B did not confirm whether it created the computer. Resume checks the original request.")
      }
      guard answer.status == 201 || answer.status == 200, let made = E2BWire.readSandbox(answer.body) else {
        let creationError = failure(answer, key)
        // These are definitive input, authentication, authorization or missing-template rejections.
        if [400, 401, 403, 404].contains(answer.status) {
          try saveIDs(nil, previousID, nil)
          createAttempt = nil
        }
        throw creationError
      }
      // If local persistence fails, the durable tag recovers this exact sandbox on next startup.
      do { try saveIDs(made.id, previousID, attempt) } catch {
        _ = try? await call(E2BWire.pause(made.id), key)
        throw error
      }
      sandboxID = made.id
      sandbox = made
      created = true
    }
    guard let id = sandboxID else { throw SereinError.invalid("E2B gave no computer.") }
    var confirmedDetail: E2BWire.Detail
    if let detail { confirmedDetail = detail } else { confirmedDetail = try await confirmed(id, key) }
    if !E2BWire.confirms(confirmedDetail, network) {
      if created {
        // Serein never uses a computer E2B did not make as asked: it goes at once. Its id is kept
        // until E2B confirms the delete, so Delete can retry and a later start can fix or pause it.
        let killed = (try? await call(E2BWire.kill(id), key)).map { [200, 204, 404].contains($0.status) } ?? false
        if killed {
          try forget(removalConfirmed: true)
        } else {
          closeRun()
          token = nil
        }
        throw SereinError.invalid(
          HostedCard.notConfirmed("E2B") + (killed ? "" : " It is still on E2B: Delete it in Settings › Serein's computer."))
      }
      // A computer made with an earlier internet setting gets the current one, and E2B must
      // confirm it before anything runs; otherwise it is paused again and not used.
      let set = try await call(E2BWire.setNetwork(id, network), key)
      if (200..<300).contains(set.status) { confirmedDetail = try await confirmed(id, key) }
      guard (200..<300).contains(set.status), E2BWire.confirms(confirmedDetail, network) else {
        let paused = (try? await call(E2BWire.pause(id), key)).map { [200, 204, 409].contains($0.status) } ?? false
        if paused {
          closeRun()
          token = nil
        }
        throw SereinError.invalid(HostedCard.notConfirmed("E2B") + " Reset it in Settings › Serein's computer to make it again.")
      }
    }
    guard let live = sandbox?.accessToken ?? token ?? confirmedDetail.accessToken else {
      throw SereinError.invalid("E2B sent no access token for the computer.")
    }
    token = live
    spent.cpuCount = confirmedDetail.cpuCount ?? spent.cpuCount
    spent.memoryMB = confirmedDetail.memoryMB ?? spent.memoryMB
    if runningSince == nil { runningSince = Date() }
    checkedAt = Date()
    confirmedNetwork = network
    if !created { try? await endLeftovers(id, live) }
    if created || woke {
      if let prepareDesktop { try await prepareDesktop() } else { try await startDesktop() }
    }
    return created
  }

  /// Helper and shim processes from before a pause, a quit or a dropped stream would hold the
  /// shim's port: every one Serein no longer holds is ended before new ones start.
  private func endLeftovers(_ id: String, _ token: String) async throws {
    let answer = try await call(E2BWire.listProcesses(id), token)
    guard answer.status == 200, let pids = E2BWire.readHelperPIDs(answer.body) else { return }
    for pid in pids where !attached.contains(pid) {
      _ = try? await call(E2BWire.killProcess(id, pid: pid), token)
    }
  }
  /// The desktop, if the template did not leave it running: Serein's own start script, detached.
  private func startDesktop() async throws {
    _ = try await runOnce(
      ["/bin/sh", "-c", "test -e /tmp/serein/ready || setsid /opt/serein/start.sh </dev/null >/dev/null 2>&1 &"],
      input: nil) { _ in }
  }

  func openShell(_ command: [String], onStdout: @escaping (Data) -> Void, onEnd: @escaping () -> Void)
    async throws -> ComputerStream?
  {
    try await openStream(command, stdin: true, user: HostedWire.shellUser, onStdout: onStdout, onEnd: onEnd)
  }
  func openStream(_ command: [String], stdin: Bool, onStdout: @escaping (Data) -> Void, onEnd: @escaping () -> Void)
    async throws -> ComputerStream
  {
    try await openStream(command, stdin: stdin, user: HostedWire.user, onStdout: onStdout, onEnd: onEnd)
  }
  private func openStream(_ command: [String], stdin: Bool, user: String, onStdout: @escaping (Data) -> Void,
                          onEnd: @escaping () -> Void) async throws -> ComputerStream
  {
    guard let id = sandboxID, let token else { throw SereinError.invalid("Serein's computer on E2B is not running.") }
    final class Pid { var value: Int? }
    let pid = Pid()
    let stream = try await E2BStream.open(
      sandbox: id, token: token, session: account.session, command: command, environment: HostedWire.environment(network),
      stdin: stdin, user: user, onStdout: onStdout,
      onEnd: { [weak self] in
        Task { @MainActor in
          if let value = pid.value { self?.attached.remove(value) }
          // The next start asks E2B again instead of trusting the last answer.
          self?.checkedAt = nil
        }
        onEnd()
      })
    pid.value = stream.pid
    if !stream.isClosed { attached.insert(stream.pid) }
    return stream
  }

  /// One command to its end. Its input, when there is one, is uploaded first under a name of
  /// Serein's own and given to it as stdin, then removed.
  func runOnce(_ command: [String], input: URL?, sink: @escaping (Data) -> Void) async throws -> Int {
    guard let id = sandboxID, let token else { throw SereinError.invalid("Serein's computer on E2B is not running.") }
    var command = command
    if let input {
      let path = "/tmp/serein/input-" + UUID().uuidString.lowercased()
      try await putFile(input, at: path)
      command = ["/bin/sh", "-c", "\"$0\" \"$@\" < '\(path)'; code=$?; rm -f '\(path)'; exit $code"] + command
    }
    let stream = try await E2BStream.open(
      sandbox: id, token: token, session: account.session, command: command, environment: HostedWire.environment(network),
      stdin: false, onStdout: sink, onEnd: {})
    return await stream.finished()
  }

  /// A fixed host-authored operation. Archive bytes uploaded for it live in root's private
  /// folder, so a desktop process cannot replace them between preflight and import.
  func checkpoint(_ operation: CheckpointOperation, input: URL?, sink: @escaping (Data) -> Void) async throws -> Int {
    guard let id = sandboxID, let token else { throw SereinError.invalid("The E2B computer is not running.") }
    let command = try operation.command(home: "/home/serein")
    func run(_ arguments: [String], output: @escaping (Data) -> Void) async throws -> Int {
      let stream = try await E2BStream.open(sandbox: id, token: token, session: account.session, command: arguments,
        environment: [:], stdin: false, user: "root", onStdout: output, onEnd: {})
      return await stream.finished()
    }
    guard let input else { return try await run(command, output: sink) }
    let path = "/root/.serein-checkpoint-" + UUID().uuidString
    do {
      try await putFile(input, at: path, checkpoint: true)
      let wrapper = ["/bin/sh", "-c", #"file="$1"; shift; "$@" < "$file"; code=$?; rm -f -- "$file"; exit "$code""#, "checkpoint", path]
      return try await run(wrapper + command, output: sink)
    } catch {
      // Also clean up if the upload or process handshake failed part way through.
      _ = try? await run(["/bin/rm", "-f", "--", path], output: { _ in })
      throw error
    }
  }

  func putFile(_ file: URL, at path: String) async throws { try await putFile(file, at: path, checkpoint: false) }
  private func putFile(_ file: URL, at path: String, checkpoint: Bool) async throws {
    guard let id = sandboxID, let token else { throw SereinError.invalid("Serein's computer on E2B is not running.") }
    guard let request = E2BWire.upload(id, path: path, checkpoint: checkpoint)?.urlRequest(secret: token) else {
      throw SereinError.invalid("Serein could not make the E2B request.")
    }
    let (body, response) = try await account.session.upload(for: request, fromFile: file)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    // The answer comes from the computer's own service: an oversized one is refused, not parsed.
    guard body.count <= E2BWire.answerLimit else { throw SereinError.invalid("E2B sent a longer answer than Serein reads.") }
    guard (200..<300).contains(status) else {
      throw SereinError.invalid(AgentPrivacy.redact(E2BWire.errorText(status: status, body: body, secrets: [token])))
    }
  }

  func keepAlive() async {
    guard runningSince != nil, let id = sandboxID, let key = account.key() else { return }
    _ = try? await call(E2BWire.keepRunning(id), key)
  }

  /// Paused with its memory: not billed while paused, kept until deleted.
  func pause() async throws {
    guard let id = sandboxID else { return }
    // Without the key it cannot be paused: it is not shown as paused while it runs and bills.
    guard let key = accountKey() else { throw SereinError.invalid(HostedCard.noKey("E2B")) }
    let answer = try await call(E2BWire.pause(id), key)
    // 409: E2B paused it already (its own timeout).
    guard [200, 204, 409].contains(answer.status) else { throw failure(answer, key) }
    closeRun()
    token = nil
  }

  /// The computer is deleted; the next start makes a new one from the template.
  func restart() async throws {
    try beginChange()
    defer { starting = false }
    try await deleteCurrent()
  }

  func prepareReplacement() async throws {
    try beginChange()
    defer { starting = false }
    try await reconcileForRemoval()
    if previousID != nil { try await deleteCurrent(); return }
    guard let id = sandboxID else { return }
    try await pause()
    try saveIDs(nil, id, nil)
    createAttempt = nil
    previousID = id
    sandboxID = nil
    token = nil
    attached = []
  }

  func finishReplacement() async throws {
    try beginChange()
    defer { starting = false }
    try await discardSource()
  }

  private func discardSource() async throws {
    guard previousID != nil || createAttempt != nil else { return }
    if let previousID { try await remove(previousID) }
    try saveIDs(sandboxID, nil, nil)
    previousID = nil
    createAttempt = nil
  }

  /// Deleted on E2B; only E2B's yes (or its "not found") forgets it, so an unconfirmed delete
  /// stays visible and can be tried again.
  func delete() async throws {
    try beginChange()
    defer { starting = false }
    try await deleteCurrent()
    try await discardSource()
  }

  private func reconcileForRemoval() async throws {
    if let createAttempt, sandboxID == nil {
      guard let key = accountKey() else { throw SereinError.invalid(HostedCard.noKey("E2B")) }
      let id = try await resolveCreate(createAttempt, key: key)
      _ = try await confirmed(id, key)
      try acceptRecovered(id)
    }
  }

  private func deleteCurrent() async throws {
    try await reconcileForRemoval()
    guard let id = sandboxID else { return }
    try await remove(id)
    try forget(removalConfirmed: true)
  }

  private func remove(_ id: String) async throws {
    guard let key = accountKey() else { throw SereinError.invalid(HostedCard.noKey("E2B")) }
    if let createAttempt, !E2BWire.matchesCreateKey(createAttempt, key: key) {
      _ = try await resolveCreate(createAttempt, key: key)
    }
    let answer = try await call(E2BWire.kill(id), key)
    guard [200, 204, 404].contains(answer.status) else { throw failure(answer, key) }
  }

  func stopForQuit(paused: Bool) {
    guard !paused, runningSince != nil, let id = sandboxID, let key = accountKey(),
      let request = E2BWire.pause(id)?.urlRequest(secret: key)
    else { return }
    closeRun()
    // If this does not land in time, E2B pauses it on its own after `providerTimeout`.
    HostedAccount.sendBlocking(request, session: account.session, seconds: 5)
  }
}

/// A process inside an E2B computer kept open as a stream (HostedStream). Its output comes as
/// E2B's streamed process events in one HTTPS answer, read by a session of the stream's own on a
/// serial queue of its own (never the shared cooperative pool): a slow reader, such as the proxy
/// writing to a slow site, holds back only this stream, and URLSession stops reading its socket
/// meanwhile. Its stdin goes through HostedInput as ordered `SendInput` calls.
final class E2BStream: HostedStream, URLSessionDataDelegate {
  private let onStdout: (Data) -> Void
  private let onEnd: () -> Void
  private let token: String
  /// Guarded by `state`.
  private(set) var pid = 0
  private var started: CheckedContinuation<Int, Error>?
  /// Only on the stream's own queue: the answer so far, its status, and why it ended.
  private var buffer = Data()
  private var status = 0
  private var errorBody = Data()
  private var failure: String?
  private var sawEnd = false
  /// Bytes sent in one SendInput request.
  static let batchLimit = 1 << 20

  private init(token: String, onStdout: @escaping (Data) -> Void, onEnd: @escaping () -> Void) {
    self.token = token
    self.onStdout = onStdout
    self.onEnd = onEnd
    super.init()
  }

  /// Starts `command` and returns once E2B says it started. Throws when it did not start; then
  /// `onEnd` never fires. Otherwise `onEnd` fires once, when the stream ends.
  static func open(
    sandbox: String, token: String, session: URLSession, command: [String], environment: [String: String], stdin: Bool,
    user: String = HostedWire.user, onStdout: @escaping (Data) -> Void, onEnd: @escaping () -> Void
  ) async throws -> E2BStream {
    guard let call = E2BWire.startProcess(sandbox, command: command, environment: environment, stdin: stdin, user: user),
      let request = call.urlRequest(secret: token)
    else { throw SereinError.invalid("Serein could not start the command in its computer.") }
    let stream = E2BStream(token: token, onStdout: onStdout, onEnd: onEnd)
    let pid = try await withCheckedThrowingContinuation { (started: CheckedContinuation<Int, Error>) in
      stream.begin(request, started: started)
    }
    stream.state.lock()
    stream.pid = pid
    stream.state.unlock()
    if stdin {
      // SendInput and CloseStdin go through the account's session, one at a time, in order.
      stream.attach(HostedInput(
        batchLimit: batchLimit,
        send: { batch in
          guard let call = E2BWire.sendInput(sandbox, pid: pid, data: batch) else { throw SereinError.invalid("No process.") }
          let answer = try await E2BAccount.send(call, secret: token, session: session)
          guard (200..<300).contains(answer.status) else { throw SereinError.invalid("E2B refused the input.") }
        },
        end: {
          if let call = E2BWire.closeInput(sandbox, pid: pid) { _ = try? await E2BAccount.send(call, secret: token, session: session) }
        },
        failed: { [weak stream] reason in
          // Fail closed: input that did not arrive ends the whole stream.
          stream?.note("Input to the computer failed: " + reason)
          stream?.close()
        }))
    }
    return stream
  }

  /// The answer is read by a session of this stream's own (EphemeralHTTP's settings, no redirect)
  /// on a serial queue; the session holds the stream until the answer ends, then is let go.
  private func begin(_ request: URLRequest, started: CheckedContinuation<Int, Error>) {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.name = "serein.computer.e2b-stream"
    let session = URLSession(configuration: EphemeralHTTP.configuration(), delegate: self, delegateQueue: queue)
    let task = session.dataTask(with: request)
    state.lock()
    self.started = started
    cancelReading = { task.cancel() }
    let gone = closed
    state.unlock()
    task.resume()
    if gone { task.cancel() }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    status = (response as? HTTPURLResponse)?.statusCode ?? 0
    completionHandler(.allow)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard status == 200 else {
      if errorBody.count <= E2BWire.answerLimit { errorBody.append(data.prefix(E2BWire.answerLimit + 1 - errorBody.count)) }
      // Past the cap nothing more is read: the download stops, and the status decides the error.
      if errorBody.count > E2BWire.answerLimit { dataTask.cancel() }
      return
    }
    guard !sawEnd else { return }
    buffer.append(data)
    do {
      while buffer.count >= 5 {
        let frame = try E2BWire.frameHead([UInt8](buffer.prefix(5)))
        let whole = buffer.startIndex + 5 + frame.length
        guard buffer.endIndex >= whole else { break }
        let payload = Data(buffer[(buffer.startIndex + 5)..<whole])
        buffer.removeSubrange(buffer.startIndex..<whole)
        if frame.end {
          failure = E2BWire.endError(payload)
          sawEnd = true
          buffer = Data()
          return
        }
        try handle(payload)
      }
    } catch {
      failure = AgentPrivacy.redact(error.localizedDescription)
      sawEnd = true
      dataTask.cancel()
    }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if status != 200 && status != 0 && failure == nil {
      failure = E2BWire.errorText(status: status, body: errorBody, secrets: [token])
    } else if let error, failure == nil, !sawEnd {
      failure = AgentPrivacy.redact(error.localizedDescription)
    }
    session.finishTasksAndInvalidate()
    finish()
  }

  private func handle(_ payload: Data) throws {
    guard let event = try E2BWire.processEvent(payload) else { return }
    switch event {
    case .start(let pid):
      state.lock()
      let waiting = started
      started = nil
      state.unlock()
      waiting?.resume(returning: pid)
    case .stdout(let data):
      onStdout(data)
    case .stderr(let data):
      note(String(decoding: data.prefix(300), as: UTF8.self))
    case .end(let code, let error):
      state.lock()
      exitCode = code
      state.unlock()
      if let error, !error.isEmpty { note(error) }
    case .keepalive:
      break
    }
  }

  /// The answer ended: waiters get the exit code, a command that never started fails its open,
  /// and a started one fires its end once.
  private func finish() {
    state.lock()
    let waiting = started
    started = nil
    state.unlock()
    endReading()
    if let waiting {
      waiting.resume(throwing: SereinError.invalid(failure ?? "The command did not start in Serein's computer."))
      return
    }
    if let failure { note(failure) }
    onEnd()
  }
}
