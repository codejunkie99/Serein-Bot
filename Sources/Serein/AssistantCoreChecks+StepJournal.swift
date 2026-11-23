#if DEBUG
import Foundation
import SereinCore

/// V3, the step journal (`StepJournal`): every order of calls, results, quits and sends-again,
/// on the real store, against a model that knows only the three promises.
/// How to read a failure: .claude/skills/proactive-safety/SKILL.md.
extension AssistantCoreChecks {
  static func stepJournal(_ check: Check) throws {
    let wide = JournalWalk.run(events: JournalWalk.events(keys: 3, ends: JournalWalk.End.allCases), depth: 3)
    let deep = JournalWalk.run(events: JournalWalk.events(keys: 2, ends: JournalWalk.End.allCases), depth: 4)
    let long = JournalWalk.run(
      events: JournalWalk.events(keys: 1, ends: [.done, .unknown, .quit]).filter(\.runsByItself), depth: 6)
    let walked = wide.walked + deep.walked + long.walked
    let faults = wide.faults.merging(deep.faults) { first, _ in first }.merging(long.faults) { first, _ in first }
    func held(_ fault: JournalWalk.Fault, _ label: String) throws {
      try check(faults[fault] == nil, faults[fault].map { label + ". Broken by: " + $0 } ?? label + ", in \(walked) orders of events")
    }
    try held(.ranTwice, "A changing step with a recorded result never runs again")
    try held(.silent, "A changing step whose outcome is unknown never runs again without asking")
    try held(.unrecorded, "No changing step runs before it is written down")
    try held(.resend, "A turn goes again by itself only when no step's outcome is unknown")
    try held(.replay, "A step answered from the journal is one this request finished in an earlier send")
    try held(.asksForNothing, "The journal adds an ask only for a step whose outcome is unknown")

    // The walk itself: a journal that forgets results, and one that forgets unknown outcomes, are reported.
    let forgetful = JournalWalk.run(
      rule: { key, tool, occurrence, request in
        let before = StepJournal.before(key: key, tool: tool, occurrence: occurrence, in: request)
        if case .replay = before { return .run }
        return before
      }, events: JournalWalk.events(keys: 1, ends: [.done]), depth: 3)
    try check(forgetful.faults[.ranTwice] != nil, "The walk reports a journal that runs a finished step again")
    let careless = JournalWalk.run(
      rule: { key, tool, occurrence, request in
        let before = StepJournal.before(key: key, tool: tool, occurrence: occurrence, in: request)
        if case .asks = before { return .run }
        return before
      }, events: JournalWalk.events(keys: 1, ends: [.unknown, .quit]), depth: 3)
    try check(careless.faults[.silent] != nil, "The walk reports a journal that runs an unknown step again without asking")

    try journalOnDisk(check)
    try journalAtTheDoor(check)
    try modelMoves(check)
  }

