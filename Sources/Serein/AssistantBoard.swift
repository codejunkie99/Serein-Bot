import AppKit
import SereinCore
import UniformTypeIdentifiers

/// The assistants board in the app: one state per assistant for the sidebar rows, the team
/// headers and the header picker, the roster edits the board makes by hand (every one through
/// `changeTeam`, so it is journaled and undoable), and the person's own hand-off, which asks on
/// the same card an assistant's suggestion does. The rules are pure, in SereinCore/AssistantBoard.swift.
extension RelayOrchestrator {
  // MARK: who is doing what

  /// An assistant's Main chat when it has one on disk; nothing is written here, so an assistant
  /// that never spoke has no chat and no state of its own.
  func knownMainThread(of id: String) -> String? {
    if id == team.activeID { return threadID }
    if let cached = mainThreadCache[id] { return cached }
    guard let saved = browser.library.load(State.self, from: team.folder(id) + "/state.json") else { return nil }
    mainThreadCache[id] = saved.threadID
    return saved.threadID
  }
  /// The assistant a chat belongs to: the owner of a delegated task, else the assistant whose
  /// Main chat it is; nil for a chat of nobody's.
  func assistantOwning(thread: String?) -> String? {
    guard let thread else { return nil }
    if let owner = childOwners[thread] { return owner.isEmpty ? nil : owner }
    if thread == threadID { return team.activeID }
    if let record = handoffLedger.records.last(where: { $0.threadID == thread }) { return record.to }
    return team.profiles.first { knownMainThread(of: $0.id) == thread }?.id
  }
  /// The words of the first card waiting on the person in an assistant's chats, or nil: its chats'
  /// approvals, then (the active assistant) an ask_user form and the consent card, then approvals
  /// of runs it owns, then secure cards open in its chats. The one list `assistantStatus` reads for
  /// Needs you, so the dot and "Waiting for you:" never disagree. Titles and labels only, never an
  /// approval's detail; `AssistantRowPreview` makes them safe.
  func waitingQuestion(_ id: String, hub: AgentHub) -> String? {
    let active = id == team.activeID
    let owns: (String?) -> Bool = { [self] thread in assistantOwning(thread: thread) == id }
    if let approval = approvals.first(where: { owns($0.threadID) }) { return approval.title }
    if active, let form = questionForms.first { return form.questions.first?.label ?? form.title }
    if active && consentWaiting { return ApprovalLevel.consentTitle }
    let run = hub.runs.first { $0.isActive && owns($0.spec.threadID) && !$0.approvals.isEmpty }
    if let label = run?.approvals.first?.label { return label }
    return browser.secureCards.open.first { owns($0.thread) }?.title
  }
  /// Any card waiting on the person, in any chat: an approval, an ask_user form, the consent card
  /// or an open secure card, owned by any assistant or by none. Unlike `waitingQuestion` it leaves
  /// out run approvals, which SereinTrayList.needsYou covers.
  var cardsWaiting: Bool {
    !approvals.isEmpty || !questionForms.isEmpty || consentWaiting || !browser.secureCards.open.isEmpty
  }
  /// The sidebar row's one-line preview of an assistant's Main chat (and the Search palette's):
  /// its waiting card, else its newest of the last 8 messages. Reads only memory.
  func rowPreview(_ id: String) -> AssistantRowPreview? {
    guard let profile = team.profiles.first(where: { $0.id == id }) else { return nil }
    let thread = knownMainThread(of: id)
    let replying = id == team.activeID ? replyingHere : thread.flatMap { agent.hub.latest(for: $0) }?.isActive == true
    return AssistantRowPreview.of(waiting: waitingQuestion(id, hub: agent.hub),
                                  lines: AssistantRowMenu.chatLines(self, profile, last: 8), replying: replying)
  }
  /// One assistant's state, in the Serein row's vocabulary (`SereinStatus.current`): its own
  /// cards, the tasks it started, a hand-off it works on, and an unread reply in its chat.
  func assistantStatus(_ id: String, hub: AgentHub, online: Bool, connected: Bool, unread: Bool) -> SereinStatus {
    let active = id == team.activeID
    let needsYou = waitingQuestion(id, hub: hub) != nil
    let handingOver = handoffLedger.records.contains { $0.state == .running && $0.to == id }
    // A routine in its owner's own chat (`ownerRun`) shows on that owner, never on the chat on screen.
    let ownsRoutine: Bool = ownerRun?.profileID == id
    let replying: Bool = ownsRoutine || (active ? replyingHere : handingOver)
    let tasks = hub.slotted.filter { childOwners[$0.spec.threadID] == id }.count
    // Stop Everything pauses every assistant; `assistant_change` pauses one (RelayProfile.paused).
    let paused: Bool = state.paused || team.profiles.contains { $0.id == id && $0.isPaused }
    return SereinStatus.current(
      needsYou: needsYou, connected: connected, online: online, paused: paused, replying: replying,
      working: tasks, unread: active && unread)
  }
  /// A reply runs in the chat on screen: Serein's own turn here. Another assistant's routine in
  /// its own chat (`ownerRun`) keeps `working` true, so Serein starts no other turn, but it is not
  /// a reply here: the header, the status line and the send button do not show it.
  var replyingHere: Bool {
    guard working else { return false }
    guard let owner = ownerRun else { return true }
    return owner.thread == threadID
  }
  /// Another assistant's routine that runs in its own chat, away from the chat on screen.
  var routineElsewhere: OwnerRun? {
    guard let owner = ownerRun, owner.thread != threadID else { return nil }
    return owner
  }
  /// The short live line of what an assistant works on right now, for a folded team's Now line.
  func assistantPhase(_ id: String, hub: AgentHub) -> String? {
    if let thread = knownMainThread(of: id), let run = hub.run(for: thread), run.isActive { return run.phase }
    return hub.slotted.first { childOwners[$0.spec.threadID] == id }?.phase
  }
  /// Every assistant's name and state, for the attention dot and the header picker.
  func assistantStates(hub: AgentHub, online: Bool, connected: Bool, unread: Bool) -> [(name: String, status: SereinStatus)] {
    team.profiles.map { ($0.name, assistantStatus($0.id, hub: hub, online: online, connected: connected, unread: unread)) }
  }
  /// The team the person last opened, while it still exists.
  var activeTeam: AssistantGroup? {
    guard let id = activeTeamID, !id.isEmpty else { return nil }
    return team.group(id)
  }
  /// The assistant who answers a team: its lead, else its first member.
  func responder(of group: AssistantGroup) -> String? {
    group.leadID.flatMap { lead in group.memberIDs.contains(lead) ? lead : nil } ?? group.memberIDs.first
  }

