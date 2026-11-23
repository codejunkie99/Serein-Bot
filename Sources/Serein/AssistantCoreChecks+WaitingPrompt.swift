#if DEBUG
import Foundation
import SereinCore

/// A session waiting in an outside app: reading what it asks.
extension AssistantCoreChecks {
  static func waitingPrompt(_ check: Check) throws {
    let claude = """
      ⏺ Bash(git push origin main)
      ╭──────────────────────────────────────────────╮
      │ Bash command                                 │
      │                                              │
      │   git push origin main                       │
      │   Push the branch                            │
      │                                              │
      │ Do you want to proceed?                      │
      │ ❯ 1. Yes                                     │
      │   2. Yes, and don't ask again for git push   │
      │   3. No, and tell Claude what to do differently (esc) │
      ╰──────────────────────────────────────────────╯
      """
    let read = WaitingPromptReader.terminal(claude)
    try check(read?.question == "Do you want to proceed?" && read?.choices.map(\.label).first == "Yes"
      && read?.choices.count == 3 && read?.selected == 0 && read?.detail?.contains("git push origin main") == true,
      "Claude Code's CLI question, its command and its three answers are read from the terminal")
    if let read, let no = read.choices.last {
      try check(read.moves(to: no) == ["Down", "Down"], "Choosing the third answer moves the marker down twice")
      let unmarked = WaitingPromptReader.terminal("Do you want to proceed?\n  1. Yes\n  2. No")
      try check(unmarked != nil && unmarked.flatMap { $0.moves(to: $0.choices[1]) } == nil,
        "With no visible marker, Serein won't guess where the arrows land")
    }
    let ask = """
       ☐ Filename
      │ Which filename should I use: today.txt or now.txt? I'll write today's date
      │ (2026-11-13) into the file you pick, in the working directory.
      ❯ 1. today.txt
           Writes the date 2026-11-13 into today.txt.
        2. now.txt
           Writes the date 2026-11-13 into now.txt.
        3. Type something.
      ────────────────────────────────────────────────────────────────────
        4. Chat about this
      Enter to select · ↑/↓ to navigate · Esc to cancel
      """
    let asked = WaitingPromptReader.terminal(ask)
    try check(asked?.question == "Which filename should I use: today.txt or now.txt?"
      && asked?.choices.map(\.label) == ["today.txt", "now.txt"] && asked?.choices.map(\.index) == [0, 1]
      && asked?.detail == "I'll write today's date (2026-11-13) into the file you pick, in the working directory.",
      "Claude Code's AskUserQuestion, as it really draws: descriptions under options, the sentence after the question")
    let rerun = """
      ⏺ Wrote now.txt
      ✻ Crunched for 2s · done 3:55 PM
      ❯ Ask me again with AskUserQuestion: today.txt or now.txt?
      ────────────────────────────────────────────────────────────────────
       ☐ File
      Which file should I write the date into: today.txt or now.txt?
      ❯ 1. today.txt
           Write 2026-11-13 into today.txt.
        2. now.txt
           Write 2026-11-13 into now.txt.
        3. Type something.
      ────────────────────────────────────────────────────────────────────
        4. Chat about this
      Enter to select · ↑/↓ to navigate · Esc to cancel
      """
    let again = WaitingPromptReader.terminal(rerun)
    try check(again?.question == "Which file should I write the date into: today.txt or now.txt?" && again?.detail == nil,
      "Earlier output above the prompt's rule is never shown as what it would do")
    let codex = """
      Would you like to run the following command?
        $ rm -rf build
      › 1. Yes, proceed (y)
        2. No, and tell Codex what to do differently (esc)
      Press enter to confirm or esc to cancel
      """
    let codexRead = WaitingPromptReader.terminal(codex)
    try check(codexRead?.choices.count == 2 && codexRead?.question.hasPrefix("Would you like") == true
      && codexRead?.detail?.contains("rm -rf build") == true, "Codex's question is read, with the key help left out")
    try check(WaitingPromptReader.terminal("Steps:\n1. Build it\n2. Ship it\n$ ") == nil,
      "Ordinary numbered output with no question is not a prompt")
    try check(WaitingPromptReader.terminal("Ready?\n1. One\n3. Three") == nil, "Numbers out of order are not a prompt")
    try check(WaitingPromptReader.terminal("Do you want to proceed?\n❯ 1. Yes\n  2. No\n$ ls\nfile.txt") == nil,
      "An old prompt above later output is not read as waiting")

    typealias C = WaitingPromptReader.Control
    let dialog = [
      C(role: "AXStaticText", label: "Claude wants to edit Package.swift", ref: "m1"),
      C(role: "AXStaticText", label: "Allow this edit?", ref: "m2"),
      C(role: "AXButton", label: "Allow once", ref: "m3"),
      C(role: "AXButton", label: "Always allow", ref: "m4"),
      C(role: "AXButton", label: "Deny", ref: "m5"),
    ]
    let window = WaitingPromptReader.window(dialog)
    try check(window?.question == "Allow this edit?" && window?.choices.map(\.ref) == ["m3", "m4", "m5"]
      && window?.detail == "Claude wants to edit Package.swift", "A window's question and its answer buttons are read, by ref")
    let toolbar = [
      C(role: "AXStaticText", label: "Ready?", ref: "m1"), C(role: "AXButton", label: "Run", ref: "m2"),
      C(role: "AXButton", label: "Continue", ref: "m3"),
    ]
    try check(WaitingPromptReader.window(toolbar) == nil, "Buttons that only say yes are not a question")
    let lookalikes = [
      C(role: "AXStaticText", label: "Anything new?", ref: "m1"), C(role: "AXButton", label: "Running", ref: "m2"),
      C(role: "AXButton", label: "Notify", ref: "m3"),
    ]
    try check(WaitingPromptReader.window(lookalikes) == nil, "“Running” and “Notify” are not Run and No")
    if let window {
      let moved = WaitingPrompt(kind: .window, question: window.question, detail: "Claude wants to edit Other.swift", choices: window.choices)
      try check(!window.sameAsked(moved), "A different file is a different question: nothing is pressed")
    }

    try claudeTranscriptQuestion(check)

    try check(ClaudeSessionRecords.waiting(["status": "waiting", "waitingFor": "input needed"]) == "input needed"
      && ClaudeSessionRecords.waiting(["status": "busy"]) == nil
      && ClaudeSessionRecords.waiting(["status": "waiting", "waitingFor": " "]) == nil
      && ClaudeSessionRecords.waiting(["status": "idle", "waitingFor": "input needed"]) == nil,
      "A Claude Code session waiting on the person is told by its live record, before its transcript shows the question")
    try check(HarnessProcessDiscovery.parentPID(getpid()) == getppid() && HarnessProcessDiscovery.parentPID(-1) == nil,
      "A process's parent is found, also where proc_pidinfo is refused (root-owned login under Terminal)")
  }

