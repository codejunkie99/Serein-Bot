#if DEBUG
import Foundation
import SereinCore

/// The voice pill (VoicePill.swift): its phases, its wave, and what happens to the words.
extension AssistantCoreChecks {
  static func voicePill(_ check: Check) throws {
    var pill = VoicePill()
    try check(!pill.shown && pill.end(heard: "hello", chatInFront: false) == .drop,
      "A pill that never showed sends nothing")

    pill.begin(latched: false)
    try check(pill.phase == .waiting && pill.levels.allSatisfy { $0 == 0 }, "A hold shows the pill with a still wave")
    pill.hear(0.9)
    try check(pill.levels.allSatisfy { $0 == 0 }, "The wave holds still until the microphone opens")
    pill.micOpened()
    try check(pill.phase == .listening, "The open microphone makes the pill listen")
    pill.hear(1)
    pill.hear(0)
    let eased = pill.levels.last ?? 0
    try check(pill.levels.count == VoicePill.barCount && pill.levels[VoicePill.barCount - 2] == 1 && eased > 0 && eased < 1,
      "The wave rises at once with the voice and eases down after it")
    for _ in 0..<100 { pill.hear(.nan) }
    try check(pill.levels.count == VoicePill.barCount && pill.levels.allSatisfy { $0 >= 0 && $0 <= 1 },
      "The wave keeps its bars and stays in range whatever the microphone reads")

    pill.release()
    try check(pill.phase == .sending && pill.shown, "Letting go keeps the pill while the words are finished")
    pill.hear(1)
    try check(pill.levels.allSatisfy { $0 == 0 }, "A reading after the release never moves the wave")
    try check(pill.end(heard: "  Book a table for two \n", chatInFront: false) == .send("Book a table for two", reply: .bar),
      "The words go to Serein, trimmed, with the reply under the bar over another app")
    try check(!pill.shown && pill.end(heard: "Book a table for two", chatInFront: false) == .drop,
      "The pill ends once: a second end sends nothing")

    pill.begin(latched: true)
    pill.micOpened()
    try check(pill.latched, "The menu bar button starts a pill that takes a click to end")
    pill.release()
    try check(pill.end(heard: "What is on today", chatInFront: true) == .send("What is on today", reply: .chat) && !pill.latched,
      "With Serein's chat in front the reply streams there")

    pill.begin(latched: false)
    pill.micOpened()
    pill.release()
    try check(pill.end(heard: " \n ", chatInFront: false) == .drop && !pill.shown, "Silence sends nothing and the pill goes")

    pill.begin(latched: false)
    pill.micOpened()
    pill.hear(0.5)
    pill.cancel()
    try check(!pill.shown && pill.levels.allSatisfy { $0 == 0 } && pill.end(heard: "never sent", chatInFront: false) == .drop,
      "A cancelled hold sends nothing")
  }
}
#endif
