import Foundation

// Pure rules for tasks inside Serein: the one-line Working strip above the composer (which tasks
// it lists, in what order, how many before “+N”), the words on a task's card and in its header,
// and what Serein says after a Stop. Nothing here touches the UI, so SereinChecks covers it.

/// The Working strip: every task, Serein's and direct ones, live and from the last 24 hours. It is
/// built from the run ledger (which survives the hub's trim and a relaunch) merged with live hub
/// runs. Serein's own turns are not tasks and never show. It wraps `AtWorkList`'s idea of waiting.
public enum SereinTrayList {
  public struct Item: Equatable {
    /// The task's thread id (one chip per thread: its latest run).
    public var id: String
    public var title: String
    public var outcome: RunRecord.Outcome
    public var startedAt: Date
    public var endedAt: Date?
    /// A task Serein started (it opens in the Serein surface); false for a direct task (its tab).
    public var serein: Bool
    public init(id: String, title: String, outcome: RunRecord.Outcome, startedAt: Date, endedAt: Date? = nil, serein: Bool) {
      self.id = id
      self.title = title
      self.outcome = outcome
      self.startedAt = startedAt
      self.endedAt = endedAt
      self.serein = serein
    }
    public var live: Bool { outcome == .running }
    public var needsYou: Bool { outcome == .waiting }
  }
  /// A finished task stays in the strip this long.
  public static let retention: TimeInterval = 24 * 3600
  /// Chips shown before “+N”.
  public static let cap = 3

  /// The strip's items: live hub runs win over the ledger's record of the same thread; Serein's
  /// own turns (`own`) never show. A run still working stays; everything else, one that ended
  /// waiting on you included, drops out a day after it ended (or sooner, once you dismiss it).
  /// Live and needs-you first (oldest first, so chips do not jump), then done, failed and stopped,
  /// newest first.
  public static func items(ledger: [Item], live: [Item], now: Date, own: (String) -> Bool = { _ in false }) -> [Item] {
    var byThread: [String: (item: Item, hub: Bool)] = [:]
    // The ledger keeps every record of a run; the latest start per thread stands for it.
    for item in ledger where !own(item.id) {
      if let known = byThread[item.id], known.item.startedAt >= item.startedAt { continue }
      byThread[item.id] = (item, false)
    }
    for item in live where !own(item.id) {
      if let known = byThread[item.id], known.item.startedAt > item.startedAt { continue }
      byThread[item.id] = (item, true)
    }
    let kept = byThread.values.filter { entry in
      (entry.hub && entry.item.live)
        || now.timeIntervalSince(entry.item.endedAt ?? entry.item.startedAt) < retention
    }.map(\.item)
    let first = kept.filter { $0.live || $0.needsYou }.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
    let rest = kept.filter { !$0.live && !$0.needsYou }
      .sorted { (($0.endedAt ?? $0.startedAt), $0.id) > (($1.endedAt ?? $1.startedAt), $1.id) }
    return first + rest
  }
  /// Any task waits on your answer: the Serein row and band tab then read “Needs you”.
  public static func needsYou(_ items: [Item]) -> Bool { items.contains(where: \.needsYou) }
  /// The chips that show, and how many fold into “+N”. Beside a tab, two chips keep each title
  /// readable; full, three.
  public static func layout(_ items: [Item], cap: Int = cap) -> (shown: [Item], more: Int) {
    (Array(items.prefix(cap)), max(0, items.count - cap))
  }
  /// The strip shows while a task is live, waiting, or finished in the last 24 hours.
  public static func visible(_ items: [Item]) -> Bool { !items.isEmpty }
  /// The strip's label: “Working on 2”, “Working on 1 · 1 needs you”, “Needs you”,
  /// “Offline · Working on 2”, or “Done today”. It counts every task, also the one in view, so it
  /// says what the Serein row says. `compact` (beside a tab, where every waiting chip shows and
  /// says “Needs you” itself) leaves the waiting count out.
  public static func label(_ items: [Item], online: Bool, compact: Bool = false) -> String {
    let live = items.filter(\.live).count
    let waiting = items.filter(\.needsYou).count
    let words = live > 0
      ? "Working on \(live)" + (waiting > 0 && !compact ? " · \(waiting) needs you" : "")
      : waiting > 0 ? "Needs you" : "Done today"
    return online ? words : "Offline · " + words
  }
  /// A chip's second words: the live line, “Needs you”, “3 h ago”, “Could not finish”, “Stopped”.
  public static func chipDetail(_ item: Item, line: String?, now: Date) -> String {
    switch item.outcome {
    case .running:
      let clock = TaskClock.short(now.timeIntervalSince(item.startedAt))
      return line.map { TaskWords.short($0, limit: 28) + " · " + clock } ?? clock
    case .waiting: return "Needs you"
    case .done: return ago(item.endedAt ?? item.startedAt, now: now)
    case .stuck: return "Could not finish"
    case .stopped: return "Stopped"
    }
  }
  /// “just now”, “4 min ago”, “3 h ago”.
  public static func ago(_ date: Date, now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(date)))
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60) min ago" }
    return "\(s / 3600) h ago"
  }
  /// How much a chip says after its title, as room runs short: everything (the live step and
  /// time), the short words (the time), or only what its glyph cannot say.
  public enum ChipDetail: Sendable { case full, short, minimal }
  /// Nothing is live and a task waits on you: the label reads “Needs you”.
  public static func labelSaysNeedsYou(_ items: [Item]) -> Bool {
    !items.contains(where: \.live) && items.contains(where: \.needsYou)
  }
  /// A chip's words after its title at `detail`, or nil for none. A live chip's spinner and a done
  /// chip's check say their state, so at `.minimal` they show no words; “Needs you”, “Could not
  /// finish” and “Stopped” always show, except that a waiting chip leaves “Needs you” to a label
  /// that already says it.
  public static func chipWords(_ item: Item, line: String?, now: Date, detail: ChipDetail, labelSaysNeedsYou: Bool)
    -> String?
  {
    if item.needsYou && labelSaysNeedsYou { return nil }
    switch detail {
    case .full: return chipDetail(item, line: line, now: now)
    case .short: return chipDetail(item, line: nil, now: now)
    case .minimal: return item.live || item.outcome == .done ? nil : chipDetail(item, line: nil, now: now)
    }
  }
  /// What VoiceOver reads for a chip: “Fix the tests, working, 0:12”.
  public static func chipLabel(_ item: Item, now: Date) -> String {
    switch item.outcome {
    case .running: return "\(item.title), working, \(TaskClock.short(now.timeIntervalSince(item.startedAt)))"
    case .waiting: return "\(item.title), needs you"
    case .done: return "\(item.title), done \(ago(item.endedAt ?? item.startedAt, now: now))"
    case .stuck: return "\(item.title), could not finish"
    case .stopped: return "\(item.title), stopped"
    }
  }
}

