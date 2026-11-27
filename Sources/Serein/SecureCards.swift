import Foundation
import SereinCore
import SereinEngines
import WebKit

/// The secure cards open in the chat (SecureCard), and the person steps waiting on the person's
/// card (PersonStep). Neither holds its task's call: the call answers `asked` at once, and the
/// answer reaches the task later (`ComposerFlow.deliver`). The person's entry goes from the view
/// through `submit` into the page fill and is dropped. Cards are keyed by task, so a task that
/// moves to another AI app keeps them (R12, R20).
@MainActor final class SecureCards: ObservableObject {
  struct Card: Identifiable {
    let id = UUID()
    let kind: SecureCard.Kind
    let parts: [SecureCard.Part]
    /// The tab's top page host: the site the value goes to.
    let host: String
    let amount: String?
    let task: String
    let thread: String?
    weak var tab: BrowserTab?
    let ref: String
    let document: String
    let origin: String
    let pageVersion: String
    /// A Mac app's field (MacSecureCard.swift): `tab` is nil and `document` names the field.
    var mac: MacControl.SecureTarget? = nil
    /// A field in Serein's computer (ComputerHost+Box): `tab` is nil, `ref` names the element.
    var box: ComputerHost.BoxField? = nil
    /// A day with no answer closes it (R26).
    let opened = Date()
    var title: String { SecureCard.title(kind, host: host, amount: amount) }
  }
  /// The relay redraws too: its Needs you and row previews read this list (`waitingQuestion`).
  @Published private(set) var open: [Card] = [] { willSet { RelayOrchestrator.shared?.objectWillChange.send() } }
  weak var browser: BrowserModel?
  #if DEBUG
  /// Checks stand a task at Allow all, or below it, without a run behind it.
  var allowsAllOverride: Bool?
  #endif

  /// A person step's card, shown as an approval card in the task's chat.
  struct Step {
    let card: UUID
    let key: PersonStep.Key
    let task: String
  }
  private(set) var steps: [Step] = []
  /// Fills from saved data whose receipt's Undo can still clear them, by undo entry.
  var filledFromSaved: [String: Card] = [:]
  /// Keys the person said no to, per task: asking again answers so (R16).
  private var declined: [String: Set<PersonStep.Key>] = [:]

  /// Opens the card, or joins the open one for the same field. A card the person declined on this
  /// page answers so when it is raised again.
  func raise(_ card: Card) -> PersonStep.Reply {
    if wasDeclined(Self.declineKey(card), task: card.task) { return .askedBefore(declined: true) }
    if open.contains(where: { $0.task == card.task && $0.origin == card.origin && $0.tab === card.tab && $0.ref == card.ref && $0.document == card.document }) {
      return .askedBefore(declined: false)
    }
    open.append(card)
    return .asked
  }

  /// The person's submit. A refusal line when the entry is not one; nil once it goes to the page.
  func submit(_ id: UUID, _ entry: SecretEntry) -> String? {
    guard let card = open.first(where: { $0.id == id }) else { return nil }
    guard let values = SecureCard.values(card.kind, parts: card.parts, entry) else { return SecureCard.refusal(card.kind) }
    open.removeAll { $0.id == id }
    Task {
      let result = await browser?.secureFill(card, values) ?? .pageChanged
      if result == .filled {
        for value in values.values { FilledValues.shared.add(value, task: card.task) }
      }
      await browser?.secureCardAnswered(card, result)
    }
    return nil
  }

  func decline(_ id: UUID) {
    guard let card = open.first(where: { $0.id == id }) else { return }
    open.removeAll { $0.id == id }
    declined[card.task, default: []].insert(Self.declineKey(card))
    Task { await browser?.secureCardAnswered(card, .declined) }
  }

  private static func declineKey(_ card: Card) -> PersonStep.Key {
    .field(host: card.host, field: "\(card.kind.rawValue) \(card.document) \(card.pageVersion)")
  }

