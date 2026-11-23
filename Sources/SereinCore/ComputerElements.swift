import Foundation

/// A ref the model names an element of Serein's computer by: `e<read>.<number>`, for example
/// "e7.4". It starts with a letter, so it is never read as a pixel. It names an element of one
/// read only: the read that printed it.
public struct ElementRef: Hashable, Sendable, CustomStringConvertible {
  public let read: Int
  public let number: Int
  public init(read: Int, number: Int) {
    self.read = read
    self.number = number
  }
  /// "e7.4" and nothing else, 16 characters at most.
  public init?(_ raw: Any?) {
    guard let text = raw as? String, text.count <= 16, text.first == "e" else { return nil }
    let parts = text.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
      let read = Int(parts[0]), let number = Int(parts[1]), read > 0
    else { return nil }
    self.init(read: read, number: number)
  }
  public var description: String { "e\(read).\(number)" }
}

/// Why a ref names no element Serein can act on. Each line is Serein's own words.
public enum ElementMiss: Error, Equatable, Sendable {
  case noRead, olderRead, unknown, changed
  public var line: String {
    switch self {
    case .noRead: return "Read the screen with computer_tree first; element refs come from it."
    case .olderRead: return "That ref is from an older computer_tree. Use a ref from your latest computer_tree."
    case .unknown: return "Your latest computer_tree has no element with that ref. Use a ref it printed, or x and y."
    case .changed: return "That element is gone or changed since your latest computer_tree. Use your latest computer_tree: call it again, then act."
    }
  }
}

/// An element of one window, as a step aims at it: its process and window, the row a read showed,
/// and its place (0 first) among that window's rows of the same role and label down to `depth`
/// (the model's tree shows rows down to its depth; a whole read's own rows have no ceiling).
public struct BoxTarget: Equatable, Sendable {
  public let pid: Int
  public let window: Int
  public let row: DriverCalls.Row
  public let nth: Int
  public let depth: Int
  /// No one element: a stop of the whole screen's.
  static let screen = BoxTarget(pid: 0, window: 0, row: DriverCalls.Row(depth: 0, role: "screen", label: "", frame: nil), nth: 0, depth: .max)
}

/// One window read whole for the floor (DriverScreen.read, inside the step's own slot): every row,
/// token or not, and what of each is the person's. A row inside a CAPTCHA is the CAPTCHA's. The
/// floor judges a step on this read only, never on one the model saw earlier.
public struct FreshRead: Sendable {
  public let pid: Int
  public let window: Int
  public let rows: [DriverCalls.Row]
  public let marks: [BoxFloor.Mark?]
  /// The CAPTCHA each row sits in (an index into rows, the outermost), or nil.
  public let captchas: [Int?]
  /// Each row's parent (an index into rows), and where it is: its frame, or its nearest framed
  /// ancestor's when the driver gives it none.
  let up: [Int?]
  let places: [DriverCalls.Row.Frame?]
  /// Each row's depth as a tree's `depth` counts it: from its outermost document (a web page's
  /// rows sit many levels under the browser's own), else from the window.
  public let levels: [Int]
  /// The walk stopped short (the driver's limits) or the app gave no real tree (`degraded`).
  public let cut: Bool
  public let commandWindow: Bool
  public let degraded: Bool

