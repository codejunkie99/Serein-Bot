import Foundation

/// Steps that only the user may take: passwords, card details, codes, CAPTCHAs and files.
public enum HandBack {
  /// Returned to the agent whenever a tool reaches one of the user's steps.
  public static let message =
    "This step is yours: the user types passwords, card details and codes, solves CAPTCHAs and chooses files (upload takes only a document the user attached to this message, after the user allows it). Routes: secure_card on a field marked secure; person_step with kind check on this tab for any other such field; ask_person_takeover on this tab for a CAPTCHA or bot check. Carry on with every other part, and pass this tab as result_tab when you finish."
  /// 13 to 19 digits, optionally grouped by spaces or dashes, that pass the Luhn check.
  public static func looksLikeCardNumber(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == " " || $0 == "-") }) else {
      return false
    }
    let digits = trimmed.compactMap { $0.wholeNumberValue }
    guard (13...19).contains(digits.count) else { return false }
    var sum = 0
    for (i, d) in digits.reversed().enumerated() {
      if i % 2 == 1 {
        let doubled = d * 2
        sum += doubled > 9 ? doubled - 9 : doubled
      } else {
        sum += d
      }
    }
    return sum % 10 == 0
  }

  /// Treat a run as an edge between the two Luhn doubling parities, starting at the
  /// right of the number. An even-length run stays on its starting parity. An odd
  /// run crosses to the other parity. A selection of runs can form a number only
  /// when its edges admit one continuous walk from the normal starting parity.
  public static func containsCardFragments(_ labels: [String]) -> Bool {
    let runs = labels.flatMap { $0.split(whereSeparator: { !$0.isWholeNumber }) }
    return matchesCard(runs, requiring: nil)
  }

  /// A label belongs to the mask when at least one valid card can include one of its
  /// runs. Equal runs are interchangeable. Cap provenance work on very large views.
  public static func cardFragmentLabels(_ labels: [String]) -> Set<String> {
    let numbers = labels.map { $0.split(whereSeparator: { !$0.isWholeNumber }) }
    let runs = numbers.flatMap { $0 }
    guard matchesCard(runs, requiring: nil) else { return [] }
    guard runs.count <= 48, !runs.contains(where: { $0.count > 19 }) else {
      return Set(labels.indices.filter { !numbers[$0].isEmpty }.map { labels[$0] })
    }
    var included: [Substring: Bool] = [:]
    for (i, run) in runs.enumerated() where included[run] == nil {
      included[run] = matchesCard(runs, requiring: i)
    }
    return Set(labels.indices.filter { numbers[$0].contains { included[$0] == true } }.map { labels[$0] })
  }

  private static func matchesCard(_ runs: [Substring], requiring required: Int?) -> Bool {
    let total = runs.reduce(0) { $0 + $1.count }
    guard total >= 13 else { return false }
    if total <= 19, looksLikeCardNumber(runs.joined()) { return true }
    // With a single long identifier there are no other runs to combine. Its only
    // possible card is a contiguous substring. Bound inspection of oversized input.
    if runs.count == 1, total > 19 {
      guard total <= 128 else { return true }
      let digits = runs[0].compactMap(\.wholeNumberValue)
      guard digits.count == total, digits.allSatisfy({ (0...9).contains($0) }) else { return true }
      for length in 13...19 {
        for start in 0...(digits.count - length) {
          if luhn(Array(digits[start..<(start + length)])) { return true }
        }
      }
      return false
    }

    struct Path: Hashable {
      // Normal-to-flipped crossings minus flipped-to-normal crossings.
      let balance: Int
      let crossed: Bool
      let usedFlipped: Bool

      func appending(odd: Bool, flipped: Bool) -> Path {
        Path(balance: balance + (odd ? (flipped ? -1 : 1) : 0),
             crossed: crossed || odd, usedFlipped: usedFlipped || flipped)
      }
      func canFinish(length: Int) -> Bool {
        balance == length % 2 && (!usedFlipped || crossed)
      }
    }
    let hasOdd = runs.contains { !$0.count.isMultiple(of: 2) }
    // A bit for each possible checksum modulo ten. Descending lengths ensure that
    // an observation can be selected once. Leaving the old state also permits gaps.
    var states = [[Path: Int]](repeating: [:], count: 20)
    states[0][Path(balance: 0, crossed: false, usedFlipped: false)] = 1
    for (index, run) in runs.enumerated() {
      let digits = run.compactMap(\.wholeNumberValue)
      guard digits.count <= 19, digits.allSatisfy({ (0...9).contains($0) }) else { return true }
      guard !digits.isEmpty else { continue }
      var normal = 0, flipped = 0
      for (i, digit) in digits.reversed().enumerated() {
        let twice = digit < 5 ? 2 * digit : 2 * digit - 9
        normal += i.isMultiple(of: 2) ? digit : twice
        flipped += i.isMultiple(of: 2) ? twice : digit
      }
      let odd = !digits.count.isMultiple(of: 2)
      for length in stride(from: 19, through: digits.count, by: -1) {
        if required == index { states[length].removeAll(keepingCapacity: true) }
        for (path, bits) in states[length - digits.count] {
          for flip in 0...(hasOdd ? 1 : 0) {
            let next = path.appending(odd: odd, flipped: flip == 1)
            let shift = (flip == 1 ? flipped : normal) % 10
            let residues = ((bits << shift) | (bits >> (10 - shift))) & 1023
            if index >= (required ?? 0) && length >= 13 && next.canFinish(length: length) && residues & 1 != 0 { return true }
            states[length][next, default: 0] |= residues
          }
        }
      }
      if required == index {
        for length in 0..<digits.count { states[length].removeAll(keepingCapacity: true) }
      }
    }
    return false
  }

  /// Characters that may sit between the digits of a card number.
  static let cardSeparators: Set<Character> = [" ", "-", ".", "/", "\u{00A0}"]

  /// True when the text holds a run of 13 to 19 digits, ignoring spaces, dashes, dots and
  /// slashes between them, that passes the Luhn check, anywhere in the text. Used on a field's
  /// final value, so chunked or appended typing is caught too.
  public static func containsCardNumber(_ text: String) -> Bool {
    var digits: [Int] = []
    func check() -> Bool {
      defer { digits.removeAll() }
      guard (13...19).contains(digits.count) else { return false }
      return luhn(digits)
    }
    for ch in text {
      if ch.isASCII, let d = ch.wholeNumberValue {
        digits.append(d)
      } else if cardSeparators.contains(ch), !digits.isEmpty {
        continue
      } else if check() {
        return true
      }
    }
    return check()
  }

  static func luhn(_ digits: [Int]) -> Bool {
    var sum = 0
    for (i, d) in digits.reversed().enumerated() {
      if i % 2 == 1 {
        let doubled = d * 2
        sum += doubled > 9 ? doubled - 9 : doubled
      } else {
        sum += d
      }
    }
    return sum % 10 == 0
  }
}

