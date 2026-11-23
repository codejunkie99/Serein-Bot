import Foundation

/// Whether Serein's built-in computer uses Cua Driver for its screen, input and tree (DriverScreen)
/// when its boot image carries the pinned driver. Older images continue to use their helper.
public enum CuaDriverPolicy {
  public static let switchKey = "serein.computer.builtIn.cuaDriver"
  public static func isOn(defaults: any SettingsStore = GateSettings.shared) -> Bool {
    defaults.object(forKey: switchKey) as? Bool ?? true
  }
}

/// Serein's own screen ops (the helper's names and arguments, as ComputerHost.screenCall sends
/// them) as calls of Cua Driver's closed tool set, and the driver's answers read back into the
/// helper's answer shapes (CUA-INTEGRATION.md section 3). Every call targets the primary desktop
/// in the foreground: the guest's desktop has one controller, and no `/dev/uinput` is needed.
/// Every answer is untrusted: it is read into typed fields against the shape pinned here, and an
/// answer of another shape is refused, never passed on.
public enum DriverCalls {
  public struct Call {
    public let tool: DriverWire.Tool
    public let arguments: [String: Any]
  }
  static var desktop: [String: Any] { ["kind": "desktop", "display_id": "primary"] }
  static func input(_ tool: DriverWire.Tool, _ fields: [String: Any]) -> Call {
    var arguments: [String: Any] = ["target": desktop, "delivery_mode": "foreground"]
    arguments.merge(fields) { _, new in new }
    return Call(tool: tool, arguments: arguments)
  }
  /// A picture's longest side: the guest's screen (1280×800) at full size.
  public static let pictureEdge = 1280
  /// Elements one window's read walks, and how long it may take: the walker's own limits, so a
  /// window of a few thousand elements is read whole (Cua Driver 0.53.2 cuts at 250 and 1 second
  /// by default). Windows one tree or one x, y step reads.
  public static let treeElements = 5_000
  public static let treeMilliseconds = 5_000
  /// A popup's read walks its whole app first, so it may take longer: on the box, the list of
  /// browsers in Default Applications took 5.5 seconds to read.
  public static let popupMilliseconds = 15_000
  public static let treeWindows = 12
  /// The printed tree's rows at most, as the helper's. The judging read is not held to it.
  public static let treeRows = 2_000

  // MARK: Serein's ops as calls

  public static func screenshot() -> Call { Call(tool: .getDesktopState, arguments: ["max_image_dimension": pictureEdge]) }

