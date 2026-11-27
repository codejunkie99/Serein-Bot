#if DEBUG
import Foundation
import SereinCore

/// Bots work on their own: on a real Relay over a throwaway library, a bot's turn that read outside
/// text makes many assistants and saves many teams with no card and no refusal, archives an
/// assistant a bot made, and leaves the person's own assistants alone.
extension AssistantCoreChecks {
  static func botsUnbounded(_ check: Check) throws {
    try MainActor.assumeIsolated { try botsUnboundedOnRelay(check) }
  }

  @MainActor private static func botsUnboundedOnRelay(_ check: Check) throws {
    guard RelayOrchestrator.shared == nil else {
      try check(false, "bots unbounded: no Relay runs before this check starts one")
      return
    }
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("serein-bots-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }
    let browser = try BrowserModel(root: root)
    try files.createDirectory(at: browser.library.root.appendingPathComponent("relay", isDirectory: true), withIntermediateDirectories: true)
    let agent = AgentModel(browser: browser, discoverProviders: false)
    let relay = RelayOrchestrator.start(agent: agent, browser: browser)
    defer { RelayOrchestrator.releaseForChecks(relay) }
    var cards: [String] = []
    relay.confirmOverride = { title, _ in
      cards.append(title)
      return false
    }
    defer { relay.confirmOverride = nil }

    let main = relay.team.activeID
    let personChat = "bots-person-" + UUID().uuidString
    let botChat = "bots-bot-" + UUID().uuidString
    // The person's own turn after a web page was read, and a bot's turn (a hand-off) that read one too.
    let person = TurnFrame(thread: personChat, serial: 9301, admission: .person, unattended: false,
                           personWords: "plan the offsite", readOutside: true, profile: main, acting: main)
    let bot = TurnFrame(thread: botChat, serial: 9302, admission: .assistant, unattended: false,
                        personWords: nil, readOutside: true, profile: main, acting: main)
    relay.frames.begin(person)
    relay.frames.begin(bot)
    defer {
      relay.frames.end(personChat)
      relay.frames.end(botChat)
    }

    func run(_ name: String, _ a: [String: Any], in thread: String) -> Result<[String: Any], Error> {
      var out: Result<[String: Any], Error>?
      Task { @MainActor in
        do { out = .success(try await relay.tools.call(name, a, thread: thread)) } catch { out = .failure(error) }
      }
      let end = Date().addingTimeInterval(10)
      while out == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
      return out ?? .failure(SereinError.invalid("timed out"))
    }
    func failure(_ r: Result<[String: Any], Error>) -> String? {
      if case .failure(let error) = r { return error.localizedDescription }
      return nil
    }

    // Past every old cap: 2 makes a room, 16 on the roster, 1 team a room, 8 members a team.
    var refused: [String] = []
    for (chat, tag) in [(personChat, "P"), (botChat, "B")] {
      for i in 0..<12 {
        if let why = failure(run("assistant_make", ["name": "Helper \(tag)\(i)", "job": "Helps with part \(i)"], in: chat)) {
          refused.append("make \(tag)\(i): \(why)")
        }
      }
    }
    let helpers = relay.team.profiles.filter { $0.name.hasPrefix("Helper ") }
    try check(refused.isEmpty && helpers.count == 24 && relay.team.profiles.count > 16,
      "bots unbounded: a person's turn and a bot's turn that read outside text each make 12 assistants, with no refusal [\(refused.first ?? "none")]")

    let members = helpers.prefix(10).map(\.name)
    for (chat, tag) in [(personChat, "P"), (botChat, "B")] {
      for i in 0..<3 {
        if let why = failure(run("team_make", ["name": "Crew \(tag)\(i)", "members": Array(members), "lead": members[0]], in: chat)) {
          refused.append("team \(tag)\(i): \(why)")
        }
      }
    }
    let crews = (relay.team.groups ?? []).filter { $0.name.hasPrefix("Crew ") }
    try check(refused.isEmpty && crews.count == 6 && crews.allSatisfy { $0.memberIDs.count == 10 },
      "bots unbounded: both turns save 3 teams of 10 each, with no refusal [\(refused.first ?? "none")]")

    // A bot archives what a bot made, with Undo; an assistant the person made is left alone.
    guard relay.addProfile("Ana") else { return try check(false, "bots unbounded: the person makes Ana") }
    let archived = run("assistant_delete", ["name": helpers[0].name], in: botChat)
    let kept = failure(run("assistant_delete", ["name": "Ana"], in: botChat)) ?? ""
    try check((try? archived.get())?["archived"] as? String == helpers[0].name && relay.team.profile(named: helpers[0].name) == nil
        && kept.contains("set up by the person") && relay.team.profile(named: "Ana") != nil,
      "bots unbounded: a bot's turn archives an assistant a bot made, never one the person made [\(failure(archived) ?? "") | \(kept)]")
    try check(cards.isEmpty, "bots unbounded: nothing above showed the person a card [\(cards)]")
  }
}
#endif