/// Limits for tabs an agent opens during one task.
public enum AgentTabPolicy {
  public static let maxTabs = 12
  public static let maxSteps = 400
  public static func capMessage() -> String {
    "This task already has \(maxTabs) tabs open. Close one before opening another."
  }
}

/// One timestamped entry in a run's "Show what the agent did" list.
public struct AgentStep: Codable, Equatable, Identifiable {
  public var id = UUID().uuidString
  public var time: Date
  public var tool: String
  public var label: String
  public var failed: String?
  /// The tab the step worked in, when the call named one (or opened it); nil in older records.
  public var tab: String?
  /// The site whose Never rule refused this step, so the list offers Change rule…; nil otherwise.
  public var ruleSite: String?
  public init(time: Date = Date(), tool: String, label: String) {
    self.time = time
    self.tool = tool
    self.label = label
  }
  /// A plain past-tense label. Typed text is shown briefly, never when it looks like a card number.
  public static func label(tool: String, arguments: [String: Any]) -> String {
    func host(_ key: String) -> String {
      guard let raw = arguments[key] as? String else { return "a page" }
      return URL(string: raw)?.host ?? "a page"
    }
    func quoted(_ key: String) -> String {
      guard let raw = arguments[key] as? String, !raw.isEmpty else { return "" }
      let flat = raw.replacingOccurrences(of: "\n", with: " ")
      let short = flat.count > 48 ? String(flat.prefix(47)) + "…" : flat
      return " “" + short + "”"
    }
    if let label = PeerTools.label(tool) { return label }
    switch tool {
    case "list_tabs", "tabs": return "Checked its tabs"
    case "open_tab", "open": return "Opened a new tab on " + host("url")
    case "navigate", "go": return "Went to " + host("url")
    case "read": return arguments["frame"] == nil ? "Read the page" : "Read part of the page"
    case "find": return "Searched the page" + (quoted("text").isEmpty ? "" : " for" + quoted("text"))
    case "click": return "Clicked on the page"
    case "fill", "type":
      let text = arguments["text"] as? String ?? ""
      return "Typed" + (HandBack.containsCardNumber(text) ? " a number" : quoted("text"))
    case "select": return "Picked an option" + quoted("value")
    case "hover": return "Pointed at an element"
    case "scroll": return "Scrolled " + (arguments["direction"] as? String ?? "down")
    case "key": return "Pressed " + (arguments["key"] as? String ?? "a key")
    case "back": return "Went back a page"
    case "wait": return "Waited for the page"
    case "screenshot": return "Looked at the page"
    case "close_tab", "close": return "Closed a tab"
    case "finish": return "Finished the task"
    case "mac_script": return "Proposed a Mac script"
    // A Mac app's window: the app and the kind of step, never what was typed. The host names
    // the control once the step ran (`RelayToolHost.describe`).
    case "mac_observe":
      let app = (arguments["app"] as? String ?? "").trimmingCharacters(in: .whitespaces)
      return app.isEmpty ? "Checked the open apps" : "Looked at " + String(app.prefix(40))
    case "mac_run": return "Ran a command on your Mac"
    case "mac_act":
      let named = (arguments["app"] as? String ?? "").trimmingCharacters(in: .whitespaces)
      let app = named.isEmpty ? "a Mac app" : String(named.prefix(40))
      switch arguments["kind"] as? String ?? "" {
      case "click": return "Clicked in " + app
      case "type": return "Typed in " + app
      case "key": return "Pressed " + String((arguments["key"] as? String ?? "a key").prefix(20)) + " in " + app
      case "scroll": return "Scrolled in " + app
      default: return "Worked in " + app
      }
    case "page_tool": return "Used a tool the page offers"
    case "upload": return "Uploaded" + (quoted("file").isEmpty ? " a file" : quoted("file"))
    case "click_point": return "Clicked a point on the page"
    case "downloads": return "Checked its downloaded files"
    case "table_query": return "Looked into" + (quoted("file").isEmpty ? " an attached table" : quoted("file"))
    case "connected_app_tools":
      let app = arguments["app"] as? String ?? ""
      return app.isEmpty ? "Checked its connected apps" : "Looked at the tools of" + quoted("app")
    case "connected_app_call": return "Used a connected app" + quoted("tool")
    // Mail and Messages: what was asked, never the message itself (the card shows that).
    case "mail_search": return "Searched Mail"
    case "mail_read": return "Read an email"
    case "mail_draft":
      // No card for a draft, so the step names who it is for and its subject.
      let to = (arguments["to"] as? [String])?.first ?? (arguments["to"] as? String) ?? ""
      let saved: String = arguments["id"] != nil ? "Saved a reply draft in Mail" : "Saved a draft in Mail"
      let recipient: String = to.isEmpty ? "" : " to \(String(to.prefix(60)))"
      return saved + recipient + quoted("subject")
    case "mail_send": return "Proposed an email"
    case "mail_reply": return "Proposed a reply"
    case "mail_move": return "Proposed moving an email"
    case "mail_mark": return "Proposed marking an email"
    case "mail_delete": return "Proposed deleting an email"
    case "messages_send": return "Proposed a message"
    case "messages_read": return "Read chosen Messages conversations"
    case "computer_screenshot": return "Looked at Serein's computer"
    case "computer_click": return "Clicked in Serein's computer"
    case "computer_type":
      let text = arguments["text"] as? String ?? ""
      return "Typed in Serein's computer" + (HandBack.containsCardNumber(text) ? " a number" : quoted("text"))
    case "computer_key": return "Pressed " + (arguments["key"] as? String ?? "a key") + " in Serein's computer"
    case "computer_scroll": return "Scrolled in Serein's computer"
    case "computer_open_url": return "Opened " + host("url") + " in Serein's computer"
    case "computer_run": return "Ran a command in Serein's computer"
    case "computer_tree": return "Read the screen of Serein's computer"
    case "computer_read_file": return "Read a file in Serein's computer"
    case "computer_send_file": return "Offered a file from Serein's computer"
    case "computer_send_text": return "Offered text from Serein's computer"
    // Calendar, Reminders, Contacts and Notes (NativeConnection): a change is only proposed here;
    // the person decides on its card.
    case "calendar_list": return "Read the calendar"
    case "calendar_create": return "Proposed an event" + quoted("title")
    case "calendar_update": return "Proposed a change to an event"
    case "calendar_delete": return "Proposed deleting an event"
    case "reminder_list_apple": return "Read Reminders"
    case "sessions_overview": return "Looked over your AI chats"
    case "sessions_list": return "Listed your AI chats"
    case "session_read": return "Read an AI chat"
    case "chats_search": return "Searched your other chats"
    case "reminder_create_apple": return "Proposed a reminder" + quoted("title")
    case "contacts_find": return "Looked up a contact"
    case "notes_search": return "Searched Notes"
    case "notes_read": return "Read a note"
    case "notes_create": return "Proposed a note" + quoted("title")
    case "notes_append": return "Proposed adding to a note"
    // Serein's own tools: files on the Mac, memory, helpers, reminders and its look.
    case "files_find": return "Looked for files" + quoted("query")
    case "files_search": return "Searched inside files" + quoted("text")
    case "folder_list": return "Looked in a folder"
    case "file_read":
      let name = (arguments["path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
      return name.isEmpty ? "Read a file" : "Read " + String(name.prefix(48))
    case "agent_start": return "Started a helper"
    case "agent_status": return "Checked on its helpers"
    case "agent_send": return "Sent a helper a message"
    case "agent_stop": return "Stopped a helper"
    case "agent_wait": return "Waited for a helper"
    case "remember": return "Saved a note to memory"
    case "recall": return "Checked its memory"
    case "forget": return "Forgot a note"
    case "memory_share": return "Shared a note with an assistant"
    case "rule_save": return "Kept a rule you set"
    case "rule_undo": return "Removed a rule"
    case ChatSettings.tool: return "Changed a setting you asked for"
    case "instructions_propose": return "Proposed new instructions"
    case "reminder_create": return "Set a reminder"
    case "reminder_list": return "Checked its reminders"
    case "reminder_update": return "Changed a reminder"
    case "reminder_cancel": return "Cancelled a reminder"
    case "notify": return "Sent you a notification"
    case "goal_create": return "Set a goal"
    case "goal_list": return "Checked your goals"
    case "goal_plan": return "Planned a goal"
    case "goal_progress": return "Noted progress on a goal"
    case "site_list": return "Checked your sites"
    case "site_save": return "Saved a site"
    case "site_show": return "Showed a site"
    case "goal_update": return "Updated a goal"
    case "skill_list": return "Checked its skills"
    case "skill_read": return "Read a skill"
    case "harness_capabilities": return "Checked what the AI app can do"
    case "look_get": return "Checked its look"
    case "look_set": return "Changed its look"
    case "look_undo": return "Undid a look change"
    case "look_show": return "Showed its looks"
    case "watch_create": return "Set up a watch"
    case "watch_list": return "Checked its watches"
    case "watch_cancel": return "Stopped a watch"
    case "ask_user": return "Asked you"
    case "current_page": return "Read the page beside it"
    case "recipe_run": return "Ran a saved routine"
    case "recipe_update": return "Updated a routine"
    case "team_make": return "Saved a team"
    case "todo_propose": return "Proposed a to-do list"
    case "setup_offer": return "Offered a setting"
    case "research_start": return "Started research"
    case "research_status": return "Checked on its research"
    case "research_pause": return "Paused its research"
    case "research_resume": return "Resumed its research"
    case "research_cross_check": return "Cross-checked its research"
    case "assistant_list": return "Checked your assistants"
    case "assistant_make": return "Made a new assistant"
    case "assistant_change": return "Proposed a change to an assistant"
    case "assistant_delete": return "Proposed removing an assistant"
    case "assistant_ask": return "Asked an assistant"
    case "assistant_handoff": return "Handed work to " + ((arguments["to"] as? String).map { String($0.prefix(40)) } ?? "a teammate")
    case "channel_say": return "Sent a message in the chat"
    case "swarm_start": return "Asked several models at once"
    case "room_read": return "Read its team room"
    case "room_note": return "Left a note for the team"
    case "room_report": return "Reported back"
    case "hook_make": return "Proposed an automation"
    case "hook_list": return "Checked its automations"
    case "hook_remove": return "Proposed removing an automation"
    case "plan": return "Updated its plan"
    case "dashboard_make": return "Made a dashboard"
    case "ui_show": return "Drew a view"
    case "post_draft": return "Drafted a post"
    case "connect_app": return "Offered to connect an app"
    case "secret_ask": return arguments["kind"] as? String == "card" ? "Asked for a card" : "Asked for a key"
    case "service_request":
      return (arguments["url"] as? String).flatMap { SecretVault.destination($0, template: true)?.host }.map { "Sent a request to " + $0 }
        ?? "Sent a request"
    case "undo": return "Undid a change"
    case "app_places": return "Checked where things are in Serein"
    case "app_open": return "Opened a place in Serein"
    case "app_read": return "Read a part of Serein"
    case "board_update": return "Changed a card on your Board"
    case ToolGroups.moreTool: return "Looked at more tools"
    // A tool reached through tool_run reads as that tool (ToolGroups).
    case ToolGroups.runTool:
      guard let inner = arguments["name"] as? String, inner != ToolGroups.runTool else { return "Used a tool" }
      return label(tool: inner, arguments: arguments["arguments"] as? [String: Any] ?? [:])
    // A tool this table does not know yet: never its raw name.
    default: return "Used a tool"
    }
  }
}

/// The small bubble on an agent's tab once its run ends.
public struct TabBubble: Equatable {
  public enum Kind: String { case done, waiting, stuck, stopped }
  public var kind: Kind
  public var text: String
  public static let wordLimit = 30
  public init(kind: Kind, text: String) {
    self.kind = kind
    self.text = text
  }
  public var title: String {
    switch kind {
    case .done: return "Done"
    case .waiting: return "Needs you"
    case .stuck: return "Could not finish"
    case .stopped: return "Stopped"
    }
  }
  /// Builds the bubble from the agent's finish call, then the run's outcome classifier, then fallback copy.
  public static func make(outcome: String?, summary: String?, classified: String? = nil)
    -> TabBubble
  {
    // A finish call may still say the old words (needs_user, failed).
    let kind = Kind(rawValue: outcome == "needs_user" ? "waiting" : outcome ?? "")
      ?? RunRecord.Outcome(reported: outcome ?? "").flatMap { Kind(rawValue: $0.rawValue) } ?? .stopped
    let fallback: String
    switch kind {
    case .done: fallback = "The task is done."
    case .waiting: fallback = "The agent needs you in this tab."
    case .stuck: fallback = "The task could not be done."
    case .stopped: fallback = "The agent stopped before finishing."
    }
    let source = [summary, classified].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
    return TabBubble(kind: kind, text: clip(source ?? fallback))
  }
  public static func clip(_ text: String, words limit: Int = wordLimit) -> String {
    let words = text.split(whereSeparator: { $0.isWhitespace })
    guard words.count > limit else { return words.joined(separator: " ") }
    return words.prefix(limit).joined(separator: " ") + "…"
  }
}

/// Serein's guide for agents working on the web, appended to the run's system prompt.
public enum WebTaskPrompt {
  public static func text(isolated: Bool, actions: Bool, fastSteps: Bool = false, repl: Bool = false) -> String {
    // A task that is not isolated still has a store of its own, empty when it starts (TaskStores).
    let tabs =
      isolated
      ? "Your tabs are isolated: no cookies, no sign-ins, nothing is saved. If a site needs the user to be signed in, do every part that works signed out first, then take another route that needs no sign-in, or finish stuck with signing in as the next action."
      : "Your tabs have a cookie store of their own and start signed out, even on a page the user had open. A site sees the user only after the user signs in there or approves a kept sign-in. If a site needs the user to be signed in, do every part that works signed out first, then sign in through Serein's tool as below; only when that cannot go through, take another route, or finish stuck with signing in as the next action and that tab as result_tab."
    return """
      Web task guide.
      You work in browser tabs the user can watch in Serein's sidebar and take over at any time. \(tabs)
      Keep going until the task is done. Do not stop to report progress or to ask whether to continue.
      How to work: read a tab before acting and use element refs from the latest result. Every action and navigation returns the page after it with new refs, so read again only for more text or a frame. Use wait while a page is still loading or searching. Use screenshot only when the text does not explain the page, such as a map, chart or seat plan. Keep to at most \(AgentTabPolicy.maxTabs) tabs and close tabs you no longer need. If one way is blocked, try another before giving up.\(actions ? "" : " Clicks and typing are off for this task: research only.")\(fastSteps ? " Fast steps: when the next steps on a page are clear (search, fill a form, open a result, set filters, move through pages), hand them to the do tool with the goal, the values to type and what the finished page shows. It is much faster than clicking yourself. Act yourself when the page needs judgement or do returns NEEDS_AGENT." : "")\(repl ? " repl: when you know the next steps, write them as one repl program (fill every field, submit, open results, page through and log only what you need) instead of one tool call per step. Elements are found by their visible words, so when the request names the site and the steps, act in your first program: open the page, do the steps and log only what the answer needs. A missing element returns the page's elements. Each repl result names its tab; pass it to finish as result_tab." : "")
      Never solve CAPTCHAs and never choose files yourself; the one exception is upload, which puts a document the user attached to this message into a file field after the user allows it, and never any other file. When a tool answers "This step is yours", carry on with every other part.
      Go through with ordering, booking, sending, posting or deleting when the task calls for it; do not stop to ask first. When a step needs the user's OK, Serein shows them a card itself; carry on with their answer.
      Scout first: read the pages the task needs and note every choice it involves before you act. A read lists each group of options under choices, with the current pick in [brackets] and options that unlock after an earlier choice marked (locked).
      Choose sensible defaults and state them: one traveller, economy, the best-known site, the cheapest reasonable option.
      When the user's words do not match an option exactly, take the nearest one and say so, for example white as Silver. When the difference changes the model or the price, or the item is no longer sold, say so in your answer and take the closest match.
      If a cookie or consent banner covers the page, press its reject or necessary-only button and go on. If a click says the element is covered by something, close or move that first.
      \(CollectedTablePrompt.table)
      Always end the same way: write your answer for the user, then call finish once in that same message with done or stuck, and the tab the user should see as result_tab.
      """
  }
}