  /// A click at x, y of the latest picture, bound to that picture's one-use `capture` when Serein
  /// holds one; nil for a point off the screen or an unknown button.
  public static func click(_ a: [String: Any], capture: String?) -> Call? {
    guard let x = coordinate(a["x"], below: ComputerPolicy.screenWidth), let y = coordinate(a["y"], below: ComputerPolicy.screenHeight)
    else { return nil }
    let button = String(describing: a["button"] ?? "left").lowercased()
    guard ["left", "middle", "right"].contains(button) else { return nil }
    let count: Int = a["double"] as? Bool == true ? 2 : 1
    var fields: [String: Any] = ["x": x, "y": y, "button": button, "count": count]
    if let capture, validCapture(capture) { fields["capture_id"] = capture }
    return input(.click, fields)
  }
  /// Text typed where the keyboard focus is: 1 to 8,000 characters.
  public static func type(_ text: String) -> Call? {
    guard !text.isEmpty, text.count <= 8_000 else { return nil }
    return input(.typeText, ["text": text])
  }
  /// One press per key or chord, in order; nil for words the helper would refuse too.
  public static func keys(_ raw: String) -> [Call]? {
    keyPresses(raw)?.map { input(.pressKey, $0.fields) }
  }
  /// Scroll notches at x, y: up or down, 1 to 30 (the helper's clamp).
  public static func scroll(_ a: [String: Any]) -> Call? {
    guard let x = coordinate(a["x"], below: ComputerPolicy.screenWidth), let y = coordinate(a["y"], below: ComputerPolicy.screenHeight)
    else { return nil }
    let direction = String(describing: a["direction"] ?? "down").lowercased() == "up" ? "up" : "down"
    let amount = max(1, min(30, coordinate(a["amount"] ?? 3, below: 1_000_000) ?? 3))
    return input(.scroll, ["x": x, "y": y, "direction": direction, "amount": amount])
  }
  public static func windows() -> Call { Call(tool: .listWindows, arguments: ["on_screen_only": true]) }
  /// One window's whole accessibility tree as structured rows, every depth (the model's tree
  /// shows the first `depth` levels of it, the floor judges all of it); with `picture`, the
  /// window's own picture too, which `zoom` needs first.
  public static func windowState(pid: Int, window: Int, picture: Bool = false, popup: Bool = false) -> Call {
    Call(tool: .getWindowState, arguments: [
      "pid": pid, "window_id": window, "max_elements": treeElements, "timeout_ms": popup ? popupMilliseconds : treeMilliseconds,
      "include_screenshot": picture, "tree_format": "elements",
    ])
  }
  /// A step on one element of a window's latest read: its process and the read's token. In the
  /// foreground, like every other input call (X11 delivers keys only to the focused window); a
  /// `background` click is the element's own accessibility action, with no pointer.
  public static func onElement(_ tool: DriverWire.Tool, pid: Int, token: String, _ fields: [String: Any] = [:], background: Bool = false) -> Call {
    var arguments: [String: Any] = ["pid": pid, "element_token": token, "delivery_mode": background ? "background" : "foreground"]
    arguments.merge(fields) { _, new in new }
    return Call(tool: tool, arguments: arguments)
  }
  /// An element token as the driver gives one: `s<hex>:<index>`, short and plain.
  public static func validToken(_ token: String) -> Bool {
    let parts = token.split(separator: ":", omittingEmptySubsequences: false)
    guard token.count <= 32, parts.count == 2, parts[0].first == "s", parts[0].count > 1, !parts[1].isEmpty else { return false }
    return parts[0].dropFirst().allSatisfy(\.isHexDigit) && parts[1].allSatisfy(\.isNumber) && token.allSatisfy(\.isASCII)
  }
  /// A closer look at a region (x1, y1)-(x2, y2) of a window's own latest picture.
  public static func zoom(_ a: [String: Any]) -> Call? {
    guard let window = coordinate(a["window_id"], below: Int(UInt32.max)), window > 0,
      let x1 = coordinate(a["x1"], below: 10_000), let y1 = coordinate(a["y1"], below: 10_000),
      let x2 = coordinate(a["x2"], below: 10_000), let y2 = coordinate(a["y2"], below: 10_000), x2 > x1, y2 > y1
    else { return nil }
    return Call(tool: .zoom, arguments: ["window_id": window, "x1": x1, "y1": y1, "x2": x2, "y2": y2])
  }

  /// The tree's depth from the agent's arguments: 1 to 12, 6 when not given (the helper's rule).
  public static func depth(_ value: Any?) -> Int {
    max(1, min(12, value.flatMap { coordinate($0, below: 1_000) } ?? 6))
  }

  /// A whole number from the agent's arguments (a number, or a number in a string), rounded, in
  /// 0..<limit; nil otherwise.
  public static func coordinate(_ value: Any?, below limit: Int) -> Int? {
    var parsed: Double?
    if let number = DriverWire.number(value) {
      parsed = number
    } else if let text = value as? String, let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite {
      parsed = number
    }
    guard let parsed, parsed >= 0, parsed < Double(limit) else { return nil }
    return Int(parsed.rounded())
  }
  /// A capture id as the driver gives one: short, and only plain characters.
  public static func validCapture(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_:.".unicodeScalars.contains($0)) }
  }

  // MARK: keys

