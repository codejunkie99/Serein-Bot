#if DEBUG
import Foundation
import SereinCore

/// Tool Call Cards (`ToolCalls`), reply versions after Try again (`ReplyVersions`) and words typed
/// while a turn runs (`RunSteering`).
extension AssistantCoreChecks {
  static func affectLaneOne(_ check: Check) throws {
    let start = Date(timeIntervalSince1970: 1_000)
    var calls: [String: ToolCall] = [:]
    ToolCalls.apply([
      "type": "assistant",
      "message": ["content": [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "ls -la"]]]],
    ], to: &calls, at: start)
    try check(
      calls["t1"]?.tool == "Bash" && calls["t1"]?.input.contains("ls -la") == true
        && calls["t1"]?.output == nil && calls["t1"].flatMap(ToolCalls.took) == nil,
      "A tool_use opens a call with its tool and what it was given, still waiting for its result")

    ToolCalls.apply([
      "type": "user",
      "message": ["content": [["type": "tool_result", "tool_use_id": "t1", "content": "No such file", "is_error": true]]],
    ], to: &calls, at: start.addingTimeInterval(12.4))
    try check(
      calls["t1"]?.output == "No such file" && calls["t1"]?.failed == true
        && calls["t1"].flatMap(ToolCalls.took) == "12s",
      "Its tool_result closes it with what came back, a failure, and how long it took")

    ToolCalls.apply([
      "type": "user",
      "message": ["content": [["type": "tool_result", "tool_use_id": "unknown", "content": "x"]]],
    ], to: &calls, at: start)
    try check(calls.count == 1, "A result for a call never opened adds nothing")

    ToolCalls.apply(["type": "item.started", "item": ["id": "c1", "type": "command_execution", "command": "swift --version"]],
                    to: &calls, at: start)
    ToolCalls.apply(["type": "item.completed", "item": ["id": "c1", "type": "command_execution", "command": "swift --version",
                                                        "aggregated_output": "Swift 6", "exit_code": 0, "status": "completed"]],
                    to: &calls, at: start.addingTimeInterval(0.4))
    try check(
      calls["c1"]?.tool == "command_execution" && calls["c1"]?.input == "swift --version"
        && calls["c1"]?.output == "Swift 6" && calls["c1"]?.failed == false
        && calls["c1"].flatMap(ToolCalls.took) == "0.4s",
      "A Codex item opens and closes a call the same way, and exit code 0 is no failure")

    ToolCalls.apply(["type": "item.started", "item": ["id": "c2", "type": "command_execution", "command": "false"]], to: &calls, at: start)
    ToolCalls.apply(["type": "item.completed", "item": ["id": "c2", "aggregated_output": "", "exit_code": 1]], to: &calls, at: start)
    try check(calls["c2"]?.failed == true, "A Codex command that exits non-zero failed")

    var many: [String: ToolCall] = [:]
    for index in 0...ToolCalls.keep {
      ToolCalls.apply([
        "type": "assistant",
        "message": ["content": [["type": "tool_use", "id": "m\(index)", "name": "Read", "input": [:] as [String: Any]]]],
      ], to: &many, at: start.addingTimeInterval(Double(index)))
    }
    try check(many.count == ToolCalls.keep && many["m0"] == nil && many["m\(ToolCalls.keep)"] != nil,
              "At most \(ToolCalls.keep) calls are kept, the oldest going first")

    ToolCalls.apply([
      "type": "assistant",
      "message": ["content": [["type": "tool_use", "id": "big", "name": "Write",
                               "input": ["content": String(repeating: "a", count: ToolCalls.inputLimit * 3)]]]],
    ], to: &calls, at: start)
    try check((calls["big"]?.input.count ?? .max) <= ToolCalls.inputLimit + 1,
              "What a call was given is clipped, so a long file write stays small")

    let long = (1...20).map { "line \($0)" }.joined(separator: "\n")
    let shut = ToolCalls.folded(long, open: false)
    try check(
      shut.hidden == 12 && shut.text.split(separator: "\n").count == ToolCalls.foldLines
        && ToolCalls.folded(long, open: true) == (long, 0) && ToolCalls.folded("one\ntwo", open: false) == ("one\ntwo", 0),
      "A long result folds to its first lines and says how many more there are; a short one never folds")
    let minute = ToolCall(id: "x", tool: "Bash", input: "", startedAt: start, endedAt: start.addingTimeInterval(65))
    try check(ToolCalls.took(minute) == "1m 05s", "A call over a minute says minutes and seconds")
    try check(ToolCalls.retryWords("Run the tests").contains("Run the tests"),
              "Retry on a failed call asks for that step again by its name")

    var book: [String: ReplyVersions] = [:]
    try check(ReplyVersions.of(chat: "a", asked: "Plan my week", in: book) == nil, "A reply nobody tried again has no versions")
    ReplyVersions.keep("First answer", asked: "Plan my week", chat: "a", in: &book)
    var versions = ReplyVersions.of(chat: "a", asked: "Plan my week", in: book)
    try check(
      versions?.count == 2 && versions?.position == "2 of 2" && versions?.text(current: "Second") == "Second",
      "Try again keeps the earlier reply and shows the new one, as 2 of 2")
    versions?.step(-1)
    try check(versions?.position == "1 of 2" && versions?.text(current: "Second") == "First answer",
              "Stepping back shows the earlier reply, as 1 of 2")
    versions?.step(-1)
    try check(versions?.index == 0, "Stepping back is held at the first version")
    versions?.step(5)
    try check(versions?.position == "2 of 2" && versions?.shown == nil, "Stepping on is held at the newest")
    ReplyVersions.keep("First answer", asked: "Plan my week", chat: "a", in: &book)
    try check(book["a"]?.earlier.count == 1, "The same reply kept twice in a row is one version")
    ReplyVersions.keep("Other", asked: "Book a table", chat: "a", in: &book)
    try check(
      ReplyVersions.of(chat: "a", asked: "Plan my week", in: book) == nil
        && ReplyVersions.of(chat: "a", asked: "Book a table", in: book)?.count == 2
        && ReplyVersions.of(chat: "b", asked: "Book a table", in: book) == nil,
      "A new question in a chat starts its versions over, and each chat keeps its own")
    for index in 0..<(ReplyVersions.limit + 3) {
      ReplyVersions.keep("v\(index)", asked: "Book a table", chat: "a", in: &book)
    }
    try check(book["a"]?.earlier.count == ReplyVersions.limit && book["a"]?.earlier.first == "v3",
              "At most \(ReplyVersions.limit) earlier versions are kept, the oldest going first")

    try check(
      RunSteering.offersResume(stopped: true, running: false, typed: false)
        && !RunSteering.offersResume(stopped: true, running: true, typed: false)
        && !RunSteering.offersResume(stopped: true, running: false, typed: true)
        && !RunSteering.offersResume(stopped: false, running: false, typed: false),
      "Resume shows after Stop while nothing runs and nothing is typed")
    try check(
      RunSteering.useNow(several: false) == "Stop and use now" && RunSteering.useNow(several: true) == "Stop and use all now"
        && RunSteering.nextStep == "Goes with the next step",
      "Waiting words say they go with the next step, and the other choice says it stops the turn")
  }
}
#endif
