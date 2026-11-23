import AppKit
import ApplicationServices
import SereinCore

/// An agent tab's controls from WebKit's accessibility tree, the one VoiceOver reads. It sees what
/// PageKit's HTML scan misses: ARIA tabs, switches and menu items, controls a page hides and draws
/// with a label, and buttons in closed shadow roots, each with its enabled state. A press is
/// AXPress, which the page receives as a person's click (isTrusted). Text, typing, lists and the
/// password, card and code rules stay with PageKit: only click-type controls are added from here,
/// controls inside frames are left to PageKit's frame reads, and secure text fields never appear.
/// Needs Accessibility access for Serein; the web view must be in a window, so an agent tab that is
/// not on screen is hosted in a hidden one.
@MainActor enum PageAX {
  /// On with SEREIN_AX=1 or the serein.accessibilityReader default, and only with Accessibility access.
  static var enabled: Bool {
    (ProcessInfo.processInfo.environment["SEREIN_AX"] == "1"
      || UserDefaults.standard.bool(forKey: "serein.accessibilityReader")) && AXIsProcessTrusted()
  }
  struct Control {
    let ref: String
    let role: String
    let label: String
    let checked: Bool?
    let enabled: Bool
    let typed: Bool
    let center: CGPoint
  }
  private static var hosts: [String: NSWindow] = [:]
  private static var refs: [String: [String: AXUIElement]] = [:]
  private static var generation = 0
  /// Serein answers its own accessibility requests on the main thread, so the first request after
  /// launch, made from the main thread, waited on itself for about 3 s and came back with no tree.
  /// Made from a background thread it takes milliseconds. So the first request (which also asks
  /// WebKit for its trees: AXManualAccessibility) goes off the main thread, and reads wait for it.
  private static var warm = false
  private static var warming = false
  private static func warmUp() {
    guard !warming else { return }
    warming = true
    DispatchQueue.global(qos: .userInitiated).async {
      let app = AXUIElementCreateApplication(getpid())
      AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
      var windows: AnyObject?
      _ = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
      Task { @MainActor in warm = true }
    }
  }

