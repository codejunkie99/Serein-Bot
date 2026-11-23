#if DEBUG
import Foundation
import SereinCore

extension AssistantCoreChecks {
  static func draftQuote(_ check: Check) throws {
    try check(DraftQuote.draft(quoting: "Booked the 9:40\nferry.", before: "") == "> Booked the 9:40 ferry.\n\n",
      "Reply quotes the message on one line, then leaves room for the person's words")
    try check(DraftQuote.draft(quoting: "Booked.", before: "is it refundable?") == "> Booked.\n\nis it refundable?",
      "Words already in the draft follow the quote")
    try check(DraftQuote.draft(quoting: "Second.", before: "> First.\n\nmine") == "> Second.\n\nmine",
      "Replying again swaps the quote and keeps the person's words")
    let long = DraftQuote.draft(quoting: String(repeating: "a", count: 400), before: "")
    try check(long.count == DraftQuote.limit + 4 && long.contains("…"), "A long message is cut in the quote")
    try check(DraftQuote.draft(quoting: "Found it:\n```swift\nlet a = 1\n```\nOpen it?", before: "") == "> Found it: let a = 1 Open it?\n\n",
      "A quote leaves out code fence marks")
    try check(DraftQuote.draft(quoting: " \n ", before: "kept") == "kept", "An empty message changes nothing")
    // A sent reply draws its quote as a chip above the bubble.
    let sent = DraftQuote.draft(quoting: "Booked the 9:40 ferry.", before: "is it refundable?")
    try check(DraftQuote.split(sent)?.quote == "Booked the 9:40 ferry." && DraftQuote.split(sent)?.words == "is it refundable?",
      "A sent reply splits into the words it answered and the person's own")
    try check(DraftQuote.split("> just a quoted line") == nil && DraftQuote.split("plain words") == nil
      && DraftQuote.split("> quote\n\n   ") == nil && DraftQuote.split("> line one\nline two\n\nwords") == nil,
      "Only a one-line quote followed by words is a reply; anything else stays as it was written")
    try check(DraftQuote.oneLine("  first\n\n second  ") == "first second", "A quote shows on one line")
  }
}
#endif