  public struct KeyPress: Equatable, Sendable {
    public let key: String
    public let modifiers: [String]
    public init(key: String, modifiers: [String]) {
      self.key = key
      self.modifiers = modifiers
    }
    /// press_key's own arguments for it.
    public var fields: [String: Any] { modifiers.isEmpty ? ["key": key] : ["key": key, "modifiers": modifiers] }
  }
  /// Serein's key words (xdotool's names, as the agent sends them) in the driver's own names.
  static let keyNames: [String: String] = [
    "return": "return", "enter": "return", "kp_enter": "return", "tab": "tab", "escape": "escape", "esc": "escape",
    "space": "space", "backspace": "backspace", "delete": "delete", "insert": "insert", "home": "home", "end": "end",
    "prior": "pageup", "page_up": "pageup", "pageup": "pageup", "next": "pagedown", "page_down": "pagedown",
    "pagedown": "pagedown", "up": "up", "down": "down", "left": "left", "right": "right", "minus": "minus", "plus": "plus",
    "equal": "equal", "period": "period", "comma": "comma", "slash": "slash", "backslash": "backslash",
    "semicolon": "semicolon", "colon": "colon", "underscore": "underscore", "asterisk": "asterisk",
    "parenleft": "parenleft", "parenright": "parenright", "f1": "f1", "f2": "f2", "f3": "f3", "f4": "f4", "f5": "f5",
    "f6": "f6", "f7": "f7", "f8": "f8", "f9": "f9", "f10": "f10", "f11": "f11", "f12": "f12",
  ]
  static let modifierNames: [String: String] = [
    "ctrl": "ctrl", "control": "ctrl", "alt": "alt", "shift": "shift", "super": "super", "cmd": "super", "meta": "super",
  ]
  /// A key or a space-separated sequence of keys and chords (`Return`, `ctrl+l`, `Tab Tab`), with
  /// the helper's rules: its characters only, 40 at most, 8 presses at most; each chord ends with
  /// one key (a known name, or one letter or digit) after its known modifiers. nil otherwise.
  public static func keyPresses(_ raw: String) -> [KeyPress]? {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+ ")
    let text = raw.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty, text.count <= 40, text.allSatisfy(allowed.contains) else { return nil }
    let chords = text.split(separator: " ")
    guard chords.count <= 8 else { return nil }
    var presses: [KeyPress] = []
    for chord in chords {
      let parts = chord.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
      guard let last = parts.last, !last.isEmpty else { return nil }
      var modifiers: [String] = []
      for part in parts.dropLast() {
        guard let modifier = modifierNames[part.lowercased()] else { return nil }
        modifiers.append(modifier)
      }
      let named = keyNames[last.lowercased()]
      let single: String? = last.count == 1 ? last : nil
      guard let key = named ?? single else { return nil }
      presses.append(KeyPress(key: key, modifiers: modifiers))
    }
    return presses
  }

  // MARK: the driver's answers, read back

  /// A desktop picture: the PNG as base64 (its bytes are checked by ScreenPicture before any
  /// decoder sees them), its size, the driver's one-use binding for a click on it, and desktop
  /// pixels per picture pixel (the driver maps a click's x, y back itself; the floor's point needs it).
  public struct Shot: Equatable, Sendable {
    public let png: String
    public let width: Int
    public let height: Int
    public let capture: String?
    public let scale: Double
    public init(png: String, width: Int, height: Int, capture: String?, scale: Double = 1) {
      self.png = png
      self.width = width
      self.height = height
      self.capture = capture
      self.scale = scale
    }
  }
  public static func shot(_ answer: DriverWire.ToolAnswer) -> Shot? {
    let pictures = answer.images.filter { $0.mimeType == "image/png" }
    guard !answer.isError, answer.images.count == 1, let picture = pictures.first, let structured = answer.structured,
      let width = DriverWire.integer(structured["screenshot_width"]), let height = DriverWire.integer(structured["screenshot_height"]),
      (1...pictureEdge).contains(width), (1...pictureEdge).contains(height)
    else { return nil }
    let capture = (structured["capture_id"] as? String).flatMap { validCapture($0) ? $0 : nil }
    let screen = DriverWire.integer(structured["screen_width"]).flatMap { (width...width * 8).contains($0) ? $0 : nil } ?? width
    return Shot(png: picture.data, width: width, height: height, capture: capture, scale: Double(screen) / Double(width))
  }