  static func isHost(_ window: NSWindow) -> Bool { hosts.values.contains { $0 === window } }
  static func release(_ tab: BrowserTab) {
    hosts.removeValue(forKey: tab.id)?.close()
    refs[tab.id] = nil
  }
  /// The tab's hidden window; nil when the tab is shown to the user (PageKit alone reads it then).
  private static func host(_ tab: BrowserTab) -> NSWindow? {
    if let shown = tab.web.window { return isHost(shown) ? shown : nil }
    let window = hosts[tab.id] ?? {
      let w = NSWindow(
        contentRect: CGRect(x: -20000, y: -20000, width: 1000, height: 750), styleMask: .borderless,
        backing: .buffered, defer: false)
      w.isReleasedWhenClosed = false
      w.ignoresMouseEvents = true
      w.isExcludedFromWindowsMenu = true
      w.collectionBehavior = [.transient, .ignoresCycle]
      w.title = "serein-agent-" + tab.id
      w.setAccessibilityIdentifier(w.title)
      w.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 750))
      return w
    }()
    hosts[tab.id] = window
    tab.web.frame = window.contentView!.bounds
    window.contentView!.addSubview(tab.web)
    window.orderFront(nil)
    return window
  }

  /// The tab's click-type controls, or nil when the tree is not available (fall back to PageKit).
  /// The first read of a launch waits up to 1 s for the warm-up request instead of reading without
  /// the tree (most pages then have it; see walk for heavy ones). The warm-up starts at that read,
  /// not when the tab opens: starting it (and the hidden window) at open made CNN's first page load
  /// 2.2 s slower.
  /// The walk runs off the main thread: Serein answers its own accessibility requests there, and a
  /// page whose tree WebKit must still build (X) stalled a main-thread read for 3 s. Each request
  /// gives up after 0.5 s and the whole read after 0.4 s of walking; then PageKit reads alone.
  static func controls(_ tab: BrowserTab) async -> Tree? {
    guard enabled else { return nil }
    let fresh = tab.web.window == nil
    guard let window = host(tab) else { return nil }
    if !warm {
      warmUp()
      for _ in 0..<20 where !warm { try? await Task.sleep(nanoseconds: 50_000_000) }
      guard warm else { return nil }
    }
    let started = Date()
    let title = window.title
    let scale = tab.web.pageZoom * tab.web.magnification
    generation += 1
    let generation = generation
    let walked = await withCheckedContinuation { (done: CheckedContinuation<Walk?, Never>) in
      DispatchQueue.global(qos: .userInitiated).async {
        done.resume(returning: walk(window: title, scale: scale, generation: generation, fresh: fresh))
      }
    }
    guard let walked else {
      FastSteps.log(String(format: "ax    no tree after %d ms; PageKit alone", Int(Date().timeIntervalSince(started) * 1000)))
      return nil
    }
    refs[tab.id] = walked.table
    FastSteps.log(String(format: "ax    %d controls in %d ms", walked.found.count, Int(Date().timeIntervalSince(started) * 1000)))
    return Tree(controls: walked.found, complete: walked.complete)
  }
  private struct Walk: @unchecked Sendable {
    var found: [Control] = []
    var table: [String: AXUIElement] = [:]
    /// False when the walk stopped at the control cap or the depth limit.
    var complete = true
  }
  /// The tree's controls, and whether the walk saw the whole page (see merge).
  struct Tree {
    let controls: [Control]
    let complete: Bool
  }
  nonisolated private static func walk(window title: String, scale: CGFloat, generation: Int, fresh: Bool) -> Walk? {
    let app = AXUIElementCreateApplication(getpid())
    AXUIElementSetMessagingTimeout(app, 0.5)
    // A window made for this read (a tab's first read) shows its web area to the tree up to about
    // 0.3 s later (CNN); that read came back without the tree. It looks again for up to 0.4 s. Just
    // after the warm-up, a heavy page takes longer (Apple's store: 1.1 s) and that read stays without.
    let until = Date().addingTimeInterval(fresh ? 0.4 : 0)
    var found: (AXUIElement, CGPoint)?
    while true {
      found = (value(app, kAXWindowsAttribute) as? [AXUIElement])?
        .first(where: { value($0, kAXIdentifierAttribute) as? String == title || value($0, kAXTitleAttribute) as? String == title })
        .flatMap { webArea(in: $0) }
      if found != nil || Date() > until { break }
      Thread.sleep(forTimeInterval: 0.025)
    }
    guard let (area, origin) = found else { return nil }
    let deadline = Date().addingTimeInterval(0.4)
    var out = Walk()
    var late = false
    // An element can be reached twice (a table lists its header cells under a header group too).
    var seen = Set<AXUIElement>()
    func walk(_ e: AXUIElement, _ depth: Int) {
      guard !late else { return }
      guard out.found.count < 300, depth < 80 else {
        out.complete = false
        return
      }
      guard seen.insert(e).inserted else { return }
      if Date() > deadline { late = true; return }
      let v = values(e, [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXValueAttribute, kAXEnabledAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute])
      let role = v[0] as? String ?? ""
      // A frame's controls belong to PageKit's frame reads, with their own checks.
      if role == "AXWebArea" && depth > 0 { return }
      // A table lists each cell under its row and again under its column; the rows are enough.
      if role == "AXColumn" { return }
      let named = [v[2], v[3]].compactMap { $0 as? String }.first { !$0.isEmpty }
      // A group or a table cell with its own click handler (a header that sorts) is a control.
      let group = role == "AXGroup" || role == "AXCell" ? pressableGroup(e, named: named, children: v[8] as? [AXUIElement] ?? []) : nil
      if let (kind, typed) = group == nil ? kind(role, v[1] as? String) : ("clickable", false),
        let position = point(v[6]), let size = size(v[7])
      {
        let ref = "x\(generation)_\(out.found.count + 1)"
        out.table[ref] = e
        let label = group ?? named ?? ""
        let toggle = ["radio", "checkbox", "switch", "tab"].contains(kind)
        out.found.append(Control(
          ref: ref, role: kind, label: String(label.prefix(160)),
          checked: toggle ? ((v[4] as? NSNumber)?.intValue ?? 0) != 0 : nil,
          enabled: (v[5] as? Bool) ?? true, typed: typed,
          center: CGPoint(
            x: (position.x + size.width / 2 - origin.x) / scale, y: (position.y + size.height / 2 - origin.y) / scale)))
      }
      for child in (v[8] as? [AXUIElement]) ?? [] { walk(child, depth + 1) }
    }
    walk(area, 0)
    // A part of a tree would make the merge drop PageKit rows the walk never reached.
    return late ? nil : out
  }

  /// PageKit's rows with what the tree knows: roles, names and enabled states for the same controls
  /// (matched by centre), plus click-type controls PageKit missed. The centres are dropped.
  static func merge(_ rows: [[String: Any]], _ tree: Tree) -> [[String: Any]] {
    let controls = tree.controls
    var rows = rows
    var used = Set<Int>()
    var extra: [[String: Any]] = []
    let tags: Set = ["div", "span", "a", "button", "input", "li", "label", "img", "svg", "p"]
    for c in controls {
      let near = rows.indices.first { i in
        guard !used.contains(i), let x = (rows[i]["x"] as? NSNumber)?.doubleValue,
          let y = (rows[i]["y"] as? NSNumber)?.doubleValue
        else { return false }
        return abs(x - c.center.x) <= 4 && abs(y - c.center.y) <= 4
      }
      // A control the page draws with its label can sit away from its own box; the same name matches it.
      let named = near ?? rows.indices.first { i in
        !used.contains(i) && !c.label.isEmpty
          && (rows[i]["label"] as? String)?.lowercased() == c.label.lowercased()
      }
      if let i = named {
        used.insert(i)
        if tags.contains(rows[i]["role"] as? String ?? "") { rows[i]["role"] = c.role }
        if (rows[i]["label"] as? String ?? "").isEmpty, !c.label.isEmpty { rows[i]["label"] = c.label }
        if rows[i]["checked"] == nil, let checked = c.checked { rows[i]["checked"] = checked }
        if !c.enabled { rows[i]["disabled"] = true }
      } else if !c.typed, !c.label.isEmpty {
        var row: [String: Any] = ["ref": c.ref, "role": c.role, "label": c.label, "acts": ["click"]]
        if let checked = c.checked { row["checked"] = checked }
        if !c.enabled { row["disabled"] = true }
        extra.append(row)
      }
    }
    // A row the tree does not have at all is hidden from people (aria-hidden): leave it out too,
    // but only after a whole walk; a walk cut short at the cap never reached the rest of the page.
    // PageKit's pointer rows stay: the tree shows a control handled on the page root as text only.
    // So do file fields, which the tree is not allowed to list: the agent learns one is there.
    // So do form fields: the tree holds only the roles kind() knows, and a date field, a slider or
    // a list box (select size=5) has other roles, so its absence does not mean it is hidden.
    let kept: Set = ["clickable", "file", "input", "select", "textarea"]
    let shown =
      controls.isEmpty || !tree.complete
      ? rows
      : rows.indices.filter { i in
        used.contains(i) || kept.contains(rows[i]["role"] as? String ?? "")
          || (rows[i]["acts"] as? [String] ?? []).contains { $0 != "click" }
      }.map { rows[$0] }
    return (shown + extra).map { $0.filter { $0.key != "x" && $0.key != "y" } }
  }

  /// AXPress on a control from the latest read: a person's click for the page.
  static func press(_ tab: BrowserTab, ref: String, name: String, allowed: () -> Bool) async throws -> Any {
    guard name == "click" else { throw SereinError.invalid("This control takes clicks only.") }
    guard let e = refs[tab.id]?[ref] else { throw SereinError.invalid("Stale element reference. Read the page again.") }
    guard allowed() else { throw SereinError.invalid("The task ended during this operation") }
    refs[tab.id] = nil
    // Off the main thread, as the read. AXPress reports success on a disabled control and nothing
    // happens, so the enabled state is checked first.
    let element = Walk(table: ["e": e])
    let outcome = await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
      DispatchQueue.global(qos: .userInitiated).async {
        guard let e = element.table["e"] else { return done.resume(returning: "Stale element reference. Read the page again.") }
        AXUIElementSetMessagingTimeout(e, 0.5)
        if (value(e, kAXEnabledAttribute) as? Bool) == false { return done.resume(returning: "Element is disabled.") }
        done.resume(returning: AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
          ? nil : "The press did not reach the page. Read the page again.")
      }
    }
    if let outcome { throw SereinError.invalid(outcome) }
    return ["performed": "click", "via": "accessibility"]
  }

  nonisolated private static func kind(_ role: String, _ subrole: String?) -> (String, Bool)? {
    switch role {
    // A file field's button opens the file chooser, which is the user's step; PageKit refuses it too.
    case "AXButton": return subrole == "AXFileUploadButton" ? nil : ("button", false)
    case "AXLink": return ("link", false)
    case "AXRadioButton": return (subrole == "AXTabButton" ? "tab" : "radio", false)
    case "AXCheckBox": return (subrole == "AXSwitch" ? "switch" : "checkbox", false)
    case "AXMenuItem": return ("menuitem", false)
    case "AXMenuButton", "AXPopUpButton": return ("menubutton", false)
    case "AXDisclosureTriangle": return ("disclosure", false)
    // Fields are only matched to PageKit's rows, which type with their secret checks.
    case "AXTextField", "AXTextArea", "AXComboBox": return subrole == "AXSecureTextField" ? nil : ("textbox", true)
    default: return nil
    }
  }
  /// A group the page made clickable with a handler of its own (WebKit offers AXPress on it), named
  /// by its label or its own text. A group with no text of its own or a long one, such as a page
  /// root that handles every click, is not a control.
  nonisolated private static func pressableGroup(_ e: AXUIElement, named: String?, children: [AXUIElement]) -> String? {
    var actions: CFArray?
    guard AXUIElementCopyActionNames(e, &actions) == .success,
      (actions as? [String])?.contains(kAXPressAction) == true
    else { return nil }
    let text = named ?? children.compactMap { child -> String? in
      let v = values(child, [kAXRoleAttribute, kAXValueAttribute])
      return v[0] as? String == "AXStaticText" ? v[1] as? String : nil
    }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty || text.count > 80 ? nil : text
  }
  nonisolated private static func webArea(in window: AXUIElement) -> (AXUIElement, CGPoint)? {
    var queue: [(AXUIElement, AXUIElement?, Int)] = [(window, nil, 0)]
    while !queue.isEmpty {
      let (e, parent, depth) = queue.removeFirst()
      if value(e, kAXRoleAttribute) as? String == "AXWebArea", let parent,
        let origin = point(value(parent, kAXPositionAttribute))
      {
        return (e, origin)
      }
      if depth < 8 { for child in (value(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { queue.append((child, e, depth + 1)) } }
    }
    return nil
  }
  nonisolated private static func value(_ e: AXUIElement, _ attribute: String) -> AnyObject? {
    var out: AnyObject?
    return AXUIElementCopyAttributeValue(e, attribute as CFString, &out) == .success ? out : nil
  }
  /// Several attributes in one call; a missing one is nil.
  nonisolated private static func values(_ e: AXUIElement, _ attributes: [String]) -> [AnyObject?] {
    var out: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(e, attributes as CFArray, [], &out) == .success,
      let list = out as? [AnyObject], list.count == attributes.count
    else { return Array(repeating: nil, count: attributes.count) }
    return list.map { item in
      if CFGetTypeID(item) == AXValueGetTypeID(), AXValueGetType(item as! AXValue) == .axError { return nil }
      return item
    }
  }
  nonisolated private static func point(_ any: AnyObject?) -> CGPoint? {
    guard let any, CFGetTypeID(any) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(any as! AXValue, .cgPoint, &p) ? p : nil
  }
  nonisolated private static func size(_ any: AnyObject?) -> CGSize? {
    guard let any, CFGetTypeID(any) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(any as! AXValue, .cgSize, &s) ? s : nil
  }
}
