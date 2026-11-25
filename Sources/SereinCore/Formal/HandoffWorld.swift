import Foundation

/// The hand-off lifecycle as `RelayTeams` (Sources/Serein/RelayTeams.swift) drives `HandoffLedger`:
/// the Chain and Report machines both explore it. Every ledger change goes through the shipped
/// reducers (`admit`, `chainRefusal`, `refusal`, `running`, `closable`, `expire`, `stop`,
/// `claimReport`). The shell glue around them (`closeHandoff`, `launch`, `finishHandoff`,
/// `deliverChainResults`, `deliverHandoffReports`, `sweepHandoffs`, and `postReport` in
/// RelayChannel.swift) lives in the app target, which
/// SereinCore cannot call, so it is mirrored here step for step. Each shell function is one step.
struct HandoffWorld: Encodable, Equatable {
  var ledger = HandoffLedger()
  /// Chats where a hand-off's run is live (`agent.hub.run(for:)`), sorted.
  var live: [String] = []
  /// Claims that returned the report, per hand-off: by `claimReport` here or inside `stop`.
  var claims: [String: Int] = [:]
  /// Turns that showed a report to the chat that asked: the parent's results turn or a wake turn.
  var readerTurns: [String: Int] = [:]
  /// Reader turns started for a report whose claim did not return it.
  var unclaimedReads = 0
  /// Wake turns per root hand-off (`deliverHandoffReports`).
  var wakes: [String: Int] = [:]
  /// Report posts saved in the chat the task started in, by `HandoffReport.postID`, in order:
  /// `channelPost` appends one only when its id is not there.
  var posted: [String] = []
  /// Report posts held in memory for a busy chat (`desk.facts`, `desk.posts`): a relaunch loses them.
  var held: [String] = []
  /// The chat a report goes to may be busy, so its post waits (the Report machine); else it lands at once.
  var heldPosts = false
  var crashes = 0
  /// A day went by once: `expire` ran, and later hand-offs are made a day on.
  var dayLater = false

  struct Config {
    /// The first is the one the person talks to; it sends every root.
    var assistants: [String]
    /// Most rows the ledger may get, refused sends included as attempts.
    var rows: Int
    var crashes: Int
    var expiry: Bool
    /// A replayed delivery may carry any hand-off id (TEAMS-V2 §4.8); only `claimReport` decides.
    var replays: Bool
    /// Runs may end and results come back; off explores sends and starts only, which reaches the caps sooner.
    var finishes: Bool
    /// Most hand-offs the person's assistant starts (roots).
    var roots: Int
    /// One channel (`GroupTurn`, RelayGroupTurn.swift): the person tags everyone once, and every
    /// run that ends done tags everyone else; a tagged root never wakes its sender.
    var mentions = false
  }

  /// What any step or property reads; times and result words are left out, since nothing reads them.
  var key: String {
    let rows = ledger.records.map { r in
      [r.id, r.from, r.to, r.state.rawValue, r.reported == true ? "R" : "", r.parentID ?? "", r.createdAt == Self.base ? "" : "L",
       r.mention == nil ? "" : "M"]
        .joined(separator: ",")
    }
    let counts = [claims, readerTurns, wakes].map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") }
    let daily = ledger.daily.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    let posts = [posted.sorted().joined(separator: ","), held.sorted().joined(separator: ",")]
    return (rows + [live.joined(separator: ","), daily] + counts + posts + ["\(unclaimedReads) \(crashes) \(dayLater)"]).joined(separator: ";")
  }

  static let base = Date(timeIntervalSince1970: 1_800_000_000)
  /// The chat an assistant's own turns run in: where a root is asked.
  static func thread(_ who: String) -> String { "main-" + who }
  /// A hand-off's seat chat, its own (`RelayTeams.seatThread`).
  static func seat(_ id: String) -> String { "seat-" + id }
  var now: Date { dayLater ? Self.base.addingTimeInterval(HandoffLedger.queueExpiry + 3_600) : Self.base }
  func record(_ id: String) -> AssistantHandoff? { ledger.records.first { $0.id == id } }

  // MARK: shell glue, each one step

