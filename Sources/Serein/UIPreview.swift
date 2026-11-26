import Cocoa
import CoreText
import SQLite3
import SereinCore
import WebKit

/// Synthetic native previews never restore a personal library or discover a provider.
struct UIPreview {
  let screen: String
  let root: URL
  let capture: URL?
  let size: NSSize
  let reducedEffects: Bool
  let horizontalTabs: Bool
  /// `--appearance light|dark`; previews default to dark so older captures stay comparable.
  var appearance: AppearancePreference = .dark
  /// History keeps the old route names while exposing its four labelled segments.
  var historySegment: HistorySegment?
  var readyToSend = false

  static func configuration(
    arguments: [String] = CommandLine.arguments,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> UIPreview? {
    let flags = ["--ui-preview", "--ui-capture", "--ui-width", "--ui-height", "--ui-horizontal-tabs", "--ui-history-segment", "--ui-ready-to-send"]
    _ = setupStep
    guard arguments.contains(where: { flags.contains($0) || $0 == "--ui-reduced-effects" }) else {
      return nil
    }
    func value(_ flag: String) throws -> String? {
      let positions = arguments.indices.filter { arguments[$0] == flag }
      guard positions.count <= 1 else { throw SereinError.invalid("Duplicate \(flag)") }
      guard let index = positions.first else { return nil }
      guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
        throw SereinError.invalid("Missing value for \(flag)")
      }
      return arguments[index + 1]
    }
    let screens = ["start", "thread", "projects", "history", "saved", "browser", "settings", "composer", "phone", "agent", "tasks", "models", "setup", "menu", "ask", "serein", "serein-side", "connect", "search"]
    guard let screen = try value("--ui-preview"), screens.contains(screen),
      !arguments.contains("--verify")
    else { throw SereinError.invalid("Use --ui-preview with a supported screen, without --verify") }
    guard let path = environment["SEREIN_DATA_DIR"], path.hasPrefix("/") else {
      throw SereinError.invalid("UI preview requires SEREIN_DATA_DIR to name a fresh marked temp directory")
    }
    let files = FileManager.default
    let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let temporaryRoots = [files.temporaryDirectory, URL(fileURLWithPath: "/tmp", isDirectory: true)]
      .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    guard temporaryRoots.contains(where: { root.path.hasPrefix($0.path + "/") }),
      let attributes = try? files.attributesOfItem(atPath: root.path),
      attributes[.type] as? FileAttributeType == .typeDirectory,
      let created = attributes[.creationDate] as? Date,
      abs(created.timeIntervalSinceNow) <= 600,
      Set(try files.contentsOfDirectory(atPath: root.path)) == [".serein-ui-preview"]
    else { throw SereinError.invalid("Preview directory must be newly created, empty, and under system temp") }
    let marker = root.appendingPathComponent(".serein-ui-preview")
    let markerAttributes = try files.attributesOfItem(atPath: marker.path)
    guard markerAttributes[.type] as? FileAttributeType == .typeRegular,
      (markerAttributes[.size] as? NSNumber)?.intValue == 0
    else { throw SereinError.invalid("Preview marker must be an empty regular file") }
    func dimension(_ flag: String, fallback: Int, minimum: Int) throws -> Int {
      guard let raw = try value(flag) else { return fallback }
      guard let result = Int(raw), result >= minimum, result <= 4096 else {
        throw SereinError.invalid("\(flag) must be between \(minimum) and 4096")
      }
      return result
    }
    // `--ui-serein-narrow`: the minimum window (with a wide sidebar), unless a size is named.
    let narrow = arguments.contains("--ui-serein-narrow")
    let width = try dimension("--ui-width", fallback: narrow ? 1030 : 1360, minimum: 1030)
    let height = try dimension("--ui-height", fallback: narrow ? 680 : 860, minimum: 680)
    var capture: URL?
    if let destination = try value("--ui-capture") {
      guard destination.hasPrefix("/"), destination.lowercased().hasSuffix(".png") else {
        throw SereinError.invalid("--ui-capture requires an absolute PNG path")
      }
      let url = URL(fileURLWithPath: destination).standardizedFileURL.resolvingSymlinksInPath()
      let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        .resolvingSymlinksInPath()
      guard !url.path.hasPrefix(sourceRoot.path + "/") else {
        throw SereinError.invalid("Keep preview captures outside the repository")
      }
      capture = url
    }
    var appearance = AppearancePreference.dark
    if let raw = try value("--appearance") {
      guard let chosen = AppearancePreference(rawValue: raw), chosen != .system else {
        throw SereinError.invalid("--appearance must be light or dark")
      }
      appearance = chosen
    }
    var historySegment: HistorySegment?
    if let raw = try value("--ui-history-segment") {
      guard let segment = HistorySegment(rawValue: raw) else {
        throw SereinError.invalid("--ui-history-segment must be pages, chats, activity, projects or todo")
      }
      historySegment = segment
    }
    let readyToSend = arguments.contains("--ui-ready-to-send")
    if readyToSend { historySegment = .chats }
    return UIPreview(screen: screen, root: root, capture: capture,
      size: NSSize(width: CGFloat(width), height: CGFloat(height)),
      reducedEffects: arguments.contains("--ui-reduced-effects"),
      horizontalTabs: arguments.contains("--ui-horizontal-tabs"), appearance: appearance,
      historySegment: historySegment, readyToSend: readyToSend)
  }

  func installDefaults() {
    var defaults = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    defaults.merge([
      "serein.history": false,
      "serein.horizontalTabs": horizontalTabs, "serein.sleepMinutes": 0, "serein.retentionDays": 0,
      "serein.darkPages": false, "serein.searchEngine": "DuckDuckGo",
      "serein.browserImportOnboardingComplete": true,
      // Serein as a new install has it (never written to the user's settings): ⌥Space off unless
      // `--ui-global-access`, the migration done, no check-ins, no note suggestions, Every step,
      // and no hologram unless `--ui-hologram` (its WebGL page would hold up the capture).
      "serein.relay.enabled": CommandLine.arguments.contains("--ui-global-access"),
      // `--ui-menu-bar`: Keep Serein in the menu bar is on.
      "serein.assistant.menuBar": CommandLine.arguments.contains("--ui-menu-bar"),
      // `--ui-serein-hidden`: Serein after Hide, with the toast that says how to bring it back.
      // `--ui-serein-peek`: hidden too, then a peek beside this tab (presentAndCapture).
      // `--ui-serein-waiting`: hidden, with a card waiting (the slim line and the row say so).
      // `--ui-serein-bar-*`: hidden, so the window behind the bar is a page as it was.
      "serein.relay.column": !["--ui-serein-hidden", "--ui-serein-peek", "--ui-serein-waiting", "--ui-serein-bar-reply",
                               "--ui-serein-bar-approval", "--ui-serein-bar-held", "--ui-serein-bar-mic"].contains { CommandLine.arguments.contains($0) },
      // `--ui-serein-narrow`: the sidebar dragged to its widest, so beside has no room.
      UIStyle.sidebarExtraKey: CommandLine.arguments.contains("--ui-serein-narrow") ? Double(UIStyle.sidebarExtraMax) : 0.0,
      AssistantMigration.flagKey: 1,
      // The rail's place for the screen (it follows the main view, as in use); `--ui-agents`
      // shows the Agents list, and `--ui-assistants` Serein's list, where the assistant list now
      // sits, each with a preview roster and one team (RelayOrchestrator.previewTeam).
      SidebarMode.key: (CommandLine.arguments.contains("--ui-assistants") ? SidebarMode.serein
        : CommandLine.arguments.contains("--ui-agents") || ["composer", "models"].contains(screen) ? SidebarMode.assistants
        : SidebarMode.mode(for: screen) ?? .serein).rawValue,
      "serein.relay.learnsNotes": false,
      "serein.relay.hologram": CommandLine.arguments.contains("--ui-hologram"),
      // The page chip is on (GateSettings, in memory here), and its first-time line shows only
      // in `--ui-serein-page-chip`.
      SereinPageChip.seenKey: !CommandLine.arguments.contains("--ui-serein-page-chip"),
    ]) { _, preview in preview }
    // With tabs on top there is no sidebar to widen: Compact Mode is what leaves no room there.
    if CommandLine.arguments.contains("--ui-serein-narrow") && horizontalTabs { defaults["serein.compact"] = true }
    // `--ui-sidebar-live`: the sidebar's width is not held, so a drag of its edge takes. It reads
    // and writes this build's own two sidebar width settings, the one thing a preview saves.
    if CommandLine.arguments.contains("--ui-sidebar-live") {
      defaults[UIStyle.sidebarExtraKey] = nil
    } else {
      // `--ui-sidebar-rail`: the sidebar as its rail, as a new install opens; else the list.
      defaults[UIStyle.sidebarRailKey] = CommandLine.arguments.contains("--ui-sidebar-rail")
    }
    UserDefaults.standard.setVolatileDomain(defaults, forName: UserDefaults.argumentDomain)
    // `--ui-ask-before every|risky`: what Serein asks before (Every step unless risky). A preview
    // never opens GateSettings, so this stays in memory.
    GateSettings.shared.set(Self.askBefore == .riskyOnly, forKey: AssistantMigration.autopilotKey)
    GateSettings.shared.set(true, forKey: SereinPageChip.shareKey)
    // No day descriptions and no check-ins, as a new install has them.
    GateSettings.shared.set(false, forKey: FeaturePolicy.key(.timeline))
    GateSettings.shared.set(RelayProactive.Level.off.rawValue, forKey: AssistantMigration.proactiveKey)
    if CommandLine.arguments.contains("--ui-screen-sharing") {
      for key in [ScreenContext.enabledKey, ScreenContext.pictureKey, ScreenTrail.enabledKey] { GateSettings.shared.set(true, forKey: key) }
    }
    // affectUI lane dial: `--ui-affect-autonomy-dial` (with `--ui-preview settings
    // --ui-settings-section Relay/asks`, add `--ui-ask-before risky` for the other stop): two
    // standing yeses and two site rules, one of which outranks a yes. In memory, like the rest here.
    if CommandLine.arguments.contains("--ui-affect-autonomy-dial") {
      for site in ["maps.example.com", "shop.example.com"] { RoutineGrants.allow(site) }
      SiteRules.set(.ask, for: "shop.example.com")
      SiteRules.set(.never, for: "bank.example.com")
    }
  }