  /// Claude's desktop app: its question is read from the session's transcript, shown only.
  static func claudeTranscriptQuestion(_ check: Check) throws {
    func line(_ object: [String: Any]) -> String {
      String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }
    let ask: [String: Any] = ["type": "tool_use", "id": "t1", "name": "AskUserQuestion", "input": [
      "questions": [
        ["question": "Where should the access live?", "header": "Access via", "multiSelect": false,
         "options": [["label": "Serein chat only", "description": "Remove the pages"], ["label": "Both", "description": "Keep a CLI"]]],
        ["question": "Second?", "options": [["label": "A"], ["label": "B"]]],
      ]]]
    let asking = [
      line(["type": "user", "message": ["role": "user", "content": "Remove the pages"]]),
      line(["type": "assistant", "message": ["role": "assistant", "stop_reason": "tool_use", "content": [["type": "thinking", "thinking": "…"]]]]),
      line(["type": "assistant", "message": ["role": "assistant", "stop_reason": "tool_use", "content": [ask]]]),
      line(["type": "bridge-session", "sessionId": "s"]),
    ].joined(separator: "\n")
    let read = WaitingPromptReader.claudeTranscript(Data(asking.utf8))
    try check(read?.kind == .transcript && read?.question == "Where should the access live?"
      && read?.choices.map(\.label) == ["Serein chat only", "Both"]
      && read?.detail == "Question 1 of 2. Answer the rest in Claude.",
      "A pending AskUserQuestion in Claude Code's transcript is the card's question and answers")

    let answered = asking + "\n" + line(["type": "user", "message": ["role": "user", "content": [
      ["type": "tool_result", "tool_use_id": "t1", "content": "Both"]]]])
    try check(WaitingPromptReader.claudeTranscript(Data(answered.utf8)) == nil, "An answered question is not shown again")

    let plan = line(["type": "assistant", "message": ["role": "assistant", "stop_reason": "tool_use", "content": [
      ["type": "tool_use", "id": "t2", "name": "ExitPlanMode", "input": ["plan": "1. Edit the dock"]]]]])
    let planRead = WaitingPromptReader.claudeTranscript(Data(plan.utf8))
    try check(planRead?.question == "Claude has a plan ready. Approve it?" && planRead?.detail == "1. Edit the dock"
      && planRead?.choices.isEmpty == true, "A plan waiting for approval is shown with its plan")

    let other = line(["type": "assistant", "message": ["role": "assistant", "stop_reason": "tool_use", "content": [
      ["type": "tool_use", "id": "t3", "name": "Bash", "input": ["command": "ls"]]]]])
    try check(WaitingPromptReader.claudeTranscript(Data((asking + "\n" + other).utf8)) == nil
      && WaitingPromptReader.claudeTranscript(Data("not json\n{}".utf8)) == nil,
      "Only a question still pending at the end counts; other tools and junk lines read as none")
    try check(WaitingPrompt(kind: .transcript, question: "Q", detail: nil, choices: [.init(label: "A", index: 0)], selected: 0)
      .moves(to: .init(label: "A", index: 0)) == nil, "A transcript question is never answered by keys")
  }
}
#endif