  /// `claimReport` (RelayTeams): its post goes first, then the claim, saved before anything is delivered.
  mutating func claim(_ id: String) -> AssistantHandoff? {
    guard record(id)?.reported != true else { return nil }
    post(id, busy: heldPosts)
    guard let claimed = ledger.claimReport(id) else { return nil }
    claims[id, default: 0] += 1
    return claimed
  }

  /// `sendHandoff` after the `assistant_handoff` tool's checks: the chain rule for a part, then the
  /// sender's open limit and the reader's daily one. nil when refused.
  func sending(from sender: String, to target: String, parent: AssistantHandoff?, mention: AssistantHandoff.Mention? = nil) -> HandoffWorld? {
    if let parent, ledger.chainRefusal(parent: parent, fromName: sender, to: target, toName: target) != nil { return nil }
    guard ledger.refusal(from: sender, fromName: sender, to: target, toName: target, now: now) == nil else { return nil }
    var next = self
    let id = "h\(ledger.records.count + 1)"
    let record = AssistantHandoff(
      id: id, from: sender, to: target, task: "task", threadID: Self.seat(id),
      askedIn: parent?.threadID ?? Self.thread(sender), team: "", teamName: "All assistants", createdAt: now, parent: parent)
    var tagged = record
    tagged.mention = mention
    next.ledger.admit(tagged, now: now)
    return next
  }

  /// `startWaitingHandoffs` then `launch` for one waiting hand-off whose chat is free.
  func starting(_ id: String) -> HandoffWorld? {
    guard let r = record(id), r.state == .waiting, !live.contains(r.threadID), ledger.running(thread: r.threadID) == nil
    else { return nil }
    var next = self
    let at = now
    next.update(id) {
      $0.state = .running
      $0.startedAt = at
      $0.progressAt = at
    }
    next.goLive(r.threadID)
    return next
  }

  /// `finishHandoff`: the run in `thread` ended done or not.
  func finishing(_ thread: String, done: Bool) -> HandoffWorld {
    var next = self
    next.live.removeAll { $0 == thread }
    guard let r = next.ledger.running(thread: thread) else { return next }
    if done && !next.ledger.closable(r.id) { return next }
    next.close(r.id, done ? .done : .failed, report: true)
    return next
  }

  /// `closeHandoff`: ends one hand-off and, with it, what its target handed on. A part whose run is
  /// live has that run stopped, and its end (`finishHandoff`, stopped) closes it as failed.
  mutating func close(_ id: String, _ state: AssistantHandoff.State, report: Bool) {
    guard let r = record(id), r.isOpen else { return }
    let at = now
    update(id) {
      $0.state = state
      $0.finishedAt = at
      $0.result = "result"
    }
    post(id, busy: heldPosts)
    if !report { _ = claim(id) }
    for child in ledger.records where child.isOpen && child.parentID == id {
      if child.state == .running && live.contains(child.threadID) {
        live.removeAll { $0 == child.threadID }
        close(child.id, .failed, report: true)
      } else {
        close(child.id, .failed, report: false)
      }
    }
  }

  /// `deliverChainResults` for the parts of one hand-off that ended and are not yet told.
  func deliveringResults(of parentID: String) -> HandoffWorld? {
    let due = ledger.records.filter { $0.parentID == parentID && !$0.isOpen && $0.reported != true }
    guard !due.isEmpty, let parent = record(parentID) else { return nil }
    var next = self
    guard parent.state == .running else {
      // The hand-off they were part of has ended: nobody is left to take them.
      for result in due { _ = next.claim(result.id) }
      return next
    }
    guard !live.contains(parent.threadID) else { return nil }
    // `launch` with results: claimed, then the parent's next turn shows them all.
    let at = now
    next.update(parentID) { $0.progressAt = at }
    for result in due {
      if next.claim(result.id) == nil { next.unclaimedReads += 1 }
      next.readerTurns[result.id, default: 0] += 1
    }
    next.goLive(parent.threadID)
    return next
  }

  /// `deliverHandoffReports`' wake turn for a root that ended, keyed by its claim. Its post lands
  /// first (`postReport`, the asking chat is idle): one step, so a relaunch can fall between the
  /// post and the claim (`claimReport(landed:)`).
  func waking(_ id: String) -> HandoffWorld? {
    guard let r = record(id), r.parentID == nil, r.mention == nil, r.state == .done || r.state == .failed, r.reported != true
    else { return nil }
    guard posted.contains(HandoffReport.postID(id)) else {
      var next = self
      next.post(id, busy: false)
      return next
    }
    return wake(id)
  }