  private static func journalOnDisk(_ check: Check) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("serein-journal-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent(StepJournalStore.path)
    let effect = JournalWalk.effect
    let arguments: [String: Any] = ["to": "a@example.com", "body": "hello"]

    // Serein quits between the line and the result.
    var store = StepJournalStore(file: file)
    store.nextTurn(in: "t", is: "request-1", words: StepJournal.words("send it"))
    store.turnStarts("t")
    var call = store.step(thread: "t", tool: "mail_send", arguments: arguments)
    try check(call.before == .run && call.live.decided(effect, .auto) == .auto && call.live.started != nil,
              "A changing step that runs by itself is written down first")
    store = StepJournalStore(file: file)
    var waits = false
    if case .waits = store.resend(request: "request-1") { waits = true }
    try check(store.request("t")?.entries.map(\.outcome) == [.open] && waits,
              "A step that was started when Serein quit is still in the journal, and its turn does not go again by itself")
    try check(store.current("t", words: StepJournal.words("send it")) == "request-1"
                && store.current("t", words: StepJournal.words("send it now")) == nil,
              "Try again finds the request by what was asked, and only then")
    store.nextTurn(in: "t", is: "request-1")
    store.turnStarts("t")
    call = store.step(thread: "t", tool: "mail_send", arguments: arguments)
    var asks = false
    if case .asks = call.before { asks = true }
    try check(asks && call.live.decided(effect, .auto) == .ask && call.live.started == nil,
              "Sent again after the quit, that step asks whatever the level")
    try check(call.live.allowed() && call.live.started != nil, "The person's yes writes it down and lets it run")
    store.finish(call.live, thread: "t", result: "Sent to a@example.com")

    // Its result is read back, not run again, by the next send of the same request.
    store = StepJournalStore(file: file)
    store.nextTurn(in: "t", is: "request-1")
    store.turnStarts("t")
    call = store.step(thread: "t", tool: "mail_send", arguments: arguments)
    var replayed: String?
    if case .replay(let entry) = call.before, case .done(let result) = entry.outcome { replayed = result }
    try check(replayed == "Sent to a@example.com", "A finished step's result is read from the journal after a relaunch")
    let other = store.step(thread: "t", tool: "mail_send", arguments: ["to": "b@example.com", "body": "hello"])
    try check(other.before == .run, "A step with other arguments is another step")

    // A turn in between is its own request, and the first one is still known by its id.
    store.turnStarts("t")
    try check(store.request("t")?.entries.isEmpty == true && store.step(thread: "t", tool: "mail_send", arguments: arguments).before == .run,
              "A new message is a new request: the same step runs for it")
    store.nextTurn(in: "t", is: "request-1")
    store.turnStarts("t")
    var again = false
    if case .replay = store.step(thread: "t", tool: "mail_send", arguments: arguments).before { again = true }
    try check(again && store.request("t")?.attempt == 4, "A request sent again after another turn still reads its own steps")
    store.nextTurn(in: "u", is: "request-1")
    store.turnStarts("u")
    try check(store.request("u")?.id != "request-1" || store.request("u")?.entries.isEmpty == true,
              "A request's steps are never read in another chat")

    // A line cut short by a quit is a step that was never written down.
    let whole = try Data(contentsOf: file)
    var torn = whole
    torn.append(Data(#"{"kind":"started","thread":"t","requ"#.utf8))
    try torn.write(to: file)
    let before = StepJournalStore(file: file).request("t")
    try check(before != nil && before == store.request("t"), "A torn last line changes nothing")

    // The file as it is rewritten at launch adds up to the same journal.
    var book = StepJournal.Book()
    let decoder = JSONDecoder()
    for row in whole.split(separator: 10) { book.apply(try decoder.decode(StepJournal.Line.self, from: row)) }
    var folded = StepJournal.Book()
    for line in book.lines() { folded.apply(line) }
    try check(folded == book && book.requests.count >= 3, "The rewritten file adds up to the same journal")

    // Old requests go.
    let later = Date().addingTimeInterval(StepJournalStore.keeps + 60)
    try check(StepJournalStore(file: file, now: { later }).request("t") == nil, "A request nothing touched for two weeks is forgotten")

    // A journal that cannot be saved stops the step.
    let blocker = folder.appendingPathComponent("blocker")
    try Data().write(to: blocker)
    let unsaved = StepJournalStore(file: blocker.appendingPathComponent("steps.jsonl"))
    unsaved.turnStarts("t")
    let stopped = unsaved.step(thread: "t", tool: "mail_send", arguments: arguments).live
    let asked = unsaved.step(thread: "t", tool: "mail_send", arguments: arguments).live
    _ = asked.decided(effect, .ask)
    try check(stopped.decided(effect, .auto) == .refuse && !asked.allowed() && stopped.started == nil && asked.started == nil,
              "A step that cannot be written down does not run, by itself or on a yes")
    try check(stopped.decided(.read, .auto) == .auto, "A step that changes nothing needs no line")

    // What the journal keeps of a result.
    let long = String(repeating: "a", count: StepJournal.resultLimit + 50)
    let kept = BrowserModel.journalText(["result": long, "verification": "Read back"])
    try check(kept.contains(String(repeating: "a", count: StepJournal.resultLimit)) && !kept.contains(long),
              "A long result is cut short in the journal, not left out")
    try check(!BrowserModel.journalText(["type": "image", "data": long, "mimeType": "image/png"]).contains("aaa"),
              "A picture is left out of the journal")
  }

  private static func journalAtTheDoor(_ check: Check) throws {
    typealias Door = ApprovalDoor
    let effect = JournalWalk.effect
    let store = StepJournalStore(file: nil)
    store.turnStarts("t")
    let plain = store.step(thread: "t", tool: "mail_send", arguments: [:]).live
    let same = StepJournal.$live.withValue(plain) { DoorTable.differences() }
    try check(same.found.isEmpty, same.found.isEmpty
      ? "Inside a tool call the door answers by its table, for \(same.walked) questions"
      : "The journal changed an answer. \(same.found.first ?? "")")

    // A step with an unknown outcome behind it: the first changing step is told to check, once;
    // the same call again runs, and a read never waits on it.
    let lost = store.step(thread: "t", tool: "mail_send", arguments: ["n": 1]).live
    _ = lost.decided(effect, .auto)
    lost.cannotTell()
    store.finish(lost, thread: "t", result: nil)
    store.sendAgain("t")
    store.turnStarts("t")
    let stuck = store.step(thread: "t", tool: "mail_send", arguments: ["n": 1]).live
    let task = Door.Standing.proactiveTask(present: true)
    let answers = StepJournal.$live.withValue(stuck) {
      [Door.Step.effect(.read), .effect(.send), .effect(.send), .effect(.pay)].map {
        Door.answer(.init($0, task), facts: DoorTable.facts())
      }
    }
    try check(
      stuck.stuck != nil
        && answers == [
          .run, .checkFirst("Serein cannot tell whether mail_send already ran. Check, then call it again if it did not."),
          .run, .blocked(.pay(ref: "")),
        ],
      "After an unknown outcome the first changing step is told to check once, then runs; a read runs and the floor holds")
  }

  /// V3's third promise, on the real `ModelFallback.next`: moving from model to model ends, and
  /// never comes back to a model already tried in the turn.
  private static func modelMoves(_ check: Check) throws {
    typealias Next = (ModelRoute, [ModelRoute]) -> ModelRoute?
    let names = ["A", "B", "C", "D"]
    func route(_ name: String, _ flags: Int) -> ModelRoute {
      ModelRoute(provider: "p", model: name, costClass: .free, caps: [.tools], installed: flags & 1 == 1, reason: flags & 2 == 2 ? nil : "off")
    }
    var orders: [[String]] = [[]]
    var grown: [[String]] = [[]]
    for _ in names {
      grown = grown.flatMap { order in names.filter { !order.contains($0) }.map { order + [$0] } }
      orders += grown
    }
    func fault(_ next: Next) -> (walked: Int, first: String?) {
      var walked = 0
      for order in orders {
        for bits in 0..<(1 << (2 * order.count)) {
          let list: [ModelRoute] = order.enumerated().map { route($1, (bits >> (2 * $0)) & 3) }
          for start in names {
            walked += 1
            var current: ModelRoute = list.first { $0.model == start } ?? route(start, 3)
            var tried: [String] = [current.id]
            while let to = next(current, list) {
              if tried.contains(to.id) || tried.count > list.count || !to.installed || !to.selectable {
                let shown: [String] = list.map { $0.model + ($0.installed && $0.selectable ? "" : " (off)") }
                return (walked, "list \(shown), from \(start), tried \(tried + [to.id])")
              }
              tried.append(to.id)
              current = to
            }
          }
        }
      }
      return (walked, nil)
    }
    let real = fault { ModelFallback.next(current: $0, list: $1)?.route }
    try check(real.first == nil, real.first.map { "Moving to a backup model came back to one already tried. " + $0 }
      ?? "Moving to a backup model ends and never tries one again, for \(real.walked) lists and starts")
    let wraps = fault { current, list in list.first { $0.id != current.id && $0.installed && $0.selectable } }
    try check(wraps.first != nil, "The check reports a backup rule that starts again from the top")
  }
}

/// Every order of events on one chat's journal. The model below is the promises written out; it
/// shares no code with `StepJournal.before`.
enum JournalWalk {
  static let thread = "t"
  static let effect: ApprovalGate.Effect = .send

  enum End: CaseIterable { case done, failed, unknown, quit }
  enum Fault: Hashable { case ranTwice, silent, unrecorded, resend, replay, asksForNothing }
  enum Event: CustomStringConvertible {
    /// A tool call. `auto`: the door would run it by itself. `yes`: the person's answer when a
    /// card shows. `end`: how the step ends when it runs.
    case call(key: Int, auto: Bool, yes: Bool, end: End)
    /// The turn is sent again: by itself (only when the journal lets it), or by the person.
    case again(byPerson: Bool)
    /// The person's next message.
    case fresh

    var runsByItself: Bool {
      if case .call(_, let auto, _, _) = self { return auto }
      return true
    }
    var description: String {
      switch self {
      case .call(let key, let auto, let yes, let end):
        return "step \(key) (\(auto ? "runs by itself" : "asks"), the person says \(yes ? "yes" : "no"), ends \(end))"
      case .again(let byPerson): return byPerson ? "the person sends it again" : "it goes again by itself"
      case .fresh: return "a new message"
      }
    }
  }

  /// Steps 0 and 1 are one tool with different arguments; step 2 is another tool.
  static func tool(_ key: Int) -> String { key == 2 ? "pay_bill" : "mail_send" }

  static func events(keys: Int, ends: [End]) -> [Event] {
    var out: [Event] = [.again(byPerson: false), .again(byPerson: true), .fresh]
    for key in 0..<keys {
      out.append(.call(key: key, auto: false, yes: false, end: .done))
      for end in ends {
        out.append(.call(key: key, auto: true, yes: true, end: end))
        out.append(.call(key: key, auto: true, yes: false, end: end))
        out.append(.call(key: key, auto: false, yes: true, end: end))
      }
    }
    return out
  }

  struct Model {
    enum State { case open, done, failed, unknown }
    struct Step {
      var id: String
      var key: Int
      var attempt: Int
      var state: State
      var settled = false
    }
    var attempt = 1
    var steps: [Step] = []
    var calls: [Int: Int] = [:]

    /// Steps nobody knows the outcome of: no result or "cannot tell", not answered for by the
    /// person, and not finished since by the same step.
    var stuck: [Step] {
      steps.indices.filter { index in
        let step = steps[index]
        return (step.state == .open || step.state == .unknown) && !step.settled
          && !steps[(index + 1)...].contains { $0.key == step.key && $0.state == .done }
      }.map { steps[$0] }
    }
  }

  struct Result {
    var walked = 0
    var faults: [Fault: String] = [:]
  }

  static func run(rule: @escaping StepJournalStore.Rule = StepJournal.before, events: [Event], depth: Int) -> Result {
    var result = Result()
    let store = StepJournalStore(file: nil, rule: rule)
    store.turnStarts(thread)
    walk(store, Model(), [], depth, events, &result)
    return result
  }

  private static func walk(_ store: StepJournalStore, _ model: Model, _ trace: [Event], _ left: Int, _ events: [Event], _ result: inout Result) {
    guard left > 0 else { return }
    for event in events {
      let next = store.fork()
      var after = model
      let path = trace + [event]
      result.walked += 1
      for fault in apply(event, to: next, &after) where result.faults[fault] == nil {
        result.faults[fault] = path.map(\.description).joined(separator: "; ")
      }
      walk(next, after, path, left - 1, events, &result)
    }
  }

  private static func apply(_ event: Event, to store: StepJournalStore, _ model: inout Model) -> [Fault] {
    switch event {
    case .fresh:
      store.turnStarts(thread)
      model = Model()
      return []
    case .again(let byPerson):
      var waits = false
      if case .waits = store.resend(thread) { waits = true }
      let fault: [Fault] = waits == model.stuck.isEmpty ? [.resend] : []
      guard byPerson || !waits else { return fault }
      store.sendAgain(thread)
      store.turnStarts(thread)
      model.attempt += 1
      model.calls = [:]
      return fault
    case .call(let key, let auto, let yes, let end):
      let call = store.step(thread: thread, tool: tool(key), arguments: ["n": key])
      let nth: Int = model.calls[key, default: 0]
      model.calls[key] = nth + 1
      let finished = model.steps.filter { $0.key == key && $0.state == .done && $0.attempt < model.attempt }
      if case .replay(let entry) = call.before {
        return finished.contains { $0.id == entry.id } ? [] : [.replay]
      }
      // What the promises say about this call: it must not run by itself while one of these stands.
      let unknown = model.stuck.contains { step in
        (step.attempt < model.attempt && tool(step.key) == tool(key))
          || (step.attempt == model.attempt && step.key == key && step.state == .unknown)
      }
      let answer = call.live.decided(effect, auto ? .auto : .ask)
      var faults: [Fault] = []
      if auto, !unknown, answer != .auto { faults.append(.asksForNothing) }
      let byItself = answer == .auto
      guard byItself || (answer == .ask && yes && call.live.allowed()) else { return faults }
      guard let id = call.live.started else { return faults + [.unrecorded] }
      if nth < finished.count { faults.append(.ranTwice) }
      if byItself, unknown { faults.append(.silent) }
      // A yes on a card that named an unknown step answers for that step.
      if !byItself, let old = call.live.stuck, let index = model.steps.firstIndex(where: { $0.id == old.id }) {
        model.steps[index].settled = true
      }
      var step = Model.Step(id: id, key: key, attempt: model.attempt, state: .open)
      switch end {
      case .done:
        store.finish(call.live, thread: thread, result: "ok")
        step.state = .done
      case .failed:
        store.finish(call.live, thread: thread, result: nil)
        step.state = .failed
      case .unknown:
        call.live.cannotTell()
        store.finish(call.live, thread: thread, result: nil)
        step.state = .unknown
      case .quit: break
      }
      model.steps.append(step)
      return faults
    }
  }
}
#endif
