#if DEBUG
import Foundation
import SereinCore

/// What setup's closing line says about the things found on this Mac (LocalFinds.swift).
extension AssistantCoreChecks {
  static func localFinds(_ check: Check) throws {
    try check(LocalFinds().sentence == nil, "Nothing found adds nothing to the closing line")
    try check(
      LocalFinds(browser: "Chrome").sentence
        == "On this Mac I also found Chrome, with sign-ins and bookmarks I can bring in. Ask me to bring any of it in.",
      "A browser alone is named with what it can bring")
    let all = LocalFinds(browser: "Arc", toolApps: ["Claude Desktop", "Cursor", "Codex"], modelApps: ["Ollama"], speechModel: true)
    try check(
      all.sentence == "On this Mac I also found Arc, with sign-ins and bookmarks I can bring in, connected tools in "
        + "Claude Desktop, Cursor and Codex, Ollama running a model here and the speech model for typing by voice. "
        + "Ask me to bring any of it in.",
      "Every find is named in one sentence, lists joined with commas and a last and")
    try check(LocalFinds.modelPorts.allSatisfy { $0.url.hasPrefix("http://127.0.0.1:") },
              "The model apps are only looked for on this Mac's own address")
  }
}
#endif
