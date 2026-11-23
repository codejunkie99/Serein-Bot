import Foundation
import SereinCore

/// Sample views for `--ui-serein-ui <name>` and the checks, written as the JSON a model sends, so
/// each one goes through `UITree.parse` like a real `ui_show` call.
enum UITreeSamples {
  static let names: [String] = ["queue", "trip", "week"]

  static func tree(_ name: String) -> UITree? {
    guard let json = source[name], let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      case .success(let tree) = UITree.parse(object)
    else { return nil }
    return tree
  }
  static func asked(_ name: String) -> String {
    switch name {
    case "trip": return "How is the Lisbon budget looking?"
    case "week": return "How did my week go?"
    default: return "What are my agents doing?"
    }
  }

  static let source: [String: String] = ["queue": queue(), "queue-paused": queue(paused: true), "trip": trip, "week": week]
  /// The view a sample's answer draws after a press, and that answer's words (`--ui-serein-ui-pressed`).
  static func after(_ name: String) -> (tree: UITree, words: String)? {
    guard name == "queue", let tree = tree("queue-paused") else { return nil }
    return (tree, "Codex is paused. Its task keeps its place.")
  }

  /// affectUI's Agent Queue, rebuilt from blocks: the strip of counts, a tile for each agent with
  /// its state, progress and its own button, the queue's settings, what is next, and its depth.
  private static func queue(paused: Bool = false) -> String {
    """
    {"title": "Agent queue", "blocks": [
      {"type": "row", "children": [
        {"type": "stat", "label": "Running", "value": "\(paused ? 2 : 3)", "tone": "accent"},
        {"type": "stat", "label": "Queued", "value": "12", "trend": "up", "change": "4"},
        {"type": "stat", "label": "Done today", "value": "48", "trend": "up", "change": "6"},
        {"type": "stat", "label": "Failed", "value": "1", "tone": "danger"}
      ]},
      {"type": "grid", "columns": 2, "children": [
        {"type": "card", "title": "Codex", "children": [
          {"type": "badge", "text": "\(paused ? "Paused" : "Running")", "tone": "\(paused ? "warning" : "success")", "dot": true},
          {"type": "text", "text": "Fix the flaky checkout test"},
          {"type": "progress", "label": "Step 4 of 6", "percent": 66, "detail": "\(paused ? "Paused" : "2 min left")"},
          {"type": "button", "label": "\(paused ? "Resume Codex" : "Pause Codex")"}
        ]},
        {"type": "card", "title": "Claude", "children": [
          {"type": "badge", "text": "Running", "tone": "success", "dot": true},
          {"type": "text", "text": "Draft the release notes"},
          {"type": "progress", "label": "Step 2 of 5", "percent": 40, "detail": "6 min left"},
          {"type": "button", "label": "Pause Claude"}
        ]},
        {"type": "card", "title": "Gemini", "children": [
          {"type": "badge", "text": "Waiting on you", "tone": "warning", "dot": true},
          {"type": "text", "text": "Send the invoice reminder"},
          {"type": "text", "text": "Needs a yes before it sends mail", "style": "meta"},
          {"type": "row", "children": [
            {"type": "button", "label": "Send the reminder", "style": "primary"},
            {"type": "button", "label": "Skip it"}
          ]}
        ]},
        {"type": "card", "title": "Pi", "children": [
          {"type": "badge", "text": "Failed", "tone": "danger", "dot": true},
          {"type": "text", "text": "Rename the photo folders"},
          {"type": "text", "text": "The drive was unplugged at step 3", "style": "meta"},
          {"type": "button", "label": "Retry Pi"}
        ]}
      ]},
      {"type": "card", "title": "Queue settings", "children": [
        {"type": "stepper", "label": "Agents at once", "number": 3, "min": 1, "max": 6},
        {"type": "toggle", "label": "Keep working while I'm away", "on": true},
        {"type": "button", "label": "Apply the settings"}
      ]},
      {"type": "text", "text": "Up next", "style": "meta"},
      {"type": "list", "marker": "number", "items": [
        {"title": "Review the pull request", "detail": "Proactive mode, piece 1", "value": "Codex"},
        {"title": "Book the dentist", "detail": "Any morning next week", "value": "Claude"},
        {"title": "Tidy the Downloads folder", "value": "Pi"}
      ]},
      {"type": "divider"},
      {"type": "chart", "chart": {"kind": "line", "title": "Queue depth today", "labels": ["9", "10", "11", "12", "13", "14"],
        "series": [{"name": "Queued", "values": [4, 7, 9, 14, 12, 12]}], "unit": "tasks"}}
    ]}
    """
  }

