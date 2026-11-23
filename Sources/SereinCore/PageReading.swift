import Foundation

/// Ceilings for the live page reader. Tests advance `Clock` and do not sleep.
public enum ReaderLimits {
  public static let loadSeconds: Double = 5
  public static let totalSeconds: Double = 60

  public struct Clock: Sendable {
    public var now: @Sendable () -> Double
    public init(now: @escaping @Sendable () -> Double) { self.now = now }
    public func exceeded(since start: Double, limit: Double) -> Bool { now() - start >= limit }
    public func loadExceeded(since start: Double) -> Bool { exceeded(since: start, limit: ReaderLimits.loadSeconds) }
    public func totalExceeded(since start: Double) -> Bool { exceeded(since: start, limit: ReaderLimits.totalSeconds) }
  }
}

/// What a page reading contains. JavaScript returns these facts. Swift decides the effect.
/// A card field, including one inside a frame, is a fact here, not a payment decision.
public struct PageSnapshot: Equatable, Sendable {
  public struct Field: Equatable, Sendable {
    public var name: String
    public var id: String
    public var type: String
    public var autocomplete: String
    public var label: String
  }
  public struct Frame: Equatable, Sendable {
    public var src: String
    public var title: String
    public var name: String
    public var id: String
  }
  /// False when this action was not read from a page. Mac steps stay on that path.
  public var present: Bool
  public var connected: Bool
  public var bind: String
  public var label: String
  public var tag: String
  public var type: String
  public var role: String
  public var nearbyText: String
  public var pageText: String
  public var frames: [Frame]
  public var fields: [Field]
  public var submits: Bool
  public var secret: Bool
  public var formBlob: String
  /// PageKit's kind for a control in a cookie, consent, survey or newsletter overlay: "private",
  /// "neutral" or "accept"; empty outside one. `ApprovalGate.rate` can raise on it, and lower
  /// nothing on it unless the control's own words are private too.
  public var consent: String = ""
  /// Identity of the submitted form when it contains a password field.
  public var passwordForm: String = ""
  /// The control takes typed text as a person edits it (`isContentEditable`, inherited).
  public var editable: Bool = false

  public static let absent = PageSnapshot(
    present: false, connected: false, bind: "", label: "", tag: "", type: "", role: "",
    nearbyText: "", pageText: "", frames: [], fields: [], submits: false, secret: false, formBlob: "")
}

/// Reads an HTML document the way the live page reader reports a control.
/// The target is the element marked `data-serein-target`. Payment is not decided here.
public enum PageReading {
  public static func describe(html: String) -> PageSnapshot {
    let root = parse(html)
    guard let target = find(root, where: { $0.attrs["data-serein-target"] != nil }) else {
      var missing = PageSnapshot.absent
      missing.present = true
      return missing
    }
    var fields: [PageSnapshot.Field] = []
    var frames: [PageSnapshot.Frame] = []
    collect(root, fields: &fields, frames: &frames)
    func owner(_ node: Node) -> Node? {
      if let id = node.attrs["form"] {
        return find(root, where: { $0.name == "form" && $0.attrs["id"] == id })
      }
      return ancestor(node, named: "form")
    }
    let form = owner(target)
    let submits = form != nil && submitsForm(target)
    let passwordForm = submits && find(root, where: {
      $0.name == "input" && isSecret($0) && owner($0) === form
    }) != nil
    return PageSnapshot(
      present: true, connected: true, bind: "fixture", label: labelOf(target), tag: target.name,
      type: (target.attrs["type"] ?? "").lowercased(), role: (target.attrs["role"] ?? "").lowercased(),
      nearbyText: nearbyText(target), pageText: String(collapse(textOf(root)).prefix(8000)),
      frames: frames, fields: fields, submits: submits, secret: isSecret(target),
      formBlob: form.map(formBlob) ?? "",
      passwordForm: passwordForm ? "form" : "", editable: isEditable(target))
  }

  /// A frame this document did not describe. The pre-press re-rate merges these in
  /// so a card or a payment frame beside the action still counts.
  public static func frameHint(src: String, title: String = "", name: String = "", id: String = "") -> PageSnapshot {
    var snap = PageSnapshot.absent
    snap.present = true
    snap.connected = true
    snap.frames = [PageSnapshot.Frame(src: src, title: title, name: name, id: id)]
    return snap
  }

