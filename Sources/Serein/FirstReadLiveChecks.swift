#if DEBUG
import Foundation
import SereinCore

extension SmokeTest {
  /// `--verify-first-read-live`: Get to know you and a check-in on the person's real AI app
  /// (consumes their usage), in a throwaway library, over synthetic chats of a made-up person. The
  /// assistant must read the chats, keep notes, offer the workspaces those chats use, and later
  /// speak first about a chat that waits on the person. Touches no real chat, Mac app or website.
  @MainActor static func firstReadLive(browser: BrowserModel, agent: AgentModel) async throws -> [String] {
    var results: [String] = []
    func check(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label + "\n" + results.joined(separator: "\n")) }
      results.append("PASS: " + label)
    }
    func waitFor(_ seconds: Double, _ condition: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(seconds)
      while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 250_000_000) }
    }
    let requested = ProcessInfo.processInfo.environment["SEREIN_LIVE_PROVIDER"] ?? ""
    let provider = Provider.allCases.first { $0.rawValue == requested || $0.name == requested } ?? .claude
    try await waitFor(90) { agent.available[provider] != nil && HarnessRegistry.shared.snapshot(provider)?.checkedAt != nil }
    try check(agent.available[provider] != nil, "\(provider.name) is found and checked on this Mac")
    guard let relay = RelayOrchestrator.shared else { throw SereinError.invalid("FAIL: Relay did not start") }
    RelayOrchestrator.enabledOverride = true
    relay.provider = provider
    relay.confirmOverride = { _, _ in false }
    defer {
      relay.confirmOverride = nil
      RelayOrchestrator.enabledOverride = nil
    }

    let chats = try FirstReadFixture.write(into: browser.library.root.appendingPathComponent("fixture-chats"))
    SessionHistoryStore.shared.installPreview(SessionHistory(sessions: chats), cloud: [])

    SessionReading.allowed = false
    do {
      _ = try await relay.tools.call("sessions_list", [:])
      try check(false, "Reading chats is refused once the person turns it off")
    } catch let error as SereinError {
      try check(error.localizedDescription.contains("Read your AI chats"), "Reading chats is refused once the person turns it off")
    }

    // Setup is done: Serein gets to know the person in the background, as it does after setup.
    SessionReading.allowed = true
    defer { SessionReading.allowed = false }
    let started = Date()
    let chatBefore = relay.transcript.count
    GetToKnow.checking = true
    defer { GetToKnow.checking = false }
    let facts = await GetToKnow.run(relay)
    results.append("INFO: getting to know you \(Int(Date().timeIntervalSince(started))) s")
    results.append("FACTS: " + facts.joined(separator: " | "))
    try check(relay.transcript.count == chatBefore, "Getting to know you writes nothing in the chat")
    try check(facts.count >= 3, "It kept at least three facts about the person")
    let known = facts.joined(separator: " ").lowercased()
    try check(["lumen", "storefront", "next"].contains { known.contains($0) }, "A fact names the project the chats are about")
    try check(["typescript", "short", "strict", "tailwind"].contains { known.contains($0) }, "A fact keeps how the person likes to work")
    try check(facts.allSatisfy { fact in relay.notes.contains { $0.text == fact } }, "The facts are Serein's notes now")
    try check(relay.setupOffersHere.isEmpty, "It asked nothing with a card")
    // Run again: the same facts stay, none are added twice.
    let again = await GetToKnow.run(relay)
    try check(Set(relay.notes.map(\.text)).count == relay.notes.count && relay.notes.filter { again.contains($0.text) }.count == again.count,
      "Running again keeps the notes current without doubling them")

    // Speaking first: a check-in at Sometimes notices a chat in another app that waits on the person.
    // It started after the first read, so it is in no chat history yet: only its live transcript.
    let folder = browser.library.root.appendingPathComponent("fixture-chats")
    var waiting = ExternalSession(id: "claude:" + FirstReadFixture.waiting.id, driver: .claude, title: FirstReadFixture.waiting.title,
      cwd: "/Users/maya/code/lumen-shop", state: .needsUser, updatedAt: Date())
    waiting.log = try FirstReadFixture.file(FirstReadFixture.waiting, into: folder).path
    ExternalSessionStore.shared.update([waiting])
    defer { ExternalSessionStore.shared.update([]) }
    relay.proactiveOverride = .light
    defer { relay.proactiveOverride = nil }
    var ten = Calendar.current.dateComponents([.year, .month, .day], from: Date())
    ten.hour = 10
    // The day's first speaking turn is the brief; it reads the chats the same way a check-in does.
    let before = relay.transcript.count
    relay.toolsCalledForChecks = []
    RelayOrchestrator.quietForChecks = false
    relay.speakFirst(now: Calendar.current.date(from: ten)!, idle: 5)
    RelayOrchestrator.quietForChecks = true
    try await waitFor(20) { relay.working }
    try await waitFor(300) { !relay.working }
    let checkIn = relay.transcript.dropFirst(before).last(where: { $0.role == "assistant" })?.text ?? ""
    results.append("CHECK-IN: " + checkIn.replacingOccurrences(of: "\n", with: "\n  "))
    let checkSteps = relay.toolsCalledForChecks
    results.append("INFO: check-in tools: \(checkSteps)")
    try check(checkSteps.contains("sessions_overview") || checkSteps.contains("sessions_list"),
      "The check-in looked at the person's other chats")
    try check(checkIn.lowercased().contains("checkout") || checkIn.lowercased().contains("tax"),
      "The check-in told the person about the chat waiting on them")
    try check(checkIn.contains("1.07") || checkIn.lowercased().contains("half") || checkIn.lowercased().contains("round"),
      "It read that chat and said what it asks")
    return results
  }
}

