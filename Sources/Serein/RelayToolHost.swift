import Foundation
import SereinCore

/// Answers Relay's tools (RelayTools) for its own run: BrowserModel.perform sends them here
/// only for a task that holds `allowRelay`. Delegated runs start through AgentModel.dispatch, so
/// each one is an ordinary Serein thread with its own capability, limits and history.
@MainActor final class RelayToolHost {
  unowned let relay: RelayOrchestrator
  init(relay: RelayOrchestrator) { self.relay = relay }
  private var agent: AgentModel { relay.agent }
  private var browser: BrowserModel { relay.browser }
  /// Personal-tab bindings never persist or come from model arguments.
  private var herePages: [String: SereinPage] = [:]

  /// Tools that create, change or cancel the person's schedules and alerts.
  static let scheduleTools: Set<String> = [
    "reminder_create", "reminder_update", "goal_create", "goal_update", "reminder_cancel", "watch_create", "watch_cancel",
  ]

  func call(_ name: String, _ a: [String: Any]) async throws -> [String: Any] {
    if RelayTools.personalNames.contains(name) { return try await personalTool(name, a) }
    if RelayTools.researchNames.contains(name) { return try await researchTool(name, a) }
    // A turn the person did not start changes no schedule, with no card: a check-in, a report,
    // a hand-off's result, and every unattended turn (a routine, a watch, a link; SPEC 3.6, 3.9).
    // The one exception: a scheduled run acting on the person's words sets one follow-up for
    // itself (RelayFollowUp); a link's run has no such words.
    if Self.scheduleTools.contains(name), relay.working, !relay.startedByPerson {
      guard name == "reminder_create", relay.runsUnattended, let words = relay.turnAuthority else {
        throw SereinError.invalid(Self.lowerTrust)
      }
      return try followUp(a, source: words, profileID: relay.scheduledProfileID)
    }
    // In the person's own turn, a check-back on something Serein did needs no card either: it
    // acts only on what they typed in this turn.
    if name == "reminder_create", a["follow_up"] as? Bool == true, relay.working, relay.startedByPerson,
      !relay.typedWords.isEmpty
    {
      return try followUp(a, source: relay.typedWords, profileID: relay.actingProfile?.id)
    }
    if MacFiles.toolNames.contains(name) {
      let gate = MacFiles.call(
        on: MacFiles.readsWholeMac(), personStarted: !relay.working || relay.startedByPerson,
        // The card is drawn in the chat on screen, so the turn must be that chat's own.
        mayOffer: SereinSetup.mayOffer(personStarted: relay.startedByPerson, unattended: relay.runsUnattended)
          && relay.turnThread == relay.threadID,
        declinedHere: relay.dismissedSetupOffersHere.contains(.files))
      // Asked about their files while reading is off: the card goes up at the moment of use. It
      // only shows; the person's click on it is what turns reading on.
      if gate == .offer { relay.offerSetup(.files) }
      let result = try await RelayFileTools.call(name, a, gate: gate)
      // The person's files are personal, like their mail: a chat that saw them keeps out of
      // Serein's computer, so nothing read here can leave through it. Withheld if not saved.
      guard relay.agent.markPersonalRead(thread: relay.turnThread) else {
        throw SereinError.invalid(BrowserModel.personalMarkWithheld)
      }
      return result
    }
    // Serein's own window (AppPlaceTools.swift): its map, showing a place, reading one, the Board.
    if AppPlaces.toolNames.contains(name) { return try await appTool(name, a) }
    switch name {
    case "setup_offer":
      guard SereinSetup.mayOffer(personStarted: relay.startedByPerson, unattended: relay.runsUnattended) else {
        throw SereinError.invalid("Setup controls can be offered only while answering the person, never by an automatic turn.")
      }
      let topic = try SereinSetup.topic(a)
      relay.offerSetup(topic)
      return ["offered": topic.rawValue, "settings_changed": false,
              "note": "The card is in the chat and no setting has changed. In one short line, say why it helps with what they asked (for files: what you would look for on their Mac once they allow it). Do not describe the card or how it works."]
    // The model cannot start a web run: the assistant works on websites through a Mac
    // (AssistantWeb). A recipe still starts one itself, through start, after the person's yes.
    case "agent_start":
      if a["destination"] as? String == RelayTools.Destination.web.rawValue { throw SereinError.invalid(AssistantWeb.webRefusal) }
      return try await start(a)
    case "agent_status":
      if let run = a["run"] as? String { return try status(of: run, detailed: true) }
      return overview()
    case "sessions_overview", "sessions_list", "session_read": return try await sessionTool(name, a)
    case "agent_send": return try await send(a)
    case "agent_wait": return try await wait(a)
    case "agent_stop": return try stop(a) // Stopping a run Serein started only ends work; it never acts.
    // Shared memory (RelayMemoryShell.swift): `Admission` decides each change; recall reads.
    case "remember": return try await remember(a)
    case "recall": return try await relay.recallFacts(a["query"] as? String, limit: a["limit"] as? Int ?? 10)
    case "chats_search": return try relay.searchChats(a["query"] as? String, limit: a["limit"] as? Int)
    case "forget": return try await forget(a)
    case "rule_save": return try await saveRule(a)
    // A rule is a memory record: removing one is a forget, with the same Undo.
    case "rule_undo": return try await forget(a)
    case "memory_share": return try await shareMemory(a)
    case "instructions_propose": return try await proposeInstructions(a)
    // A plain reminder only shows in the user's own UI; a request for later (action) is gated in createReminder.
    case "reminder_create": return try await createReminder(a)
    case "reminder_list":
      // A To do card's deadline is the board's: its words may come from a page or mail.
      let listed: [RelayReminder] = relay.reminders.filter { !TodoBoard.isReminder($0.id) }
      return ["reminders": listed.sorted { $0.due < $1.due }.map(Self.reminder), "now": Self.stamp(Date())]
    case "reminder_update": return try await updateReminder(a)
    case "goal_create": return try await createGoal(a)
    case "goal_update": return try await updateGoal(a)
    case "reminder_cancel": // Removing one of Serein's own reminders only stops later work; it never acts.
      guard let id = a["id"] as? String, let reminder = relay.reminders.first(where: { $0.id == id }) else {
        throw SereinError.invalid("No reminder has that id. Use reminder_list to find it.")
      }
      if TodoBoard.isReminder(id) { throw Self.boardReminder }
      if let refusal = ownerRefusal(reminder.profileID) { throw SereinError.invalid(refusal) }
      // Recorded like the user's own changes, so Settings can undo it.
      relay.changeReminder(id, actor: "relay", "Cancelled \(RelayOrchestrator.short(reminder.text))") { $0 = nil }
      return ["cancelled": id]
    case "notify": // Notify only changes the user's own UI and can't act on a site.
      // A goal check notifies only for new findings, so a page cannot turn each check into a ping.
      guard !relay.checkingGoal else {
        throw SereinError.invalid("A goal check reports new findings with NEW: lines; Serein notifies for them.")
      }
      guard let text = (a["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
        throw SereinError.invalid("text is required")
      }
      // The body holds the assistant's name only (SPEC I14): the words can come from mail, pages
      // or another app, so they stay in the chat, in the reply.
      let name = relay.notificationName(thread: relay.turnThread)
      TaskNotifications.shared.post(
        threadID: relay.turnThread, title: name, body: RelayOrchestrator.updateBody(name), always: true)
      return ["notified": true, "note": "The notification says only that \(name) has an update. Say what it is about in your reply."]
    case "skill_list":
      return ["skills": PluginHost.shared.skills.map { ["name": $0.name, "description": $0.description] }]
    case "skill_read":
      guard let name = a["name"] as? String, let skill = PluginHost.shared.skills.first(where: { $0.name == name }) else {
        throw SereinError.invalid("No skill by that name. Use skill_list.")
      }
      // A saved skill is written with no other files; anything added to its folder later is not read.
      let saved = PluginHost.shared.savedSkills.contains { $0.folder == skill.folder }
      if let file = a["file"] as? String, !file.isEmpty {
        if saved { throw SereinError.invalid("A saved skill has no other files.") }
        return ["skill": name, "file": file, "text_untrusted": try SkillParser.supportFile(file, in: skill)]
      }
      var out: [String: Any] = ["skill": name, "instructions": skill.instructions, "files": saved ? [] : SkillParser.files(of: skill)]
      if let compatibility = skill.compatibility { out["compatibility"] = compatibility }
      return out
    case "watch_create": return try await createWatch(a)
    case "ask_user":
      let parsed = try RelayAsk.parse(a)
      // Nobody watches the run: no form waits, and the question goes in the reply's NEEDS INPUT.
      if let unattended = RelayAsk.unattended(relay.runsUnattended) { return unattended }
      relay.note("Asked: \(String(parsed.title.prefix(80)))", .auto)
      if let answers = await relay.ask(parsed.title, parsed.questions) {
        return RelayAsk.result(answers)
      }
      return ["timeout": true]
    case "watch_list":
      return [
        "watches": relay.watches.map(Self.watch), "now": Self.stamp(Date()),
        "max": RelayWatch.maxWatches,
      ]
    case "watch_cancel": // Removing one of Serein's own watches only stops later checks; it never acts.
      guard let id = a["id"] as? String, let watch = relay.watches.first(where: { $0.id == id }) else {
        throw SereinError.invalid("No watch has that id. Use watch_list to find it.")
      }
      if let refusal = ownerRefusal(watch.profileID) { throw SereinError.invalid(refusal) }
      relay.changeWatch(id, actor: "relay", "Cancelled \(RelayOrchestrator.short(watch.name))") { $0 = nil }
      return ["cancelled": id]
    case "current_page":
      if let refusal = relay.placeRefusal(.page) { throw SereinError.invalid(refusal) }
      return try await currentPage(a)
    // Team changes and hand-offs always ask, and only in a turn the person started (RelayTeams.swift).
    case "team_propose": return try await proposeTeam(a)
    case "assistant_handoff": return try await handOff(a)
    // One assistant at a time, judged by the admission rule; each change lands as a receipt
    // with Undo (RelayAssistantTools.swift).
    case "assistant_list": return listAssistants()
    case "assistant_make": return try await makeAssistant(a)
    case "assistant_change": return try await changeAssistant(a)
    case "assistant_delete": return try await deleteAssistant(a)
    case "undo": return try await undoChange(a)
    // A read-only question to other assistants, each in a hidden chat (RelayAsks.swift).
    case "assistant_ask": return try await askAssistants(a)
    // Links another app calls to wake one assistant; the secret never reaches the model (RelayLinks.swift).
    case "hook_make": return try await makeLink(a)
    case "hook_list": return listLinks()
    case "hook_remove": return try removeLink(a)
    // The plan card of live work; it changes nothing (RelayAssistantTools.swift).
    case "plan": return try updatePlan(a)
    // The connect pill for an app the request needs; only the person connects (RelayAssistantTools.swift).
    case "connect_app": return try connectApp(a)
    // A key or card typed into its own card, used only by placeholder for its own hosts (RelaySecrets.swift).
    case "secret_ask": return try secretAsk(a)
    case "service_request": return try await serviceRequest(a)
    // A dashboard card on this reply, in the person's own turn (RelayAssistantTools.swift).
    case "dashboard_make": return try makeDashboard(a)
    // A read-only view on this reply, drawn from the model's blocks; it saves nothing (RelayAssistantTools.swift).
    case "ui_show": return try showView(a)
    // A post for X drawn as it will look; Serein never posts it (RelayAssistantTools.swift).
    case "post_draft": return try draftPost(a)
    // A card for To do: always asks (Add / Decline), and adding starts nothing (TodoBook.swift).
    case "todo_propose": return try await proposeTodo(a)
    case "recipe_run": return try await recipeRun(a)
    case "recipe_update": return try await recipeUpdate(a)
    case "harness_capabilities": return try await capabilities(a)
    case "look_get": return lookInfo()
    case "look_set": return try setLook(a) // look_set only changes the user's own UI and can't act on a site.
    case "look_undo": // look_undo only changes the user's own UI and can't act on a site.
      guard relay.undoLook() else { throw SereinError.invalid("There is no earlier look to go back to.") }
      relay.note("Went back to its look “\(relay.look.name)”", .auto)
      return ["wearing": relay.look.name, "states": relay.look.summary]
    case "look_show":
      guard let state = a["state"] as? String, state == "tour" || RelayLook.State(rawValue: state) != nil else {
        throw SereinError.invalid("state is one of " + RelayLook.State.allCases.map(\.rawValue).joined(separator: ", ") + ", or tour")
      }
      let seconds = Double(min(max((a["seconds"] as? Int) ?? (state == "tour" ? 14 : 5), 2), 30))
      let visible = relay.previewLook(state, seconds)
      var out: [String: Any] = ["showing": state, "seconds": seconds, "on_screen": visible]
      if !visible { out["note"] = "Serein is not on screen, so the user did not see it." }
      return out
    default: throw SereinError.invalid("Unknown Serein tool")
    }
  }

  /// What each paired harness has installed, in the user's setup and optionally one project. Reads
  /// only names and short descriptions off disk, on a background task, through HarnessCatalog.
  private func capabilities(_ a: [String: Any]) async throws -> [String: Any] {
    let ready = Provider.allCases.filter { $0.thinksForSerein && agent.available[$0] != nil }
    let providers: [Provider]
    if let name = (a["harness"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
      providers = [try harness(name)]
    } else {
      providers = ready
    }
    var project: Project?
    if let wanted = (a["project"] as? String)?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty {
      if let refusal = relay.placeRefusal(.project) { throw SereinError.invalid(refusal) }
      guard let id = RelayTools.project(wanted, among: browser.shareableProjects.map { ($0.id, $0.name) }),
        let found = browser.shareableProjects.first(where: { $0.id == id })
      else { throw SereinError.invalid("Name a project from agent_status: " + projectNames()) }
      project = found
    }
    let targets = providers.compactMap(\.driver)
    let path = project?.path
    let reports = await Task.detached {
      targets.map { HarnessCatalog.read($0, project: path) }
    }.value
    let harnesses = reports.map { report -> [String: Any] in
      var entry: [String: Any] = [
        "harness": Provider(report.driver).name, "id": report.driver.rawValue,
        "skills": report.skills.map(Self.cap), "commands": report.commands.map(Self.cap),
        "mcp_servers": report.mcpServers.map(Self.cap),
      ]
      if !report.verified {
        entry["verified"] = false
        entry["note"] = "Read from this agent's documentation; not yet checked against a running copy."
      }
      return entry
    }
    var out: [String: Any] = ["harnesses": harnesses]
    if let project { out["project"] = project.name }
    return out
  }
  static func cap(_ c: HarnessCapability) -> [String: Any] {
    var out: [String: Any] = ["name": c.name, "scope": c.scope.rawValue, "enabled": c.enabled]
    if let detail = c.detail, !detail.isEmpty { out[c.enabled ? "description" : "off_because"] = detail }
    return out
  }

  // MARK: agent runs

  private func start(_ a: [String: Any]) async throws -> [String: Any] {
    guard let task = (a["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty else {
      throw SereinError.invalid("task is required")
    }
    // A tab never comes from a tool call: only the user's own message can carry one.
    if !CurrentPageContext.tabArguments.isDisjoint(with: a.keys) { throw Self.namedTab }
    guard let raw = a["destination"] as? String, let destination = RelayTools.Destination(rawValue: raw) else {
      throw SereinError.invalid("destination is project, web, mac, answer or here")
    }
    // The active assistant's own places (AssistantScope): refused before any card.
    if let refusal = relay.placeRefusal(destination.place) { throw SereinError.invalid(refusal) }
    if destination == .here { return try await startHere(task, a) }
    let provider = try harness(a["agent"] as? String)
    var projectID: String?
    if destination == .project {
      guard let wanted = a["project"] as? String,
        let id = RelayTools.project(wanted, among: browser.shareableProjects.map { ($0.id, $0.name) })
      else {
        throw SereinError.invalid("Name a project from agent_status: " + projectNames())
      }
      projectID = id
    }
    // Autonomy by default (the owner's choice, 2026-11-16): a project task may change files unless
    // the call says edits=false.
    let edits = destination == .project && (a["edits"] as? Bool ?? true)
    let mode: TaskMode = [.project: .project, .web: .research, .mac: .anywhere, .answer: .answer][destination]!
    let place = destination == .project
      ? browser.shareableProjects.first { $0.id == projectID }?.name ?? "a project"
      : ["web": "websites", "mac": "Mac apps", "answer": "an answer"][raw] ?? raw
    // A project whose name cannot be found reads “Start a task in a project?”, never a
    // placeholder in quotes.
    let name = destination == .project ? browser.shareableProjects.first { $0.id == projectID }?.name : place
    let card = ApprovalCopy.startTask(provider: provider.name, destination: raw, place: name, edits: edits, task: task)
    // The model and effort Serein named, when the AI app offers them; otherwise the app's own
    // default model at medium effort. Never the chat that happens to be open: what a task runs
    // with must not change with the tab in view.
    let choice = Self.modelAndEffort(withAssistantModel(a, provider: provider), models: HarnessRegistry.shared.models(provider))
    // The run that is judged is the run that is dispatched. An answer run gets no page actions.
    var target = AgentModel.DispatchTarget(
      mode: mode, provider: provider, model: choice.model, effort: choice.effort, projectID: projectID,
      actions: destination != .answer, edits: edits, mac: destination == .mac,
      permission: Self.startPermission(edits: edits, fullAccessConfirmed: FullAccessConsent.confirmed(projectID)),
      initiator: .delegated)
    target.byPerson = relay.startedByPerson
    try await gateRun(Self.runEffect(target), title: card.title, detail: card.detail, button: "Start", task: true)
    let model = choice.model.isEmpty ? "default" : choice.model
    let id = try await agent.dispatch(task, into: nil, as: target)
    relay.adopt(id, edits: edits)
    try carryPersonalMark(to: id)
    relay.note("Asked \(provider.name) to work on \(place): \(String(task.prefix(80)))", .auto)
    return ["run": id, "agent": provider.name, "destination": raw, "place": place, "state": "working",
            "model": model, "effort": choice.effort]
  }

  static let namedTab = SereinError.invalid(
    "A tab named in a tool call is refused. Serein works in the user's tab only when their own message carried it (destination here); otherwise it works in its own tabs (destination web).")

  /// “Do it here”: a task in the tab the user's own message carried (the host binding), never one
  /// a tool call names. It always asks first, once per chat per site, whatever Serein asks before.
  private func startHere(_ task: String, _ a: [String: Any], into threadID: String? = nil) async throws -> [String: Any] {
    guard let page = relay.turnPage, !page.isPrivate else {
      throw SereinError.invalid(CurrentPageContext.noChipRefusal + " Or work in your own tabs (destination web).")
    }
    guard let tab = browser.tabs.first(where: { $0.id == page.tabID }), !tab.privateMode, !tab.hiddenFromAgents,
      let site = CurrentPageContext.host(page.url), CurrentPageContext.host(tab.address) == site
    else { throw SereinError.invalid("That tab is closed now, or its site changed. Ask again from the page you want to use.") }
    if let threadID {
      guard let original = herePages[threadID], original.tabID == page.tabID, original.host == site else {
        throw SereinError.invalid("This task can continue only from its original tab and site. Send the request from that tab, or start a new task.")
      }
    }
    let chat = relay.threadID
    let approvedPage = SereinPageChip.page(tab)
    let isCurrent = { [weak relay] in relay?.threadID == chat && relay?.turnPage == page }
    let provider = try harness(a["agent"] as? String)
    let key = CurrentPageContext.workHereKey(chat: chat, url: approvedPage.url)
    if let key, relay.workHereAllowed.contains(key) {
      // Already allowed in this chat for this site. New instructions for a task already here
      // were asked for by agent_send.
      if threadID == nil {
        let card = ApprovalCopy.startTask(provider: provider.name, destination: "here", place: site, edits: false, task: task)
        // A task in the user's own tab clicks and types there: always asks.
        try await gateRun(.change, title: card.title, detail: card.detail, button: "Start", more: task, moreName: "the task", site: .ask)
      }
    } else {
      // Working in the user's own tab grants access to it: an access effect, which always asks.
      let card = CurrentPageContext.workHereCard(title: AgentPrivacy.redact(tab.title), site: site)
      try await gateRun(
        .access, title: card.title, detail: card.detail, button: card.button, more: task, moreName: "the task",
        declined: "The user said no to working in their tab. Offer to do it in your own tabs instead.", site: .ask)
    }
    // An answer covers the displayed site, not a different site reached while it waited.
    guard isCurrent(), browser.tabs.contains(where: { $0.id == tab.id }), !tab.privateMode,
      !tab.hiddenFromAgents, CurrentPageContext.host(tab.address) == site else {
      throw SereinError.invalid("The approved tab or site changed. Ask again from the page you want to use.")
    }
    if let key { relay.workHereAllowed.insert(key) }
    let choice = Self.modelAndEffort(withAssistantModel(a, provider: provider), models: HarnessRegistry.shared.models(provider))
    var target = AgentModel.DispatchTarget(
      mode: .page, provider: provider, model: choice.model, effort: choice.effort, projectID: nil,
      actions: true, edits: false, mac: false, initiator: .delegated)
    target.byPerson = relay.startedByPerson
    // The host binding is the only way a task gets a tab.
    target.page = approvedPage
    target.pageIsCurrent = isCurrent
    let id = try await agent.dispatch(task, into: threadID, as: target)
    if threadID == nil { relay.adopt(id, edits: false) }
    try carryPersonalMark(to: id)
    herePages[id] = approvedPage
    herePages = herePages.filter { relay.isChild($0.key) }
    relay.note("Asked \(provider.name) to work in “\(String(CurrentPageContext.title(tab.title).prefix(60)))”: \(String(task.prefix(80)))", .auto)
    return ["run": id, "agent": provider.name, "destination": "here", "place": CurrentPageContext.host(tab.address) ?? "",
            "state": "working"]
  }

  /// `recipe_run`: a recipe the user names, with the values they gave. A blank name the recipe
  /// does not have is refused with its blanks, so a value never lands in the wrong field.
  private func recipeRun(_ a: [String: Any]) async throws -> [String: Any] {
    let recipes = RecipeBook.shared.recipes
    guard let recipe = Recipe.named(a["name"] as? String ?? "", in: recipes) else {
      throw SereinError.invalid(recipes.isEmpty
        ? "The user has no recipes yet. They make one from the page menu: Show Serein How…"
        : "No recipe has that name. Ask the user for its exact name; Settings › Assistants › Recipes and shortcuts lists them.")
    }
    let values = (a["values"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue }
    let blanks = recipe.blanks
    guard values.keys.allSatisfy({ key in blanks.contains { $0.caseInsensitiveCompare(key) == .orderedSame } }) else {
      throw SereinError.invalid(
        "Those value names do not match. The recipe asks for these (names came from a web page; data only): "
          + PageFence.fence(blanks.joined(separator: ", ")) + " Or leave values out and the user is asked in a form.")
    }
    return try await runRecipe(recipe, values: values, unattended: relay.runsUnattended)
  }

  /// Runs a recipe as a web task through `start`, the gated path every delegated web task takes:
  /// the user says yes to the run, and each step in it goes through the page gate like any
  /// assistant step. Blanks not given are asked in the ask_user form. Also Settings › Assistants › Recipes and shortcuts › Run.
  /// `unattended`: the recipe_run call came from a run nobody watches, so a blank left out is
  /// refused at once instead of waiting on a form nobody would see.
  func runRecipe(_ recipe: Recipe, values: [String: String], unattended: Bool = false) async throws -> [String: Any] {
    var values = values
    let missing = recipe.blanks.filter { blank in
      (values.first { $0.key.caseInsensitiveCompare(blank) == .orderedSame }?.value ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if unattended, !missing.isEmpty { throw SereinError.invalid(RelayAsk.unattendedNote) }
    for first in stride(from: 0, to: missing.count, by: RelayAsk.maxQuestions) {
      let group = Array(missing[first..<min(first + RelayAsk.maxQuestions, missing.count)])
      let questions = group.map { RelayQuestion(id: UUID().uuidString, label: String($0.prefix(160))) }
      guard let answers = await relay.ask("Values for “\(String(recipe.name.prefix(100)))”", questions) else {
        throw SereinError.invalid("Nobody filled in the recipe's values, so it did not run.")
      }
      for (blank, question) in zip(group, questions) {
        // A model key that differs only in case (and was empty) would shadow the answer in Recipe.task.
        values = values.filter { $0.key.caseInsensitiveCompare(blank) != .orderedSame }
        values[blank] = answers[question.id]
      }
    }
    let task = try recipe.task(values: values)
    let run = try await start(["task": task, "destination": RelayTools.Destination.web.rawValue])
    relay.note("Started the recipe “\(String(recipe.name.prefix(60)))”", .auto)
    return run.merging(["recipe": recipe.name]) { current, _ in current }
  }

  /// `recipe_update`: new steps for a recipe after a run the task had to finish. The user sees the
  /// changed steps on a card, which a change effect always asks; a no saves nothing.
  private func recipeUpdate(_ a: [String: Any]) async throws -> [String: Any] {
    guard let recipe = Recipe.named(a["name"] as? String ?? "", in: RecipeBook.shared.recipes) else {
      throw SereinError.invalid("No recipe has that name.")
    }
    let steps = try Recipe.steps(fromTool: a["steps"])
    let changes = Recipe.changes(from: recipe.steps, to: steps)
    guard !changes.isEmpty else { return ["recipe": recipe.name, "changed": 0] }
    let shown = changes.prefix(6).joined(separator: "\n") + (changes.count > 6 ? "\n…and \(changes.count - 6) more" : "")
    try await gateRun(
      .change, title: "Update the recipe “\(String(recipe.name.prefix(80)))”?", detail: shown, button: "Update",
      more: changes.joined(separator: "\n"), moreName: "every changed step",
      declined: "The user kept the recipe as it was.")
    // What the card showed is what is saved: a recipe changed or deleted while it waited is not overwritten.
    guard var current = RecipeBook.shared.recipes.first(where: { $0.id == recipe.id }), current.steps == recipe.steps else {
      throw SereinError.invalid("The recipe changed while the user decided. Propose the update again.")
    }
    current.steps = steps
    try RecipeBook.shared.save(current)
    return ["recipe": current.name, "changed": changes.count]
  }

  /// `current_page`: the tab the user's message carried, read now. Its address (no query) and its
  /// text, capped and framed as untrusted. Refused for private tabs, files and about: pages, and
  /// pages with password or payment fields. Each read shows in Activity.
  private func currentPage(_ a: [String: Any]) async throws -> [String: Any] {
    if !CurrentPageContext.tabArguments.isDisjoint(with: a.keys) { throw Self.namedTab }
    guard let page = relay.turnPage else { throw SereinError.invalid(CurrentPageContext.noChipRefusal) }
    if let refusal = CurrentPageContext.refusal(url: page.url, isPrivate: page.isPrivate) {
      throw SereinError.invalid(refusal)
    }
    guard let tab = browser.tabs.first(where: { $0.id == page.tabID }) else {
      throw SereinError.invalid("That tab is closed now, so there is no page to read.")
    }
    if let refusal = CurrentPageContext.refusal(url: tab.address, isPrivate: tab.privateMode) {
      throw SereinError.invalid(refusal)
    }
    guard !tab.hiddenFromAgents else {
      throw SereinError.invalid(
        tab.isSourceView ? "Page text not included: source views are never shared." : SiteRules.refusal(tab.address))
    }
    guard CurrentPageContext.host(tab.address) == page.host else {
      throw SereinError.invalid("The tab changed sites. Ask again from the page you want to read.")
    }
    let captured = await ComposerContext.capture(tab)
    guard relay.turnPage == page, browser.tabs.contains(where: { $0.id == tab.id }), !tab.hiddenFromAgents else {
      throw SereinError.invalid("That page is no longer shared with this message.")
    }
    if let refusal = CurrentPageContext.refusal(url: captured.url, isPrivate: tab.privateMode)
      ?? CurrentPageContext.refusal(url: tab.address, isPrivate: tab.privateMode) {
      throw SereinError.invalid(refusal)
    }
    guard CurrentPageContext.host(captured.url) == page.host, CurrentPageContext.host(tab.address) == page.host else {
      throw SereinError.invalid("The tab changed sites. Ask again from the page you want to read.")
    }
    let title = CurrentPageContext.title(AgentPrivacy.redact(tab.title))
    if captured.sensitive {
      relay.note("Did not read “\(title)”: it has password or payment fields", .refused)
      throw SereinError.invalid(CurrentPageContext.sensitiveRefusal)
    }
    relay.note("Read “\(title)”", .auto)
    var out: [String: Any] = ["address": CurrentPageContext.address(tab.address) ?? "", "title": title]
    if captured.unavailable {
      out["note"] = "The page is not loaded, so only its address and title are known."
    } else {
      out["text_untrusted"] = PageFence.fence(UntrustedText.escape(UntrustedText.capped(CurrentPageContext.text(AgentPrivacy.redact(captured.text)))))
      // A table Relay collects from this page is checked against what it read here.
      CollectedPages.note(out, owner: CollectedPages.relayOwner, real: tab.address)
    }
    return out
  }

  /// A To do card's deadline reminder changes only with its card, on the board.
  static let boardReminder = SereinError.invalid("That reminder belongs to a To do card; the user changes it on the board.")
  /// The model and effort for a new task: what agent_start named, kept only when the AI app
  /// lists that model and the model offers that effort (an invented name would stop the task
  /// from starting); else the app's own default model, at medium effort when that is offered.
  static func modelAndEffort(_ a: [String: Any], models: [HarnessModel]) -> (model: String, effort: String) {
    let named = (a["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let wanted = (a["effort"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    let chosen = named.isEmpty ? nil : models.first { $0.id == named || $0.id == ClaudeModelID.split(named).base }
    let model = chosen == nil ? "" : named
    let levels = (chosen ?? models.first(where: \.isDefault) ?? models.first)?.effortLevels ?? []
    let fallback = levels.isEmpty || levels.contains("medium") ? "medium" : levels.first ?? "medium"
    let effort = !wanted.isEmpty && levels.contains(wanted) ? wanted : fallback
    return (model, effort)
  }

  /// The level new instructions to a delegated thread run at: the one saved on that thread,
  /// which only the person sets (the thread's access menu); the assistant has no way to name one.
  /// A read-only run stays Supervised, and Full access needs the project's confirmation still on
  /// this Mac (`dispatch` checks it again). A thread with no saved level works Supervised.
  nonisolated static func sendPermission(saved: String?, edits: Bool, fullAccessConfirmed: Bool) -> RunPermissionMode {
    guard edits, let level = saved.flatMap(RunPermissionMode.init(rawValue:)) else { return .supervised }
    return level == .fullAccess && !fullAccessConfirmed ? .supervised : level
  }

  /// The level a new delegated project task starts at: it works on its own, Full access once the
  /// person confirmed it for the project, else Auto (asks only before risky commands). A read-only
  /// task stays Supervised. Hard stops and the start card are untouched.
  nonisolated static func startPermission(edits: Bool, fullAccessConfirmed: Bool) -> RunPermissionMode {
    edits ? (fullAccessConfirmed ? .fullAccess : .auto) : .supervised
  }

  /// agent_start's arguments, with the acting assistant's own model when the call named none and
  /// the task runs on the harness it thinks with (`RelayTeam.route(of:)`: its own route, else the
  /// starting one, else Serein's); `modelAndEffort` keeps it only when the AI app lists it.
  private func withAssistantModel(_ a: [String: Any], provider: Provider) -> [String: Any] {
    guard ((a["model"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let route = relay.actingProfile.flatMap(relay.team.route(of:)), route.provider == provider.rawValue
    else { return a }
    var named = a
    named["model"] = route.model
    return named
  }

  private func send(_ a: [String: Any]) async throws -> [String: Any] {
    guard let id = a["run"] as? String, let text = a["text"] as? String,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw SereinError.invalid("run and text are required") }
    guard let child = relay.child(id), let thread = agent.conversations.first(where: { $0.id == id }) else {
      throw SereinError.invalid("Serein did not start that run. Use agent_status to list yours.")
    }
    // More work in a place the active assistant may no longer use is refused like a new start.
    if let place = AssistantPlace.of(runKey: thread.mode.runKey), let refusal = relay.placeRefusal(place) {
      throw SereinError.invalid(refusal)
    }
    // A task in the user's tab continues only from its original tab and site: a send from any
    // other tab is refused before anything is asked. startHere checks again after the card.
    if thread.mode == .page {
      guard let page = relay.turnPage else { throw SereinError.invalid(CurrentPageContext.noChipRefusal) }
      if herePages[id].map({ $0.tabID != page.tabID || $0.host != CurrentPageContext.host(page.url) }) ?? true {
        throw SereinError.invalid("This task can continue only from its original tab and site. Send the request from that tab, or start a new task.")
      }
    }
    // New instructions are a new approval: the one the run started with covered its first task.
    let card = ApprovalCopy.sendTask(provider: thread.provider.name, run: id, title: thread.title, text: text)
    let target = AgentModel.DispatchTarget(
      mode: thread.mode, provider: thread.provider, model: thread.model ?? "", effort: thread.effort ?? "medium",
      projectID: thread.projectID, actions: thread.mode != .answer, edits: child.edits, mac: thread.mode == .anywhere,
      permission: Self.sendPermission(
        saved: thread.permission, edits: child.edits, fullAccessConfirmed: FullAccessConsent.confirmed(thread.projectID)))
    try await gateRun(
      Self.runEffect(target), title: card.title, detail: card.detail, button: "Send", more: text, moreName: "the message",
      task: true, site: thread.mode == .page ? .ask : .normal)
    /// New work is the acting assistant's: its steps follow that assistant's scope.
    relay.childOwners[id] = relay.actingProfile?.id ?? ""
    // And its standing yeses follow the turn that sent it (RoutineGrants.standsIn).
    relay.noteSteered(id)
    if thread.mode == .page {
      return try await startHere(text, ["agent": thread.provider.rawValue, "model": thread.model ?? "",
                                       "effort": thread.effort ?? "medium"], into: id)
    }
    // The run the person approved earlier keeps going; only this new work is refused.
    try carryPersonalMark(to: id, stopRun: false)
    _ = try await agent.dispatch(text, into: id, as: target)
    return ["run": id, "state": "working"]
  }

  /// Serein's chat read personal data: the task it starts or sends to holds what Serein wrote,
  /// so it is marked too (no computer). A mark that cannot be saved refuses the call, and with
  /// `stopRun` also stops the task it just started.
  private func carryPersonalMark(to id: String, stopRun: Bool = true) throws {
    // The chat whose turn starts or steers it: another assistant's while its routine runs there.
    guard agent.readsPersonal(thread: relay.turnThread), !agent.markPersonalRead(thread: id) else { return }
    if stopRun, let run = agent.hub.run(for: id) { agent.hub.stop(run) }
    throw SereinError.invalid(BrowserModel.personalMarkFailed)
  }

  private func wait(_ a: [String: Any]) async throws -> [String: Any] {
    let seconds = min(max((a["seconds"] as? Int) ?? RelayTools.maxWait, 1), RelayTools.maxWait)
    let named = (a["runs"] as? [String])?.filter { relay.isChild($0) }
    let ids = named ?? relay.childRuns.filter(\.isActive).map(\.spec.threadID)
    let working = { (id: String) in self.agent.hub.run(for: id) != nil }
    let deadline = Date().addingTimeInterval(TimeInterval(seconds))
    while Date() < deadline, ids.contains(where: working) {
      try await Task.sleep(nanoseconds: 500_000_000)
    }
    return ["runs": try ids.map { try status(of: $0, detailed: true) }, "still_working": ids.filter(working)]
  }

  private func stop(_ a: [String: Any]) throws -> [String: Any] {
    if a["all"] as? Bool == true {
      let active = relay.childRuns.filter(\.isActive)
      for run in active { agent.hub.stop(run) }
      return ["stopped": active.map(\.spec.threadID)]
    }
    guard let id = a["run"] as? String, relay.isChild(id) else {
      throw SereinError.invalid("Give run (one Serein started) or all=true")
    }
    guard let run = agent.hub.run(for: id) else { return ["stopped": [], "note": "That run was not working."] }
    agent.hub.stop(run)
    return ["stopped": [id]]
  }

  private func overview() -> [String: Any] {
    let recent = relay.state.children.suffix(12).reversed()
    return [
      "runs": recent.map(\.threadID).compactMap { try? status(of: $0, detailed: false) },
      "working": relay.childRuns.filter(\.isActive).count,
      "projects": browser.shareableProjects.prefix(80).map { ["id": $0.id, "name": $0.name] },
      "agents": Provider.allCases.filter { $0.thinksForSerein && agent.available[$0] != nil }.map(\.name),
    ]
  }

  /// One delegated run. The reply is the agent's own words, which may quote websites: data.
  private func status(of id: String, detailed: Bool) throws -> [String: Any] {
    guard relay.isChild(id) else { throw SereinError.invalid("Serein did not start run \(id).") }
    let run = agent.hub.latest(for: id)
    let thread = agent.conversations.first { $0.id == id }
    let messages = run?.transcript ?? thread?.messages ?? []
    var out: [String: Any] = [
      "run": id,
      "title": run?.spec.title ?? thread?.title ?? "",
      "agent": (run?.spec.provider ?? thread?.provider)?.name ?? "",
      "state": run.map { $0.isActive ? "working" : $0.record.outcome.rawValue } ?? "finished",
    ]
    if let project = run?.spec.projectName ?? thread?.projectID.flatMap({ id in browser.projects.first { $0.id == id }?.name }) {
      out["project"] = project
    }
    if let run, run.isActive { out["progress"] = run.phase }
    if let error = run?.error { out["error"] = String(error.prefix(400)) }
    if detailed {
      // The child's words come back into Serein's chat: a marked child marks it too, and its
      // words are withheld when that mark cannot be saved.
      if agent.readsPersonal(thread: id), !agent.markPersonalRead(thread: relay.turnThread) {
        out["error"] = BrowserModel.personalMarkWithheld
        return out
      }
      if let reported = run?.reportedSummary { out["summary"] = reported }
      if let last = messages.last(where: { $0.role == "assistant" && !$0.text.isEmpty }) {
        out["reply_untrusted"] = String(last.text.suffix(2400))
        // What the child read joins Serein's own reply, so a chart of its numbers names their source.
        let names: [String] = last.read?.names ?? []
        for name in names { agent.hub.run(for: relay.turnThread)?.noteRead(name) }
      }
    }
    return out
  }

  private func harness(_ name: String?) throws -> Provider {
    let ready = Provider.allCases.filter { $0.thinksForSerein && agent.available[$0] != nil }
    guard let name, !name.isEmpty else {
      // Delegated work defaults to the acting assistant's own engine (its route), else Relay's.
      return relay.assistantEngine(relay.actingProfile).provider
    }
    if let id = RelayTools.harness(name, among: ready.map(\.rawValue)) { return Provider(rawValue: id) }
    if let display = RelayTools.harness(name, among: ready.map(\.name)), let p = ready.first(where: { $0.name == display }) {
      return p
    }
    throw SereinError.invalid("\(name) is not set up. Ready agents: " + ready.map(\.name).joined(separator: ", "))
  }
  private func projectNames() -> String {
    browser.shareableProjects.prefix(40).map(\.name).joined(separator: ", ")
  }

  // MARK: the hologram's look

  private func lookInfo() -> [String: Any] {
    let look = relay.look, store = relay.looks
    let why = store.refusal(own: relay.ownTurn, allowedOnOwn: relay.restyleOnItsOwn, now: Date())
    var out: [String: Any] = [
      "look": look.json, "wearing": look.name, "states_now": look.summary,
      "chosen_by": store.current.by.rawValue,
      "states": RelayLook.State.allCases.map { ["state": $0.rawValue, "means": $0.meaning] },
      "formations": RelayLook.formations.map { ["name": $0.name, "shape": $0.shape] },
      "cores": RelayLook.cores.map { ["name": $0.name, "shape": $0.shape] },
      "ring_styles": RelayLook.styles, "presets": RelayLook.presets.map(\.name),
      "how_to_write": RelayLook.guide, "skill": "design-your-look",
      "may_change_now": why == nil, "earlier_looks": store.history.suffix(5).map(\.look.name),
    ]
    if let why { out["why_not"] = why }
    if let reason = store.current.reason { out["reason"] = reason }
    if store.current.at != .distantPast { out["since"] = Self.stamp(store.current.at) }
    return out
  }
  private func setLook(_ a: [String: Any]) throws -> [String: Any] {
    guard a["look"] != nil || a["preset"] != nil else { throw SereinError.invalid("Give look (only what changes) or preset.") }
    var look = relay.look
    if let name = a["preset"] as? String {
      guard let preset = RelayLook.preset(name) else {
        throw SereinError.invalid("No preset is called \(name). Presets: " + RelayLook.presets.map(\.name).joined(separator: ", "))
      }
      look = preset
    }
    if let patch = a["look"] {
      guard let patch = patch as? [String: Any] else { throw SereinError.invalid("look must be an object") }
      look = try look.applying(patch)
    }
    let reason = (a["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160).description
    let own = relay.ownTurn
    try relay.wear(look, by: .relay, reason: reason?.isEmpty == false ? reason : nil)
    relay.note("Changed its look to “\(look.name)”" + (reason.map { $0.isEmpty ? "" : ": " + $0 } ?? ""), .auto)
    return [
      "wearing": look.name, "states": look.summary, "on_its_own": own,
      "undo": "look_undo goes back; the user can also say “undo your look” or use Settings › Appearance › Serein's look.",
    ]
  }

  // MARK: memory

  /// remember (SPEC 4.3, 5.2). What the person's words ask to keep applies at once with a
  /// receipt; without such words it is this assistant's idea, kept unreviewed until the person
  /// keeps it. `share` asks for a wider scope, which applies only when the person's words name the
  /// share (else a card). `keep` keeps one of the ideas recall offered, after the person said yes.
  /// A turn nobody typed is refused (`Admission`).
  private func remember(_ a: [String: Any]) async throws -> [String: Any] {
    if let id = (a["keep"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
      // Only the person's own yes keeps an idea (SPEC 4.3, R1): `typedWords` is empty in every
      // turn the person did not start, and an idea's text never counts.
      guard MemoryTools.saysKeep(relay.typedWords) else { throw SereinError.invalid(MemoryTools.keepNeedsYes) }
      let idea = try await relay.memoryRecord(id)
      try await admit(.memory, effect: AgentWrite.memoryEffect(), title: "Serein wants to keep a note", detail: String(idea.text.prefix(240)))
      let receipt = try await relay.keepIdea(idea)
      relay.note("Kept the note “\(String(idea.text.prefix(60)))”", .auto)
      return ["kept": id, "done": receipt.line]
    }
    guard let text = a["text"] as? String else { throw SereinError.invalid("text is required") }
    var expires: Date?
    if let raw = (a["expires"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
      guard let date = RelayReminder.parse(raw) else {
        throw SereinError.invalid("expires must be an ISO 8601 date such as 2026-11-02")
      }
      expires = date
    }
    var scope: MemoryScope?
    if let raw = (a["share"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
      scope = try shareScope(raw)
    }
    // A wider scope is a share: the person's words must name it. Keeping it to itself is not.
    let wider = scope.map { $0 != .assistant(relay.turnProfileID) } ?? false
    let title = wider ? "Serein wants to remember this for more assistants" : "Serein wants to remember this"
    try await admit(wider ? .shareMemory : .memory, effect: AgentWrite.memoryEffect(), title: title, detail: String(text.prefix(240)))
    let saved = try await relay.rememberFact(text, quote: a["quote"] as? String, scope: scope, expires: expires)
    relay.note("Remembered: \(String(text.prefix(80)))", .auto)
    var out: [String: Any] = ["saved": saved.record.id, "text": saved.record.text]
    if let receipt = saved.receipt {
      out["done"] = receipt.line
    } else {
      out["waiting"] = "Kept as an idea, not as a note: it is not used until the person keeps it. Offer it only when they ask what you remember."
    }
    return out
  }

  /// forget: one note by `id`, or up to three by `ids` (SPEC 4.3). The person's turn applies,
  /// with the 10-second Undo; a turn nobody typed is refused.
  private func forget(_ a: [String: Any]) async throws -> [String: Any] {
    var wanted: [String] = []
    if let id = (a["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty { wanted.append(id) }
    for id in (a["ids"] as? [String]) ?? [] where !wanted.contains(id) { wanted.append(id) }
    guard !wanted.isEmpty else { throw SereinError.invalid("id is required") }
    guard wanted.count <= 3 else {
      throw SereinError.invalid("Forget at most 3 notes at a time. Ask the person which ones matter most.")
    }
    var records: [MemoryRecord] = []
    for id in wanted {
      let record = try await relay.memoryRecord(id)
      records.append(record)
    }
    let detail = records.map { "“\(String($0.text.prefix(120)))”" }.joined(separator: ", ")
    let title = records.count == 1 ? "Serein wants to forget a note" : "Serein wants to forget \(records.count) notes"
    try await admit(.memory, effect: AgentWrite.memoryEffect(), title: title, detail: detail)
    let receipt = try await relay.forgetFacts(records)
    relay.note("Forgot \(records.count == 1 ? "a note" : "\(records.count) notes")", .auto)
    return ["forgotten": wanted, "done": receipt.line]
  }

  /// rule_save (harness v2 unit 1): a rule the person typed holds at once, with a receipt. No
  /// card: the guard is the quote, which must be the person's own words from this turn.
  private func saveRule(_ a: [String: Any]) async throws -> [String: Any] {
    guard let rule = a["rule"] as? String else { throw SereinError.invalid("rule is required") }
    guard let quote = a["quote"] as? String else { throw SereinError.invalid(Rules.quoteWordsMissing) }
    try await admit(.memory, effect: AgentWrite.memoryEffect(), title: "Serein wants to keep a rule", detail: String(rule.prefix(240)))
    let saved = try await relay.saveRule(rule, scope: a["scope"] as? String, quote: quote)
    guard let receipt = saved.receipt else { return ["saved": saved.record.id, "already": "That rule is already in force."] }
    relay.note("Rule: \(String(saved.record.text.prefix(80)))", .auto)
    return ["saved": saved.record.id, "rule": saved.record.text, "done": receipt.line]
  }

  /// memory_share: one note to every assistant, to one of the person's teams, or back to this
  /// assistant only (SPEC 4.3). A wider share applies when the person's words name it, else a
  /// card; a learned note, and one from outside content, never goes wider.
  private func shareMemory(_ a: [String: Any]) async throws -> [String: Any] {
    guard let id = (a["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
      throw SereinError.invalid("id is required")
    }
    guard let raw = (a["with"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      throw SereinError.invalid("with is required: everyone, the name of one of the person's teams, or only you")
    }
    let scope = try shareScope(raw)
    let record = try await relay.memoryRecord(id)
    // A note typed by hand is not filtered, but it does not go wider through the model if it fails.
    if let why = SavedText.problem(record.text) { throw SereinError.invalid(why) }
    let narrow = scope == .assistant(record.owner)
    let whom = MemoryTools.whom(scope, in: relay.team)
    try await admit(
      narrow ? .memory : .shareMemory, effect: AgentWrite.memoryEffect(), title: "Serein wants to share a note",
      detail: "\(whom) can use it: \(String(record.text.prefix(200)))")
    let receipt = try await relay.shareFact(record, with: scope)
    return ["shared": id, "with": whom, "done": receipt.line]
  }

  /// The scope a `share` or `with` names, or a refusal that says what it may name.
  private func shareScope(_ raw: String) throws -> MemoryScope {
    guard let scope = MemoryTools.scope(with: raw, in: relay.team, assistant: relay.turnProfileID) else {
      let teams = relay.team.teams.map(\.name)
      let named = teams.isEmpty ? "" : " Teams: " + teams.joined(separator: ", ") + "."
      throw SereinError.invalid("Share with everyone, one of the person's teams, or only you." + named)
    }
    return scope
  }

  /// One change to Serein itself, by `Admission` (`RelayOrchestrator.admission`): apply goes on, ask
  /// shows the card `gateAgentWrite` shows (a call outside any turn always asks), refuse says why.
  /// `named` is false when the person's words do not name what the change reaches (a routine for
  /// another assistant, a request Serein carries out): then an apply asks too.
  private func admit(
    _ change: Admission.Change, effect: ApprovalGate.Effect, title: String, detail: String, scheduled: Bool = false,
    named: Bool = true
  ) async throws {
    var verdict = relay.admission(change)
    if verdict == .apply, !named { verdict = .ask }
    switch verdict {
    case .apply: return
    case .ask: try await gateAgentWrite(effect, title: title, detail: detail, scheduled: scheduled)
    case .refuse(let words): throw SereinError.invalid(words)
    }
  }

  // MARK: reminders

  /// Serein, the main assistant, changes any routine or watch the person asks it to. Every other
  /// assistant changes only its own (SPEC 5.9): nil when the one `owner` names (nil is the
  /// person's own, which is Serein's) may change in this turn, else the words that say why not.
  private func ownerRefusal(_ owner: String?) -> String? {
    let acting: String = relay.turnProfileID
    let main: String = relay.team.mainProfileID ?? RelayTeam.mainID
    guard acting != main else { return nil }
    let whose: String = owner ?? main
    guard whose != acting else { return nil }
    let name: String = relay.profileName(whose)
    return "That belongs to \(name), so \(relay.profileName(acting)) cannot change it. Ask \(name) or Serein in their chat."
  }

  /// Reminders and routines change nothing while their file could not be read (SPEC I13).
  private func requireReadableSchedules() throws {
    let path = "relay/reminders.json"
    if relay.isUnreadable(path) { throw SereinError.invalid(RelayStateFile.words(for: path)) }
  }

  /// reminder_create. The host does every time sum (`in_minutes`, `ScheduleGuard.time`) and keeps
  /// routines within `ScheduleGuard` (no action repeats under 15 minutes, at most 20 on). By
  /// `Admission`: a plain reminder in the person's turn applies with a receipt; a request Serein
  /// carries out applies when the person's words name a schedule, else it asks on its card; kept
  /// sign-ins always ask; a routine for another assistant (`assistant`) asks unless the words name
  /// that assistant; a turn nobody typed is refused.
  /// A one-time follow-up a scheduled run or the person's own turn sets, without a card: bounded by
  /// RelayFollowUp, run under the scheduled gate, and acting only on the person's words that led
  /// to it (`source`), never on its own text. The person sees it in Settings and can cancel it.
  private func followUp(_ a: [String: Any], source: String, profileID: String?) throws -> [String: Any] {
    try requireReadableSchedules()
    guard let text = (a["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
      text.count <= 600
    else { throw SereinError.invalid("text is required (under 600 characters)") }
    let now = Date()
    guard let first = ScheduleRequest.firstDue(at: a["at"] as? String, inMinutes: a["in_minutes"] as? Int, now: now),
      case .success(let due) = first
    else {
      throw SereinError.invalid(
        "Give in_minutes, or at as an ISO 8601 time such as \(Self.stamp(now.addingTimeInterval(86_400)))")
    }
    let repeats = RelayReminder.Repeat(rawValue: a["repeat"] as? String ?? "none") ?? .none
    let cron = (a["cron"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    if let refusal = RelayFollowUp.refusal(
      repeats: repeats, cron: cron, due: due, now: now, setThisRun: relay.followedUpThisRun ? 1 : 0,
      open: RelayFollowUp.open(relay.reminders))
    {
      throw SereinError.invalid(refusal)
    }
    if let refusal = ScheduleRequest.refusal(
      repeats: .none, cron: nil, acts: true, actionRoutinesOn: ScheduleRequest.actionRoutinesOn(relay.reminders))
    {
      throw SereinError.invalid(refusal.words)
    }
    guard relay.reminders.count < 200 else { throw SereinError.invalid("Too many reminders. Cancel some first.") }
    var reminder = RelayReminder(text: text, due: due, action: true, profileID: profileID)
    reminder.selfSet = true
    reminder.source = source
    relay.markFollowUp()
    let made = reminder
    relay.changeReminder(made.id, actor: "relay", "Serein set a follow-up: \(RelayOrchestrator.short(text))") { $0 = made }
    relay.note(
      "Serein set a follow-up for \(made.due.formatted(date: .abbreviated, time: .shortened)): “\(String(text.prefix(60)))”",
      .auto)
    var out = Self.reminder(made)
    out["done"] = "Follow-up set. It runs once, and the person can cancel it."
    return out
  }

  private func createReminder(_ a: [String: Any]) async throws -> [String: Any] {
    try requireReadableSchedules()
    guard let text = (a["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
      text.count <= 600
    else { throw SereinError.invalid("text is required (under 600 characters)") }
    let now = Date()
    guard let first = ScheduleRequest.firstDue(at: a["at"] as? String, inMinutes: a["in_minutes"] as? Int, now: now) else {
      throw SereinError.invalid(
        "Give in_minutes, or at as an ISO 8601 time such as \(Self.stamp(now.addingTimeInterval(3600)))")
    }
    let due: Date
    switch first {
    case .success(let date): due = date
    case .failure(let refusal): throw SereinError.invalid(refusal.words)
    }
    let repeats = RelayReminder.Repeat(rawValue: a["repeat"] as? String ?? "none") ?? .none
    var expression: String?
    if let raw = (a["cron"] as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
      guard let schedule = RelayCron(parse: raw) else {
        throw SereinError.invalid("cron must be five fields such as 17 9 * * 1-5 (minute hour day-of-month month day-of-week).")
      }
      expression = schedule.expression
    }
    guard due > now.addingTimeInterval(-60) || repeats != .none || expression != nil else {
      throw SereinError.invalid("That time has passed. Now is \(Self.stamp(now)).")
    }
    guard relay.reminders.count < 200 else { throw SereinError.invalid("Too many reminders. Cancel some first.") }
    let action = a["action"] as? Bool ?? false
    let rule: RelayReminder.Repeat = expression != nil ? .cron : repeats
    if let refusal = ScheduleRequest.refusal(
      repeats: rule, cron: expression, acts: action, actionRoutinesOn: ScheduleRequest.actionRoutinesOn(relay.reminders))
    {
      throw SereinError.invalid(refusal.words)
    }
    // Whose it is: the assistant the request names, else the one acting now. Its runs happen in
    // that assistant's own chat, with its engine and scope (SPEC I10).
    let acting = relay.actingProfile
    var owner = acting
    if let name = (a["assistant"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
      guard let named = relay.team.profile(named: name) else {
        let names = relay.team.profiles.map(\.name).joined(separator: ", ")
        throw SereinError.invalid("No assistant is called \(String(name.prefix(40))). Your assistants: \(names).")
      }
      owner = named
    }
    let other: Bool = owner != nil && owner?.id != acting?.id
    var reminder = RelayReminder(
      text: text, due: due, repeats: rule, action: action, cron: expression, profileID: owner?.id)
    // The kept sign-ins its runs may use with nobody watching: only sites the person keeps
    // (KeptSignIns) that no Never rule covers, each named on the card below. Its runs use no other.
    var signIns: [String] = []
    if let named = a["sign_ins"] as? [String], !named.isEmpty {
      guard reminder.action else { throw SereinError.invalid("sign_ins is only for a request you carry out (action=true).") }
      for name in named.prefix(10) {
        guard let site = KeptSignIns.named(name), KeptSignIns.kept(site) != nil, SiteRules.rule(for: site) != .never else {
          throw SereinError.invalid(
            "Serein isn't kept signed in to \(String(name.prefix(80))). Leave it out of sign_ins: the user keeps a sign-in at Hand back, and lists them in Settings › Privacy.")
        }
        if !signIns.contains(site) { signIns.append(site) }
      }
      reminder.signInSites = signIns
    }
    if let weekly = a["weekly_tokens"] as? Int {
      guard reminder.action else { throw SereinError.invalid("weekly_tokens is only for a request you carry out (action=true).") }
      reminder = try reminder.limitingWeek(to: weekly, now: Date())
    }
    // Typed words approve what they name: the routine's owner, and, for a request Serein carries
    // out, a schedule.
    let words = relay.typedWords
    let ownerNamed: Bool = !other || ScheduleRequest.wordsName(owner?.name ?? "", in: words)
    let scheduleNamed: Bool = !reminder.action || ScheduleRequest.namesSchedule(words)
    if reminder.action {
      // It fires as a scheduled turn (RelayOrchestrator.drainScheduled), so it is judged as one now.
      let date = reminder.due.formatted(date: .abbreviated, time: .shortened)
      let when = reminder.repeats == .none ? "At \(date)" : "From \(date), repeating (\(expression ?? reminder.repeats.rawValue))"
      let plural: String = signIns.count == 1 ? "" : "s"
      let signedIn: String = signIns.isEmpty
        ? "" : ", signed in to \(signIns.joined(separator: ", ")) with the sign-in\(plural) you kept,"
      let whose: String = other ? " as \(owner?.name ?? "another assistant")" : ""
      try await admit(
        .schedule(signIns: !signIns.isEmpty), effect: AgentWrite.requestEffect(),
        title: "Serein wants to do something later on its own",
        detail: "\(when), Serein runs this request on its own\(whose)\(signedIn) and may start other tasks: \(String(text.prefix(240)))"
          + Self.costLines(reminder, relay: relay),
        scheduled: true, named: ownerNamed && scheduleNamed)
    } else {
      let date = reminder.due.formatted(date: .abbreviated, time: .shortened)
      try await admit(
        .schedule(signIns: false), effect: AgentWrite.memoryEffect(), title: "Serein wants to set a reminder",
        detail: "\(date): \(String(text.prefix(240)))", named: ownerNamed)
    }
    // Recorded like the person's own changes, so its receipt's Undo and Settings can take it back.
    let made = reminder
    relay.changeReminder(made.id, actor: "relay", "Added \(RelayOrchestrator.short(text))") { $0 = made }
    GuideCenter.shared.record(.reminderCreated)
    relay.noteReminderCreated(made)
    relay.note("Scheduled “\(String(text.prefix(60)))” for \(made.due.formatted(date: .abbreviated, time: .shortened))", .auto)
    // A routine whose words name an app that is not connected carries its connect pill (board 13).
    let missing: [ConnectLink] = made.action ? Array(relay.missingApps(in: text).prefix(1)) : []
    let receipt = relay.scheduleReceipt(for: made, owner: other ? owner?.name : nil, connect: missing)
    var out = Self.reminder(made)
    out["done"] = receipt.line
    return out
  }

  /// Serein's own edit of a schedule. The card shows each old and new value; by `Admission` the
  /// person's turn applies when their words name a schedule change, with a receipt, and a schedule
  /// with kept sign-ins always asks. The new timing stays within `ScheduleGuard`. Nothing changes
  /// before a yes; a no leaves the schedule as it was.
  private func updateReminder(_ a: [String: Any]) async throws -> [String: Any] {
    try requireReadableSchedules()
    guard let id = a["id"] as? String, let old = relay.reminders.first(where: { $0.id == id }) else {
      throw SereinError.invalid("No reminder has that id. Use reminder_list to find it.")
    }
    if TodoBoard.isReminder(id) { throw Self.boardReminder }
    if let refusal = ownerRefusal(old.profileID) { throw SereinError.invalid(refusal) }
    var atArg: Date?
    if let at = a["at"] as? String {
      guard let parsed = RelayReminder.parse(at) else {
        throw SereinError.invalid("at must be an ISO 8601 time such as \(Self.stamp(Date().addingTimeInterval(3600)))")
      }
      atArg = parsed
    }
    var repeatArg: RelayReminder.Repeat?
    if let raw = a["repeat"] as? String {
      guard let parsed = RelayReminder.Repeat(rawValue: raw) else {
        throw SereinError.invalid("repeat is one of " + RelayReminder.Repeat.allCases.map(\.rawValue).joined(separator: ", "))
      }
      repeatArg = parsed
    }
    var cronArg: String?
    if let raw = (a["cron"] as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty { cronArg = raw }
    let textArg = a["text"] as? String
    let stopArg = a["stop_after"] as? Int
    let weeklyArg = a["weekly_tokens"] as? Int
    let paused = a["paused"] as? Bool
    // Only the fields Serein named change; every other field comes from `r` as it is, on a fresh clock.
    func apply(_ r: RelayReminder, now: Date) throws -> RelayReminder {
      var repeats = repeatArg ?? r.repeats
      var cron = r.cron
      if let cronArg {
        cron = cronArg
        repeats = .cron
      }
      let limit = stopArg.map { $0 > 0 ? $0 : nil } ?? r.limit
      var next = try r.editing(
        text: textArg ?? r.text, due: atArg ?? r.due, repeats: repeats, cron: cron, limit: limit,
        skipIfBusy: r.skipsWhileBusy, now: now)
      if let weeklyArg { next = try next.limitingWeek(to: weeklyArg > 0 ? weeklyArg : nil, now: now) }
      if let paused { next = paused ? next.pausing() : next.resumed(now: now) }
      return next
    }
    let preview = try apply(old, now: Date())
    if let refusal = ScheduleRequest.refusal(
      repeats: preview.repeats, cron: preview.cron, acts: preview.action, on: preview.paused != true,
      actionRoutinesOn: ScheduleRequest.actionRoutinesOn(relay.reminders, except: id))
    {
      throw SereinError.invalid(refusal.words)
    }
    let lines = RelayReminder.changeLines(from: old, to: preview)
    guard !lines.isEmpty else { return Self.reminder(old) }
    let effect = ApprovalGate.settingsEffect(tool: "settings_set")
    var detail: String = "“\(String(old.text.prefix(120)))”\n" + lines
    // New words keep the kept sign-ins the request named: the card says so.
    let signedIn: [String] = old.signInSites ?? []
    if !signedIn.isEmpty, preview.text != old.text {
      detail += "\nIts runs stay signed in to \(signedIn.joined(separator: ", "))."
    }
    if old.action, preview.weeklyTokens != old.weeklyTokens || preview.cron != old.cron || preview.repeats != old.repeats {
      detail += relay.costEstimate(preview).map { "\n" + $0 } ?? ""
    }
    let named: Bool = ScheduleRequest.namesSchedule(relay.typedWords)
    try await admit(
      .schedule(signIns: !signedIn.isEmpty), effect: effect,
      title: "Serein wants to change \(old.action ? "a scheduled request" : "a reminder")", detail: detail,
      scheduled: old.action, named: named)
    // Only the fields the card showed change, applied to the schedule as it is now: runs that
    // landed and edits the person made while the card waited stay.
    var gone = false
    try relay.changeReminder(id, actor: "relay", "Changed \(RelayOrchestrator.short(old.text))") { current in
      guard let reminder = current else {
        gone = true
        return
      }
      current = try apply(reminder, now: Date())
    }
    guard !gone, let updated = relay.reminders.first(where: { $0.id == id }) else {
      throw SereinError.invalid("That reminder was removed while the user decided.")
    }
    relay.note("Changed “\(String(updated.text.prefix(60)))”: " + lines.replacingOccurrences(of: "\n", with: "; "), .allowed)
    var ownerName: String?
    if let ownerID = updated.profileID, ownerID != relay.actingProfile?.id {
      ownerName = relay.team.profiles.first(where: { $0.id == ownerID })?.name
    }
    let receipt = relay.scheduleReceipt(for: updated, owner: ownerName)
    var out = Self.reminder(updated)
    out["done"] = receipt.line
    return out
  }

  // MARK: standing instructions

  /// The standing instructions are the person's own words: Serein may only propose a new
  /// version. The proposal is a memory write (`.change`, so it asks under every level), and the
  /// card shows what goes and what comes. Allowed, it is journaled with actor "relay" and Undo
  /// puts the earlier words back.
  private func proposeInstructions(_ a: [String: Any]) async throws -> [String: Any] {
    guard let raw = a["rules"] as? String else {
      throw SereinError.invalid("rules is required: the complete new list, one instruction per line")
    }
    let before = relay.persona.rules
    let proposed = RelayPersona(rules: raw).sanitized()?.rules ?? ""
    if let why = SavedText.problem(proposed) { throw SereinError.invalid(why) }
    guard proposed != before else { throw SereinError.invalid("Those are already the standing instructions.") }
    try await gateAgentWrite(
      AgentWrite.memoryEffect(), title: "Serein wants to change your standing instructions",
      detail: RelayPersona.changeSummary(from: before, to: proposed),
      more: RelayPersona.changeText(from: before, to: proposed), moreName: "the change")
    // The card can wait; if the person edited them meanwhile, what they allowed is no longer the change.
    guard relay.persona.rules == before else {
      throw SereinError.invalid("The standing instructions changed while the card waited, so nothing was changed.")
    }
    relay.updateInstructions(proposed, actor: "relay")
    relay.note("Changed the standing instructions", .allowed)
    return ["rules": proposed]
  }

  // MARK: goals

  /// A goal is a scheduled request that checks again and again, so it is judged as one now. By
  /// `Admission`, the person's turn applies with a receipt when their words name a goal or a
  /// schedule; otherwise the card shows the goal, how often it checks and when it ends, and a no
  /// creates nothing. Its checks stay within `ScheduleGuard`. Each check later runs unattended
  /// (`runsUnattended`), so every step beyond reading asks.
  private func createGoal(_ a: [String: Any]) async throws -> [String: Any] {
    try requireReadableSchedules()
    guard let text = (a["goal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
      text.count <= 600
    else { throw SereinError.invalid("goal is required (under 600 characters)") }
    let now = Date()
    var first = now.addingTimeInterval(60)
    if let at = a["at"] as? String {
      guard let parsed = RelayReminder.parse(at) else {
        throw SereinError.invalid("at must be an ISO 8601 time such as \(Self.stamp(now.addingTimeInterval(3600)))")
      }
      first = parsed
    }
    var ends = now.addingTimeInterval(RelayGoal.defaultSpan)
    if let raw = a["ends"] as? String {
      guard let parsed = RelayReminder.parse(raw), parsed > now, parsed <= now.addingTimeInterval(RelayGoal.longest) else {
        throw SereinError.invalid("ends must be an ISO 8601 time after now and within a year.")
      }
      ends = parsed
    }
    var quietLimit: Int?
    if let quiet = a["quiet_after"] as? Int {
      guard (1...100).contains(quiet) else { throw SereinError.invalid("quiet_after takes 1 to 100 checks.") }
      quietLimit = quiet
    }
    let cron = (a["cron"] as? String)?.trimmingCharacters(in: .whitespaces)
    var repeats = RelayReminder.Repeat(rawValue: a["repeat"] as? String ?? "daily") ?? .daily
    if cron?.isEmpty == false { repeats = .cron }
    guard repeats != .none else { throw SereinError.invalid("A goal checks again and again: repeat is daily, weekdays, weekly or cron.") }
    let guardedCron: String? = cron?.isEmpty == false ? cron : nil
    if let refusal = ScheduleRequest.refusal(
      repeats: repeats, cron: guardedCron, acts: true, actionRoutinesOn: ScheduleRequest.actionRoutinesOn(relay.reminders))
    {
      throw SereinError.invalid(refusal.words)
    }
    guard relay.reminders.filter({ $0.goal != nil }).count < RelayGoal.maxGoals else {
      throw SereinError.invalid("\(RelayGoal.maxGoals) goals are the limit. End or delete one first.")
    }
    // The schedule's own rules: a cron runs at its next match, a time already past moves on.
    let draft = RelayReminder(
      text: text, due: first, repeats: repeats, action: true, goal: RelayGoal(ends: ends, quietLimit: quietLimit),
      profileID: relay.actingProfile?.id)
    let goal = try draft.editing(
      text: text, due: first, repeats: repeats, cron: cron, limit: nil, skipIfBusy: true, now: now)
    guard goal.due < ends else { throw SereinError.invalid("The first check must come before the end date.") }
    guard relay.reminders.count < 200 else { throw SereinError.invalid("Too many reminders. Cancel some first.") }
    let date = goal.due.formatted(date: .abbreviated, time: .shortened)
    let until = ends.formatted(date: .abbreviated, time: .omitted)
    let quiet = quietLimit.map { ", or after \($0) checks in a row with nothing new" } ?? ""
    try await admit(
      .schedule(signIns: false), effect: AgentWrite.requestEffect(), title: "Serein wants to track a goal",
      detail: "From \(date), \(goal.scheduleTitle.lowercased()), until \(until)\(quiet), Serein checks this on its own and tells you only what is new. Checks read; any other step asks you. Goal: \(text)"
        + Self.costLines(goal, relay: relay),
      scheduled: true, named: ScheduleRequest.namesGoal(relay.typedWords))
    guard relay.reminders.filter({ $0.goal != nil }).count < RelayGoal.maxGoals else {
      throw SereinError.invalid("\(RelayGoal.maxGoals) goals are the limit. End or delete one first.")
    }
    // Recorded like the person's own changes, so Settings can undo it.
    relay.changeReminder(goal.id, actor: "relay", "Added goal \(RelayOrchestrator.short(text))") { $0 = goal }
    relay.noteReminderCreated(goal)
    relay.note("Tracking goal “\(String(text.prefix(60)))” \(goal.scheduleTitle.lowercased()) until \(until)", .allowed)
    let receipt = relay.scheduleReceipt(for: goal, owner: nil)
    var out = Self.reminder(goal)
    out["done"] = receipt.line
    return out
  }

  /// Serein's own edit of a goal's note, end date or quiet limit, or Done: the card shows each old
  /// and new value, judged as a settings change that later runs unattended, as reminder_update.
  private func updateGoal(_ a: [String: Any]) async throws -> [String: Any] {
    guard let id = a["id"] as? String, let old = relay.reminders.first(where: { $0.id == id }), old.goal != nil else {
      throw SereinError.invalid("No goal has that id. Use reminder_list to find it.")
    }
    if let refusal = ownerRefusal(old.profileID) { throw SereinError.invalid(refusal) }
    var endsArg: Date?
    if let raw = a["ends"] as? String {
      guard let parsed = RelayReminder.parse(raw) else { throw SereinError.invalid("ends must be an ISO 8601 time.") }
      endsArg = parsed
    }
    let noteArg = a["note"] as? String
    let quietArg = a["quiet_after"] as? Int
    let done = a["done"] as? Bool == true
    func apply(_ r: RelayReminder, now: Date) throws -> RelayReminder {
      guard let g = r.goal else { throw SereinError.invalid("That goal was removed while the user decided.") }
      var next = try r.editingGoal(
        note: noteArg ?? g.note ?? "", ends: endsArg ?? g.ends,
        quietLimit: quietArg.map { $0 > 0 ? $0 : nil } ?? g.quietLimit, now: now)
      if done, !next.goalEnded { next = next.ending("Marked done in Serein's chat") }
      return next
    }
    let preview = try apply(old, now: Date())
    let lines = RelayReminder.changeLines(from: old, to: preview)
    guard !lines.isEmpty else { return Self.reminder(old) }
    try await gateAgentWrite(
      ApprovalGate.settingsEffect(tool: "settings_set"), title: "Serein wants to change a goal",
      detail: "“\(String(old.text.prefix(120)))”\n" + lines, scheduled: true)
    var gone = false
    let summary = (done ? "Ended goal " : "Changed goal ") + RelayOrchestrator.short(old.text)
    try relay.changeReminder(id, actor: "relay", summary) { current in
      guard let reminder = current, reminder.goal != nil else {
        gone = true
        return
      }
      current = try apply(reminder, now: Date())
    }
    guard !gone, let updated = relay.reminders.first(where: { $0.id == id }) else {
      throw SereinError.invalid("That goal was removed while the user decided.")
    }
    relay.note("Changed goal “\(String(updated.text.prefix(60)))”: " + lines.replacingOccurrences(of: "\n", with: "; "), .allowed)
    return Self.reminder(updated)
  }

  // MARK: watches

  private func createWatch(_ a: [String: Any]) async throws -> [String: Any] {
    guard let name = (a["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !name.isEmpty, name.count <= 80
    else { throw SereinError.invalid("name is required (under 80 characters)") }
    guard let raw = a["kind"] as? String, let kind = RelayWatch.Kind(rawValue: raw) else {
      throw SereinError.invalid("kind is script or url")
    }
    guard let source = (a["source"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty,
      RelayWatch.validSource(kind: kind, source: source)
    else {
      throw SereinError.invalid(
        kind == .script
          ? "source must be a read-only AppleScript over Calendar, Reminders, Notes or Finder (getting names, counts or titles)."
          : "source must be a public page, https://…")
    }
    if kind == .url { try SiteRules.check(source) }
    // The assistant's own places and Never sites, as for any step it takes (AssistantScope).
    if let refusal = relay.placeRefusal(kind == .url ? .web : .mac) { throw SereinError.invalid(refusal) }
    if kind == .url, let profile = relay.actingProfile, relay.effectiveScope(profile)?.blocks(source) == true {
      throw SereinError.invalid(AssistantScope.siteRefusal(name: profile.name, address: source))
    }
    guard relay.watches.count < RelayWatch.maxWatches else {
      throw SereinError.invalid("\(RelayWatch.maxWatches) watches are the limit. Cancel one first.")
    }
    let watch = RelayWatch(
      name: name, kind: kind, source: source, minutes: RelayWatch.clamped(minutes: a["minutes"] as? Int ?? 15),
      profileID: relay.actingProfile?.id, request: relay.typedWords.isEmpty ? nil : relay.typedWords)
    try await gateAgentWrite(
      AgentWrite.watchEffect(), title: "Serein wants to watch “\(name)”",
      detail: "This checks later and can start a run. \(String(source.prefix(180)))")
    relay.updateWatches { $0.append(watch) }
    GuideCenter.shared.record(.watchCreated)
    relay.note(
      "Alert “\(name)”: checking \(kind == .script ? "“\(String(source.prefix(60)))”" : String(source.prefix(80))) every \(watch.minutes) min",
      .auto)
    // The first check learns the starting answer, so the watch fires on the first change after it.
    Task { await relay.checkWatch(watch) }
    return Self.watch(watch)
  }

  /// A run that can click or type on websites, edit project files or work in Mac apps acts on its
  /// instructions, so starting or steering one always asks; only an answer run with none of these
  /// follows Autopilot.
  static func runEffect(_ target: AgentModel.DispatchTarget) -> ApprovalGate.Effect {
    target.actions || target.edits || target.mac ? .change : .navigate
  }

  /// Asks before a delegated run starts or takes new instructions, by `ApprovalDoor.answer`.
  /// The one-time consent card comes only before a routine step, which is then judged again.
  /// A no, a timeout or an error starts and sends nothing.
  private func gateRun(
    _ effect: ApprovalGate.Effect, title: String, detail: String, button: String, more: String? = nil,
    moreName: String = "the details", declined: String = "The user declined this delegated run.",
    task: Bool = false, site: SiteRule = .normal
  ) async throws {
    // `task`: a task started or steered in the person's own turn stands at Proactive, at any chat level.
    let today = relay.standing
    let standing: ApprovalDoor.Standing = task && today.levelStands && today.present ? .proactiveTask(present: true) : today
    let judge = { (standing: ApprovalDoor.Standing) throws -> RelayAutonomy.Decision in
      try ApprovalDoor.answer(
        .init(.effect(effect), standing, site: site),
        facts: .init(
          secureField: false, botCheck: false, pays: .no, covered: false, path: nil,
          hostKeyChanged: nil, runsAnything: false, ref: "")
      ).decision()
    }
    var decision = try judge(standing)
    if decision == .auto, standing.level != .proactive {
      guard await relay.settleConsent(thread: relay.turnThread) else { throw SereinError.invalid(RelayOrchestrator.stoppedStep) }
      decision = try judge(relay.standing)
    }
    if decision == .auto { return }
    let human = await relay.confirmAnswer(
      title, detail, button: button, thread: relay.turnThread, more: more, moreName: moreName)
    guard human == .yes else {
      throw SereinError.invalid(human == .no ? declined : ActionAdmission.needsPerson)
    }
  }

  /// Asks before an agent memory write, a new watch or a request for later. The effect is the one
  /// `ApprovalGate` judges; `scheduled` is set for a write that later runs a turn unattended.
  /// `more` is shown behind the card's “Show `moreName`” disclosure; the defaults are
  /// `confirmAnswer`'s, so a card without it is unchanged.
  private func gateAgentWrite(
    _ effect: ApprovalGate.Effect, title: String, detail: String, scheduled: Bool = false,
    more: String? = nil, moreName: String = "the script"
  ) async throws {
    let decision = try ApprovalDoor.answer(
      .init(.effect(effect), relay.standing(present: !(scheduled || relay.runsUnattended))),
      facts: .init(
        secureField: false, botCheck: false, pays: .no, covered: false, path: nil,
        hostKeyChanged: nil, runsAnything: false, ref: "")
    ).decision()
    if decision == .auto { return }
    let human = await relay.confirmAnswer(
      title, ApprovalGate.askLine(effect) + " " + detail, thread: relay.turnThread, more: more, moreName: moreName)
    guard human == .yes else {
      throw SereinError.invalid(human == .no ? ActionAdmission.declined : ActionAdmission.needsPerson)
    }
  }

  static func watch(_ w: RelayWatch) -> [String: Any] {
    var out: [String: Any] = [
      "id": w.id, "name": w.name, "kind": w.kind.rawValue,
      "source_untrusted": String(w.source.prefix(400)), "minutes": w.minutes,
      "last_check": w.lastCheckedAt.map(stamp) ?? "",
      "paused": w.paused == true, "failures": w.failures ?? 0,
    ]
    if let answer = w.lastAnswer { out["last_answer_untrusted"] = String(answer.prefix(600)) }
    return out
  }

  /// A Mac step in plain words: "Clicked “New Note” in Notes".
  static func describe(_ step: RelayAutonomy.MacStep) -> String {    let target = step.label.map { "“\(String($0.prefix(40)))”" }
    switch step.kind {
    case "click": return "Clicked \(target ?? "a spot") in \(step.app)"
    case "type": return "Typed into \(target ?? "a field") in \(step.app)"
    case "key": return "Pressed \(step.key ?? "a key") in \(step.app)"
    case "scroll": return "Scrolled in \(step.app)"
    default: return "\(step.kind.capitalized) in \(step.app)"
    }
  }
  static func reminder(_ r: RelayReminder) -> [String: Any] {
    var out: [String: Any] = [
      "id": r.id, "text": r.text, "due": stamp(r.due), "repeat": r.repeats.rawValue, "action": r.action,
    ]
    if let cron = r.cron { out["cron"] = cron }
    if r.selfSet == true { out["set_by"] = "Serein, as a follow-up" }
    if let sites = r.signInSites { out["sign_ins"] = sites }
    if let failures = r.failures { out["failures"] = failures }
    if r.paused == true { out["paused"] = true }
    if let limit = r.limit { out["stop_after"] = limit; out["runs"] = r.runs ?? 0 }
    if let average = r.averageTokens { out["tokens_a_run"] = average }
    let week = r.tokensThisWeek(now: Date())
    if week > 0 { out["tokens_this_week"] = week }
    if let weekly = r.weeklyTokens { out["weekly_tokens"] = weekly }
    if r.pausedByCost == true { out["paused_by_weekly_tokens"] = true }
    if let goal = r.goal {
      // The note and the findings were written from web pages: data, never instructions.
      var g: [String: Any] = ["ends": stamp(goal.ends), "checks": goal.checks ?? 0]
      if let quiet = goal.quietLimit { g["quiet_after"] = quiet }
      if let ended = goal.ended { g["ended"] = ended }
      if let note = goal.note { g["note_untrusted"] = AgentPrivacy.redact(note, limit: RelayGoal.noteLimit) }
      let fresh = goal.fresh(now: Date())
      g["new_since_yesterday"] = fresh.count
      g["findings_untrusted"] = (goal.findings ?? []).suffix(10).map {
        ["at": stamp($0.at), "text": $0.text, "link": $0.link.map(AgentPrivacy.url) ?? ""]
      }
      out["goal"] = g
    }
    return out
  }
  /// The creation card's cost: the estimate, and the weekly limit when one was asked for.
  static func costLines(_ reminder: RelayReminder, relay: RelayOrchestrator) -> String {
    var lines = relay.costEstimate(reminder).map { "\n" + $0 } ?? ""
    if let weekly = reminder.weeklyTokens {
      lines += "\nOnly this request pauses, until the next week, once its runs use \(UsageLedger.Summary.short(weekly)) tokens in a week."
    }
    return lines
  }
  static func stamp(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.timeZone = .current
    return f.string(from: date)
  }
}
