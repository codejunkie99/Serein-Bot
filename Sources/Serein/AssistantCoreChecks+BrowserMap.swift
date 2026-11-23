#if DEBUG
import Foundation
import SereinCore

/// The pure rules behind faster page steps: read-only calls side by side (ToolTurns and the MCP
/// readOnlyHint), find (PageFind) and one map of a page and its frames (FrameMap). Synthetic rows
/// only; no page, tab or provider.
extension AssistantCoreChecks {
  static func browserMap(_ check: Check) throws {
    try browserMapTurns(check)
    try browserMapAnnotations(check)
    try browserMapFind(check)
    try browserMapFrames(check)
  }

  // MARK: turns

  private static func browserMapTurns(_ check: Check) throws {
    var turns = ToolTurns()
    try check(turns.request(id: 1, write: false, tab: "a"), "A read starts at once")
    try check(turns.request(id: 2, write: false, tab: "b"), "A read of another tab starts beside it")
    try check(turns.request(id: 3, write: false, tab: nil), "A tab list starts beside reads")
    try check(!turns.request(id: 4, write: false, tab: "a"), "A second read of the same tab waits: a read replaces its references")
    try check(turns.request(id: 5, write: false, tab: "c"), "A read of a free tab passes a read that waits for its own tab")
    try check(!turns.request(id: 6, write: true, tab: "a"), "An action waits for the calls before it")
    try check(!turns.request(id: 7, write: false, tab: "d"), "A read that came after an action waits for it")
    try check(turns.finish(id: 1) == [4], "When the first read of a tab ends, the next read of that tab starts")
    try check(turns.finish(id: 2).isEmpty && turns.finish(id: 3).isEmpty && turns.finish(id: 5).isEmpty,
      "The action does not start while a read runs")
    try check(turns.finish(id: 4) == [6] && turns.runningCount == 1, "The action starts alone when every earlier call ended")
    try check(turns.finish(id: 6) == [7], "The read after the action starts when the action ends")
    try check(turns.finish(id: 7).isEmpty && turns.isIdle, "The line is empty at the end")

    var held = ToolTurns()
    try check(held.request(id: 1, write: true, tab: "a"), "An action on an idle task starts at once")
    try check(!held.request(id: 2, write: false, tab: "a") && !held.request(id: 3, write: false, tab: "b"),
      "Reads wait while an action runs, on any tab")
    try check(held.cancel(id: 2).isEmpty, "A call that gave up leaves the line and starts nothing while the action runs")
    try check(held.finish(id: 1) == [3], "The calls still waiting start when the action ends")
    try check(held.finish(id: 3).isEmpty && held.isIdle, "A call that gave up never starts")

    // The helper and the app take a call's turn from the same rule.
    let read = ToolTurns.turn(name: "read", arguments: ["tab": "a", "start": 0])
    try check(!read.write && read.tab == "a", "A read is read-only, on the tab its arguments name")
    let click = ToolTurns.turn(name: "click", arguments: ["tab": "b", "ref": "e1"])
    try check(click.write && click.tab == "b", "A click is an action on its tab")
    let plugin = ToolTurns.turn(name: "notes__save", arguments: nil)
    try check(plugin.write && plugin.tab == nil, "A plugin tool or a call without arguments is an action")

    // A read sent after an action stays behind it, in the order the client sent them.
    var line = ToolTurns()
    try check(line.request(id: 1, write: true, tab: "a"), "go starts")
    try check(!line.request(id: 2, write: false, tab: "a"), "A read sent after go waits for it")
    try check(line.finish(id: 1) == [2], "The read starts when go ends, so it sees the new page")
  }

  // MARK: annotations