  /// Why an input step did not happen, in Serein's words, or nil when the driver did it: a tool
  /// failure, a refused action, or an action answer of another shape.
  public static func inputRefusal(_ tool: DriverWire.Tool, _ answer: DriverWire.ToolAnswer) -> String? {
    if answer.isError { return DriverWire.refusal(tool, code: DriverWire.failureCode(answer)) }
    guard let effect = answer.structured?["effect"] else { return nil }
    let known: Set<String> = ["confirmed", "partial", "unverifiable", "suspected_noop", "refused"]
    guard let word = effect as? String, known.contains(word) else { return DriverWire.unreadable(tool) }
    return word == "refused" ? DriverWire.refusal(tool, code: DriverWire.failureCode(answer)) : nil
  }

  /// Where Cua Driver says the keyboard focus was after a step on an element (`focus_after=` in
  /// its summary: `target`, `same_pid` and the like), or nil when it does not say.
  public static func focusAfter(_ answer: DriverWire.ToolAnswer) -> String? {
    let text = answer.structured?["summary"] as? String ?? answer.texts.joined(separator: " ")
    guard let found = text.range(of: "focus_after=[a-z_]+", options: .regularExpression) else { return nil }
    return String(text[found].dropFirst("focus_after=".count))
  }

  public struct Window: Equatable, Sendable {
    public let id: Int
    public let pid: Int?
    public let title: String
    public let app: String
    /// Its place on the desktop, when the driver gives one.
    public let bounds: Row.Frame?
    public init(id: Int, pid: Int?, title: String, app: String, bounds: Row.Frame? = nil) {
      self.id = id
      self.pid = pid
      self.title = title
      self.app = app
      self.bounds = bounds
    }
  }
  /// The on-screen windows of a `list_windows` answer; nil when the answer is not that shape.
  public static func windowList(_ answer: DriverWire.ToolAnswer) -> [Window]? {
    guard !answer.isError, let entries = answer.structured?["windows"] as? [[String: Any]], entries.count <= 200 else { return nil }
    var windows: [Window] = []
    for entry in entries {
      guard let id = DriverWire.integer(entry["window_id"]), id >= 0, let title = entry["title"] as? String,
        let app = entry["app_name"] as? String
      else { return nil }
      if entry["is_on_screen"] as? Bool == false { continue }
      let pid = DriverWire.integer(entry["pid"]).flatMap { $0 > 0 ? $0 : nil }
      let bounds = (entry["bounds"] as? [String: Any]).flatMap { frame($0, width: "width", height: "height") }
      windows.append(Window(id: id, pid: pid, title: shown(AgentPrivacy.redact(title), 200), app: shown(app, 200), bounds: bounds))
    }
    return windows
  }
  /// The popups open in a read window (a menu, a list), which `list_windows` leaves out and each
  /// `get_window_state` answer names: those on the screen, as windows of `app`.
  public static func popups(_ answer: DriverWire.ToolAnswer, app: String) -> [Window] {
    guard !answer.isError, let entries = answer.structured?["popups"] as? [[String: Any]] else { return [] }
    return entries.prefix(treeWindows).compactMap { entry in
      guard let id = DriverWire.integer(entry["window_id"]), id >= 0, let pid = DriverWire.integer(entry["pid"]), pid > 0,
        let bounds = (entry["bounds"] as? [String: Any]).flatMap({ frame($0, width: "width", height: "height") }),
        bounds.width > 1, bounds.height > 1, bounds.x + bounds.width > 0, bounds.y + bounds.height > 0,
        bounds.x < ComputerPolicy.screenWidth, bounds.y < ComputerPolicy.screenHeight
      else { return nil }
      return Window(id: id, pid: pid, title: shown(AgentPrivacy.redact(entry["title"] as? String ?? ""), 200), app: app, bounds: bounds)
    }
  }
  /// The helper's `windows` answer: each window's id and title.
  public static func windowsAnswer(_ windows: [Window], hiddenNumberLabels: Set<String> = []) -> [[String: Any]] {
    windows.map { ["id": String($0.id), "title": hiddenNumberLabels.contains($0.title) ? AgentPrivacy.hidingDigits($0.title) : $0.title] }
  }
  /// The windows a tree reads: those whose title holds `wanted` (any case), or all, with a pid.
  public static func treeTargets(_ windows: [Window], wanted: String?) -> [Window] {
    let name = (wanted ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    let named = windows.filter { $0.pid != nil && (name.isEmpty || $0.title.lowercased().contains(name)) }
    return Array(named.prefix(treeWindows))
  }

  /// One row of a window's tree: its role, label and place on the screen (screen pixels, which are
  /// the picture's: the driver gives every element's frame in desktop coordinates).
  public struct Row: Equatable, Sendable {
    public struct Frame: Equatable, Sendable {
      public let x: Int
      public let y: Int
      public let width: Int
      public let height: Int
      public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
      }
      public func holds(_ px: Int, _ py: Int) -> Bool { px >= x && px < x + width && py >= y && py < y + height }
    }
    public let depth: Int
    public let role: String
    public private(set) var label: String
    /// Chromium appends this counter to tab titles. Record whether the title itself has a price
    /// before any digits are hidden. Only the browser's native tab strip uses this distinction.
    let onlyTabMemoryAmount: Bool
    private var priceBeforeRedaction = false
    var hasPrice: Bool { priceBeforeRedaction || ApprovalGate.hasPrice(label) }

    /// Keep the approval decision when a displayed amount is hidden, without retaining the amount.
    fileprivate mutating func hideDigits() {
      priceBeforeRedaction = hasPrice
      label = AgentPrivacy.hidingDigits(label)
    }
    public let frame: Frame?
    /// The driver's index of an element it can act on, and its token in this read (nil for a
    /// row the driver gives no address).
    public let index: Int?
    public let token: String?
    /// A field that holds text: its label is dropped, so the text never reaches the model.
    public let filled: Bool
    /// The driver's index of the element this row sits in.
    public let parent: Int?
    /// The row has an accessibility action besides its context menu: a click can be that action.
    public let acts: Bool
    public init(
      depth: Int, role: String, label: String, frame: Frame?, index: Int? = nil, token: String? = nil, filled: Bool = false, parent: Int? = nil,
      acts: Bool = false
    ) {
      if role == "page tab", let suffix = label.range(of: #" - Memory usage - [0-9]+(?:[.,][0-9]+)? [KMGT]?B$"#, options: .regularExpression) {
        onlyTabMemoryAmount = !ApprovalGate.hasPrice(String(label[..<suffix.lowerBound]))
      } else {
        onlyTabMemoryAmount = false
      }
      self.depth = depth
      self.role = role
      self.label = label
      self.frame = frame
      self.index = index
      self.token = token
      self.filled = filled
      self.parent = parent
      self.acts = acts
    }
  }
  /// A `get_window_state` answer's rows (its elements, each followed by the display-only
  /// observations inside it), whether its walk stopped short or left frames out, and whether the
  /// app gave no real tree (`degraded`: Chromium with its accessibility off); nil for another shape.
  public static func treeRows(_ answer: DriverWire.ToolAnswer) -> (rows: [Row], cut: Bool, degraded: Bool)? {
    guard !answer.isError, let structured = answer.structured, DriverWire.integer(structured["window_id"]) != nil else { return nil }
    func list(_ key: String) -> [[String: Any]]? {
      guard let value = structured[key], !(value is NSNull) else { return [] }
      return value as? [[String: Any]]
    }
    guard let entries = list("elements"), let notes = list("observations") else { return nil }
    var rows: [Row] = []
    var inside: [Int: [Row]] = [:]
    for entry in notes.prefix(treeElements) {
      guard let row = row(entry) else { return nil }
      inside[row.parent ?? -1, default: []].append(row)
    }
    for entry in entries.prefix(treeElements) {
      guard let row = row(entry) else { return nil }
      rows.append(row)
      if let index = row.index { rows += inside.removeValue(forKey: index) ?? [] }
    }
    rows += inside.keys.sorted().flatMap { inside[$0] ?? [] }
    // XFCE exposes the panel's visible launcher and clock buttons without their layout containers.
    // Treat that flat list as one privacy group. A partial read or a named but missing parent
    // still cannot establish which controls or fragments belong together.
    let flatPanel = structured["app_name"] as? String == "Xfce4-panel"
      && structured["truncated"] as? Bool == false && structured["elements_complete"] as? Bool == true
      && structured["bounds_complete"] as? Bool == true && structured["degraded"] as? Bool != true
      && entries.count <= treeElements && notes.isEmpty
      && rows.allSatisfy { $0.parent == nil && $0.role == "toggle button" }
      && !zip(rows, rows.dropFirst()).contains { ApprovalGate.pricedAcrossRows($0.label, $1.label) }
    guard let safe = grouped(rows, flatPanel: flatPanel) else { return nil }
    let degraded = structured["degraded"] as? Bool == true
    let cut = structured["truncated"] as? Bool == true || structured["elements_complete"] as? Bool == false
      || structured["bounds_complete"] as? Bool == false || degraded
      || entries.count > treeElements || notes.count > treeElements
    return (safe, cut, degraded)
  }
  /// Observations and addressable children are reported separately, not necessarily in paint order.
  /// Do not use a checksum on one guessed ordering to clear fragments of a possible card.
  static func grouped(_ rows: [Row], flatPanel: Bool) -> [Row]? {
    // Descriptive labels can each carry a different part of a number.
    let fragments = rows.map { $0.label.filter(\.isWholeNumber) }
    guard fragments.contains(where: { !$0.isEmpty }) else { return rows }
    var at: [Int: Int] = [:]
    for (i, row) in rows.enumerated() {
      if let index = row.index, at.updateValue(i, forKey: index) != nil { return nil }
    }
    let up = rows.map { $0.parent.flatMap { at[$0] } }
    var pages: [Int: [Int]] = [:]
    for i in rows.indices {
      let chain = FreshRead.chain(i, up)
      guard let root = chain.last, rows[root].parent == nil else { return nil }
      let page = chain.first { rows[$0].role.lowercased().hasPrefix("document") }
      // A missing link must not put part of this page's number in a different group.
      if rows[root].depth != 0 && page == nil && !flatPanel { return nil }
      pages[page ?? -1, default: []].append(i)
    }
    var out = rows
    for page in pages.values {
      let numeric = page.filter { !fragments[$0].isEmpty }
      guard !numeric.isEmpty else { continue }
      let labels = numeric.map { rows[$0].label }
      let cardLabels = HandBack.cardFragmentLabels(labels)
      let hideAll = page.contains { rows[$0].label.contains(AgentPrivacy.replacement) }
        || FilledValues.shared.containsAcross(labels: labels, digits: numeric.map { fragments[$0] })
      // A registered value can span labels. Card-only matches retain unrelated figures.
      for i in numeric where hideAll || cardLabels.contains(rows[i].label) || HandBack.containsCardNumber(fragments[i]) {
        out[i].hideDigits()
      }
    }
    guard out != rows else { return rows }
    // A number can also identify a price or a challenge. Withhold an ambiguous read instead of
    // changing what a subsequent input would be allowed to do.
    let before = FreshRead(pid: 0, window: 0, rows: rows, cut: false)
    let after = FreshRead(pid: 0, window: 0, rows: out, cut: false)
    guard before.marks == after.marks, before.captchas == after.captchas, !before.pays || after.pays else { return nil }
    return out
  }
  static func row(_ entry: [String: Any]) -> Row? {
    guard let role = entry["role"] as? String, let depth = DriverWire.integer(entry["depth"]), depth >= 0 else { return nil }
    // AT-SPI gives a field its text as its label once it has some, whoever typed it: a field with
    // text keeps its label only when the two share nothing. Labels are redacted, and judged
    // whole: only the printed tree clips them (ElementTable). A field whose text Serein redacts
    // (a value it filled, a card number) says so, so a picture of it is masked (FreshRead.secretPlaces).
    let raw = entry["label"] as? String ?? "", value = entry["value"] as? String ?? ""
    let filled = !value.isEmpty && BoxFloor.fieldRoles.contains(role.lowercased())
    let same = raw.localizedCaseInsensitiveContains(value) || value.localizedCaseInsensitiveContains(raw)
    let held = filled && (FilledValues.shared.scrubAll(value) != value || HandBack.containsCardNumber(value))
    let words = filled && same ? "" : AgentPrivacy.redact(raw)
    let label = held && !words.contains(AgentPrivacy.replacement) ? (words.isEmpty ? "" : words + " ") + AgentPrivacy.replacement : words
    let index = DriverWire.integer(entry["element_index"]).flatMap { $0 >= 0 ? $0 : nil }
    let parent = DriverWire.integer(entry["parent_index"]).flatMap { $0 >= 0 ? $0 : nil }
    let token = (entry["element_token"] as? String).flatMap { validToken($0) ? $0 : nil }
    let acts = (entry["actions"] as? [Any] ?? []).contains { ($0 as? String).map { $0 != "showContextMenu" } ?? false }
    return Row(
      depth: min(depth, 40), role: shown(role, 40), label: shown(label, .max), frame: (entry["frame"] as? [String: Any]).flatMap { frame($0) },
      index: index, token: token, filled: filled, parent: parent, acts: acts)
  }
  /// The popups a `get_window_state` answer says are open over its window (`popups`: a context
  /// menu is an override-redirect window `list_windows` never lists), each as a window.
  public static func popups(_ answer: DriverWire.ToolAnswer) -> [Window] {
    completePopups(answer) ?? []
  }

