#if DEBUG
import Foundation
import SereinCore

/// Both platform and desktop calls use local fixtures. The lifecycle exercise can run offline.
@MainActor enum E2BCreateChecks {
  @MainActor private final class Fixture {
    var record = HostedSettings()
    var createStatus = 201
    var loseReply = true
    var failPersist = false
    var refuseAdoption = false
    var matchCount = 1
    var wrongTag = false
    var wrongProof = false
    var listedID: String?
    var storedTags: [String: String] = [:]
    var hasNext = false
    var connectStatus = 200
    var infoStatus = 200
    var failDesktop = false
    var posts = 0
    var allocations = 0
    var lists = 0
    var boots = 0
    var deleted: [String] = []
    var accountKey = "offline-fixture"
    var tag: String?
    let id = "test-sandbox-001"

    func machine() throws -> E2BComputer {
      let restored = try JSONDecoder().decode(HostedSettings.self, from: JSONEncoder().encode(record))
      return E2BComputer(sandboxID: restored.sandboxID, previousID: restored.checkpointSourceID,
        createAttempt: restored.e2bCreateAttempt, spent: restored.spent, account: .shared,
        saveIDs: { current, previous, attempt in
          if self.failPersist || (self.refuseAdoption && current != nil) { throw SereinError.invalid("fixture disk error") }
          self.record.sandboxID = current
          self.record.checkpointSourceID = previous
          self.record.e2bCreateAttempt = attempt
        }, saveSpent: { _ in }, accountKey: { self.accountKey }, send: { call, _ in
          try self.respond(call)
        }, prepareDesktop: {
          self.boots += 1
          if self.failDesktop { throw SereinError.invalid("fixture desktop error") }
        })
    }

