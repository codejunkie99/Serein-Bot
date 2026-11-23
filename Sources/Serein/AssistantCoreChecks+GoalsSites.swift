#if DEBUG
import Foundation
import SereinCore

extension AssistantCoreChecks {
  static func goalsSites(_ check: Check) throws {
    let failed = TranscriptActivity(id: "ci", tool: "test", label: "Hosted CI did not start", failed: true)
    let evidence = CompletionExplanation.Evidence(request: "Install it and test it", answer: "Installed build 1498. Local checks passed. Hosted CI did not start. UI acceptance is still pending.", activities: [failed])
    let good = #"{"notify":true,"outcome":{"text":"Build 1498 is installed; the report says local checks passed.","quote":"Installed build 1498. Local checks passed."},"caveats":[{"text":"Hosted CI did not start, and the UI still needs acceptance.","quote":"Hosted CI did not start. UI acceptance is still pending."}],"failedActivityIDs":["ci"]}"#
    let parsed = CompletionExplanation.parse(good, evidence: evidence)
    try check(parsed != nil, "A grounded explanation accepts the outcome and unresolved caveats")
    let words = CompletionExplanation.text(parsed!, evidence: evidence, app: "Codex", folder: "Serein")
    try check(words.contains("not independently verified") && words.contains("UI still needs acceptance"), "The explanation distinguishes reporting from independent verification")
    try check(CompletionExplanation.parse(good.replacingOccurrences(of: "Installed build 1498. Local checks passed.", with: "All remote tests passed"), evidence: evidence) == nil, "An invented supporting quote is rejected")
    try check(CompletionExplanation.parse(good.replacingOccurrences(of: "[\"ci\"]", with: "[]"), evidence: evidence) == nil, "A response cannot omit recorded failures")
    let quiet = #"{"notify":false,"outcome":null,"caveats":[],"failedActivityIDs":[]}"#
    try check(CompletionExplanation.parse(quiet, evidence: evidence) == nil, "A model cannot silence an observed failure")
    let paused = CompletionExplanation.Evidence(request: "Keep working", answer: "Done.", activities: [], goalState: "paused")
    try check(CompletionExplanation.parse(quiet, evidence: paused) == nil, "A paused goal cannot be silenced as a courtesy")
    let courtesy = CompletionExplanation.Evidence(request: "Open the folder", answer: "Opened the folder.", activities: [])
    try check(CompletionExplanation.parse(quiet, evidence: courtesy)?.notify == false, "The model may suppress a routine confirmation")
    try check(CompletionExplanation.parse("not JSON", evidence: evidence) == nil, "Malformed explanations fail closed")
    let long = CompletionExplanation.Evidence(request: "request", answer: String(repeating: "x", count: 20_000) + "Final caveat", activities: [])
    try check(long.shortened && long.answer.hasSuffix("Final caveat") && long.answer.count < 16_100, "Bounded evidence retains the ending where limitations often appear")
    let prompt = CompletionExplanation.prompt(evidence)
    try check(prompt.contains("UNTRUSTED EVIDENCE") && prompt.contains("Hosted CI did not start"), "The model gets fenced evidence including failed actions")

    var goal = PersonalGoal(kind: .saving, steps: [.init(title: "Choose the destination"), .init(title: "Set aside money")], target: 1000, unit: "dollars")
    try check(goal.valid && goal.next?.title == "Choose the destination", "A savings goal has a concrete next step")
    try check(goal.record(value: 250, note: "First deposit") && goal.fraction == 0.25, "A recorded total drives measured progress")
    _ = goal.record(value: 250, note: "First deposit")
    try check(goal.entries.count == 1 && goal.current == 250, "Retrying the same observation does not double-count progress")
    try check(!goal.record(value: -.infinity, note: nil) && !goal.record(value: -1, note: nil), "Invalid and negative readings cannot damage progress")
    goal.steps[0].done = true
    try check(goal.next?.title == "Set aside money", "Completing a step reveals the next unfinished step")
    let edited = goal.steps(editedTo: "Book flights\n  \nChoose the destination\n")
    try check(edited.map(\.title) == ["Book flights", "Choose the destination"] && edited[1] == goal.steps[0] && !edited[0].done,
      "Editing a goal's steps keeps a finished step finished and drops blank lines")
    let reworded = goal.steps(editedTo: "Pick the destination\r\nSet aside money")
    try check(reworded.count == goal.steps.count && reworded[0].id == goal.steps[0].id && reworded[0].done
      && reworded[0].title == "Pick the destination" && reworded[1] == goal.steps[1],
      "A reworded step keeps its tick, and Windows line breaks still split steps")
    try check(goal.remaining == 750 && PersonalGoal(steps: goal.steps).remaining == nil, "A goal with a target says how far is left")
    try check(ThinkingTrail.clock(7) == "7s" && ThinkingTrail.clock(65) == "1m 05s" && ThinkingTrail.clock(-3) == "0s",
      "A thinking trail counts seconds, then minutes and seconds, and never below zero")
    let restored = try JSONDecoder().decode(PersonalGoal.self, from: JSONEncoder().encode(goal))
    try check(restored == goal && restored.entries.count == 1, "Goal steps and progress survive serialization")
    var card = TodoCard(title: "A trip", column: .doing); card.goal = goal
    try check(TodoBoard.relaunched([card])[0].column == .doing, "A personal goal keeps its status through a restart")
    let encoder = JSONEncoder(); let decoder = JSONDecoder()
    var object = try JSONSerialization.jsonObject(with: encoder.encode(card)) as! [String: Any]
    object.removeValue(forKey: "goal")
    let old = try decoder.decode(TodoCard.self, from: JSONSerialization.data(withJSONObject: object))
    try check(old.goal == nil && old.title == card.title, "Existing goal cards migrate without invented progress")
    try check(SavedSite.safeURL("https://example.org/tracker") != nil && SavedSite.safeURL("javascript:alert(1)") == nil
      && SavedSite.safeURL("https://name:secret@example.org") == nil && SavedSite.safeURL("file:///private/notes") == nil,
      "Saved websites reject script, file and credential-bearing addresses")
    let site = SavedSite(title: "Trip", goalID: card.id)
    try check(try decoder.decode(SavedSite.self, from: encoder.encode(site)) == site, "Saved sites preserve their goal link through a restart")

    let date = Date(timeIntervalSince1970: 1_800_000_000)
    try check(!MessageTimeline.startsGroup(nil, after: date), "Old undated messages get no invented timestamp")
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let midnight = calendar.startOfDay(for: date)
    let noon = midnight.addingTimeInterval(12 * 3600)
    try check(MessageTimeline.startsGroup(noon, after: nil) && !MessageTimeline.startsGroup(noon.addingTimeInterval(3600), after: noon, calendar: calendar)
      && MessageTimeline.startsGroup(noon.addingTimeInterval(3601), after: noon, calendar: calendar), "Messages within an hour share a time group; a longer pause starts another")
    try check(MessageTimeline.startsGroup(midnight, after: midnight.addingTimeInterval(-10), calendar: calendar), "Crossing midnight starts a new group even within a minute")
    let labels = [noon, noon.addingTimeInterval(-86_400), noon.addingTimeInterval(-3 * 86_400), noon.addingTimeInterval(-400 * 86_400)]
      .map { MessageTimeline.label($0, now: noon.addingTimeInterval(60), calendar: calendar) }
    try check(labels[0].hasPrefix("Today ") && labels[1].hasPrefix("Yesterday ")
      && !labels[2].hasPrefix("Today") && !labels[2].hasPrefix("Yesterday") && !labels[2].contains(String(calendar.component(.year, from: noon)))
      && labels[3].contains(String(calendar.component(.year, from: noon.addingTimeInterval(-400 * 86_400)))),
      "Dividers read Today, Yesterday, a weekday date, and add the year only for another year")
    var messageObject = try JSONSerialization.jsonObject(with: encoder.encode(AgentMessage(role: "assistant", text: "Old reply"))) as! [String: Any]
    messageObject.removeValue(forKey: "sentAt")
    let oldMessage = try decoder.decode(AgentMessage.self, from: JSONSerialization.data(withJSONObject: messageObject))
    try check(oldMessage.sentAt == nil && oldMessage.siteID == nil, "Legacy message decoding keeps missing times and sites absent")
    try check(RelayTools.assistantNames.isSuperset(of: RelayTools.personalNames), "Goal and site tools are offered through the existing assistant capability")
  }
}
#endif

