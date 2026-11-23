import Foundation
import SereinCore

/// The Agents list's model: every task chat grouped by its project, with its status, AI app and
/// the pull request its messages link, and Serein's handoffs as jobs with their helpers. Sessions
/// running in the AI apps themselves (ExternalSessionStore) join their project too, with the
/// subagents they started; a session a Serein thread follows lends that thread its live state.
/// Built from what is already saved or scanned; nothing here is stored.
@MainActor enum AgentsByProject {
  enum Status: Equatable {
    case working, needsYou, review, failed, stopped, done, idle
    /// Nothing more will happen without you starting it again.
    var settled: Bool { self == .done || self == .idle || self == .stopped }
    var word: String {
      switch self {
      case .working: return "Working"
      case .needsYou: return "Needs you"
      case .review: return "Needs review"
      case .failed: return "Failed"
      case .stopped: return "Stopped"
      case .done: return "Finished"
      case .idle: return "Idle"
      }
    }
    /// Working and waiting stay listed in a project that shows only its first rows.
    var leads: Bool { self == .working || self == .needsYou || self == .review }
  }
  struct PullRequest: Equatable {
    let number: Int
    let url: URL
  }
  /// How far back a session the AI app keeps with no process still shows.
  static let recentWindow: TimeInterval = 48 * 3600
  struct Task: Identifiable {
    let id: String
    let title: String
    var status: Status
    let provider: Provider?
    let pullRequest: PullRequest?
    var when: Date
    /// One of Serein's helpers (it opens in Serein's surface).
    let serein: Bool
    let projectKey: String
    let projectName: String?
    /// A session running in the AI app itself, not started from Serein.
    var outside: ExternalSession? = nil
    /// A recent session in the AI app with no process now (the app keeps one only for the chat
    /// in front); it opens as a Serein thread that follows it.
    var past: DiscoveredSession? = nil
    /// The helpers its session started, newest first.
    var subagents: [ExternalSubagent] = []
    /// Where its pull request's state comes from: the PR its messages link, else the branch of the
    /// folder its session runs in.
    var pullKey: PullRequestStore.Key? = nil
    /// Every name it goes by, for its place in the list (AgentListOrder): its chat, and the session
    /// that chat follows, so a session opened as a chat stays where it was.
    var keys: [String] = []
    /// When it last really moved, for Recents. `when` may fall back to a time that an open
    /// also sets, so a chat with no record of its own activity counts as old here.
    var activity: Date = .distantPast
    /// Finished with its pull request still open: it waits on your review.
    func shown(_ pull: PullRequestLookup.Info?) -> Status {
      status == .done && (pull?.state == .open || pull?.state == .conflict) ? .review : status
    }
  }
  struct Job: Identifiable {
    let id: String
    let title: String
    let helpers: [Task]
    var status: Status { combined(helpers.map(\.status)) }
    var when: Date { helpers.map(\.when).max() ?? .distantPast }
    var keys: [String] { ["job." + id] }
    var activity: Date { helpers.map(\.activity).max() ?? .distantPast }
  }
  enum Entry: Identifiable {
    case task(Task)
    case job(Job)
    var id: String {
      switch self {
      case .task(let task): return "task." + task.id
      case .job(let job): return "job." + job.id
      }
    }
    var status: Status {
      switch self {
      case .task(let task): return task.status
      case .job(let job): return job.status
      }
    }
    var when: Date {
      switch self {
      case .task(let task): return task.when
      case .job(let job): return job.when
      }
    }
    var keys: [String] {
      switch self {
      case .task(let task): return task.keys
      case .job(let job): return job.keys
      }
    }
    var activity: Date {
      switch self {
      case .task(let task): return task.activity
      case .job(let job): return job.activity
      }
    }
    /// Every name in it, its job's helpers too, for what the list remembers.
    var allKeys: [[String]] {
      switch self {
      case .task(let task): return [task.keys]
      case .job(let job): return [job.keys] + job.helpers.map(\.keys)
      }
    }
  }
  struct Group: Identifiable {
    let id: String
    let name: String
    let entries: [Entry]
    var active: Bool { entries.contains { $0.status.leads } }
    var key: String { "project." + id }
    var when: Date { entries.map(\.when).max() ?? .distantPast }
  }
  static let noProject = "none"

