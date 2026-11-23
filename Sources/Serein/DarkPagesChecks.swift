#if DEBUG
import Foundation
import WebKit

/// "Darken light webpages" picks a way per page. A page with no background of its own showed a
/// dark canvas under its dark text (Apple's sign-in page was unreadable); it is light unless it
/// says it has a dark scheme.
@MainActor func checkDarkPages() async {
  guard let url = Bundle.assets.url(forResource: "DarkPages", withExtension: "js"),
    let source = try? String(contentsOf: url, encoding: .utf8)
  else {
    FileHandle.standardError.write(Data("FAIL: dark pages check: DarkPages.js is missing\n".utf8))
    exit(1)
  }
  let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
  let invert = "invert", dark = ":root{color-scheme:dark}"
  let pages: [(String, String, String)] = [
    ("no background, no scheme", "<p>Text</p>", invert),
    (
      "no background, dark scheme",
      "<meta name=\"color-scheme\" content=\"light dark\"><p>Text</p>", dark
    ),
    ("white background", "<body style=\"background:#fff\"><p>Text</p>", invert),
    ("dark background", "<body style=\"background:#111\"><p>Text</p>", dark),
  ]
  for (name, html, expected) in pages {
    web.loadHTMLString("<!doctype html>" + html, baseURL: URL(string: "https://fixture.invalid/")!)
    for _ in 0..<100 where web.isLoading || web.url == nil {
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    let probe = "\nglobalThis.__sereinDarkPages(true);"
      + "document.getElementById('serein-dark-page').textContent"
    let style = try? await web.evaluateJavaScript(source + probe)
    let text = style as? String ?? ""
    if expected == invert ? !text.contains("filter:invert") : text != dark {
      FileHandle.standardError.write(Data("FAIL: dark pages check: \(name) gave \(text)\n".utf8))
      exit(1)
    }
  }
}
#endif
