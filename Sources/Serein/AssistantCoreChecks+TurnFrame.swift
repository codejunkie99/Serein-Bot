#if DEBUG
import SereinCore

/// Per-turn frames (TurnFrame.swift): a tool call resolves the frame of the thread its call came
/// from, as `RelayToolHost.frame` does, and frames on two threads stay apart. Synthetic data only.
extension AssistantCoreChecks {
  static func turnFrame(_ check: Check) throws {
    let person = TurnFrame(thread: "chat-a", serial: 1, admission: .person, unattended: false,
                           personWords: "Make an assistant for my inbox", readOutside: false)
    let routine = TurnFrame(thread: "chat-b", serial: 2, admission: .unattended, unattended: true,
                            personWords: "Make an assistant for my inbox", readOutside: true)
    let none = TurnFrame(thread: "none", serial: 0, admission: .assistant, unattended: false, personWords: nil, readOutside: false)
    var book = TurnFrames()
    book.begin(person)
    book.begin(routine)
    func called(from thread: String?) -> TurnFrame {
      TurnFrame.$callingThread.withValue(thread) { book.frame(for: TurnFrame.callingThread, none: none) }
    }

    try check(called(from: "chat-a") == person && called(from: "chat-b") == routine,
      "turn frame: a tool call reads the frame of the thread it came from")
    try check(called(from: "chat-c") == none && called(from: nil) == none,
      "turn frame: a call from a thread with no running turn never reads another thread's frame")
    try check(called(from: "chat-a").typedWords == "Make an assistant for my inbox" && called(from: "chat-b").typedWords.isEmpty,
      "turn frame: the person's words count only in the turn they started")
    try check(called(from: "chat-a").byPerson && !called(from: "chat-b").byPerson && called(from: "chat-b").unattended,
      "turn frame: two running turns each keep their own trust")

    book.noteReadOutside("chat-a")
    try check(book["chat-a"]?.readOutside == true && book["chat-b"] == routine,
      "turn frame: outside text one turn reads does not mark the other")
    book.end("chat-b")
    try check(book["chat-a"]?.readOutside == true && book["chat-b"] == nil,
      "turn frame: one turn ending leaves the other's frame")

    // The run's end clears it whatever its outcome (`ended`, done, failed or stopped).
    book.end("chat-a")
    try check(book["chat-a"] == nil, "turn frame: the run's end clears its frame")
    // The start failed before a run existed (`turn`'s catch, a scheduled turn that did not start).
    book.begin(person)
    book.end("chat-a", serial: person.serial)
    try check(book["chat-a"] == nil, "turn frame: a start that failed clears its own frame")
    // Stop Everything moved a scheduled turn before it started, and a new turn began on its thread.
    let next = TurnFrame(thread: "chat-a", serial: 3, admission: .person, unattended: false, personWords: "Hi", readOutside: false)
    book.begin(next)
    book.end("chat-a", serial: person.serial)
    try check(book["chat-a"] == next, "turn frame: a stopped start's late end leaves the newer turn's frame")
    book.end("chat-a")
    book.end("chat-a")
    try check(book["chat-a"] == nil, "turn frame: ending a turn twice is a no-op")
  }
}
#endif