  /// The pinned driver omits an empty popup list. A partial list cannot clear a picture.
  public static func completePopups(_ answer: DriverWire.ToolAnswer) -> [Window]? {
    guard !answer.isError, let state = answer.structured else { return nil }
    guard let value = state["popups"] else { return [] }
    guard let entries = value as? [[String: Any]], entries.count <= treeWindows else { return nil }
    var windows: [Window] = []
    for entry in entries {
      guard let id = DriverWire.integer(entry["window_id"]), id > 0 else { return nil }
      let bounds = (entry["bounds"] as? [String: Any]).flatMap { frame($0, width: "width", height: "height") }
      let pid = DriverWire.integer(entry["pid"]).flatMap { $0 > 0 ? $0 : nil }
      windows.append(Window(id: id, pid: pid, title: "menu", app: "popup", bounds: bounds))
    }
    return windows
  }

  public static func staleWindow(_ answer: DriverWire.ToolAnswer, pid: Int, id: Int) -> Bool {
    answer.isError && answer.texts == ["Window target pid \(pid), window_id \(id) is stale or no longer running; refresh list_windows."]
  }

  static func frame(_ box: [String: Any], width: String = "w", height: String = "h") -> Row.Frame? {
    guard let x = DriverWire.number(box["x"]), let y = DriverWire.number(box["y"]), let w = DriverWire.number(box[width]),
      let h = DriverWire.number(box[height]), abs(x) < 1e6, abs(y) < 1e6, (0..<1e6).contains(w), (0..<1e6).contains(h)
    else { return nil }
    return Row.Frame(x: Int(x.rounded()), y: Int(y.rounded()), width: Int(w.rounded()), height: Int(h.rounded()))
  }

