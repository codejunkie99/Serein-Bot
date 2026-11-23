#if DEBUG
import Foundation
import SereinCore

/// Shell units 13 to 15: the pure rules behind the assistant tools, the light ask's run and owned
/// links (AssistantTools.swift, and the pause on RelayProfile).
extension AssistantCoreChecks {
  static func tools(_ check: Check) throws {
    try toolsRoster(check)
    try toolsChange(check)
    try toolsPause(check)
    try toolsProposals(check)
    try toolsUndo(check)
    try toolsApps(check)
    try toolsLinks(check)
  }

  private static let toolsTeam = RelayTeam(
    profiles: [
      RelayProfile(id: "main", name: "Serein"),
      RelayProfile(
        id: "inbox", name: "Inbox Zero",
        scope: AssistantScope(destinations: [.web, .mail], instructions: "Who you are: It sorts your mail.\nNever send.")),
      RelayProfile(id: "scout", name: "Scout", scope: AssistantScope(destinations: [.web])),
    ],
    activeID: "main")
  private static let toolsPerson = AssistantScope(destinations: [.web, .answer, .mail, .calendar, .connectedApps])

  private static func toolsChangeResult(_ a: [String: Any], acting: String = "main", team: RelayTeam? = nil)
    -> Result<AssistantChange, AssistantChange.Problem>
  {
    let roster: RelayTeam = team ?? toolsTeam
    return AssistantChange.parse(a, actingID: acting, team: roster, person: toolsPerson, global: .off)
  }

  // MARK: roster

  private static func toolsRoster(_ check: Check) throws {
    let parts = AssistantRoster.split("Who you are: It sorts your mail.\nNever send.")
    try check(parts.job == "It sorts your mail." && parts.rest == "Never send.", "The job line splits from the other instructions")
    try check(AssistantRoster.joined(job: parts.job, rest: parts.rest) == "Who you are: It sorts your mail.\nNever send.", "A job and instructions join back as they were saved")
    try check(AssistantRoster.split("Never send.").job == nil, "Instructions without a job line have no job")
    let entries = AssistantRoster.entries(toolsTeam, person: toolsPerson)
    try check(entries.map(\.name) == ["Serein", "Inbox Zero", "Scout"], "The list keeps roster order")
    try check(entries[1].job == "It sorts your mail." && entries[1].places == [.web, .mail], "An entry has the job and the places it may use")
    try check(entries[0].main && entries[0].active && !entries[1].main, "The main assistant and the one in this chat are marked")
    let listing = AssistantRoster.listing(entries)
    let keys = Set(listing.flatMap { $0.keys })
    try check(keys.isSubset(of: ["name", "job", "can_use", "main", "this_chat", "paused"]), "The list gives name, job and places, never notes or chats")
  }

  // MARK: change

