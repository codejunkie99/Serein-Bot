#if DEBUG
import Cocoa
import NaturalLanguage
import SQLite3
import SereinCore
import WebKit

enum SmokeTest {
  @MainActor static func run(browser: BrowserModel, agent: AgentModel, window: NSWindow) async {
    var results: [String] = []
    func check(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label) }
      results.append("PASS: " + label)
    }
    // Read before anything opens a tab: a fresh library has nothing to restore.
    let launchedOn = browser.section
    let launchedWithTabs = !browser.tabs.isEmpty
    do {
      if !CommandLine.arguments.contains("--verify-browser-only") {
        // AppKit activation is asynchronous for a verifier started from a shell. The native
        // selection-pixel assertions require a key window; wait for activation.
        for _ in 0..<30 where !NSApp.isActive {
          NSApp.activate(ignoringOtherApps: true)
          try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await checkTextInteractions()
        try check(true, "Native composer newlines, Return routing, wrapping and transcript selection/copy")
      }
      try check(
        launchedOn == ShellSection.serein && !launchedWithTabs, "A new window opens on Serein, with no tabs")
      do {
        let before = browser.tabs
        for tab in before { browser.close(tab, remember: false) }
        let only = browser.newTab()
        let onStart = browser.section == ShellSection.start && browser.selected == only.id
        browser.close(only, remember: false)
        try check(
          onStart && browser.tabs.isEmpty && browser.selected == nil && browser.section == ShellSection.serein
            && !TabPage.rowSelected(isActive: true, section: browser.section, isNew: true) && !browser.startAlone,
          "Closing the last tab returns to Serein")
      }
      do {
        // A task starting (agent.running) never moves the main view off the page in view.
        let page = browser.newTab()
        page.rest(at: ProcessInfo.processInfo.environment["SEREIN_FIXTURE_URL"] ?? "http://127.0.0.1:18765/", title: "Fixture")
        browser.show(page)
        let wasRunning = agent.running
        // The shell is mounted and sees the run start: its own `agent.running` observer runs
        // (that is where the old jump to the thread lived), and the page stays in view.
        let seenBefore = ShellProbe.runningChanges
        agent.running = true
        var observed = false
        for _ in 0..<20 where !observed {
          try await Task.sleep(nanoseconds: 100_000_000)
          observed = ShellProbe.runningChanges > seenBefore
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let kept = observed && browser.section == ShellSection.browser && browser.selected == page.id
        agent.running = wasRunning
        try await Task.sleep(nanoseconds: 100_000_000)
        browser.close(page, remember: false)
        browser.section = ShellSection.start
        try check(kept, "Starting a task leaves the selected page in view (the shell saw the run start: \(observed))")
      }
      let approvals = try FixtureApprovals(browser: browser, agent: agent)
      defer { approvals.close() }
      #if DEBUG
      let previousAutopilot = approvals.relay.autopilotOverride
      approvals.relay.autopilotOverride = false
      defer { approvals.relay.autopilotOverride = previousAutopilot }
      #endif
      let task = try browser.beginTask(isolated: true, allowActions: true, includeCurrent: false)
      defer { browser.endTask(task.capability.task) }
      func call(_ name: String, _ args: [String: Any] = [:],
                expecting cards: [FixtureApprovals.Card] = []) async throws -> [String: Any] {
        try await approvals.perform(expecting: cards) {
          try await browser.handle([
            "task": task.capability.task, "token": task.capability.token, "name": name,
            "arguments": args,
          ])
        }
      }
      let fixtureURL = ProcessInfo.processInfo.environment["SEREIN_FIXTURE_URL"] ?? "http://127.0.0.1:18765/"
      var siteDeclined = false
      do {
        _ = try await call("open_tab", ["url": fixtureURL],
                           expecting: [.site(url: fixtureURL, answer: .no)])
      } catch { siteDeclined = error.localizedDescription == ActionAdmission.declined }
      try check(siteDeclined && browser.sites(for: task.capability.task).isEmpty
        && browser.tasks[task.capability.task]?.tabs.isEmpty == true,
        "Declining the first site leaves the task's site list and tabs empty")
      let opened = try await call("open_tab", ["url": fixtureURL],
                                  expecting: [.site(url: fixtureURL)])
      let id = opened["tab"] as! String
      guard let tab = browser.tasks[task.capability.task]?.tabs.first else {
        throw SereinError.invalid("No task tab")
      }
      try check(tab.web.configuration.preferences.isElementFullscreenEnabled
        && BrowserMedia.allowsPictureInPicture(tab.web.configuration),
        "WebKit video fullscreen and picture-in-picture are enabled")
      for _ in 0..<100 {
        if !tab.loading, tab.web.url != nil { break }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      try await Task.sleep(nanoseconds: 500_000_000)
      let outline = try await call("read", ["tab": id])
      try check(
        outline["title"] as? String == "Serein fixture" && outline["sensitive"] as? Bool == true
          && (outline["text"] as? String)?.contains("Serein fixture") == true,
        "WebKit navigation and page read")
      let frames = outline["frames"] as? [[String: String]] ?? []
      guard
        let frameID = frames.first(where: { $0["url"]?.contains("localhost") == true })?["frame"]
      else { throw SereinError.invalid("Cross-origin frame missing") }
      try check(!frames.isEmpty, "Cross-origin frame is discoverable with its origin")
      let childRead = try await call("read", ["tab": id, "frame": frameID])
      func safePassword(_ page: [String: Any], sentinel: String) -> Bool {
        let fields = (page["elements"] as? [[String: Any]] ?? []).filter { $0["label"] as? String == "Password" }
        return !fields.isEmpty && fields.allSatisfy {
          $0["secure"] as? String == "password" && $0["acts"] as? [String] == ["secure_card"] && $0["value"] == nil
        } && !String(describing: page).contains(sentinel)
      }
      let childElements = childRead["elements"] as? [[String: Any]] ?? []
      try check(
        safePassword(childRead, sentinel: "FIXTURE_FRAME_PRIVATE_VALUE")
          && childElements.contains { ($0["label"] as? String) == "Frame message" },
        "Cross-origin frame keeps the password value private and exposes only secure entry")
      let childField =
        childElements.first { ($0["label"] as? String) == "Frame message" }!["ref"] as! String
      // The reader's action label uses the input's own aria-label/name; this fixture's
      // associated <label> appears in the outline but not in the approval readback.
      _ = try await call("fill", ["tab": id, "ref": childField, "text": "Frame effect verified"],
        expecting: [.init(title: "Serein wants to type on this page",
                          detail: "Check this before you allow it.")])
      let childAgain = try await call("read", ["tab": id, "frame": frameID])
      let button =
        (childAgain["elements"] as! [[String: Any]]).first {
          ($0["label"] as? String) == "Frame apply"
        }!["ref"] as! String
      // Words naming the tab's site never cover a step inside another site's frame: the step is
      // judged by the frame's own origin (`actionSite`); an accessibility ref acts in the tab's page.
      let top = URL(string: tab.address)?.host
      try check(
        tab.actionSite(["ref": button]) == "localhost" && top != nil && top != "localhost"
          && tab.actionSite(["ref": "x1"]) == top && tab.actionSite([:]) == top
          && tab.actionSite(["frame": "gone"]) == nil,
        "A step in another site's frame is judged by that frame's site, not the tab's")
      _ = try await call("click", ["tab": id, "ref": button],
        expecting: [.init(title: "Serein wants to click on this page",
                          detail: "This may change something. Check it before you allow it.\nTarget: Frame apply")])
      // Main's private-page policy preserves safe text and controls beside sensitive fields.
      let childResult = try await call("read", ["tab": id, "frame": frameID])
      let childEffect = try await tab.script("document.querySelector('#result').textContent", frame: tab.frames[frameID]) as? String
      try check(
        childResult["sensitive"] as? Bool == true
          && (childResult["text"] as? String)?.contains("Frame effect verified") == true
          && childEffect == "Frame effect verified",
        "Cross-origin fill and click produce a verified DOM effect")
      var refused = false
      do { _ = try await call("click", ["tab": id, "ref": button]) }
      catch { refused = error.localizedDescription == ActionAdmission.pageChanged }
      let unchangedChild = try await tab.script("document.querySelector('#result').textContent", frame: tab.frames[frameID]) as? String
      try check(refused && unchangedChild == "Frame effect verified", "Stale child-frame references are refused")
      // Child actions reread sibling documents for payment facts, invalidating their refs.
      // Obtain fresh main-frame references before acting there.
      let mainAgain = try await call("read", ["tab": id])
      let elements = mainAgain["elements"] as? [[String: Any]] ?? []
      try check(
        safePassword(mainAgain, sentinel: "FIXTURE_MAIN_PRIVATE_VALUE"), "Password value excluded from main page read")
      guard
        let field = elements.first(where: { ($0["label"] as? String) == "Message" })?["ref"]
          as? String
      else { throw SereinError.invalid("Message field missing from outline") }
      var actionDeclined = false
      do {
        _ = try await call("fill", ["tab": id, "ref": field, "text": "must not type"],
          expecting: [.init(title: "Serein wants to type on this page",
                            detail: "Check this before you allow it.", answer: .no)])
      } catch { actionDeclined = error.localizedDescription == ActionAdmission.declined }
      let untouched = try await tab.script("document.querySelector('#message').value") as? String
      try check(actionDeclined && untouched == "", "Declining a page action leaves the field unchanged")
      _ = try await call("fill", ["tab": id, "ref": field, "text": "serein verified"],
        expecting: [.init(title: "Serein wants to type on this page",
                          detail: "Check this before you allow it.")])
      let value = try await tab.script("document.querySelector('#message').value") as? String
      try check(value == "serein verified", "MCP fill modifies real DOM")
      do {
        _ = try await call("fill", ["tab": id, "ref": field, "text": "stale"])
        throw SereinError.invalid("Stale ref accepted")
      } catch {
        let unchanged = try await tab.script("document.querySelector('#message').value") as? String
        try check(error.localizedDescription == ActionAdmission.pageChanged && unchanged == "serein verified",
                  "Stale references refused")
      }
      let fresh = try await call("read", ["tab": id])
      guard
        let button = (fresh["elements"] as? [[String: Any]])?.first(where: {
          ($0["label"] as? String) == "Apply"
        })?["ref"] as? String
      else { throw SereinError.invalid("Apply button missing from outline") }
      _ = try await call("click", ["tab": id, "ref": button],
        expecting: [.init(title: "Serein wants to click on this page",
                          detail: "This may change something. Check it before you allow it.\nTarget: Apply")])
      let text = try await tab.script("document.querySelector('#result').textContent") as? String
      try check(text == "serein verified", "MCP click effect visibly confirmed in DOM")
      let referenceBeforeNavigation = field
      try tab.navigate(
        ProcessInfo.processInfo.environment["SEREIN_FIXTURE_URL"] ?? "http://127.0.0.1:18765/")
      try await Task.sleep(nanoseconds: 700_000_000)
      _ = try await call("read", ["tab": id])
      do {
        _ = try await call(
          "fill", ["tab": id, "ref": referenceBeforeNavigation, "text": "must not fill"])
        throw SereinError.invalid("Old document reference was accepted")
      } catch {
        try check(
          error.localizedDescription == ActionAdmission.pageChanged,
          "References from a previous document are refused after navigation")
      }
      try check(!tab.web.configuration.websiteDataStore.isPersistent, "Isolated cookie store")
      let normal = browser.newTab("", select: false)
      do {
        _ = try await call("read", ["tab": normal.id])
        throw SereinError.invalid("Cross-task tab accepted")
      } catch {
        try check(
          error.localizedDescription.contains("belong"), "Personal tab denied to isolated task")
      }
      do {
        _ = try await call("navigate", ["tab": id, "url": "file:///etc/passwd"])
        throw SereinError.invalid("File URL accepted")
      } catch { try check(error.localizedDescription.contains("HTTP"), "Non-HTTP URL refused") }
      let cap = task.capability
      let socketResponse = try await Task.detached {
        try LocalSocket.request(["name": "list_tabs", "arguments": [:]], capability: cap)
      }.value
      try check(socketResponse["tabs"] != nil, "Unix socket authenticated request")
      let readOnly = try browser.beginTask(
        isolated: true, allowActions: false, includeCurrent: false)
      do {
        _ = try await browser.handle([
          "task": readOnly.capability.task, "token": readOnly.capability.token, "name": "click",
          "arguments": ["tab": id, "ref": "x"],
        ])
        throw SereinError.invalid("Read-only click accepted")
      } catch { try check(error.localizedDescription.contains("off"), "Read-only action gate") }
      browser.endTask(readOnly.capability.task)
      browser.endTask(task.capability.task)
      do {
        _ = try await call("list_tabs")
        throw SereinError.invalid("Expired token accepted")
      } catch {
        try check(error.localizedDescription.contains("expired"), "Capability revoked after task")
      }
      try check(!FileManager.default.fileExists(atPath: task.file.path), "Capability file removed")
      results += try await concurrentRuns(browser: browser, agent: agent)
      results += try await codexAppServer(browser: browser, agent: agent)
      results += try await harnessReadiness(browser: browser, agent: agent)
      results += try await agentTabs(browser: browser, agent: agent, approvals: approvals)
      #if DEBUG
      results += try await fastSteps(browser: browser, approvals: approvals)
      #endif
      results += try await reviewRegressions(browser: browser, agent: agent)
      results += try await editReview(browser: browser, agent: agent)
      results += try await fileGuard(browser: browser)
      results += try await consoleCapture(browser: browser)
      results += try await agentBehaviorHistory(browser: browser, agent: agent)
      browser.close(normal)
      let fixtureDB = browser.library.root.appendingPathComponent("import-test.sqlite")
      var db: OpaquePointer?
      guard sqlite3_open(fixtureDB.path, &db) == SQLITE_OK else {
        throw SereinError.invalid("Could not create import fixture")
      }
      sqlite3_exec(
        db,
        "CREATE TABLE urls(url TEXT,title TEXT,last_visit_time INTEGER); INSERT INTO urls VALUES('https://example.com/imported','Imported fixture',13435977600000000);",
        nil, nil, nil)
      sqlite3_close(db)
      let imported = try HistoryImporter.read(fixtureDB)
      try check(
        imported.count == 1 && imported[0].title == "Imported fixture",
        "Chromium history import reads a real SQLite fixture")
      for (name, sql) in [
        (
          "Firefox",
          "CREATE TABLE moz_places(url TEXT,title TEXT,last_visit_date INTEGER); INSERT INTO moz_places VALUES('https://example.com/firefox','Firefox fixture',1760000000000000);"
        ),
        (
          "Safari",
          "CREATE TABLE history_items(id INTEGER,url TEXT); CREATE TABLE history_visits(history_item INTEGER,title TEXT,visit_time REAL); INSERT INTO history_items VALUES(1,'https://example.com/safari'); INSERT INTO history_visits VALUES(1,'Safari fixture',780000000);"
        ),
      ] {
        let url = browser.library.root.appendingPathComponent(name + ".sqlite")
        var connection: OpaquePointer?
        guard sqlite3_open(url.path, &connection) == SQLITE_OK else {
          throw SereinError.invalid("Cannot create import fixture")
        }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
          sqlite3_close(connection)
          throw SereinError.invalid("Cannot populate import fixture")
        }
        sqlite3_close(connection)
        let rows = try HistoryImporter.read(url)
        try check(
          rows.count == 1 && rows[0].title == name + " fixture",
          name + " history schema imports from a real SQLite fixture")
      }
      let sleeper = browser.newTab("", select: false)
      try sleeper.navigate(
        ProcessInfo.processInfo.environment["SEREIN_FIXTURE_URL"] ?? "http://127.0.0.1:18765/")
      // Wait for the fixture to finish loading rather than a fixed delay; a busy Mac can take seconds.
      try await Task.sleep(nanoseconds: 300_000_000)
      for _ in 0..<150 where sleeper.web.isLoading || sleeper.web.url == nil {
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      _ = try await sleeper.script("document.querySelectorAll('input').forEach(e=>e.value='')")
      let originalAddress = sleeper.address
      await sleeper.suspend()
      try check(
        sleeper.sleeping && sleeper.sleepingAddress == originalAddress,
        "Inactive tab suspends while retaining its URL")
      sleeper.wake()
      try check(
        !sleeper.sleeping && sleeper.address == originalAddress,
        "Selecting a sleeping tab restores its address")
      browser.close(sleeper)
      try check(
        ContentBlocking.shared.status.contains("active"), "Native WebKit content rules compile")
      browser.section = ShellSection.start
      let blockerTab = BrowserTab(privateMode: true)
      let baseURL = ProcessInfo.processInfo.environment["SEREIN_FIXTURE_URL"] ?? "http://127.0.0.1:18765/"
      browser.section = ShellSection.start
      let blockerSource = "||127.0.0.1^$script\n##.advert"
      func installRules(_ source: String) async throws {
        let converted = FilterRules.convert(source)
        let compiled: WKContentRuleList = try await withCheckedThrowingContinuation { c in
          WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "SereinIntegration-" + UUID().uuidString,
            encodedContentRuleList: jsonString(converted.rules)
          ) { rule, error in
            if let rule {
              c.resume(returning: rule)
            } else {
              c.resume(throwing: error ?? SereinError.invalid("Rules failed"))
            }
          }
        }
        blockerTab.web.configuration.userContentController.removeAllContentRuleLists()
        blockerTab.web.configuration.userContentController.add(compiled)
        try blockerTab.navigate(baseURL + "blocking")
        for _ in 0..<100 {
          try await Task.sleep(nanoseconds: 100_000_000)
          if !blockerTab.loading && blockerTab.web.url?.path == "/blocking" { break }
        }
      }
      try await installRules(blockerSource)
      let blockedScript =
        try await blockerTab.script(
          "document.documentElement.getAttribute('data-ad-loaded') || 'blocked'") as? String
      let cosmeticDisplay =
        try await blockerTab.script("getComputedStyle(document.querySelector('.advert')).display")
        as? String
      try check(blockedScript == "blocked", "Native content blocker blocks a script request")
      try check(cosmeticDisplay == "none", "Native cosmetic rule hides an advertisement")
      try await installRules(blockerSource + "\n@@||127.0.0.1^$script")
      let allowedScript =
        try await blockerTab.script("document.documentElement.getAttribute('data-ad-loaded')")
        as? String
      try check(allowedScript == "yes", "Network exception permits the previously blocked script")
      try check(
        try await heldTaskWaitsAtLaunch(browser: browser, agent: agent),
        "A held task saved before launch waits for Send instead of sending itself")
      try check(
        try await iconBeforeLoad(browser: browser, baseURL: baseURL),
        "Site icon appears before a slow page finishes; private tabs keep the globe")
      if CommandLine.arguments.contains("--verify-semantic") {
        let sample = Visit(
          url: "https://example.com/bread", title: "Baking sourdough bread",
          text: "A recipe for flour, water and yeast.")
        let other = Visit(
          url: "https://example.com/code", title: "Swift software",
          text: "Compile native programs with a compiler.")
        let query = sample.title + " " + sample.textExcerpt
        let root = browser.library.root.appendingPathComponent("SemanticFixture")
        let first = try await SemanticSearchService.shared.search(
          query: query, visits: [other, sample], library: root)
        let second = try await SemanticSearchService.shared.search(
          query: query, visits: [other, sample], library: root)
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
          throw SereinError.invalid("English embedding unavailable")
        }
        let model = "english-sentence-\(embedding.revision)-\(embedding.dimension)"
        let fingerprint = SemanticIndex.fingerprint(query)
        let index = try SemanticIndex(url: root.appendingPathComponent("index/semantic.sqlite"))
        let persisted = try index.contains(id: sample.id, fingerprint: fingerprint, model: model)
        try await SemanticSearchService.shared.clear(library: root)
        let cleared = try !index.contains(id: sample.id, fingerprint: fingerprint, model: model)
        try check(
          first.first == sample.id && first == second && persisted && cleared,
          "Apple on-device semantic recall persists, reuses and clears embeddings")
      }
      if let filterPath = ProcessInfo.processInfo.environment["SEREIN_FILTER_FIXTURE"] {
        let source = try String(contentsOfFile: filterPath)
        let converted = await Task.detached { FilterRules.convert(source) }.value
        func compileChunk(_ chunk: [[String: Any]]) async throws {
          let identifier = "SereinFilterCheck-" + UUID().uuidString
          let _: WKContentRuleList = try await withCheckedThrowingContinuation { c in
            WKContentRuleListStore.default().compileContentRuleList(
              forIdentifier: identifier, encodedContentRuleList: jsonString(chunk)
            ) { rule, error in
              if let rule {
                c.resume(returning: rule)
              } else {
                c.resume(throwing: error ?? SereinError.invalid("Filter compilation failed"))
              }
            }
          }
          try? await WKContentRuleListStore.default().removeContentRuleList(
            forIdentifier: identifier)
        }
        for chunk in FilterRules.chunks(converted.rules) {
          do { try await compileChunk(chunk) } catch {
            // Report one minimal failing rule instead of hiding the engine diagnostic.
            var failing = chunk
            while failing.count > 1 {
              let half = failing.count / 2
              do {
                try await compileChunk(Array(failing.prefix(half)))
                failing = Array(failing.dropFirst(half))
              } catch { failing = Array(failing.prefix(half)) }
            }
            throw SereinError.invalid(
              "Filter fixture rejected rule: " + jsonString(failing) + " "
                + String(describing: error as NSError))
          }
        }
        try check(
          !converted.rules.isEmpty,
          "External filter fixture compiles: \(converted.rules.count) native rules, \(converted.skipped) unsupported rules"
        )
      }
      if CommandLine.arguments.contains("--verify-agent") {
        let callsBefore = browser.toolAudit.count
        agent.clear()
        agent.autoRouting = false
        agent.mode = .research
        agent.provider = CommandLine.arguments.contains("--verify-claude") ? .claude : .codex
        agent.send(
          "Use the serein_browser list_tabs tool once. Then reply with exactly: SEREIN_AGENT_OK")
        for _ in 0..<1200 {
          if !agent.running { break }
          try await Task.sleep(nanoseconds: 100_000_000)
        }
        if let detail = agent.error { results.append("Agent diagnostic: " + detail) }
        try check(
          !agent.running && agent.error == nil
            && agent.messages.last?.text.contains("SEREIN_AGENT_OK") == true,
          "Live \(agent.provider.rawValue) process and streamed response")
        try check(
          browser.toolAudit.count > callsBefore,
          "Live agent called browser MCP over stdio and Unix socket")
        let sessionID = agent.nativeSessionID
        let callsBeforeResume = browser.toolAudit.count
        agent.send(
          "Use serein_browser list_tabs once with the current connection. Then reply exactly SEREIN_RESUME_OK"
        )
        for _ in 0..<1200 {
          if !agent.running { break }
          try await Task.sleep(nanoseconds: 100_000_000)
        }
        if let detail = agent.error { results.append("Resume diagnostic: " + detail) }
        try check(
          !agent.running && agent.error == nil
            && agent.messages.last?.text.contains("SEREIN_RESUME_OK") == true && sessionID != nil
            && agent.nativeSessionID == sessionID, "Native CLI session resumed with the same ID")
        try check(
          browser.toolAudit.count > callsBeforeResume,
          "Resumed session uses a fresh working MCP capability")
      }
      if CommandLine.arguments.contains("--verify-intelligence") {
        agent.provider = .codex
        let first = Visit(
          url: "https://example.com/swift", title: "Swift documentation",
          text: "Read about Swift structs.")
        let second = Visit(
          url: "https://example.com/swiftui", title: "SwiftUI documentation",
          text: "Read about SwiftUI views.")
        browser.visits = [second, first]
        browser.generateTimeline(day: Date(), agent: agent)
        for _ in 0..<1500 {
          if !browser.intelligenceBusy { break }
          try await Task.sleep(nanoseconds: 100_000_000)
        }
        if browser.timelines[BrowserModel.dayKey(Date())] == nil {
          results.append("Timeline diagnostic: " + (browser.notice ?? "none"))
        }
        try check(
          browser.timelines[BrowserModel.dayKey(Date())]?.episodes.flatMap(\.visitIDs) == [
            first.id, second.id,
          ], "Live browsing episodes validate and persist every visit ID")
        agent.clear()
        agent.mode = .auto
        agent.send("What is 2 plus 2? Answer briefly, without browsing or accessing a project.")
        for _ in 0..<1800 {
          if !agent.running { break }
          try await Task.sleep(nanoseconds: 100_000_000)
        }
        if let error = agent.error { results.append("Router diagnostic: " + error) }
        try check(
          !agent.running && agent.error == nil && agent.mode == .answer
            && agent.messages.last?.text.contains("4") == true,
          "Auto router selects answer mode and completes the request")
        let saved = browser.library.load([Conversation].self, from: "sessions/threads.json") ?? []
        try check(
          saved.contains { $0.id == agent.conversationID && $0.remoteID != nil },
          "Conversation and native session survive disk serialization")
      }

    } catch { results.append("FAIL: " + error.localizedDescription) }
    let report = results.joined(separator: "\n") + "\n"
    print(report)
    try? report.write(
      to: browser.library.root.appendingPathComponent("verification.txt"), atomically: true,
      encoding: .utf8)
    (NSApp as? CheckApplication)?.finished = true
    NSApp.terminate(nil)
  }
}
#endif