  @MainActor func seed(browser: BrowserModel, agent: AgentModel) throws {
    browser.lifecycle?.cancel()
    browser.lifecycle = nil
    BrowserOnboardingPreview.profiles = try browserImportFixtures()
    let names = [
      "Atlas customer operations and onboarding portal", "Fieldnotes collaborative product planning",
      "Signal market research and source validation", "Studio long form publishing workspace",
      "Northstar accessible navigation and design system", "Archive document search and evidence review",
      "Harbor support triage and account history", "Notebook local knowledge and project memory",
      "Workshop native application performance lab", "Orchard community operations dashboard",
      "Beacon deployment observability and incident response", "Loom editorial calendar and review queue",
      "Compass personal research and reading library", "Canvas presentation and reporting toolkit",
      "Current finance reconciliation and audit evidence", "Lantern agent permissions and capability controls",
      "Maple educational lesson planning workspace", "Bridge external integrations and import adapters",
      "Quartz keyboard accessibility regression suite", "Horizon customer interview synthesis archive",
      "Trellis project discovery and placement controls", "Cedar native browser content extraction",
      "Ember synthetic benchmark and fixture explorer", "Mosaic multilingual product documentation",
    ]
    let areaNames = ["Customer workflows", "Design and knowledge", "Operations", "Research and reporting", "Learning and integrations", "Native tools"]
    var projects: [Project] = []
    var notes: [ProjectNote] = []
    for (index, name) in names.enumerated() {
      let folder = root.appendingPathComponent("Fixtures/project-\(index + 1)", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data("# \(name)\nSynthetic UI preview project.\n".utf8)
        .write(to: folder.appendingPathComponent("README.md"), options: .atomic)
      // Project markers so the classifier keeps them; one folder was added by hand without any.
      let added = index == 21
      if !added {
        if index.isMultiple(of: 3) {
          let git = folder.appendingPathComponent(".git")
          try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
          // A synthetic origin, so that the map has more than one area to show.
          let owner = ["atlas-team", "fieldnotes", "signal-lab"][index / 3 % 3]
          try Data("[remote \"origin\"]\n\turl = https://git.preview.invalid/\(owner)/project-\(index + 1).git\n".utf8)
            .write(to: git.appendingPathComponent("config"))
        } else {
          try Data("{}".utf8).write(
            to: folder.appendingPathComponent(index.isMultiple(of: 2) ? "package.json" : "Package.swift"))
        }
      }
      var project = Project(name: name, path: folder.path, source: added ? .added : .history)
      project.id = "preview-project-\(index + 1)"
      projects.append(project)
      notes.append(ProjectNote(projectID: project.id,
        summary: "A synthetic workspace for reviewing \(areaNames[index / 4].lowercased()) across long project names and compact controls.",
        purpose: areaNames[index / 4], resources: ["README.md"]))
    }
    // One-off chat folders, temp and system places from CLI history: realistic junk that the
    // classifier moves to "Other folders". Synthetic names under a fixture home.
    let home = root.appendingPathComponent("Fixtures/home", isDirectory: true)
    let junk = [
      "Documents/Codex/2026-10-05/can-you-check-why-the-build", "Documents/Codex/2026-10-05/do",
      "Documents/Codex/2026-10-07/https-github-com-example-sample-repo", "Documents/Codex/2026-10-07/giv",
      "Documents/Codex/2026-10-08/recreate-the-image-put-it-on", "Desktop/what-is-the-best-way-to",
      "Library/Application Support/Sample/scratch-2026-10-01-a1b2c3", "Desktop", "",
    ]
    for (index, path) in junk.enumerated() {
      let folder = path.isEmpty ? home : home.appendingPathComponent(path, isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      var project = Project(
        name: path.isEmpty ? "home" : folder.lastPathComponent, path: folder.path, source: .history)
      project.id = "preview-folder-\(index + 1)"
      projects.append(project)
    }
    browser.projects = projects
    browser.projectNotes = Dictionary(uniqueKeysWithValues: notes.map { ($0.projectID, $0) })
    try browser.library.save(projects, to: "projects/projects.json")
    try browser.library.save(notes, to: "projects/notes.json")
    // Preview-only: `-serein.previewProjectAreas YES` gives the map areas by purpose, as if the
    // agent had sorted the projects. The last project stays out, as a new one would.
    if UserDefaults.standard.bool(forKey: "serein.previewProjectAreas") {
      let sorted = (0..<areaNames.count).map { area in
        ProjectArea(
          name: areaNames[area],
          projectIDs: (0..<names.count - 1).filter { $0 / 4 == area }.map { "preview-project-\($0 + 1)" })
      }
      try browser.library.save(sorted, to: ProjectPurposeStore.path)
    }
    browser.refreshProjectKindsNow()
    for (index, branch) in ["main", "feature/onboarding", "main", "design-tokens", "main", "fix/search"]
      .enumerated()
    {
      ProjectInsights.shared.setGit(
        GitSummary(branch: branch, commits: ["Synthetic preview commit"]),
        for: projects[index].path, library: browser.library)
    }
    if screen == "projects" {
      // Activity markers: one running, one waiting on you, one finished today.
      let marks: [(Int, RunRecord.Outcome)] = [(0, .running), (2, .waiting), (5, .done)]
      for (index, outcome) in marks {
        var run = RunRecord(
          threadID: "preview-thread-\(index + 1)", provider: "codex", mode: "project",
          projectID: projects[index].id, projectName: projects[index].name, title: "Synthetic run",
          startedAt: Date().addingTimeInterval(-600))
        run.outcome = outcome
        run.lastEventAt = Date().addingTimeInterval(-120)
        if outcome == .done { run.endedAt = Date().addingTimeInterval(-120) }
        try browser.library.appendRun(run)
      }
      ProjectActivityStore.shared.prime(library: browser.library)
      if CommandLine.arguments.contains("--ui-project-chats") {
        // Chats of every kind in the first projects: a running session, past sessions of six
        // harnesses (synthetic titles), so the marks, the panel and the finder have rows.
        let now = Date()
        let a = projects[0].path, b = projects[1].path, c = projects[2].path
        ExternalSessionStore.shared.update([
          ExternalSession(id: "claude:run1", driver: .claude, title: "Tighten the sidebar spacing", cwd: a, state: .running, updatedAt: now),
        ])
        let rows: [(String, String, String, String, Double)] = [
          ("claude", "c1", a, "Fix the onboarding copy", 3_600), ("claude", "c2", a, "Review the release notes", 90_000),
          ("codex", "x1", a, "Speed up the start page", 7_200), ("codex", "x2", a, "Add tests for the tab band", 200_000),
          ("codex", "x3", b, "Pick a chart library", 5_000), ("opencode", "o1", a, "Plan the docs site", 40_000),
          ("grok", "g1", a, "Profile the build", 12_000), ("grok", "g2", c, "Draft the launch post", 9_000),
          ("cursor", "u1", b, "Tidy the CSS tokens", 30_000), ("omp", "m1", a, "Summarise the open issues", 60_000),
          ("pi", "p1", c, "Rename the module", 400_000),
        ]
        var sessions: [String: DiscoveredSession] = [:]
        for row in rows {
          sessions["/preview/\(row.0)/\(row.1)"] = DiscoveredSession(
            provider: row.0, id: row.1, cwd: row.2, title: row.3, date: now.addingTimeInterval(-row.4),
            file: ["claude", "codex"].contains(row.0) ? "/preview/\(row.1).jsonl" : nil)
        }
        SessionHistoryStore.shared.installPreview(SessionHistory(sessions: sessions), cloud: [])
      }
    }

    let now = Date()
    let titles = [
      "Review the workspace hierarchy and long project names",
      "Compare customer onboarding research and support feedback",
      "Check keyboard navigation across compact controls",
      "Trace the reading flow in the research library",
      "Review the native application release checklist",
      "Summarize the reporting toolkit design decisions",
      "Audit integration permissions and review evidence",
      "Prepare multilingual documentation for the next release",
      "Find the project with the source validation workflow",
      "Plan the next writing session from saved passages",
    ]
    let reply = """
      ## Workspace review
      The workspace now has a clear hierarchy: project groups lead to tasks, while the main pane keeps the active work in view.

      - [x] Compact controls retain their keyboard labels.
      - [ ] Check long names and source context.

      | Surface | Review |
      | :--- | :--- |
      | Transcript | Spacing and selection |
      | Composer | Focus and keyboard flow |

      ```swift
      let workspace = "Synthetic UI preview"
      let ready = true // Local layout fixture
      ```

      > These are synthetic fixtures for checking the native layout.
      """
    agent.conversations = titles.enumerated().map { index, title in
      Conversation(id: "preview-thread-\(index + 1)", title: title,
        messages: [AgentMessage(id: "preview-earlier-user-\(index)", role: "you", text: "Earlier synthetic request"),
          AgentMessage(id: "preview-earlier-assistant-\(index)", role: "assistant",
            text: "Earlier synthetic reply.\n\n```swift\nlet previous = true\n```"),
          AgentMessage(id: "preview-user-\(index)", role: "you", text: title),
          AgentMessage(id: "preview-assistant-\(index)", role: "assistant", text: reply)],
        provider: index.isMultiple(of: 2) ? .codex : .claude,
        mode: index < 8 ? .project : .research,
        projectID: index < 8 ? projects[index].id : nil, remoteID: nil,
        scope: "Synthetic preview", updatedAt: now.addingTimeInterval(-Double(index) * 1800),
        autoRouting: false,
        model: index.isMultiple(of: 2) ? "Synthetic Codex model" : "Synthetic Claude model",
        effort: index.isMultiple(of: 2) ? "high" : "medium",
        draft: index == 1 ? "Summarize the onboarding research and support feedback." : nil)
    }
    agent.restore(agent.conversations[0])
    agent.model = "Synthetic reasoning model for layout preview"
    agent.effort = "high"
    agent.auth = Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, "Disabled in UI preview") })
    agent.available = [:]
    try browser.library.save(agent.conversations, to: "sessions/threads.json")
    try browser.library.save(agent.messages, to: "sessions/conversation.json")
    try browser.library.save(agent.conversationID, to: "sessions/active.json")

    let today = Calendar.current.startOfDay(for: now)
    let pages = ["Workspace design notes", "Customer research brief", "Navigation accessibility checklist", "Reporting workflow review", "Native performance observations", "Source validation guide"]
    browser.visits = Array((0..<18).map { index in
      var visit = Visit(url: "https://preview.invalid/notes/\(index + 1)",
        title: pages[index % pages.count],
        text: "Synthetic reading history for \(pages[index % pages.count].lowercased()). Review hierarchy, keyboard flow, and evidence links.")
      visit.id = "preview-visit-\(index + 1)"
      visit.date = today.addingTimeInterval(Double(9 * 3600 + index * 1200))
      return visit
    }.reversed())
    browser.marks = browser.visits.prefix(8).map { visit in
      var mark = Mark(title: visit.title, url: visit.url,
        quote: "A quieter workspace keeps the active task, its sources, and the next useful action within reach.")
      mark.id = "preview-mark-\(visit.id)"
      mark.date = visit.date
      return mark
    }
    let timeline = DayTimeline(headline: "A day of workspace research and native UI review",
      episodes: (0..<3).map { index in
        Episode(title: ["Research the workspace", "Review the design details", "Prepare the release notes"][index],
          summary: "Synthetic sources connect the layout review to \(pages[index].lowercased()).",
          visitIDs: Array(browser.visits[(index * 6)..<(index * 6 + 6)]).map(\.id))
      })
    try timeline.validate(visits: browser.visits)
    browser.timelines = [BrowserModel.dayKey(now): timeline]
    for visit in browser.visits { try browser.library.append(visit, to: "history/\(Library.day).jsonl") }
    try browser.library.save(browser.marks, to: "marks/saved.json")
    try browser.library.save(timeline, to: "index/days/\(Library.day).json")