  private static func toolsChange(_ check: Check) throws {
    func change(_ result: Result<AssistantChange, AssistantChange.Problem>) -> AssistantChange? {
      if case .success(let value) = result { return value }
      return nil
    }
    func problem(_ result: Result<AssistantChange, AssistantChange.Problem>) -> AssistantChange.Problem? {
      if case .failure(let value) = result { return value }
      return nil
    }
    let rename = change(toolsChangeResult(["name": "scout", "rename": "Ranger"]))
    try check(rename?.rename == "Ranger" && rename?.widens == false && rename?.admission == .ownChange, "A rename is the assistant's own change")
    try check(problem(toolsChangeResult(["name": "Scout", "rename": "inbox zero"])) == .name(.nameTaken("Inbox Zero")), "A rename to a name in use is refused")
    try check(problem(toolsChangeResult(["name": "Nobody", "paused": true])) == .unknown("Nobody"), "An unknown assistant is refused")
    try check(problem(toolsChangeResult(["paused": true])) == .pauseMain("Serein"), "The main assistant cannot be paused")
    try check(problem(toolsChangeResult(["name": "Scout", "can_use": ["web"]])) == .nothing, "A change to what it is already changes nothing")

    let narrow = change(toolsChangeResult(["name": "Inbox Zero", "can_use": ["mail"]]))
    try check(narrow?.widens == false && narrow?.places == [.mail], "Fewer places is a narrow change that applies")
    let wide = change(toolsChangeResult(["name": "Scout", "can_use": "web, mail, messages"]))
    try check(wide?.widens == true && wide?.added == [.mail] && wide?.admission == .widen, "More places widen and ask on a card")
    try check(wide?.dropped == ["Messages"], "A place the person does not allow is left out and listed")
    try check(wide?.cardDetail.contains("Mail") == true, "The card names what it would get")
    try check(wide?.cardTitle == "Let Scout use Mail?" && wide?.cardDetail.hasSuffix("Changes always ask you first.") == true, "The widen card asks as the spec says")
    try check(problem(toolsChangeResult(["name": "Scout", "can_use": ["messages"]])) == .noPlaces, "No allowed place at all is refused")
    let louder = change(toolsChangeResult(["name": "Scout", "speaks_first": "often"]))
    try check(louder?.speaksMore == true && louder?.widens == true, "Speaking first more often asks on a card")
    let quieter = change(toolsChangeResult(["name": "Scout", "speaks_first": "never"], team: toolsLouder()))
    try check(quieter?.speaksMore == false && quieter?.widens == false, "Speaking first less often applies")

    let job = change(toolsChangeResult(["name": "Inbox Zero", "job": "It clears your inbox each morning."]))
    if let job, let after = job.applied(to: toolsTeam, person: toolsPerson), let inbox = after.profiles.first(where: { $0.id == "inbox" }) {
      try check(AssistantRoster.job(of: inbox) == "It clears your inbox each morning.", "A new job replaces the job line")
      try check(inbox.scope.map { AssistantRoster.split($0.instructions).rest } == "Never send.", "A new job keeps the other instructions")
      try check(inbox.scope?.destinations == [.web, .mail], "A new job keeps the places")
    } else {
      try check(false, "A new job applies to the roster")
    }
    let fresh = change(toolsChangeResult(["job": "It answers questions."]))
    if let fresh, let after = fresh.applied(to: toolsTeam, person: toolsPerson), let main = after.profiles.first(where: { $0.id == "main" }) {
      let effective = AssistantScope.effective(main.scope, person: toolsPerson)
      try check(effective.destinations == toolsPerson.destinations, "A job for an assistant with no scope does not narrow it")
    } else {
      try check(false, "A job applies to an assistant with no scope")
    }
    if let rename {
      let line = ReceiptCopy.changed(name: rename.shownName, what: rename.receiptPhrase, entry: "e").line
      try check(ReceiptCopy.lint(line).isEmpty, "The rename receipt is plain: \(line)")
      let renamed = rename.applied(to: toolsTeam, person: toolsPerson)
      try check(renamed?.profiles.first(where: { $0.id == "scout" })?.name == "Ranger", "A rename applies")
      if let renamed {
        let back = renamed.undoingChange(before: toolsTeam, after: renamed)
        try check(back?.profiles.first(where: { $0.id == "scout" })?.name == "Scout", "Undo of a rename puts the old name back")
      }
    }
    if let wide {
      let line = ReceiptCopy.changed(name: wide.shownName, what: wide.receiptPhrase, entry: "e").line
      try check(ReceiptCopy.lint(line).isEmpty, "The places receipt is plain: \(line)")
    }
  }

  private static func toolsLouder() -> RelayTeam {
    var team = toolsTeam
    team.profiles[2].speaksFirst = .jarvis
    return team
  }

  // MARK: pause