  private static let trip: String = """
    {"title": "Lisbon, 4 nights", "blocks": [
      {"type": "row", "children": [
        {"type": "stat", "label": "Budget", "value": "$2,400"},
        {"type": "stat", "label": "Spent", "value": "$1,310", "trend": "up", "change": "$180"},
        {"type": "stat", "label": "Left", "value": "$1,090", "tone": "success"}
      ]},
      {"type": "card", "title": "By category", "children": [
        {"type": "progress", "label": "Flights", "percent": 92, "detail": "$640 of $700"},
        {"type": "progress", "label": "Hotel", "percent": 58, "detail": "$520 of $900"},
        {"type": "progress", "label": "Food", "percent": 25, "detail": "$150 of $600"}
      ]},
      {"type": "table", "headers": ["Booking", "When", "Cost"], "rows": [
        ["TAP 1362, London to Lisbon", "Thu 9:40", "$320"],
        ["Hotel Lumiares", "Thu to Mon", "$520"],
        ["TAP 1357, Lisbon to London", "Mon 18:05", "$320"]
      ]},
      {"type": "row", "children": [
        {"type": "badge", "text": "Flights confirmed", "tone": "success", "dot": true},
        {"type": "badge", "text": "Hotel not paid yet", "tone": "warning", "dot": true}
      ]},
      {"type": "text", "text": "Prices are from your confirmation mails on 12 November.", "style": "meta"},
      {"type": "card", "title": "Change the stay", "children": [
        {"type": "choice", "label": "Room", "options": ["Classic", "Deluxe", "Suite"], "selected": "Deluxe"},
        {"type": "stepper", "label": "Nights", "number": 4, "min": 1, "max": 14},
        {"type": "toggle", "label": "Breakfast"},
        {"type": "input", "label": "Note for the hotel", "placeholder": "Late arrival, a quiet room"},
        {"type": "row", "children": [
          {"type": "button", "label": "Update the booking", "style": "primary"},
          {"type": "button", "label": "Leave it as it is"}
        ]}
      ]}
    ]}
    """

  private static let week: String = """
    {"title": "Your week", "blocks": [
      {"type": "text", "text": "A steady week", "style": "title"},
      {"type": "text", "text": "Most of the deep work landed on Tuesday and Thursday. Friday went to meetings."},
      {"type": "row", "children": [
        {"type": "stat", "label": "Focus time", "value": "21 h", "trend": "up", "change": "3 h"},
        {"type": "stat", "label": "Meetings", "value": "9", "trend": "down", "change": "2"},
        {"type": "stat", "label": "Tasks done", "value": "34", "trend": "flat", "change": "same"}
      ]},
      {"type": "chart", "chart": {"kind": "bar", "title": "Focus hours", "labels": ["Mon", "Tue", "Wed", "Thu", "Fri"],
        "series": [{"name": "This week", "values": [3.5, 6, 4, 5.5, 2]}, {"name": "Last week", "values": [4, 3, 4.5, 3.5, 3]}], "unit": "h"}},
      {"type": "row", "children": [
        {"type": "column", "children": [
          {"type": "text", "text": "Done", "style": "meta"},
          {"type": "list", "items": [
            {"title": "Shipped the key card", "detail": "Merged on Tuesday", "tone": "success"},
            {"title": "Cleared the inbox", "detail": "Twice", "tone": "success"}
          ]}
        ]},
        {"type": "column", "children": [
          {"type": "text", "text": "Still open", "style": "meta"},
          {"type": "list", "items": [
            {"title": "Onboarding copy", "detail": "Waiting on Maya's review", "tone": "warning"},
            {"title": "Billing page", "detail": "Not started", "tone": "danger"}
          ]}
        ]}
      ]}
    ]}
    """
}