  /// The action frame plus every sibling reading. Fields and frames accumulate.
  /// Words in the siblings are appended. They can only add a card, a price or a payment frame.
  public static func withSiblings(_ primary: PageSnapshot, siblings: [PageSnapshot]) -> PageSnapshot {
    var copy = primary
    copy.present = primary.present || siblings.contains { $0.present }
    var fields = primary.fields
    var frames = primary.frames
    var page = primary.pageText
    var nearby = primary.nearbyText
    for sibling in siblings where sibling.present {
      for field in sibling.fields where !fields.contains(field) { fields.append(field) }
      for frame in sibling.frames where !frames.contains(frame) { frames.append(frame) }
      if !sibling.pageText.isEmpty { page += "\n" + sibling.pageText }
      if !sibling.nearbyText.isEmpty { nearby += "\n" + sibling.nearbyText }
      if sibling.secret { copy.secret = true }
    }
    copy.fields = fields
    copy.frames = frames
    copy.pageText = String(page.prefix(8000))
    copy.nearbyText = String(nearby.prefix(1200))
    return copy
  }

  /// The script `elementFacts` runs in each other frame. It reuses `read` and `describe`.
  public static let siblingScan = """
  (() => {
    const read = globalThis.__serein && globalThis.__serein.read ? globalThis.__serein.read(0) : null;
    const rows = read && read.elements || [];
    // A secure field's row is listed for secure_card only; its frame's fields still count below.
    const row = rows.find(r => r && r.ref && !r.secure);
    if (!row || !globalThis.__serein.describe) {
      return {connected:true, bind:'', label:'', tag:'', type:'', role:'', nearbyText:'', pageText:'', frames:[], fields:[], submits:false, secret:false, formBlob:''};
    }
    return globalThis.__serein.describe(row.ref, 'read', {});
  })()
  """

  /// The same shape `describe` returns from a live `__serein.describe` payload.
  public static func snapshot(_ raw: [String: Any]) -> PageSnapshot {
    if flag(raw["connected"]) == false {
      var gone = PageSnapshot.absent
      gone.present = true
      return gone
    }
    func text(_ dict: [String: Any], _ key: String) -> String { dict[key] as? String ?? "" }
    let frames = dicts(raw["frames"]).map {
      PageSnapshot.Frame(src: text($0, "src"), title: text($0, "title"), name: text($0, "name"), id: text($0, "id"))
    }
    let fields = dicts(raw["fields"]).map {
      PageSnapshot.Field(
        name: text($0, "name"), id: text($0, "id"), type: text($0, "type"),
        autocomplete: text($0, "autocomplete"), label: text($0, "label"))
    }
    return PageSnapshot(
      present: true, connected: flag(raw["connected"]) ?? true, bind: text(raw, "bind"),
      label: text(raw, "label"), tag: text(raw, "tag"), type: text(raw, "type"), role: text(raw, "role"),
      nearbyText: text(raw, "nearbyText"), pageText: text(raw, "pageText"), frames: frames, fields: fields,
      submits: flag(raw["submits"]) ?? false, secret: flag(raw["secret"]) ?? false,
      formBlob: text(raw, "formBlob"), consent: text(raw, "consent"), passwordForm: text(raw, "passwordForm"), editable: flag(raw["editable"]) ?? false)
  }

  private static func flag(_ value: Any?) -> Bool? {
    if let flag = value as? Bool { return flag }
    if let number = value as? NSNumber { return number.boolValue }
    return nil
  }

  private static func dicts(_ value: Any?) -> [[String: Any]] {
    let rows: [Any]
    if let list = value as? [Any] { rows = list }
    else if let list = value as? NSArray { rows = Array(list) }
    else { return [] }
    return rows.compactMap { item in
      if let row = item as? [String: Any] { return row }
      guard let row = item as? NSDictionary else { return nil }
      var out: [String: Any] = [:]
      for (key, value) in row {
        guard let key = key as? String else { continue }
        out[key] = value
      }
      return out
    }
  }

  // MARK: tree