  /// A `get_window_state` answer's window on the desktop (`window_bounds`), or nil.
  public static func windowBounds(_ answer: DriverWire.ToolAnswer) -> Row.Frame? {
    guard !answer.isError, let box = answer.structured?["window_bounds"] as? [String: Any],
      let frame = frame(box, width: "width", height: "height"), frame.width > 0, frame.height > 0
    else { return nil }
    return frame
  }

  /// A zoomed region: the JPEG as base64 with its size, once its bytes are checked.
  public static func zoomPicture(_ answer: DriverWire.ToolAnswer) -> (jpeg: String, width: Int, height: Int)? {
    guard !answer.isError, answer.images.count == 1, let picture = answer.images.first, picture.mimeType == "image/jpeg",
      let bytes = Data(base64Encoded: picture.data), let size = ScreenPicture.jpegSize(bytes),
      (1...pictureEdge).contains(size.width), (1...pictureEdge).contains(size.height)
    else { return nil }
    return (picture.data, size.width, size.height)
  }

  /// Text from inside the computer for a line of Serein's own: no control or invisible
  /// characters, at most `limit` characters.
  static func shown(_ text: String, _ limit: Int) -> String {
    let kept = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !$0.properties.isDefaultIgnorableCodePoint }
    return String(String(kept.map(Character.init)).prefix(limit))
  }
  static func quoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
  }
}