    let hosts = ["notes.preview.invalid", "research.preview.invalid", "access.preview.invalid"]
    let tiles: [(String, NSColor)] = [
      ("N", NSColor(red: 0.30, green: 0.36, blue: 0.95, alpha: 1)),
      ("R", NSColor(red: 0.85, green: 0.27, blue: 0.27, alpha: 1)),
      ("A", NSColor(red: 0.10, green: 0.62, blue: 0.47, alpha: 1)),
    ]
    // Pages are open only in the previews that show one: the rest open as a person's Serein does.
    let chatFirst = ["serein", "search", "start", "history", "thread", "saved", "projects", "settings", "composer", "models", "connect"].contains(screen)
      && !CommandLine.arguments.contains { $0.hasPrefix("--ui-") && $0.range(of: "page|chip|here|tab|split|beside|peek|private", options: .regularExpression) != nil }
    browser.tabs = (chatFirst ? [] : Array(pages.prefix(3))).enumerated().map { index, title in
      let tab = BrowserTab(store: .nonPersistent())
      tab.web.loadHTMLString(Self.page(title: title), baseURL: URL(string: "https://\(hosts[index])/"))
      tab.title = title
      tab.address = "https://\(hosts[index])/"
      FaviconStore.shared.seedPreview(host: hosts[index], letter: tiles[index].0, color: tiles[index].1)
      return tab
    }
    browser.selected = browser.tabs.first?.id
    // `--ui-recently-closed`: three closed tabs, so the new-tab page shows Recently closed.
    if CommandLine.arguments.contains("--ui-recently-closed") {
      browser.recentlyClosed = Array(browser.visits.prefix(5).map(\.url).reversed().prefix(3))
    }
    if CommandLine.arguments.contains("--ui-serein-private") {
      // `--ui-serein-private`: a private tab in front; the chip slot says it is not shared.
      let tab = BrowserTab(privateMode: true, store: .nonPersistent())
      tab.web.loadHTMLString(Self.page(title: "Gift ideas for Maya"), baseURL: URL(string: "https://gifts.preview.invalid/"))
      tab.title = "Gift ideas for Maya"
      tab.address = "https://gifts.preview.invalid/"
      browser.tabs.insert(tab, at: 0)
      browser.selected = tab.id
    }
    if CommandLine.arguments.contains("--ui-split"), browser.tabs.count >= 2 {
      browser.selected = browser.tabs[0].id
      browser.splitCompanionID = browser.tabs[1].id
    }
    if CommandLine.arguments.contains("--ui-page-recording"), let tab = browser.active {
      tab.title = "Page recording demo"
      tab.web.loadHTMLString("""
        <!doctype html><meta name="viewport" content="width=device-width">
        <style>
        :root{color-scheme:dark}body{margin:0;background:#121212;color:#eee;font:16px -apple-system,sans-serif}
        main{max-width:720px;margin:auto;padding:70px 40px}h1{font-size:42px;font-weight:500;letter-spacing:-1px}
        p{color:#aaa;line-height:1.6}button{border:0;border-radius:8px;padding:12px 18px;background:#eee;color:#111;font:inherit;cursor:pointer}
        .stage{margin:34px 0;padding:30px;border:1px solid #444;border-radius:16px;background:#172432;transition:background .2s}
        .ball{width:44px;height:44px;background:#8ab8df;border-radius:50%;animation:move 2s ease-in-out infinite alternate}
        @keyframes move{to{transform:translateX(360px)}}.lower{margin-top:440px;padding:30px;border:1px solid #444;border-radius:16px}
        </style><main><p>SEREIN · LOCAL RECORDING DEMO</p><h1>Record just this page.</h1>
        <p>Click the record circle in Serein's toolbar. Change the scene, scroll, then stop and save an MP4.
        The sidebar, address bar and chat panel stay out of the recording.</p>
        <div class="stage" id="stage"><div class="ball"></div><p>Live page animation · <span id="clock">0</span> seconds</p></div>
        <button onclick="const s=document.getElementById('stage');s.style.background=s.style.background?'':'#3b2421'">Change scene color</button>
        <section class="lower"><h2>The viewport follows your scroll.</h2><p>This section appears in the video only after you scroll it into view.</p></section></main>
        <script>const start=performance.now();setInterval(()=>document.getElementById('clock').textContent=((performance.now()-start)/1000).toFixed(1),100)</script>
        """, baseURL: URL(string: tab.address))
    }
    if horizontalTabs { browser.tabs.first?.ext.pinned = true }
    // `--ui-sidebar-pinned`: the first two tabs pinned, so the sidebar shows its pinned tiles.
    if CommandLine.arguments.contains("--ui-sidebar-pinned") { browser.tabs.prefix(2).forEach { $0.ext.pinned = true } }
    // Every other screen names its section (`serein` is Serein full).
    browser.section = [
      "settings": ShellSection.start, "composer": ShellSection.browser,
      "setup": ShellSection.start, "phone": ShellSection.browser, "tasks": ShellSection.browser,
      "models": ShellSection.browser, "menu": ShellSection.browser, "ask": ShellSection.browser,
      "serein-side": ShellSection.browser, "connect": ShellSection.start, "search": ShellSection.serein,
    ][screen] ?? screen
    // The composer and models previews show a task tab (the ⌘E overlay is gone).
    if ["composer", "models"].contains(screen) { browser.section = ShellSection.thread }
    // `--ui-agents`: the Agents view in the main body, with the sidebar's Agents list.
    if CommandLine.arguments.contains("--ui-agents") { browser.section = ShellSection.agents }
    if screen == "phone" { browser.tabs.first?.address = "https://preview.invalid/notes/1" }
    if CommandLine.arguments.contains("--ui-update") { Updates.shared.previewPending("9.9.9") }
    if CommandLine.arguments.contains("--ui-tab-groups") { seedTabGroups(browser: browser) }
    if screen == "agent" { seedAgentTabs(browser: browser, agent: agent, now: now) }
    if screen == "tasks" || (["serein", "serein-side"].contains(screen)
      && CommandLine.arguments.contains("--ui-task-failed"))
    {
      try seedTaskPanel(browser: browser, agent: agent, now: now)
    }
    if CommandLine.arguments.contains("--ui-external-sessions") {
      ExternalSessionStore.shared.update([
        ExternalSession(id: "preview:1", driver: .codex, title: "Check running harness sessions", cwd: "/synthetic/serein", state: .running, updatedAt: now),
        ExternalSession(id: "preview:2", driver: .codex, title: "Locate the browser chat button", cwd: "/synthetic/serein", state: .needsUser, updatedAt: now),
        ExternalSession(id: "preview:3", driver: .opencode, title: "serein", cwd: "/synthetic/serein", state: .open, updatedAt: now),
      ])
    }
    if CommandLine.arguments.contains("--ui-agents") {
      // The Agents card: two sessions in other apps, past sessions on this Mac and a cloud task.
      ExternalSessionStore.shared.update([
        ExternalSession(id: "preview:a", driver: .claude, title: "Tidy the onboarding copy", cwd: "/synthetic/serein", state: .running, updatedAt: now),
        ExternalSession(id: "preview:b", driver: .codex, title: "Pick a chart library", cwd: "/synthetic/site", state: .needsUser, updatedAt: now.addingTimeInterval(-300)),
        ExternalSession(id: "preview:c", driver: .claude, title: "Ship the docs search", cwd: "/synthetic/docs", state: .open, updatedAt: now.addingTimeInterval(-900)),
      ], subagents: ["preview:a": [
        ExternalSubagent(id: "claude:s1", title: "Find every place the copy appears", state: nil, updatedAt: now.addingTimeInterval(-240)),
        ExternalSubagent(id: "claude:s2", title: "Rewrite the welcome steps", state: .running, updatedAt: now),
      ]])
      // Each pull request mark without running gh.
      PullRequestStore.shared.installPreview([
        .folder("/synthetic/serein"): PullRequestLookup.Info(number: 212, url: "https://github.com/serein/serein/pull/212", state: .open),
        .folder("/synthetic/site"): PullRequestLookup.Info(number: 88, url: "https://github.com/serein/site/pull/88", state: .conflict),
        .folder("/synthetic/docs"): PullRequestLookup.Info(number: 41, url: "https://github.com/serein/docs/pull/41", state: .merged),
      ])
      SessionHistoryStore.shared.installPreview(
        SessionHistory(sessions: [
          "/preview/1": DiscoveredSession(provider: "claude", id: "p1", cwd: "/synthetic/serein", title: "Fix the sidebar spacing", date: now.addingTimeInterval(-3600)),
          "/preview/2": DiscoveredSession(provider: "codex", id: "p2", cwd: "/synthetic/site", title: "Speed up the start page", date: now.addingTimeInterval(-7200)),
          "/preview/3": DiscoveredSession(provider: "claude", id: "p3", cwd: "/synthetic/serein", title: "Review the release notes", date: now.addingTimeInterval(-86_400)),
        ]),
        cloud: [CloudTask(id: "t1", title: "Fix the flaky upload test", status: "ready", url: "https://chatgpt.com/codex/tasks/t1", environment: "serein", updatedAt: now.addingTimeInterval(-1800))])
    }
    // `--ui-agent-list`: a full Agents list (many sessions in two projects, sub-threads with their
    // own transcripts), to review its order and its quiet rows. Synthetic files in the preview's library.
    if CommandLine.arguments.contains("--ui-agent-list") { try seedAgentList(browser: browser, now: now) }
    if CommandLine.arguments.contains("--ui-history-active-task") {
      guard screen == "settings" else { throw SereinError.invalid("The history task fixture requires the settings preview") }
      // A permission-free, isolated capability: no process, provider or page is started.
      // This exercises Clear's active-task restriction in the native settings sheet.
      _ = try browser.beginTask(isolated: true, allowActions: false, includeCurrent: false)
    }
    if screen == "models" {
      // Synthetic catalog so the picker has rows to show; nothing here names a real product tier.
      CodexCatalog.shared.update([
        ModelChoice(model: "preview-codex-fast", name: "Preview Codex Fast", tier: .fastest, blurb: "Synthetic."),
        ModelChoice(model: "preview-codex-deep", name: "Preview Codex Deep", tier: .deepest, blurb: "Synthetic."),
      ])
    }
    if screen == "composer" || screen == "models" {
      agent.draft = "Compare these workspace ideas and suggest a clearer hierarchy.\nThen check spacing and keyboard navigation at the smaller window size."
      // `--ui-destination project|web|library|mac`: the Ask box with that chip beside its +.
      if let index = CommandLine.arguments.firstIndex(of: "--ui-destination"), index + 1 < CommandLine.arguments.count {
        let destination: TaskMode? = [
          "project": .project, "web": .research, "library": .library, "mac": .anywhere,
        ][CommandLine.arguments[index + 1]]
        if let destination {
          agent.mode = destination
          agent.projectID = destination == .project ? browser.projects.first?.id : nil
        }
      }
    }
    // History fixtures stay in the marked temporary library. A preview never discovers the
    // user's sessions, changes discovery consent, or makes an executable available.
    if historySegment != nil || ["history", "projects"].contains(screen) {
      try seedHistory(browser: browser, agent: agent, now: now)
    }
    if let segment = historySegment { browser.section = segment.section }
    if readyToSend {
      let tasks = agent.conversations.prefix(5).enumerated().map { index, thread in
        PendingTask(id: "preview-offline-\(index + 1)", threadID: thread.id,
          prompt: ["Review the workspace hierarchy", "Compare the onboarding research",
                   "Check keyboard navigation", "Trace the library reading flow",
                   "Prepare the fifth offline task for review"][index],
          provider: thread.provider.rawValue, mode: thread.mode.rawValue, projectID: thread.projectID,
          model: thread.model ?? "", effort: thread.effort ?? "medium",
          createdAt: now.addingTimeInterval(-Double(5 - index) * 600))
      }
      agent.flow.previewReadyTasks(tasks)
      precondition(agent.flow.restoredTasks.count == 5)
    }
    if CommandLine.arguments.contains("--ui-serein-past-chats") {
      seedPastChats(agent: agent, now: now)
    }
    precondition(browser.projects.count >= 20 && agent.conversations.count >= 8)
    precondition(!browser.historyEnabled && agent.available.isEmpty)
  }

  /// Every source pill and several calendar groups, plus completed Activity records whose
  /// raw model IDs can be disclosed. No run or subprocess is started.
  @MainActor private func seedHistory(browser: BrowserModel, agent: AgentModel, now: Date) throws {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: now)
    let days = [0, 0, 1, 1, 2, 3, 8, 14, 0, 1]
    for index in agent.conversations.indices {
      let offset = days[index % days.count]
      let date = offset == 0 ? max(today, now.addingTimeInterval(-Double(index) * 10))
        : (calendar.date(byAdding: .day, value: -offset, to: today) ?? today).addingTimeInterval(12 * 3600)
      agent.conversations[index].updatedAt = date
      agent.conversations[index].lastMessageAt = date
      // Leave the first five as project tasks for the offline card's Send and Edit actions.
      if index >= 7 {
        agent.conversations[index].serein = true
        agent.conversations[index].projectID = nil
        agent.conversations[index].mode = .anywhere
      }
    }
    try browser.library.save(agent.conversations, to: "sessions/threads.json")
    let project = browser.projects[0]
    if !CommandLine.arguments.contains("--ui-project-chats"), !CommandLine.arguments.contains("--ui-agents") {
      ExternalSessionStore.shared.update([
      ExternalSession(id: "claude:history-running", driver: .claude, title: "Tidy the onboarding copy",
        cwd: project.path, state: .running, updatedAt: now),
    ])
    SessionHistoryStore.shared.installPreview(SessionHistory(sessions: [
      "/preview/history/claude": DiscoveredSession(provider: "claude", id: "history-claude",
        cwd: project.path, title: "Review the release notes", date: now.addingTimeInterval(-3600)),
      "/preview/history/codex": DiscoveredSession(provider: "codex", id: "history-codex",
        cwd: project.path, title: "Make the start page faster", date: today.addingTimeInterval(-3600)),
    ]), cloud: [CloudTask(id: "preview-history-cloud", title: "Check the upload retry test", status: "ready",
      url: "https://chatgpt.com/codex/tasks/preview-history-cloud", environment: project.name,
      updatedAt: now.addingTimeInterval(-1800))])
    }
    // The dedicated Projects fixture already seeded running/waiting markers.
    for (index, thread) in agent.conversations.prefix(screen == "projects" ? 0 : 6).enumerated() {
      let started = max(today, now.addingTimeInterval(-Double(index + 1) * 300))
      var record = RunRecord(id: "preview-history-run-\(index)", threadID: thread.id,
        provider: thread.provider.rawValue, model: "preview-\(thread.provider.rawValue)-model-2026-10",
        effort: "high", mode: thread.mode.rawValue, projectID: thread.projectID,
        projectName: browser.projects.first { $0.id == thread.projectID }?.name,
        title: thread.title, startedAt: started)
      record.endedAt = started.addingTimeInterval(90)
      record.lastEventAt = record.endedAt ?? started
      record.outcome = .done
      record.toolCount = index + 2
      record.summary = "Finished the synthetic layout review."
      try browser.library.appendRun(record)
    }
    ProjectActivityStore.shared.prime(library: browser.library)
  }

  /// The Past chats flag works alone as well as beside --ui-serein-chat or --ui-serein-busy.
  /// These saved chats also allow a manual check of read-only opening while Serein replies.
  @MainActor private func seedPastChats(agent: AgentModel, now: Date) {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: now)
    let titles = ["Plan the design review", "Find ramen for dinner", "Compare the weekend reading list"]
    for (index, title) in titles.enumerated() {
      let date = index == 0 ? now
        : (calendar.date(byAdding: .day, value: index == 1 ? -1 : -8, to: today) ?? today).addingTimeInterval(12 * 3600)
      var chat = Conversation(id: "preview-serein-past-\(index)", title: title,
        messages: [AgentMessage(role: "you", text: title),
                   AgentMessage(role: "assistant", text: "Here are the notes from our earlier synthetic chat.")],
        provider: .claude, mode: .anywhere, projectID: nil, remoteID: nil, scope: "", updatedAt: date)
      chat.lastMessageAt = date
      chat.serein = true
      agent.conversations.append(chat)
    }
  }

  /// Tabs of two sites, mixed up, then grouped by site as with no helper agent: the groups come
  /// together, with their labels, and the lone tab stays after them.
  @MainActor private func seedTabGroups(browser: BrowserModel) {
    let pages = [
      ("Pull requests · serein", "https://github.com/serein/serein/pulls"),
      ("Tab groups land in Serein", "https://news.example.com/serein-tab-groups"),
      ("Issues · serein", "https://github.com/serein/serein/issues"),
      ("The Swift Programming Language", "https://docs.swift.org/swift-book/"),
      ("Browsers rethink the tab", "https://news.example.com/rethink-tabs"),
    ]
    browser.tabs += pages.map { title, address in
      let tab = BrowserTab(store: .nonPersistent())
      tab.web.loadHTMLString(Self.page(title: title), baseURL: URL(string: address))
      tab.title = title
      tab.address = address
      return tab
    }
  }
  /// An agent tab that finished (banner, docked task, status bubble), one still working, and a
  /// kept tab with its outcome bar. Synthetic: no run starts and no provider is called.
  @MainActor private func seedAgentTabs(browser: BrowserModel, agent: AgentModel, now: Date) {
    let board = browser.agentTabs
    let threads = agent.conversations
    func agentTab(_ task: String, title: String, host: String, letter: String, color: NSColor)
      -> BrowserTab
    {
      let tab = BrowserTab(privateMode: true, owner: task, store: .nonPersistent())
      tab.web.loadHTMLString(Self.page(title: title), baseURL: URL(string: "https://\(host)/"))
      tab.title = title
      tab.address = "https://\(host)/"
      FaviconStore.shared.seedPreview(host: host, letter: letter, color: color)
      return tab
    }
    let done = agentTab("preview-task-1", title: "Release checklist", host: "checklist.preview.invalid",
      letter: "C", color: NSColor(red: 0.92, green: 0.55, blue: 0.20, alpha: 1))
    board.opened(done, task: "preview-task-1", isolated: true)
    board.describePreview(task: "preview-task-1", agent: "Codex", threadID: threads[0].id,
      title: threads[0].title,
      steps: [AgentStep(time: now.addingTimeInterval(-40), tool: "open", label: "Opened checklist.preview.invalid"),
        AgentStep(time: now.addingTimeInterval(-22), tool: "read", label: "Read the page"),
        AgentStep(time: now.addingTimeInterval(-5), tool: "finish", label: "Finished")],
      startedAt: now.addingTimeInterval(-41))
    board.finished(task: "preview-task-1", outcome: "done",
      summary: "Opened the release checklist. Every item has an owner.", result: done)
    _ = board.taskEnded("preview-task-1", tabs: [])
    let working = agentTab("preview-task-2", title: "Support feedback", host: "support.preview.invalid",
      letter: "S", color: NSColor(red: 0.55, green: 0.40, blue: 0.95, alpha: 1))
    board.opened(working, task: "preview-task-2", isolated: true)
    board.describePreview(task: "preview-task-2", agent: "Claude", threadID: threads[1].id,
      title: threads[1].title,
      steps: [AgentStep(time: now.addingTimeInterval(-12), tool: "open", label: "Opened support.preview.invalid")],
      startedAt: now.addingTimeInterval(-12))
    if browser.tabs.count > 1 {
      browser.tabs[1].agentMark = TabAgentMark(agent: "Codex", threadID: threads[2].id,
        taskID: "preview-task-0", title: threads[2].title,
        summary: "Collected the keyboard findings into one list.", status: .needsYou,
        startedAt: now.addingTimeInterval(-600), endedAt: now.addingTimeInterval(-540), steps: [])
    }
    browser.viewAgentTab(done)
  }

  @MainActor private func seedAgentList(browser: BrowserModel, now: Date) throws {
    guard let root = ProcessInfo.processInfo.environment["SEREIN_DATA_DIR"], browser.projects.count >= 2 else { return }
    let folder = URL(fileURLWithPath: root).appendingPathComponent("agent-list", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // Sessions in a temporary folder are left out of the list (ProjectChatIndex), and the library is one.
    let (first, second) = ("/synthetic/agent-list/first", "/synthetic/agent-list/second")
    browser.projects[0].path = first
    browser.projects[1].path = second
    func transcript(_ name: String, asked: String, answer: String, sidechain: Bool = true, cwd: String = "/synthetic/agent-list/first") throws -> String {
      let lines = [
        #"{"type":"user","cwd":"\#(cwd)","isSidechain":\#(sidechain),"message":{"role":"user","content":"\#(asked)"}}"#,
        #"{"type":"assistant","cwd":"\#(cwd)","isSidechain":\#(sidechain),"message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"\#(answer)"}]}}"#,
      ]
      let file = folder.appendingPathComponent(name + ".jsonl")
      try Data(lines.joined(separator: "\n").utf8).write(to: file)
      return file.path
    }
    let rows: [(id: String, driver: HarnessDriver, title: String, cwd: String, state: ExternalSession.State, ago: TimeInterval)] = [
      ("claude:one", .claude, "Tidy the onboarding copy", first, .running, 20),
      ("claude:two", .claude, "Why does the build use so much memory", first, .open, 600),
      ("codex:three", .codex, "Pick a chart library", first, .needsUser, 300),
      ("claude:four", .claude, "Review the release notes", first, .open, 1200),
      ("codex:five", .codex, "Speed up the start page", first, .running, 60),
      ("claude:six", .claude, "Ship the docs search", first, .open, 4000),
      ("claude:seven", .claude, "Fix the flaky upload test", second, .open, 90),
      ("opencode:eight", .opencode, "Rewrite the settings page", second, .running, 15),
      ("claude:nine", .claude, "Add dark mode to the site", second, .open, 9000),
    ]
    var sessions: [ExternalSession] = []
    for row in rows {
      var session = ExternalSession(id: row.id, driver: row.driver, title: row.title, cwd: row.cwd, state: row.state,
                                    updatedAt: now.addingTimeInterval(-row.ago))
      session.log = try transcript("session-" + row.id.replacingOccurrences(of: ":", with: "-"), asked: row.title, answer: "Working on it.", sidechain: false, cwd: row.cwd)
      sessions.append(session)
    }
    ExternalSessionStore.shared.update(sessions, subagents: ["claude:one": [
      ExternalSubagent(id: "claude:s1", title: "Find every place the copy appears", state: nil, updatedAt: now.addingTimeInterval(-240),
                       log: try transcript("s1", asked: "Find every place the copy appears", answer: "It shows in **three** places.")),
      ExternalSubagent(id: "claude:s2", title: "Rewrite the welcome steps", state: .running, updatedAt: now,
                       log: try transcript("s2", asked: "Rewrite the welcome steps", answer: "Rewriting step two now.")),
    ]])
  }

  /// Three tasks (two running, one that needs you; the `tasks` preview makes them Serein’s): a
  /// running Codex task with its Now line, steps, a page it uses, and an edit card and approval
  /// card inline in the transcript. Synthetic: no process starts and no provider is called.
  @MainActor private func seedTaskPanel(browser: BrowserModel, agent: AgentModel, now: Date) throws {
    let threads = agent.conversations
    let projects = browser.projects
    func spec(_ thread: Conversation, provider: Provider, model: String, mode: TaskMode,
      project: Project?, grants: RunGrants) -> RunSpec
    {
      RunSpec(threadID: thread.id, provider: provider, executable: "/usr/bin/false", model: model,
        effort: "high", mode: mode, projectID: project?.id, projectName: project?.name,
        title: thread.title, scope: "Synthetic preview", autoRouting: false, grants: grants,
        limits: RunLimits(hard: nil, idle: 3600))
    }
    // A: Claude researching on the web, just started.
    let research = AgentRun(
      spec: spec(threads[3], provider: .claude, model: "claude-opus-4-1", mode: .research, project: nil,
        grants: RunGrants(actions: false, signIns: false)),
      taskID: "preview-task-a", transcript: threads[3].messages)
    research.record.startedAt = now.addingTimeInterval(-9)
    research.phase = "Reading the request"
    // B: Codex editing a project, with a browser step, CLI steps (one failed) and tokens.
    let project = projects[2]
    let turnOne = AgentMessage(id: "preview-b-assistant-1", role: "assistant",
      text: "I moved the onboarding copy into one strings file and tightened the empty state. Two edits still need your approval.")
    let transcript = [
      AgentMessage(id: "preview-b-user-1", role: "you", text: threads[2].title), turnOne,
      AgentMessage(id: "preview-b-user-2", role: "you", text: "Also run the tests and fix anything that fails."),
      AgentMessage(id: "preview-b-assistant-2", role: "assistant", text: "Running the onboarding tests now."),
    ]
    let coding = AgentRun(
      spec: spec(threads[2], provider: .codex, model: "gpt-5.1-codex", mode: .project, project: project,
        grants: RunGrants(actions: false, edits: true, projectName: project.name)),
      taskID: "preview-task-b", transcript: transcript)
    coding.record.startedAt = now.addingTimeInterval(-134)
    coding.record.tokens = 18_400
    coding.record.toolCount = 8
    coding.phase = "Editing files"
    let labels: [(TimeInterval, String, String, String?)] = [
      (-130, "read", "Read README.md", nil), (-118, "search", "Searched for “onboarding”", nil),
      (-96, "read", "Read Sources/Onboarding/Flow.swift", nil),
      (-70, "edit", "Edited Sources/Onboarding/Flow.swift", nil),
      (-52, "test", "Ran tests", "Exited with an error"),
      (-30, "edit", "Edited Sources/Onboarding/Strings.swift", nil), (-12, "test", "Ran tests", nil),
    ]
    coding.steps = labels.map { offset, tool, label, failed in
      var step = AgentStep(time: now.addingTimeInterval(offset), tool: tool, label: label)
      step.failed = failed
      return step
    }
    coding.now = "Editing Sources/Onboarding/Flow.swift"
    coding.nowAt = now.addingTimeInterval(-3)
    let tab = BrowserTab(privateMode: true, owner: "preview-task-b", store: .nonPersistent())
    tab.web.loadHTMLString(Self.page(title: "Onboarding guide"), baseURL: URL(string: "https://guide.preview.invalid/"))
    tab.title = "Onboarding guide"
    tab.address = "https://guide.preview.invalid/"
    FaviconStore.shared.seedPreview(host: "guide.preview.invalid", letter: "G",
      color: NSColor(red: 0.20, green: 0.55, blue: 0.85, alpha: 1))
    browser.agentTabs.opened(tab, task: "preview-task-b", isolated: true)
    browser.agentTabs.describePreview(task: "preview-task-b", agent: "Codex", threadID: threads[2].id,
      title: threads[2].title,
      steps: [AgentStep(time: now.addingTimeInterval(-100), tool: "navigate", label: "Went to guide.preview.invalid")],
      startedAt: now.addingTimeInterval(-134))
    // C: Claude finished and waits for an answer.
    let waiting = AgentRun(
      spec: spec(threads[1], provider: .claude, model: "claude-sonnet-4-5", mode: .project, project: projects[1],
        grants: RunGrants(projectName: projects[1].name)),
      taskID: "preview-task-c", transcript: Array(threads[1].messages.dropLast()))
    waiting.record.startedAt = now.addingTimeInterval(-620)
    waiting.record.endedAt = now.addingTimeInterval(-200)
    waiting.record.outcome = .waiting
    waiting.record.summary = "Should the shortcuts help page change too?"
    waiting.reportedSummary = """
      Should the shortcuts help page change too?

      Reply with “Update the help page” or “Keep the current page” so I can finish the copy review.
      """
    waiting.record.attentionDetail = RunAttention.detail(outcome: .waiting, reported: waiting.reportedSummary)
    var runs = [research, coding, waiting]
    if CommandLine.arguments.contains("--ui-task-failed") {
      // No assistant answer for this turn: the error alone must explain what happened.
      let failed = AgentRun(
        spec: spec(threads[5], provider: .codex, model: "gpt-5.1-codex", mode: .project, project: projects[5],
          grants: RunGrants(projectName: projects[5].name)),
        taskID: "preview-task-failed", transcript: Array(threads[5].messages.dropLast()))
      failed.record.startedAt = now.addingTimeInterval(-90)
      failed.record.endedAt = now.addingTimeInterval(-30)
      failed.record.lastEventAt = now.addingTimeInterval(-30)
      failed.record.outcome = .stuck
      failed.error = """
        Connection to the AI app closed before a reply arrived.

        The request could not reach the local Codex connection. Reconnect the AI app, then choose Try again to send a new run.
        """
      failed.record.summary = "Connection to the AI app closed before a reply arrived."
      failed.record.attentionDetail = RunAttention.detail(outcome: .stuck, error: failed.error)
      runs.append(failed)
    }
    for run in runs {
      agent.hub.adoptPreview(run)
      if let index = agent.conversations.firstIndex(where: { $0.id == run.spec.threadID }) {
        agent.conversations[index].messages = run.transcript
      }
      // Seed the ledger before SereinTray attaches, then remove the ended run from memory.
      // This exercises exactly the record and transcript a reopened task reads.
      if CommandLine.arguments.contains("--ui-task-restored"), !run.isActive {
        try browser.library.appendRun(run.record)
        agent.hub.dismiss(run)
      }
    }
    try browser.library.save(agent.conversations, to: "sessions/threads.json")
    EditReview.shared.seedPreview([
      TurnReview(id: "preview-review-1", threadID: threads[2].id, messageID: turnOne.id,
        projectID: project.id, projectName: project.name, folder: project.path, state: .ready,
        files: [DiffFile(path: "Sources/Onboarding/Flow.swift", added: 42, removed: 18),
          DiffFile(path: "Sources/Onboarding/Strings.swift", added: 27, removed: 0),
          DiffFile(path: "Tests/OnboardingTests.swift", added: 9, removed: 3)],
        approvals: [PendingApproval(id: "preview-approval-1", tool: "Edit", target: "Package.swift"),
          PendingApproval(id: "preview-approval-2", tool: "Write", target: "Resources/Onboarding.strings")],
        endedAt: now.addingTimeInterval(-80)),
    ])
    // `--ui-edit-held`: Allow once was pressed while Codex works, so it waits for the step to
    // end (`--ui-edit-held reply` instead opens the Decline reply, its Send enabled).
    if let i = CommandLine.arguments.firstIndex(of: "--ui-edit-held") {
      let variant = CommandLine.arguments.indices.contains(i + 1) ? CommandLine.arguments[i + 1] : ""
      let resolution: TurnReview.Resolution?
      switch variant {
      case "reply": resolution = nil
      case "always": resolution = .alwaysAllowed
      case "decline": resolution = .denied
      default: resolution = .allowedOnce
      }
      if let resolution {
        EditReview.shared.seedHeldPreview(reviewID: "preview-review-1", threadID: threads[2].id, resolution)
      }
    }
  }
  /// `--ui-ask-before every|risky`.
  static var askBefore: ApprovalLevel {
    guard let i = CommandLine.arguments.firstIndex(of: "--ui-ask-before"),
      CommandLine.arguments.indices.contains(i + 1)
    else { return .everyStep }
    return CommandLine.arguments[i + 1] == "risky" ? .riskyOnly : .everyStep
  }

  private func browserImportFixtures() throws -> [BrowserImportProfile] {
    let base = root.appendingPathComponent("Fixtures/browser-import", isDirectory: true)
    let chrome = base.appendingPathComponent("Chrome/Default", isDirectory: true)
    let safari = base.appendingPathComponent("Safari", isDirectory: true)
    let firefox = base.appendingPathComponent("Firefox", isDirectory: true)
    let arc = base.appendingPathComponent("Arc", isDirectory: true)
    for folder in [chrome, safari, firefox, arc] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    let chromeBookmarks = chrome.appendingPathComponent("Bookmarks")
    try JSONSerialization.data(
      withJSONObject: [
        "roots": [
          "bookmark_bar": [
            "children": [
              ["type": "url", "name": "Serein import guide", "url": "https://fixture.invalid/import-guide"],
              ["type": "url", "name": "Workspace notes", "url": "https://fixture.invalid/workspace-notes"],
            ]
          ]
        ]
      ], options: [.prettyPrinted, .sortedKeys]
    ).write(to: chromeBookmarks, options: .atomic)
    let chromeHistory = chrome.appendingPathComponent("History")
    try makeSQLite(
      chromeHistory,
      sql: """
        CREATE TABLE urls(url TEXT,title TEXT,last_visit_time INTEGER);
        INSERT INTO urls VALUES('https://fixture.invalid/chrome-history','Chrome history fixture',13435977600000000);
        """)

    let safariBookmarks = safari.appendingPathComponent("Bookmarks.plist")
    let plist: [String: Any] = [
      "Children": [
        [
          "URLString": "https://fixture.invalid/safari-saved",
          "URIDictionary": ["title": "Safari saved fixture"],
        ]
      ]
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
      .write(to: safariBookmarks, options: .atomic)
    let safariHistory = safari.appendingPathComponent("History.db")
    try makeSQLite(
      safariHistory,
      sql: """
        CREATE TABLE history_items(id INTEGER,url TEXT);
        CREATE TABLE history_visits(history_item INTEGER,title TEXT,visit_time REAL);
        INSERT INTO history_items VALUES(1,'https://fixture.invalid/safari-history');
        INSERT INTO history_visits VALUES(1,'Safari history fixture',780000000);
        """)

    let places = firefox.appendingPathComponent("places.sqlite")
    try makeSQLite(
      places,
      sql: """
        CREATE TABLE moz_places(id INTEGER,url TEXT,title TEXT,last_visit_date INTEGER);
        CREATE TABLE moz_bookmarks(type INTEGER,fk INTEGER,title TEXT,dateAdded INTEGER);
        INSERT INTO moz_places VALUES(1,'https://fixture.invalid/firefox','Firefox fixture',1760000000000000);
        INSERT INTO moz_bookmarks VALUES(1,1,'Firefox saved fixture',1760000000000000);
        """)

    let sidebar = arc.appendingPathComponent("StorableSidebar.json")
    try JSONSerialization.data(
      withJSONObject: [
        "sidebar": [
          "containers": [
            [
              "items": [
                [
                  "data": [
                    "tab": [
                      "savedTitle": "Arc pinned fixture",
                      "savedURL": "https://fixture.invalid/arc-pinned",
                    ]
                  ]
                ]
              ]
            ]
          ]
        ]
      ], options: [.prettyPrinted, .sortedKeys]
    ).write(to: sidebar, options: .atomic)

    return [
      BrowserImportProfile(
        browser: "Chrome preview", profile: "Default", directory: chrome,
        bookmarks: chromeBookmarks, history: chromeHistory, bookmarkFormat: .chromiumJSON),
      BrowserImportProfile(
        browser: "Safari preview", profile: "Personal", directory: safari,
        bookmarks: safariBookmarks, history: safariHistory, bookmarkFormat: .safariPlist),
      BrowserImportProfile(
        browser: "Firefox preview", profile: "Synthetic", directory: firefox,
        bookmarks: places, history: places, bookmarkFormat: .firefoxSQLite),
      BrowserImportProfile(
        browser: "Arc preview", profile: "Pinned", directory: arc,
        bookmarks: sidebar, history: nil, bookmarkFormat: .arcSidebarJSON),
    ]
  }

  private func makeSQLite(_ url: URL, sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
      if let database { sqlite3_close(database) }
      throw SereinError.invalid("Could not create synthetic browser database")
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw SereinError.invalid("Could not seed synthetic browser database")
    }
  }

  private static func page(title: String) -> String {
    """
    <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
    <style>body{margin:0;background:#f0f1ed;color:#25322e;font:16px system-ui}main{max-width:720px;margin:72px auto;padding:32px}small{color:#6d7770}h1{font-size:36px;font-weight:500;letter-spacing:-1px}.card{padding:24px;margin-top:16px;background:#fff;border:1px solid #d7ddd5;border-radius:8px}h2{font-size:18px;font-weight:500}p{line-height:1.65;color:#647168}</style>
    </head><body><main><small>FIELDNOTES · SYNTHETIC PREVIEW</small><h1>Make room for good ideas.</h1><p>\(title). A local page for reviewing Serein's native browser pane.</p>
    <section class="card"><h2>A calmer workspace</h2><p>Keep the active task, its sources, and the next useful action within reach.</p></section>
    <section class="card"><h2>Next steps</h2><p>Review the flow, check long names, and verify compact controls.</p></section>
    <section class="card"><h2>Progress</h2><p>This document contains synthetic content and loads no external resources.</p></section></main></body></html>
    """
  }

  @MainActor func presentAndCapture(window: NSWindow, browser: BrowserModel, agent: AgentModel) async {
    #if DEBUG
      if CommandLine.arguments.contains("--ui-agents-live") { await Self.loadLiveAgents(agent: agent) }
      if CommandLine.arguments.contains("--ui-projects-live") { await Self.loadLiveProjects(browser: browser, agent: agent) }
    #endif
    if let index = CommandLine.arguments.firstIndex(of: "--ui-agents-tab"), index + 1 < CommandLine.arguments.count {
      SessionHistoryStore.shared.previewTab = CommandLine.arguments[index + 1]
    }
    try? await Task.sleep(nanoseconds: 300_000_000)
    if ["setup", "models", "settings"].contains(screen) { HarnessRegistry.shared.installSyntheticPreview() }
    if screen == "settings" { browser.showSettings = true }
    if screen == "connect" {
      browser.showMarketplace = true
      // `--ui-marketplace-place yours|mac|plugins|teams`: the Marketplace on that page. A name the old
      // Settings pages had (`Connections`, `Plugins`, `Mail`) opens where it moved, as a link would.
      let arguments = CommandLine.arguments
      if let index = arguments.firstIndex(of: "--ui-marketplace-place"), index + 1 < arguments.count {
        let named = arguments[index + 1]
        let places: [String: MarketplacePlace] = ["yours": .yours, "mac": .mac, "plugins": .plugins, "teams": .teams]
        if let place = places[named] ?? SettingsCategory.moved(named) { browser.marketplacePlace = place }
      }
    }
    if screen == "search" { SearchPaletteCenter.shared.open = true }
    // affectUI lane 6, only in memory.
    // `--ui-affect-cited-answer` (`--ui-preview thread`): a reply whose claims cite their pages;
    // add `open` to light each paragraph's first claim and unfold its page.
    // `--ui-affect-usage-meter` (`--ui-preview settings --ui-settings-section Usage`): this
    // month on two models against their warn levels, one near it and one past it.
    if screen == "thread", CommandLine.arguments.contains("--ui-affect-cited-answer") {
      agent.conversationID = "preview-cited"
      agent.messages = [
        AgentMessage(role: "you", text: "Why does my laptop battery wear out, and what slows it down?"),
        AgentMessage(role: "assistant", text: """
          Heat and long hours at full charge wear a battery fastest [1]. Holding the charge near 80% \
          slows that wear, and some laptops can do it for you [2]. Shallow top-ups are gentler than \
          running it flat ([Cell notes](https://cells.example.invalid/depth)).

          - Keep it out of hot cars and off soft bedding [1][3].
          - Unplugging often does not help on its own [2].

          1. [How heat ages a battery](https://power.example.invalid/heat)
          2. [Charge limits explained](https://charge.example.invalid/limits)
          3. https://care.example.invalid/storage
          """),
      ]
    }
    if CommandLine.arguments.contains("--ui-affect-usage-meter") { RouteUsage.shared.previewMeters() }
    if screen == "models" {
      if CommandLine.arguments.contains("--ui-model-arrival") {
        // A Claude thread on an older model; Claude Fable 5.1 arrives in Claude Code's list.
        agent.provider = .claude
        agent.model = "claude-opus-4-8"
        let registry = HarnessRegistry.shared
        // Claude Code's own update check found a newer release: the search bar offers it.
        var snapshots = registry.snapshots
        if var claude = snapshots[.claude] {
          claude.version = "2.1.301"
          claude.latestVersion = "2.1.302"
          claude.needsUpdate = true
          (claude.status, claude.message) = HarnessSnapshot.summarize(claude, name: "Claude Code")
          snapshots[.claude] = claude
        }
        registry.installPreview(snapshots, settings: registry.settings)
        let ids = registry.models(.claude).map(\.id)
        var watch = ModelWatch()
        _ = watch.record(Provider.claude.rawValue, ids: ids.filter { $0 != "claude-fable-5-1" }, now: Date())
        _ = watch.record(Provider.claude.rawValue, ids: ids, now: Date())
        registry.watch = watch
        agent.modelsListed(.claude, arrived: registry.models(.claude).filter { $0.id == "claude-fable-5-1" })
      }
      NotificationCenter.default.post(name: Notification.Name("SereinPreviewModels"), object: nil)
    }
    if screen == "phone" {
      NotificationCenter.default.post(name: Notification.Name("SereinPreviewPhoneHandoff"), object: nil)
    }
    if screen == "thread" {
      if CommandLine.arguments.contains("--ui-actions") {
        let picture = NSImage(size: NSSize(width: 420, height: 110))
        picture.lockFocus()
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 420, height: 110).fill()
        ("Synthetic screenshot · upload complete" as NSString).draw(at: NSPoint(x: 20, y: 46),
          withAttributes: [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.white])
        picture.unlockFocus()
        let path = picture.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
          .representation(using: .png, properties: [:]).flatMap { browser.saveChatPicture($0) }
        agent.conversationID = "preview-actions"
        agent.messages = [
          AgentMessage(role: "you", text: "Check the upload and show what you did."),
          AgentMessage(role: "assistant", text: "", images: path.map { [$0] }, activities: [
            TranscriptActivity(id: "read", tool: "read", label: "Read Sources/Upload.swift"),
            TranscriptActivity(id: "test", tool: "test", label: "Ran tests"),
          ]),
          AgentMessage(role: "assistant", text: "The upload completed and all tests passed."),
        ]
      }
      // A long chat, which opens on its newest messages (TranscriptWindow).
      if CommandLine.arguments.contains("--ui-long-thread") {
        agent.messages = (1...400).flatMap { turn in
          [AgentMessage(role: "you", text: "Synthetic question \(turn)"),
           AgentMessage(role: "assistant", text: "Synthetic answer \(turn), with **some** markdown and `code` in it.")]
        }
      }
      #if DEBUG
        // `--ui-swarm-line`: a chat whose lead started a swarm of 13 bots. `--ui-swarm-board`: its
        // board open over the chat.
        let swarmBoard = CommandLine.arguments.contains("--ui-swarm-board")
        if swarmBoard || CommandLine.arguments.contains("--ui-swarm-line") {
          agent.conversationID = "preview-swarm"
          agent.messages = [
            AgentMessage(role: "you", text: "Move the swarm prompts into one file and add a live board for each swarm."),
            SwarmBoards.shared.seedPreview(room: agent.conversationID, open: swarmBoard),
            AgentMessage(role: "assistant", text: "I split this into eight parts and started a worker on each, with a verifier. Six have finished so far."),
          ]
        }
      #endif
      // Three threads open as tabs, the shown one last.
      for thread in agent.conversations.prefix(3) where thread.id != agent.conversationID {
        agent.showThreadTab(thread.id)
      }
      agent.showThreadTab(agent.conversationID)
      #if DEBUG
        if CommandLine.arguments.contains("--ui-linked") {
          // A Codex chat from another app, open in Serein while Codex still works on it there.
          agent.messages = [
            AgentMessage(role: "you", text: "Why does the upload test fail on CI but pass here?"),
            AgentMessage(role: "assistant", text: "The test waits a fixed 2 seconds for the upload to finish. CI machines are slower, so the wait runs out first. Waiting for the upload's own completion event fixes it."),
            AgentMessage(role: "you", text: "Make that change and run the whole suite."),
          ]
          // `--ui-linked grok`: a chat Serein follows but cannot reply to.
          let index = CommandLine.arguments.firstIndex(of: "--ui-linked")! + 1
          let driver = (CommandLine.arguments.indices.contains(index) ? HarnessDriver(rawValue: CommandLine.arguments[index]) : nil) ?? .codex
          agent.previewLink(SessionLink(driver: driver.rawValue, nativeID: "preview-linked"))
          ExternalSessionStore.shared.update([
            ExternalSession(id: "\(driver.rawValue):preview-linked", driver: driver, title: "Fix the flaky upload test",
              cwd: "/synthetic/serein", state: .running, updatedAt: Date()),
          ])
        }
        // `--ui-linked-file claude <file>` or `--ui-linked-file codex <thread id>`: a real chat from
        // that app, read and shown as an opened chat is, to check how its messages look. Codex is
        // found through SEREIN_PREVIEW_CODEX, since a preview checks no AI app.
        if let index = CommandLine.arguments.firstIndex(of: "--ui-linked-file"), index + 2 < CommandLine.arguments.count,
          let driver = HarnessDriver(rawValue: CommandLine.arguments[index + 1]) {
          let target = CommandLine.arguments[index + 2]
          let link = driver == .codex ? SessionLink(driver: driver.rawValue, nativeID: target)
            : SessionLink(driver: driver.rawValue, nativeID: URL(fileURLWithPath: target).deletingPathExtension().lastPathComponent,
                          file: target)
          agent.previewLink(link)
          do {
            let history = try await LinkedSessionMonitor.read(link, codex: ProcessInfo.processInfo.environment["SEREIN_PREVIEW_CODEX"])
            agent.showLinked(history)
            // What was read, beside the capture: each message's role, words and steps.
            let dump: [[String: Any]] = history.messages.map {
              ["role": $0.role, "text": $0.text, "steps": $0.activities.map { "\($0.tool): \($0.label)\($0.failed ? " (failed)" : "")" }]
            }
            if let root = ProcessInfo.processInfo.environment["SEREIN_DATA_DIR"],
              let data = try? JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted]) {
              try? data.write(to: URL(fileURLWithPath: root).appendingPathComponent("linked-dump.json"))
            }
          } catch {
            print("LINKED FAILED: \(error.localizedDescription)")
          }
        }
      #endif
      // `--ui-new-task`: a new task, before its first message, in the first project.
      if CommandLine.arguments.contains("--ui-new-task"), let project = browser.projects.first {
        agent.clear()
        agent.selectProject(project.id)
      }
    }
    if screen == "ask" { ComposerContext.shared.openAsk(browser: browser) }
    if screen == "tasks" {
      // Three tasks Serein started (seedTaskPanel's runs), the working Codex task in Serein's
      // view beside the page, with its edit approval and the strip listing the other two.
      let ids = agent.conversations.map(\.id)
      RelayController.shared?.relay.previewAdoptTasks([ids[3], ids[2], ids[1]] + (CommandLine.arguments.contains("--ui-task-idle") ? [ids[0]] : []))
      var shown = ids[2]
      // `--ui-task-idle`: a task with no run in front, its field empty.
      if CommandLine.arguments.contains("--ui-task-idle") { shown = ids[0] }
      // `--ui-task-restored`: the waiting task, loaded from its saved record and transcript.
      // Combine with `--ui-task-failed` for the saved failure, with no live hub run.
      if CommandLine.arguments.contains("--ui-task-restored") { shown = ids[1] }
      // `--ui-task-needs-you`: the waiting task in front.
      if CommandLine.arguments.contains("--ui-task-needs-you") { shown = ids[1] }
      if CommandLine.arguments.contains("--ui-task-failed") {
        shown = ids[5]
        RelayController.shared?.relay.previewAdoptTasks([ids[5], ids[3], ids[2], ids[1]])
      }
      // `--ui-task-stopped`: the task in view was stopped mid-step (its held reply then waits
      // for you: “Not sent”, with Send now).
      if CommandLine.arguments.contains("--ui-task-stopped"), let run = agent.hub.run(for: shown) {
        run.record.outcome = .stopped
        run.record.endedAt = Date()
      }
      SereinRouter.openTask(shown)
      // `--ui-task-held`: a reply held for the task in view (“Sends when this step ends: …”);
      // with `--ui-task-idle`, one that could not go, with its reason and Try again; with
      // `--ui-task-stopped`, one held after a stopped step.
      if CommandLine.arguments.contains("--ui-task-held") {
        agent.flow.previewHeldReply(
          shown, error: CommandLine.arguments.contains("--ui-task-idle") ? AgentModel.choosingWords : nil)
      }
      // `--ui-serein-task-full`: the same task view with Serein full.
      if CommandLine.arguments.contains("--ui-serein-task-full") { SereinRouter.home() }
      // `--ui-serein-task-tab`: a direct task's tab in the main view while a different Serein task
      // shows beside it (the task view reads its task by id, never the tab's current chat).
      if CommandLine.arguments.contains("--ui-serein-task-tab") {
        SereinRouter.open(threadID: ids[4])
      }
    }
    // Serein chat card: add `--ui-serein-chat` on the full preview to seed its conversation.
    // The side preview already seeds a chat; neither variant opens the task automatically.
    if ["serein", "serein-side"].contains(screen), CommandLine.arguments.contains("--ui-task-failed"),
      let failed = agent.hub.runs.first(where: { $0.taskID == "preview-task-failed" })
    {
      // Serein inserts its own chat during startup; use the fixture's identity, not its old index.
      RelayController.shared?.relay.previewAdoptTasks([failed.spec.threadID])
    }
    // Teardown lane: affectUI Agent Plan and Context Window (PlanCard.swift, SessionFiles.swift).
    // `--ui-affect-agent-plan` (with `--ui-preview serein`): plan first on, and the Serein chat's
    // newest reply holds a three-step plan that waits for Start, to drop, move and reword.
    if CommandLine.arguments.contains("--ui-affect-agent-plan"), let relay = RelayController.shared?.relay {
      var plan = PlanCard(steps: [
        PlanCard.Step(title: "Read the onboarding copy"), PlanCard.Step(title: "Move strings to one file"),
        PlanCard.Step(title: "Tighten the empty state", effect: .change),
      ], now: Date().addingTimeInterval(-40))
      plan.end(now: Date().addingTimeInterval(-30))
      var reply = AgentMessage(id: "preview-affect-plan-reply", role: "assistant", text: """
        Here is what I would change. Nothing changes until you start.

        1. Read the onboarding copy
        2. Move strings to one file
        3. Tighten the empty state
        """)
      reply.plan = plan
      let ask = AgentMessage(id: "preview-affect-plan-ask", role: "you", text: "Tidy the onboarding copy")
      agent.amendThread(relay.threadID) { $0 += [ask, reply] }
      ComposerContext.shared.planMode = true
      ComposerContext.shared.awaitingApproval.insert(relay.threadID)
    }
    // `--ui-affect-context-window` (with `--ui-preview tasks --ui-task-needs-you`): the waiting
    // task's result line at 86% of a 200k window, with what fills it.
    if CommandLine.arguments.contains("--ui-affect-context-window"), screen == "tasks",
      let id = agent.conversations.dropFirst().first?.id, let run = agent.hub.latest(for: id)
    {
      run.contextWindow = 200_000
      run.contextTokens = 172_000
      run.record.context = ContextMeter(percent: 86, estimated: false)
    }
    for _ in 0..<60 {
      try? await Task.sleep(nanoseconds: 100_000_000)
      if !browser.tabs.contains(where: { $0.web.isLoading }) { break }
    }
    // `--ui-serein-page-text`: ⌥⌘E, the page chip with the page's text (once the page has loaded).
    if CommandLine.arguments.contains("--ui-serein-page-text") {
      ComposerContext.shared.openAsk(browser: browser)
      for _ in 0..<30 where SereinSurface.main.attachments.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
    }
    if CommandLine.arguments.contains("--ui-hide-sidebar") {
      NotificationCenter.default.post(name: Notification.Name("SereinWall"), object: nil)
    }
    if CommandLine.arguments.contains("--ui-slash") {
      HarnessRegistry.shared.installSyntheticPreview()
      if let i = CommandLine.arguments.firstIndex(of: "--ui-slash"), i + 1 < CommandLine.arguments.count,
        let driver = HarnessDriver(rawValue: CommandLine.arguments[i + 1]) { agent.provider = Provider(driver) }
      agent.mode = .answer
      agent.draft = "/"
      browser.section = ShellSection.thread
      try? await Task.sleep(nanoseconds: 300_000_000)
    }
    // The address field focused (⌘L), for the horizontal band's editing state.
    if CommandLine.arguments.contains("--ui-edit-address") {
      NotificationCenter.default.post(name: Notification.Name("SereinFocusAddress"), object: nil)
      try? await Task.sleep(nanoseconds: 300_000_000)
    }
    // The toolbar's "…" menu, open with its first submenu showing.
    if screen == "menu" {
      NotificationCenter.default.post(name: Notification.Name("SereinPreviewMenu"), object: nil)
    }
    // `--ui-account-menu`: the sidebar's account menu (Settings, Marketplace, Usage), open.
    if CommandLine.arguments.contains("--ui-account-menu") {
      NotificationCenter.default.post(name: Notification.Name("SereinPreviewAccountMenu"), object: nil)
    }
    // `--ui-serein-attach`: Serein's composer holding a draft and a pointed-part chip, unsent.
    if CommandLine.arguments.contains("--ui-serein-attach") {
      SereinSurface.main.draft = "What does this part say about the deadline?"
      SereinSurface.main.attach(SereinAttachment(
        title: "Part of “Checkout redesign notes”", icon: "cursorarrow.rays", body: "Synthetic preview"))
    }
    // `--ui-serein-peek`: Serein hidden, then asked from this tab: beside it for now, with Keep
    // beside in its header.
    if CommandLine.arguments.contains("--ui-serein-peek") { SereinSurface.main.peek = true }
    // `--ui-voice-pill idle|listening|sent`: the voice pill as Talk to Serein shows it, on a synthetic voice.
    let voicePill = CommandLine.arguments.firstIndex(of: "--ui-voice-pill").map { CommandLine.arguments.index(after: $0) }
    if let at = voicePill, at < CommandLine.arguments.count {
      await RelayController.shared?.previewVoicePill(CommandLine.arguments[at])
    }
    // `--ui-finish-notice short|long|swarm|stack [typed]`: the finish notice, which the capture takes.
    let finishNotice = CommandLine.arguments.firstIndex(of: "--ui-finish-notice").map { CommandLine.arguments.index(after: $0) }
    if let at = finishNotice, at < CommandLine.arguments.count {
      FinishNoticeCenter.shared.preview(CommandLine.arguments[at], typed: CommandLine.arguments.contains("typed"))
    }
    Self.seedAffectLane3()
    Self.seedTakeoverCard(browser: browser)
    // Explicit guidance fixtures only; both centers disable persistence in preview launches.
    if let count = RelayOrchestrator.previewGuide.flatMap(Int.init) {
      GuideCenter.shared.preview(completed: count)
    }
    // affectUI lane 2: real cards raised through confirmAnswer, after Serein's chat is seeded. Run
    // each with `--ui-preview serein --ui-serein-chat`, so no seeded card comes before them.
    // `--ui-affect-approval`: a routine click declined at once (its resolved row in the chat), then
    // a message send waiting in the dock with its risk word and its preview rows.
    // `--ui-affect-email-draft [edited]`: a mail send waiting with its draft editable in place;
    // `edited` changes the subject first, so the card says Mail sends the person's words.
    if let relay = RelayController.shared?.relay {
      let arguments = CommandLine.arguments
      if arguments.contains("--ui-affect-approval") {
        let archive = ApprovalCopy.macStep(kind: "click", label: "Archive", app: "Notes")
        Task { _ = await relay.confirmAnswer(archive.title, archive.detail, thread: nil, effect: .click) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        if let first = relay.approvals.first(where: { $0.title == archive.title }) { relay.decline(first) }
        let text = Connections.messageCard(to: "ana@example.com", text: "Running ten minutes late, see you at 7.",
                                           service: "iMessage", new: true)
        Task {
          _ = await relay.confirmAnswer(text.title, text.detail, button: text.button, thread: nil, more: text.more,
                                        moreName: text.moreName, moreOpen: text.moreOpen, effect: text.effect)
        }
      }
      if let index = arguments.firstIndex(of: "--ui-affect-email-draft") {
        let body = "Hi Ana,\n\nThe table is booked for 7 at Lumen. Bo is coming too.\n\nSee you then."
        let card = Connections.sendCard(to: ["ana@example.com"], cc: ["bo@example.com"], bcc: [], subject: "Friday dinner",
                                        body: body, new: [])
        let draft = EmailDraft(to: ["ana@example.com"], cc: ["bo@example.com"], subject: "Friday dinner", body: body)
        if let email = EmailDrafts.shared.offer(draft, title: card.title, detail: card.detail, thread: nil) {
          if arguments.indices.contains(index + 1), arguments[index + 1] == "edited" { email.draft.subject = "Friday dinner at 7" }
          Task {
            _ = await relay.confirmAnswer(card.title, card.detail, button: card.button, thread: nil, more: card.more,
                                          moreName: card.moreName, moreOpen: card.moreOpen, effect: card.effect)
          }
        }
      }
    }
    if let hint = RelayOrchestrator.previewHint {
      if hint == .sereinRow {
        SereinRouter.hide()
        if let page = browser.active { browser.show(page) }
      }
      HintCenter.shared.preview(hint)
    }
    // affectUI lane 1: `--ui-affect-tool-call`, `--ui-affect-run-controls [stopped]` and
    // `--ui-affect-message-actions` put their fixture on a sheet, which the capture takes.
    if let item = AffectLaneOnePreview.item(CommandLine.arguments) {
      AffectLaneOnePreview.present(item, on: window, browser: browser, agent: agent)
    }
    // affectUI lane 4 preview flags.
    try? await Task.sleep(nanoseconds: 600_000_000)
    window.contentView?.layoutSubtreeIfNeeded()
    Self.emit(["event": "serein-ui-preview", "screen": screen, "root": root.path,
      "contentWidth": Int(window.contentView?.bounds.width ?? 0),
      "contentHeight": Int(window.contentView?.bounds.height ?? 0),
      "projects": browser.projects.count, "threads": agent.conversations.count,
      "providers": agent.available.count, "historyWrites": browser.historyEnabled,
      "reducedEffects": reducedEffects, "appearance": appearance.rawValue,
      "fonts": Self.geistFonts, "windowButtons": WindowChrome.shared.buttonFrames(),
      "headerCard": [Int(WindowChrome.shared.headerCardFrame.minX), Int(WindowChrome.shared.headerCardFrame.minY),
        Int(WindowChrome.shared.headerCardFrame.width), Int(WindowChrome.shared.headerCardFrame.height)]])
    #if DEBUG
      if CommandLine.arguments.contains("--ui-agent-list-clicks") {
        await AgentListClickCheck.run(window: window, capture: capture)
        return
      }
    #endif
    guard let capture else { return }
    // `--ui-hologram`: the light has drawn before the window is captured.
    if CommandLine.arguments.contains("--ui-hologram") { await RelayAvatarEngine.settle(in: window) }
    do {
      let notice = finishNotice != nil ? FinishNoticeCenter.shared.panel : nil
      let target: NSWindow = notice ?? window.attachedSheet ?? window
      target.contentView?.layoutSubtreeIfNeeded()
      guard target.isVisible, !target.isMiniaturized, target.screen != nil else {
        throw SereinError.invalid("Capture requires the visible native preview window")
      }
      try FileManager.default.createDirectory(at: capture.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      do {
        try await Self.captureWindow(number: target.windowNumber, destination: capture)
      } catch {
        // Without Screen Recording permission, render the view hierarchy in-process instead.
        // Glass materials and web content may render flatter than on screen; Relay's hologram
        // is drawn from its own frame.
        let holograms = await RelayAvatarEngine.frames(in: target)
        defer { holograms.restore() }
        try Self.renderInProcess(target, destination: capture, overlays: holograms.frames)
        Self.emit(["event": "serein-ui-capture-fallback", "reason": error.localizedDescription])
      }
      guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: capture)) else {
        throw SereinError.invalid("Native window capture did not produce a readable PNG")
      }
      Self.emit(["event": "serein-ui-capture", "screen": screen, "path": capture.path,
        "method": "native-window", "targetKind": target === window ? "main-window" : notice != nil ? "finish-notice" : "attached-sheet",
        "targetContentWidth": Int(target.contentView?.bounds.width ?? 0),
        "targetContentHeight": Int(target.contentView?.bounds.height ?? 0),
        "reducedEffects": reducedEffects, "appearance": appearance.rawValue,
        "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh,
        "contentWidth": Int(window.contentView?.bounds.width ?? 0),
        "contentHeight": Int(window.contentView?.bounds.height ?? 0), "fonts": Self.geistFonts])
    } catch {
      Self.emit(["event": "serein-ui-capture-error", "message": error.localizedDescription])
    }
  }

  private static var geistFonts: [String] {
    ((CTFontManagerCopyAvailablePostScriptNames() as? [String]) ?? [])
      .filter { $0.hasPrefix("Geist") }.sorted()
  }
  private static func emit(_ values: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: values, options: .sortedKeys) else { return }
    data.append(10)
    FileHandle.standardOutput.write(data)
  }
  static func renderInProcess(_ window: NSWindow, destination: URL, overlays: [(NSRect, Data)] = []) throws {
    guard let view = window.contentView?.superview ?? window.contentView,
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { throw SereinError.invalid("In-process capture has no view") }
    view.cacheDisplay(in: view.bounds, to: rep)
    // Popovers (the tab status bubble) are their own windows; draw them over the capture.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    for child in NSApp.windows where child !== window && child.isVisible
      && child.level.rawValue >= window.level.rawValue && child.frame.intersects(window.frame)
      && String(describing: type(of: child)).contains("Popover")
    {
      guard let childView = child.contentView?.superview ?? child.contentView,
        let childRep = childView.bitmapImageRepForCachingDisplay(in: childView.bounds)
      else { continue }
      childView.cacheDisplay(in: childView.bounds, to: childRep)
      let origin = NSPoint(x: child.frame.minX - window.frame.minX, y: child.frame.minY - window.frame.minY)
      childRep.draw(in: NSRect(origin: origin, size: child.frame.size), from: .zero,
        operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    }
    for (rect, png) in overlays {
      NSImage(data: png)?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
      throw SereinError.invalid("In-process capture could not encode PNG")
    }
    try png.write(to: destination, options: .atomic)
  }
  private static func captureWindow(number: Int, destination: URL) async throws {
    try await Task.detached {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-o", "-l", String(number), destination.path]
      process.standardOutput = FileHandle.nullDevice
      let errors = Pipe()
      process.standardError = errors
      try process.run()
      defer { if process.isRunning { process.terminate() } }
      for _ in 0..<80 {
        if !process.isRunning { break }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      guard !process.isRunning else { throw SereinError.invalid("Native window capture timed out") }
      guard process.terminationStatus == 0 else {
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw SereinError.invalid("Native window capture failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
      }
    }.value
  }
}

extension UIPreview {
  /// `--ui-setup-step <SetupStep raw value>`: which step the "setup" preview opens on.
  static var setupStep: String? {
    CommandLine.arguments.drop(while: { $0 != "--ui-setup-step" }).dropFirst().first
  }
}

#if DEBUG
  extension UIPreview {
    /// `--ui-agents-live` (debug builds): the Agents card from this Mac, read-only: the sessions
    /// running now, every past Claude Code and Codex session, Codex Cloud tasks (through the Codex
    /// CLI) and Serein's own threads from the real library. Nothing is written back to it.
    /// `--ui-projects-live` (debug builds): the Projects page from this Mac, read-only: the
    /// projects and threads saved in Serein's library, sessions running now and every harness's
    /// history. The project with the most chats opens its chats. Nothing is written back.
    @MainActor static func loadLiveProjects(browser: BrowserModel, agent: AgentModel) async {
      let library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Serein/Library")
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      if let data = FileManager.default.contents(atPath: library.appendingPathComponent("projects/projects.json").path),
        let projects = try? decoder.decode([Project].self, from: data)
      {
        browser.projects = projects
        browser.refreshProjectKindsNow()
      }
      await loadLiveAgents(agent: agent, cloud: false)
      let index = ProjectChatIndex(
        projects: browser.listedProjects, threads: agent.conversations, running: ExternalSessionStore.shared.sessions,
        history: SessionHistoryStore.shared.history.sessions, hides: agent.isSereinChat)
      let busiest = browser.listedProjects.max { (index.byProject[$0.id]?.count ?? 0) < (index.byProject[$1.id]?.count ?? 0) }
      if UserDefaults.standard.string(forKey: "serein.previewChatProvider") == nil, let busiest {
        SessionHistoryStore.shared.previewExpand = busiest.id
      }
      browser.section = ShellSection.projects
      fputs("live: projects=\(browser.projects.count) listed=\(browser.listedProjects.count) chats=\(index.all.count) placed=\(index.byProject.values.map(\.count).reduce(0, +)) busiest=\(busiest?.name ?? "-")\n", stderr)
    }

    @MainActor static func loadLiveAgents(agent: AgentModel, cloud readCloud: Bool = true) async {
      let home = NSHomeDirectory()
      var executables: [HarnessDriver: String] = [:]
      for driver in HarnessDriver.allCases {
        if let path = HarnessRegistry.locate(driver, override: nil, shellPath: nil) { executables[driver] = path }
      }
      let found = executables
      let (sessions, history) = await Task.detached(priority: .userInitiated) {
        var reader = ExternalSessionReader()
        let sessions = reader.snapshot(processes: HarnessProcessDiscovery.snapshot(executables: found), executables: found)
        var history = SessionHistory()
        history.refresh(nil, roots: SessionHistory.Roots(home: home, environment: ProcessInfo.processInfo.environment), known: [], hidden: HelperFolder.hidden)
        return (sessions, history)
      }.value
      var cloud: [CloudTask] = []
      if readCloud, let codex = executables[.codex] {
        let env = HarnessRegistry.environment(executable: codex, driver: .codex, shellPath: nil, extra: [:])
        let scratch = CloudTaskModel.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let result = await HarnessProbe.run(
          codex, ["cloud", "list", "--json", "--limit", "20"], environment: env, timeout: 25, cwd: scratch)
        let json = result.output.firstIndex(of: "{").map { String(result.output[$0...]) } ?? ""
        cloud = CloudTask.list(Data(json.utf8))
        fputs("live: codex cloud exit=\(result.code) tasks=\(cloud.count)\n", stderr)
      }
      let real = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Serein/Library/sessions/threads.json")
      if let data = FileManager.default.contents(atPath: real.path),
        let threads = try? { () -> JSONDecoder in
          let decoder = JSONDecoder()
          decoder.dateDecodingStrategy = .iso8601  // as Library saves them
          return decoder
        }().decode([Conversation].self, from: data)
      {
        agent.conversations = threads
      }
      ExternalSessionStore.shared.update(sessions)
      SessionHistoryStore.shared.installPreview(history, cloud: cloud)
      fputs("live: running=\(sessions.count) past=\(history.sessions.count) threads=\(agent.conversations.count)\n", stderr)
    }
  }
#endif


// MARK: affectUI previews, lane 3: `--ui-affect-away-summary` and `--ui-affect-running-now`

extension UIPreview {
  /// `--ui-takeover-card` (with `--ui-serein-chat`, where the card shows).
  @MainActor static func seedTakeoverCard(browser: BrowserModel) {
    guard CommandLine.arguments.contains("--ui-takeover-card"),
      let task = try? browser.beginTask(isolated: true, allowActions: true, includeCurrent: false)
    else { return }
    let id = task.capability.task
    let tab = BrowserTab(privateMode: true, owner: id, store: task.store)
    browser.tasks[id]?.tabs.append(tab)
    browser.agentTabs.opened(tab, task: id, isolated: true)
    tab.web.loadHTMLString(takeoverCheckPage, baseURL: URL(string: "https://shop.example/checkout"))
    _ = browser.askPersonTakeover(tab, task: id, reason: "The shop asks you to confirm you are human before checkout.")
  }

  static let takeoverCheckPage = """
    <!doctype html><title>Just a moment...</title>
    <body style="font:16px -apple-system;background:#1b1b1b;color:#eee;display:grid;place-items:center;height:90vh;margin:0">
    <div style="text-align:center"><h2>shop.example</h2><p>Please verify you are human by pressing the button.</p>
    <button id="human" style="font-size:16px;padding:10px 18px">I am human</button></div>
    <script>document.getElementById('human').onclick=()=>{document.title='Checkout';document.body.innerHTML='<h2>Checkout</h2><p>You are through.</p><button>Continue</button>'}</script>
    """
}

extension UIPreview {
  private static let affectLane3Flags = ["--ui-affect-away-summary", "--ui-affect-running-now"]

  /// What both previews add to the Tasks tab's list (`SereinSessions.read`): two tasks at
  /// work, one waiting on the person, one that failed and two done, all synthetic.
  @MainActor static var affectLane3Tasks: [SereinTrayList.Item] {
    guard RunMode.previewing, CommandLine.arguments.contains(where: { affectLane3Flags.contains($0) }) else { return [] }
    let now = Date()
    func task(_ id: String, _ title: String, _ outcome: RunRecord.Outcome, endedAgo minutes: Double? = nil) -> SereinTrayList.Item {
      SereinTrayList.Item(id: "preview-affect-" + id, title: title, outcome: outcome,
                          startedAt: now.addingTimeInterval(-90 * 60),
                          endedAt: minutes.map { now.addingTimeInterval(-$0 * 60) }, serein: true)
    }
    return [
      task("inbox", "Sort the inbox", .running), task("flights", "Check in for Friday's flight", .running),
      task("maya", "Reply to Maya about the lease", .waiting),
      task("report", "Weekly report", .stuck, endedAgo: 20),
      task("downloads", "Tidy Downloads", .done, endedAgo: 35), task("table", "Book the table", .done, endedAgo: 10),
    ]
  }

  /// `--ui-affect-away-summary` (with `--ui-serein-chat`): back after 50 minutes away, the Unread
  /// line over Serein's newest reply and the away card under it.
  @MainActor static func seedAffectLane3() {
    guard CommandLine.arguments.contains("--ui-affect-away-summary"), let relay = RelayController.shared?.relay,
      let reply = relay.transcript.last(where: { $0.role == "assistant" && !$0.text.isEmpty && $0.text != "DONE" })
    else { return }
    RelayController.leftAt = Date().addingTimeInterval(-50 * 60)
    relay.unreadFrom[relay.threadID] = reply.id
  }
}

// MARK: affectUI preview, Memory Panel: `--ui-affect-memory-panel [edit]`

extension UIPreview {
  private static let affectMemoryPanelFlag = "--ui-affect-memory-panel"

  /// `--ui-affect-memory-panel` (with `--ui-preview settings --ui-settings-section
  /// Relay/main/memory`): fixture notes on an assistant's Memory page in place of the store,
  /// which previews never open. Its own notes (one it learned and used, one from a page, one
  /// paused), two every assistant shares, and one learned note waiting. All synthetic.
  static func affectMemoryPanel(owner: String) -> AssistantSettingsMemory? {
    guard RunMode.previewing, CommandLine.arguments.contains(affectMemoryPanelFlag) else { return nil }
    let now = Date(timeIntervalSince1970: 1_794_700_000)
    func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
    func note(
      _ id: String, _ text: String, scope: MemoryScope, from source: MemorySource, reference: String? = nil,
      saved: Double, used: Double? = nil, on: Bool = true, quote: String? = nil
    ) -> MemoryRecord {
      MemoryRecord(
        id: "preview-memory-" + id, text: text, quote: quote, owner: owner, scope: scope,
        provenance: MemoryProvenance(source: source, reference: reference), createdAt: ago(saved), enabled: on,
        review: .confirmed, personal: false, useCount: used == nil ? 0 : 3, lastUsed: used.map { ago($0) })
    }
    let own = MemoryScope.assistant(owner)
    let notes: [MemoryRecord] = [
      note("diet", "Vegetarian, no mushrooms", scope: own, from: .person, saved: 12, used: 1, quote: "I don’t eat meat or mushrooms"),
      note("standup", "Team standup moves to 9:30 on Mondays", scope: own, from: .assistant, saved: 4, used: 2),
      note("venue", "The offsite venue holds 40 people", scope: own, from: .page, reference: "https://venue.example.invalid/hall", saved: 6),
      note("gym", "Gym on Tuesday and Thursday evenings", scope: own, from: .person, saved: 30, on: false),
      note("name", "Goes by Sam at work", scope: .person, from: .person, saved: 40, used: 0.2),
      note("timezone", "Works from Lisbon time", scope: .person, from: .migrated, saved: 90, used: 3),
    ]
    let waiting = [RelayNote(id: "preview-memory-wait", text: "Prefers window seats on long flights", createdAt: ago(0.5))]
    return AssistantSettingsMemory(notes: notes, waiting: waiting)
  }

  /// `--ui-affect-memory-panel edit`: the first note opens in place.
  static var affectMemoryPanelEditing: String? {
    let arguments = CommandLine.arguments
    guard RunMode.previewing, let index = arguments.firstIndex(of: affectMemoryPanelFlag), index + 1 < arguments.count,
      arguments[index + 1] == "edit"
    else { return nil }
    return "preview-memory-diet"
  }
}


// MARK: affectUI previews, last three: `--ui-affect-schedules`

extension UIPreview {
  /// `--ui-affect-schedules` (`--ui-preview settings --ui-settings-section Relay/reminders`): the day
  /// line's fixture, only in memory. Serein's hourly tidy (two runs before now), a routine whose
  /// last run failed, a plain reminder, a goal and an assistant's schedule still to come.
  @MainActor static var affectSchedules: [RelayReminder] {
    guard RunMode.previewing, CommandLine.arguments.contains("--ui-affect-schedules") else { return [] }
    let now = Date()
    let hour = Calendar.current.dateInterval(of: .hour, for: now.addingTimeInterval(1800))?.end ?? now.addingTimeInterval(3600)
    var tidy = RelayReminder(id: "preview-affect-tidy", text: "Tidy my Downloads folder", due: hour, repeats: .cron,
                             action: true, cron: "0 */2 * * *")
    tidy.history = [RelayReminder.Run(at: now.addingTimeInterval(-4 * 3600), outcome: "done", result: "Moved 4 files"),
                    RelayReminder.Run(at: now.addingTimeInterval(-2 * 3600), outcome: "nothing new")]
    var inbox = RelayReminder(id: "preview-affect-inbox", text: "Check my inbox and tell me what needs me",
                              due: now.addingTimeInterval(3 * 3600), repeats: .daily, action: true)
    inbox.history = [RelayReminder.Run(at: now.addingTimeInterval(-50 * 60), outcome: "failed", result: "Mail did not answer")]
    let dentist = RelayReminder(id: "preview-affect-dentist", text: "Call the dentist", due: now.addingTimeInterval(90 * 60))
    let goal = RelayReminder(id: "preview-affect-goal", text: "Find a desk lamp under $60", due: now.addingTimeInterval(4.5 * 3600),
                             repeats: .daily, action: true, goal: RelayGoal(ends: now.addingTimeInterval(RelayGoal.defaultSpan)))
    let assistant = RelayController.shared?.relay.team.profiles.dropFirst().first?.id
    let numbers = RelayReminder(id: "preview-affect-numbers", text: "Post the weekly numbers", due: now.addingTimeInterval(5 * 3600),
                                repeats: .weekly, action: true, profileID: assistant)
    return [tidy, inbox, dentist, goal, numbers]
  }
}
