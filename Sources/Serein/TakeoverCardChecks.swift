#if DEBUG
import Foundation
import SereinCore
import WebKit

@MainActor func checkTakeoverCards() async throws -> Bool {
  guard let data = ProcessInfo.processInfo.environment["SEREIN_DATA_DIR"] else {
    throw SereinError.invalid("Takeover card checks need an isolated test library (SEREIN_DATA_DIR).")
  }
  let root = URL(fileURLWithPath: data).appendingPathComponent("takeover", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let browser = try BrowserModel(root: root)
  defer { browser.shutdown() }
  var failed = false
  func check(_ ok: Bool, _ label: String) {
    print((ok ? "PASS: " : "FAIL: ") + label)
    if !ok { failed = true }
  }
  let task = try browser.beginTask(isolated: true, allowActions: true, includeCurrent: false)
  let id = task.capability.task
  browser.setSites(["127.0.0.1"], taskID: id)
  let tab = BrowserTab(privateMode: true, owner: id, store: task.store)
  let other = BrowserTab(privateMode: true, owner: id, store: task.store)
  browser.tasks[id]?.tabs += [tab, other]
  browser.agentTabs.opened(tab, task: id, isolated: true)
  browser.agentTabs.opened(other, task: id, isolated: true)
  func call(_ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
    try await browser.handle(["task": id, "token": task.capability.token, "name": name, "arguments": arguments])
  }
  func load(_ page: BrowserTab, _ html: String) async {
    page.web.loadHTMLString(html, baseURL: URL(string: "http://127.0.0.1/check"))
    for _ in 0..<100 {
      try? await Task.sleep(nanoseconds: 50_000_000)
      if !page.web.isLoading, page.web.url != nil { break }
    }
    await page.settle(limit: 3)
  }
  func title() async -> String { (try? await tab.web.evaluateJavaScript("document.title")) as? String ?? "" }
  let line = Boundary.botCheck.blocked.text

  await load(tab, UIPreview.takeoverCheckPage)
  await load(other, "<!doctype html><title>Other</title><p>Order summary</p>")
  let read = try await call("read", ["tab": tab.id])
  check(
    read["message"] as? String == line && browser.takeoverCards.open.first?.tab === tab,
    "A read of a check page opens the takeover card and returns the botCheck line")

  let human = (read["elements"] as? [[String: Any]])?.first { $0["label"] as? String == "I am human" }?["ref"] as? String
  let pressed = try await call("click", ["tab": tab.id, "ref": human ?? "x0"])
  check(
    pressed["message"] as? String == line && pressed["reason"] as? String == "captcha",
    "A press inside the check is a plain result with the botCheck line, not a refusal")
  check(await title() == "Just a moment...", "Serein never presses inside the check: the page is unchanged")
  check(browser.tasks[id]?.finished == false && browser.takeoverCards.open.count == 1, "The task keeps running with one card")

  let asked = try await call(TakeoverCard.tool, ["tab": tab.id, "reason": "The shop asks you to confirm you are human."])
  let card = browser.takeoverCards.open.first
  check(
    asked["asked"] as? String == TakeoverCard.asked && card?.tab === tab && card?.holder == .assistant
      && card?.host == "127.0.0.1",
    "ask_person_takeover returns at once and opens one card, Watching, for that tab")
  _ = try await call(TakeoverCard.tool, ["tab": tab.id, "reason": "again"])
  check(browser.takeoverCards.open.count == 1, "A second ask for the same tab keeps the one card")

  let elsewhere = try await call("read", ["tab": other.id])
  check(
    jsonString(elsewhere).contains("Order summary") && browser.tasks[id]?.finished == false,
    "While the card waits, the rest of the task goes on in another tab")

  guard let card else { return false }
  browser.takeoverCards.takeControl(card.id)
  let held = try await call("read", ["tab": tab.id])
  check(
    browser.takeoverCards.open.first?.holder == .person && held["person_step"] as? String == TakeoverCard.held,
    "Take control gives the person the tab; the model's calls on it answer that the person has it")

  _ = try await tab.web.evaluateJavaScript("document.getElementById('human').click()")
  check(await title() == "Checkout", "The person's own press clears the check")
  browser.takeoverCards.close(card.id, .handedBack)
  check(browser.takeoverCards.open.isEmpty, "Hand back closes the card")
  let after = try await call("read", ["tab": tab.id])
  check(
    after["person_step"] == nil && after["reason"] as? String != "captcha" && browser.tasks[id]?.finished == false,
    "After Hand back the model reads the cleared page in the same running task")
  check(
    TakeoverCard.followUp(host: "127.0.0.1", tab: tab.id, ending: .handedBack).contains("handed tab \(tab.id) back")
      && TakeoverCard.followUp(host: "127.0.0.1", tab: tab.id, ending: .dismissed).contains("without doing the step"),
    "The follow-up turn says the tab was handed back, or that the card was closed")
  check(
    TaskPrompt.core(served: []).contains(TakeoverCard.promptLine) && !WebTaskPrompt.text(isolated: true, actions: true).contains(TakeoverCard.promptLine)
      && ToolSchema.tools(isolated: true).contains { $0["name"] as? String == TakeoverCard.tool },
    "Both prompts name ask_person_takeover, and isolated tasks get the tool")
  return !failed
}
#endif