  static func groups(agent: AgentModel, hub: AgentHub, relay: RelayOrchestrator?, ledger: [RunRecord],
                     items: [SereinTrayList.Item], projects: [Project], outside: [ExternalSession] = [],
                     subagents: [String: [ExternalSubagent]] = [:], known: [String] = [], pinned: [String] = [],
                     history: [DiscoveredSession] = [], now: Date = Date()) -> [Group] {
    // The latest ledger record per thread, then the strip's items (live hub runs win).
    var latest: [String: RunRecord] = [:]
    for record in ledger where (latest[record.threadID]?.startedAt ?? .distantPast) <= record.startedAt {
      latest[record.threadID] = record
    }
    let current = Dictionary(items.map { ($0.id, $0.outcome) }, uniquingKeysWith: { first, _ in first })
    func status(_ id: String) -> Status {
      let outcome = current[id] ?? latest[id]?.outcome
      switch outcome {
      // A record still marked running with no run behind it ended when an earlier launch quit.
      case .running?: return hub.run(for: id) != nil ? .working : .stopped
      case .waiting?: return .needsYou
      case .stuck?: return .failed
      case .stopped?: return .stopped
      case .done?: return .done
      case nil: return hub.run(for: id) != nil ? .working : .idle
      }
    }
    let names = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    // A running session by the harness id a thread knows it by (`<driver>:<native id>`).
    let running = Dictionary(outside.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var followed = Set<String>()
    // Codex's own names for its threads, and which are helpers (listed under their parent only).
    // Sessions the apps keep with no process now: those of the last two days.
    let recent = history.filter { now.timeIntervalSince($0.date) < Self.recentWindow }
    let codexIDs = agent.conversations.compactMap { $0.link?.driver == HarnessDriver.codex.rawValue ? $0.link?.nativeID : nil }
      + outside.filter { $0.driver == .codex }.map { String($0.id.dropFirst(HarnessDriver.codex.rawValue.count + 1)) }
      + recent.filter { $0.provider == HarnessDriver.codex.rawValue }.map(\.id)
    // Every app chat a Serein thread follows: it shows once, as that thread.
    var linked = Set<String>()
    let codex = CodexThreadIndex.shared.facts(codexIDs)
    func codexFacts(_ link: SessionLink?) -> CodexThreadIndex.Facts? {
      guard let link, link.driver == HarnessDriver.codex.rawValue else { return nil }
      return codex[link.nativeID]
    }
    func task(_ chat: Conversation, serein: Bool) -> Task {
      let record = latest[chat.id]
      let key = chat.projectID ?? record?.projectID ?? record?.projectName ?? noProject
      let name = chat.projectID.flatMap { names[$0] } ?? record?.projectID.flatMap { names[$0] } ?? record?.projectName
      // `updatedAt` also moves when a chat is only opened, so it is the last resort.
      // The person's own words, as the task's header shows them: links read as their words.
      // A Codex thread goes by the name Codex shows for it.
      let named = codexFacts(chat.link)?.name ?? (chat.messages.isEmpty ? chat.title : ProjectChatIndex.title(chat))
      var item = Task(id: chat.id, title: named.isEmpty ? "New task" : named, status: status(chat.id),
                      provider: chat.provider, pullRequest: pullRequest(chat),
                      when: chat.lastMessageAt ?? record?.lastEventAt ?? chat.updatedAt,
                      serein: serein, projectKey: name == nil ? noProject : key, projectName: name)
      item.pullKey = item.pullRequest.map { .url($0.url.absoluteString) }
      let keys = [chat.link.map { $0.driver + ":" + $0.nativeID },
                  chat.remoteID.flatMap { remote in chat.provider.driver.map { $0.rawValue + ":" + remote } }]
      item.keys = [chat.id] + keys.compactMap { $0 }
      linked.formUnion(keys.compactMap { $0 })
      item.activity = chat.lastMessageAt ?? record?.lastEventAt ?? .distantPast
      if let session = keys.compactMap({ $0 }).lazy.compactMap({ running[$0] }).first {
        followed.insert(session.id)
        if !item.status.leads, let live = Self.status(session.state) { item.status = live }
        item.when = max(item.when, session.updatedAt)
        item.activity = max(item.activity, session.updatedAt)
        item.subagents = subagents[session.id] ?? []
        if item.pullKey == nil { item.pullKey = session.cwd.map { .folder($0) } }
      }
      return item
    }
    var entries: [(key: String, name: String?, entry: Entry)] = []
    var helpersByJob: [String: [Task]] = [:]
    var jobTitles: [String: String] = [:]
    for chat in agent.conversations {
      if agent.isSereinTask(chat.id) {
        let child = relay?.child(chat.id)
        let job = (child?.chatID ?? "") + "/" + (child?.messageID ?? chat.id)
        helpersByJob[job, default: []].append(task(chat, serein: true))
        if jobTitles[job] == nil { jobTitles[job] = request(child, agent: agent) }
      } else if !agent.isSereinThread(chat.id, item: chat) {
        // A Codex helper's thread is one of its parent's sub-threads, not a task of its own.
        if codexFacts(chat.link)?.helper == true { continue }
        let item = task(chat, serein: false)
        entries.append((item.projectKey, item.projectName, .task(item)))
      }
    }
    // Sessions in the AI apps that no Serein thread follows, in the project of the folder they run
    // in (temporary folders left out, as in the project chats).
    for chat in ProjectChatIndex(projects: projects, threads: [], running: outside, history: recent).all {
      if case .past(let past) = chat.kind {
        let key = past.provider + ":" + past.id
        guard !linked.contains(key), !followed.contains(key) else { continue }
        let facts = past.provider == HarnessDriver.codex.rawValue ? codex[past.id] : nil
        if facts?.helper == true { continue }
        let name = chat.projectID.flatMap { names[$0] }
        let title = facts?.name ?? SessionIndex.userTitle(past.title) ?? past.title
        var item = Task(id: "past." + key, title: title.isEmpty ? chat.provider.name : title, status: .idle,
                        provider: chat.provider, pullRequest: nil, when: past.date, serein: false,
                        projectKey: name == nil ? noProject : chat.projectID ?? noProject, projectName: name, past: past)
        item.pullKey = past.cwd.isEmpty ? nil : .folder(past.cwd)
        item.keys = [key]
        item.activity = past.date
        entries.append((item.projectKey, item.projectName, .task(item)))
        continue
      }
      guard case .running(let session) = chat.kind, !followed.contains(session.id), session.parent == nil else { continue }
      let codexID = session.driver == .codex ? String(session.id.dropFirst(HarnessDriver.codex.rawValue.count + 1)) : nil
      if let codexID, codex[codexID]?.helper == true { continue }
      let name = chat.projectID.flatMap { names[$0] }
      let title = codexID.flatMap { codex[$0]?.name } ?? session.title
      var item = Task(id: "outside." + session.id, title: title.isEmpty ? chat.provider.name : title,
                      status: Self.status(session.state) ?? .idle, provider: chat.provider, pullRequest: nil,
                      when: session.updatedAt, serein: false, projectKey: name == nil ? noProject : chat.projectID ?? noProject,
                      projectName: name, outside: session, subagents: subagents[session.id] ?? [])
      item.pullKey = session.cwd.map { .folder($0) }
      item.keys = [session.id]
      item.activity = session.updatedAt
      entries.append((item.projectKey, item.projectName, .task(item)))
    }
    for (id, helpers) in helpersByJob {
      let ordered = AgentListOrder.arranged(helpers.sorted { $0.when < $1.when }, known: known, keys: \.keys)
      // Without the request's words (records from before they were kept) a job row would say
      // nothing, so its helpers stand as rows of their own.
      guard let title = jobTitles[id] else {
        for helper in ordered { entries.append((helper.projectKey, helper.projectName, .task(helper))) }
        continue
      }
      let lead = ordered.first { $0.projectName != nil } ?? ordered[0]
      entries.append((lead.projectKey, lead.projectName, .job(Job(id: id, title: title, helpers: ordered))))
    }
    let grouped = Dictionary(grouping: entries, by: \.key)
    let groups = grouped.map { key, members in
      // Newest first the first time they are seen; after that each keeps its place (AgentListOrder).
      let newest = AgentListOrder.recent(members.map(\.entry).sorted { $0.id < $1.id }, when: \.when)
      return Group(id: key, name: members.first { $0.name != nil }?.name ?? "No project",
                   entries: AgentListOrder.arranged(newest, known: known, pinned: pinned, keys: \.keys))
    }
    let newest = AgentListOrder.recent(groups.sorted { $0.id < $1.id }, when: \.when)
    let placed = AgentListOrder.arranged(newest, known: known) { [$0.key] }
    // No project stays last.
    return placed.filter { $0.id != noProject } + placed.filter { $0.id == noProject }
  }

  /// An outside session's or subagent's state; nil for one that is open but idle (or finished).
  nonisolated static func status(_ state: ExternalSession.State?) -> Status? {
    switch state {
    case .running?: return .working
    case .needsUser?: return .needsYou
    case .open?, nil: return nil
    }
  }

  nonisolated static func combined(_ statuses: [Status]) -> Status {
    for status in [Status.needsYou, .working, .review, .failed, .stopped, .done] where statuses.contains(status) { return status }
    return .idle
  }

  /// The words of Serein's message that started a job: its first line, at most 80 characters.
  private static func request(_ child: RelayOrchestrator.Child?, agent: AgentModel) -> String? {
    guard let child, let chatID = child.chatID, let messageID = child.messageID,
      let message = agent.conversations.first(where: { $0.id == chatID })?.messages.first(where: { $0.id == messageID })
    else { return nil }
    let line = message.text.split(whereSeparator: \.isNewline).first.map(String.init)?
      .trimmingCharacters(in: .whitespaces) ?? ""
    guard !line.isEmpty else { return nil }
    return line.count > 80 ? String(line.prefix(79)) + "…" : line
  }

  /// The last pull request a task's messages link (github.com/<owner>/<repo>/pull/<n>), looked
  /// up once per message count so redraws do not rescan whole chats.
  private static var pullCache: [String: (count: Int, pull: PullRequest?)] = [:]
  private static let pullPattern = try! NSRegularExpression(
    pattern: #"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/([0-9]{1,7})"#)
  static func pullRequest(_ chat: Conversation) -> PullRequest? {
    if let cached = pullCache[chat.id], cached.count == chat.messages.count { return cached.pull }
    var found: PullRequest?
    for message in chat.messages.reversed() where message.role != "you" {
      found = pullRequest(in: message.text)
      if found != nil { break }
    }
    pullCache[chat.id] = (chat.messages.count, found)
    return found
  }
  static func pullRequest(in text: String) -> PullRequest? {
    let range = NSRange(text.startIndex..., in: text)
    guard let match = pullPattern.matches(in: text, range: range).last,
      let whole = Range(match.range, in: text), let digits = Range(match.range(at: 1), in: text),
      let number = Int(text[digits]), let url = URL(string: String(text[whole]))
    else { return nil }
    return PullRequest(number: number, url: url)
  }
}
