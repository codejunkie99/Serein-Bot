#if DEBUG
import Foundation
import SereinCore

/// Per-turn frames (TurnFrame.swift): a tool call reads the frame it entered with, as
/// `RelayToolHost.call` binds it, and frames on two threads stay apart. Then on a real Relay over a
/// throwaway library: two chats' turns interleave and each call sees only its own authority, acting
/// assistant and receipts, and a call from a chat with no turn refuses.
extension AssistantCoreChecks {
  static func turnFrame(_ check: Check) throws {
    let person = TurnFrame(thread: "chat-a", serial: 1, admission: .person, unattended: false,
                           personWords: "Make an assistant for my inbox", readOutside: false, profile: "main", acting: "main")
    let routine = TurnFrame(thread: "chat-b", serial: 2, admission: .unattended, unattended: true,
                            personWords: "Make an assistant for my inbox", readOutside: true, profile: "scout", acting: "scout",
                            authority: "watch the ferry price")
    var book = TurnFrames()
    book.begin(person)
    book.begin(routine)
    func called(_ entry: TurnFrame?) -> TurnFrame? {
      TurnFrame.$calling.withValue(entry) { book.frame(for: TurnFrame.calling) }
    }

    try check(called(person) == person && called(routine) == routine,
      "turn frame: a tool call reads the frame of the turn it came from")
    try check(called(nil) == nil, "turn frame: a call from no turn reads no frame")
    try check(called(person)?.typedWords == "Make an assistant for my inbox" && called(routine)?.typedWords.isEmpty == true,
      "turn frame: the person's words count only in the turn they started")
    try check(called(person)?.byPerson == true && called(routine)?.byPerson == false && called(routine)?.unattended == true,
      "turn frame: two running turns each keep their own trust")
    let personStands = RelayOrchestrator.standing(person, level: .proactive)
    let routineStands = RelayOrchestrator.standing(routine, level: .proactive)
    try check(personStands.levelStands && personStands.present && !routineStands.levelStands && !routineStands.present,
      "turn frame: the door's standing is each turn's own")

    book.noteReadOutside("chat-a")
    try check(book["chat-a"]?.readOutside == true && book["chat-b"] == routine && called(person)?.readOutside == true,
      "turn frame: outside text one turn reads marks only its own frame, which its calls read live")
    book.end("chat-b")
    try check(book["chat-a"]?.readOutside == true && book["chat-b"] == nil,
      "turn frame: one turn ending leaves the other's frame")
    try check(called(routine) == routine, "turn frame: a call whose turn ended reads the frame it entered with")

    // The run's end clears it whatever its outcome (`ended`, done, failed or stopped).
    book.end("chat-a")
    try check(book["chat-a"] == nil, "turn frame: the run's end clears its frame")
    // The start failed before a run existed (`turn`'s catch, a scheduled turn that did not start).
    book.begin(person)
    book.end("chat-a", serial: person.serial)
    try check(book["chat-a"] == nil, "turn frame: a start that failed clears its own frame")
    // Stop Everything moved a scheduled turn before it started, and a new turn began on its thread.
    let next = TurnFrame(thread: "chat-a", serial: 3, admission: .person, unattended: false, personWords: "Hi",
                         readOutside: false, profile: "main", acting: "main")
    book.begin(next)
    book.end("chat-a", serial: person.serial)
    try check(book["chat-a"] == next, "turn frame: a stopped start's late end leaves the newer turn's frame")
    try check(called(person) == person, "turn frame: an older turn's late call never reads the newer turn on its thread")
    book.end("chat-a")
    book.end("chat-a")
    try check(book["chat-a"] == nil, "turn frame: ending a turn twice is a no-op")

    try MainActor.assumeIsolated { try turnFrameOnRelay(check) }
  }