  private final class Node {
    var name: String
    var attrs: [String: String] = [:]
    var children: [Node] = []
    weak var parent: Node?
    var text = ""
    init(_ name: String) { self.name = name }
  }

  private struct Tag {
    var name: String
    var attrs: [String: String]
    var closing: Bool
    var closed: Bool
  }

  private final class Scanner {
    let s: String
    var i: String.Index
    init(_ s: String) { self.s = s; self.i = s.startIndex }
    var done: Bool { i >= s.endIndex }
    func peek() -> Character? { done ? nil : s[i] }
    @discardableResult func pop() -> Character? {
      guard !done else { return nil }
      let c = s[i]
      i = s.index(after: i)
      return c
    }
  }

  private static let voidTags: Set<String> = [
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
  ]

  private static func parse(_ html: String) -> Node {
    let root = Node("#document")
    var stack = [root]
    let scan = Scanner(html)
    while !scan.done {
      let mark = scan.i
      if scan.peek() == "<", let tag = readTag(scan) {
        if tag.closing {
          while stack.count > 1, stack.last?.name != tag.name { stack.removeLast() }
          if stack.count > 1 { stack.removeLast() }
          continue
        }
        let node = Node(tag.name)
        node.attrs = tag.attrs
        node.parent = stack.last
        stack.last?.children.append(node)
        let keepsChildren = !tag.closed && !voidTags.contains(tag.name)
        if keepsChildren { stack.append(node) }
        if tag.name == "script" || tag.name == "style" {
          skipUntilClose(scan, tag.name)
          if stack.last === node { stack.removeLast() }
        }
        continue
      }
      // A comment or doctype advanced the scanner and is not text.
      if scan.i != mark { continue }
      if let c = scan.pop() { stack.last?.text.append(c) }
    }
    return root
  }

  /// nil when the `<` is text. A comment or doctype is consumed and returns nil as well,
  /// after the scanner has moved past it. The caller treats a consumed skip as no text.
  private static func readTag(_ scan: Scanner) -> Tag? {
    guard scan.peek() == "<" else { return nil }
    let mark = scan.i
    scan.pop()
    if scan.peek() == "!" || scan.peek() == "?" {
      if scan.s[scan.i...].hasPrefix("!--") {
        if let range = scan.s.range(of: "-->", range: scan.i..<scan.s.endIndex) {
          scan.i = range.upperBound
        } else {
          scan.i = scan.s.endIndex
        }
      } else {
        while let c = scan.peek(), c != ">" { scan.pop() }
        if scan.peek() == ">" { scan.pop() }
      }
      return nil
    }
    let closing = scan.peek() == "/"
    if closing { scan.pop() }
    guard let first = scan.peek(), first.isLetter else {
      scan.i = mark
      return nil
    }
    var name = ""
    while let c = scan.peek(), c.isLetter || c.isNumber || c == "-" {
      name.append(c)
      scan.pop()
    }
    let attrs = closing ? [:] : readAttributes(scan)
    var selfClosed = false
    if scan.peek() == "/" { selfClosed = true; scan.pop() }
    if scan.peek() == ">" { scan.pop() }
    return Tag(name: name.lowercased(), attrs: attrs, closing: closing, closed: selfClosed)
  }

  private static func readAttributes(_ scan: Scanner) -> [String: String] {
    var attrs: [String: String] = [:]
    while !scan.done {
      while let c = scan.peek(), c.isWhitespace { scan.pop() }
      guard let c = scan.peek(), c != ">", c != "/" else { break }
      var name = ""
      while let c = scan.peek(), c != "=", c != ">", c != "/", !c.isWhitespace {
        name.append(c)
        scan.pop()
      }
      while let c = scan.peek(), c.isWhitespace { scan.pop() }
      var value = ""
      if scan.peek() == "=" {
        scan.pop()
        while let c = scan.peek(), c.isWhitespace { scan.pop() }
        if let quote = scan.peek(), quote == "\"" || quote == "'" {
          scan.pop()
          while let c = scan.peek(), c != quote { value.append(c); scan.pop() }
          if scan.peek() == quote { scan.pop() }
        } else {
          while let c = scan.peek(), !c.isWhitespace, c != ">" { value.append(c); scan.pop() }
        }
      }
      if !name.isEmpty { attrs[name.lowercased()] = HTMLEntities.decode(value) }
    }
    return attrs
  }