  private static func toolsPause(_ check: Check) throws {
    let result = toolsChangeResult(["name": "Scout", "paused": true])
    guard case .success(let pause) = result, let paused = pause.applied(to: toolsTeam, person: toolsPerson) else {
      try check(false, "Pausing an assistant applies")
      return
    }
    try check(paused.profiles.first(where: { $0.id == "scout" })?.isPaused == true, "A pause marks the assistant paused")
    try check(ReceiptCopy.lint(ReceiptCopy.changed(name: "Scout", what: pause.receiptPhrase, entry: "e").line).isEmpty, "The pause receipt is plain")
    let back = paused.undoingChange(before: toolsTeam, after: paused)
    try check(back?.profiles.first(where: { $0.id == "scout" })?.isPaused == false, "Undo of a pause turns the assistant on")

    // A change made before the pause cannot be undone past it: newer changes go first.
    var narrowed = toolsTeam
    narrowed.profiles[2].scope = AssistantScope(destinations: [.answer])
    var pausedAfter = narrowed
    pausedAfter.profiles[2].paused = true
    try check(pausedAfter.undoing(before: toolsTeam, after: narrowed) == nil, "An older change is not undone past a newer pause")

    let profile = RelayProfile(id: "x", name: "Bob", paused: true)
    let data = (try? JSONEncoder().encode(profile)) ?? Data()
    let decoded = try? JSONDecoder().decode(RelayProfile.self, from: data)
    try check(decoded?.isPaused == true, "A paused assistant reads back paused")
    let old = Data(#"{"id":"y","name":"Ann","createdAt":0}"#.utf8)
    let older = try? JSONDecoder().decode(RelayProfile.self, from: old)
    try check(older != nil && older?.isPaused == false, "A team file from before pauses reads as on")

    let items = [
      DeletePlan.Item(kind: .routine, id: "r1", title: "Clear inbox", on: true),
      DeletePlan.Item(kind: .watch, id: "w1", title: "Price", on: false),
      DeletePlan.Item(kind: .link, id: "l1", title: "GitHub", on: true),
      DeletePlan.Item(kind: .handoff, id: "h1", title: "Task", on: true),
    ]
    try check(HeldWork.from(items) == [HeldWork(kind: .routine, id: "r1"), HeldWork(kind: .link, id: "l1")], "Only work that was on comes back, and never a hand-off")
    try check(AgentHistoryRun.Initiator.ask.isUnattended, "A light ask's run is judged as unattended")
  }

  // MARK: proposals

  private static func toolsProposals(_ check: Check) throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var book = MakeProposals()
    func draft(_ name: String) -> AssistantDraft { AssistantDraft(name: name, job: "It watches fares.", places: [.web]) }
    try check(book.add(.init(by: "scout", draft: draft("Fare watcher"), createdAt: now), byName: "Scout", now: now) == nil, "A first proposal waits")
    try check(book.add(.init(by: "scout", draft: draft("fare watcher"), createdAt: now), byName: "Scout", now: now) == .waiting("fare watcher"), "The same name cannot wait twice")
    try check(book.add(.init(by: "scout", draft: draft("Hotel finder"), createdAt: now), byName: "Scout", now: now) == nil, "A second proposal waits")
    try check(book.add(.init(by: "scout", draft: draft("Third"), createdAt: now), byName: "Scout", now: now) == .tooMany("Scout"), "At most two proposals wait per assistant")
    try check(book.add(.init(by: "planner", draft: draft("Third"), createdAt: now), byName: "Planner", now: now) == nil, "Another assistant has its own two")
    guard let first = book.open.first else {
      try check(false, "The proposals are kept")
      return
    }
    try check(book.decline(first.id, now: now)?.name == "Fare watcher", "Not now takes the proposal away")
    let later = now.addingTimeInterval(86_400)
    let blocked = book.refusal(by: "scout", byName: "Scout", name: "FARE WATCHER", now: later)
    try check(blocked == .blocked("FARE WATCHER", days: 6), "Not now blocks that name for seven days")
    try check(book.refusal(by: "planner", byName: "Planner", name: "Fare watcher", now: later) == nil, "The block is for the assistant that asked")
    let free = book.refusal(by: "scout", byName: "Scout", name: "Fare watcher", now: now.addingTimeInterval(7 * 86_400 + 1))
    try check(free == nil, "After seven days the name may come back")
    try check(MakeProposals.title(draft("Fare watcher")) == "Make Fare watcher?", "The card asks to make it by name")
    let detail = MakeProposals.detail(draft("Fare watcher"), byName: "Scout")
    try check(detail == "Scout wants a helper that watches fares.\nIt starts with no apps.", "The card says who asks and that it starts with no apps")
    let own = MakeProposals.detail(AssistantDraft(name: "Bob 3000", job: nil, places: [.web]), byName: nil)
    try check(own == "It will ask what to do.\nIt starts with no apps.", "The person's own card says the new assistant will ask")
    try check(MakeProposals.declined("Fare watcher") == "You said no to Fare watcher.", "Not now leaves one line")
    try check(asksPlainWords(detail) && asksPlainWords(MakeProposals.more(draft("Fare watcher"))), "The proposal card has no feature words")

    // The first message of a new assistant (SPEC 2.2).
    let named: [String] = ["Inbox Zero", "Calendar", "Trip planner", "Fare watcher", "Writer", "Notes", "Researcher", "News", "Budget", "Fitness", "Recipes", "Shopper"]
    for name in named {
      let job = NameReading.job(for: name)
      let first = FirstWords.message(name: name, job: job, jobFromName: true)
      let ok = first.map { $0.text.hasPrefix("Hi, I am \(name). From my name, I think I ") && $0.text.hasSuffix(". Right?") } ?? false
      try check(ok && first.map { asksPlainWords($0.text) } == true, "\(name) greets in the first person and asks if its job is right")
    }
    let inbox = FirstWords.message(name: "Inbox Zero", job: NameReading.job(for: "Inbox Zero"), jobFromName: true)
    try check(inbox?.text == "Hi, I am Inbox Zero. From my name, I think I sort your mail and ask before I send anything. Right?" && inbox?.chips == ["Yes", "Something else"], "Inbox Zero's first message is as the spec says")
    let bob = FirstWords.message(name: "Bob 3000", job: nil, jobFromName: false)
    try check(bob?.text == "Hi, I am Bob 3000. I cannot tell my job from my name. What should I do for you?" && bob?.chips == HostFacts.firstChips, "A name that tells nothing asks with three chips")
    try check(FirstWords.message(name: "Mail sorter", job: "It sorts mail by sender.", jobFromName: false) == nil, "A job the person gave needs no question")
  }

