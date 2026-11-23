#if DEBUG
import Foundation
import SereinCore

/// A reply as text messages (ChatBubbles.swift): where it splits, what stays whole, and that no
/// word is lost.
extension AssistantCoreChecks {
  static func bubbles(_ check: Check) throws {
    typealias B = ChatBubbles
    let kinds = { (text: String) in B.split(text).map(\.kind) }
    let words = { (text: String) in B.split(text).map(\.text) }

    try check(B.split("").isEmpty && B.split(" \n\n ").isEmpty, "An empty reply has no bubbles")
    try check(words("hey") == ["hey"] && kinds("hey") == [.words], "One thought is one bubble")
    try check(words("found it\n\nwant me to book?") == ["found it", "want me to book?"], "A blank line starts a new bubble")
    try check(words("found it\r\n\r\nwant me to book?") == ["found it", "want me to book?"], "Windows line endings split the same")
    try check(words("line one\nline two") == ["line one\nline two"], "A single line break stays in its bubble")
    try check(words("a\n\n\n\nb") == ["a", "b"], "Extra blank lines make no empty bubble")

    let code = "here you go\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nthat's it"
    try check(kinds(code) == [.words, .document, .words], "Code sits between bubbles, in the column")
    try check(words(code)[1] == "```swift\nlet a = 1\n\nlet b = 2\n```", "A blank line inside code keeps the code whole")
    let open = "one sec\n\n```\nstill\n\nstreaming"
    try check(kinds(open) == [.words, .document] && words(open)[1] == "```\nstill\n\nstreaming",
              "A fence still streaming stays one piece")
    try check(kinds("```\n# not a heading\n```\n\nok") == [.document, .words], "A hash inside code is not a heading")

    let table = "| a | b |\n| - | - |\n| 1 | 2 |"
    try check(kinds(table) == [.document], "A table keeps the column")
    try check(kinds("a | b\n--- | ---\n1 | 2") == [.document], "So does one without outer pipes")
    try check(kinds("![chart](a.png)") == [.document], "A picture keeps the column")
    try check(kinds("this | that are both fine") == [.words], "A pipe in a sentence is still words")

    try check(words("- one\n\n- two\n\n- three") == ["- one\n\n- two\n\n- three"], "A spaced-out list is one bubble")
    try check(words("1. one\n\n   more\n\n2. two") == ["1. one\n\n   more\n\n2. two"], "Indented lines stay under their item")
    try check(words("three things:\n\n- one\n- two") == ["three things:", "- one\n- two"], "A lead-in is its own bubble")

    let report = "# Report\n\nFirst part.\n\nSecond part."
    try check(words(report) == [report] && kinds(report) == [.document], "A reply with headings stays whole")
    try check(kinds("#hashtag\n\nok") == [.words, .words], "A hashtag is not a heading")
    let long = (1...(B.maxBubbles + 1)).map { "part \($0)" }.joined(separator: "\n\n")
    try check(words(long) == [long] && kinds(long) == [.words], "Too many short parts are one message, still in a bubble")
    let most = (1...B.maxBubbles).map { "part \($0)" }.joined(separator: "\n\n")
    try check(B.split(most).count == B.maxBubbles, "Up to the limit each part is a bubble")
    try check(B.split(most).map(\.id) == Array(0..<B.maxBubbles), "Pieces are numbered in order")

    let mixed = "hey **you**\n\n- a\n- b\n\n> quoted\n\n```\nx\n```\n\nbye"
    let squeezed = { (text: String) in text.filter { !$0.isWhitespace } }
    try check(squeezed(words(mixed).joined()) == squeezed(mixed), "Every word stays, in order")

    // Reply tags.
    let burst = B.split("[reply 1] Booked.\n\n[reply 3] Done.\n\nAnything else?")
    try check(burst.map(\.text) == ["Booked.", "Done.", "Anything else?"], "A tag leaves the words")
    try check(burst.map(\.replyTag) == [1, 3, nil], "A tag rides on its bubble")
    try check(B.split("[reply 2]\nOn its own line").first?.replyTag == 2, "A tag may sit on a line of its own")
    try check(B.split("[REPLY 2] Loud").first?.replyTag == 2, "A tag is read in any case")
    try check(B.split("hey [reply 2] there").first?.replyTag == nil && words("hey [reply 2] there") == ["hey [reply 2] there"],
              "A tag only counts at the start of a paragraph")
    try check(words("```\n[reply 1] code\n```") == ["```\n[reply 1] code\n```"], "A tag inside code stays code")
    try check(words("[reply x] hi") == ["[reply x] hi"] && words("[reply 123] hi") == ["[reply 123] hi"] && words("[reply 0] hi") == ["[reply 0] hi"],
              "Anything else in brackets stays as written")
    let lists = B.split("[reply 1] - a\n\n[reply 2] - b")
    try check(lists.map(\.text) == ["- a", "- b"], "Tagged list items stay apart")
    let tagDocument = B.split("[reply 2] # Report\n\nFirst part.")
    try check(tagDocument.count == 1 && tagDocument[0].replyTag == 2 && !tagDocument[0].text.contains("[reply"), "A document loses its tag too")
    try check(B.plain("[reply 1] One\n\n[reply 2] Two") == "One\n\nTwo", "Plain words have no tags")
    let saved = B.tagged("[reply 2] Two\n\nmore\n\n[reply 1] One")
    try check(saved.text == "Two\n\nmore\n\nOne" && saved.tags == [0: 2, 2: 1], "A saved reply keeps each bubble's tag apart from its words")
    let untouched = "  plain\n\n\nwords  "
    try check(B.tagged(untouched).text == untouched && B.tagged(untouched).tags.isEmpty, "Words with no tag are saved exactly as they were")
    try check(B.withoutPartialTag("Hi\n\n[rep") == "Hi\n" && B.withoutPartialTag("[reply 1") == "", "A tag still being written stays hidden")
    try check(B.withoutPartialTag("Hi\n[rep") == "Hi\n[rep" && B.withoutPartialTag("[reply 1] Hi") == "[reply 1] Hi", "Only an unfinished tag at a paragraph's start")

    let reverse = "[reply 3] Three\n\nmore three\n\n[reply 1] One\n\n[reply 2] Two"
    let ordered = B.ordered(reverse, replies: 3)
    try check(B.plain(ordered) == "One\n\nTwo\n\nThree\n\nmore three", "Answers sort by send order and keep their continuation paragraphs")
    try check(B.ordered("[reply 2] Two", replies: 2, streaming: true).isEmpty, "A later streaming answer waits for the first answer")
    try check(B.plain(B.ordered("[reply 2] Two", replies: 2)) == "Two", "A final answer is kept even when an earlier request needed no separate answer")
    let richOrdered = B.ordered("[reply 2] # Two\n\n```\n[reply 1] literal code\n```\n\n[reply 1] # One\n\nfirst", replies: 2)
    try check(B.plain(richOrdered).hasPrefix("# One\n\nfirst\n\n# Two") && B.plain(richOrdered).contains("[reply 1] literal code"), "Rich answers move whole; code is never parsed as an answer tag")
    try check(B.ordered(untouched, replies: 2) == untouched, "An untagged combined answer is unchanged")
    try check(B.plain(B.ordered("[reply 2] Two\n\n[reply 9] Other\n\n[reply 1] One", replies: 2)) == "Other\n\nOne\n\nTwo", "An unknown tag cannot push the latest answer out of last place")
    try check(B.tagged(richOrdered).tags.isEmpty, "Merged saved documents never receive a misleading per-piece quote")

    // The prompt for a burst.
    let one = RelaySteering.prompt(["  only  "])
    try check(one == "only", "A lone message goes as it is, with no tags")
    let prompt = RelaySteering.prompt(["first", " ", "second"])
    try check(prompt.contains("[1] first\n[2] second") && prompt.contains("[reply 2]") && prompt.contains("oldest first and newest last"), "A burst numbers its messages and asks for tags")

    // Who has read what.
    typealias R = ChatReading
    let you = R.Entry(id: "y", isReply: false, hasOutput: true)
    let blank = R.Entry(id: "b", isReply: true, hasOutput: false)
    let a = R.Entry(id: "a", isReply: true, hasOutput: true)
    let c = R.Entry(id: "c", isReply: true, hasOutput: true)
    try check(!R.personSeen(after: []) && !R.personSeen(after: [blank]) && !R.personSeen(after: [you]), "A message is only sent until an answer begins")
    try check(R.personSeen(after: [blank, a]), "An answer begun means seen")
    try check(R.unread([], mark: nil) == (nil, nil), "An empty chat has nothing unread")
    let fresh = R.unread([you, a], mark: nil)
    try check(fresh.first == nil && fresh.mark == "a", "A chat with no mark counts as read")
    let gone = R.unread([you, a], mark: "left")
    try check(gone.first == nil && gone.mark == "a", "A mark that left the chat counts as read")
    let away = R.unread([a, you, blank, c], mark: "a")
    try check(away.first == "c" && away.mark == "c", "The first reply after the mark is unread")
    let caught = R.unread([a, you], mark: "a")
    try check(caught.first == nil && caught.mark == "a", "Nothing new, nothing unread")
    let waiting = R.unread([a, blank], mark: "a")
    try check(waiting.first == nil && waiting.mark == "a", "A reply with no words yet is not unread")
  }
}
#endif