  private static func skipUntilClose(_ scan: Scanner, _ name: String) {
    let end = "</" + name
    if let range = scan.s.range(of: end, options: .caseInsensitive, range: scan.i..<scan.s.endIndex) {
      scan.i = range.upperBound
      while let c = scan.peek(), c != ">" { scan.pop() }
      if scan.peek() == ">" { scan.pop() }
    } else {
      scan.i = scan.s.endIndex
    }
  }

  private static func find(_ node: Node, where match: (Node) -> Bool) -> Node? {
    if match(node) { return node }
    for child in node.children {
      if let found = find(child, where: match) { return found }
    }
    return nil
  }

  private static func ancestor(_ node: Node, named name: String) -> Node? {
    var current = node.parent
    while let at = current {
      if at.name == name { return at }
      current = at.parent
    }
    return nil
  }

  private static func collect(_ node: Node, fields: inout [PageSnapshot.Field], frames: inout [PageSnapshot.Frame]) {
    switch node.name {
    case "input", "textarea", "select":
      fields.append(PageSnapshot.Field(
        name: node.attrs["name"] ?? "", id: node.attrs["id"] ?? "",
        type: (node.attrs["type"] ?? node.name).lowercased(),
        autocomplete: node.attrs["autocomplete"] ?? "", label: labelOf(node)))
    case "iframe":
      frames.append(PageSnapshot.Frame(
        src: node.attrs["src"] ?? "", title: node.attrs["title"] ?? "",
        name: node.attrs["name"] ?? "", id: node.attrs["id"] ?? ""))
    default: break
    }
    for child in node.children { collect(child, fields: &fields, frames: &frames) }
  }

  private static func labelOf(_ node: Node) -> String {
    if let aria = node.attrs["aria-label"], !aria.isEmpty { return String(collapse(aria).prefix(160)) }
    let text = collapse(textOf(node))
    if !text.isEmpty { return String(text.prefix(160)) }
    if let value = node.attrs["value"], !value.isEmpty { return String(collapse(value).prefix(160)) }
    return node.attrs["name"] ?? ""
  }

  private static func textOf(_ node: Node) -> String {
    var parts: [String] = []
    func walk(_ n: Node) {
      if !n.text.isEmpty { parts.append(n.text) }
      for child in n.children where child.name != "script" && child.name != "style" { walk(child) }
    }
    walk(node)
    return parts.joined(separator: " ")
  }

  private static func nearbyText(_ target: Node) -> String {
    let boxes: Set<String> = ["form", "section", "article", "li", "dialog", "main"]
    var current = target.parent
    var chosen = target.parent ?? target
    while let at = current {
      if boxes.contains(at.name) || at.attrs["role"]?.lowercased() == "dialog" {
        chosen = at
        break
      }
      guard at.parent != nil else { chosen = at; break }
      current = at.parent
    }
    return String(collapse(textOf(chosen)).prefix(1200))
  }

  private static func submitsForm(_ node: Node) -> Bool {
    let type = (node.attrs["type"] ?? "").lowercased()
    if type == "button" || type == "reset" { return false }
    if node.name == "input", type == "submit" || type == "image" { return true }
    return node.name == "button"
  }

  /// As `isContentEditable`: the nearest `contenteditable` on the node or an ancestor decides.
  private static func isEditable(_ node: Node) -> Bool {
    var current: Node? = node
    while let at = current {
      if let value = at.attrs["contenteditable"]?.lowercased() { return value != "false" }
      current = at.parent
    }
    return false
  }

  private static func isSecret(_ node: Node) -> Bool {
    let type = (node.attrs["type"] ?? "").lowercased()
    let autocomplete = (node.attrs["autocomplete"] ?? "").lowercased()
    return type == "password" || autocomplete.contains("password")
  }

  private static func formBlob(_ form: Node) -> String {
    [form.attrs["action"], form.attrs["id"], form.attrs["name"], form.attrs["class"]]
      .compactMap { $0 }.joined(separator: " ")
  }

  private static func collapse(_ text: String) -> String {
    HTMLEntities.decode(text).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
