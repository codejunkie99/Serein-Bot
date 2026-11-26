#if DEBUG
import Foundation
import SereinCore

/// What Serein loads only when it is needed: two weeks of history at launch, the chats file
/// written once per burst, rarely used tools behind tools_more and tool_run, and the parts the
/// sibling suites cover (followed chat files, session discovery, launch reads, AI app probes).
extension AssistantCoreChecks {
  static func lazyLoad(_ check: Check) throws {
    try lazyLoadHistory(check)
    try lazyLoadSaves(check)
    try lazyLoadTools(check)
    try lazyLoadTranscripts(check)
    try lazyLoadLaunch(check)
    try lazyLoadProbes(check)
  }

  static func lazyLoadHistory(_ check: Check) throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("serein-lazy-history-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let library = try Library(root: root)
    // Midday, so no clock change moves a visit to another day.
    let noon = Calendar.current.date(byAdding: .hour, value: 12, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    func visit(_ daysAgo: Int) throws -> Visit {
      var visit = Visit(url: "https://example.com/\(daysAgo)", title: "Day \(daysAgo)", text: "Page \(daysAgo)")
      visit.date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: noon) ?? noon
      try library.append(visit, to: "history/\(Library.dayKey(visit.date)).jsonl")
      return visit
    }
    let today = try visit(0), lastInWindow = try visit(Library.launchHistoryDays - 1)
    let firstOutside = try visit(Library.launchHistoryDays), imported = try visit(400)
    let launch = library.visits(from: Library.dayKey(Library.launchHistoryStart(noon)))
    try check(
      launch.map(\.id) == [today.id, lastInWindow.id],
      "Launch reads today and the 13 days before it, newest first, and no older day")
    let all = library.visits()
    try check(
      all.map(\.id) == [today.id, lastInWindow.id, firstOutside.id, imported.id],
      "An older day, imported history included, still reads in full when something needs it")
    try check(
      launch.allSatisfy { $0.textExcerpt.hasPrefix("Page") },
      "The launch copy keeps each page's words: day summaries, the timeline and search read them")
  }

