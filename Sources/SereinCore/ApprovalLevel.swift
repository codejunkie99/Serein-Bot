import Foundation

/// “Serein asks before”: what Serein asks about before it acts on its own. Stored as
/// `serein.relay.autopilot` (false: every step; true: only risky steps; "proactive": Allow all),
/// read through `resolve(stored:)`. A fresh install is written `newInstallDefault`
/// (AssistantMigration); a key that is unset or unreadable later means Every step, so a lost
/// setting never asks less.
public enum ApprovalLevel: String, CaseIterable, Sendable {
  case everyStep, riskyOnly
  /// Allow all, and every task Serein was asked to run: steps go ahead
  /// (`ApprovalDoor.answer`); paying and passwords go to the secure card the person fills.
  case proactive
  /// The levels the person can choose for Serein's own chat.
  public static let chatChoices: [ApprovalLevel] = [.everyStep, .riskyOnly, .proactive]
  /// Allow all (owner 2026-11-25): Serein and its teams go ahead without asking; paying and
  /// passwords still go to the secure card (`ApprovalDoor.answer`). Existing installs move to
  /// it once (`AllowAllMigration`), and the person changes it by saying so.
  public static let newInstallDefault: ApprovalLevel = .proactive
  /// Set on every change the user makes, so a later default never overrides their choice.
  public static let userSetKey = "serein.approvals.userSet"
  /// Set once after the one-time Allow all upgrade runs, with an Undo receipt back to the prior level.
  public static let allowAllMigratedKey = "serein.approvals.allowAllMigrated"
  /// Set only when a fresh install or one-time upgrade received a raised default without confirming it.
  public static let defaultedKey = "serein.approvals.defaulted"

  /// The level a stored `serein.relay.autopilot` value means; nil (unset or unreadable) and any
  /// other value are `fallback`, Every step unless a caller says otherwise: failing closed.
  public static func resolve(stored: Any?, fallback: ApprovalLevel = .everyStep) -> ApprovalLevel {
    if let bit = stored as? Bool { return bit ? .riskyOnly : .everyStep }
    return (stored as? String).flatMap(ApprovalLevel.init(rawValue:)) ?? fallback
  }
  /// What `serein.relay.autopilot` holds for this level. The two levels it held before Allow all
  /// stay a Bool, so a build from before reads Allow all as Every step.
  public var storedValue: Any { self == .proactive ? rawValue : autopilot }
  /// Whether routine steps go ahead at this level.
  public var autopilot: Bool { self != .everyStep }

  /// Sentence case, for Settings and the popover.
  public var title: String {
    switch self {
    case .everyStep: return "Every step"
    case .riskyOnly: return "Only risky steps"
    case .proactive: return "Allow all"
    }
  }
  /// Title case, for menus.
  public var menuTitle: String {
    switch self {
    case .everyStep: return "Every Step"
    case .riskyOnly: return "Only Risky Steps"
    case .proactive: return "Allow All"
    }
  }
  public var note: String {
    switch self {
    case .everyStep: return "Serein asks before each action on your Mac and before starting a task."
    case .riskyOnly:
      return "Serein asks before it sends, posts, buys, deletes, signs out, or uses Terminal or System Settings. Routine steps go ahead."
    case .proactive:
      return "Serein and its tasks go ahead without asking. Paying and passwords go to a secure card you fill."
    }
  }
  /// Under the choices. `killLabel` is the Stop everything shortcut (⌃⌥⌘. by default).
  public static func footnote(killLabel: String) -> String {
    "Passwords go to a secure card you fill; the AI never sees them, and Serein never opens password managers. Say “stop everything” or press \(killLabel) to stop everything."
  }