  func stepOpen(_ key: PersonStep.Key, task: String) -> Bool { steps.contains { $0.key == key && $0.task == task } }
  func wasDeclined(_ key: PersonStep.Key, task: String) -> Bool { declined[task]?.contains(key) == true }
  func opened(_ step: Step) { steps.append(step) }
  func closed(card: UUID, declined no: Bool) {
    guard let step = steps.first(where: { $0.card == card }) else { return }
    steps.removeAll { $0.card == card }
    if no { declined[step.task, default: []].insert(step.key) }
  }

  /// A deleted chat, or a finished task with no chat: its shell's answers and cards go.
  func threadClosed(_ thread: String) {
    hostAnswers[thread] = nil
    hosts.removeAll { $0.ask.thread == thread }
  }

  /// A task shell's call to a payment service (PayGuard), refused at once while the card waits
  /// for the person. Allow opens the host for the rest of the thread; either answer sends the
  /// thread one follow-up turn.
  struct HostCard: Identifiable {
    let id = UUID()
    let ask: PayGuard.Ask
    var title: String { PayGuard.title(ask) }
    var lines: [String] { PayGuard.lines(ask) }
  }
  @Published private(set) var hosts: [HostCard] = []
  /// Thread -> host -> allowed, until the thread closes (PAYGUARD-REVIEW M1).
  private var hostAnswers: [String: [String: Bool]] = [:]

  /// Never waits: Allow all passes, the thread's answer stands, otherwise the call joins the open
  /// card for its host or raises one and is refused for now.
  func askHost(_ ask: PayGuard.Ask) -> PayGuard.Answer {
    if browser?.allowsAll(task: ask.task) == true { return .allowed }
    if let allowed = hostAnswers[ask.thread]?[ask.host] { return allowed ? .allowed : .declined }
    if !hosts.contains(where: { $0.ask.thread == ask.thread && $0.ask.host == ask.host }) { hosts.append(HostCard(ask: ask)) }
    return .open
  }

  /// The open host card a task raised, whose turn then ends waiting on the person.
  func openHost(task: String) -> String? { hosts.first { $0.ask.task == task }?.ask.host }

  /// The person's Allow or Decline: it stands for the thread, and one follow-up turn tells it.
  func answerHost(_ id: UUID, allowed: Bool) {
    guard let card = hosts.first(where: { $0.id == id }) else { return }
    hosts.removeAll { $0.id == id }
    hostAnswers[card.ask.thread, default: [:]][card.ask.host] = allowed
    Task { await browser?.hostCardAnsweredLate(card, allowed: allowed) }
  }

  /// R4, R20: a card waits on the person for this task, so its run is waiting, not silent.
  func holdsCard(task: String) -> Bool { open.contains { $0.task == task } || steps.contains { $0.task == task } }

  /// R26: a secure card nobody answered for a day closes, and its task hears so. Person step
  /// cards close in the chat's own day sweep (`RelayOrchestrator.personCard`).
  func expire(now: Date = Date()) {
    for card in open where now.timeIntervalSince(card.opened) >= PersonStep.life {
      open.removeAll { $0.id == card.id }
      Task { await browser?.cardExpired(card.task, title: card.title) }
    }
  }

  /// The task's end forgets what it filled and widened. Its open cards stay for the person.
  func taskEnded(_ task: String) {
    FilledValues.shared.forget(task: task)
    PathGrants.shared.forget(task: task)
    declined[task] = nil
    threadClosed(Engines.taskThread(task).id)
  }
}

extension SecureCards: PayCards {
  nonisolated func ask(_ ask: PayGuard.Ask) async -> PayGuard.Answer { await askHost(ask) }
}

extension BrowserModel {
  /// Whether task `id` stands at Allow all, read at the step (`standing(task:else:)`): the chosen
  /// level is Allow all, or the task is one Serein delegated. Its shell then reaches payment hosts
  /// with no card and reads secret files (owner, 2026-11-18). A plain chat turn at Auto or Manual
  /// keeps both guarded.
  func allowsAll(task id: String) -> Bool {
    #if DEBUG
    if let forced = secureCards.allowsAllOverride { return forced }
    #endif
    let relay = relayTask(id, tasks[id])
    return standing(task: id, else: RelayOrchestrator.standing(relay, present: !isUnattended(task: id))).level == .proactive
  }