/// A screen picture from inside a computer, read by hand before any image decoder sees it: the PNG
/// signature and IHDR (or a JPEG's start and frame header), at most 8 MB.
public enum ScreenPicture {
  public static let byteLimit = 8_000_000
  public enum Rule: Equatable, Sendable {
    /// Exactly this size: the helper's pictures of Serein's own computers (1280×800).
    case exactly(width: Int, height: Int)
    /// 1 to this many pixels a side: the person's own machine (its helper scales to fit) and
    /// Cua Driver's pictures (a desktop, a window or a zoom).
    case upTo(Int)
  }
  /// The rule for a computer's screen pictures: exactly the screen on Serein's own computers
  /// through the helper; 1 to 1280 a side on the person's own machine and through Cua Driver.
  public static func rule(isolated: Bool, driver: Bool) -> Rule {
    isolated && !driver ? .exactly(width: ComputerPolicy.screenWidth, height: ComputerPolicy.screenHeight) : .upTo(1280)
  }
  public static func size(_ png: Data, rule: Rule) -> (width: Int, height: Int)? {
    guard let size = pngSize(png) else { return nil }
    switch rule {
    case .exactly(let width, let height):
      return size.width == width && size.height == height ? size : nil
    case .upTo(let edge):
      return (1...edge).contains(size.width) && (1...edge).contains(size.height) ? size : nil
    }
  }
  /// A PNG's width and height from its signature and IHDR chunk; nil for anything else.
  public static func pngSize(_ png: Data) -> (width: Int, height: Int)? {
    guard png.count > 24, png.count <= byteLimit else { return nil }
    let b = [UInt8](png.prefix(24))
    guard Array(b[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], Array(b[12..<16]) == [0x49, 0x48, 0x44, 0x52]
    else { return nil }
    return (word(b, 16), word(b, 20))
  }
  /// A baseline or progressive JPEG's width and height from its first frame header (SOF0 to SOF2),
  /// walking the marker segments from the start; nil for anything else.
  public static func jpegSize(_ jpeg: Data) -> (width: Int, height: Int)? {
    guard jpeg.count > 4, jpeg.count <= byteLimit else { return nil }
    let b = [UInt8](jpeg)
    guard b[0] == 0xFF, b[1] == 0xD8 else { return nil }
    var i = 2
    while i + 3 < b.count {
      guard b[i] == 0xFF else { return nil }
      let marker = b[i + 1]
      if marker == 0xFF {
        i += 1
        continue
      }
      // Start of scan or end of image before a frame header: no size.
      if marker == 0xDA || marker == 0xD9 { return nil }
      let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
      guard length >= 2, i + 2 + length <= b.count else { return nil }
      if (0xC0...0xC2).contains(marker) {
        guard length >= 7 else { return nil }
        let height = Int(b[i + 5]) << 8 | Int(b[i + 6])
        let width = Int(b[i + 7]) << 8 | Int(b[i + 8])
        return width > 0 && height > 0 ? (width, height) : nil
      }
      i += 2 + length
    }
    return nil
  }
  static func word(_ b: [UInt8], _ i: Int) -> Int {
    let b0 = Int(b[i]), b1 = Int(b[i + 1]), b2 = Int(b[i + 2]), b3 = Int(b[i + 3])
    return b0 << 24 | b1 << 16 | b2 << 8 | b3
  }
}