  private static func browserMapAnnotations(_ check: Check) throws {
    func readOnly(_ tools: [[String: Any]]) -> Set<String> {
      Set(tools.filter { ($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true }
        .compactMap { $0["name"] as? String })
    }
    let full = ToolSchema.tools(isolated: false)
    try check(readOnly(full) == ["tabs", "read", "find", "wait", "screenshot"],
      "Only tabs, read, find, wait and screenshot are marked read-only")
    try check(readOnly(ToolSchema.tools(isolated: true)) == ["list_tabs", "read", "find", "wait", "screenshot"],
      "The isolated names carry the same marks, find included")
    let find = full.first { $0["name"] as? String == "find" }
    let properties = ((find?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?.keys.sorted()
    try check(properties == ["role", "tab", "text"], "find takes a tab, a role and words")
  }

  // MARK: find

  private static let browserMapRows: [[String: Any]] = [
    ["ref": "e1_0_1", "role": "a", "label": "Pricing", "acts": ["click"]],
    ["ref": "e1_0_2", "role": "button", "label": "Sign in", "acts": ["click"]],
    ["ref": "e1_0_3", "role": "input", "label": "Search", "acts": ["type"], "value": "Café"],
    ["ref": "e1_0_4", "role": "select", "label": "Country", "acts": ["select"],
     "options": [["value": "fr", "label": "France"]]],
    ["ref": "e1_0_5", "role": "input", "label": "Remember me", "acts": ["click"], "checked": false],
    ["ref": "e1_0_6", "role": "clickable", "label": "Sign in with Google", "acts": ["click"]],
    ["ref": "e1_0_7", "role": "input", "label": "Submit", "acts": ["click"]],
  ]

  private static func browserMapFind(_ check: Check) throws {
    func refs(_ role: String?, _ text: String?) -> [String] {
      PageFind.matches(browserMapRows, role: role, text: text).compactMap { $0["ref"] as? String }
    }
    try check(refs("button", nil) == ["e1_0_2", "e1_0_6", "e1_0_7"], "Buttons include clickable rows and submit inputs, not a checkbox")
    try check(refs("link", nil) == ["e1_0_1"], "A link is an a row")
    try check(refs("textbox", nil) == ["e1_0_3"], "A text box is a row that types")
    try check(refs("Checkbox", nil) == ["e1_0_5"], "A checkbox is a toggle input, in any case")
    try check(refs("dropdown", "france") == ["e1_0_4"], "A list matches by its options' words")
    try check(refs(nil, "sign in") == ["e1_0_2", "e1_0_6"], "The exact label comes first, and \"in\" does not match Pricing")
    try check(refs(nil, "CAFE") == ["e1_0_3"], "Words match a value without case or accents")
    try check(refs("button", "google") == ["e1_0_6"], "Role and words together narrow the match")
    try check(refs(nil, "sub") == ["e1_0_7"], "A word matches the start of a label word")

    let page: [String: Any] = [
      "tab": "t1", "url": "https://shop.example/", "text": "Synthetic page words", "elements": browserMapRows,
      "next_start": 3, "start": 0, "choices": ["x"], "page_tools": ["y"], "sensitive": false, "user_steps": [String](),
    ]
    let found = PageFind.result(page: page, role: "link", text: nil)
    try check(found["text"] == nil && found["elements"] == nil && found["next_start"] == nil && found["page_tools"] == nil,
      "find leaves out the page's words and the full element list")
    try check(found["tab"] as? String == "t1" && found["sensitive"] as? Bool == false && found["user_steps"] != nil,
      "find keeps the tab and the page's notes")
    try check((found["matches"] as? [[String: Any]])?.count == 1 && found["count"] as? Int == 1 && found["find_note"] == nil,
      "find returns the matches and their count")
    let none = PageFind.result(page: page, role: "file", text: nil)
    try check(none["count"] as? Int == 0 && none["find_note"] != nil, "No match says to read the page")
    let many = (1...40).map { ["ref": "e1_0_\($0)", "role": "button", "label": "Item \($0)", "acts": ["click"]] as [String: Any] }
    let capped = PageFind.result(page: ["elements": many], role: "button", text: nil)
    try check((capped["matches"] as? [[String: Any]])?.count == PageFind.limit && capped["count"] as? Int == 40
      && (capped["find_note"] as? String)?.hasPrefix("10 more") == true, "find returns at most 30 and says how many more matched")
  }

  // MARK: frames

  private static func browserMapFrames(_ check: Check) throws {
    let page: [String: Any] = [
      "text": "Main words", "sensitive": false, "user_steps": [String](), "viewport": [1200, 800], "shown_frames": 3,
      "elements": [["ref": "e1_0_1", "role": "button", "label": "Go"]],
      "redaction": ["inspected": 5, "withheld": 1],
    ]
    let booking = FrameMap.Child(id: "f2", site: "booking.example", page: [
      "viewport": [600, 400], "sensitive": false, "user_steps": [String](), "redaction": ["inspected": 3, "withheld": 0],
      "elements": [
        ["ref": "ef2_0_1", "role": "button", "label": "Book", "x": 10, "y": 20],
        ["role": "file", "label": "Upload", "upload": "uf2_0_2"],
      ],
    ])
    let card = FrameMap.Child(id: "f3", site: "pay.example", page: [
      "viewport": [400, 200], "sensitive": true, "user_steps": ["card"], "redaction": ["inspected": 2, "withheld": 2],
      "elements": [["ref": "ef3_0_1", "role": "button", "label": "Pay"]],
    ])
    let tracker = FrameMap.Child(id: "f4", site: "ads.example", page: [
      "viewport": [1, 1], "elements": [["ref": "ef4_0_1", "role": "a", "label": "Ad"]],
    ])
    let captcha = FrameMap.Child(id: "f5", site: "check.example", page: [
      "viewport": [300, 80], "challenge": ["kind": "page", "blocks": true],
      "elements": [["ref": "ef5_0_1", "role": "input", "label": "I am human", "acts": ["click"]]],
    ])
    let merged = FrameMap.merge(page, children: [booking, card, tracker, captcha])
    let rows = merged["elements"] as? [[String: Any]] ?? []
    try check(rows.compactMap { $0["ref"] as? String } == ["e1_0_1", "ef2_0_1"],
      "A visible frame's controls follow the page's; card, tracker and check frames add none, nor a file row")
    try check(rows.last?["frame"] as? String == "f2" && rows.last?["site"] as? String == "booking.example"
      && rows.last?["x"] == nil && rows.last?["y"] == nil, "A frame's row names its frame and site, without the frame's coordinates")
    let steps = merged["frame_steps"] as? [[String: Any]] ?? []
    try check(steps.count == 1 && steps[0]["frame"] as? String == "f3" && steps[0]["steps"] as? [String] == ["card"]
      && merged["frame_steps_note"] != nil, "A frame with the user's fields is named with its steps")
    try check(merged["sensitive"] as? Bool == false && (merged["user_steps"] as? [String])?.isEmpty == true,
      "The page's own sensitive flag and steps stay the main document's")
    let counts = merged["redaction"] as? [String: Any]
    try check(counts?["inspected"] as? Int == 10 && counts?["withheld"] as? Int == 3,
      "Redaction counts add up over the page and its frames")
    try check(merged["text"] as? String == "Main words" && merged["viewport"] == nil && merged["shown_frames"] == nil,
      "The page's words stay; the window size and frame count are dropped")
    try check(FrameMap.shownFrames(page) == 3 && FrameMap.shownFrames(["text": "x"]) == 0,
      "A page that shows no frames reads none")

    let crowd = (0..<12).map { n in
      FrameMap.Child(id: "c\(n)", site: "widget\(n).example", page: [
        "viewport": [300, 300],
        "elements": (0..<10).map { ["ref": "ec\(n)_0_\($0)", "role": "button", "label": "Option \($0)"] as [String: Any] },
      ])
    }
    let crowded = (FrameMap.merge(["elements": [[String: Any]]()], children: crowd)["elements"] as? [[String: Any]]) ?? []
    try check(crowded.count == FrameMap.frameLimit * 10 && Set(crowded.compactMap { $0["frame"] as? String }).count == FrameMap.frameLimit,
      "At most 8 frames add rows")
    let big = FrameMap.Child(id: "big", site: "big.example", page: [
      "viewport": [800, 800],
      "elements": (0..<400).map { ["ref": "ebig_0_\($0)", "role": "button", "label": "Row \($0)"] as [String: Any] },
    ])
    let capped = (FrameMap.merge(["elements": [[String: Any]]()], children: [big])["elements"] as? [[String: Any]]) ?? []
    try check(capped.count == FrameMap.rowLimit, "Frames add at most 150 rows")
    try check(FrameMap.merge(["text": "x"], children: [booking])["elements"] == nil,
      "A read without elements gets none from its frames")
  }
}
#endif