  private static func asksPlainWords(_ text: String) -> Bool {
    let words = Set(text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
    return ReceiptCopy.bannedWords.intersection(words).isEmpty
  }

  // MARK: undo

  private static func toolsUndo(_ check: Check) throws {
    var stack = UndoStack()
    stack.push(UndoToken(entry: "a", kind: .assistantMade), thread: "chat1")
    stack.push(UndoToken(entry: "b", kind: .assistantChanged), thread: "chat2")
    stack.push(UndoToken(entry: "c", kind: .hookMade), thread: "chat1")
    try check(stack.find(entry: nil, thread: "chat1")?.entry == "c", "Undo without a token finds the newest change of this chat")
    try check(stack.find(entry: "a", thread: "chat2")?.entry == "a", "Undo with a token finds that change")
    stack.remove("c")
    try check(stack.find(entry: nil, thread: "chat1")?.entry == "a", "An undone change leaves the stack")
    try check(HostFacts.hides("DONE.") && !HostFacts.hides("Done. Inbox Zero is ready."), "A reply of exactly DONE stays hidden")
    try check(AskLines.asked(["Planner"]) == "Asked Planner", "One target reads Asked Planner")
    try check(AskLines.asked(["Planner", "Scout"]) == "Asked Planner and Scout", "Two targets are named")
    try check(AskLines.asked(["Planner", "Scout", "Writer"]) == "Asked 3 assistants", "Three targets are counted")
    try check(AskLines.stillAnswering("Scout") == "Scout is still answering. I will add it here.", "A late answer says it comes here")
    try check(AskLines.noAnswer("Scout") == "Scout did not answer.", "An ask over the time cap says so")
    try check(AskLines.messaged("Writer") == "Messaged Writer", "A hand-off's line names the assistant")
    let lines = [AskLines.askedYou("Serein"), AskLines.answering("Serein"), AskLines.personalFold]
    try check(lines.allSatisfy { asksPlainWords($0) }, "The lines of working together have no feature words")
  }

  // MARK: apps

  private static func toolsApps(_ check: Check) throws {
    try check(AppSuggestions.apps(name: "Inbox Zero", job: nil) == ["gmail", "outlook"], "An inbox assistant is offered Gmail and Outlook")
    try check(AppSuggestions.apps(name: "Release", job: "It reads pull requests.") == ["github"], "A release assistant is offered GitHub")
    try check(AppSuggestions.apps(name: "Bob 3000", job: nil).isEmpty, "A name that says nothing is offered no app")
    try check(AppSuggestions.offers(name: "Inbox Zero", job: nil, composioReady: false).map(\.app) == ["gmail"], "Without a key, one connect card")
    try check(AppSuggestions.offers(name: "Inbox Zero", job: nil, composioReady: true).count == 2, "With a key, the matching apps as chips")
  }

  // MARK: links

  private static func toolsLinks(_ check: Check) throws {
    try check(LinkAddress.id(fromPath: "/link/link-abc123?x=1") == "link-abc123", "A link's id comes from its path, without the query")
    try check(LinkAddress.id(fromPath: "/link/../secret") == nil, "A path that is not an id is refused")
    try check(LinkAddress.id(fromPath: "/hook/abc") == nil, "Only /link/ paths are owned links")
    let id = LinkAddress.newID()
    try check(id.hasPrefix("link-") && id.count == 21 && LinkAddress.id(fromPath: "/link/" + id) == id, "A new link id is a valid id")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let made = LinkDraft.parse(
      ["name": "GitHub", "assistant": "Scout", "from": "GitHub", "event": "pull_request", "field": "action", "equals": "opened",
       "instruction": "Tell me about new pull requests."],
      actingID: "main", team: toolsTeam, existing: 0, id: id, now: now)
    if case .success(let spec) = made {
      try check(spec.owner == "scout" && spec.auth == .github, "A GitHub link wakes the assistant named, with GitHub's signature")
      try check(spec.filter == HookSpec.Filter(eventPrefix: "pull_request", field: "action", equals: "opened"), "The link takes only the deliveries named")
      try check(LinkDraft.takes(spec.filter) == "events starting pull_request, action is opened", "The list says what the link takes")
    } else {
      try check(false, "A GitHub link is made")
    }
    if case .success(let spec) = LinkDraft.parse(["name": "Deploys"], actingID: "inbox", team: toolsTeam, existing: 0, id: id, now: now) {
      try check(spec.owner == "inbox" && spec.auth == .bearer && spec.filter == nil, "Without a name the asking assistant owns the link")
    } else {
      try check(false, "A plain link is made")
    }
    let noName = LinkDraft.parse(["name": " "], actingID: "main", team: toolsTeam, existing: 0, id: id, now: now)
    if case .failure(let problem) = noName { try check(problem == .spec(.badName), "A link needs a name") } else { try check(false, "A link needs a name") }
    let full = LinkDraft.parse(["name": "X"], actingID: "main", team: toolsTeam, existing: LinkDraft.maxLinks, id: id, now: now)
    if case .failure(let problem) = full { try check(problem == .tooMany, "Twenty links are the most") } else { try check(false, "Twenty links are the most") }
    let copy = LinkAddress.copyText(id: id, auth: .github, secret: "s3cr3t")
    try check(copy.contains(LinkAddress.url(id)) && copy.contains("s3cr3t"), "Copy link gives the address and the secret")
    try check(LinkConsent.namesRemoval("Remove the GitHub link") && !LinkConsent.namesRemoval("Remove Scout"), "Typed words name removing a link")
    let removed = ReceiptCopy.linkRemoved(title: "GitHub", entry: "unlink:x", now: now)
    try check(ReceiptCopy.lint(removed.line).isEmpty && removed.line == "Done. I removed the link from GitHub.", "The link-removed receipt is plain")
    try check(removed.undo?.isLive(now: now.addingTimeInterval(9)) == true && removed.undo?.isLive(now: now.addingTimeInterval(10)) == false, "A removed link can come back for 10 seconds")
    let titled = LinkDraft.cardTitle(owner: "Release")
    let detailed = LinkDraft.cardDetail(owner: "Release", instruction: "Tell me about new pull requests.")
    try check(titled == "Make a link that wakes Release?" && detailed.hasSuffix("The link works on this Mac."), "The link card says whom it wakes and where it works")
    try check(asksPlainWords(titled) && asksPlainWords(LinkDraft.cardDetail(owner: "Release", instruction: "")), "The link card has no feature words")
    if case .success(let spec) = LinkDraft.parse(["name": "Deploys", "auth": "standard"], actingID: "main", team: toolsTeam, existing: 0, id: id, now: now) {
      try check(spec.auth == .standard, "auth names how deliveries prove the secret")
    } else {
      try check(false, "auth names how deliveries prove the secret")
    }
    let receipt = ReceiptCopy.linkMade(for: "Scout", title: "GitHub")
    try check(receipt.item == nil, "A receipt carries no item until the host sets the link's id")
  }
}
#endif