  /// A host card answered: one follow-up turn on the chat thread. A task with no chat thread
  /// (an outside app's) has no turn to send; its next call reads the answer, and the notice says so.
  func hostCardAnsweredLate(_ card: SecureCards.HostCard, allowed: Bool) async {
    guard card.ask.thread != Engines.taskThread(card.ask.task).id, let agent = intelligenceAgent else {
      notice = "\(allowed ? "Allowed" : "Declined") \(card.ask.host) for that task. It applies on the task's next try."
      return
    }
    let text = PayGuard.followUp(host: card.ask.host, allowed: allowed)
    if let refused = await agent.flow.replyToTask(card.ask.thread, text: text, interrupt: false) { notice = refused }
  }

  /// A check's own loopback fixture counts as a secure page in a debug build only.
  private static var secureLoopback: Bool {
    #if DEBUG
    true
    #else
    false
    #endif
  }

  /// `secure_card`, and `type` on a field the read marks secure. A value the person saved for this
  /// exact origin fills with no card (`FillGuard`); with nothing saved, or a rule of theirs that
  /// asks, a card in the task's chat. The model's arguments name the field only.
  func secureCard(_ tab: BrowserTab, task id: String, ref: String) async throws -> [String: Any] {
    if !tab.address.isEmpty { try await authorizeSite(tab.address, taskID: id) }
    if let check = await tab.verificationCheck(["ref": ref]) { throw check }
    let frame = try tab.actionFrame(["ref": ref])
    guard let probe = await secureProbe(tab, ref: ref, frame: frame) else {
      throw SereinError.invalid(ActionAdmission.pageChanged)
    }
    let kind: SecureCard.Kind
    switch SecureCard.admit(probe.field, loopback: Self.secureLoopback) {
    case .card(let admitted): kind = admitted
    case .refused(SecureCard.captcha): throw VerificationCheck(host: tab.verificationHost)
    case .refused(let why): throw SereinError.invalid(why)
    }
    var amount: String?
    if kind == .card {
      let live = await tab.elementFacts(name: "type", arguments: ["ref": ref])
      let read = ActionAdmission.readback(effect: .pay, label: live.label, reading: live.reading).amount
      amount = read.isEmpty ? nil : read
    }
    let host = URL(string: probe.field.topOrigin)?.host ?? tab.verificationHost
    let card = SecureCards.Card(
      kind: kind, parts: probe.parts, host: host, amount: amount, task: id, thread: threadID(forTask: id), tab: tab,
      ref: ref, document: probe.document, origin: probe.field.frameOrigin, pageVersion: tab.pageVersion)
    guard let target = FillGuard.target(probe.field, loopback: Self.secureLoopback) else {
      throw SereinError.invalid(ActionAdmission.pageChanged)
    }
    switch FillGuard.fill(target, saved: savedItems(), person: await personWords(task: id)) {
    case .refused(let why): throw SereinError.invalid(why)
    case .fill(let item):
      if let filled = await fillFromSaved(card, item, parts: probe.parts) { return filled }
    case .ask: break
    }
    return PersonStep.fields(secureCards.raise(card))
  }

  /// Whether the read marks this field secure: `type` there raises the card instead.
  func isSecureField(_ tab: BrowserTab, ref: String) async -> Bool {
    guard ref.hasPrefix("e"), let frame = try? tab.actionFrame(["ref": ref]),
      let probe = await secureProbe(tab, ref: ref, frame: frame), let kind = probe.field.kind
    else { return false }
    return SecureCard.Kind(rawValue: kind) != nil
  }

  struct SecureProbe {
    var field: SecureCard.Field
    var document: String
    var parts: [SecureCard.Part]
  }

