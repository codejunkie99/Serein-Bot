import AppKit
import SereinCore
import WebKit

/// `--stress`: scripts/stress.py sends one command per line on stdin and reads one JSON reply
/// per line on stdout. Each command goes through the same calls as the user's own actions
/// (`newTab`, `close`, `suspend`, `wake`, the agent tools). The driver also counts the tabs and
/// web views that are still in memory and the longest wait on the main thread.
/// It never runs on the user's own library: main.swift refuses `--stress` without
/// `SEREIN_DATA_DIR`.
@MainActor final class StressDriver {
  /// True when `SEREIN_DATA_DIR` names a folder made for a stress run: under the system's
  /// temporary folders, with an empty regular file `.serein-stress` in it. A library that someone
  /// uses, in the default place or another, has no such file. The same check as fixture approvals.
  nonisolated static var usesTestLibrary: Bool {
    guard let named = ProcessInfo.processInfo.environment["SEREIN_DATA_DIR"] else { return false }
    return FixtureApprovals.isAllowed(root: URL(fileURLWithPath: named, isDirectory: true))
  }
  /// Stress tabs keep their cookies and caches in a store of their own, apart from the user's.
  static let store: WKWebsiteDataStore? =
    RunMode.stress
    ? WKWebsiteDataStore(forIdentifier: UUID(uuidString: "5E2E1AC4-57E5-4000-8000-000000000001")!)
    : nil
  private static var shared: StressDriver?
  static func start(browser: BrowserModel) {
    let driver = StressDriver(browser: browser)
    shared = driver
    driver.listen()
  }

  private let browser: BrowserModel
  private let tabs = NSHashTable<BrowserTab>.weakObjects()
  private let webs = NSHashTable<WKWebView>.weakObjects()
  private var task: String?
  private var typedTask: String?
  private var typedCopy: BrowserTab?
  private var typedPersonal: BrowserTab?
  private var typedPersonalURL = ""
  private var typedPersonalUnchanged = false
  private var stall = 0.0
  private var pulse: DispatchSourceTimer?

  private init(browser: BrowserModel) { self.browser = browser }