  public init(pid: Int, window: Int, rows: [DriverCalls.Row], cut: Bool, degraded: Bool = false, app: String = "") {
    commandWindow = BoxFloor.runsAnything(app: app, rows: rows, cut: cut)
    self.pid = pid
    self.window = window
    self.rows = rows
    self.cut = cut
    self.degraded = degraded
    var at: [Int: Int] = [:]
    for (i, row) in rows.enumerated() { if let index = row.index, at[index] == nil { at[index] = i } }
    let up = rows.map { $0.parent.flatMap { at[$0] } }
    var own = rows.map(BoxFloor.mark)
    let chains = rows.indices.map { Self.chain($0, up) }
    let isDocument = { (i: Int) in rows[i].role.lowercased().hasPrefix("document") }
    let page = chains.map { $0.dropFirst().first(where: isDocument) }
    let says = { (k: Int, pattern: String) in rows[k].label.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
    let readOnly = { (k: Int) in BoxFloor.readOnlyRoles.contains(rows[k].role.lowercased()) }
    let article = chains.map { chain in chain.first { ["article", "figure"].contains(rows[$0].role.lowercased()) } }
    let form = chains.map { chain in chain.first { rows[$0].role.lowercased() == "form" } }
    let parents = Set(up.compactMap { $0 })
    let unnamed = { (k: Int) in
      rows[k].label.replacingOccurrences(of: BotCheck.noName, with: "", options: [.regularExpression, .caseInsensitive])
        .range(of: #"[\p{L}\p{N}]"#, options: .regularExpression) == nil
    }
    // The driver lists a parent's frameless rows (the picture, a label) before its element
    // children, so the rows' order is not the page's. Chromium gives a picture no size: a logo, an
    // avatar or a product is known by its name. A block with no name and nothing in it is how
    // Chromium shows a picture with alt="" or a CSS one.
    for a in rows.indices where page[a] != nil {
      let role = rows[a].role.lowercased()
      if ["image", "canvas"].contains(role) && (article[a] == nil || rows[a].acts || chains[a].contains { BoxFloor.presses(rows[$0]) }) && says(a, #"\bcaptcha\b"#) { own[a] = .personOnly(.captcha) }
      let picture = ["image", "canvas"].contains(role) && (!says(a, BotCheck.owns) || says(a, #"\bcaptcha\b"#))
      let blank = ["section", "paragraph"].contains(role) && rows[a].frame != nil && !parents.contains(a) && unnamed(a)
      let arithmetic = says(a, BotCheck.sums)
      guard picture || blank || arithmetic else { continue }
      let around = rows.indices[max(0, a - BotCheck.near)..<min(rows.count, a + BotCheck.near + 1)].filter {
        guard page[$0] == page[a] else { return false }
        if let imageForm = form[a], let otherForm = form[$0] { return imageForm == otherForm }
        return article[$0] == article[a]
      }
      let sum = arithmetic && around.contains { $0 != a && says($0, BotCheck.names) }
      guard picture || blank || sum else { continue }
      let fields = around.filter { BoxFloor.takesText(rows[$0]) }
      let answers = fields.filter { unnamed($0) || says($0, BotCheck.answers) }
      let order = { (k: Int) in (k < a ? rows.count : 0) + abs(k - a) }
      guard let field = BoxFloor.takesText(rows[a]) ? a : answers.min(by: { order($0) < order($1) }) ?? fields.first(where: { $0 > a })
      else { continue }
      let span = min(a, field) - BotCheck.redrawReach...max(a, field) + BotCheck.redrawReach
      let redraws = around.filter { span.contains($0) && BoxFloor.presses(rows[$0]) && says($0, BotCheck.redraws) && !says($0, BotCheck.owns) }
      let asked = around.contains { k in
        (k == a || readOnly(k) || BoxFloor.takesText(rows[k]) || rows[k].role.lowercased() == "label")
          && (says(k, BotCheck.asks) || says(k, BotCheck.imageWords) || k > a && says(k, BotCheck.over) || k < a && says(k, BotCheck.under))
      }
      let plain = unnamed(a) || says(a, BotCheck.answers + "|" + BotCheck.imageWords + "|" + BotCheck.redraws)
      let linked = chains[a].dropFirst().contains { rows[$0].role.lowercased() == "link" }
      let fieldNotYetThePersons = own[field] == nil
      let bareShape = plain && !linked && answers.contains(field) && fieldNotYetThePersons
      let pictureCheck = says(a, BotCheck.names) || !redraws.isEmpty || bareShape || asked
      guard sum || picture && pictureCheck || blank && asked else { continue }
      let confirms = around.filter { span.contains($0) && form[$0] == form[field] && BoxFloor.presses(rows[$0]) && says($0, BotCheck.confirms) }
      for k in [a, field] + redraws + confirms { own[k] = .personOnly(.captcha) }
    }
    // A click on a label works the control it holds, so a label holding a check's control is the
    // check's (a label with no row: `labelZone`).
    for (j, chain) in chains.enumerated() where own[j] == .personOnly(.captcha) {
      for k in chain.dropFirst() where rows[k].role.lowercased() == "label" { own[k] = .personOnly(.captcha) }
    }
    // A document that is a whole check page (BotCheck.interstitial, PageKit's reading) holds nothing
    // that is not the check's. Its shown text is its own leaves' labels (a heading's or paragraph's
    // label repeats its text's), not a frame's inside it, which PageKit's innerText leaves out too.
    // A short page whose own words ask the person to prove they are one anywhere on it (Amazon's
    // "make sure you're not a robot" over its "Type characters" field) is a check page too; a
    // frame's title inside it is the frame's, and the words of a check's own control or label
    // (under it, or beside it as the driver lists a label's text) are that check's, marked already.
    let control = { (k: Int) in
      let role = rows[k].role.lowercased()
      return own[k] == .personOnly(.captcha) && (role == "label" || BoxFloor.pressRoles.contains(role) || BoxFloor.fieldRoles.contains(role) || BoxFloor.runsOnCheckout.contains(role))
    }
    let words = { (k: Int) in rows[k].label.trimmingCharacters(in: .whitespaces).lowercased() }
    let named = Set(rows.indices.filter(control).map(words))
    let browserPage = app == "Chromium" && !cut && !degraded && rows.indices.contains(where: isDocument)
    var priced = rows.indices.contains { i in
      let tabMemory = browserPage && rows[i].onlyTabMemoryAmount && page[i] == nil
        && up[i].map { rows[$0].role == "page tab list" } == true
      return (rows[i].hasPrice && !tabMemory) || says(i, BoxFloor.resubmits)
    }
    for d in rows.indices where isDocument(d) {
      let inside = rows.indices.filter { chains[$0].dropFirst().first(where: isDocument) == d }
      let leaves = inside.filter { !parents.contains($0) }
      let text = leaves.map { rows[$0].label }.joined(separator: "\n")
      let namedLeaves = leaves.filter { !rows[$0].label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      priced = priced || zip(namedLeaves, namedLeaves.dropFirst()).contains { first, second in
        ApprovalGate.pricedAcrossRows(rows[first].label, rows[second].label)
      }
      let asks = inside.contains {
        BoxFloor.readOnlyRoles.contains(rows[$0].role.lowercased()) && !BoxFloor.titled(rows[$0])
          && !chains[$0].dropFirst().contains(where: control) && !named.contains(words($0))
          && rows[$0].label.range(of: BotCheck.asks, options: [.regularExpression, .caseInsensitive]) != nil
      }
      if text.count < BotCheck.shortPage && (asks || BotCheck.interstitial(title: rows[d].label, text: text)) { own[d] = .personOnly(.captcha) }
    }
    let captchas: [Int?] = chains.map { $0.last { own[$0] == .personOnly(.captcha) } }
    self.up = up
    places = chains.map { $0.lazy.compactMap { rows[$0].frame }.first }
    levels = rows.indices.map { i in
      chains[i].last(where: isDocument).map { rows[i].depth - rows[$0].depth } ?? rows[i].depth
    }
    self.captchas = captchas
    let marks: [BoxFloor.Mark?] = rows.indices.map { captchas[$0] != nil ? .personOnly(.captcha) : own[$0] }
    self.marks = marks
    pays = priced || marks.contains { $0 == .pay || $0 == .personOnly(.payment) }
  }

  /// Row i and its ancestors, nearest first.
  static func chain(_ i: Int, _ up: [Int?]) -> [Int] {
    var out: [Int] = [], next: Int? = i
    while let j = next, out.count < 64 {
      out.append(j)
      next = up[j]
    }
    return out
  }
  /// The window shows a press that pays, card details, a price (ApprovalGate's page-price rule, on
  /// a row or a page's text) or a browser's offer to send a form again (`BoxFloor.resubmits`).
  public let pays: Bool
  /// The window `pays`, or Serein could not read all of it: Return in any field and a press that
  /// submits may pay.
  public var checkout: Bool { cut || pays }
  /// Where a picture of this window may show the person's values: every field that takes a secret
  /// (BoxFloor.secret: password, code and card fields, whoever typed in them), every row whose
  /// words held what Serein redacts (DriverCalls.row: a value it filled, a card number), and while
  /// `values` (Serein filled one, or owes a clipboard clear) every field, since Cua Driver gives no
  /// text of a field with a label of its own. nil when one of them has no place, or when `values`
  /// holds and the read is cut or has no tree: a value may show where no row says.
  public func secretPlaces(values: Bool) -> [DriverCalls.Row.Frame]? {
    if values && (cut || degraded) { return nil }
    var out: [DriverCalls.Row.Frame] = []
    for (i, row) in rows.enumerated()
    where BoxFloor.takesText(row) && (values || BoxFloor.secret(row)) || row.label.contains(AgentPrivacy.replacement) {
      guard let place = places[i] else { return nil }
      out.append(place)
    }
    return out
  }
  /// The rows of `there` (`under`) a pointer lands on itself: each with a frame of its own and no
  /// row with one inside it there, and each with no place at all (it may be anywhere). The rest
  /// hold them.
  func innermost(_ there: [Int]) -> Set<Int> {
    let framed = there.filter { rows[$0].frame != nil }
    let holders = Set(framed.flatMap { Self.chain($0, up).dropFirst() })
    return Set(framed.filter { !holders.contains($0) } + there.filter { places[$0] == nil })
  }
  /// The row a target names in this read, or nil when it is gone or changed.
  public func find(_ target: BoxTarget) -> Int? {
    let same = rows.indices.filter {
      levels[$0] <= target.depth && rows[$0].role == target.row.role && rows[$0].label == target.row.label
    }
    return target.nth < same.count ? same[target.nth] : nil
  }
  /// Row i as a target with no depth ceiling.
  public func target(_ i: Int) -> BoxTarget {
    let nth = rows[..<i].filter { $0.role == rows[i].role && $0.label == rows[i].label }.count
    return BoxTarget(pid: pid, window: window, row: rows[i], nth: nth, depth: .max)
  }
  /// A CAPTCHA's identity across reads: its window, role, label and place (`target`), never a
  /// page title, which a script may change (a document's own label is its title, so a whole check
  /// page is known by role and place). One the person had opens no new ask (StepGuard.hadChecks)
  /// while uncut reads still show it; an uncut read without it forgets it, so a later one asks.
  public func checkID(_ i: Int) -> String {
    let t = target(i), label = t.row.role.lowercased().hasPrefix("document") ? "" : t.row.label
    return "\(window)\u{0}\(t.row.role)\u{0}\(label)\u{0}\(t.nth)"
  }
  /// Every CAPTCHA the read shows, each by its outermost row.
  public var botChecks: Set<String> { Set(captchas.compactMap { $0 }.map(checkID)) }
  /// Every row whose place (`places`) touches the 3 by 3 pixels around a desktop point (the
  /// driver rounds a centre its own way), and every press or row of the person's with no place:
  /// where it is is unknown, so it counts at every point. A check's box counts on its `labelZone`.
  public func under(_ x: Int, _ y: Int) -> [Int] {
    let touches = { (f: DriverCalls.Row.Frame) in f.x <= x + 1 && x - 1 < f.x + f.width && f.y <= y + 1 && y - 1 < f.y + f.height }
    return rows.indices.filter { i in
      places[i].map(touches) ?? (marks[i] != nil || BoxFloor.presses(rows[i])) || labelZone(i).map(touches) == true
    }
  }
  /// Where a click may work a check's box or radio button through its label. Chromium gives a label
  /// no place, and no row at all when its text names its box (live), so that text is on the box's
  /// parent's pixels: that whole row, or the box's line across it when it is a page or a window.
  func labelZone(_ i: Int) -> DriverCalls.Row.Frame? {
    let role = rows[i].role.lowercased()
    guard marks[i] == .personOnly(.captcha), ["check box", "radio button"].contains(role), let box = rows[i].frame,
      let p = up[i], let place = places[p] else { return nil }
    let parent = rows[p].role.lowercased()
    guard parent.hasPrefix("document") || ["frame", "internal frame", "window"].contains(parent) else { return place }
    return DriverCalls.Row.Frame(x: place.x, y: box.y - box.height, width: place.width, height: 3 * box.height)
  }
}

/// The model's latest tree (DriverScreen's `tree`): each row of each window down to the asked
/// depth, the ones the driver can act on with a ref. Only for the model to name a target; the floor
/// never judges on it. One owner, the screen; a new read replaces the whole table. Every word in it
/// came from inside the computer.
public struct ElementTable: Sendable {
  public struct Element: Equatable, Sendable {
    public let ref: ElementRef
    public let target: BoxTarget
  }

  public let read: Int
  public let elements: [ElementRef: Element]
  public let text: String
  public let cut: Bool
  public static let empty = ElementTable(read: 0, depth: 0, windows: [])

  /// Numbers every addressed row of every window down to `depth`, in order, and writes the text
  /// the model reads: a line per window, then its rows indented by depth as
  /// `[ref] role 'label' x,y wxh`, with `(yours: …)` on what is the person's; cut at the helper's
  /// limits. Rows on the screen come first and the rest after, under the window's line again, so
  /// a cut keeps the ref of everything a click can reach.
  public init(read: Int, depth: Int, windows: [(window: DriverCalls.Window, read: FreshRead)], hiddenNumberLabels: Set<String> = []) {
    func display(_ text: String) -> String {
      hiddenNumberLabels.contains(text) ? AgentPrivacy.hidingDigits(text) : text
    }
    self.read = read
    var elements: [ElementRef: Element] = [:]
    var shown: [String] = [], hidden: [String] = []
    var number = 0
    for (window, fresh) in windows {
      let head = "window " + DriverCalls.quoted(display(window.title)) + " (" + display(window.app) + ")"
      var off: [String] = []
      shown.append(head)
      var seen: [String: Int] = [:]
      for (i, row) in fresh.rows.enumerated() where fresh.levels[i] <= depth {
        let key = row.role + "\u{0}" + row.label
        let nth = seen[key, default: 0]
        seen[key] = nth + 1
        var ref: ElementRef?
        if row.token != nil {
          let made = ElementRef(read: read, number: number)
          elements[made] = Element(ref: made, target: BoxTarget(pid: fresh.pid, window: fresh.window, row: row, nth: nth, depth: depth))
          number += 1
          ref = made
        }
        let box = row.frame.map { " \($0.x),\($0.y) \($0.width)x\($0.height)" } ?? ""
        let named = ref.map { "[\($0)] " } ?? ""
        let yours = (row.filled ? " filled" : "") + (fresh.marks[i].map { " (yours: \($0.word))" } ?? "")
        let line = String(repeating: "  ", count: row.depth + 1) + named + display(row.role) + " " + DriverCalls.quoted(String(display(row.label).prefix(80))) + box + yours
        if row.frame.map({ BoxFloor.onScreen($0, window.bounds) }) ?? true { shown.append(line) } else { off.append(line) }
      }
      if !off.isEmpty { hidden += [head + ", off the screen"] + off }
    }
    let lines = shown + hidden
    var cut = windows.contains { $0.read.cut && !BoxFloor.bare($0.window, $0.read) } || lines.count > DriverCalls.treeRows
    self.elements = elements
    let head = "read \(read) of Serein's computer. Act on an element by its ref (element: \"e\(read).N\"); refs work until your next computer_tree."
    var body = ([head] + lines.prefix(DriverCalls.treeRows)).joined(separator: "\n")
    if body.count > ComputerPolicy.outputLimit {
      body = String(body.prefix(ComputerPolicy.outputLimit))
      cut = true
    }
    text = body
    self.cut = cut
  }

  /// The element a ref names, or why there is none.
  public func resolve(_ ref: ElementRef) -> Result<Element, ElementMiss> {
    guard read > 0 else { return .failure(.noRead) }
    guard ref.read == read else { return .failure(.olderRead) }
    return elements[ref].map { .success($0) } ?? .failure(.unknown)
  }
}

/// The code floor for a step inside Serein's computer, where ApprovalDoor is not asked (the box
/// boundary is the control): what Boundary already names, in the same words and the same
/// person-only reading as the web and the Mac (ComputerHold.personOnly, SecureCard.fieldKinds).
/// A password, code or card field takes a secure card that Serein fills; a CAPTCHA, a passkey or
/// a press that pays is the person's own, asked of them on the computer itself.
public enum BoxFloor {
  public enum Mark: Equatable, Sendable {
    case personOnly(ComputerHold.PersonOnly)
    case pay
    /// The word in the tree's `(yours: …)`.
    public var word: String {
      switch self {
      case .personOnly(let only): return only.rawValue
      case .pay: return "pay"
      }
    }
  }
  public enum Stop: Equatable, Sendable {
    /// A single-field secret or card details: Serein raises a secure card for this element.
    case secureCard(SecureCard.Kind, SecureCard.Part)
    /// A CAPTCHA, a passkey or a press that pays: Serein asks the person to take control.
    case askPerson(Mark)
    /// Serein does not take the step; the words say why and the way on.
    case refused(String)
  }
  /// What a task brings to a judgment: the CAPTCHAs the person already had there
  /// (StepGuard.hadChecks), and whether Serein filled a person's value in it (FilledValues),
  /// after which nothing is pasted: what was copied may be that value.
  public struct Facts: Sendable {
    public let had: Set<String>
    public let filled: Bool
    public init(had: Set<String> = [], filled: Bool = false) {
      self.had = had
      self.filled = filled
    }
  }

  /// Rows the person types into (AT-SPI role names, as Cua Driver gives them, matched whole).
  public static func runsAnything(app: String, rows: [DriverCalls.Row], cut: Bool) -> Bool {
    let app = app.lowercased(), roles = rows.map { $0.role.lowercased() }
    if ["exo-desktop-item-edit", "xfce4-settings-editor", "xfce4-mime-helper"].contains(app) { return true }
    if app == "xfce4-terminal" {
      return !roles.contains("terminal") && (cut || !roles.allSatisfy { $0.contains("menu") || $0 == "separator" })
    }
    if app == "xfce4-panel" { return !roles.contains("page tab") && (cut || roles.contains("radio button")) }
    guard ["xfce4-keyboard-settings", "xfce4-session-settings", "xfce4-mime-settings"].contains(app), !roles.contains("page tab")
    else { return false }
    return cut || !roles.contains("table cell") && roles.contains { commandFieldRoles.contains($0) }
  }
  static let commandFieldRoles: Set = ["text", "entry", "check box", "radio button", "combo box", "spin button"]

  static let fieldRoles: Set = ["text", "entry", "password text", "combo box", "spin button", "editbar", "terminal"]
  /// Rows a press on can pay.
  static let pressRoles: Set = ["push button", "button", "link", "menu item", "check menu item", "radio menu item", "toggle button"]
  /// The rows a click on runs in a window that may pay (`FreshRead.checkout`): text fields, check
  /// boxes, radio buttons, page tabs in a page tab list, scroll bars and sliders, none of which commits a total. Every
  /// other row asks pay there, as every click on a priced page does on the web, but a press whose
  /// whole label commits nothing (ApprovalGate.commitsNothing) and words or a picture on one of
  /// these (`runs`).
  static let runsOnCheckout: Set = [
    "text", "entry", "password text", "spin button", "editbar", "terminal", "check box", "radio button", "page tab", "scroll bar", "slider",
  ]
  /// Rows that hold a choice. Choosing in one is the web's select, which a priced page rates pay:
  /// in a window that may pay, any step that may change it asks.
  static let choiceRoles: Set = ["combo box", "list box", "slider"]
  /// Rows that are words or a picture on the row that holds them: a click on one works its holder.
  static let textRoles: Set = ["label", "static", "static text", "icon", "image"]
  /// Rows named for a window's or a page's title, which are no control's words.
  static func titled(_ row: DriverCalls.Row) -> Bool {
    let role = row.role.lowercased()
    return role.hasPrefix("document") || ["frame", "internal frame", "window", "application"].contains(role)
  }

  /// What of this row itself is the person's (FreshRead adds what sits inside a CAPTCHA).
  public static func mark(_ row: DriverCalls.Row) -> Mark? {
    if let only = personOnly(fieldRoles.contains(row.role.lowercased()) ? "type" : "click", row) {
      return .personOnly(only)
    }
    return pays(row) ? .pay : nil
  }
  /// ComputerHold's reading, with a CAPTCHA anywhere but on a row nobody acts on: a "protected
  /// by reCAPTCHA" text badge asks nobody; its checkbox, field, image grid's buttons, frame or
  /// label (a click on a label works its control) do. A window's frame or a page's document is
  /// named for its title, so its own label marks nothing (FreshRead reads a whole check page).
  static func personOnly(_ kind: String, _ row: DriverCalls.Row) -> ComputerHold.PersonOnly? {
    let only = ComputerHold.personOnly(kind: kind, role: row.role, label: row.label)
    return only == .captcha && readOnlyRoles.contains(row.role.lowercased()) ? nil : only
  }
  static let readOnlyRoles: Set = [
    "static", "static text", "heading", "paragraph", "image", "caption", "frame", "document web", "document frame", "document",
  ]
  /// A press whose label pays (`paysOwn`): it marks its window as one that may pay.
  static func pays(_ row: DriverCalls.Row) -> Bool { presses(row) && paysOwn(row) }
  /// A label that pays as ApprovalGate reads a target's own for the web and the Mac: a pay word
  /// (`labelRaises`) or a price.
  static func paysOwn(_ row: DriverCalls.Row) -> Bool { ApprovalGate.raisedEffect(in: row.label) == .pay || row.hasPrice }

  /// Why a step (click, type, set_value, scroll) on this row stops, or nil to run: what of it is
  /// the person's, and a click on a row whose own label pays, whatever its role. A scroll changes
  /// nothing the person owns, so it always runs.
  public static func check(step: String, on row: DriverCalls.Row) -> Stop? {
    guard step != "scroll" else { return nil }
    if let only = personOnly(step == "click" ? "click" : "type", row) { return stop(only, row) }
    return step == "click" && paysOwn(row) ? .askPerson(.pay) : nil
  }
  static func stop(_ only: ComputerHold.PersonOnly, _ row: DriverCalls.Row) -> Stop {
    if case .card(let secure)? = SecureCard.fieldKinds[only.rawValue] {
      return .secureCard(secure, secure == .card ? SecureCard.macPart(label: row.label) : .number)
    }
    return .askPerson(.personOnly(only))
  }

  /// A password, code or card field: what is typed there is the person's.
  public static func secret(_ row: DriverCalls.Row) -> Bool {
    if case .secureCard? = check(step: "type", on: row) { return true }
    return false
  }
  /// A screen step as the floor judges it, on one row of a fresh read.
  public enum Act: Sendable {
    case click, scroll
    case type(String), setValue(String)
    case key(DriverCalls.KeyPress)
  }
  /// A step the floor stopped: why, the element it was aimed at, and the CAPTCHA it sits in.
  public struct Stopped: Sendable {
    public let stop: Stop
    public let target: BoxTarget
    public let check: String?
  }
  /// What a key press does to the element it lands on: Return (and ctrl+m, ctrl+j) and an alt
  /// letter press it, space presses or types, and a character or a paste types; nil for a key that
  /// only moves (Tab, arrows, Escape, PageUp, F5) or a shortcut (ctrl+l, super+e).
  public enum Reach: Sendable { case enter, space, text }
  static let typedNames: Set = [
    "minus", "plus", "equal", "period", "comma", "slash", "backslash", "semicolon", "colon", "underscore", "asterisk", "parenleft", "parenright",
  ]
  /// A key that opens a menu no answer reports: F10 with or without shift (the menu bar, the
  /// context menu) and an alt letter (a menu's mnemonic). The Menu key is none Serein sends
  /// (DriverCalls.keyPresses refuses it).
  public static func opensMenu(_ press: DriverCalls.KeyPress) -> Bool {
    press.key.lowercased() == "f10" || press.modifiers.contains("alt") && press.key.count == 1
  }
  public static func reach(_ press: DriverCalls.KeyPress) -> Reach? {
    let held = Set(press.modifiers), key = press.key.lowercased()
    if key == "return" { return .enter }
    if key == "space" { return .space }
    if key == "insert" { return held.contains("shift") ? .text : nil }
    guard key.count == 1 || typedNames.contains(key), !held.contains("super") else { return nil }
    if held.contains("ctrl") && !held.contains("alt") { return ["m", "j"].contains(key) ? .enter : key == "v" ? .text : nil }
    return held.contains("alt") && !held.contains("ctrl") ? .enter : .text
  }
  /// Keys that move inside the element the focus is on: in a list, a select, a slider or a radio
  /// group they change the choice, and in a check they may work it.
  public static let movesInside: Set = ["up", "down", "left", "right", "home", "end", "pageup", "pagedown", "backspace", "delete"]
  /// F5 or ctrl+r, with any other modifiers: a reload, which may send a form again (an order).
  public static func reloads(_ press: DriverCalls.KeyPress) -> Bool {
    let key = press.key.lowercased()
    return key == "f5" || key == "r" && press.modifiers.contains("ctrl")
  }
  /// Keys with no element the floor judges on every window's read (`judge(bare:)`).
  public static func judgedBare(_ press: DriverCalls.KeyPress) -> Bool { movesInside.contains(press.key.lowercased()) || reloads(press) }
  /// A browser's offer to send a form again (Chromium's dialog and page, Firefox's): its Continue,
  /// and a reload under it, may place the order once more.
  static let resubmits = "confirm form resubmission|repeat any action"
  /// Why a step on row i of a fresh read stops, or nil to run. A CAPTCHA, or anything inside
  /// one, is never Serein's to touch (`botCheck`). A scroll changes nothing the person owns. Any
  /// other step the row receives that may act on it is a press (`press`); a field's typing is the
  /// person's when the field is (`check`), and a choice changed in a window that may pay asks pay,
  /// as a select on a priced page does on the web (ApprovalGate.rate).
  public static func judge(_ act: Act, at i: Int, in read: FreshRead, _ facts: Facts = Facts()) -> Stopped? {
    if read.commandWindow { return Stopped(stop: .refused("Only the person can operate a window that configures shell commands."), target: read.target(i), check: nil) }
    if case .scroll = act { return nil }
    if let stopped = botCheck(i, read, facts) { return stopped }
    let row = read.rows[i], role = row.role.lowercased()
    let choice = choiceRoles.contains(role), text = takesText(row) || choice
    let chooses: Stop? = choice && (read.checkout || paysOwn(row)) ? .askPerson(.pay) : nil
    let typed = { check(step: "type", on: row) }
    let returns = { (words: String) in words.contains { $0.isNewline } ? enter(i, read) : nil }
    var stop: Stop?
    switch act {
    case .scroll: return nil
    case .click: stop = press(i, read)
    case .setValue(let words): stop = choice ? typed() ?? chooses : takesText(row) ? typed() ?? returns(words) : press(i, read)
    case .type(let words): stop = text ? typed() ?? chooses ?? returns(words) : press(i, read)
    case .key(let key):
      switch reach(key) {
      case nil: stop = movesInside.contains(key.key.lowercased()) ? chooses : reloads(key) && read.checkout ? .askPerson(.pay) : nil
      case .enter?: stop = enter(i, read)
      case .space?, .text?: stop = text ? typed() ?? chooses : press(i, read)
      }
    }
    if stop == nil, facts.filled, pastes(act, row) { stop = .refused(noPaste) }
    return stop.map { Stopped(stop: $0, target: read.target(i), check: nil) }
  }
  /// A step on row i, or on a row it sits in, inside a CAPTCHA: the person is asked the first time,
  /// and after they had it the step is refused with the way to ask them again.
  static func botCheck(_ i: Int, _ read: FreshRead, _ facts: Facts) -> Stopped? {
    guard let outer = read.captchas[i] else { return nil }
    let check = read.checkID(outer)
    return facts.had.contains(check)
      ? Stopped(stop: .refused(hadCheck), target: read.target(i), check: nil)
      : Stopped(stop: .askPerson(.personOnly(.captcha)), target: read.target(i), check: check)
  }
  /// A click on row i that reaches row i only through a row inside it (`held`).
  static func judge(holder i: Int, in read: FreshRead, _ facts: Facts) -> Stopped? {
    botCheck(i, read, facts) ?? held(i, read).map { Stopped(stop: $0, target: read.target(i), check: nil) }
  }
  /// A click by the element's own action (no pointer): row i receives it, and what holds it.
  public static func judge(press i: Int, in read: FreshRead, _ facts: Facts = Facts()) -> Stopped? {
    if let stopped = judge(.click, at: i, in: read, facts) { return stopped }
    for j in FreshRead.chain(i, read.up).dropFirst() { if let stopped = judge(holder: j, in: read, facts) { return stopped } }
    return nil
  }
  /// A click landing at a desktop point, on the reads of every window there: the rows there the
  /// pointer lands on itself receive it (FreshRead.innermost), and the rest hold them.
  public static func judge(clickAt x: Int, _ y: Int, in reads: [FreshRead], _ facts: Facts = Facts()) -> Stopped? {
    for read in reads {
      let there = read.under(x, y), inner = read.innermost(there)
      for i in there {
        if let stopped = inner.contains(i) ? judge(.click, at: i, in: read, facts) : judge(holder: i, in: read, facts) { return stopped }
      }
    }
    return nil
  }
  /// Keys sent to no element while Cua Driver reports no keyboard focus, on the reads of every
  /// window (`whole` when they are all of them, uncut): the focus may be on any of them. A reload
  /// (`reloads`) asks pay while a window may pay or Serein could not read one. One that may change
  /// a choice or work a check (`movesInside`) stops while a window shows a check, which is asked of
  /// the person, or may pay, or one Serein could not read.
  public static func judge(bare keys: [DriverCalls.KeyPress], in reads: [FreshRead], whole: Bool, _ facts: Facts = Facts()) -> Stopped? {
    if reads.contains(where: \.commandWindow) { return Stopped(stop: .refused("Only the person can operate a window that configures shell commands."), target: .screen, check: nil) }
    let unsure = !whole || reads.contains(where: \.checkout)
    if unsure, keys.contains(where: reloads) { return Stopped(stop: .askPerson(.pay), target: .screen, check: nil) }
    guard keys.contains(where: { movesInside.contains($0.key.lowercased()) }) else { return nil }
    for read in reads {
      if let i = read.captchas.firstIndex(where: { $0 != nil }) { return botCheck(i, read, facts) }
    }
    return unsure ? Stopped(stop: .refused(bareMoves), target: .screen, check: nil) : nil
  }
  /// Where Cua Driver's foreground click on row i lands. It presses a real pointer at the frame's
  /// centre (its answer's `screen_point`); an element with no frame on the screen it presses by
  /// its AT-SPI action, with no pointer (`none`). `hidden` when the centre is off the window or the
  /// screen while some of the frame is on it: the pointer would land on something else.
  public enum Landing: Equatable, Sendable {
    case at(x: Int, y: Int)
    case none
    case hidden
  }
  public static func landing(of i: Int, in read: FreshRead, window: DriverCalls.Row.Frame?) -> Landing {
    guard let frame = read.rows[i].frame, onScreen(frame, nil) else { return .none }
    let x = frame.x + frame.width / 2, y = frame.y + frame.height / 2
    return frame.holds(x, y) && (window ?? screen).holds(x, y) && screen.holds(x, y) ? .at(x: x, y: y) : .hidden
  }
  public static let screen = DriverCalls.Row.Frame(x: 0, y: 0, width: ComputerPolicy.screenWidth, height: ComputerPolicy.screenHeight)
  /// Whether any of a frame is on the screen, and inside its window when the window's place is known.
  public static func onScreen(_ frame: DriverCalls.Row.Frame, _ window: DriverCalls.Row.Frame?) -> Bool {
    [screen, window ?? screen].allSatisfy {
      frame.x < $0.x + $0.width && $0.x < frame.x + frame.width && frame.y < $0.y + $0.height && $0.y < frame.y + frame.height
    }
  }
  /// The box's own desktop, and its panel's windows that have no tree but the window itself (the
  /// hidden dock's strip): what a point on one holds is the windows over it.
  public static func bare(_ window: DriverCalls.Window, _ read: FreshRead) -> Bool {
    read.degraded && read.rows.allSatisfy { $0.token == nil || $0.role.lowercased() == "window" }
      && (window.app == "Xfdesktop" && window.bounds == screen || window.app == "Xfce4-panel")
  }
  /// A paste: a press on a Paste item, or a key that pastes (`pastes(_:)`).
  static func pastes(_ act: Act, _ row: DriverCalls.Row) -> Bool {
    switch act {
    case .key(let press): return pastes(press)
    case .click: return presses(row) && row.label.range(of: "\\bpaste\\b", options: [.regularExpression, .caseInsensitive]) != nil
    default: return false
    }
  }
  /// ctrl+v or super+v with any other modifiers (ctrl+shift+v, ctrl+alt+v), or shift+Insert.
  public static func pastes(_ press: DriverCalls.KeyPress) -> Bool {
    let held = Set(press.modifiers), key = press.key.lowercased()
    return key == "v" && (held.contains("ctrl") || held.contains("super")) || key == "insert" && held.contains("shift")
  }
  /// How the driver delivers a step on a row so that it reaches that row: Return or space on a
  /// press or a check box is a click on it (by its own action when it has one). Every other key
  /// and all typing go by element: the driver moves the keyboard focus onto the row first and
  /// sends nothing when it cannot (DriverScreen.noFocus).
  public static func delivered(_ act: Act, on row: DriverCalls.Row) -> Act {
    guard case .key(let key) = act, let reach = reach(key), reach != .text, !takesText(row) else { return act }
    return presses(row) || row.role.lowercased() == "check box" ? .click : act
  }
  public static func takesText(_ row: DriverCalls.Row) -> Bool { fieldRoles.contains(row.role.lowercased()) }
  public static let hadCheck =
    "That is a check that a person is there. The person had it already, and Serein never clicks or types in one itself. If it needs the person again, call computer_ask_person; otherwise carry on with the rest of the page."
  public static let bareMoves =
    "Cua Driver reports no keyboard focus, and a check that a person is there or a window that may pay is on the screen, where an arrow, Home, End, PageUp, PageDown, Backspace or Delete may change a choice or work the check. Send the key to one element instead (computer_key with element, a ref from computer_tree), or move the page with computer_scroll."
  public static let noPaste =
    "Serein filled the person's own value in this task (or in an earlier one, and could not clear the clipboard since), so it pastes nothing here: what was copied may be that value. Type the text with computer_type and element instead."
  static func presses(_ row: DriverCalls.Row) -> Bool { pressRoles.contains(row.role.lowercased()) }
  /// A click, or any other step that may act, that row i receives: what of it is the person's, a
  /// row whose own label pays, and in a window that may pay (`FreshRead.checkout`, ApprovalGate.rate's
  /// page-price rule) every row but the ones that run there (`runs`), as every click on such a page
  /// asks on the web. A page's own script may pay on any row, so no other role is let run.
  static func press(_ i: Int, _ read: FreshRead) -> Stop? {
    check(step: "click", on: read.rows[i]) ?? (read.checkout && !runs(i, read) ? .askPerson(.pay) : nil)
  }
  /// Row i runs in a window that may pay: its role is one of `runsOnCheckout` (a page tab only in a
  /// page tab list, as a tab widget's tabs are), it is a press whose whole label only moves about
  /// the page or edits it (ApprovalGate.commitsNothing) or the browser's own Forward or New Tab
  /// outside any page, or it is words or a picture on such a row.
  static func runs(_ i: Int, _ read: FreshRead) -> Bool {
    let role = { (j: Int) in read.rows[j].role.lowercased() }
    let browses = { (j: Int) in
      ["forward", "new tab"].contains(read.rows[j].label.lowercased()) && !FreshRead.chain(j, read.up).contains { role($0).hasPrefix("document") }
    }
    let free = { (j: Int) in
      role(j) == "page tab" ? read.up[j].map { role($0) == "page tab list" } == true
        : runsOnCheckout.contains(role(j)) || presses(read.rows[j]) && (ApprovalGate.commitsNothing(read.rows[j].label) || browses(j))
    }
    return free(i) || textRoles.contains(role(i)) && read.up[i].map(free) == true
  }
  /// A row a click reaches through a row inside it: what of it is the person's, and a press
  /// (`press`'s rule for presses) when the window may pay.
  static func held(_ i: Int, _ read: FreshRead) -> Stop? {
    let row = read.rows[i]
    if let only = personOnly("click", row) { return stop(only, row) }
    if pays(row) { return .askPerson(.pay) }
    return read.checkout && presses(row) && !ApprovalGate.commitsNothing(row.label) ? .askPerson(.pay) : nil
  }
  /// Return on row i: on anything but a field a press, and in card details or a window that pays
  /// a submit.
  static func enter(_ i: Int, _ read: FreshRead) -> Stop? {
    let row = read.rows[i]
    if !takesText(row) { return press(i, read) }
    if case .secureCard(.card, _)? = check(step: "type", on: row) { return .askPerson(.pay) }
    return read.checkout ? .askPerson(.pay) : nil
  }

  /// The step's answer when the person is asked to take control: Serein's fixed words.
  public static func asked(_ mark: Mark) -> Blocked {
    switch mark {
    case .pay:
      return Blocked(
        "this step may pay. Serein asked the person to take control of its computer and take it themselves",
        routes: .init("carry on with the parts that need no payment"))
    case .personOnly(let only):
      let what = only == .captcha ? "this screen checks that a person is there"
        : only == .passkey ? "this step needs the person's passkey or security key" : "this field takes the person's own details"
      return Blocked(
        what + ". Serein asked the person to take control of its computer",
        routes: .init("carry on with every other part", "reach the same result another way"),
        after: "Computer steps wait until Serein says they handed it back.")
    }
  }
}