  static func lazyLoadSaves(_ check: Check) throws {
    let coalescer = SaveCoalescer(delay: 0.05)
    let lock = NSLock()
    var written: [Int] = []
    func schedule(_ value: Int) {
      coalescer.schedule("chats") {
        lock.lock()
        written.append(value)
        lock.unlock()
      }
    }
    func seen() -> [Int] {
      lock.lock()
      defer { lock.unlock() }
      return written
    }
    for value in 1...5 { schedule(value) }
    try check(seen().isEmpty && coalescer.isPending("chats"), "A burst of saves waits rather than writing each one")
    Thread.sleep(forTimeInterval: 0.3)
    coalescer.flush("chats")
    try check(seen() == [5], "A burst of five saves writes once, and the last value wins")

    schedule(6)
    coalescer.now("chats") {
      lock.lock()
      written.append(7)
      lock.unlock()
    }
    Thread.sleep(forTimeInterval: 0.3)
    coalescer.flush("chats")
    try check(seen() == [5, 7], "A direct save drops the older save still waiting, so it never lands after it")

    schedule(8)
    coalescer.flushAll()
    try check(seen() == [5, 7, 8] && !coalescer.isPending("chats"), "The flush on quit writes what is still waiting")

    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("serein-lazy-saves-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let library = try Library(root: root)
    library.saveSoon(["first"], to: "sessions/threads.json")
    library.saveSoon(["second"], to: "sessions/threads.json")
    try check(
      library.load([String].self, from: "sessions/threads.json") == ["second"],
      "Reading the chats file first writes the save still waiting, so a read never sees an older file")
    let file = root.appendingPathComponent("sessions/threads.json")
    try check(
      Library.load([String].self, at: file) == ["second"]
        && (try? String(contentsOf: file))?.contains("\n") == true,
      "The chats file keeps its format: the same JSON, pretty-printed, readable without a Library")
  }

  static func lazyLoadTools(_ check: Check) throws {
    func names(_ list: [[String: Any]]) -> [String] { list.compactMap { $0["name"] as? String } }
    let every = ToolSchema.everyTool(["--relay"])
    let shown = Set(names(ToolSchema.offered(["--relay"])))
    let reachable = ToolGroups.reachable(every)
    try check(
      ToolGroups.hidden.isSubset(of: Set(names(every))) && Set(names(reachable)) == ToolGroups.hidden,
      "Every tool kept out of the list is one a relay turn has, and tool_run reaches each of them")
    try check(
      shown.isDisjoint(with: ToolGroups.hidden) && shown.contains(ToolGroups.moreTool) && shown.contains(ToolGroups.runTool)
        && shown.isSuperset(of: ["app_places", "app_open", "app_read", "board_update", "setup_offer", "skill_list", "skill_read"]),
      "A relay turn's list leaves the hidden tools out, holds tools_more and tool_run, and keeps app places, Goals, setup and skills")
    try check(
      Set(names(ToolSchema.offered([]))) == Set(names(ToolSchema.everyTool([]))),
      "A task that is not a relay turn keeps its whole list")

    let listing = try ToolGroups.more([:], reachable: reachable)
    let groups = listing["groups"] as? [[String: Any]] ?? []
    try check(
      groups.compactMap { $0["group"] as? String } == ToolGroups.groups.map(\.id)
        && groups.allSatisfy { !($0["about"] as? String ?? "").isEmpty }
        && Set(groups.flatMap { $0["tools"] as? [String] ?? [] }) == ToolGroups.hidden,
      "tools_more without a group lists every group with one line and its tools")
    let allSchemas = try ToolGroups.groups.flatMap { group in
      (try ToolGroups.more(["group": group.id], reachable: reachable)["tools"] as? [[String: Any]] ?? [])
    }
    try check(
      Set(names(allSchemas)) == ToolGroups.hidden && allSchemas.allSatisfy { $0["inputSchema"] is [String: Any] },
      "tools_more with a group gives that group's full schemas")
    try check((try? ToolGroups.more(["group": "nothing"], reachable: reachable)) == nil, "An unknown group is refused")

    let hiddenNames = ToolGroups.hidden
    let direct: [String: Any] = ["name": "assistant_delete", "arguments": ["name": "Scout"]]
    let viaRun = try ToolGroups.request(
      ["name": "assistant_delete", "arguments": ["name": "Scout"]], reachable: hiddenNames)
    let viaText = try ToolGroups.request(
      ["name": "assistant_delete", "arguments": "{\"name\":\"Scout\"}"], reachable: hiddenNames)
    func same(_ a: [String: Any], _ b: [String: Any]) -> Bool { NSDictionary(dictionary: a).isEqual(to: b) }
    try check(
      same(viaRun, direct) && same(viaText, direct),
      "tool_run sends Serein the inner tool's own call, so it takes the same dispatch, asks and receipts")
    // Serein decides by the name it receives (RelayAssistantTools.deleteAssistant): the call
    // above carries the inner name, so the same rule answers it.
    let refused = Staffing.mayRework(RelayProfile(id: "scout", name: "Scout"), in: .unattended) != nil
    try check(
      refused && (viaRun["name"] as? String) == "assistant_delete" && !ToolGroups.hidden.contains(ToolGroups.runTool),
      "An unattended turn that deletes the person's assistant through tool_run gets the refusal a direct call gets")
    try check(
      (try? ToolGroups.request(["name": "app_read"], reachable: hiddenNames)) == nil
        && (try? ToolGroups.request(["name": "nothing"], reachable: hiddenNames)) == nil
        && (try? ToolGroups.request(["name": ToolGroups.runTool], reachable: hiddenNames)) == nil
        && (try? ToolGroups.request(["name": "update"], reachable: hiddenNames)) == nil,
      "tool_run refuses a listed tool, an unknown one, itself and the settings tools")
    try check(
      AgentStep.label(tool: ToolGroups.runTool, arguments: ["name": "assistant_delete", "arguments": ["name": "Scout"]])
        == AgentStep.label(tool: "assistant_delete", arguments: ["name": "Scout"])
        && AgentStep.label(tool: ToolGroups.moreTool, arguments: [:]) == "Looked at more tools",
      "A step through tool_run reads as the inner tool's own step")
  }
}
#endif