/// The words a task shows on its card, in its header's pill and in the strip.
public enum TaskWords {
  /// The header's pill: “Working · 2:16”, “Needs you”, “Done in 3 min”, “Could not finish”,
  /// “Stopped”.
  public static func pill(_ outcome: RunRecord.Outcome, seconds: TimeInterval) -> String {
    switch outcome {
    case .running: return "Working · " + TaskClock.short(seconds)
    case .waiting: return "Needs you"
    case .done: return "Done in " + AgentTabStatus.duration(seconds)
    case .stuck: return "Could not finish"
    case .stopped: return "Stopped"
    }
  }
  /// The pill in a narrow header (Serein beside, under 380 points): the time while it works
  /// (“2:16”), “Done” once done; the full words stay in its help and accessibility value.
  public static func compactPill(_ outcome: RunRecord.Outcome, seconds: TimeInterval) -> String {
    switch outcome {
    case .running: return TaskClock.short(seconds)
    case .done: return "Done"
    default: return pill(outcome, seconds: seconds)
    }
  }
  /// The Options chip's model words: a family people know (“Opus”, “Sonnet”, “GPT-5.1”), or
  /// nothing when the model has no short name (the chip then reads “Options” alone).
  public static func modelBadge(_ model: String) -> String {
    let short = ModelBadge.short(model)
    guard let first = short.first else { return "" }
    if first.isNumber { return model.lowercased().contains("gpt") ? "GPT-" + short : "" }
    return short
  }
  /// A task card whose run and record are gone (an earlier launch, a trimmed ledger): no outcome
  /// is guessed.
  public static let finishedEarlier = "Finished earlier"
  /// The card's status line: “Running the tests · 0:12”, “Needs your answer”, “Done in 3 min”,
  /// “Could not finish.”, “Stopped”.
  public static func card(_ outcome: RunRecord.Outcome, line: String?, seconds: TimeInterval) -> String {
    switch outcome {
    case .running: return (line.map { short($0) + " · " } ?? "") + TaskClock.short(seconds)
    case .waiting: return "Needs your answer"
    case .done: return "Done in " + AgentTabStatus.duration(seconds)
    case .stuck: return "Could not finish."
    case .stopped: return "Stopped"
    }
  }
  /// Where a task works, in the card's words: “in shop-web”, “On the web”, “On your Mac”.
  public static func place(mode: String, project: String?) -> String {
    switch mode {
    case "project": return project.map { "in \($0)" } ?? "in a project"
    case "research", "page": return "On the web"
    case "anywhere": return "On your Mac"
    default: return "An answer"
    }
  }
  /// The task composer's label and placeholder: “Reply to Codex in shop-web”.
  public static func replyTo(app: String, mode: String, project: String?) -> String {
    switch mode {
    case "project": return "Reply to \(app) in \(project ?? "this project")"
    case "research", "page": return "Reply to \(app) on the web"
    case "anywhere": return "Reply to \(app) on your Mac"
    default: return "Reply to \(app)"
    }
  }
  /// A live line kept short enough for a chip.
  public static func short(_ line: String, limit: Int = 40) -> String {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
  }
  /// What Serein says at the limit of three tasks at once, for a start that cannot wait in line.
  public static func atLimit(_ max: Int) -> String {
    "I am already working on \(max) things. Stop one, or ask me again when one finishes."
  }
  /// The Delete Chat… confirmation.
  public static func deleteTitle(_ title: String) -> String {
    "Delete “\(title.isEmpty ? "this chat" : String(title.prefix(80)))”?"
  }
  public static let deleteBody = "This removes the chat and stops any task still working in it. This cannot be undone."
  /// A task tab's × help: closing never stops the task.
  public static let closeHelp = "Close tab. The task keeps working."
}

