/// Things to ask Serein with each connected app, shown as buttons in the Marketplace (Your apps, On this Mac) and in
/// a new chat. A click sends the words as the person's own message, so every step that sends,
/// changes or deletes still asks on its card. Most ideas only read, and none needs editing first
/// (no made-up names, dates or places).
public enum IntegrationIdeas {
  /// The apps in the order a new chat offers them: the Mac's own first, then online apps.
  public static let order = [
    "mail", "calendar", "reminders", "notes", "contacts", "messages",
    "gmail", "googlecalendar", "slack", "notion", "github", "outlook",
  ]

  /// Ideas for one app, by its id: a Mac connection ("mail", "calendar") or a Composio app slug
  /// ("gmail", "slack"). An app with no list of its own gets none.
  public static func ideas(for app: String) -> [String] {
    switch app.lowercased() {
    case "mail":
      return ["Summarize my unread email from today", "Find emails I haven't answered this week", "Draft a reply to my latest email"]
    case "messages":
      // Reading Messages is a switch of its own, so only a send (which asks) is offered.
      return ["Text a contact that I'm running 10 minutes late"]
    case "calendar":
      return ["What's on my calendar today?", "Find a free hour this week", "What's my next meeting?"]
    case "reminders":
      return ["What's due today?", "Which reminders are overdue?"]
    case "contacts":
      return ["Whose birthday is coming up?", "Which contacts have no email address?"]
    case "notes":
      return ["Summarize my most recent note", "Make a note of today's calendar"]
    case "gmail":
      return ["Summarize my unread Gmail", "Find receipts in Gmail from this month"]
    case "googlecalendar":
      return ["What's on my Google Calendar this week?", "When am I free tomorrow afternoon?"]
    case "slack":
      return ["Catch me up on my Slack mentions today", "Summarize the busiest Slack channel today"]
    case "notion":
      return ["Search Notion for this week's meeting notes", "List the Notion pages I edited recently"]
    case "github":
      return ["List pull requests waiting for my review", "What issues were assigned to me this week?"]
    case "outlook":
      return ["Summarize my unread Outlook email", "What meetings do I have in Outlook today?"]
    default:
      return []
    }
  }

  /// A new chat's ideas for the apps that are on: one from each app in `order`, then a second
  /// from each, until `limit`.
  public static func pick(connected: Set<String>, limit: Int) -> [(app: String, text: String)] {
    let apps: [String] = order.filter { connected.contains($0) }
    var picked: [(app: String, text: String)] = []
    var round = 0
    while picked.count < limit {
      var added = false
      for app in apps where picked.count < limit {
        let list: [String] = ideas(for: app)
        if round < list.count {
          picked.append((app: app, text: list[round]))
          added = true
        }
      }
      if !added { break }
      round += 1
    }
    return picked
  }
}