  /// The field as the live page shows it. The origins and the certificate come from WebKit, not the page.
  func secureProbe(_ tab: BrowserTab, ref: String, frame: WKFrameInfo?) async -> SecureProbe? {
    guard let raw = try? await tab.script("globalThis.__serein.secureField(\(jsonString(ref)))", frame: frame)
      as? [String: Any], raw["connected"] as? Bool == true, let url = tab.web.url
    else { return nil }
    let top = Self.origin(scheme: url.scheme, host: url.host, port: url.port)
    let frameOrigin = frame.map {
      Self.origin(scheme: $0.securityOrigin.protocol, host: $0.securityOrigin.host, port: $0.securityOrigin.port)
    } ?? top
    let trusted = url.scheme?.lowercased() == "https" && tab.web.serverTrust != nil && tab.web.hasOnlySecureContent
      && !PasswordCapture.certificateBypassed(tab) && frameOrigin.hasPrefix("https://")
    let field = SecureCard.Field(
      kind: raw["kind"] as? String, autocomplete: raw["autocomplete"] as? String ?? "", frameOrigin: frameOrigin,
      topOrigin: top, formOrigin: raw["form"] as? String, trusted: trusted)
    let parts = (raw["parts"] as? [String] ?? []).compactMap(SecureCard.Part.init(rawValue:))
    return SecureProbe(field: field, document: raw["document"] as? String ?? "", parts: parts)
  }

  /// scheme://host[:port] as a page's `location.origin` reads it.
  static func origin(scheme: String?, host: String?, port: Int?) -> String {
    let scheme = (scheme ?? "").lowercased()
    let standard = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
    let shown = port.map { $0 == 0 || standard ? "" : ":\($0)" } ?? ""
    return scheme + "://" + (host ?? "").lowercased() + shown
  }

  /// The person's values into the field the card was raised for, after the page is read again.
  /// The values go as script arguments, never inside script text.
  func secureFill(_ card: SecureCards.Card, _ values: [String: String]) async -> SecureCard.Result {
    if let mac = card.mac { return MacControl.secureFill(mac, kind: card.kind, values) }
    if let box = card.box { return await ComputerHost.shared.secureFill(box, values) }
    guard let tab = card.tab, !tab.sleeping, tab.pageVersion == card.pageVersion,
      let frame = try? tab.actionFrame(["ref": card.ref]),
      let probe = await secureProbe(tab, ref: card.ref, frame: frame),
      probe.document == card.document, probe.field.frameOrigin == card.origin,
      SecureCard.admit(probe.field, loopback: Self.secureLoopback) == .card(card.kind),
      tab.pageVersion == card.pageVersion
    else { return .pageChanged }
    let done = try? await tab.web.callAsyncJavaScript(
      "return globalThis.__serein.fillSecure(ref, doc, origin, kind, values)",
      arguments: ["ref": card.ref, "doc": card.document, "origin": card.origin, "kind": card.kind.rawValue, "values": values],
      in: frame, contentWorld: BrowserTab.world)
    return done as? String == "ok" ? .filled : .pageChanged
  }

  /// The person answered a secure card. A live task with a chat hears it as a steer or one
  /// follow-up turn, and a fill covers the one press after it (SecureCard.Pass); any other goes
  /// to the parked path, whose fallback gives the tab to the person (R20).
  func secureCardAnswered(_ card: SecureCards.Card, _ result: SecureCard.Result) async {
    guard tasks[card.task] != nil, let thread = card.thread ?? threadID(forTask: card.task), let agent = intelligenceAgent
    else { return await parkedSecureCardAnswered(card, result) }
    if result == .filled, let tab = card.tab {
      tasks[card.task]?.securePasses[tab.id] = SecureCard.Pass(
        tab: tab.id, pageVersion: tab.pageVersion, kind: card.kind, amount: card.amount,
        field: card.kind == .card ? nil : card.ref)
    }
    let text = SecureCard.followUp(result, host: card.host, tab: card.tab?.id)
    if let refused = await agent.flow.deliver(thread, text: text) { notice = refused }
  }

  /// R26: the task hears that a card closed unanswered.
  func cardExpired(_ task: String, title: String) async {
    guard tasks[task] != nil, let thread = threadID(forTask: task), let agent = intelligenceAgent else { return }
    if let refused = await agent.flow.deliver(thread, text: PersonStep.expired("the card \"\(title)\"")) { notice = refused }
  }

