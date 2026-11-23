import Foundation

/// One building block of a view an assistant draws under its reply (`ui_show`). The model picks
/// the shape; the app draws each block with its own fixed view (Serein/UITreeCard.swift) and
/// every string as plain text. A button sends its own label as the person's next message, with
/// what they set in the view's controls under it (`UITree.message`). `type` and the other choices stay strings, so a saved chat that
/// holds a block this build does not know still opens: `UITree.problem` refuses it and the card
/// draws nothing.
public struct UIBlock: Codable, Equatable, Sendable {
  public enum Kind: String, CaseIterable, Sendable {
    case column, row, grid, card, text, stat, badge, table, progress, list, divider, chart
    case button, toggle, stepper, choice, input
    var holdsChildren: Bool { self == .column || self == .row || self == .grid || self == .card }
    /// A control: it holds a value the person sets, sent when a button is pressed.
    public var holdsValue: Bool { self == .toggle || self == .stepper || self == .choice || self == .input }
  }
  public enum ButtonStyle: String, CaseIterable, Sendable { case primary, secondary }
  public enum Tone: String, CaseIterable, Sendable { case neutral, accent, success, warning, danger }
  public enum TextStyle: String, CaseIterable, Sendable { case title, body, meta }
  public enum Marker: String, CaseIterable, Sendable { case none, bullet, number }
  public struct Item: Codable, Equatable, Sendable {
    public var title: String
    public var detail: String?
    public var value: String?
    public var tone: String?
    public var toneValue: Tone? { tone.flatMap(Tone.init(rawValue:)) }
  }

  public var type: String
  /// column, row, grid, card.
  public var children: [UIBlock]?
  /// grid: 2 to `UITree.maxGridColumns`.
  public var columns: Int?
  /// card: its heading.
  public var title: String?
  /// text, badge.
  public var text: String?
  /// text: title, body or meta. button: primary or secondary.
  public var style: String?
  /// stat, progress, and every button and control.
  public var label: String?
  public var value: String?
  public var trend: String?
  public var change: String?
  /// stat (its value), badge.
  public var tone: String?
  public var dot: Bool?
  /// progress: 0 to 100.
  public var percent: Double?
  public var detail: String?
  public var headers: [String]?
  public var rows: [[String]]?
  public var items: [Item]?
  public var marker: String?
  public var chart: ReplyChart?
  /// toggle: where it starts.
  public var on: Bool?
  /// stepper: where it starts, its ends and its step (0, 0 to 100 and 1 when absent).
  public var number: Double?
  public var min: Double?
  public var max: Double?
  public var step: Double?
  /// choice: 2 to `UITree.maxOptions`, and the one that starts picked (the first when absent).
  public var options: [String]?
  public var selected: String?
  /// input: the hint in the empty field.
  public var placeholder: String?

  public var kind: Kind? { Kind(rawValue: type) }
  public var toneValue: Tone { tone.flatMap(Tone.init(rawValue:)) ?? .neutral }
  public var styleValue: TextStyle { style.flatMap(TextStyle.init(rawValue:)) ?? .body }
  public var markerValue: Marker { marker.flatMap(Marker.init(rawValue:)) ?? .none }
  public var trendValue: DashboardSpec.Direction? { trend.flatMap(DashboardSpec.Direction.init(rawValue:)) }
  public var gridColumns: Int { columns ?? 2 }
  public var buttonStyle: ButtonStyle { style.flatMap(ButtonStyle.init(rawValue:)) ?? .secondary }
  public var low: Double { min ?? 0 }
  public var high: Double { max ?? 100 }
  public var stride: Double { step ?? 1 }
}

/// What `ui_show` draws: an optional heading and the blocks under it. A tree with any `problem`
/// draws nothing, and the tool answers with the problem's words so the model can fix that block.
public struct UITree: Codable, Equatable, Sendable {
  public var title: String?
  public var blocks: [UIBlock]

  public static let maxDepth = 5
  public static let maxBlocks = 60
  public static let maxChildren = 12
  public static let maxRowChildren = 4
  public static let maxGridColumns = 4
  public static let maxCharts = 2
  public static let maxTitle = 60
  public static let maxText = 600
  public static let maxLabel = 40
  public static let maxValue = 24
  public static let maxChange = 12
  public static let maxBadge = 24
  public static let maxTableColumns = 6
  public static let maxTableRows = 12
  public static let maxCell = 60
  public static let maxItems = 12
  public static let maxItemTitle = 80
  public static let maxDetail = 120
  public static let maxButtons = 8
  public static let maxControls = 8
  public static let maxOptions = 4
  public static let maxOption = 16
  /// What the person may type into one input.
  public static let maxTyped = 200
  static let maxNumber: Double = 1_000_000
  /// A stepper's smallest step: a value shows two decimals, and `stepped` rounds to thousandths.
  public static let minStep: Double = 0.01