  // MARK: opening chats

  /// A click on an assistant's row, a picker row or a result card: it becomes the active
  /// assistant and its Main chat shows where Serein is (beside stays beside, hidden peeks, no room
  /// shows full). Refused mid-reply: the work in flight belongs to the assistant that started it.
  @discardableResult
  func openAssistant(_ id: String, team groupID: String? = nil) -> Bool {
    if id != team.activeID {
      guard switchTo(id) else {
        ToastCenter.shared.show("\(team.activeName) is still busy in this chat. Wait for it to finish, then switch.")
        return false
      }
    }
    if activeTeamID != groupID { activeTeamID = groupID }
    let surface = SereinSurface.main
    surface.view = .chat
    if surface.place == .full { surface.requestFocus() } else { SereinRouter.show() }
    return true
  }
  /// A click on a team header: the team becomes active and its lead (or first member) answers.
  @discardableResult
  func openTeam(_ groupID: String) -> Bool {
    guard let group = team.group(groupID), let who = responder(of: group) else { return false }
    return openAssistant(who, team: groupID)
  }

  // MARK: roster edits by hand (each journaled, with Undo on its toast)

  /// Shows the change's toast with Undo, which puts the roster back (`undoTeam`).
  private func toastTeamChange(_ text: String) {
    guard let entry = teamJournal.last else { return }
    ToastCenter.shared.show(text, actionTitle: "Undo", commandZ: true) { [weak self] in self?.undoTeam(entry) }
  }
  /// New assistant: inherits everything, Speaks first Never, the next free tint. nil refuses:
  /// the name is empty or taken, the roster is full, or Serein is mid-reply.
  func addAssistant(named name: String) -> RelayProfile? {
    guard addProfile(name), let made = team.profiles.last else { return nil }
    persist(RelayPersona(name: made.name), team.folder(made.id) + "/persona.json")
    // Edit opens its page in Settings › Assistants.
    ToastCenter.shared.show("Added \(made.name).", actionTitle: "Edit") { AssistantSettingsKey.open(made.id) }
    return made
  }
  /// Delete Writer… after its confirmation: its chats stay in History, its routines, watches and
  /// links pause, and Undo brings it all back (`DeletePlan`, RelayAssistantTools.swift).
  func deleteAssistant(_ id: String) {
    guard case .success(let plan) = deletePlan(for: id), let receipt = applyDelete(plan, actor: "user"),
      let entry = receipt.undo?.entry
    else { return }
    let chat = threadID
    ToastCenter.shared.show("Deleted \(plan.profile.name).", actionTitle: "Undo", commandZ: true) { [weak self] in
      _ = self?.revert(entry: entry, chat: chat)
    }
  }
  /// Delete Trip planner… after its confirmation: the assistants stay.
  func deleteTeam(_ groupID: String) {
    let name = team.group(groupID)?.name ?? "the team"
    if activeTeamID == groupID { activeTeamID = nil }
    guard removeGroup(groupID) else { return }
    toastTeamChange("Deleted \(name).")
  }
  func addToTeam(_ profileID: String, _ groupID: String) {
    let who = profileName(profileID), where_ = team.group(groupID)?.name ?? "the team"
    guard changeTeam("Added \(who) to \(where_)", { $0.addingMember(profileID, to: groupID) }) else { return }
    toastTeamChange("Added \(who) to \(where_).")
  }
  func removeFromTeam(_ profileID: String, _ groupID: String) {
    let who = profileName(profileID), where_ = team.group(groupID)?.name ?? "the team"
    guard changeTeam("Removed \(who) from \(where_)", { $0.removingMember(profileID, from: groupID) }) else { return }
    if team.group(groupID) == nil, activeTeamID == groupID { activeTeamID = nil }
    toastTeamChange("Removed \(who) from \(where_).")
  }
  func setLead(_ profileID: String?, of groupID: String) {
    let where_ = team.group(groupID)?.name ?? "the team"
    let summary = profileID.map { "Made \(profileName($0)) lead of \(where_)" } ?? "Removed the lead of \(where_)"
    guard changeTeam(summary, { $0.settingLead(profileID, of: groupID) }) else { return }
    toastTeamChange(summary + ".")
  }
  func renameTeam(_ groupID: String, to name: String) -> Bool {
    changeTeam("Renamed the team \(team.group(groupID)?.name ?? "") to \(name.trimmingCharacters(in: .whitespacesAndNewlines))") {
      $0.renamingGroup(groupID, to: name)
    }
  }
  func orderMembers(_ order: [String], of groupID: String) {
    changeTeam("Reordered \(team.group(groupID)?.name ?? "a team")") { $0.orderingMembers(order, of: groupID) }
  }
  func orderTeams(_ order: [String]) {
    changeTeam("Reordered the teams") { $0.orderingGroups(order) }
  }
  func setSpeaksFirst(_ profileID: String, _ level: RelayProactive.Level) {
    /// The main assistant's unset level is Settings' level; written first, so Undo puts that back.
    if profileID == team.mainProfileID { syncSpeaksFirst(main: proactiveLevel) }
    changeTeam("\(profileName(profileID)) speaks first: \(level.title)") { $0.settingSpeaksFirst(profileID, level) }
  }
  /// A new team by hand (Blank): existing assistants, a name and a lead.
  func createTeam(named name: String, members: [String], lead: String?) -> Bool {
    let made = changeTeam("Created team \(name.trimmingCharacters(in: .whitespacesAndNewlines))") {
      $0.addingGroup(AssistantGroup(name: name.trimmingCharacters(in: .whitespacesAndNewlines), memberIDs: members, leadID: lead))
    }
    if made { toastTeamChange("Added \(team.teams.last?.name ?? name).") }
    return made
  }
  /// Duplicate: the team, and on request copies of its assistants, who can do the same and never more.
  func duplicateTeam(_ groupID: String, as name: String, copyingMembers: Bool) -> Bool {
    let source = team.group(groupID)?.name ?? "a team"
    let before = team
    let made = changeTeam("Duplicated \(source) as \(name)") { $0.duplicatingGroup(groupID, as: name, copyingMembers: copyingMembers) }
    if made {
      // Each copy answers to its own name from its first turn, as a proposal's members do.
      for profile in team.profiles where !before.profiles.contains(where: { $0.id == profile.id }) {
        persist(RelayPersona(name: profile.name), team.folder(profile.id) + "/persona.json")
      }
      toastTeamChange("Added \(name).")
    }
    return made
  }
  /// A starter, an edited proposal, or an imported file after Add team: the same path a
  /// proposal card's Create team takes (`createTeam(_:actor:)`), with the person as the actor.
  func createTeam(fromSheet proposal: TeamProposal) -> String? {
    do {
      _ = try createTeam(proposal, actor: "user")
      toastTeamChange("Added \(proposal.name).")
      return nil
    } catch {
      return error.localizedDescription
    }
  }
  /// The editor's Save: the whole form in one journaled change. A new picture (`picture`, read
  /// once when it was chosen) is written to the assistant's folder first. nil when saved; else why not.
  func saveAssistant(
    _ id: String, name: String, colour: String?, icon: AssistantIcon?, picture: Data?, scope: AssistantScope,
    speaksFirst: RelayProactive.Level?
  ) -> String? {
    let places = personPlaces
    let clean = RelayProfile.cleanName(name)
    guard !clean.isEmpty else { return "Give \(profileName(id)) a name." }
    guard !team.profiles.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(clean) == .orderedSame }) else {
      return "Another assistant is called \(clean)."
    }
    guard !scope.destinations.isEmpty else { return "\(clean) needs at least one thing it can use." }
    guard scope.destinations.isSubset(of: places) else { return "\(clean) can only use what you allow Serein." }
    guard scope.neverSites.count <= AssistantBoard.neverSitesLimit else {
      return "\(AssistantBoard.neverSitesLimit) sites is the most for one assistant."
    }
    /// The main assistant's unset level is Settings' level; written first, so Undo puts that back.
    if id == team.mainProfileID { syncSpeaksFirst(main: proactiveLevel) }
    guard let before = team.profiles.first(where: { $0.id == id }) else { return "\(clean) was deleted." }
    // Nothing narrowed: the assistant keeps the person's full settings (nil), so a place turned on
    // later still reaches it.
    let kept: AssistantScope? = before.scope == nil && scope.destinations == places && scope.neverSites.isEmpty
      && scope.instructions.isEmpty && scope.apps == nil ? nil : scope
    // An unchanged level keeps following its default (Settings' level for the main assistant).
    let level: RelayProactive.Level? = before.speaksFirst == nil && speaksFirst == self.speaksFirst(before) ? nil : speaksFirst
    // A refusal must never read as saved.
    guard team.updatingProfile(id, name: clean, colour: colour, icon: icon, scope: kept, speaksFirst: level, person: places) != nil
    else {
      return "\(clean) couldn't be saved. Check its settings and try again."
    }
    if let picture, let file = icon?.pictureFile, !AssistantPictures.save(picture, as: file, owner: id, relay: self) {
      return "Serein couldn't save the picture. Try again, or choose another icon."
    }
    let renamed = before.name != clean
    if renamed { _ = renameProfile(id, to: clean) }
    let summary = "Saved \(clean)"
    let saved = changeTeam(summary) {
      $0.updatingProfile(id, name: clean, colour: colour, icon: icon, scope: kept, speaksFirst: level, person: places)
    }
    guard saved || renamed else { return nil }
    if saved { toastTeamChange("Saved \(clean).") } else { ToastCenter.shared.show("Saved \(clean).") }
    if id == team.activeID, renamed { updatePersona(RelayPersona(name: clean, about: persona.about, rules: persona.rules)) }
    return nil
  }
  /// Its Speaks first now (`RelayProactive.level(of:in:global:)`): its own level; unset, Settings' level.
  func speaksFirst(_ profile: RelayProfile) -> RelayProactive.Level {
    RelayProactive.level(of: profile, in: team, global: proactiveLevel)
  }
  /// Export Team…: the team as a file through the save panel, redacted, with keys, history,
  /// models and grants left out (`TeamFile`).
  func exportTeam(_ groupID: String) {
    guard let group = team.group(groupID) else { return }
    let file = TeamFile(group: group, profiles: team.profiles)
    let saved = ChatExport.saveText(
      named: TeamFile.fileName(group.name), panelTitle: "Export Team",
      message: "The file holds names, icons, what each assistant can use, its Never sites and instructions. Keys, chat history, models, permissions and pictures are left out.",
      types: TeamFile.fileTypes
    ) { (try? file.text()) ?? "" }
    // Each member's Library lists the file it is in (AssistantLibrary, this launch).
    if let saved { AssistantLibrary.shared.exported(saved, owners: group.memberIDs) }
  }

  // MARK: the inspector (AssistantInspector.swift)

  /// The label under an assistant's name: one journaled change with Undo on its toast. nil when
  /// saved or unchanged; else why it was refused (`RelayProfile.cleanLabel`).
  func setLabel(_ id: String, _ text: String) -> String? {
    guard let clean = RelayProfile.cleanLabel(text) else { return RelayProfile.labelRefusal }
    let name = profileName(id)
    let summary = clean.isEmpty ? "Removed \(name)'s label" : "Labelled \(name) “\(clean)”"
    guard changeTeam(summary, { $0.settingLabel(id, clean) }) else { return nil }
    toastTeamChange(summary + ".")
    return nil
  }
  /// An assistant's icon from the inspector's mark: one journaled change with Undo on its toast. A
  /// new picture (`picture`, read once when it was chosen) is written to its folder first, under a
  /// name of its own, so Undo shows the one before. nil when saved or unchanged; else why not.
  func setIcon(_ id: String, _ icon: AssistantIcon?, picture: Data? = nil) -> String? {
    guard icon?.checked == icon else { return "Serein couldn't use that icon." }
    // Nothing is written for an assistant that is gone (or an unchanged icon): a new folder would
    // keep Undo from bringing the deleted assistant's files back.
    guard team.settingIcon(id, icon) != nil else { return nil }
    if let picture, let file = icon?.pictureFile, !AssistantPictures.save(picture, as: file, owner: id, relay: self) {
      return "Serein couldn't save the picture. Try again."
    }
    let name = profileName(id)
    let summary = icon == nil ? "Gave \(name) the petal again" : "Changed \(name)'s icon"
    guard changeTeam(summary, { $0.settingIcon(id, icon) }) else { return nil }
    toastTeamChange(summary + ".")
    return nil
  }
  /// The harness, model and effort an assistant thinks with: its own route while that harness can
  /// think for Serein on this Mac (the model kept only when the AI app lists it,
  /// `RelayToolHost.modelAndEffort`); else Serein's own (Settings › Assistants › Default AI app) at its
  /// default model. Its Main chat, hand-offs to it, its turns of speaking first and the tasks it
  /// starts without naming an AI app all use this.
  /// `route`: a swarm seat's own, picked from the registry, in place of the assistant's.
  func assistantEngine(_ profile: RelayProfile?, route seat: AssistantRoute? = nil) -> (provider: Provider, model: String, effort: String) {
    // No route of its own: it thinks as Serein does (`RelayTeam.route(of:)`), so an assistant never
    // lands on an AI app nobody chose (Claude Code first by default, even when it is signed out).
    if let route = seat ?? profile.flatMap(team.route(of:)) {
      let chosen = Provider(rawValue: route.provider)
      // A route refused now (signed out, a version gate) stays: its turn fails closed at send with
      // that reason, never moved silently onto Serein's engine, which could change who pays.
      if chosen.thinksForSerein, agent.available[chosen] != nil {
        let pick = RelayToolHost.modelAndEffort(
          ["model": route.model, "effort": route.effort ?? ""], models: HarnessRegistry.shared.models(chosen))
        return (chosen, pick.model, pick.effort)
      }
    }
    return (provider, "", "medium")
  }
  /// Why an assistant cannot be moved onto `provider` now, or nil: a model endpoint gets no Serein
  /// tools, and a harness the policy refuses for the Main chat's mode ("anywhere") would have every
  /// turn refused at send (`HarnessRegistry.verdict`). The model list and `chooseRoute` use it; a
  /// route already chosen is kept by `assistantEngine` and fails closed at send instead.
  static func assistantRouteRefusal(_ provider: Provider) -> String? {
    guard provider.thinksForSerein else { return "A local model can't answer as an assistant" }
    return HarnessRegistry.shared.verdict(provider, mode: TaskMode.anywhere.runKey, edits: false, permission: .supervised).reason
  }
  /// The same, as the model list's check mark and the pill read it.
  func chatEngine(ofAssistant id: String) -> AgentModel.ChatEngine { chatEngine(of: profile(id: id)) }
  /// What an assistant made now would think with (the starting route, else Serein's): the model
  /// list's check mark for "All assistants". Always a listed model or the app's listed default.
  var newAssistantEngine: AgentModel.ChatEngine { chatEngine(of: RelayProfile(id: "", name: "")) }
  private func chatEngine(of profile: RelayProfile) -> AgentModel.ChatEngine {
    let engine = assistantEngine(profile)
    return AgentModel.ChatEngine(
      provider: engine.provider, model: engine.model, mode: .anywhere, link: nil, edits: false, permission: .supervised)
  }
  /// The composer's effort chip: the assistant's next turns run at `effort` (`assistantEngine`).
  /// Stored on its route; with no route yet, it is pinned to the engine it thinks with now.
  func setEffort(_ effort: String, for id: String) {
    guard let who = team.profiles.first(where: { $0.id == id }) else { return }
    let engine = assistantEngine(who)
    var route = team.route(of: who) ?? AssistantRoute(provider: engine.provider.rawValue, model: engine.model)
    route.effort = effort
    _ = setProfileRoute(id, route)
  }
  /// An assistant's own engine, saved outside the journal: an undo never moves an assistant onto
  /// another route, which could change who pays without asking (`RelayTeam.undoing` keeps every
  /// current route). `switchRoute` calls it (the model list's pick, a held turn's Use another
  /// AI app…) after the switch's own rules, and `setEffort` for an effort on the same model.
  func setProfileRoute(_ id: String, _ route: AssistantRoute?) -> Bool {
    setRoutes { $0.settingRoute(id, route, fallback: AssistantRoute(provider: provider.rawValue, model: "")) }
  }
  /// Who a pick in the model list is for: the assistant it was opened for, or every assistant and
  /// those made later (`RelayTeam.startingRoute`).
  enum RouteScope { case thisAssistant, allAssistants }
  /// A pick in the inspector's model list sets the assistant's own route, by the chat switch's
  /// rules (AgentModel.switchModel, ModelBackups.askToMove): a move that could change who pays
  /// (onto the person's own key, or onto another provider's plan: `ModelFallback.sameCost`) waits
  /// behind an approval card first, and a real change declines what its Main chat was asking.
  func chooseRoute(_ route: ModelRoute, for id: String, scope: RouteScope = .thisAssistant) {
    Task { [weak self] in
      guard let self else { return }
      let every = scope == .allAssistants
      guard await (every ? self.switchEveryRoute(route) : self.switchRoute(route, for: id)) else { return }
      // A pick for Serein answers setup's AI app question too (SereinChatSetup.adopt).
      if every || id == self.team.mainProfileID {
        SereinChatSetup.shared.adopt(AssistantRoute(provider: route.provider, model: route.model), relay: self)
      }
    }
  }
  /// The same move, awaited: true once the assistant thinks with `route` (it already did, the
  /// same-cost move was made, or its card was allowed). A held turn's Use another AI app… waits
  /// on it before it goes again (`continueElsewhere`). `byPerson` false: Serein makes a same-cost
  /// move by itself, so the holds it sends again read the step journal (`resumeLimitedHolds`).
  func switchRoute(_ route: ModelRoute, for id: String, isCurrent: @escaping () -> Bool = { true },
                   byPerson: Bool = true, atLimit: Bool = false) async -> Bool {
    guard isCurrent(), route.selectable, Self.assistantRouteRefusal(Provider(rawValue: route.provider)) == nil,
      let who = team.profiles.first(where: { $0.id == id })
    else { return false }
    let now = assistantEngine(who)
    let from = agent.routes(now.provider, models: [now.model]).first
    guard from?.id != route.id else {
      // Confirming the current implicit default is still an explicit choice. Pin it so a later
      // change to the global fallback cannot silently move this assistant to another AI app.
      let explicit = AssistantRoute(provider: route.provider, model: route.model, effort: team.route(of: who)?.effort)
      return who.route == explicit || setProfileRoute(id, explicit)
    }
    guard let from, ModelFallback.sameCost(from: from, to: route) || atLimit && LimitFailover.allowed(from: from, to: route) else {
      let uses = "\(who.name)'s chat and the tasks it starts use it. Its chat's pending approvals are declined."
      guard await askRoute(route, name: who.name, uses: uses, isCurrent: isCurrent, liveFrom: {
        self.team.profiles.first { $0.id == who.id }.map(self.engineRouteID)
      }) else { return false }
      return applyRoute(route, for: id)
    }
    if atLimit { failedOver(id, from: from, to: route) }
    return applyRoute(route, for: id, byPerson: byPerson)
  }
  /// "All assistants", awaited: true once every assistant thinks with `route` and it is the
  /// starting route. Refused as `switchRoute` refuses; one pay card for the whole move when any
  /// assistant's move could change who pays. Nothing is written before that card is answered, and
  /// one save carries every route and the starting one, so Stay or a refusal changes nothing.
  private func switchEveryRoute(_ route: ModelRoute) async -> Bool {
    guard route.selectable, Self.assistantRouteRefusal(Provider(rawValue: route.provider)) == nil else { return false }
    let froms = team.profiles.map { who -> (id: String, from: ModelRoute?) in
      let now = assistantEngine(who)
      return (who.id, agent.routes(now.provider, models: [now.model]).first)
    }
    let movers = froms.filter { $0.from?.id != route.id }.map(\.id)
    let asks = froms.contains { move in
      guard let from = move.from else { return true }
      return from.id != route.id && !ModelFallback.sameCost(from: from, to: route)
    }
    if asks {
      let uses = "Every assistant's chat, the tasks they start and assistants made later use it. Their chats' pending approvals are declined."
      guard await askRoute(route, name: "every assistant", uses: uses, isCurrent: { true }, liveFrom: {
        self.team.profiles.map(self.engineRouteID).joined(separator: ",")
      }) else { return false }
    }
    let next = AssistantRoute(provider: route.provider, model: route.model)
    _ = setRoutes { $0.settingEveryRoute(next) }
    for id in movers { if let thread = knownMainThread(of: id) { agent.dropApprovals(chat: thread) } }
    if !movers.isEmpty { note("Every assistant thinks with \(ModelBackups.name(route))", .user) }
    if movers.contains(team.activeID) { resumeLimitedHolds(on: route.provider, byPerson: true) }
    return team.startingRoute == next
  }
  /// The route an assistant thinks with now, as the model list names it; "" when none is listed.
  private func engineRouteID(_ who: RelayProfile) -> String {
    let now = assistantEngine(who)
    return agent.routes(now.provider, models: [now.model]).first?.id ?? ""
  }
  /// The card for a move that can change the bill. Its intent is minted with the pay effect
  /// (ApprovalGate.record), which is in `mustAsk`, so Autopilot never answers it. Switch applies
  /// it only while the assistant is still on the engine the card was asked from and the route can
  /// still answer (ApprovalGate.beforeInput); Stay, a timeout or a change meanwhile leaves it.
  /// `name` is who moves ("Writer", "every assistant") and `uses` the detail's last words.
  /// `liveFrom`: the engine it moves from now, nil once the assistant is gone. True when allowed.
  private func askRoute(_ route: ModelRoute, name: String, uses: String, isCurrent: () -> Bool,
                        liveFrom: () -> String?) async -> Bool {
    let toName = ModelBackups.name(route)
    let action = ApprovalGate.GateAction(
      kind: "switch_model", label: "Use \(toName) for \(name)", effect: .pay, elementID: route.id,
      pageVersion: liveFrom() ?? "")
    let intent = ApprovalGate.record(action, effect: .pay) { UUID().uuidString }
    // The person's own pick of a paid route: the card below is the decision.
    let bill = route.costClass == .free ? "" : ApprovalGate.askLine(.pay) + " "
    let title = "Switch \(name) to \(toName) (\(route.costClass.label))?"
    let detail = RouteTag.help(route.costClass) + ". " + bill + uses
    // Every route here is the person's own pick, so a Stay earlier does not silence the next pick.
    ApprovalEnds.shared.forgetDenial(title: title, detail: detail, thread: threadID)
    let human = await confirmAnswer(title, detail, button: "Switch", decline: "Stay", thread: threadID, effect: .pay,
                                    aboutSerein: true)
    let still = agent.routes(Provider(rawValue: route.provider), models: [route.model]).first
    // The card named who pays: a route whose cost class changed while it waited (a key added
    // meanwhile) is not applied.
    guard isCurrent(), let live = liveFrom(), still?.costClass == route.costClass,
      ApprovalGate.beforeInput(
        intent: intent, answer: human, liveElement: still?.selectable == true ? route.id : "", liveVersion: live,
        liveEffect: .pay)
    else { return false }
    return true
  }
  /// Saves the route (outside the journal: `setProfileRoute`), then declines what the assistant's
  /// Main chat was asking the old engine (a chat it already has; none is made for this).
  @discardableResult private func applyRoute(_ route: ModelRoute, for id: String, byPerson: Bool = true) -> Bool {
    guard setProfileRoute(id, AssistantRoute(provider: route.provider, model: route.model)) else { return false }
    if let thread = knownMainThread(of: id) { agent.dropApprovals(chat: thread) }
    note("\(profileName(id)) thinks with \(ModelBackups.name(route))", .user)
    if id == team.activeID { resumeLimitedHolds(on: route.provider, byPerson: byPerson) }
    return true
  }

  // MARK: the person's own hand-off

  /// Why the person cannot hand work to `target` from the active assistant now, in the words the
  /// chat shows, or nil. The depth rule never applies: the person is not a handed-over task.
  func handoffRefusal(to target: RelayProfile) -> String? {
    guard let sender = team.active else { return "No assistant is answering." }
    guard sender.id != target.id else { return "\(target.name) is already in this chat." }
    guard team.handoffTargets(from: sender.id).contains(where: { $0.id == target.id }) else {
      return "\(target.name) isn't in a team with \(sender.name)."
    }
    return handoffLedger.refusal(from: sender.id, fromName: sender.name, to: target.id, toName: target.name, now: Date())
  }
  /// Ask Writer to Continue, a message dropped on Writer's row, Hand Off to Writer…: the words go
  /// to Writer's Main chat at once. The person is the sender, so no turn is needed.
  /// `personal`: the words come from a hand-off that was already personal (Send again).
  func requestHandoff(to targetID: String, task: String, personal: Bool = false) {
    guard !runsUnattended, let sender = team.active, let target = team.profiles.first(where: { $0.id == targetID }) else { return }
    if let refusal = handoffRefusal(to: target) {
      lastError = refusal
      return
    }
    let group = team.sharedGroup(sender.id, target.id)
    let words = task.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !words.isEmpty, words.count <= HandoffLedger.taskLimit else {
      lastError = "The task is empty or longer than \(HandoffLedger.taskLimit) characters, so nothing was handed over."
      return
    }
    _ = sendHandoff(from: sender, to: target, task: words, team: group?.id ?? "", teamName: group?.name ?? "All assistants",
                    personal: personal, how: .user)
  }
  /// Send again on an expired hand-off: the same words, sent again.
  func resendHandoff(_ record: AssistantHandoff) {
    requestHandoff(to: record.to, task: record.task, personal: record.personal == true)
  }
  /// Stop on a stalled hand-off: only that run ends; its end marks the hand-off failed.
  func stopHandoff(_ record: AssistantHandoff) {
    guard record.state == .running, let run = agent.hub.run(for: record.threadID) else { return }
    agent.hub.stop(run)
  }
  /// Open Writer's chat from a status line or result card: Writer's Main chat where Serein is.
  func openHandoffChat(_ record: AssistantHandoff) {
    guard openAssistant(record.to) else { return }
    if !record.threadID.isEmpty, record.threadID != threadID { _ = resumeChat(record.threadID) }
  }

  // MARK: previews

  /// `--ui-assistants`: a roster of four with one team, so previews draw the board. It writes
  /// through `changeTeam` into the preview's own throwaway library (reachable only with
  /// `--ui-preview`). `--ui-team-chat` also opens that team's chat with a short conversation, and
  /// `--ui-team-chat typing` has its lead working, and `--ui-team-chat handoff` hands a message on. `--ui-pins` adds three more and pins five, so
  /// the pinned faces show how they fill the sidebar's width. `--ui-row-previews` adds the same
  /// three and gives each row a preview (`previewRowChats`); `--ui-model-scope` sets the starting route.
  /// `--ui-harness-v2 [seed]` adds Coach and seeds Serein's chat (`previewHarnessV2`).
  func previewTeam() {
    let teamChat = CommandLine.arguments.contains("--ui-team-chat")
    let harnessV2 = CommandLine.arguments.contains("--ui-harness-v2")
    guard CommandLine.arguments.contains("--ui-preview"), CommandLine.arguments.contains("--ui-assistants") || teamChat || harnessV2
    else { return }
    defer { if harnessV2 { previewHarnessV2() } }
    defer { if teamChat { previewTeamChat() } }
    let pins = CommandLine.arguments.contains("--ui-pins")
    let rows = CommandLine.arguments.contains("--ui-row-previews")
    defer { if pins { team.profiles.dropFirst().prefix(5).forEach { AssistantRowState.shared.pin($0.id) } } }
    defer { if rows { previewRowChats() } }
    defer { previewModelScope() }
    changeTeam("Preview roster") { current in
      var team = current
      for name in ["Scout", "Planner", "Writer"] + (pins || rows ? ["Coach", "Shopper", "Editor"] : harnessV2 ? ["Coach"] : []) {
        guard let next = team.adding(name) else { return nil }
        team = next
      }
      let ids = team.profiles.map(\.id)
      guard ids.count >= 4 else { return nil }
      team.profiles[1].scope = AssistantScope(destinations: [.web, .answer])
      team.profiles[2].scope = AssistantScope(destinations: [.answer])
      team.profiles[3].scope = AssistantScope(destinations: [.answer, .web], instructions: "Write briefly.")
      let members = teamChat ? [ids[1], ids[2], ids[3], ids[0]] : [ids[1], ids[2]]
      return team.addingGroup(AssistantGroup(name: "Trip planner", memberIDs: members, leadID: ids[1]))
    }
    // `--ui-computer-place`: Serein's details open on Computer, with the place it runs on at the top.
    if CommandLine.arguments.contains("--ui-computer-place"), let main = team.main?.id {
      GateSettings.shared.set(true, forKey: ComputerPolicy.enabledKey)
      DispatchQueue.main.async { AssistantInspector.shared.show(main, tab: .activity) }
    }
  }

  /// One turn in each preview assistant's Main chat, in memory, so `rowPreview` reads: Scout
  /// "You: can you book the 8:05…" cut with "…"; Planner "Sent 2 PDFs"; Writer "Ran 4 steps";
  /// Coach "Waiting for you: Sign in to example.com" (an open secure card); Shopper "You: my card
  /// [REDACTED] and [REDACTED]"; Editor a reply with a right-to-left override, drawn in order.
  private func previewRowChats() {
    var chips = AgentMessage(role: "you", text: "")
    chips.attached = ["itinerary.pdf", "tickets.pdf"]
    var steps = AgentMessage(role: "assistant", text: "")
    steps.activities = (1...4).map { TranscriptActivity(id: "preview-step-\($0)", tool: "Read", label: "Read page \($0)") }
    let turns: [String: AgentMessage] = [
      "Scout": AgentMessage(role: "you", text: "can you book the 8:05 to Lisbon on Friday, hold the Alfama hotel with the river view until Sunday, and check whether the airport transfer is included"),
      "Planner": chips, "Writer": steps,
      "Coach": AgentMessage(role: "assistant", text: "Signing in to example.com now."),
      "Shopper": AgentMessage(role: "you", text: "my card 4242 4242 4242 4242 and password: hunter2"),
      "Editor": AgentMessage(role: "assistant", text: "Total due \u{202E}00.51$\u{202C} by Friday"),
    ]
    for profile in team.profiles {
      guard let message = turns[profile.name] else { continue }
      let thread = "preview-row-" + profile.id
      mainThreadCache[profile.id] = thread
      var chat = Conversation(
        id: thread, title: profile.name, messages: [message], provider: .claude, mode: .anywhere, projectID: nil, remoteID: nil,
        scope: "", updatedAt: Date())
      chat.lastMessageAt = Date()
      agent.conversations.removeAll { $0.id == thread }
      agent.conversations.append(chat)
      guard profile.name == "Coach" else { continue }
      _ = browser.secureCards.raise(SecureCards.Card(
        kind: .password, parts: [], host: "example.com", amount: nil, task: "preview-row-card", thread: thread, tab: nil,
        ref: "preview", document: "", origin: "https://example.com", pageVersion: ""))
    }
  }
  /// `--ui-model-scope`: the starting route on the first model Serein's AI app lists, so
  /// `newAssistantEngine` shows it. `--ui-model-scope gone`: on a model id that app does not list,
  /// so a new assistant reads the app's listed default and the saved route stays as it was.
  private func previewModelScope() {
    let arguments = CommandLine.arguments
    guard let flag = arguments.firstIndex(of: "--ui-model-scope") else { return }
    let gone = arguments.dropFirst(flag + 1).first == "gone"
    let app = team.main?.route?.provider ?? provider.rawValue
    let model = gone ? "serein-preview-retired" : HarnessRegistry.shared.models(Provider(rawValue: app)).first?.id ?? ""
    _ = setRoutes { current in
      var next = current
      next.startingRoute = AssistantRoute(provider: app, model: model)
      return next
    }
  }

  private func previewTeamChat() {
    guard let group = team.teams.first, let lead = group.leadID, openTeam(group.id) else { return }
    let helper = group.memberIDs.first { $0 != lead }
    var messages = [
      AgentMessage(role: "you", text: "Plan a long weekend in Lisbon under $1,500."),
      AgentMessage(role: "assistant", text: "TAP has a nonstop for $640, leaving Friday morning."),
      AgentMessage(role: "assistant", text: "That leaves $860 for three nights and food."),
    ]
    var answer = AgentMessage(role: "assistant", text: "Two hotels in Alfama fit. I can draft the days once you pick one.")
    answer.from = helper
    messages.append(answer)
    messages.append(AgentMessage(role: "you", text: "Hold that flight."))
    let variant = CommandLine.arguments.drop(while: { $0 != "--ui-team-chat" }).dropFirst().first
    let typing = variant == "typing"
    if typing {
      let turn = AgentRun(
        spec: RunSpec(threadID: threadID, provider: .claude, executable: "/usr/bin/false", model: "",
          effort: "medium", mode: .anywhere, projectID: nil, projectName: nil, title: "Scout · Reply",
          scope: "Synthetic preview", autoRouting: false, grants: RunGrants(), limits: RunLimits(hard: nil, idle: 3600),
          relay: true),
        taskID: "relay-preview-team-turn", transcript: messages)
      turn.phase = "Checking flights…"
      agent.hub.adoptPreview(turn)
    } else {
      messages.append(AgentMessage(role: "assistant", text: "Should I hold the Friday flight for 24 hours?"))
    }
    var chat = Conversation(
      id: threadID, title: "Lisbon weekend", messages: messages, provider: .claude, mode: .anywhere, projectID: nil, remoteID: nil, scope: "",
      updatedAt: Date())
    chat.lastMessageAt = Date()
    agent.conversations.removeAll { $0.id == threadID }
    agent.conversations.insert(chat, at: 0)
    // `--ui-team-chat handoff`: the lead hands the hotels to the helper, as the person's own hand-off does.
    if variant == "handoff", let helper {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.requestHandoff(to: helper, task: answer.text) }
    }
  }
}

extension TeamFile {
  /// The export's and the open panel's types: `.serein-team`, and plain JSON.
  static var fileTypes: [UTType] {
    [UTType(filenameExtension: format, conformingTo: .json), UTType.json].compactMap { $0 }
  }
}