/// What Serein says after a Stop (F5): the reply stopped while tasks go on, a bare “stop” while
/// idle, and Stop Everything. `working` counts the tasks Serein started (what “Stop them” stops);
/// `others`, the tasks you started yourself, which a Stop never touches. With none of those the
/// words are the short ones (“2 tasks are still working.”); with some, they say whose is whose.
public enum RelayStopNotice: Equatable, Sendable {
  /// Stop, or a bare “stop”, ended the reply; `working` tasks are still going.
  case stoppedReply(working: Int, others: Int = 0)
  /// A bare “stop” while Serein was idle.
  case idle(working: Int, others: Int = 0)
  /// Stop Everything: Serein and every task stopped, reminders and alerts paused.
  case everything
  /// The reply used its whole step budget (StepBudget) and stopped as Stop stops it.
  case steps(Int)

  public var text: String {
    switch self {
    case .steps(let limit): return StepBudget.line(limit)
    case .stoppedReply(let n, let others):
      if n == 0 { return others == 0 ? "Stopped this reply." : "Stopped this reply. Tasks you started keep going." }
      return others == 0
        ? "Stopped this reply. \(things(n)) still working."
        : "Stopped this reply. \(serein(n)) still working. Tasks you started keep going."
    case .idle(let n, let others):
      if n == 0 { return others == 0 ? "Nothing is running." : "Serein has no tasks running. Tasks you started keep going." }
      return others == 0 ? "\(things(n)) working." : "\(serein(n)) working. Tasks you started keep going."
    case .everything:
      return "Serein stopped everything. Reminders and alerts are paused until you resume."
    }
  }
  /// “1 task is”, “2 tasks are”.
  private func things(_ n: Int) -> String { n == 1 ? "1 task is" : "\(n) tasks are" }
  /// “1 task Serein started is”, “2 tasks Serein started are”.
  private func serein(_ n: Int) -> String { n == 1 ? "1 task Serein started is" : "\(n) tasks Serein started are" }
}