  /// `finishHandoff` for a run that ended done: `channelSay(addressed:)` tags everyone its reply
  /// names, never itself nor one its tag still holds, each through the chain rules, then it ends.
  func tagging(_ thread: String, _ assistants: [String], rows: Int) -> HandoffWorld {
    var next = self
    if let p = ledger.running(thread: thread) {
      for to in assistants where to != p.to && next.ledger.records.count < rows {
        guard !next.ledger.records.contains(where: { $0.isOpen && $0.mention != nil && $0.from == p.to && $0.to == to && $0.parentID == p.id })
        else { continue }
        if let n = next.sending(from: p.to, to: to, parent: p, mention: .byBot(post: "say-" + p.id)) { next = n }
      }
    }
    return next.finishing(thread, done: true)
  }

  /// `deliverHandoffReports` for a tagged root that ended: its post lands, then it is claimed with
  /// no wake turn (`claimReport(landed: true)`), since the reply in the chat is the answer.
  func quieting(_ id: String) -> HandoffWorld? {
    guard let r = record(id), r.mention != nil, r.parentID == nil, !r.isOpen, r.reported != true else { return nil }
    var next = self
    next.post(id, busy: heldPosts)
    if next.posted.contains(HandoffReport.postID(id)) { _ = next.claim(id) }
    return next == self ? nil : next
  }

  /// A replayed delivery of hand-off `id`: it holds only the id, so `claimReport` alone decides.
  func replaying(_ id: String) -> HandoffWorld { wake(id) }

  private func wake(_ id: String) -> HandoffWorld {
    var next = self
    guard next.record(id)?.reported != true else { return next }
    next.post(id, busy: false)
    guard next.claim(id) != nil else { return next }
    next.wakes[id, default: 0] += 1
    next.readerTurns[id, default: 0] += 1
    return next
  }

  /// `stopHandoffs`: the ledger first, then the runs of what held a chat.
  func stoppingEverything() -> HandoffWorld {
    var next = self
    let held = Set(ledger.records.filter { $0.state == .running }.map(\.id))
    let ended = next.ledger.stop(now: now)
    for r in ended {
      next.post(r.id, busy: heldPosts)
      if record(r.id)?.reported != true { next.claims[r.id, default: 0] += 1 }
      if held.contains(r.id) { next.live.removeAll { $0 == r.threadID } }
    }
    return next
  }

  /// Serein closed: every run is gone, the ledger on disk stays.
  func crashing() -> HandoffWorld {
    var next = self
    next.live = []
    next.held = []
    next.crashes += 1
    return next
  }

  /// `sweepHandoffs`, first at launch and every 15 seconds: a running hand-off with no run that
  /// waits on nothing was lost to a relaunch. A lost part is told to its parent; a lost root is only announced.
  func sweeping() -> HandoffWorld? {
    let lost = ledger.records.filter { $0.state == .running && !live.contains($0.threadID) && ledger.closable($0.id) }
    guard !lost.isEmpty else { return nil }
    var next = self
    for r in lost { next.close(r.id, .failed, report: r.parentID != nil) }
    return next
  }

  /// A day later: `expire` ends what waited in the queue too long.
  func expiring() -> HandoffWorld {
    var next = self
    next.dayLater = true
    _ = next.ledger.expire(now: next.now)
    return next
  }

  /// `postReport` into the chat the task started in, for a closed hand-off: saved now, or held
  /// while that chat is `busy`; a post whose id is saved or held changes nothing.
  mutating func post(_ id: String, busy: Bool) {
    guard record(id)?.isOpen == false else { return }
    let key = HandoffReport.postID(id)
    guard !posted.contains(key) else { return }
    if busy {
      if !held.contains(key) { held.append(key) }
      return
    }
    posted.append(key)
    held.removeAll { $0 == key }
  }

  /// The busy chat went idle: what waited for it lands (`flushHostPosts`, `land`).
  func landing() -> HandoffWorld {
    var next = self
    for key in held where !next.posted.contains(key) { next.posted.append(key) }
    next.held = []
    return next
  }