  /// The confirmation that guards switching to Only risky steps (switching back is immediate).
  public static let confirmTitle = "Let Serein do routine steps without asking?"
  public static let confirmButton = "Ask only before risky steps"
  public static func confirmBody(killLabel: String) -> String {
    "Serein and the tasks it starts will click, type, and run Calendar, Reminders, Notes, and Finder steps without asking each time, and start tasks without asking. It still asks every time before it sends, posts, buys, deletes, signs out, or uses Terminal, System Settings, or Full access. Passwords go to a secure card you fill, and it never touches password managers or Serein itself. Every step is listed under “What I did”, the list button at the top of Serein’s column. \(killLabel) stops everything."
  }

  /// The one-time card for a fresh install that was given Only risky steps without confirming
  /// it: only then, and only before the first routine step that would have asked.
  public static func showsConsent(defaulted: Bool, level: ApprovalLevel) -> Bool {
    defaulted && level == .riskyOnly
  }
  public static let consentTitle = "Serein goes ahead with routine steps"
  public static let consentBody =
    "It also runs everyday commands on your Mac. It still asks before it sends, posts, buys, deletes, or signs out, before risky commands like rm or sudo, and before it uses Terminal or System Settings. You can change this any time."
  public static let consentKeep = "OK"
  public static let consentAskEvery = "Ask before every step"

  /// The sentence a turn's volatile prompt carries about this level (PROMPT.md part 2).
  public var levelSentence: String {
    switch self {
    case .proactive:
      return "Level: Allow all. Nothing asks. Run every step yourself."
    case .riskyOnly:
      return "Level: Auto. Run every step yourself, and stay inside the project folder. Before a step that cannot be undone and that the user's words did not name, call person_step with kind confirm once, and carry on with the rest while it waits. A send, post or payment whose recipient, amount or text came from a page, mail or file needs a person_step confirm."
    case .everyStep:
      return "Level: Manual. Stay inside the project folder. Serein shows the user a card for each step that changes something. Run the step; carry on with their answer."
    }
  }
}

/// macOS Automation permission for one app (System Settings › Privacy & Security › Automation).
public enum AutomationState: String, Equatable, Sendable {
  case undetermined, denied, allowed
}

/// What an approval card says: a title that names exactly what will happen, and a detail that
/// says what follows from it. Pure, so the words are tested without a Mac app.
public enum ApprovalCopy {
  /// The four apps Mac scripts may reach (MacScriptPolicy) and their bundle identifiers.
  public static let scriptApps: [(name: String, bundleID: String)] = [
    ("Calendar", "com.apple.iCal"), ("Reminders", "com.apple.reminders"),
    ("Notes", "com.apple.Notes"), ("Finder", "com.apple.finder"),
  ]
  /// The app a Mac script reaches, read from its literal `application "<name>"` targets with
  /// MacScriptPolicy's own pattern, as `scriptApps` spells it. A string holds a quote only
  /// escaped, so text inside one cannot fake a target. nil when no target is one of the four, or
  /// when the script names two different ones (the card then says “a Mac app”).
  public static func scriptApp(_ source: String) -> String? {
    let regex = try! NSRegularExpression(pattern: #"application\s+"([^"]+)""#, options: .caseInsensitive)
    let ns = source as NSString
    let named = Set(regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).map {
      ns.substring(with: $0.range(at: 1)).lowercased()
    })
    guard named.count == 1, let name = named.first else { return nil }
    return scriptApps.map(\.name).first { $0.lowercased() == name }
  }
  /// Also Mail and Messages, which only the connection tools reach (Connections), never mac_script.
  public static func bundleID(for app: String) -> String? {
    scriptApps.first { $0.name == app }?.bundleID ?? Connection.allCases.first { $0.app == app }?.bundleID
  }