  @MainActor private static func turnFrameOnRelay(_ check: Check) throws {
    guard RelayOrchestrator.shared == nil else {
      try check(false, "turn frame: no Relay runs before this check starts one")
      return
    }
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("serein-turn-frame-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }
    let browser = try BrowserModel(root: root)
    try files.createDirectory(at: browser.library.root.appendingPathComponent("relay", isDirectory: true), withIntermediateDirectories: true)
    let agent = AgentModel(browser: browser, discoverProviders: false)
    let relay = RelayOrchestrator.start(agent: agent, browser: browser)
    defer { RelayOrchestrator.releaseForChecks(relay) }
    relay.confirmOverride = { _, _ in true }
    defer { relay.confirmOverride = nil }

    let main = relay.team.activeID
    let a = "turn-frame-a-" + UUID().uuidString
    let b = "turn-frame-b-" + UUID().uuidString
    let words = "check back on the ferry tomorrow"
    let authority = "watch the ferry price"
    let front = TurnFrame(thread: a, serial: 9101, admission: .person, unattended: false, personWords: words,
                          readOutside: false, profile: main, acting: main)
    let routine = TurnFrame(thread: b, serial: 9102, admission: .unattended, unattended: true, personWords: nil,
                            readOutside: true, profile: "scout-check", acting: "scout-check", authority: authority)
    relay.frames.begin(front)
    relay.frames.begin(routine)
    defer {
      relay.frames.end(a)
      relay.frames.end(b)
    }
    func pump(until done: () -> Bool) {
      let end = Date().addingTimeInterval(10)
      while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    // The host's own reads, held across a suspension while the other chat's call runs in between.
    var seen: [String] = []
    for (name, entry) in [("a", front), ("b", routine)] {
      Task { @MainActor in
        await TurnFrame.$calling.withValue(entry) {
          seen.append("\(name)1 \(relay.tools.frame.thread == entry.thread)")
          await Task.yield()
          await Task.yield()
          let host = relay.tools
          seen.append("\(name)2 \(host.frame.thread == entry.thread && host.frame.authority == entry.authority && host.frame.acting == entry.acting && host.acting?.id == entry.acting && host.standing().levelStands == !entry.unattended)")
        }
      }
    }
    pump { seen.count == 4 }
    try check(seen.count == 4 && seen.firstIndex(of: "b1 true").map { $0 < (seen.firstIndex(of: "a2 true") ?? 0) } == true
        && seen.allSatisfy { $0.hasSuffix("true") },
      "turn frame: two chats' calls interleave and each reads only its own frame, authority, acting assistant and standing [\(seen)]")

    // Through `call`: each chat's follow-up carries its own words and assistant, one per turn each,
    // and the person's plain reminder leaves its receipt's Undo in its own chat only.
    var results: [String: Result<[String: Any], Error>] = [:]
    let calls: [(key: String, thread: String, args: [String: Any])] = [
      ("a-follow", a, ["text": "Ferry follow-up A", "in_minutes": 60, "follow_up": true]),
      ("b-follow", b, ["text": "Ferry follow-up B", "in_minutes": 60]),
      ("a-plain", a, ["text": "Stretch", "in_minutes": 90]),
      ("b-again", b, ["text": "Ferry follow-up B again", "in_minutes": 60]),
    ]
    for pair in [[calls[0], calls[2]], [calls[1], calls[3]]] {
      Task { @MainActor in
        for call in pair {
          do { results[call.key] = .success(try await relay.tools.call("reminder_create", call.args, thread: call.thread)) } catch {
            results[call.key] = .failure(error)
          }
          await Task.yield()
        }
      }
    }
    pump { results.count == calls.count }
    func failed(_ key: String) -> String {
      if case .failure(let error)? = results[key] { return error.localizedDescription }
      return ""
    }
    let followA = relay.reminders.first { $0.text == "Ferry follow-up A" }
    let followB = relay.reminders.first { $0.text == "Ferry follow-up B" }
    try check(followA?.source == words && followA?.profileID == main && followB?.source == authority && followB?.profileID == "scout-check",
      "turn frame: each chat's follow-up carries its own turn's words and assistant [\(failed("a-follow")) | \(failed("b-follow"))]")
    try check(failed("b-again").contains("One follow-up per run") && failed("a-plain").isEmpty,
      "turn frame: one follow-up per turn counts each turn on its own [\(failed("b-again")) | \(failed("a-plain"))]")
    try check(relay.desk.undo.find(entry: nil, thread: a) != nil && relay.desk.undo.find(entry: nil, thread: b) == nil,
      "turn frame: a receipt's Undo lands in the chat whose turn made it")

    // A call from a chat with no turn of Serein's running refuses; it never borrows another's frame.
    var none: [String] = []
    for thread in ["turn-frame-none", nil] as [String?] {
      Task { @MainActor in
        do {
          _ = try await relay.tools.call("reminder_list", [:], thread: thread)
          none.append("answered")
        } catch { none.append(error.localizedDescription) }
      }
    }
    pump { none.count == 2 }
    try check(none == [RelayToolHost.noTurn, RelayToolHost.noTurn],
      "turn frame: a tool call with no frame refuses plainly [\(none)]")
  }
}
#endif
