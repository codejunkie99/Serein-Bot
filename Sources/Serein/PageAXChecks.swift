#if DEBUG
import Foundation
import SereinCore

extension PageAX {
  /// `--probe-ax <url>`: opens the page in an agent tab, prints the merged controls and the read time,
  /// then presses each control the tree added and prints the page's click log. Needs SEREIN_AX=1.
  static func probe(_ url: String) async throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SEREIN_DATA_DIR"] ?? NSTemporaryDirectory())
    let browser = try BrowserModel(root: root)
    defer { browser.shutdown() }
    let task = try browser.beginTask(isolated: true, allowActions: true, includeCurrent: false)
    func call(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
      try await browser.handle(["task": task.capability.task, "token": task.capability.token, "name": name, "arguments": args])
    }
    let opened = try await call("open_tab", ["url": url])
    let id = opened["tab"] as? String ?? ""
    for attempt in 1...4 {
      let started = Date()
      let page = try await call("read", ["tab": id])
      let rows = page["elements"] as? [[String: Any]] ?? []
      print("read \(attempt): \(rows.count) controls in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
      if attempt < 4 && !rows.contains(where: { ($0["ref"] as? String)?.hasPrefix("x") == true }) {
        try await Task.sleep(nanoseconds: 1_500_000_000)
        continue
      }
      for row in rows {
        print("  \(row["ref"] ?? "") \(row["role"] ?? "") \"\(row["label"] ?? "")\"" + (row["checked"].map { " checked=\($0)" } ?? "") + (row["disabled"] != nil ? " DISABLED" : ""))
      }
      let labels = rows.filter { ($0["ref"] as? String)?.hasPrefix("x") == true || $0["label"] as? String == "Silver" }
        .compactMap { $0["label"] as? String }
      for label in labels {
        let current = (try await call("read", ["tab": id]))["elements"] as? [[String: Any]] ?? []
        guard let ref = current.first(where: { $0["label"] as? String == label })?["ref"] as? String else { continue }
        let started = Date()
        do {
          let r = try await call("click", ["tab": id, "ref": ref])
          print("press \"\(label)\" (\(ref.prefix(1))): ok in \(Int(Date().timeIntervalSince(started) * 1000)) ms with page after, via \((r["result"] as? [String: Any])?["via"] ?? "pagekit")")
        } catch { print("press \"\(label)\": \(error.localizedDescription)") }
      }
      break
    }
    let tab = browser.tasks[task.capability.task]?.tabs.first
    // The page's own world, where its script keeps the log.
    print("page click log:", (try? await tab?.web.evaluateJavaScript("JSON.stringify(window.log||[])")) ?? "nil")
    // Is the slow first read once per app, per page or per tab?
    for (what, run) in [("same tab, new page", { _ = try await call("navigate", ["tab": id, "url": url + "?b"]) }),
                        ("new tab", { _ = try await call("open_tab", ["url": url + "?c"]) })] as [(String, () async throws -> Void)] {
      let started = Date()
      try await run()
      print("\(what): open with page after in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    }
  }
}
#endif