  private func listen() {
    // The wait between a ping's schedule and its turn on the main thread is how long a click
    // would have waited.
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
    timer.schedule(deadline: .now(), repeating: .milliseconds(50))
    timer.setEventHandler { [weak self] in
      let sent = DispatchTime.now().uptimeNanoseconds
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self else { return }
          self.stall = max(self.stall, Double(DispatchTime.now().uptimeNanoseconds - sent) / 1e6)
        }
      }
    }
    timer.resume()
    pulse = timer
    Task {
      do {
        for try await line in FileHandle.standardInput.bytes.lines {
          var reply: [String: Any]
          do { reply = try await run(line.split(separator: " ").map(String.init)) } catch {
            reply = ["error": error.localizedDescription]
          }
          let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
          FileHandle.standardOutput.write(Data("stress: ".utf8) + data + Data("\n".utf8))
        }
      } catch {}
      // The script is gone: no test browser stays behind.
      NSApp.terminate(nil)
    }
  }

  private func track() {
    for tab in browser.tabs + browser.tasks.values.flatMap(\.tabs) {
      tabs.add(tab)
      webs.add(tab.web)
    }
  }
  private func tab(_ word: String?) throws -> BrowserTab {
    guard let index = word.flatMap(Int.init), browser.tabs.indices.contains(index) else {
      throw SereinError.invalid("No tab at that index")
    }
    return browser.tabs[index]
  }

  /// The copy is deliberately kept working across the controller's sleep pass, then ended
  /// explicitly. Holding the task here does not grant any authority beyond its real capability.
  private func typedState() async throws -> [String: Any] {
    guard let id = typedTask, let copy = typedCopy, let personal = typedPersonal else {
      throw SereinError.invalid("No agent-type task is active")
    }
    let alive = browser.tasks[id]?.tabs.contains { $0.id == copy.id } == true
    await copy.suspend()
    let text = try await copy.script("document.querySelector('textarea').value") as? String ?? ""
    return [
      "ownedCopyID": copy.id, "taskID": id, "alive": alive, "url": copy.address,
      "personalUnchanged": typedPersonalUnchanged && personal.owner == nil && personal.address == typedPersonalURL,
      "storeSeparated": copy.web.configuration.websiteDataStore !== personal.web.configuration.websiteDataStore,
      "text": text, "keepsAwake": alive && !copy.sleeping, "asleep": copy.sleeping,
    ]
  }

  private func run(_ words: [String]) async throws -> [String: Any] {
    defer { track() }
    switch words.first {
    case "proxy-check":
      return try await checkFixtureProxy(browser: browser)
    case "open":
      guard words.count > 1 else { throw SereinError.invalid("open <url> [bg]") }
      browser.newTab(words[1], select: words.last != "bg")
    case "select":
      browser.selected = try tab(words.dropFirst().first).id
      browser.section = ShellSection.browser
    case "close":
      if words.last == "all" {
        // The tab in view goes last: closing it first would wake a sleeping tab only to close it.
        for tab in browser.tabs.reversed() where tab.id != browser.selected { browser.close(tab) }
        if let last = browser.active { browser.close(last) }
      } else {
        browser.close(try tab(words.dropFirst().first))
      }
    case "sleep":
      // What the lifecycle timer does at its limit, and memory pressure does at once.
      await browser.sleepIdleTabs(idle: 0)
    case "wake":
      try tab(words.dropFirst().first).wake()
    case "section":
      // Start, History, Projects or a thread in place of the page, as the sidebar does.
      guard words.count > 1 else { throw SereinError.invalid("section <name>") }
      browser.section = words[1]
    case "unload":
      // What happens to a kept agent result tab that nobody has opened for a while.
      try tab(words.dropFirst().first).unload()
    case "agent-type":
      if words.last == "state" { return try await typedState() }
      if words.last == "end" {
        guard let id = typedTask, let copy = typedCopy, let personal = typedPersonal else {
          throw SereinError.invalid("No agent-type task is active")
        }
        let oldWeb = copy.web
        browser.endTask(id)
        let discarded = browser.tasks[id] == nil && copy.web !== oldWeb && copy.web.url == nil && copy.frames.isEmpty
        let reply: [String: Any] = [
          "ownedCopyID": copy.id, "taskID": id, "alive": browser.tasks[id] != nil, "discarded": discarded,
          "personalUnchanged": typedPersonalUnchanged && personal.owner == nil && personal.address == typedPersonalURL,
        ]
        typedTask = nil
        typedCopy = nil
        typedPersonal = nil
        return reply
      }
      guard typedTask == nil else { throw SereinError.invalid("End the previous agent-type task first") }
      // A This page task now owns a fresh copy. Its text must stay alive while it works; the
      // source page and its data store remain the user's and may sleep normally.
      let personal = try tab(words.dropFirst().first)
      browser.selected = personal.id
      browser.section = ShellSection.browser
      let personalURL = personal.address
      let personalWeb = personal.web
      guard let personalState = try await personal.script("JSON.stringify({text: document.querySelector('textarea').value, storage: sessionStorage.getItem('stress')})") as? String else {
        throw SereinError.invalid("The personal fixture state could not be read")
      }
      let started = try browser.beginTask(isolated: false, allowActions: true, includeCurrent: true, current: personal)
      var keepTask = false
      defer { if !keepTask { browser.endTask(started.capability.task) } }
      // This driver owns the task's lifetime across commands. The approval session starts
      // afterward so closing its temporary Relay does not end that existing task.
      let approvals = try FixtureApprovals(browser: browser)
      defer { approvals.close() }
      guard started.tabs.count == 1, let copy = started.tabs.first,
        copy.owner == started.capability.task, copy.id != personal.id,
        copy.web.configuration.websiteDataStore !== personalWeb.configuration.websiteDataStore,
        copy.web.configuration.websiteDataStore !== WKWebsiteDataStore.default(),
        !copy.web.configuration.websiteDataStore.proxyConfigurations.isEmpty,
        personalWeb.configuration.websiteDataStore.proxyConfigurations.isEmpty
      else { throw SereinError.invalid("The page task did not create a separate owned tab") }
      track()
      await copy.settle(limit: 30)
      guard copy.address == personalURL,
        try await copy.script("document.querySelector('textarea')?.value === ''") as? Bool == true
      else { throw SereinError.invalid("The task copy did not load the approved page") }
      func call(_ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        try await browser.handle([
          "task": started.capability.task, "token": started.capability.token, "name": name,
          "arguments": arguments,
        ])
      }
      let read = try await call("read", ["tab": copy.id])
      guard
        let field = (read["elements"] as? [[String: Any]])?
          .first(where: { $0["label"] as? String == "Note" })?["ref"] as? String
      else { throw SereinError.invalid("No field named Note on this page") }
      _ = try await approvals.perform(expecting: [
        .site(url: personalURL),
        .init(title: "Serein wants to type on this page", detail: "Check this before you allow it.\nTarget: Note"),
      ]) {
        try await call("fill", ["tab": copy.id, "ref": field, "text": "written by the agent"])
      }
      let unchanged = try await personal.script("JSON.stringify({text: document.querySelector('textarea').value, storage: sessionStorage.getItem('stress')})") as? String == personalState
      guard unchanged && personal.web === personalWeb && personal.owner == nil && personal.address == personalURL else {
        throw SereinError.invalid("Agent typing changed the personal source tab")
      }
      typedTask = started.capability.task
      typedCopy = copy
      typedPersonal = personal
      typedPersonalURL = personalURL
      typedPersonalUnchanged = unchanged
      keepTask = true
      return try await typedState()
    case "type":
      // Text typed by hand and not sent: `suspend` must leave this tab alone. It goes in through
      // the text input system, as keys do; a value set by script is not the user's.
      // `type <tab> frame` types into the page's first embedded frame instead, and
      // `type <tab> input` into its one-line search field.
      let tab = try tab(words.dropFirst().first)
      let frame = words.last == "frame" ? tab.frames.values.first { !$0.isMainFrame } : nil
      if words.last == "frame", frame == nil { throw SereinError.invalid("No embedded frame") }
      let field = words.last == "input" ? "input[name=q]" : "textarea"
      _ = try await tab.script("document.querySelector('\(field)').focus(); true", frame: frame)
      tab.web.insertText("draft")
      try await Task.sleep(nanoseconds: 300_000_000)
    case "go":
      guard words.count > 2 else { throw SereinError.invalid("go <tab> <url>") }
      try tab(words[1]).navigate(words[2])
    case "scroll":
      guard words.count > 2, let y = Int(words[2]) else { throw SereinError.invalid("scroll <tab> <y>") }
      _ = try await tab(words[1]).script("scrollTo(0, \(y)); true")
    case "page":
      // Where one tab is: for checks that a woken tab came back as it was.
      let tab = try tab(words.dropFirst().first)
      let y = tab.sleeping ? nil : try? await tab.script("Math.round(scrollY)") as? Int
      let kept =
        tab.sleeping ? nil : try? await tab.script("sessionStorage.getItem('stress')") as? String
      return [
        "url": tab.address, "title": tab.title, "asleep": tab.sleeping,
        "back": tab.ext.canGoBack, "scrollY": y ?? -1, "storage": kept ?? "",
      ]
    case "settle":
      let deadline = Date().addingTimeInterval(words.dropFirst().first.flatMap(Double.init) ?? 30)
      let all = { self.browser.tabs + self.browser.tasks.values.flatMap(\.tabs) }
      try await Task.sleep(nanoseconds: 300_000_000)
      while all().contains(where: { $0.loading }) && Date() < deadline {
        try await Task.sleep(nanoseconds: 100_000_000)
      }
    case "agent":
      // The same path as an agent's browser tools: a capability, then `open_tab` calls.
      if words.last == "end" {
        if let task { browser.endTask(task) }
        task = nil
      } else {
        guard words.count > 2, let count = Int(words[1]) else {
          throw SereinError.invalid("agent <count> <url> | agent end")
        }
        if let task { browser.endTask(task) }
        let started = try browser.beginTask(isolated: true, allowActions: false, includeCurrent: false)
        task = started.capability.task
        var keepTask = false
        defer {
          if !keepTask {
            browser.endTask(started.capability.task)
            let entries = browser.agentTabs.entries.filter { $0.taskID == started.capability.task }
            for entry in entries { browser.agentTabs.dismiss(entry.id) }
            task = nil
          }
        }
        let approvals = try FixtureApprovals(browser: browser)
        defer { approvals.close() }
        for index in 0..<count {
          _ = try await approvals.perform(expecting: index == 0 ? [.site(url: words[2])] : []) {
            try await self.browser.handle([
              "task": started.capability.task, "token": started.capability.token,
              "name": "open_tab", "arguments": ["url": words[2]],
            ])
          }
        }
        keepTask = true
      }
    case "state": break
    case "quit":
      NSApp.terminate(nil)
    default: throw SereinError.invalid("Unknown stress command")
    }
    track()
    let open = browser.tabs
    let longest = stall
    stall = 0
    return [
      "tabs": open.count, "asleep": open.filter(\.sleeping).count,
      "loading": open.filter(\.loading).count,
      "agentTabs": browser.tasks.values.reduce(0) { $0 + $1.tabs.count } ,
      "keptAgentTabs": browser.agentTabs.entries.count,
      "liveTabs": tabs.allObjects.count, "liveWebs": webs.allObjects.count,
      "stallMs": (longest * 10).rounded() / 10,
    ]
  }
}
