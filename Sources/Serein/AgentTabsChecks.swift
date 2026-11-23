#if DEBUG
import Foundation
import SereinCore
import WebKit

extension SmokeTest {
  /// Agent tabs, take over, hand-back and web-task tools against the local fixture.
  /// Runs use a harmless long-running process; no provider is involved.
  @MainActor static func agentTabs(browser: BrowserModel, agent: AgentModel, approvals: FixtureApprovals) async throws
    -> [String]
  {
    var results: [String] = []
    func check(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label) }
      results.append("PASS: " + label)
    }
    let base = ProcessInfo.processInfo.environment["SEREIN_FIXTURE_URL"] ?? "http://127.0.0.1:18765/"
    let hub = agent.hub
    func launch(_ name: String, actions: Bool, seconds: String = "60") throws -> (AgentRun, BrowserTask) {
      let task = try browser.beginTask(isolated: true, allowActions: actions, includeCurrent: false)
      let spec = RunSpec(
        threadID: "check-" + name, provider: .codex, executable: "/bin/sleep", model: "",
        effort: "low", mode: .research, projectID: nil, projectName: nil, title: "Check " + name,
        scope: "", autoRouting: false, grants: RunGrants(), limits: RunLimits(hard: 120, idle: 120))
      do {
        return (
          try hub.start(
            spec, task: task, arguments: [seconds], folder: browser.library.root, prompt: "",
            transcript: []), task
        )
      } catch {
        browser.endTask(task.capability.task)
        throw error
      }
    }
    func call(_ task: BrowserTask, _ name: String, _ args: [String: Any],
              expecting cards: [FixtureApprovals.Card] = []) async throws -> [String: Any] {
      try await approvals.perform(expecting: cards) {
        try await browser.handle([
          "task": task.capability.task, "token": task.capability.token, "name": name,
          "arguments": args,
        ])
      }
    }
    // Ordinary actions on the options page go through the normal approval card.
    func optionCard(_ action: String, target: String) -> FixtureApprovals.Card {
      .init(title: "Serein wants to \(action) on this page",
            detail: (action == "type" ? "Check this before you allow it." : "This may change something. Check it before you allow it.") + "\nTarget: \(target)",
            thread: "check-tabs-a")
    }
    func loaded(_ id: String) async throws -> BrowserTab {
      guard let tab = browser.agentTabs.entry(id)?.tab else {
        throw SereinError.invalid("Agent tab missing from the board")
      }
      for _ in 0..<100 {
        if !tab.web.isLoading, tab.web.url?.absoluteString.hasPrefix(base) == true { break }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      await tab.settle(limit: 3)
      return tab
    }
    func ref(_ outline: [String: Any], _ label: String) -> String? {
      (outline["elements"] as? [[String: Any]])?.first { ($0["label"] as? String) == label }?["ref"]
        as? String
    }
    func refusal(_ body: () async throws -> Any) async -> String? {
      do {
        _ = try await body()
        return nil
      } catch { return error.localizedDescription }
    }

    // Run A: visible while working, page tools, hand-back, then take over.
    let (runA, taskA) = try launch("tabs-a", actions: true)
    let opened = try await call(taskA, "open_tab", ["url": base + "checkout"],
      expecting: [.site(url: base, thread: "check-tabs-a")])
    let id = opened["tab"] as? String ?? ""
    let tab = try await loaded(id)
    let board = browser.agentTabs
    try check(
      board.entries(thread: "check-tabs-a", known: []).contains { $0.id == id }
        && board.isWorking(id) && board.badge(id) == "Codex is working here"
        && board.info(id)?.isolated == true && !browser.tabs.contains { $0.id == id },
      "Agent tab is listed under its run with a working badge while the agent runs")
    let outline = try await call(taskA, "read", ["tab": id])
    try check(
      outline["sensitive"] as? Bool == true
        && (outline["user_steps"] as? [String])?.contains("card") == true
        && outline["user_note"] as? String == SecureCard.readNote
        && (outline["elements"] as? [[String: Any]])?.contains {
          $0["secure"] as? String == "card" && $0["label"] as? String == "Card number"
            && $0["acts"] as? [String] == ["secure_card"] && $0["value"] == nil
        } == true,
      "Read marks card entry as the user’s step and exposes only the secure entry action")
    guard let payTarget = ref(outline, "Check") else { throw SereinError.invalid("Checkout button missing") }
    let paymentRefusal = await refusal { try await call(taskA, "click", ["tab": id, "ref": payTarget]) }
    let beforePay = try await tab.script("document.querySelector('#status').textContent") as? String
    guard paymentRefusal == SecureCard.payOnCard, beforePay == "Ready" else {
      throw SereinError.invalid("A direct checkout press must require the person's payment step")
    }
    _ = try await call(taskA, "navigate", ["tab": id, "url": base + "options"])
    let options = try await call(taskA, "read", ["tab": id])
    guard let size = ref(options, "Size") else { throw SereinError.invalid("Size list missing") }
    _ = try await call(taskA, "select", ["tab": id, "ref": size, "value": "medium"],
      expecting: [optionCard("select", target: "Size")])
    let picked = try await tab.script("document.querySelector('#size').value") as? String
    try check(picked == "m2", "Select picks an option by its visible words")
    let again = try await call(taskA, "read", ["tab": id])
    guard let button = ref(again, "Check") else {
      throw SereinError.invalid("Checkout controls missing")
    }
    _ = try await call(taskA, "click", ["tab": id, "ref": button],
      expecting: [optionCard("click", target: "Check")])
    let waited = try await call(taskA, "wait", ["tab": id])
    let settledStatus = try await tab.script("document.querySelector('#status').textContent") as? String
    try check(
      waited["sensitive"] as? Bool == false
        && (waited["text"] as? String)?.contains("Checked") == true && settledStatus == "Checked",
      "Wait returns once a working page goes quiet")
    let fresh = try await call(taskA, "read", ["tab": id])
    guard let field = ref(fresh, "Gift note") else { throw SereinError.invalid("Note missing") }
    _ = try await call(taskA, "fill", ["tab": id, "ref": field, "text": "Happy birthday"],
      expecting: [optionCard("type", target: "Gift note")])
    let digits = await refusal { try await call(taskA, "fill", ["tab": id, "ref": field, "text": "4242 4242 4242 4242"]) }
    try check(
      digits?.contains("This step is yours") == true,
      "Card-like text is refused in any field with the hand-back message")
    // Typing a card number in chunks is caught on the field's final value.
    func noteRef() async throws -> String {
      guard let found = ref(try await call(taskA, "read", ["tab": id]), "Gift note") else {
        throw SereinError.invalid("Note missing")
      }
      return found
    }
    _ = try await call(taskA, "fill", ["tab": id, "ref": try await noteRef(), "text": "4242 4242"],
      expecting: [optionCard("type", target: "Gift note")])
    let chunkRef = try await noteRef()
    let chunked = await refusal {
      try await call(taskA, "fill", ["tab": id, "ref": chunkRef, "text": " 4242 4242", "append": true],
        expecting: [optionCard("type", target: "Gift note")])
    }
    let afterChunks = try await tab.script("document.querySelector('#note').value") as? String
    try check(
      chunked?.contains("This step is yours") == true && afterChunks == "4242 4242",
      "A card number typed in chunks is refused on the field's final value")
    _ = try await call(taskA, "fill", ["tab": id, "ref": try await noteRef(), "text": "Happy birthday"],
      expecting: [optionCard("type", target: "Gift note")])
    // A checkout form that turns the field into a card-number field after the read.
    let latest = try await call(taskA, "read", ["tab": id])
    guard let morphing = ref(latest, "Gift note") else { throw SereinError.invalid("Note gone") }
    _ = try await tab.script(
      "document.querySelector('#note').setAttribute('autocomplete','cc-number'); true")
    let cardField = try await call(taskA, "fill", ["tab": id, "ref": morphing, "text": "hello"])
    let unchangedNote = try await tab.script("document.querySelector('#note').value") as? String
    let entryCard = browser.secureCards.open.first { $0.task == taskA.capability.task && $0.ref == morphing }
    try check(
      cardField["result"] as? String == "asked" && entryCard?.kind == .card && unchangedNote == "Happy birthday"
        && !String(describing: cardField).contains("Happy birthday"),
      "A field that becomes secure offers secure entry and keeps its previous value")
    if let entryCard { browser.secureCards.decline(entryCard.id) }
    _ = try await tab.script("document.querySelector('#note').removeAttribute('autocomplete'); true")
    // Take over: stops run A, revokes only its capability, keeps the page.
    let addressBefore = tab.address
    browser.takeOver(tab)
    let revoked = await refusal { try await call(taskA, "list_tabs", [:]) }
    try check(
      revoked?.contains("expired") == true && runA.record.outcome == .stopped
        && browser.tasks[taskA.capability.task] == nil,
      "Take over stops the run and revokes its capability")
    let kept = try await tab.script("document.querySelector('#note').value") as? String
    try check(
      browser.tabs.contains { $0.id == id } && tab.owner == nil && kept == "Happy birthday"
        && tab.address == addressBefore && !tab.web.configuration.websiteDataStore.isPersistent
        && tab.takenFrom?.contains("isolated") == true && board.entry(id) == nil,
      "Taken-over tab joins your tabs with its page intact and stays isolated")
    browser.close(tab)

    // Read-only screenshots: allowed on plain pages, and on pages with the user's own fields with
    // what was typed there blanked (bug 18).
    let readOnly = try browser.beginTask(isolated: true, allowActions: false, includeCurrent: false)
    let plain = try await call(readOnly, "open_tab", ["url": base + "plain"],
      expecting: [.site(url: base + "plain")])
    _ = try await loaded(plain["tab"] as? String ?? "")
    let picture = try await call(readOnly, "screenshot", ["tab": plain["tab"] ?? ""])
    try check(
      (picture["content"] as? [[String: Any]])?.first?["type"] as? String == "image",
      "Screenshot works read-only on a page without sensitive fields")
    let payment = try await call(readOnly, "open_tab", ["url": base + "checkout"])
    _ = try await loaded(payment["tab"] as? String ?? "")
    let paymentTab = try await loaded(payment["tab"] as? String ?? "")
    _ = try await paymentTab.script("document.querySelector('#card').value='4242 4242 4242 4242';true")
    let cardShot = await refusal { try await call(readOnly, "screenshot", ["tab": payment["tab"] ?? ""]) }
    let cardColour = try await paymentTab.script(
      "(()=>{globalThis.__serein.blank();const c=getComputedStyle(document.querySelector('#card')).opacity;globalThis.__serein.unblank();return c})()") as? String
    try check(cardShot == nil && cardColour == "0", "Screenshot of a card page has the card number blanked")
    browser.endTask(readOnly.capability.task)

    // Run B: tab cap, then an isolated finish keeps its result tab after the run ends (bug 1).
    let (runB, taskB) = try launch("tabs-b", actions: false)
    let first = try await call(taskB, "open_tab", ["url": base + "plain"],
      expecting: [.site(url: base, thread: "check-tabs-b")])
    let resultID = first["tab"] as? String ?? ""
    for _ in 1..<AgentTabPolicy.maxTabs { _ = try await call(taskB, "open_tab", ["url": base + "plain"]) }
    let capped = await refusal { try await call(taskB, "open_tab", ["url": base + "plain"]) }
    try check(
      capped?.contains("\(AgentTabPolicy.maxTabs) tabs") == true
        && board.entries(thread: "check-tabs-b", known: []).count == AgentTabPolicy.maxTabs,
      "A task can open at most \(AgentTabPolicy.maxTabs) tabs")
    _ = try await call(taskB,
      "finish",
      ["outcome": "waiting", "summary": "Pick a delivery date in this tab.", "result_tab": resultID])
    hub.stop(runB)
    let steps = board.runs[taskB.capability.task]?.steps ?? []
    try check(
      board.entry(resultID) != nil && board.entries(thread: "check-tabs-b", known: []).count == 1
        && board.bubble(resultID) == TabBubble(kind: .waiting, text: "Pick a delivery date in this tab.")
        && board.unseen.contains(resultID) && steps.first?.label.hasPrefix("Opened") == true
        && steps.last?.tool == "finish" && zip(steps, steps.dropFirst()).allSatisfy { $0.time <= $1.time }
        && browser.tasks[taskB.capability.task] == nil,
      "Finished isolated task keeps its result tab with a bubble and timed steps")
    board.dismiss(resultID)

    // Screenshots fail closed: a frame Serein cannot check means no picture.
    let framed = try browser.beginTask(isolated: true, allowActions: false, includeCurrent: false)
    let framedTab = try await call(framed, "open_tab", ["url": base + "plain"],
      expecting: [.site(url: base + "plain")])
    let framedID = framedTab["tab"] as? String ?? ""
    let framedPage = try await loaded(framedID)
    // An empty ad frame and a same-origin srcdoc frame are probed through the parent, so the
    // read-only screenshot still works; a sandboxed frame, which cannot be read, keeps refusing;
    // a cross-origin frame with a password field answers for itself and is blanked.
    _ = try await framedPage.script(
      "document.body.appendChild(document.createElement('iframe')); document.body.appendChild(Object.assign(document.createElement('iframe'),{srcdoc:'<p>inner</p>'})); true")
    try await Task.sleep(nanoseconds: 300_000_000)
    let emptyFrames = await refusal { try await call(framed, "screenshot", ["tab": framedID]) }
    try check(
      emptyFrames == nil, "Screenshot is allowed when the only frames are empty or same-origin srcdoc")
    _ = try await framedPage.script(
      "document.body.appendChild(Object.assign(document.createElement('iframe'),{srcdoc:'<p>x</p>',sandbox:''})); true")
    try await Task.sleep(nanoseconds: 300_000_000)
    let unchecked = await refusal { try await call(framed, "screenshot", ["tab": framedID]) }
    try check(
      unchecked?.contains("not pictured") == true,
      "Screenshot is refused when a frame on the page cannot be checked")
    let cardURL = base.replacingOccurrences(of: "127.0.0.1", with: "localhost") + "frame"
    let cardTab = try await call(framed, "open_tab", ["url": base + "plain"])
    let cardID = cardTab["tab"] as? String ?? ""
    let cardPage = try await loaded(cardID)
    _ = try await cardPage.script(
      "document.body.appendChild(Object.assign(document.createElement('iframe'),{src:'\(cardURL)'})); true")
    try await Task.sleep(nanoseconds: 1_200_000_000)
    let framedCard = await refusal { try await call(framed, "screenshot", ["tab": cardID]) }
    try check(framedCard == nil, "A cross-origin frame with a password field is pictured with the field blanked")
    browser.endTask(framed.capability.task)

    // Keep tab after finish releases the tab without stopping the run; the run record takes
    // the agent's own outcome; a rejected call never marks an earlier step as failed.
    let (runC, taskC) = try launch("tabs-c", actions: false, seconds: "6")
    let handed = try await call(taskC, "open_tab", ["url": base + "plain"],
      expecting: [.site(url: base, thread: "check-tabs-c")])
    let handedID = handed["tab"] as? String ?? ""
    let handedTab = try await loaded(handedID)
    _ = try await call(taskC,
      "finish", ["outcome": "waiting", "summary": "Sign in here.", "result_tab": handedID])
    _ = await refusal { try await call(taskC, "finish", ["outcome": "done"]) }
    let lastStep = board.runs[taskC.capability.task]?.steps.last
    try check(
      lastStep?.tool == "finish" && lastStep?.failed == nil,
      "A rejected duplicate call does not mark the earlier finish step as failed")
    browser.takeOver(handedTab)
    try check(
      runC.isActive && handedTab.owner == nil && browser.tabs.contains { $0.id == handedID }
        && handedTab.web.configuration.userContentController.userScripts.contains {
          $0.source.contains(PasswordCapture.marker)
        },
      "Keep tab after finish leaves the run going and makes the tab a full user tab")
    for _ in 0..<150 where runC.isActive { try await Task.sleep(nanoseconds: 100_000_000) }
    try check(
      runC.record.outcome == .waiting && runC.record.summary == "Sign in here.",
      "The run record keeps the agent's own finish outcome")
    browser.close(handedTab)

    // Kept result tabs are capped and idle ones are unloaded. Start from an empty board so
    // result tabs left by earlier checks (which may still be focused) don't change the count.
    board.focused = nil
    for entry in board.entries where board.runs[entry.taskID]?.ended == true {
      board.dismiss(entry.id)
    }
    var keptTabs: [BrowserTab] = []
    for i in 0..<(AgentTabBoard.maxKept + 2) {
      let kept = BrowserTab(privateMode: true, owner: "kept-\(i)", store: .nonPersistent())
      kept.address = base + "plain"
      board.opened(kept, task: "kept-\(i)", isolated: true)
      _ = board.taskEnded("kept-\(i)", tabs: [kept])
      keptTabs.append(kept)
    }
    let keptCount = keptTabs.filter { board.entry($0.id) != nil }.count
    board.unloadIdle(now: Date().addingTimeInterval(AgentTabBoard.idleUnload + 60))
    let survivors = keptTabs.filter { board.entry($0.id) != nil }
    try check(
      keptCount == AgentTabBoard.maxKept && board.entry(keptTabs[0].id) == nil
        && survivors.allSatisfy(\.sleeping),
      "At most \(AgentTabBoard.maxKept) result tabs are kept, and idle ones are unloaded")
    for kept in survivors { board.dismiss(kept.id) }

    // × on a task's tab closes the tab only: the task keeps working in the hub.
    let (closing, closingTask) = try launch("close-tab", actions: false)
    agent.showThreadTab(closing.spec.threadID)
    let tabbed = agent.openThreads.contains(closing.spec.threadID)
    agent.closeThreadTab(closing.spec.threadID)
    let keptWorking = closing.isActive && hub.run(for: closing.spec.threadID) === closing
      && !agent.openThreads.contains(closing.spec.threadID) && browser.tasks[closingTask.capability.task] != nil
    hub.stop(closing)
    try check(tabbed && keptWorking, "Closing a task’s tab leaves it working")

    // Plan approval never turns on the user's own edit setting; leaving research drops the
    // sign-in approval.
    let context = ComposerContext.shared
    let savedMode = agent.mode
    agent.mode = .project
    agent.allowProjectEdits = false
    context.awaitingApproval.insert(agent.conversationID)
    let approval = context.prepare("Go ahead", agent: agent, browser: browser)
    let notApproval = context.prepare("ok, which files?", agent: agent, browser: browser)
    context.awaitingApproval.remove(agent.conversationID)
    agent.mode = .research
    WebTaskGrant.shared.grant(thread: agent.conversationID)
    agent.mode = .answer
    let grantDropped = !WebTaskGrant.shared.isGranted(thread: agent.conversationID)
    agent.mode = savedMode
    try check(
      approval.approved && !notApproval.approved && !agent.allowProjectEdits && grantDropped,
      "Approving a plan leaves the edit setting alone, and leaving research drops the sign-in approval")
    return results
  }
}
#endif