  /// What a control holds: a toggle, a stepper, a choice, an input.
  public enum Value: Codable, Equatable, Sendable { case on(Bool), number(Double), pick(String), words(String) }

  public struct Problem: Error, Equatable, Sendable {
    public enum Kind: Sendable { case malformed, empty, unknownType, tooDeep, tooMany, tooLong, missing, notPlain, badValue }
    public let kind: Kind
    /// A plain sentence for the model: where, what, and the limit.
    public let words: String
    init(_ kind: Kind, _ words: String) {
      self.kind = kind
      self.words = words
    }
  }

  /// Every block in the tree, containers included.
  public var count: Int {
    func size(_ block: UIBlock) -> Int { 1 + (block.children ?? []).reduce(0) { $0 + size($1) } }
    return blocks.reduce(0) { $0 + size($1) }
  }
  public var isValid: Bool { problem == nil }

  /// The view as plain lines, for a fresh session that cannot see the card (`contextText`).
  public var plain: String {
    func words(_ parts: [String?], _ separator: String) -> String {
      parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: separator)
    }
    func lines(_ block: UIBlock) -> [String] {
      switch block.kind {
      case .column, .row, .grid, .card:
        return [block.kind == .card ? block.title : nil].compactMap { $0 } + (block.children ?? []).flatMap(lines)
      case .text, .badge: return [block.text ?? ""]
      case .stat: return [words([block.label, words([block.value, block.change.map { "(\($0))" }], " ")], ": ")]
      case .progress: return [words([block.label, block.detail ?? "\(Int((block.percent ?? 0).rounded()))%"], ": ")]
      case .table: return ([block.headers].compactMap { $0 } + (block.rows ?? [])).map { $0.joined(separator: " | ") }
      case .list: return (block.items ?? []).map { "- " + words([$0.title, $0.detail, $0.value], ", ") }
      case .chart: return ["[Chart" + (block.chart?.title.map { ": \($0)" } ?? "") + "]"]
      case .button: return ["[Button] " + (block.label ?? "")]
      case .toggle, .stepper, .choice: return [words([block.label, Self.initial(block).map { Self.words($0) }], ": ")]
      case .input: return ["[Input] " + words([block.label, block.placeholder], ", ")]
      case .divider, nil: return []
      }
    }
    return ([title].compactMap { $0 } + blocks.flatMap(lines)).filter { !$0.isEmpty }.joined(separator: "\n")
  }

  /// Every string the view draws, for the secret-input test: `plain` leaves out options and chart words.
  var drawn: String {
    func strings(_ block: UIBlock) -> [String] {
      let items: [String] = (block.items ?? []).flatMap { [$0.title, $0.detail, $0.value].compactMap { $0 } }
      let chart: [String] = block.chart.map { [$0.title, $0.unit].compactMap { $0 } + $0.labels + $0.series.compactMap(\.name) } ?? []
      let own: [String] = [block.title, block.text, block.label, block.value, block.change, block.detail, block.placeholder, block.selected]
        .compactMap { $0 }
      // Typed parts, joined in one call: a chain of `+` here is too much for the type checker.
      let table: [String] = (block.headers ?? []) + (block.rows ?? []).flatMap { $0 }
      let children: [String] = (block.children ?? []).flatMap(strings)
      let parts: [[String]] = [own, table, items, block.options ?? [], chart, children]
      return parts.flatMap { $0 }
    }
    return ([title].compactMap { $0 } + blocks.flatMap(strings)).joined(separator: "\n")
  }
  /// Words that ask for a key or token, which `ComputerHold.personOnly` does not cover.
  static let keyWords: String = SensitiveFields.controls + "|access.?(key|token)|auth.?token|bearer|client.?secret|\\btokens?\\b"

  /// Where a child sits in the tree: the key its value is kept under.
  public static func path(_ parent: String, _ index: Int) -> String { parent.isEmpty ? "\(index)" : "\(parent).\(index)" }

  /// Every control, in the order drawn, with its place.
  public var controls: [(path: String, block: UIBlock)] {
    func walk(_ blocks: [UIBlock], _ parent: String) -> [(path: String, block: UIBlock)] {
      blocks.enumerated().flatMap { index, block -> [(path: String, block: UIBlock)] in
        let here: String = Self.path(parent, index)
        return block.kind?.holdsValue == true ? [(here, block)] : walk(block.children ?? [], here)
      }
    }
    return walk(blocks, "")
  }

  /// Where a control starts, from the model's block.
  public static func initial(_ block: UIBlock) -> Value? {
    switch block.kind {
    case .toggle: return .on(block.on ?? false)
    case .stepper: return .number(block.number ?? block.low)
    case .choice: return .pick(block.selected ?? block.options?.first ?? "")
    case .input: return .words("")
    default: return nil
    }
  }
  /// A stepper one step up (`direction` 1) or down (-1), kept inside its ends.
  public static func stepped(_ block: UIBlock, from number: Double, direction: Double) -> Double {
    let next: Double = ((number + direction * block.stride) * 1000).rounded() / 1000
    return Swift.min(block.high, Swift.max(block.low, next))
  }
  /// A value as the words sent and shown: what the person typed is cut to one plain line.
  public static func words(_ value: Value) -> String {
    switch value {
    case .on(let on): return on ? "On" : "Off"
    case .number(let number):
      return number == number.rounded() && abs(number) <= maxNumber ? String(Int(number)) : String(format: "%.2f", number)
    case .pick(let option): return option
    case .words(let typed):
      let plain: String = String(String.UnicodeScalarView(typed.unicodeScalars.map { scalar -> Unicode.Scalar in
        CharacterSet.newlines.contains(scalar) ? " " : scalar
      }.filter { !SafeFileName.hidden($0) || PostDraft.joinsEmoji($0) }))
      return String(plain.trimmingCharacters(in: .whitespaces).prefix(maxTyped))
    }
  }

  /// What pressing a button sends as the person's message: the button's own label, then a line
  /// for each control with what it holds (`values` by place, else where it started). Only words
  /// drawn in the view and what the person set go out. An empty input is left out.
  public func message(pressing label: String, values: [String: Value]) -> String {
    let lines: [String] = controls.compactMap { path, block -> String? in
      guard let value = values[path] ?? Self.initial(block) else { return nil }
      let words: String = Self.words(value)
      return words.isEmpty ? nil : "\(block.label ?? ""): \(words)"
    }
    return ([label] + lines).joined(separator: "\n")
  }

  /// The first reason this tree cannot be drawn, or nil.
  public var problem: Problem? {
    var check = Check()
    if let found = check.string(title, "title", at: "ui_show", limit: Self.maxTitle) { return found }
    guard !blocks.isEmpty else { return Problem(.empty, "blocks is empty. Give at least one block.") }
    for (index, block) in blocks.enumerated() {
      if let found = check.block(block, at: "blocks[\(index)]", depth: 1) { return found }
    }
    if check.controls > 0, check.buttons == 0 {
      return Problem(.missing, "The view has controls but no button. Add a button: pressing it is what sends their values.")
    }
    // The same test that keeps Serein from typing into a secret field (`ComputerHold`).
    if check.inputs > 0,
      ComputerHold.personOnly(kind: "type", role: nil, label: drawn) != nil
        || drawn.range(of: Self.keyWords, options: [.regularExpression, .caseInsensitive]) != nil
    {
      return Problem(.badValue, "An input cannot ask for a password, a sign-in code, a key or card details. Remove the input, or the words that ask for them.")
    }
    return nil
  }

  /// The tree from `ui_show`'s arguments, or the problem to send back.
  public static func parse(_ arguments: [String: Any]) -> Result<UITree, Problem> {
    guard JSONSerialization.isValidJSONObject(arguments), let data = try? JSONSerialization.data(withJSONObject: arguments) else {
      return .failure(Problem(.malformed, "The blocks could not be read. Send title and blocks as plain JSON."))
    }
    do {
      let tree = try JSONDecoder().decode(UITree.self, from: data)
      if let problem = tree.problem { return .failure(problem) }
      return .success(tree)
    } catch let error as DecodingError {
      return .failure(Problem(.malformed, words(error)))
    } catch {
      return .failure(Problem(.malformed, "The blocks could not be read."))
    }
  }

  static func words(_ error: DecodingError) -> String {
    func path(_ keys: [CodingKey]) -> String {
      var out = ""
      for key in keys {
        if let index = key.intValue { out += "[\(index)]" } else { out += (out.isEmpty ? "" : ".") + key.stringValue }
      }
      return out.isEmpty ? "ui_show" : out
    }
    switch error {
    case .keyNotFound(let key, let context): return "\(path(context.codingPath + [key])) is missing."
    case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
      return "\(path(context.codingPath)) has the wrong kind of value."
    @unknown default: return "The blocks could not be read."
    }
  }

  /// One walk over the tree, counting blocks and charts as it goes.
  private struct Check {
    var blocks = 0
    var charts = 0
    var buttons = 0
    var controls = 0
    var inputs = 0
    var labels: Set<String> = []

    func string(_ value: String?, _ name: String, at path: String, limit: Int, required: Bool = false, lines: Bool = false) -> Problem? {
      let words: String = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if words.isEmpty {
        return required ? Problem(.missing, "\(path) needs \(name).") : nil
      }
      if words.count > limit {
        return Problem(.tooLong, "\(path): \(name) is \(words.count) characters. Use \(limit) or fewer.")
      }
      let plain: Bool = !words.unicodeScalars.contains { scalar in
        if CharacterSet.newlines.contains(scalar) { return !lines }
        return SafeFileName.hidden(scalar) && !PostDraft.joinsEmoji(scalar)
      }
      return plain ? nil : Problem(.notPlain, "\(path): \(name) must be \(lines ? "plain text" : "one line of plain text"), with no hidden characters.")
    }
    func choice<C: RawRepresentable & CaseIterable>(_ value: String?, _ name: String, _ type: C.Type, at path: String) -> Problem?
    where C.RawValue == String {
      guard let value, C(rawValue: value) == nil else { return nil }
      return Problem(.badValue, "\(path): \(name) is one of \(C.allCases.map(\.rawValue).joined(separator: ", ")).")
    }

    /// A button's or control's label: there, short, and its own, so a sent line names one thing.
    mutating func label(_ block: UIBlock, at here: String) -> Problem? {
      if let found = string(block.label, "label", at: here, limit: UITree.maxLabel, required: true) { return found }
      let key: String = (block.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if !labels.insert(key).inserted {
        return Problem(.badValue, "\(here): another button or control already has this label. Give each its own.")
      }
      return nil
    }
    mutating func control(_ block: UIBlock, at here: String) -> Problem? {
      controls += 1
      if controls > UITree.maxControls {
        return Problem(.tooMany, "There are more than \(UITree.maxControls) controls. Ask for less at once.")
      }
      return label(block, at: here)
    }

    mutating func block(_ block: UIBlock, at path: String, depth: Int) -> Problem? {
      guard let kind = block.kind else {
        let known: String = UIBlock.Kind.allCases.map(\.rawValue).joined(separator: ", ")
        return Problem(.unknownType, "\(path): there is no block type “\(String(block.type.prefix(24)))”. Use one of \(known).")
      }
      let here: String = "\(path) (\(kind.rawValue))"
      if depth > UITree.maxDepth {
        return Problem(.tooDeep, "\(here) is \(depth) levels deep. Nest blocks \(UITree.maxDepth) levels or fewer.")
      }
      blocks += 1
      if blocks > UITree.maxBlocks {
        return Problem(.tooMany, "There are more than \(UITree.maxBlocks) blocks. Show less, or split it into two views.")
      }
      if kind.holdsChildren {
        let children: [UIBlock] = block.children ?? []
        let limit: Int = kind == .row ? UITree.maxRowChildren : UITree.maxChildren
        if children.isEmpty { return Problem(.missing, "\(here) needs children.") }
        if children.count > limit { return Problem(.tooMany, "\(here) has \(children.count) children. Use \(limit) or fewer.") }
        if kind == .card, let found = string(block.title, "title", at: here, limit: UITree.maxTitle) { return found }
        if kind == .grid, !(2...UITree.maxGridColumns).contains(block.gridColumns) {
          return Problem(.badValue, "\(here): columns is 2 to \(UITree.maxGridColumns).")
        }
        for (index, child) in children.enumerated() {
          if let found = self.block(child, at: "\(path).children[\(index)]", depth: depth + 1) { return found }
        }
        return nil
      }
      if block.children?.isEmpty == false {
        return Problem(.badValue, "\(here): only column, row, grid and card hold children. Move them into one of those.")
      }
      switch kind {
      case .column, .row, .grid, .card, .divider:
        return nil
      case .text:
        return string(block.text, "text", at: here, limit: UITree.maxText, required: true, lines: true)
          ?? choice(block.style, "style", UIBlock.TextStyle.self, at: here)
      case .stat:
        return string(block.label, "label", at: here, limit: UITree.maxLabel, required: true)
          ?? string(block.value, "value", at: here, limit: UITree.maxValue, required: true)
          ?? string(block.change, "change", at: here, limit: UITree.maxChange)
          ?? choice(block.trend, "trend", DashboardSpec.Direction.self, at: here)
          ?? choice(block.tone, "tone", UIBlock.Tone.self, at: here)
      case .badge:
        return string(block.text, "text", at: here, limit: UITree.maxBadge, required: true)
          ?? choice(block.tone, "tone", UIBlock.Tone.self, at: here)
      case .progress:
        guard let percent = block.percent, percent.isFinite, (0...100).contains(percent) else {
          return Problem(.badValue, "\(here): percent is a number from 0 to 100.")
        }
        return string(block.label, "label", at: here, limit: UITree.maxLabel, required: true)
          ?? string(block.detail, "detail", at: here, limit: UITree.maxValue)
      case .table:
        return table(block, at: here)
      case .list:
        let items: [UIBlock.Item] = block.items ?? []
        if items.isEmpty { return Problem(.missing, "\(here) needs items.") }
        if items.count > UITree.maxItems { return Problem(.tooMany, "\(here) has \(items.count) items. Use \(UITree.maxItems) or fewer.") }
        for (index, item) in items.enumerated() {
          let at: String = "\(path).items[\(index)]"
          let found: Problem? = string(item.title, "title", at: at, limit: UITree.maxItemTitle, required: true)
            ?? string(item.detail, "detail", at: at, limit: UITree.maxDetail)
            ?? string(item.value, "value", at: at, limit: UITree.maxValue)
            ?? choice(item.tone, "tone", UIBlock.Tone.self, at: at)
          if let found { return found }
        }
        return choice(block.marker, "marker", UIBlock.Marker.self, at: here)
      case .chart:
        charts += 1
        if charts > UITree.maxCharts { return Problem(.tooMany, "There are more than \(UITree.maxCharts) charts. Keep the ones that matter.") }
        guard let chart = block.chart, chart.isValid else {
          return Problem(.badValue, "\(here): chart needs kind (bar, line or pie), labels, and series whose values match the labels one for one.")
        }
        return nil
      case .button:
        buttons += 1
        if buttons > UITree.maxButtons { return Problem(.tooMany, "There are more than \(UITree.maxButtons) buttons. Keep the ones that matter.") }
        if let found = label(block, at: here) { return found }
        return choice(block.style, "style", UIBlock.ButtonStyle.self, at: here)
      case .toggle:
        return control(block, at: here)
      case .stepper:
        if let found = control(block, at: here) { return found }
        let number: Double = block.number ?? block.low
        let sound: Bool = [block.low, block.high, block.stride, number].allSatisfy { $0.isFinite && abs($0) <= UITree.maxNumber }
        guard sound, block.low < block.high, block.stride >= UITree.minStep, block.stride <= block.high - block.low, (block.low...block.high).contains(number) else {
          return Problem(.badValue, "\(here): a stepper needs min below max, a step of at least \(UITree.minStep) that fits between them, and number from min to max.")
        }
        return nil
      case .choice:
        if let found = control(block, at: here) { return found }
        let options: [String] = block.options ?? []
        if !(2...UITree.maxOptions).contains(options.count) {
          return Problem(options.count < 2 ? .missing : .tooMany, "\(here) has \(options.count) options. Use 2 to \(UITree.maxOptions).")
        }
        for option in options {
          if let found = string(option, "an option", at: here, limit: UITree.maxOption, required: true) { return found }
        }
        if Set(options).count != options.count { return Problem(.badValue, "\(here): each option needs its own words.") }
        if let selected = block.selected, !options.contains(selected) {
          return Problem(.badValue, "\(here): selected is one of the options, word for word.")
        }
        return nil
      case .input:
        inputs += 1
        if let found = control(block, at: here) { return found }
        return string(block.placeholder, "placeholder", at: here, limit: UITree.maxLabel)
      }
    }

    func table(_ block: UIBlock, at here: String) -> Problem? {
      let rows: [[String]] = block.rows ?? []
      if rows.isEmpty { return Problem(.missing, "\(here) needs rows.") }
      if rows.count > UITree.maxTableRows { return Problem(.tooMany, "\(here) has \(rows.count) rows. Use \(UITree.maxTableRows) or fewer.") }
      let width: Int = block.headers?.count ?? rows[0].count
      if !(1...UITree.maxTableColumns).contains(width) {
        return Problem(.tooMany, "\(here) has \(width) columns. Use 1 to \(UITree.maxTableColumns).")
      }
      if rows.contains(where: { $0.count != width }) {
        return Problem(.badValue, "\(here): every row needs \(width) cells, one for each column.")
      }
      for (index, header) in (block.headers ?? []).enumerated() {
        if let found = string(header, "the header", at: "\(here) column \(index + 1)", limit: UITree.maxLabel, required: true) { return found }
      }
      for (index, row) in rows.enumerated() {
        for cell in row {
          if let found = string(cell, "a cell", at: "\(here) row \(index + 1)", limit: UITree.maxCell) { return found }
        }
      }
      return nil
    }
  }

  /// `ui_show`'s `blocks` in the tool list (Relay.swift). Children are described once, not nested:
  /// the limits live in `problem`, which answers a wrong tree in words.
  public static var blocksSchema: [String: Any] {
    let string: [String: Any] = ["type": "string"]
    func oneOf(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
    let tones: [String: Any] = oneOf(UIBlock.Tone.allCases.map(\.rawValue))
    let item: [String: Any] = [
      "type": "object", "properties": ["title": string, "detail": string, "value": string, "tone": tones], "required": ["title"],
    ]
    let properties: [String: Any] = [
      "type": oneOf(UIBlock.Kind.allCases.map(\.rawValue)),
      "children": ["type": "array", "items": ["type": "object"]],
      "columns": ["type": "integer"],
      "title": string, "text": string,
      "style": oneOf(UIBlock.TextStyle.allCases.map(\.rawValue) + UIBlock.ButtonStyle.allCases.map(\.rawValue)),
      "label": string, "value": string, "trend": oneOf(["up", "down", "flat"]), "change": string,
      "tone": tones, "dot": ["type": "boolean"], "percent": ["type": "number"], "detail": string,
      "headers": ["type": "array", "items": string],
      "rows": ["type": "array", "items": ["type": "array", "items": string]],
      "items": ["type": "array", "items": item],
      "marker": oneOf(UIBlock.Marker.allCases.map(\.rawValue)),
      "chart": ["type": "object"],
      "on": ["type": "boolean"], "number": ["type": "number"], "min": ["type": "number"], "max": ["type": "number"],
      "step": ["type": "number"], "options": ["type": "array", "items": string], "selected": string, "placeholder": string,
    ]
    return ["type": "array", "items": ["type": "object", "properties": properties, "required": ["type"]]]
  }
  public static let toolDescription: String =
    "Draw a small view under your reply from blocks you choose, when a custom layout shows the answer better than text or dashboard_make's fixed card (a status board, a comparison, a budget, a queue, a short form). "
    + "title: an optional heading, at most \(maxTitle) characters. blocks: one or more, each an object with a type. "
    + "Layout: column {children}; row {children, at most \(maxRowChildren); a row of stats draws as one strip}; grid {columns 2 to \(maxGridColumns), children}; card {title, children} for an inset tile. "
    + "Content: text {text, style: title, body or meta}; stat {label, value, trend: up, down or flat, change, tone}; badge {text, tone, dot}; "
    + "table {headers, rows: arrays of strings}; progress {label, percent 0 to 100, detail}; list {items: [{title, detail, value, tone}], marker: none, bullet or number}; divider; "
    + "chart {chart: {kind: bar, line or pie, title, labels, series: [{name, values}], unit}}. tone is neutral, accent, success, warning or danger. "
    + "Controls the person can use: button {label, style: primary or secondary}; toggle {label, on}; stepper {label, number, min, max, step}; "
    + "choice {label, options: 2 to \(maxOptions) short strings, selected}; input {label, placeholder} for one line of typed text. "
    + "Pressing a button sends its label as the person's next message, with a line \"label: value\" under it for each toggle, stepper, choice and filled input in the view; act on that message as on anything they type. "
    + "To show the result, call ui_show again in that answer with the whole view as it is now: it takes the place of the view they pressed. "
    + "Controls do nothing until a button is pressed, so a view with controls needs a button. Give every button and control its own label, and make a button's label say exactly what pressing it asks for. "
    + "Never ask for a password, a sign-in code, a key or card details in an input. "
    + "Limits: \(maxBlocks) blocks, \(maxDepth) levels, \(maxChildren) children, \(maxButtons) buttons, \(maxControls) controls. Every string is drawn as plain text, so write no Markdown. Use only facts you already have. "
    + "If the answer is an error, fix the block it names and call again. Do not repeat the view's contents in your reply."
}
