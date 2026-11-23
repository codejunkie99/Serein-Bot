#if DEBUG
import Foundation
import SereinCore

extension AssistantCoreChecks {
  static func chatSearch(_ check: Check) throws {
    func message(_ id: String, _ text: String, person: Bool = true, days: Double = 0) -> ChatSearch.Message {
      ChatSearch.Message(id: id, fromPerson: person, text: text, sentAt: Date(timeIntervalSince1970: 1_800_000_000 + days * 86_400))
    }
    let chats = [
      ChatSearch.Chat(id: "trip", title: "Lisbon", assistant: "Serein", messages: [
        message("t1", "We booked the Lisbon flight for Friday the 14th."),
        message("t2", "Your hotel in Alfama is confirmed.", person: false, days: 1),
      ]),
      ChatSearch.Chat(id: "work", title: "Invoices", assistant: "Planner", messages: [
        message("w1", "Send the invoice to Ana before Friday.", days: 2),
        message("w2", "東京の会議は火曜日です。", days: 3),
      ]),
    ]
    try check(ChatSearch.terms("What did we say about the Lisbon flight?") == ["say", "lisbon", "flight"], "Question words are not terms")
    try check(ChatSearch.search("lisbon flight", in: chats).first?.message == "t1", "The message holding every term comes first")
    try check(ChatSearch.search("flights", in: chats).isEmpty && ChatSearch.search("fli", in: chats).first?.message == "t1",
      "A term matches the words it starts")
    try check(ChatSearch.search("ALFAMA hôtel", in: chats).first?.message == "t2", "Case and accents do not matter")
    let friday = ChatSearch.search("friday", in: chats).map(\.message)
    try check(friday == ["w1", "t1"], "Equal matches put the newest first")
    try check(ChatSearch.search("invoice lisbon unicorn", in: chats).isEmpty, "A message needs at least half of the terms")
    try check(ChatSearch.search("会議", in: chats).first?.message == "w2", "Unspaced scripts match inside words")
    try check(ChatSearch.search("the what", in: chats).isEmpty, "A query of question words finds nothing")
    try check(ChatSearch.search("friday", in: chats, limit: 1).count == 1, "The limit holds")
    let long = String(repeating: "filler ", count: 80) + "the Alfama key code" + String(repeating: " more", count: 80)
    let cut = ChatSearch.snippet(long, query: "alfama")
    try check(cut.count <= ChatSearch.snippetWidth + 2 && cut.contains("Alfama") && cut.hasPrefix("…") && cut.hasSuffix("…"),
      "A long message is cut around the match")
    try check(ChatSearch.snippet("Short\nreply", query: "reply") == "Short reply", "A short message is kept whole on one line")
    // The cut lands inside the key, past the "sk-proj-" that marks it as one.
    let key = "sk-proj-" + String(repeating: "A1b2", count: 20)
    let secret = ChatSearch.snippet(
      String(repeating: "filler ", count: 80) + key + " opens the Alfama door" + String(repeating: " more", count: 80), query: "alfama")
    try check(secret.contains("Alfama") && !secret.contains("A1b2"), "A key the cut would split is not shown")
  }
}
#endif
