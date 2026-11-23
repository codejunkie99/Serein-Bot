#if DEBUG
import Foundation
import SereinCore

/// `--verify-repl`: the repl tool against a local fixture (SEREIN_FIXTURE_URL serves form.html with
/// Name, City and Send, and page2.html). No provider is involved.
@MainActor func checkRepl() async throws {
  setenv("SEREIN_BENCH_REPL", "1", 1)
  let base = ProcessInfo.processInfo.environment["SEREIN_FIXTURE_URL"] ?? "http://127.0.0.1:18766/"
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("serein-repl-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: root) }
  let browser = try BrowserModel(root: root, prepareHistoryAsynchronously: true)
  func check(_ condition: Bool, _ label: String, _ detail: Any = "") throws {
    guard condition else { throw SereinError.invalid("FAIL: \(label) \(detail)") }
    print("PASS: " + label)
  }
  func repl(_ task: BrowserTask, _ code: String) async throws -> [String: Any] {
    try await browser.handle([
      "task": task.capability.task, "token": task.capability.token, "name": "repl", "arguments": ["code": code],
    ])
  }
  let task = try browser.beginTask(isolated: true, allowActions: true, includeCurrent: false)
  defer { browser.endTask(task.capability.task) }

  let form = try await repl(task, """
    const t = await openTab('\(base)form.html');
    await t.fill('Name', 'Ada');
    await t.select('City', 'Rome');
    await t.click('Send');
    log(t.text.includes('Sent Ada Rome'));
    globalThis.kept = 41;
    return t.id;
    """)
  try check(form["log"] as? String == "true" && form["steps"] as? Int == 4 && form["error"] == nil,
    "One call opens a page, fills, selects and clicks by the element's words", form)
  // Refs change after every action; a program written with the first page's refs still works.
  let stale = try await repl(task, """
    const t = page, p = await t.read(), name = t.find('Name').ref, city = t.find('City').ref;
    const after = await t.fill(name, 'Eve');
    await t.select(city, 'Paris');
    return [after.elements.length > 0, name !== t.find('Name').ref, t.find('Name').value];
    """)
  try check((stale["result"] as? [Any]).map { $0[0] as? Bool == true && $0[1] as? Bool == true && $0[2] as? String == "Eve" } == true,
    "A ref from an earlier page still finds its element, and actions return the page", stale)
  let roles = try await repl(task, "const t = page; await t.fill({ role: 'textbox', name: 'Name' }, 'Ann'); await t.select('Destination', 'Rome'); return t.find({ role: 'textbox' }).value")
  try check(roles["result"] as? String == "Ann", "ARIA roles match tag rows, and select finds its list by the value", roles)
  let failed = try await repl(task, "await page.click('Nothing here')")
  let next = try await repl(task, "return page.elements.length")
  try check(failed["error"] != nil && (next["result"] as? Int ?? 0) > 0, "A failed program leaves the next one a usable page", next)
  let kept = try await repl(task, "return kept + 1")
  try check(kept["result"] as? Int == 42 && kept["tab"] as? String == form["result"] as? String,
    "Values on globalThis persist between calls, and the result names the tab", kept)
  let diff = try await repl(task, "await page.snapshot(); await page.fill('Name', 'Bob'); return (await page.snapshot()).diff")
  try check((diff["result"] as? String)?.contains("value=\"Bob\"") == true, "snapshot returns what changed", diff)
  let missing = try await repl(task, "await page.click('No such button')")
  try check((missing["error"] as? String)?.contains("No element matches") == true && missing["page"] != nil,
    "A failed step returns its error and the page", missing)
  let fetched = try await repl(task, "const r = await fetch('\(base)page2.html'); return r.ok && (await r.text()).includes('Second page')")
  try check(fetched["result"] as? Bool == true, "fetch reads an address without a page", fetched)
  let plain = try await repl(task, "return (await fetch('\(base)form.html')).pageText()")
  try check((plain["result"] as? String).map { $0.hasPrefix("Form\nOrder") && !$0.contains("<") } == true, "pageText gives readable text", plain)
  let both = try await repl(task, "const [a, b] = await Promise.all([openTab('\(base)page2.html'), openTab('\(base)long.html')]); await a.close(); await b.close(); return [a.text.includes('Second page'), b.text.includes('Paragraph 199')]")
  try check((both["result"] as? [Bool]) == [true, true], "Two tabs open at the same time", both)
  let url = try await repl(task, "const u = new URL('../b?q=1&r=a+b#x', 'https://e.com/a/c'); await new Promise(r => setTimeout(r, 10)); return [u.pathname, u.search, u.hash, u.searchParams.get('r'), u.host]")
  try check((url["result"] as? [String]) == ["/b", "?q=1&r=a+b", "#x", "a b", "e.com"], "URL, URLSearchParams and setTimeout work", url)
  let single = try await browser.handle([
    "task": task.capability.task, "token": task.capability.token, "name": "open_tab", "arguments": ["url": base + "page2.html"],
  ])
  let current = try await repl(task, "return [page.id, tabs().length, tabs().at(-1).id]")
  try check((current["result"] as? [Any]).map { $0[0] as? String == single["tab"] as? String && $0[1] as? Int == 2 && $0[2] as? String == single["tab"] as? String } == true,
    "page starts at the tab of the agent's latest call, and tabs() lists the task's tabs", current)
  let long = try await repl(task, "const t = await openTab('\(base)long.html'); await t.click('More'); return t.text.length")
  try check((long["result"] as? Int ?? 0) > 3000, "Action results keep the whole page text inside a program", long)
  let refused = try await repl(task, "await __call('finish', '{}')")
  try check((refused["error"] as? String)?.contains("not available in repl") == true, "Tools outside the list are refused", refused)
  let started = Date()
  let loop = try await repl(task, "while (true) {}")
  try check((loop["error"] as? String)?.contains("terminated") == true && Date().timeIntervalSince(started) < 6,
    "A runaway loop stops at the CPU limit", loop)
  let after = try await repl(task, "return 1 + 1")
  try check(after["result"] as? Int == 2, "The context works after a stopped loop", after)
  let syntax = try await repl(task, "return (")
  try check((syntax["error"] as? String)?.contains("SyntaxError") == true, "A syntax error comes back as an error", syntax)

  let readOnly = try browser.beginTask(isolated: true, allowActions: false, includeCurrent: false)
  defer { browser.endTask(readOnly.capability.task) }
  let off = try await repl(readOnly, "const t = await openTab('\(base)form.html'); await t.click('Send')")
  try check((off["error"] as? String)?.contains("Website actions are off") == true,
    "Each step keeps the actions switch of a single call", off)
}
#endif