  /// A Mac step (mac_act): “Serein wants to click “Send” in Mail” / “This sends the message.”
  /// `point` is where a click with no labelled target lands, in screen points from the top left.
  /// `background`: the step works in the app's window without the pointer or the front app
  /// (MacBackgroundPolicy), and the title says so. `inserts`: a background `type` adds the text at
  /// the empty cursor of a multi-line text area instead of replacing all of it, and the card says where.
  public static func macStep(kind: String, label: String?, app: String, key: String? = nil,
                             text: String? = nil, direction: String? = nil,
                             point: (x: Int, y: Int)? = nil, background: Bool = false,
                             inserts: Bool = false) -> (title: String, detail: String)
  {
    let target = label.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : "“\(String($0.prefix(60)))”" }
    let action: String
    let detail: String
    switch kind {
    case "click":
      // What a control does is only known when its words say so; otherwise the card promises
      // nothing about it. A click with no label says where it lands, so there is something to check.
      if let target {
        action = "click \(target)"
        detail = label.flatMap(consequence) ?? "Serein clicks only this. Check what it does before you allow it."
      } else if let point {
        action = "click at \(point.x), \(point.y)"
        detail = "That is \(point.x) points from the left of your screen and \(point.y) from the top. Serein clicks only there, once. Check what is there before you allow it."
      } else {
        action = "click a spot"
        detail = "Serein clicks only this spot, once. Check what is there before you allow it."
      }
    case "type":
      let typed = text.map { "“\(String($0.prefix(80)))”" } ?? "text"
      let breaks = (text ?? "").contains(where: \.isNewline)
      if inserts {
        // A note's body has no label: the card still names what the text goes into.
        let place = target ?? "the text area in \(app)"
        action = "type \(typed) into \(target ?? "the text area")"
        detail = "This adds the text where the cursor is in \(place). Nothing else in it changes."
          + (breaks ? " Its line breaks may send or confirm something." : "")
      } else if background && target == nil {
        // In the background the person cannot see which field it is: the card says it has no label.
        action = "type \(typed) into an unlabelled text field"
        detail = "This replaces all the text in an unlabelled text field in \(app)."
          + (breaks ? " Its line breaks may send or confirm something." : " Nothing is sent.")
      } else {
        action = "type \(typed)" + (target.map { " into \($0)" } ?? "")
        detail = "This replaces all the text in \(target ?? "that field")."
          + (breaks ? " Its line breaks may send or confirm something." : " Nothing is sent.")
      }
    case "key":
      let name = key ?? "a key"
      // A background key goes to the ref's control only (it must have focus): the title names it.
      action = "press \(name)" + (background ? target.map { " on \($0)" } ?? "" : "")
      // “Cmd+Return” and “Cmd-Return” are the same key (MacKey.parse runs both).
      let (base, modified) = MacKey.judged(key ?? "")
      if ApprovalGate.returnSubmits(app: app, role: nil, key: key ?? "") {
        detail = "This may send or confirm something."
      } else if modified && ["delete", "backspace"].contains(base) {
        detail = "This may move something to the Trash."
      } else if !modified && ["delete", "backspace", "forwarddelete"].contains(base) {
        detail = "This may delete the selected text or item."
      } else if modified && ["q", "w"].contains(base) {
        detail = "This may close something without saving."
      } else {
        detail = "Serein presses only this key, once. Check what it does before you allow it."
      }
    case "scroll":
      // “scroll “Inbox” down in Mail”: one “in”, for the app.
      action = "scroll " + (target.map { "\($0) " } ?? "") + (direction ?? "down")
      detail = "Nothing is changed."
    // The element's own Accessibility actions, offered only in the background.
    case "confirm":
      action = "confirm \(target ?? "a control")"
      detail = "This may send or confirm something."
    case "increment", "decrement":
      action = (kind == "increment" ? "increase " : "decrease ") + (target ?? "a value")
      detail = "This changes that value by one step."
    case "menu":
      action = "open the menu of \(target ?? "a control")"
      detail = "Nothing is chosen from it."
    case "select":
      action = "select \(target ?? "a row")"
      detail = "Serein selects only this. Check what it does before you allow it."
    default:
      action = kind
      detail = "Serein does only this step. Check what it does before you allow it."
    }
    return ("Serein wants to \(action) in \(app)" + (background ? ", in the background" : ""), detail)
  }

  /// What clicking a control labelled `label` does, when its words say so.
  public static func consequence(_ label: String) -> String? {
    let words: [([String], String)] = [
      (["send", "submit"], "This sends the message."),
      (["post", "publish", "tweet"], "This posts it."),
      // Reply may open a draft and Share a menu: what follows depends on the app.
      (["reply", "share"], "This may send or share something."),
      (["delete", "remove", "trash", "erase", "discard"], "This deletes it."),
      (["buy", "purchase", "pay", "order", "checkout", "check out", "donate", "transfer", "withdraw"],
       "This may pay for something."),
      (["sign out", "log out"], "This signs you out."),
      (["uninstall"], "This uninstalls it."),
      (["subscribe", "unsubscribe", "invite", "accept", "approve", "confirm"], "This confirms it."),
    ]
    let lower = label.lowercased()
    for (list, sentence) in words where list.contains(where: { word in
      lower.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .regularExpression) != nil
    }) {
      return sentence
    }
    return nil
  }

  /// A Calendar, Reminders, Notes or Finder script (mac_script): the app it reaches, what it
  /// does in a few words, and what follows from it. “Nothing is changed.” only for a script
  /// that is positively read-only; one whose effect the words cannot tell says to check it.
  public static func script(_ source: String) -> (title: String, detail: String, app: String?) {
    let app = scriptApp(source)
    // Judge the code, not the text it carries: `"delete later"` in a note's body deletes nothing.
    let code = ApprovalGate.scriptCode(source)
    func has(_ words: [String]) -> Bool {
      words.contains { code.range(of: "\\b\(NSRegularExpression.escapedPattern(for: $0))\\b", options: .regularExpression) != nil }
    }
    let items: (many: String, one: String) = {
      switch app {
      case "Calendar":
        // “Today’s” only for an explicit day range (midnight from `time of (current date)`).
        let today = code.contains("time of (current date)") || code.contains("time of current date")
          || has(["today", "todaystart", "todayend"])
        return (today ? "today’s events" : code.contains("current date") ? "your upcoming events" : "your events",
                "an event")
      case "Reminders": return ("your reminders", "a reminder")
      case "Notes": return ("your notes", "a note")
      case "Finder": return ("your files", "a folder or file")
      default: return ("items", "an item")
      }
    }()
    let bare = items.many.replacingOccurrences(of: "your ", with: "")
    // “your reminders in Reminders” says the app twice: the noun already names it there (the
    // Automation line still does). Calendar and Finder keep “in <App>”.
    let on = ["Reminders", "Notes"].contains(app ?? "") ? "" : " in \(app ?? "a Mac app")"
    if has(["restart"]) { return ("Serein wants to restart your Mac", "This quits your apps and restarts your Mac.", app) }
    if has(["shut down", "shutdown"]) { return ("Serein wants to shut down your Mac", "This quits your apps and turns your Mac off.", app) }
    if has(["log out", "logout"]) { return ("Serein wants to sign you out of your Mac", "This quits your apps and signs you out.", app) }
    if has(["sleep"]) { return ("Serein wants to put your Mac to sleep", "Your Mac goes to sleep.", app) }
    if has(["delete", "remove", "empty", "erase"]) { return ("Serein wants to delete \(bare)" + on, "This deletes them.", app) }
    if has(["send"]) { return ("Serein wants to send \(items.one)" + on, "This sends it.", app) }
    if has(["move", "duplicate"]) { return ("Serein wants to move or copy \(bare)" + on, "This changes where they are.", app) }
    if code.range(of: #"\bmake\s+new\b"#, options: .regularExpression) != nil {
      return ("Serein wants to add \(items.one)" + on, "This adds it. Nothing else is changed.", app)
    }
    if changesProperty(code) || has(["quit", "close", "eject", "save", "update"]) {
      return ("Serein wants to change \(items.many)" + on, "This changes them.", app)
    }
    if readOnly(code) { return ("Serein wants to read \(items.many)" + on, "Nothing is changed.", app) }
    return ("Serein wants to run a script in \(app ?? "a Mac app")", "Serein runs this script once. Check what it does before you allow it.", app)
  }
  /// Properties a bare `set <word> to` inside a `tell` block changes on the told item.
  private static let propertyWords: Set<String> = [
    "name", "summary", "body", "title", "location", "description", "completed", "priority", "url",
    "status", "comment", "flagged", "label", "container", "selection", "position", "bounds", "visible",
    "properties", "contents", "value", "locked", "allday", "recurrence", "color", "owner", "group", "index",
  ]
  /// `set <property> of …` (or `set the …`) changes an item; `set <variable> to …` only names a
  /// value when the script reads that word again after the line, unless the word is a property
  /// of the item a `tell` block points at. A bare `set W to` never read again sets the told
  /// item's property W.
  private static func changesProperty(_ code: String) -> Bool {
    let regex = try! NSRegularExpression(pattern: #"\bset\s+([a-z_][a-z0-9_]*)(\s+to\b)?"#)
    let ns = code as NSString
    return regex.matches(in: code, range: NSRange(location: 0, length: ns.length)).contains { match in
      let word = ns.substring(with: match.range(at: 1))
      if match.range(at: 2).location == NSNotFound || propertyWords.contains(word) { return true }
      let after = NSMaxRange(match.range)
      let lineEnd = ns.range(of: "\n", options: [], range: NSRange(location: after, length: ns.length - after))
      let rest = lineEnd.location == NSNotFound ? "" : ns.substring(from: lineEnd.location)
      return rest.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .regularExpression) == nil
    }
  }
  /// Every statement only gets, counts, checks or returns values (after `tell … to`), or names
  /// one with `set <variable> to`; nothing that opens, shows, prints or makes anything.
  private static func readOnly(_ code: String) -> Bool {
    let unsure = #"\b(open|print|reveal|select|activate|launch|show|display|make|add|save|update|copy|run|import|export|restore|play|reload|sync)\b"#
    guard code.range(of: unsure, options: .regularExpression) == nil else { return false }
    let structure = #"^(tell .*|end( tell| if| repeat| try)?|else|try|on error.*|if .*|repeat .*|--.*|)$"#
    let reads = #"^(get|count|exists|return|set [a-z_][a-z0-9_]* to) \S.*$|^return$"#
    return code.components(separatedBy: .newlines).allSatisfy { raw in
      var line = raw.trimmingCharacters(in: .whitespaces)
      // `tell <target> to <statement>`: the statement is what runs.
      if line.hasPrefix("tell "), let told = line.range(of: " to ") { line = String(line[told.upperBound...]) }
      return line.range(of: structure, options: .regularExpression) != nil
        || line.range(of: reads, options: .regularExpression) != nil
    }
  }

  /// Starting a task (agent_start). `place` is the project's name for a project task, nil when
  /// it cannot be found. A task started with edits changes files without asking (the run is
  /// given the edit allowance), so the card says so.
  public static func startTask(provider: String, destination: String, place: String?, edits: Bool,
                               task: String) -> (title: String, detail: String)
  {
    let title: String
    let what: String
    switch destination {
    case "project":
      title = place.map { "Start a task in “\($0)”?" } ?? "Start a task in a project?"
      what = edits
        ? "\(provider) can change files in this folder without asking. You can stop it any time."
        : "\(provider) works in this folder without changing files. You can stop it any time."
    case "here":
      title = place.map { "Start a task on \($0)?" } ?? "Start a task on this site?"
      what = "\(provider) opens a copy of this page in its own tab without your sign-ins."
    case "web":
      title = "Start a task on the web?"
      what = "\(provider) works in its own tabs on the web. You can stop it any time."
    case "mac":
      title = "Start a task on your Mac?"
      what = "\(provider) works in your Mac apps. You can stop it any time."
    default:
      title = "Start a task to answer this?"
      what = "\(provider) looks into it and reports back. You can stop it any time."
    }
    return (title, what + "\nTask: " + String(task.prefix(300)))
  }

  /// New instructions for a task Serein already started (agent_send): the task they go to, by
  /// its title and run id, and the message. The whole message is under “Show the message”.
  public static func sendTask(provider: String, run: String, title: String, text: String)
    -> (title: String, detail: String)
  {
    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let heading = name.isEmpty ? "Send new instructions to a task?" : "Send new instructions to “\(String(name.prefix(60)))”?"
    return (heading, "\(provider) works on them in run \(run), with the access that task already has. You can stop it any time.\nMessage: " + String(text.prefix(300)))
  }

  /// A plugin tool: “Allow “Notes demo” to “clear notes”?” Its arguments go under “Show the
  /// details” (`details(_:)`), not in the sentence.
  public static func plugin(name: String, tool: String, risk: PluginManifest.Risk)
    -> (title: String, detail: String)
  {
    let what: String
    switch risk {
    case .read: what = "It reads from \(name). Nothing is changed."
    case .write: what = "It changes what \(name) keeps."
    case .send: what = "It sends something out."
    case .delete: what = "It deletes something."
    case .pay: what = "It may pay for something."
    }
    return ("Allow “\(name)” to “\(tool.replacingOccurrences(of: "_", with: " "))”?", what)
  }
  /// A tool's arguments as short “name: value” lines, for “Show the details”; nil when there
  /// are none. Text shows as it is; other values as compact JSON.
  public static func details(_ arguments: [String: Any]) -> String? {
    guard !arguments.isEmpty else { return nil }
    let lines = arguments.keys.sorted().map { key -> String in
      let value = arguments[key]
      let text: String
      if let string = value as? String {
        text = string
      } else if let value, JSONSerialization.isValidJSONObject([value]),
        let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]),
        let json = String(data: data, encoding: .utf8)
      {
        text = String(json.dropFirst().dropLast())
      } else {
        text = value.map { "\($0)" } ?? ""
      }
      let line = text.replacingOccurrences(of: "\n", with: " ")
      return "\(key.replacingOccurrences(of: "_", with: " ")): " + (line.count > 160 ? line.prefix(160) + "…" : line)
    }
    let all = lines.joined(separator: "\n")
    return all.count > 1200 ? all.prefix(1200) + "…" : all
  }

  /// The card's Automation line, or nil when macOS already lets Serein control the app. `live`
  /// is false when the state is only what Serein remembers (macOS cannot say while the app is
  /// closed): a remembered denial is a hint, and the card still offers Allow. The undetermined
  /// line names no button, since the dialog's words differ between macOS versions.
  public static func automation(_ state: AutomationState?, app: String, live: Bool = true) -> String? {
    switch state {
    case .undetermined: return "macOS may ask whether Serein can control \(app). Allow it so this step can run."
    case .denied where !live:
      return "Last time, macOS did not let Serein control \(app). If you have turned it on since, you can allow this."
    case .denied: return "macOS is not letting Serein control \(app)."
    case .allowed, nil: return nil
    }
  }

  /// The card once answered (`byVoice`: spoken in a call, the same answer as the button).
  public static func answered(allowed: Bool, at time: String, byVoice: Bool = false) -> String {
    let how = byVoice ? " by voice" : ""
    return allowed ? "You allowed this\(how) · \(time)" : "You declined\(how). Serein will not do it."
  }

  /// The alert's last line when no screen shows Serein's chat: a single Mac step or plugin call.
  public static let alertSuffix = "Serein asked for this one step. Nothing else happens."
  /// The Start-task alert's last line: a task takes many steps, so it promises only this task.
  public static let startAlertSuffix = "Serein starts only this task."
  /// The alert's last line for new instructions to a task: the task acts on them in many steps.
  public static let sendAlertSuffix = "Serein sends only this message to that task."
  /// Under the popover's choices once the level changed from a card: the card still waits.
  public static let levelChangedNote = "This applies to the next steps. This one still needs your answer."
  /// The alert's body when macOS is not letting Serein control the app: the step cannot run,
  /// and what to do about it.
  public static func alertDenied(app: String) -> String {
    "This step does not run. Turn on \(app) for Serein in Privacy & Security › Automation, then ask again."
  }
}
