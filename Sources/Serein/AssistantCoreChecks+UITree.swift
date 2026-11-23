#if DEBUG
import Foundation
import SereinCore

/// A view drawn under a reply (`ui_show`; `UITree`, SereinCore/UITree.swift): a tree decodes from
/// the JSON a model sends, each limit refuses one step past it in words that name the place, an
/// unknown block is refused, a pressed button sends only words the view drew and what the person
/// set, and the tool is one a relay turn can reach.
extension AssistantCoreChecks {
  static func uiTree(_ check: Check) throws {
    typealias Block = [String: Any]
    func problem(_ blocks: [Block], title: String? = nil) -> UITree.Problem? {
      var arguments: [String: Any] = ["blocks": blocks]
      if let title { arguments["title"] = title }
      if case .failure(let problem) = UITree.parse(arguments) { return problem }
      return nil
    }
    func text(_ words: String = "Hello") -> Block { ["type": "text", "text": words] }
    func long(_ count: Int) -> String { String(repeating: "a", count: count) }
    func texts(_ count: Int) -> [Block] { Array(repeating: text(), count: count) }
    /// A text under `levels` columns: it sits `levels + 1` deep.
    func nested(_ levels: Int) -> Block {
      (0..<levels).reduce(text()) { inner, _ in ["type": "column", "children": [inner]] }
    }

    // Decoding
    let parsed = UITree.parse([
      "title": "Trip",
      "blocks": [
        ["type": "row", "children": [["type": "stat", "label": "Spent", "value": "$1,310", "trend": "up", "change": "$180", "tone": "warning"]]],
        ["type": "list", "marker": "number", "items": [["title": "Flights", "value": "$640", "tone": "success"]]],
      ],
    ])
    guard case .success(let tree) = parsed else {
      try check(false, "A tree of blocks decodes from ui_show's arguments")
      return
    }
    let stat: UIBlock? = tree.blocks.first?.children?.first
    try check(
      tree.title == "Trip" && tree.count == 3 && tree.blocks.map(\.kind) == [.row, .list] && stat?.kind == .stat
        && stat?.value == "$1,310" && stat?.trendValue == .up && stat?.toneValue == .warning
        && tree.blocks.last?.markerValue == .number && tree.blocks.last?.items?.first?.toneValue == .success,
      "A tree of blocks decodes from ui_show's arguments, with its nesting, words and choices")
    try check(
      UITreeSamples.names.allSatisfy { UITreeSamples.tree($0) != nil }
        && Set(UITreeSamples.names.compactMap { UITreeSamples.tree($0)?.title }).count == UITreeSamples.names.count,
      "Each sample view is a tree the tool takes")
    let kinds: Set<UIBlock.Kind> = Set(UITreeSamples.names.compactMap { UITreeSamples.tree($0) }.flatMap { tree -> [UIBlock.Kind] in
      func all(_ block: UIBlock) -> [UIBlock.Kind] { [block.kind].compactMap { $0 } + (block.children ?? []).flatMap(all) }
      return tree.blocks.flatMap(all)
    })
    let undrawn: [String] = UIBlock.Kind.allCases.filter { !kinds.contains($0) }.map(\.rawValue)
    try check(undrawn.isEmpty, "The samples draw every kind of block [missing: \(undrawn.joined(separator: ", "))]")

    // An unknown kind
    let html = problem([["type": "html", "text": "<b>Pay</b>"]])
    try check(
      html?.kind == .unknownType && html?.words.contains("blocks[0]") == true && html?.words.contains("html") == true
        && html?.words.contains("progress") == true,
      "A block of an unknown type is refused, in words that name it, its place and the real types")
    try check(
      problem([["type": "column", "children": [text(), ["type": "webview"]]]])?.words.contains("blocks[0].children[1]") == true,
      "An unknown block inside another is named by its place in the tree")
    try check(problem([["text": "No type"]])?.kind == .malformed && problem([["text": "No type"]])?.words.contains("type") == true,
              "A block with no type is refused")
    if case .failure(let wrong) = UITree.parse(["blocks": "a card"]) {
      try check(wrong.kind == .malformed, "Blocks that are not a list are refused")
    } else {
      try check(false, "Blocks that are not a list are refused")
    }
    try check(problem([])?.kind == .empty, "A view with no blocks is refused")
    let saved = try JSONDecoder().decode(UITree.self, from: Data(#"{"blocks":[{"type":"hologram","text":"x"}]}"#.utf8))
    try check(!saved.isValid && saved.blocks.first?.kind == nil, "A saved chat with a block this build does not know still opens, and draws nothing")

    // Depth, count, children
    try check(problem([nested(UITree.maxDepth - 1)]) == nil, "Blocks nest \(UITree.maxDepth) levels deep")
    try check(problem([nested(UITree.maxDepth)])?.kind == .tooDeep, "One level deeper is refused")
    try check(problem(texts(UITree.maxBlocks)) == nil, "A view holds \(UITree.maxBlocks) blocks")
    let over = problem(texts(UITree.maxBlocks + 1))
    try check(over?.kind == .tooMany && over?.words.contains("\(UITree.maxBlocks)") == true, "One block more is refused, with the limit in the words")
    let columns: [Block] = Array(repeating: ["type": "column", "children": texts(10)], count: 6)
    try check(problem(columns)?.kind == .tooMany, "Blocks inside other blocks count toward the limit")
    try check(
      problem([["type": "column", "children": texts(UITree.maxChildren)]]) == nil
        && problem([["type": "column", "children": texts(UITree.maxChildren + 1)]])?.kind == .tooMany,
      "A column holds \(UITree.maxChildren) children and no more")
    try check(
      problem([["type": "row", "children": texts(UITree.maxRowChildren)]]) == nil
        && problem([["type": "row", "children": texts(UITree.maxRowChildren + 1)]])?.kind == .tooMany,
      "A row holds \(UITree.maxRowChildren) children and no more")
    try check(problem([["type": "card", "title": "Empty"]])?.kind == .missing, "A card with no children is refused")
    try check(
      problem([["type": "grid", "columns": UITree.maxGridColumns, "children": texts(2)]]) == nil
        && problem([["type": "grid", "columns": UITree.maxGridColumns + 1, "children": texts(2)]])?.kind == .badValue
        && problem([["type": "grid", "columns": 1, "children": texts(2)]])?.kind == .badValue,
      "A grid has 2 to \(UITree.maxGridColumns) columns")

    // String lengths: the limit passes, one more is refused
    let lengths: [(String, Int, (String) -> Block)] = [
      ("text", UITree.maxText, { ["type": "text", "text": $0] }),
      ("stat label", UITree.maxLabel, { ["type": "stat", "label": $0, "value": "1"] }),
      ("stat value", UITree.maxValue, { ["type": "stat", "label": "L", "value": $0] }),
      ("stat change", UITree.maxChange, { ["type": "stat", "label": "L", "value": "1", "change": $0] }),
      ("badge", UITree.maxBadge, { ["type": "badge", "text": $0] }),
      ("card title", UITree.maxTitle, { ["type": "card", "title": $0, "children": [["type": "divider"]]] }),
      ("progress label", UITree.maxLabel, { ["type": "progress", "label": $0, "percent": 50] }),
      ("progress detail", UITree.maxValue, { ["type": "progress", "label": "L", "percent": 50, "detail": $0] }),
      ("table header", UITree.maxLabel, { ["type": "table", "headers": [$0], "rows": [["1"]]] }),
      ("table cell", UITree.maxCell, { ["type": "table", "rows": [[$0]]] }),
      ("list item title", UITree.maxItemTitle, { ["type": "list", "items": [["title": $0]]] }),
      ("list item detail", UITree.maxDetail, { ["type": "list", "items": [["title": "T", "detail": $0]]] }),
      ("list item value", UITree.maxValue, { ["type": "list", "items": [["title": "T", "value": $0]]] }),
    ]
    for (name, limit, block) in lengths {
      let refused = problem([block(long(limit + 1))])
      try check(
        problem([block(long(limit))]) == nil && refused?.kind == .tooLong && refused?.words.contains("\(limit)") == true,
        "A \(name) takes \(limit) characters; one more is refused with the limit in the words")
    }
    try check(
      problem([text()], title: long(UITree.maxTitle)) == nil && problem([text()], title: long(UITree.maxTitle + 1))?.kind == .tooLong,
      "The view's title takes \(UITree.maxTitle) characters and no more")
    try check(
      problem([["type": "text", "text": "  "]])?.kind == .missing && problem([["type": "stat", "label": "L"]])?.kind == .missing
        && problem([["type": "badge"]])?.kind == .missing,
      "A text, stat or badge with no words is refused")

    // Plain text only
    try check(problem([text("Total\u{202E}99")])?.kind == .notPlain && problem([text("a\u{200B}b")])?.kind == .notPlain,
              "Words with a hidden or direction-changing character are refused")
    try check(
      problem([text("One\nTwo")]) == nil && problem([["type": "stat", "label": "One\nTwo", "value": "1"]])?.kind == .notPlain
        && problem([["type": "badge", "text": "One\nTwo"]])?.kind == .notPlain,
      "A text block keeps line breaks; a label or badge is one line")
    try check(problem([text("👩\u{200D}💻 at work")]) == nil, "The joiner inside 👩‍💻 is kept")

    // Choices
    try check(
      problem([["type": "badge", "text": "Hi", "tone": "pink"]])?.kind == .badValue
        && problem([["type": "text", "text": "Hi", "style": "huge"]])?.kind == .badValue
        && problem([["type": "stat", "label": "L", "value": "1", "trend": "sideways"]])?.kind == .badValue
        && problem([["type": "list", "items": [["title": "T"]], "marker": "star"]])?.kind == .badValue
        && problem([["type": "list", "items": [["title": "T", "tone": "pink"]]]])?.kind == .badValue,
      "A tone, style, trend or marker that is not on the list is refused")
    try check(problem([["type": "badge", "text": "Hi", "tone": "pink"]])?.words.contains("success") == true, "The refusal lists the real choices")

    // Table, list, progress, chart
    let row: [String] = ["a", "b"]
    try check(
      problem([["type": "table", "headers": ["A", "B"], "rows": Array(repeating: row, count: UITree.maxTableRows)]]) == nil
        && problem([["type": "table", "rows": Array(repeating: row, count: UITree.maxTableRows + 1)]])?.kind == .tooMany,
      "A table holds \(UITree.maxTableRows) rows and no more")
    try check(
      problem([["type": "table", "rows": [Array(repeating: "a", count: UITree.maxTableColumns + 1)]]])?.kind == .tooMany
        && problem([["type": "table", "headers": ["A", "B"], "rows": [["a"]]]])?.kind == .badValue
        && problem([["type": "table", "rows": [["a", "b"], ["c"]]]])?.kind == .badValue
        && problem([["type": "table", "headers": ["A"]]])?.kind == .missing,
      "A table has up to \(UITree.maxTableColumns) columns, a cell for each in every row, and at least one row")
    let item: Block = ["title": "T"]
    try check(
      problem([["type": "list", "items": Array(repeating: item, count: UITree.maxItems)]]) == nil
        && problem([["type": "list", "items": Array(repeating: item, count: UITree.maxItems + 1)]])?.kind == .tooMany
        && problem([["type": "list"]])?.kind == .missing,
      "A list holds 1 to \(UITree.maxItems) items")
    try check(
      problem([["type": "progress", "label": "L", "percent": 100]]) == nil
        && problem([["type": "progress", "label": "L", "percent": 101]])?.kind == .badValue
        && problem([["type": "progress", "label": "L", "percent": -1]])?.kind == .badValue
        && problem([["type": "progress", "label": "L"]])?.kind == .badValue,
      "A progress bar needs a percent from 0 to 100")
    func chart(_ values: [Double]) -> Block {
      ["type": "chart", "chart": ["kind": "bar", "labels": ["Mon", "Tue"], "series": [["values": values]]] as [String: Any]]
    }
    try check(
      problem(Array(repeating: chart([1, 2]), count: UITree.maxCharts)) == nil
        && problem(Array(repeating: chart([1, 2]), count: UITree.maxCharts + 1))?.kind == .tooMany,
      "A view holds \(UITree.maxCharts) charts and no more")
    try check(
      problem([chart([1])])?.kind == .badValue && problem([["type": "chart"]])?.kind == .badValue
        && problem([["type": "chart", "chart": ["kind": "radar", "labels": ["a"], "series": [["values": [1]]]] as [String: Any]]]) != nil,
      "A chart whose values do not match its labels, a chart block with no chart, and an unknown chart kind are refused")

    // Buttons and controls
    let form: [Block] = [
      ["type": "card", "title": "Stay", "children": [
        ["type": "choice", "label": "Room", "options": ["Classic", "Deluxe"], "selected": "Deluxe"],
        ["type": "stepper", "label": "Nights", "number": 4, "min": 1, "max": 5],
        ["type": "toggle", "label": "Breakfast"],
        ["type": "input", "label": "Note", "placeholder": "Anything else"],
      ] as [Block]],
      ["type": "row", "children": [["type": "button", "label": "Update the booking", "style": "primary"], ["type": "button", "label": "Leave it"]] as [Block]],
    ]
    guard case .success(let stay) = UITree.parse(["blocks": form]) else {
      try check(false, "A view with a choice, a stepper, a switch, an input and buttons is taken")
      return
    }
    try check(
      stay.controls.map(\.path) == ["0.0", "0.1", "0.2", "0.3"] && stay.controls.map { $0.block.kind } == [.choice, .stepper, .toggle, .input],
      "A view with a choice, a stepper, a switch, an input and buttons is taken, each control with its place")
    try check(
      stay.message(pressing: "Update the booking", values: [:]) == "Update the booking\nRoom: Deluxe\nNights: 4\nBreakfast: Off",
      "A press sends the button's own label, then each control where the assistant started it; an empty input is left out")
    let set: [String: UITree.Value] = ["0.0": .pick("Classic"), "0.1": .number(5), "0.2": .on(true), "0.3": .words("  Late\narrival\u{202E}  ")]
    try check(
      stay.message(pressing: "Leave it", values: set) == "Leave it\nRoom: Classic\nNights: 5\nBreakfast: On\nNote: Late arrival",
      "A press sends what the person set; what they typed goes as one plain line")
    var kept = UITreeKept()
    kept.set(.number(2), at: "0.1", in: "reply-1")
    kept.set(.on(true), at: "0.2", in: "reply-2")
    try check(
      kept.message(stay, in: "reply-1", pressing: "Leave it") == "Leave it\nRoom: Deluxe\nNights: 2\nBreakfast: Off"
        && kept.message(stay, in: "reply-2", pressing: "Leave it") == "Leave it\nRoom: Deluxe\nNights: 4\nBreakfast: On",
      "What the person set in one drawn view is sent from that view only")
    let reread = try JSONDecoder().decode(UITreeKept.self, from: JSONEncoder().encode(kept))
    try check(
      reread == kept && reread.value(at: "0.1", in: "reply-1") == .number(2) && reread.value(at: "0.2", in: "reply-2") == .on(true),
      "What the person set is the same after it is saved and read again")
    let folder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("serein-ui-tree-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("relay", isDirectory: true), withIntermediateDirectories: true)
    let library = try Library(root: folder)
    let nextLaunch: UITreeKept = MainActor.assumeIsolated {
      let first = UITreeValues()
      first.open(library)
      first.kept.set(.pick("Suite"), at: "0.0", in: "reply-1")
      first.kept.set(.words("Late arrival"), at: "0.3", in: "reply-1")
      let second = UITreeValues()
      second.open(library)
      return second.kept
    }
    try check(
      nextLaunch.value(at: "0.0", in: "reply-1") == .pick("Suite") && nextLaunch.value(at: "0.3", in: "reply-1") == .words("Late arrival")
        && FileManager.default.fileExists(atPath: folder.appendingPathComponent(UITreeValues.file).path),
      "What the person set in a view is in the library for the next launch")
    kept.clear("reply-1")
    try check(
      kept.value(at: "0.1", in: "reply-1") == nil && kept.value(at: "0.2", in: "reply-2") == .on(true),
      "A view drawn again starts its controls over; other views keep theirs")
    var many = UITreeKept()
    many.press("Go", in: "reply-0")
    for index in 0...UITreeKept.maxViews { many.set(.on(true), at: "0", in: "reply-\(index)") }
    many.set(.on(false), at: "0", in: "reply-1")
    many.set(.on(true), at: "0", in: "reply-new")
    try check(
      many.value(at: "0", in: "reply-0") == nil && many.value(at: "0", in: "reply-2") == nil && many.value(at: "0", in: "reply-1") == .on(false)
        && many.value(at: "0", in: "reply-new") == .on(true) && many.pressed(sending: "Go").isEmpty,
      "Past \(UITreeKept.maxViews) views, the ones the person touched longest ago are let go, with their presses")

    // A press redraws its view in place
    var shown = AgentMessage(role: "assistant", text: "Here it is.")
    shown.view = stay
    var pressing = UITreeKept()
    pressing.set(.number(5), at: "0.1", in: shown.id)
    let sent: String = pressing.message(stay, in: shown.id, pressing: "Leave it")
    pressing.press(sent + "\n", in: shown.id)
    // The reply is still empty: the turn is running.
    var chat: [AgentMessage] = [shown, AgentMessage(role: "you", text: sent), AgentMessage(role: "assistant", text: "")]
    try check(
      sent.contains("Nights: 5") && AgentMessage.redraw(tree, kept: &pressing, in: &chat) && chat[0].view == tree && chat[2].view == nil
        && pressing.value(at: "0.1", in: shown.id) == nil,
      "The view drawn in answer to a press takes the pressed view's place while the turn runs, and its controls start over")
    try check(
      AgentMessage.redraw(stay, kept: &pressing, in: &chat) && chat[0].view == stay,
      "A second view drawn in the same answer takes that place too")
    chat += [AgentMessage(role: "you", text: "What else can change?"), AgentMessage(role: "assistant", text: "")]
    try check(
      !AgentMessage.redraw(tree, kept: &pressing, in: &chat) && chat[0].view == stay,
      "A view drawn in answer to any other message goes under its reply")
    var waited = UITreeKept()
    waited.press(sent, in: shown.id)
    let nextDay: UITreeKept = try JSONDecoder().decode(UITreeKept.self, from: JSONEncoder().encode(waited))
    try check(nextDay.pressed(sending: sent) == [shown.id], "A press is kept for the next launch, like what the person set")
    waited = nextDay
    var elsewhere: [AgentMessage] = [AgentMessage(role: "you", text: sent), AgentMessage(role: "assistant", text: "")]
    try check(
      !AgentMessage.redraw(tree, kept: &waited, in: &elsewhere) && elsewhere.allSatisfy { $0.view == nil },
      "A press redraws nothing in a chat that does not hold its view")
    var later: [AgentMessage] = [
      shown, AgentMessage(role: "you", text: "One thing first"), AgentMessage(role: "assistant", text: "Noted."),
      AgentMessage(role: "you", text: sent), AgentMessage(role: "assistant", text: ""),
    ]
    try check(
      AgentMessage.redraw(tree, kept: &waited, in: &later) && later[0].view == tree,
      "A press that waited to be sent, through a relaunch and behind another message, still redraws its view when its words go")
    var twice = UITreeKept()
    var again = AgentMessage(role: "assistant", text: "Here it is again.")
    again.view = stay
    twice.press("Leave it", in: again.id)
    twice.press("Leave it", in: shown.id)
    // Setting a control in the other view does not make it the pressed one.
    twice.set(.on(true), at: "0.2", in: again.id)
    var both: [AgentMessage] = [shown, again, AgentMessage(role: "you", text: "Leave it"), AgentMessage(role: "assistant", text: "")]
    try check(
      AgentMessage.redraw(tree, kept: &twice, in: &both) && both[0].view == tree && both[1].view == stay,
      "Two views whose buttons sent the same words: the one pressed last is redrawn")
    var done = UITreeKept()
    done.press(sent, in: shown.id)
    done.answered(sent, among: [shown.id])
    var typed: [AgentMessage] = [shown, AgentMessage(role: "you", text: sent), AgentMessage(role: "assistant", text: "")]
    try check(
      done.pressed(sending: sent).isEmpty && done == UITreeKept() && !AgentMessage.redraw(tree, kept: &done, in: &typed)
        && typed[0].view == stay,
      "Once the turn that answered a press ends, the same words typed later redraw nothing")
    var apart = UITreeKept()
    apart.press(sent, in: shown.id)
    apart.answered(sent, among: ["reply-in-another-chat"])
    try check(apart.pressed(sending: sent) == [shown.id], "A turn in another chat that sent the same words leaves this chat's press waiting")
    let fewer: UITreeKept = try JSONDecoder().decode(UITreeKept.self, from: Data(#"{"values":{"reply-1":{"0.1":{"number":{"_0":3}}}}}"#.utf8))
    try check(fewer.value(at: "0.1", in: "reply-1") == .number(3), "A saved file with fewer fields still reads")
    let broken: URL = folder.appendingPathComponent(UITreeValues.file)
    let leftAlone: Bool = try MainActor.assumeIsolated {
      try Data("not json".utf8).write(to: broken)
      let values = UITreeValues()
      values.open(library)
      values.kept.set(.on(true), at: "0", in: "reply-1")
      // A read writes what waits to be saved (`SaveCoalescer`); nothing may wait for this file.
      _ = library.load(UITreeKept.self, from: UITreeValues.file)
      return try Data(contentsOf: broken) == Data("not json".utf8) && values.kept.value(at: "0", in: "reply-1") == .on(true)
    }
    try check(leftAlone, "A saved file that does not read is left as it is, and the launch keeps its values in memory")
    let pausedQueue: UITree? = UITreeSamples.after("queue")?.tree
    try check(
      pausedQueue != nil && pausedQueue != UITreeSamples.tree("queue") && pausedQueue?.plain.contains("[Button] Resume Codex") == true,
      "The queue sample has the view its answer draws after Pause Codex")
    try check(
      UITree.words(.words(long(UITree.maxTyped + 50))).count == UITree.maxTyped && UITree.words(.number(2.5)) == "2.50" && UITree.words(.number(-3)) == "-3",
      "Typed words are cut to \(UITree.maxTyped) characters; a whole number is sent without a decimal point")
    let nights: UIBlock = stay.controls[1].block
    try check(
      UITree.stepped(nights, from: 4, direction: 1) == 5 && UITree.stepped(nights, from: 5, direction: 1) == 5
        && UITree.stepped(nights, from: 1, direction: -1) == 1 && UITree.initial(nights) == .number(4),
      "A stepper moves one step and stops at its ends")
    let rate: Block = ["type": "stepper", "label": "Rate", "number": 0.1, "min": 0, "max": 1, "step": 0.1]
    var tenths: UIBlock? = nil
    if case .success(let rates) = UITree.parse(["blocks": [rate, ["type": "button", "label": "Go"]] as [Block]]) { tenths = rates.controls.first?.block }
    try check(tenths.map { UITree.stepped($0, from: 0.2, direction: 1) } == 0.3, "A stepper of tenths does not drift")
    func button(_ label: String = "Go") -> Block { ["type": "button", "label": label] }
    try check(
      problem([button(), button("go ")])?.kind == .badValue && problem([button(), ["type": "toggle", "label": "Go"]])?.kind == .badValue,
      "Two buttons, or a button and a control, with one label are refused")
    try check(
      problem([button(long(UITree.maxLabel))]) == nil && problem([button(long(UITree.maxLabel + 1))])?.kind == .tooLong
        && problem([["type": "button"]])?.kind == .missing && problem([["type": "button", "label": "Go", "style": "huge"]])?.kind == .badValue,
      "A button needs a label of \(UITree.maxLabel) characters or fewer and a style from the list")
    try check(
      problem((1...UITree.maxButtons).map { button("Go \($0)") }) == nil
        && problem((1...UITree.maxButtons + 1).map { button("Go \($0)") })?.kind == .tooMany,
      "A view holds \(UITree.maxButtons) buttons and no more")
    func toggles(_ count: Int) -> [Block] { (1...count).map { ["type": "toggle", "label": "Switch \($0)"] } + [button()] }
    try check(
      problem(toggles(UITree.maxControls)) == nil && problem(toggles(UITree.maxControls + 1))?.kind == .tooMany,
      "A view holds \(UITree.maxControls) controls and no more")
    try check(problem([["type": "toggle", "label": "Breakfast"]])?.kind == .missing, "Controls with no button to send them are refused")
    func stepper(_ more: Block) -> [Block] { [more.merging(["type": "stepper", "label": "Nights"]) { old, _ in old }, button()] }
    try check(
      problem(stepper([:])) == nil && problem(stepper(["min": 5, "max": 1]))?.kind == .badValue && problem(stepper(["step": 0]))?.kind == .badValue
        && problem(stepper(["number": 101]))?.kind == .badValue && problem(stepper(["min": 0, "max": 1, "step": 2]))?.kind == .badValue
        && problem(stepper(["max": 2_000_000]))?.kind == .badValue,
      "A stepper needs min below max, a step that fits between them, and a number inside them")
    try check(
      problem(stepper(["min": 0, "max": 1, "step": 0.01])) == nil && problem(stepper(["min": 0, "max": 1, "step": 0.0001]))?.kind == .badValue,
      "A stepper's step is at least \(UITree.minStep), so a press always moves it")
    try check(
      problem([["type": "text", "text": "Hi", "children": [["type": "toggle", "label": "Hidden"]]], button()])?.kind == .badValue,
      "A block that is not a column, row, grid or card cannot hold children")
    func choice(_ options: [String], selected: String? = nil) -> [Block] {
      var block: Block = ["type": "choice", "label": "Room", "options": options]
      if let selected { block["selected"] = selected }
      return [block, button()]
    }
    try check(
      problem(choice(["A", "B", "C", "D"])) == nil && problem(choice(["A"]))?.kind == .missing && problem(choice(["A", "B", "C", "D", "E"]))?.kind == .tooMany
        && problem(choice(["A", "A"]))?.kind == .badValue && problem(choice(["A", "B"], selected: "C"))?.kind == .badValue
        && problem(choice(["A", long(UITree.maxOption + 1)]))?.kind == .tooLong,
      "A choice has 2 to \(UITree.maxOptions) short options, each its own, and starts on one of them")
    func asks(_ label: String, beside words: String = "Details") -> UITree.Problem? {
      problem([text(words), ["type": "input", "label": label], button()])
    }
    try check(
      asks("Note") == nil && asks("Your password")?.kind == .badValue && asks("Card number")?.kind == .badValue
        && asks("Verification code")?.kind == .badValue && asks("Type it here", beside: "Enter your Apple ID password to continue")?.kind == .badValue,
      "A view with an input that asks for a password, a code or card details is refused, wherever the words sit")
    try check(problem([text("Your password was changed"), button("OK")]) == nil, "The same words in a view with no input are fine")
    try check(
      asks("API key")?.kind == .badValue && asks("Access token")?.kind == .badValue && asks("Secret key")?.kind == .badValue,
      "A view with an input that asks for a key or a token is refused")
    let field: Block = ["type": "input", "label": "Value"]
    let chart: Block = ["type": "chart", "chart": ["kind": "bar", "labels": ["Enter your card number"], "series": [["values": [1]]]]]
    let pick: Block = ["type": "choice", "label": "Field", "options": ["Password", "Note"]]
    try check(
      problem([pick, button()]) == nil && problem([chart, button()]) == nil
        && problem([pick, field, button()])?.kind == .badValue && problem([chart, field, button()])?.kind == .badValue,
      "Words in a choice's options or a chart that ask for a secret refuse an input too")

    // What a fresh session reads
    var drew = AgentMessage(role: "assistant", text: "Here it is.")
    drew.view = tree
    try check(drew.contextText == "Here it is.\n\n[Drew a view]\nTrip\nSpent: $1,310 ($180)\n- Flights, $640", "A fresh session reads a drawn view's words")
    let back = try JSONDecoder().decode(AgentMessage.self, from: JSONEncoder().encode(drew))
    let older = try JSONDecoder().decode(AgentMessage.self, from: JSONEncoder().encode(AgentMessage(role: "assistant", text: "Hi")))
    try check(back.view == tree && older.view == nil, "A reply keeps its view when saved; a reply without one saves none")

    // The tool
    let schema: [String: Any]? = RelayTools.assistantTools.first { $0["name"] as? String == "ui_show" }
    let input: [String: Any]? = schema?["inputSchema"] as? [String: Any]
    let blocks: [String: Any]? = (input?["properties"] as? [String: Any])?["blocks"] as? [String: Any]
    let types: [String]? = (((blocks?["items"] as? [String: Any])?["properties"] as? [String: Any])?["type"] as? [String: Any])?["enum"] as? [String]
    try check(
      input?["required"] as? [String] == ["blocks"] && types == UIBlock.Kind.allCases.map(\.rawValue),
      "ui_show asks for blocks, and its list of types is the blocks the app draws")
    try check(
      UIBlock.Kind.allCases.allSatisfy { UITree.toolDescription.contains($0.rawValue) } && UITree.toolDescription.contains("plain text")
        && UITree.toolDescription.contains("sends its label as the person's next message")
        && UITree.toolDescription.contains("takes the place of the view they pressed")
        && UITree.toolDescription.contains("Never ask for a password"),
      "Its description names every block, says the view is plain text, what a press sends, how to redraw the pressed view, and that an input never asks for a secret")
    try check(
      RelayTools.names.contains("ui_show") && ToolGroups.hidden.contains("ui_show")
        && ToolGroups.groups.first { $0.tools.contains("ui_show") }?.id == "views",
      "A relay turn reaches ui_show through tools_more's views group")
    try check(RelayTools.assistantNames.contains("dashboard_make") && ToolGroups.hidden.contains("dashboard_make"), "dashboard_make is still offered")
    try check(AgentStep.label(tool: "ui_show", arguments: [:]) == "Drew a view", "Its step reads Drew a view")
  }
}
#endif