/// A made-up person's chats with Claude Code, written in Claude Code's own file format.
enum FirstReadFixture {
  struct Chat {
    let id: String
    let project: String
    let title: String
    let daysAgo: Double
    let turns: [(person: String, answer: String, tools: [(String, [String: Any])])]
  }
  static let chats: [Chat] = [
    Chat(id: "11111111-aaaa-4aaa-8aaa-000000000001", project: "lumen-shop", title: "Set up the product page", daysAgo: 1, turns: [
      ("I'm Maya. Set up the product page for lumen-shop, our Next.js storefront for handmade lamps. Strict TypeScript and Tailwind only, please, and keep answers short.",
       "Done: app/products/[slug]/page.tsx renders the lamp, price and gallery. Types are strict; styles are Tailwind only.",
       [("Bash", ["command": "cd web && npm run typecheck"]), ("mcp__claude_ai_Notion__notion-search", ["query": "product page spec"])]),
      ("Deploy a preview.", "Preview is live on Vercel.", [("Bash", ["command": "vercel deploy"])]),
    ]),
    Chat(id: "11111111-aaaa-4aaa-8aaa-000000000002", project: "lumen-shop", title: "Checkout and Stripe", daysAgo: 2, turns: [
      ("Wire checkout with Stripe test keys. The spec is in Notion: https://www.notion.so/lumen/Checkout-spec-42",
       "Checkout posts to /api/checkout and creates a Stripe session. I followed the Notion spec.",
       [("mcp__claude_ai_Notion__notion-fetch", ["id": "Checkout-spec-42"]), ("Bash", ["command": "vercel env pull"])]),
    ]),
    Chat(id: "11111111-aaaa-4aaa-8aaa-000000000003", project: "lumen-shop", title: "Triage Linear bugs", daysAgo: 3, turns: [
      ("Go through LUM-14 and LUM-15 on https://linear.app/lumen/issue/LUM-14 and fix what is quick.",
       "LUM-14 fixed (image ratio). LUM-15 needs your call on shipping zones.", [("Bash", ["command": "npm test"])]),
    ]),
    Chat(id: "11111111-aaaa-4aaa-8aaa-000000000004", project: "studio-notes", title: "Weekly update draft", daysAgo: 5, turns: [
      ("Draft my Friday update for the studio from this week's Notion notes. I send it every Friday.",
       "Here's a draft with three wins and one ask.", [("mcp__claude_ai_Notion__notion-search", ["query": "this week"])]),
    ]),
  ]

  /// A chat that starts after the first read and ends on a question for the person.
  static let waiting = Chat(id: "11111111-aaaa-4aaa-8aaa-000000000005", project: "lumen-shop", title: "Fix the checkout tax rounding",
    daysAgo: 0, turns: [
      ("Totals are off by a cent on some orders. Fix the checkout tax rounding.",
       "Found it: tax is rounded per line, so 3 lamps at $12.35 with 8.875% tax come to $1.07 off from rounding once on the total. Should I round half up on the order total (matches Stripe) or keep per line and adjust the receipt? I need your call before I change it.",
       [("Read", ["file_path": "/Users/maya/code/lumen-shop/web/lib/tax.ts"])]),
    ])

  /// The chats' files in `folder`, keyed as SessionHistory keys them.
  static func write(into folder: URL) throws -> [String: DiscoveredSession] {
    var out: [String: DiscoveredSession] = [:]
    for chat in chats {
      let file = try self.file(chat, into: folder)
      out[file.path] = DiscoveredSession(provider: "claude", id: chat.id, cwd: "/Users/maya/code/" + chat.project, title: chat.title,
        date: Date().addingTimeInterval(-chat.daysAgo * 86_400), file: file.path)
    }
    return out
  }

  /// One chat's file in Claude Code's format.
  static func file(_ chat: Chat, into folder: URL) throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    do {
      let cwd = "/Users/maya/code/" + chat.project
      let date = Date().addingTimeInterval(-chat.daysAgo * 86_400)
      var lines: [String] = []
      var parent: String?
      func line(_ type: String, _ message: [String: Any], at offset: Double) throws {
        let uuid = UUID().uuidString.lowercased()
        var record: [String: Any] = [
          "type": type, "uuid": uuid, "sessionId": chat.id, "cwd": cwd, "isSidechain": false, "userType": "external",
          "timestamp": ISO8601DateFormatter().string(from: date.addingTimeInterval(offset)), "message": message,
        ]
        if let parent { record["parentUuid"] = parent }
        parent = uuid
        let data = try JSONSerialization.data(withJSONObject: record)
        lines.append(String(decoding: data, as: UTF8.self))
      }
      var offset = 0.0
      for turn in chat.turns {
        try line("user", ["role": "user", "content": turn.person], at: offset)
        for (index, tool) in turn.tools.enumerated() {
          let id = "toolu_\(chat.id.suffix(4))\(Int(offset))\(index)"
          try line("assistant", ["role": "assistant", "content": [["type": "tool_use", "id": id, "name": tool.0, "input": tool.1]]],
                   at: offset + 1)
          try line("user", ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]], at: offset + 2)
        }
        try line("assistant", ["role": "assistant", "content": [["type": "text", "text": turn.answer]]], at: offset + 3)
        offset += 60
      }
      let file = folder.appendingPathComponent(chat.id + ".jsonl")
      try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
      return file
    }
  }
}
#endif
