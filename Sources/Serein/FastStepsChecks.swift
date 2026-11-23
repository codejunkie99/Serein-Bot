#if DEBUG
import Foundation
import SereinCore
import WebKit

extension FastSteps {
  /// One live request for a synthetic search page: checks the route, the encoding and the answer.
  static func probe() async throws -> String {
    let job = try JevPolicy.Job(arguments: [
      "goal": "Search for Ada Lovelace", "inputs": ["query": "Ada Lovelace"],
      "checks": ["The search field contains Ada Lovelace"],
    ])
    let prompt = JevPolicy.prompt(
      job, title: "Wikipedia, the free encyclopedia", url: "https://en.wikipedia.org/",
      elements: JevPolicy.Element.list([
        ["ref": "r1", "role": "input", "label": "Search Wikipedia", "acts": ["type"], "value": ""],
        ["ref": "r2", "role": "button", "label": "Search", "acts": ["click"]],
        ["ref": "r3", "role": "a", "label": "Log in", "acts": ["click"]],
      ]), history: [])
    guard JSONSerialization.isValidJSONObject(["state": prompt.state, "questions": prompt.questions]) else {
      throw SereinError.invalid("The request is not valid JSON")
    }
    let started = Date()
    let (answers, full) = try await ask(state: prompt.state, questions: prompt.questions)
    let ms = Int(Date().timeIntervalSince(started) * 1000)
    let d = try JevPolicy.decide(answers, prompt, job, fullDistribution: full)
    if ProcessInfo.processInfo.environment["SEREIN_PROBE_RAW"] != nil {
      for (name, value) in answers.sorted(by: { $0.key < $1.key }) {
        let v = value as? [String: Any] ?? [:]
        print("  \(name): \(v["choice"] ?? "?") confidence=\(v["confidence"] ?? "?") keys=\(v.keys.sorted())")
      }
    }
    return "PASS: Jev answered in \(ms) ms: \(d.operation?.rawValue ?? d.terminal?.rawValue ?? "?") "
      + "\(d.target?.label ?? "-") input=\(d.inputKey ?? "-") enter=\(d.enter) confidence=\(d.confidence)"
  }
}

