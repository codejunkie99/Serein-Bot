#if DEBUG
import Foundation
import SereinCore

/// How a chat's steps read in its transcript, as real Claude Code 2.1 and Codex 0.166 logs wrote
/// them (a helper, a connected app's tool, a quoted shell command, a file in the chat's folder).
/// Synthetic values in those shapes.
extension AssistantCoreChecks {
  static func stepLabels(_ check: Check) throws {
    let folder = "/Users/maya/code/lumen-shop"
    func label(_ name: String, _ input: [String: Any]) -> String {
      TranscriptActivity.call(name: name, input: input, id: "x", folder: folder).label
    }
    try check(label("Agent", ["description": "Check the README for typos", "prompt": "secret plan"]) == "Started a helper: Check the README for typos",
      "Claude Code's Agent tool reads as a helper with what it was asked, never its prompt")
    try check(label("Task", [:]) == "Started a helper", "The older Task tool reads the same way")
    try check(label("mcp__claude_ai_Notion__notion-search", ["query": "roadmap"]) == "Used notion-search in Notion",
      "A connected app's tool names the app, not its raw id")
    try check(label("Edit", ["file_path": folder + "/app/page.tsx"]) == "Edited app/page.tsx", "A file in the chat's folder shows by its place in it")
    try check(label("Edit", ["file_path": "/etc/hosts"]) == "Edited /etc/hosts", "A file elsewhere keeps its full path")

    let codex = TranscriptActivity.codex(
      ["type": "commandExecution", "id": "c1", "command": #"/bin/zsh -lc 'rg --files -g '"'"'!\.git'"'"' -g '"'"'*.py'"'"''"#, "exitCode": 0],
      folder: folder)
    try check(codex?.label == #"Ran `rg --files -g '!\.git' -g '*.py'`"#, "A quoted Codex command reads as it was typed")
    try check(RunNow.command(#"bash -lc 'it'\''s fine'"#).done == "Ran `it's fine`", "A backslash-escaped quote is undone too")
    // As Codex 0.166's app server wrote one: double quotes with single-quoted pieces spliced in.
    let spliced = TranscriptActivity.codex(
      ["type": "commandExecution", "id": "c3", "command": #"/bin/zsh -lc "rg --files -g '"'!'"\\.git' -g 'AGENTS.md'""#], folder: folder)
    try check(spliced?.label == #"Ran `rg --files -g '!\.git' -g 'AGENTS.md'`"#, "Codex's spliced quoting reads as the shell would run it")
    try check(RunNow.command(#"zsh -lc "echo \"hi\"""#).done == #"Ran `echo "hi"`"#, "A double-quoted command is undone")
    let change = TranscriptActivity.codex(["type": "fileChange", "id": "c2", "changes": [["path": folder + "/prices.py"]]], folder: folder)
    try check(change?.label == "Edited prices.py", "A Codex file change in the chat's folder shows by its place in it")
    let changes = TranscriptActivity.codex(
      ["type": "fileChange", "id": "c4", "changes": [["path": folder + "/prices.py"], ["path": folder + "/test_cheapest.py"]]], folder: folder)
    try check(changes?.label == "Edited prices.py and 1 more", "Several changed files read as the first and how many more")
    try check(RunNow.toolName("mcp__linear__create_issue") == "create_issue in linear", "A plain server name stays as it is")
    try check(RunNow.toolName("Bash") == "Bash", "A tool that is not a connected app's keeps its name")
    let own = RelayTools.names.union(RelayTools.teamNames).union(RelayTools.roomNames).union(PeerTools.names).sorted()
    let raw = own.filter { AgentStep.label(tool: $0, arguments: [:]) == "Used a tool" }
    try check(raw.isEmpty, "Each of Serein's own tools reads in words in its steps [no words for: \(raw.joined(separator: ", "))]")
    let finding = RunNow.claudeTool("mcp__serein_browser__files_find", input: ["query": "posts"], folder: nil)
    try check(finding?.now == "Looking for files “posts”" && finding?.done == "Looked for files “posts”",
      "A file search reads the same in the Now line and the steps, never as files_find")
    try check(AgentStep.label(tool: "some_new_tool", arguments: [:]) == "Used a tool" && RunNow.present("Used a tool") == "Using a tool",
      "A tool with no words yet never shows its raw name")
    let follow = SubagentFollowUp.message("  also check the footer  ", to: "Check README\nfor typos", id: "claude:a4fc0e1")
    try check(follow.contains("agent id a4fc0e1") && follow.contains("“Check README for typos”") && follow.hasSuffix("also check the footer"),
      "A message to a Claude Code helper names it and its id for its parent, and keeps the person's words whole")

    // A finished session's report (SessionReport), from the AI app's own final words.
    typealias R = SessionReport
    let answer = """
      ## Summary

      Added `cheapest(items)`, returning the cheapest item or `None` for an empty list. Tests pass.

      ```python
      def cheapest(items): ...
      ```
      - [prices.py](/Users/x/lab/prices.py)
      """
    try check(R.gist(answer) == "Added cheapest(items), returning the cheapest item or None for an empty list. Tests pass.",
      "The gist is the first paragraph that says something, without headings, code or backticks")
    try check(R.gist("- Fixed [the header](http://x/y).\n- Added tests.\n\nMore later.") == "Fixed the header. Added tests.",
      "A list answer reads as its items, with link words and not their targets")
    let steps = [
      TranscriptActivity(id: "1", tool: "edit", label: "Edited prices.py"), TranscriptActivity(id: "2", tool: "edit", label: "Edited prices.py"),
      TranscriptActivity(id: "3", tool: "edit", label: "Edited test_cheapest.py"), TranscriptActivity(id: "4", tool: "test", label: "Ran tests"),
    ]
    try check(R.changes(steps) == "Edited 2 files · ran tests", "What changed counts each file once and says tests ran")
    try check(R.changes([TranscriptActivity(id: "5", tool: "test", label: "Ran tests", failed: true)]) == "Tests failed", "A failed test run says so")
    try check(R.changes([TranscriptActivity(id: "6", tool: "edit", label: "Edited prices.py and 1 more")]) == "Edited 2 files",
      "A Codex change of several files counts each of them")
    try check(R.text(app: "Codex", folder: "stxs", answer: "Fixed the header.", activities: []) == "Fixed the header.\nCodex in stxs",
      "A report reads as the app finishing with its own words")
    try check(R.text(app: "Codex", folder: nil, answer: "", activities: []) == nil, "No words and no changes: nothing is sent")
    try check(R.text(app: "Codex", folder: "stxs", answer: "", activities: steps) == "Edited 2 files · ran tests\nCodex in stxs",
      "No words: what changed is the report, never a bare \"has an update\"")
    try check(R.gist(String(repeating: "word ", count: 80)).count <= R.gistLimit, "A long answer is cut short")
    try check(R.text(app: "Codex", folder: "stxs", answer: "All tests pass.", activities: [], goal: "complete")
      == "All tests pass.\nCodex in stxs finished its goal", "A goal that ended says so")
    try check(R.text(app: "Codex", folder: "stxs", answer: "Need a key.", activities: [], goal: "blocked")
      == "Need a key.\nCodex in stxs is blocked on its goal", "A blocked goal says so")

    try check(R.gist("The project folder is:\n\n[**serein agent**](</Volumes/Work/serein agent>)")
      == "The project folder is: /Volumes/Work/serein agent", "A folder answer keeps the actual path across a paragraph break")
    try check(R.gist("Yes. I found:\n\n- Three unused worktrees.\n- Two stale registrations.")
      == "Three unused worktrees. Two stale registrations.", "An introductory acknowledgement gives way to its findings")
    let limited = R.text(app: "Codex", folder: "serein agent", answer:
      "Installed Serein build 1497 and updated PR #9.\n\nVerified: Local checks passed.\n\nRemaining risk: GitHub CI couldn’t start.",
      activities: [TranscriptActivity(id: "b", tool: "build", label: "Built")]) ?? ""
    try check(limited.hasPrefix("Installed Serein build 1497") && limited.contains("GitHub CI couldn’t start")
      && !limited.contains("\nBuilt") && ChatBubbles.split(limited).count == 1,
      "A completion leads with the outcome, preserves a later caveat and omits redundant activity labels")
    try check(R.isRoutineReply("Opened the Serein project folder in Finder.", activities: [])
      && R.isRoutineReply("Thanks.", activities: []), "Courtesies and simple successful Finder confirmations stay quiet")
    try check(!R.isRoutineReply("Couldn’t open the folder in Finder.", activities: [])
      && !R.isRoutineReply("Fixed the header.", activities: [])
      && !R.isRoutineReply("Done.", activities: steps)
      && !R.isRoutineReply("Done.", activities: [], goal: "complete"),
      "Failures, short outcomes, file changes and completed goals remain eligible")
    try check(!R.isRoutineReply("```swift\nlet x = 1\n```", activities: []),
      "An unsupported report is not silently classified as a courtesy")
    try check(!R.isRoutineReply("Done.", activities: []) && R.text(app: "Codex", folder: nil, answer: "Done.", activities: [])?
      .contains("no result details were provided") == true, "A bare completion is delivered with its missing detail made explicit")
    try check(R.text(app: "Codex", folder: "stxs", answer: "Done.", activities: [], goal: "complete")
      .map { $0.contains("Codex in stxs finished its goal") } == true, "An explicit completed goal remains news even with a bare acknowledgement")
    try check(R.text(app: "Codex", folder: nil, answer: "Updated the app.\n\n## Limitations\n\nOnly checked on this Mac.", activities: [])?
      .contains("Only checked on this Mac.") == true, "A limitation under its own heading is retained")
    try check(R.display("Finished this turn.\n\nCodex in stxs: Fixed the header.") == "Fixed the header.\nCodex in stxs",
      "Old saved completion notices display without the redundant announcement")
    try check(R.display("Finished this turn.\n\nCodex in stxs: Yes. I found:").isEmpty
      && R.display("Finished this turn.\n\nCodex in serein agent: Opened the project folder in Finder.").isEmpty,
      "Legacy empty labels and simple Finder confirmations add no empty bubbles")

    // Goals and loops: more turns are coming, so a turn's end is not news (synthetic logs only).
    typealias X = ExternalSessionReader
    func claudeLine(_ at: String, _ tool: String, _ input: String) -> String {
      #"{"type":"assistant","timestamp":"\#(at)","message":{"content":[{"type":"tool_use","name":"\#(tool)","input":\#(input)}]}}"#
    }
    let stamp = ISO8601DateFormatter()
    stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let woke = stamp.date(from: "2026-11-07T10:00:00.000Z")!
    let wake = claudeLine("2026-11-07T10:00:00.000Z", "ScheduleWakeup", #"{"delaySeconds":1500,"prompt":"/loop"}"#)
    try check(X.claudeLoop(Data((wake + "\n").utf8)) == woke.addingTimeInterval(1500 + X.loopGrace),
      "A scheduled wake keeps a Claude Code loop going until a little after its time")
    let stop = claudeLine("2026-11-07T10:30:00.000Z", "ScheduleWakeup", #"{"stop":true}"#)
    try check(X.claudeLoop(Data((wake + "\n" + stop + "\n").utf8)) == nil, "A loop that stopped itself is over")
    let cron = claudeLine("2026-11-07T10:00:00.000Z", "CronCreate", #"{"cron":"*/3 * * * *","prompt":"x"}"#)
    let uncron = claudeLine("2026-11-07T11:00:00.000Z", "CronDelete", #"{"id":"a"}"#)
    try check(X.claudeLoop(Data((cron + "\n").utf8)) == .distantFuture && X.claudeLoop(Data((cron + "\n" + uncron + "\n").utf8)) == nil,
      "A recurring job keeps the loop going until it is deleted")
    let helperHead = #"{"type":"session_meta","payload":{"id":"b","source":{"subagent":{"thread_spawn":{"parent_thread_id":"a1","depth":1}}}}}"#
    try check(X.codexParent(Data((helperHead + "\n").utf8)) == "a1" && X.codexParent(Data(#"{"type":"session_meta","payload":{"id":"a1"}}"#.utf8)) == nil,
      "A Codex helper names the thread that spawned it")
    var going = ExternalSession(id: "codex:a1", driver: .codex, title: "", cwd: nil, state: .open, updatedAt: woke)
    going.goal = "active"
    var looping = ExternalSession(id: "claude:l", driver: .claude, title: "", cwd: nil, state: .open, updatedAt: woke)
    looping.loopUntil = woke.addingTimeInterval(600)
    try check(going.continuing(at: woke) && looping.continuing(at: woke) && !looping.continuing(at: woke.addingTimeInterval(601)),
      "An active goal or a loop before its wake is still going")
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("serein-goals-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    let made = Process()
    made.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    made.arguments = [home.appendingPathComponent(".codex/goals_1.sqlite").path,
      "CREATE TABLE thread_goals (thread_id TEXT PRIMARY KEY, status TEXT); INSERT INTO thread_goals VALUES ('a1','active'),('b2','complete');"]
    try made.run()
    made.waitUntilExit()
    try check(X.codexGoals(["a1", "b2", "c3"], home: home.path) == ["a1": "active", "b2": "complete"],
      "Codex goals are read from its goals database by thread")
    let rollout = [
      #"{"type":"session_meta","payload":{"id":"t1","cwd":"/synthetic/shop"}}"#,
      #"{"type":"turn_context","payload":{"cwd":"/synthetic/shop","model":"gpt-x","effort":"high"}}"#,
      #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
      #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix the header"}]}}"#,
      #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","call_id":"c1","input":"*** Begin Patch\n*** Update File: /synthetic/shop/Header.swift\n*** End Patch"}}"#,
      #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"c2","input":"text(await tools.exec_command({cmd:\"swift test\"}))"}}"#,
      #"{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"Fixed the header."}]}}"#,
      #"{"type":"event_msg","payload":{"type":"task_complete"}}"#,
      #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
      #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<codex_internal_context source=\"goal\">Continue</codex_internal_context>"}]}}"#,
      #"{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"Still checking."}]}}"#,
    ].joined(separator: "\n")
    let read = LinkedHistory.codexRollout(Data(rollout.utf8))
    try check(read.messages.map(\.role) == ["you", "assistant", "assistant"] && read.messages[0].text == "Fix the header"
      && read.messages[1].text == "Fixed the header." && read.messages[1].activities.count == 2
      && read.messages[2].text == "Still checking." && read.working && read.cwd == "/synthetic/shop" && read.model == "gpt-x",
      "A Codex chat reads from its own file: asks, answers and steps, without Codex's own goal messages")
    try check(SessionIndex.userTitle("[PR #318](https://github.com/acme/shop/pull/318) is ready?") == "PR #318 is ready?"
      && SessionIndex.userTitle("look at https://www.example.com/a/b?c=1 please") == "look at example.com please",
      "A title shows a link's words, never its address")
    try check(SessionIndex.userTitle("<task-notification> <task-id>b1</task-id> done") == nil,
      "A background task's notice is never a chat's title")
    try check(TaskWorktree.name(for: "8F1C-22aa-91") == "task-8f1c22aa", "A worktree's name is short letters and digits")
    let repo = FileManager.default.temporaryDirectory.appendingPathComponent("serein-worktree-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: repo) }
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    for arguments in [["init", "-q"], ["-c", "user.name=c", "-c", "user.email=c@example.invalid", "commit", "-q", "--allow-empty", "-m", "start"]] {
      let git = Process()
      git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      git.arguments = ["-C", repo.path] + arguments
      try git.run()
      git.waitUntilExit()
    }
    let tree = try TaskWorktree.make(in: repo.path, name: "task-check")
    let exclude = (try? String(contentsOf: repo.appendingPathComponent(".git/info/exclude"), encoding: .utf8)) ?? ""
    try check(tree.hasPrefix(repo.path + "/.serein/worktrees/") && FileManager.default.fileExists(atPath: tree + "/.git")
      && exclude.contains("/.serein/") && (try TaskWorktree.make(in: repo.path, name: "task-check")) == tree,
      "A task's worktree is made inside the project, kept out of git status, and reused")
    try check((try? TaskWorktree.make(in: repo.path, name: "../escape")) == nil, "A worktree name cannot leave its folder")
  }
}
#endif