#if DEBUG
extension SmokeTest {
  @MainActor static func goalsSitesPersistence(browser: BrowserModel, agent: AgentModel) async throws -> [String] {
    let book = TodoBook()
    book.attach(browser.library, hub: agent.hub)
    var card = TodoCard(id: "goal-persistence-fixture", title: "Learn a song", deadline: Date().addingTimeInterval(3600))
    card.goal = PersonalGoal(kind: .learning, steps: [.init(title: "Learn the first verse")], target: 10, unit: "sessions")
    if !book.cards.contains(where: { $0.id == card.id }) { try book.add(card) }
    var detail = card.goal!; _ = detail.record(value: 3, note: "Practised today", now: Date(timeIntervalSince1970: 1_800_000_000))
    detail.steps[0].done = true
    try book.updateGoal(card.id, details: detail)
    let reopened = TodoBook(); reopened.attach(browser.library, hub: agent.hub)
    guard let saved = reopened.cards.first(where: { $0.id == card.id }), saved.goal == detail,
      saved.deadline != nil, TodoBoard.reminder(for: saved, now: Date()) != nil else {
      throw SereinError.invalid("Goal progress or reminder was not restored.")
    }
    let sites = SiteBook(); sites.attach(browser.library)
    let spec = DashboardSpec(title: "Practice", stat: .init(label: "Sessions", value: "3"), sources: ["assistant:main"])
    let site = try sites.dashboard(spec)
    let restoredSites = SiteBook(); restoredSites.attach(browser.library)
    guard restoredSites.find(site.id)?.dashboard == spec else { throw SereinError.invalid("Saved dashboard was not restored.") }
    _ = try restoredSites.dashboard(spec)
    guard restoredSites.saved.filter({ $0.title == spec.title }).count == 1 else { throw SereinError.invalid("Dashboard update created a duplicate.") }
    let message = AgentMessage(siteID: site.id, role: "assistant", text: "Here is your tracker.")
    try browser.library.save([message], to: "sites-test-message.json")
    guard let messages = browser.library.load([AgentMessage].self, from: "sites-test-message.json"),
      messages.first?.siteID == site.id, messages.first?.sentAt != nil else { throw SereinError.invalid("Message attachment or timestamp was lost.") }
    return ["PASS: Goal steps, absolute progress and reminder restore from disk", "PASS: Dashboard restores and updates without duplication",
      "PASS: Message timestamp and site attachment survive reload"]
  }
  @MainActor static func completionLive(agent: AgentModel) async throws -> [String] {
    for _ in 0..<120 where agent.helperExecutable == nil { try await Task.sleep(for: .milliseconds(500)) }
    CompletionNarrator.allowLiveForChecks = true
    defer { CompletionNarrator.allowLiveForChecks = false }
    let evidence = CompletionExplanation.Evidence(request: "Update the installed Serein app, run checks and update the pull request.",
      answer: "Installed Serein 0.2.10 build 1498 and updated PR #9. The release build passed. 1,974 core checks and 23 delivery checks passed. Hosted CI failed before starting any jobs. The full relay test suite could not run because compiling its existing test file exceeded memory. UI checks confirmed the app launches and displays completion updates. The full relay test suite still needs to be run.",
      activities: [.init(id: "release", tool: "build", label: "Ran swift build -c release -j 2"),
        .init(id: "hosted-ci", tool: "test", label: "Hosted CI failed before starting any jobs", failed: true)])
    guard let text = await CompletionNarrator.explain(evidence, app: "Codex", folder: "Serein", agent: agent), !text.isEmpty else {
      throw SereinError.invalid("The live model did not return a grounded explanation.")
    }
    return ["PROVIDER: " + agent.helperProvider.rawValue, "LIVE EXPLANATION: " + text,
      "PASS: Live model explanation passed provenance and failed-action validation (provider usage incurred)"]
  }
}
#endif