extension SmokeTest {
  /// Fast steps against the local fixture, with scripted Jev answers: no provider request or key.
  @MainActor static func fastSteps(browser: BrowserModel, approvals: FixtureApprovals) async throws -> [String] {
    var results: [String] = []
    func check(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label) }
      results.append("PASS: " + label)
    }
    let base = ProcessInfo.processInfo.environment["SEREIN_FIXTURE_URL"] ?? "http://127.0.0.1:18765/"
    var asked: [[String: Any]] = []
    var script: [([String: Any], [String: Any]) throws -> [String: Any]] = []
    FastSteps.scripted = { state, questions in
      asked.append(state)
      guard !script.isEmpty else { throw SereinError.invalid("Unexpected Jev request") }
      return try script.removeFirst()(state, questions)
    }
    defer { FastSteps.scripted = nil }
    func answer(_ choice: String, _ question: Any?) -> [String: Any] {
      let ids = Set(((question as? [String: Any])?["criteria"] as? [String: Any] ?? [:]).keys)
      var p: [String: Any] = [:]
      for id in ids { p[id] = id == choice ? 0.9 : 0.1 / Double(max(1, ids.count - 1)) }
      if ids.count == 1 { p[choice] = 1.0 }
      return ["choice": choice, "confidence": 0.9, "probabilities": p]
    }
    func id(_ state: [String: Any], _ label: String) -> String {
      let rows = (state["page"] as? [String: Any])?["elements"] as? [[Any]] ?? []
      return rows.first { $0.count > 2 && $0[2] as? String == label }?.first as? String ?? "?"
    }
    func targets(_ question: Any?) -> Set<String> {
      Set(((question as? [String: Any])?["criteria"] as? [String: Any] ?? [:]).keys)
    }

    let task = try browser.beginTask(isolated: true, allowActions: true, includeCurrent: false)
    defer { browser.endTask(task.capability.task) }
    func call(_ name: String, _ args: [String: Any],
              expecting cards: [FixtureApprovals.Card] = []) async throws -> [String: Any] {
      try await approvals.perform(expecting: cards) {
        try await browser.handle([
          "task": task.capability.task, "token": task.capability.token, "name": name, "arguments": args,
        ])
      }
    }
    let opened = try await call("open_tab", ["url": base + "form"],
                                expecting: [.site(url: base + "form")])
    let tab = opened["tab"] as? String ?? ""
    try check(opened["title"] as? String == "Form fixture", "Open returns the loaded page")

    // Type, click, then complete: three requests, two actions, through PageKit.
    var deleteOffered = true
    script = [
      { state, q in
        deleteOffered = targets(q["click_target"]).contains(id(state, "Delete all"))
        return [
          "operation": answer("TYPE_TEXT", q["operation"]),
          "type_text_target": answer(id(state, "Message"), q["type_text_target"]),
          "input": answer("message", q["input"]), "type_text_then_key": answer("NONE", q["type_text_then_key"]),
        ]
      },
      { state, q in
        ["operation": answer("CLICK", q["operation"]), "click_target": answer(id(state, "Apply"), q["click_target"])]
      },
      { _, q in
        ["operation": answer("SUBTASK_COMPLETE", q["operation"]), "verification_0": answer("SATISFIED", q["verification_0"])]
      },
    ]
    let run = try await call("do", [
      "tab": tab, "goal": "Write the message and apply it", "inputs": ["message": "hello jev"],
      "checks": ["The page says Sent: hello jev"],
    ], expecting: [
      .init(title: "Serein wants to type on this page",
            detail: "Check this before you allow it."),
      .init(title: "Serein wants to click on this page",
            detail: "This may change something. Check it before you allow it.\nTarget: Apply"),
    ])
    let tabModel = browser.tasks[task.capability.task]?.tabs.first { $0.id == tab }
    let shown = try await tabModel?.script("document.querySelector('#result').textContent") as? String
    try check(
      run["status"] as? String == "SUBTASK_COMPLETE" && (run["steps"] as? [Any])?.count == 2
        && shown == "Sent: hello jev",
      "Fast steps type and click through PageKit, then complete")
    try check(!deleteOffered, "A risky control is not offered unless the job allows it")
    let history = asked.last?["recent_actions"] as? [String] ?? []
    try check(
      history.count == 2 && history[1].contains("CLICK") && history[1].hasSuffix("page changed"),
      "Each request carries the recent steps and whether the page changed")
    try check(
      jsonString(asked).range(of: "e[0-9a-f-]{8,}_[0-9]+_[0-9]+", options: .regularExpression) == nil,
      "PageKit references stay in Serein")

    // No supplied value fits: the run hands back without typing.
    asked = []
    script = [
      { state, q in
        [
          "operation": answer("TYPE_TEXT", q["operation"]),
          "type_text_target": answer(id(state, "Message"), q["type_text_target"]), "input": answer("NONE", q["input"]),
        ]
      }
    ]
    let missing = try await call("do", ["tab": tab, "goal": "Write a reply"])
    try check(missing["status"] as? String == "NEEDS_INPUT" && asked.count == 1, "A missing value returns NEEDS_INPUT")

    // A page with a password field is never sent.
    asked = []
    script = []
    let other = try await call("open_tab", ["url": base])
    let refused = try await call("do", ["tab": other["tab"] as? String ?? "", "goal": "Sign in"])
    try check(
      refused["status"] as? String == "NEEDS_USER" && asked.isEmpty,
      "A page with the user's steps is never sent to the decision model")

    // Website actions off: the tool is refused like click and type.
    let readOnly = try browser.beginTask(isolated: true, allowActions: false, includeCurrent: false)
    defer { browser.endTask(readOnly.capability.task) }
    do {
      _ = try await browser.handle([
        "task": readOnly.capability.task, "token": readOnly.capability.token, "name": "do",
        "arguments": ["tab": "x", "goal": "y"],
      ])
      try check(false, "Fast steps refused without website actions")
    } catch {
      try check(error.localizedDescription.contains("Website actions are off"), "Fast steps refused without website actions")
    }
    return results
  }
}
#endif