  /// `person_step`: a step only the person can take, as a card in the task's chat. It answers at
  /// once and the task goes on; the answer reaches it later (`ComposerFlow.deliver`). Every key is
  /// read from the page or the call. At Allow all a pay to a site the person named presses now,
  /// with a receipt and no card (`FillGuard.pay`); only a rule of theirs that asks raises one.
  func personStep(_ a: [String: Any], task id: String) async throws -> [String: Any] {
    guard let task = tasks[id], let relay = RelayOrchestrator.shared else {
      throw SereinError.invalid("The task ended during this operation")
    }
    let key: PersonStep.Key
    var press: (pass: SecureCard.Pass, ref: String)?
    switch a["kind"] as? String {
    case "pay", "check":
      let tabID = a["tab"] as? String ?? task.lastTab
      guard let tab = task.tabs.first(where: { $0.id == tabID }) else { throw SereinError.invalid("Missing tab") }
      guard a["kind"] as? String == "pay" else {
        key = .page(host: tab.verificationHost)
        break
      }
      guard let ref = a["ref"] as? String else { throw SereinError.invalid("Missing ref") }
      let live = await tab.elementFacts(name: "click", arguments: ["ref": ref])
      let read = ActionAdmission.readback(effect: .pay, label: live.label, reading: live.reading)
      guard !read.amount.isEmpty, !read.target.isEmpty else { throw SereinError.invalid(PersonStep.unreadPay) }
      // One yes covers this one press: nothing is kept for a later press or run.
      let pay = PersonStep.PayKey(
        host: tab.verificationHost, merchant: tab.verificationHost, item: read.target, amount: read.amount)
      let pass = SecureCard.Pass(tab: tab.id, pageVersion: tab.pageVersion, kind: .card, amount: read.amount, ref: ref)
      // Below Allow all every pay asks, as before.
      let payee = tab.web.url.map { Self.origin(scheme: $0.scheme, host: $0.host, port: $0.port) } ?? ""
      let verdict = allowsAll(task: id) ? FillGuard.pay(payee: payee, person: await personWords(task: id)) : .ask
      switch verdict {
      case .refused(let why): throw SereinError.invalid(why)
      case .pay:
        let page = try await pressPay(pass, ref: ref, task: id)
        if let thread = threadID(forTask: id) {
          relay.deliver(receipt: FillGuard.paid(amount: read.amount, host: tab.verificationHost), into: thread)
        }
        var answer = page as? [String: Any] ?? [:]
        answer.merge(FillGuard.paidFields(amount: read.amount, host: tab.verificationHost)) { $1 }
        return answer
      case .ask: break
      }
      key = .pay(pay)
      press = (pass, ref)
    case "confirm":
      guard let tool = a["tool"] as? String, !tool.isEmpty else { throw SereinError.invalid("Missing tool") }
      let path = (a["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      let hash = PersonStep.argsHash(a["arguments"] as? [String: Any] ?? [:])
      if relay.takesConfirm(tool: tool, argsHash: hash, path: path, task: id) { return PersonStep.fields(.done) }
      key = .step(tool: tool, argsHash: hash, path: path)
    default:
      throw SereinError.invalid("person_step takes kind pay, check or confirm.")
    }
    return raiseStep(key, task: id, relay: relay, press: press)
  }

  /// Opens a person step's card once per task and key. Never waits: the call answers at once.
  func raiseStep(
    _ key: PersonStep.Key, task id: String, relay: RelayOrchestrator, press: (pass: SecureCard.Pass, ref: String)? = nil
  ) -> [String: Any] {
    if secureCards.wasDeclined(key, task: id) { return PersonStep.fields(.askedBefore(declined: true)) }
    if secureCards.stepOpen(key, task: id) { return PersonStep.fields(.askedBefore(declined: false)) }
    let card = UUID()
    let words = PersonStep.card(key)
    let held = press
    secureCards.opened(.init(card: card, key: key, task: id))
    relay.personCard(card, words.title, words.detail, button: words.button, thread: threadID(forTask: id)) {
      [weak self] yes, expired in
      Task { await self?.personStepAnswered(card, key, task: id, yes: yes, expired: expired, press: held) }
    }
    return PersonStep.fields(.asked)
  }

  /// The person's answer on a person step's card. Only this presses pay or writes a confirm grant
  /// (R2, R16): no tool argument reaches it.
  func personStepAnswered(_ card: UUID, _ key: PersonStep.Key, task id: String, yes: Bool, expired: Bool,
                          press: (pass: SecureCard.Pass, ref: String)?) async {
    secureCards.closed(card: card, declined: !yes && !expired)
    var text = expired ? PersonStep.expired("the card \"\(PersonStep.card(key).title)\"") : PersonStep.answered(key, yes: yes)
    if yes, tasks[id] != nil {
      switch key {
      case .pay(let pay):
        if let press, (try? await pressPay(press.pass, ref: press.ref, task: id)) == nil {
          text = PersonStep.payMissed(pay)
        }
      case .step(let tool, let hash, let path):
        RelayOrchestrator.shared?.grantConfirm(tool: tool, argsHash: hash, path: path, task: id)
        if let path { PathGrants.shared.widen(task: id, path: path) }
      default: break
      }
    }
    guard tasks[id] != nil, let thread = threadID(forTask: id), let agent = intelligenceAgent else { return }
    if let refused = await agent.flow.deliver(thread, text: text) { notice = refused }
  }

  /// The pay press the person said yes to: a click covered by a pass for that amount on that page
  /// (SecureCard.Pass), so the gate takes it as their yes.
  private func pressPay(_ pass: SecureCard.Pass, ref: String, task id: String) async throws -> Any {
    guard let tab = tasks[id]?.tabs.first(where: { $0.id == pass.tab }) else {
      throw SereinError.invalid(ActionAdmission.pageChanged)
    }
    tasks[id]?.securePasses[pass.tab] = pass
    _ = try await runWebAction(
      name: "click", arguments: ["tab": tab.id, "ref": ref], tab: tab, taskID: id,
      allowed: { [weak self] in self?.tasks[id] != nil })
    return try await pageAfter(tab, task: id)
  }

  /// A parked card was answered after its task's turn ended. The kept tab goes to the chat's next
  /// run, which takes it before its agent starts (`adoptHandBack`), with one follow-up turn. When
  /// no turn can start now the tab becomes the person's, page intact.
  func parkedSecureCardAnswered(_ card: SecureCards.Card, _ result: SecureCard.Result) async {
    if card.mac != nil || card.box != nil { return await parkedMacCardAnswered(card, result) }
    guard let tab = card.tab, let entry = agentTabs.entry(tab.id) else { return }
    guard tasks[entry.taskID] == nil, let thread = card.thread, let agent = intelligenceAgent,
      agent.hub.run(for: thread) == nil, handBacks[thread] == nil, agent.flow.queue.items(for: thread).isEmpty,
      let info = agentTabs.release(tab.id)
    else {
      takeOver(tab)
      return
    }
    tab.agentMark = TabAgentMark(
      agent: info.agent, threadID: thread, taskID: entry.taskID, title: info.title, summary: nil, status: nil,
      startedAt: info.startedAt, endedAt: info.endedAt ?? Date(), steps: info.steps.filter { $0.tool != "take_over" })
    tab.owner = nil
    tabs.append(tab)
    handBacks[thread] = tab
    let refused = await agent.flow.replyToTask(
      thread, text: SecureCard.followUp(result, host: card.host, tab: tab.id), interrupt: false)
    guard refused != nil || agent.hub.run(for: thread) == nil, handBacks[thread] === tab else { return }
    handBacks[thread] = nil
    if let refused { notice = refused }
    attach(tab)
    PasswordCapture.adopt(tab)
    SiteFeatureBridge.adopt(tab)
    tab.takenFrom = "Taken over from \(info.agent)"
  }
}