    private func respond(_ call: E2BWire.Call) throws -> HostedAccount.Answer {
      func reply(_ status: Int, _ value: Any) throws -> HostedAccount.Answer {
        .init(status: status, body: try JSONSerialization.data(withJSONObject: value), hasNextPage: hasNext)
      }
      let machine = ["sandboxID": id, "envdAccessToken": "offline-sandbox-token"]
      if call.path == "/v2/sandboxes" && call.method == "POST" {
        posts += 1
        guard let attempt = record.e2bCreateAttempt, E2BWire.matchesCreateKey(attempt, key: accountKey),
          call.headers["Idempotency-Key"] == E2BWire.createTag(attempt), let body = call.body,
          let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any],
          let metadata = obj["metadata"] as? [String: String], metadata["serein-create"] == E2BWire.createTag(attempt),
          let proof = metadata["serein-recovery"], !E2BWire.createTag(attempt).contains(proof),
          metadata["serein"] == "computer"
        else { throw SereinError.invalid("fixture create lacked its durable receipt") }
        storedTags = metadata
        tag = attempt
        guard createStatus == 201 else { return try reply(createStatus, ["message": "fixture refusal"]) }
        allocations += 1
        if loseReply { throw URLError(.timedOut) }
        return try reply(201, machine)
      }
      if call.path.hasPrefix("/v2/sandboxes?") && call.method == "GET" {
        lists += 1
        let query = URLComponents(string: "https://fixture.invalid" + call.path)?.queryItems
        guard let tag, query?.first(where: { $0.name == "metadata" })?.value == "serein=computer&serein-create=" + E2BWire.createTag(tag)
        else { throw SereinError.invalid("fixture request did not target the exact receipt") }
        var tags = storedTags
        if wrongTag { tags["serein-create"] = "unrelated" }
        if wrongProof { tags["serein-recovery"] = "another verifier" }
        let row: [String: Any] = ["sandboxID": listedID ?? id, "metadata": tags]
        return try reply(200, Array(repeating: row, count: matchCount))
      }
      if call.method == "DELETE", call.path.hasPrefix("/sandboxes/") {
        deleted.append(String(call.path.dropFirst("/sandboxes/".count)))
        return try reply(204, [:])
      }
      if call.path.hasSuffix("/connect") { return try reply(connectStatus, machine) }
      if call.path == "/sandboxes/" + id, call.method == "GET" {
        return try reply(infoStatus, ["sandboxID": id, "state": "running", "allowInternetAccess": false,
          "network": ["allowPublicTraffic": false], "envdAccessToken": "offline-sandbox-token"])
      }
      if call.path.hasSuffix("/pause") { return try reply(204, [:]) }
      if call.path.hasSuffix("/timeout") { return try reply(204, [:]) }
      throw SereinError.invalid("unexpected fixture call " + call.logLine)
    }
  }

  static func run() async throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw SereinError.invalid(label) }
      print("PASS: " + label)
    }
    func failed(_ operation: () async throws -> Void) async -> Bool {
      do { try await operation(); return false } catch { return true }
    }
    let f = Fixture()
    let first = try f.machine()
    f.failPersist = true
    try check(await failed { _ = try await first.start() } && f.posts == 0, "a failed local journal write prevents a billed request")
    f.failPersist = false
    try check(await failed { _ = try await first.start() } && f.allocations == 1 && f.record.e2bCreateAttempt == f.tag,
      "a lost create response retains the exact operation across a relaunch")
    let reopened = try f.machine()
    f.accountKey = "other-account-fixture"
    f.wrongProof = true
    try check(await failed { _ = try await reopened.start() } && f.lists == 1 && f.posts == 1,
      "changing the E2B key cannot cross-adopt or create a second sandbox")
    f.accountKey = "offline-fixture"
    f.wrongProof = false
    f.matchCount = 0
    try check(await failed { _ = try await reopened.start() } && f.posts == 1 && f.lists == 2, "an empty list never repeats an uncertain create")
    try check(await failed { try await reopened.delete() } && f.record.e2bCreateAttempt == f.tag, "deleting an unresolved setup retains its receipt")
    f.matchCount = 2
    try check(await failed { _ = try await reopened.start() } && f.posts == 1, "multiple matches refuse adoption")
    f.matchCount = 1
    f.wrongTag = true
    try check(await failed { _ = try await reopened.start() } && f.record.sandboxID == nil, "a different operation cannot be adopted")
    f.wrongTag = false
    f.hasNext = true
    try check(await failed { _ = try await reopened.start() } && f.record.sandboxID == nil, "a paginated result cannot prove one exact match")
    f.hasNext = false
    f.connectStatus = 404
    try check(await failed { _ = try await reopened.start() } && f.record.e2bCreateAttempt == f.tag && f.posts == 1,
      "a listed sandbox that cannot yet connect keeps the receipt and avoids another create")
    f.connectStatus = 201
    f.infoStatus = 503
    try check(await failed { _ = try await reopened.start() } && f.record.sandboxID == f.id && f.record.e2bCreateAttempt == f.tag,
      "a failed post-adoption probe preserves both identity and initialization debt")
    f.infoStatus = 200
    f.failDesktop = true
    let recovered = try f.machine()
    try check(await failed { _ = try await recovered.start() } && f.boots == 1, "relaunch retries desktop setup on the same recovered ID")
    f.failDesktop = false
    let fresh = try await recovered.start()
    try check(fresh && f.boots == 2 && f.posts == 1, "a failed desktop startup cannot use the warm fast path or order another sandbox")
    try await recovered.finishReplacement()
    try check(f.record.sandboxID == f.id && f.record.e2bCreateAttempt == nil, "host acknowledgment after restore clears the receipt")
    let stable = try await recovered.start()
    try check(!stable && f.posts == 1, "a verified computer remains reusable")

    let rotation = Fixture()
    _ = await failed { _ = try await rotation.machine().start() }
    rotation.accountKey = "rotated-same-team"
    let newlyRecovered = try rotation.machine()
    try check(try await newlyRecovered.start() && rotation.record.sandboxID == rotation.id && rotation.allocations == 1,
      "a rotated same-team key recovers the unique sandbox carrying both receipt tags")
    rotation.listedID = "different-sandbox"
    try check(await failed { _ = try await rotation.machine().start() } && rotation.record.sandboxID == rotation.id && rotation.posts == 1,
      "a rotated key cannot substitute another ID for an already known pending sandbox")
    rotation.listedID = nil
    try check(try await rotation.machine().start() && rotation.posts == 1,
      "a rotated key can resume its positively verified known pending sandbox")
    let clearing = Fixture()
    let losing = try clearing.machine()
    _ = await failed { _ = try await losing.start() }
    guard let pending = clearing.record.e2bCreateAttempt else { throw SereinError.invalid("missing fixture receipt") }
    try check(await failed { try await losing.clearVerifiedUncreatedAttempt(pending) }, "a listed sandbox cannot be manually forgotten")
    clearing.matchCount = 0
    clearing.accountKey = "a-different-fixture"
    try check(await failed { try await losing.clearVerifiedUncreatedAttempt(pending) }, "an empty list from a different account cannot clear a creation")
    clearing.accountKey = "offline-fixture"
    try await losing.clearVerifiedUncreatedAttempt(pending)
    try check(clearing.record.e2bCreateAttempt == nil && clearing.posts == 1,
      "operator-confirmed noncreation and a full empty original-key lookup clear the record without a new order")

    for status in [200, 409, 422, 429, 503] {
      let uncertain = Fixture()
      uncertain.createStatus = status
      uncertain.matchCount = 0
      _ = await failed { _ = try await uncertain.machine().start() }
      try check(await failed { _ = try await uncertain.machine().start() } && uncertain.posts == 1 && uncertain.record.e2bCreateAttempt != nil,
        "ambiguous E2B response \(status) keeps one order after a relaunch")
    }

    let source = Fixture()
    source.record.checkpointSourceID = "old-source"
    _ = await failed { _ = try await source.machine().start() }
    let replacement = try source.machine()
    try check(try await replacement.start() && source.record.checkpointSourceID == "old-source" && source.deleted.isEmpty,
      "recovering an uncertain replacement preserves the old checkpoint source")
    try await replacement.finishReplacement()
    try check(source.deleted == ["old-source"] && source.record.checkpointSourceID == nil && source.record.e2bCreateAttempt == nil,
      "only verified replacement acknowledgment retires the old source")

    let rejected = Fixture()
    rejected.createStatus = 400
    try check(await failed { _ = try await rejected.machine().start() } && rejected.record.e2bCreateAttempt == nil && rejected.allocations == 0,
      "a definitive request rejection lets the person correct the template and retry")
    let disk = Fixture()
    disk.loseReply = false
    disk.refuseAdoption = true
    try check(await failed { _ = try await disk.machine().start() } && disk.allocations == 1 && disk.record.e2bCreateAttempt != nil,
      "a failed local write after create keeps the durable lookup receipt")
    disk.refuseAdoption = false
    try check(try await disk.machine().start() && disk.posts == 1, "a failed ID write recovers the original billed machine")

    let legacy = Fixture()
    legacy.record = try JSONDecoder().decode(HostedSettings.self, from: Data(#"{"sandboxID":"test-sandbox-001"}"#.utf8))
    legacy.connectStatus = 503
    try check(await failed { _ = try await legacy.machine().start() } && legacy.posts == 0 && legacy.lists == 0,
      "older saved IDs still reconnect directly")
  }
}
#endif