  private mutating func update(_ id: String, _ change: (inout AssistantHandoff) -> Void) {
    guard let i = ledger.records.firstIndex(where: { $0.id == id }) else { return }
    change(&ledger.records[i])
  }
  private mutating func goLive(_ thread: String) {
    live.append(thread)
    live.sort()
  }

  // MARK: the steps

  static func steps(_ c: Config) -> (HandoffWorld) -> [(label: String, next: HandoffWorld)] {
    { w in
      var out: [(label: String, next: HandoffWorld)] = []
      let lead = c.assistants[0]
      if w.ledger.records.count < c.rows {
        for to in c.assistants.dropFirst() where !c.mentions && w.ledger.records.filter({ $0.parentID == nil }).count < c.roots {
          if let n = w.sending(from: lead, to: to, parent: nil) { out.append(("\(lead) hands h\(w.ledger.records.count + 1) to \(to)", n)) }
        }
        // A part is sent from inside the run of the hand-off that holds the chat (in the mention
        // storm, only by tags, so the caps alone bound it).
        for p in w.ledger.records where !c.mentions && p.state == .running && w.live.contains(p.threadID) {
          for to in c.assistants where to != p.to {
            if let n = w.sending(from: p.to, to: to, parent: p) {
              out.append(("\(p.to) hands part h\(w.ledger.records.count + 1) of \(p.id) to \(to)", n))
            }
          }
        }
      }
      if c.finishes {
        for t in w.live {
          out.append(("the run in \(t) ends done", w.finishing(t, done: true)))
          out.append(("the run in \(t) ends failed", w.finishing(t, done: false)))
        }
        for p in w.ledger.records { if let n = w.deliveringResults(of: p.id) { out.append(("results of \(p.id)'s parts are delivered", n)) } }
        for r in w.ledger.records {
          guard let n = w.waking(r.id) else { continue }
          out.append((n.wakes == w.wakes ? "\(r.id)'s report is posted for its wake turn" : "wake turn for \(r.id)", n))
        }
        if !w.held.isEmpty { out.append(("the busy chat goes idle and held posts land", w.landing())) }
        if c.replays { for r in w.ledger.records { out.append(("replayed delivery of \(r.id)", w.replaying(r.id))) } }
      }
      if c.mentions {
        // One person message tags the first `roots` others; each tag is a root (`startGroupTurn`).
        if !w.ledger.records.contains(where: { $0.parentID == nil && $0.mention != nil }) {
          var n = w
          for to in c.assistants.dropFirst().prefix(c.roots) {
            if let m = n.sending(from: lead, to: to, parent: nil, mention: .byPerson(message: "m")) { n = m }
          }
          if n != w { out.append(("the person tags \(c.assistants.dropFirst().prefix(c.roots).joined(separator: " and "))", n)) }
        }
        if c.finishes { for t in w.live { out.append(("the run in \(t) ends done, tagging everyone", w.tagging(t, c.assistants, rows: c.rows))) } }
        for r in w.ledger.records { if let n = w.quieting(r.id) { out.append(("\(r.id)'s tagged reply lands with no wake", n)) } }
      }
      if w.ledger.records.contains(where: \.isOpen) { out.append(("Stop Everything", w.stoppingEverything())) }
      if w.crashes < c.crashes && !(w.live.isEmpty && w.held.isEmpty) { out.append(("Serein quits mid-run", w.crashing())) }
      if let n = w.sweeping() { out.append(("the sweep closes what a relaunch lost", n)) }
      if c.expiry && !w.dayLater { out.append(("a day goes by", w.expiring())) }
      return out.map { ($0.label, $0.next.startingWaiting()) }
    }
  }

  /// `startWaitingHandoffs`, which the shell runs after each send, run end and sweep: every waiting
  /// hand-off whose chat is free starts, oldest first. shortcut: run after every step, so the up to
  /// 15 seconds a queued root waits after Stop Everything for the next sweep are not explored.
  func startingWaiting() -> HandoffWorld {
    var next = self
    for r in ledger.records where r.state == .waiting { if let n = next.starting(r.id) { next = n } }
    return next
  }
}
