#if DEBUG
import Foundation
import SereinCore

/// What the ⌥Space bar does once a message has gone (BarWork.swift): when it steps aside, and what
/// the one notification may say. Synthetic turns only.
extension AssistantCoreChecks {
  static func barWork(_ check: Check) throws {
    typealias B = BarWork
    func aside(
      before: Int = 0, now: Int = 0, working: Bool = true, waits: Bool = false, busy: Bool = false, canNotify: Bool = true
    ) -> Bool {
      B.stepsAside(wordsBefore: before, wordsNow: now, working: working, waitsOnPerson: waits, personBusy: busy, canNotify: canNotify)
    }

    let laptop = RelayController.hologramSize(screenHeight: 820)
    try check(
      laptop == NSSize(width: 400, height: 230) && RelayController.hologramSize(screenHeight: 600) == laptop,
      "The hologram is 400 by 230 on a laptop and no smaller on a shorter screen")
    try check(
      RelayController.hologramSize(screenHeight: 1025) == NSSize(width: 500, height: 288),
      "The hologram grows in step with a taller screen")
    try check(
      RelayController.hologramSize(screenHeight: 2000) == NSSize(width: 600, height: 345),
      "The hologram stops at half again its laptop size")
    let ink = AppearanceScheme.hologramInk
    try check(
      ink(true, false, true) && !ink(false, true, true),
      "The ⌥Space hologram is ink on a light Mac and light on a dark Mac, whatever Serein's own theme")
    try check(
      !ink(true, false, false) && ink(false, true, false),
      "A hologram in Serein's own window follows Serein's theme")
    try check(B.patience == 5, "The bar waits five seconds for a quick answer")
    try check(aside(), "No words after the wait: the bar steps aside")
    try check(!aside(working: false), "The answer came: the bar stays and shows it")
    try check(!aside(now: 40), "Words still arriving: the bar stays while they're being read")
    try check(aside(before: 40, now: 40), "Words that stopped arriving mean work: the bar steps aside")
    try check(!aside(waits: true), "An approval or question keeps the bar up")
    try check(!aside(busy: true), "Someone writing or talking in the bar keeps it up")
    try check(!aside(canNotify: false), "With no way to tell the person, the bar never hides the answer")

    let reply = "Your flight lands at 4 pm."
    func notice(_ ending: B.Ending, reply text: String? = reply, personal: Bool = false) -> B.Notice? {
      B.notice(name: "Serein", ending: ending, reply: text, readPersonal: personal)
    }
    try check(notice(.finished) == B.Notice(title: "Serein", body: reply), "A finished turn says its result in one line")
    try check(notice(.finished, personal: true)?.body == B.finished, "A chat that read personal data never shows its words")
    try check(notice(.failed, personal: true)?.body == B.failed, "A failure says so, and never shows personal words")
    try check(notice(.finished, reply: nil)?.body == B.finished, "No words: it just says finished")
    try check(notice(.finished, reply: "  \n ")?.body == B.finished, "Blank words: it just says finished")
    try check(notice(.stopped) == nil, "The person stopped it: nothing to tell them")
    let long = String(repeating: "word ", count: 200)
    try check((notice(.finished, reply: long)?.body.count ?? .max) <= B.bodyLimit, "A long result is cut to one short line")
    try check(notice(.finished, reply: "  \(reply)\n")?.body == reply, "Spaces around the result are dropped")
  }

  /// Check-ins wait for setup, without holding back an install set up before this chat existed.
  static func setupHoldsCheckIns(_ check: Check) throws {
    var setup = SereinChatSetupState()
    try check(setup.holdsCheckIns(firstRunFinished: false), "A new install has no check-ins before setup starts")
    try check(!setup.holdsCheckIns(firstRunFinished: true), "An install set up earlier, with no record here, keeps its check-ins")
    setup.begin(in: "setup-thread")
    try check(setup.holdsCheckIns(firstRunFinished: true), "Setup under way holds check-ins, whatever came before")
    setup.skip(in: "setup-thread")
    try check(setup.phase == .skipped && setup.holdsCheckIns(firstRunFinished: true), "“Not now” isn't a yes to check-ins")
    var done = SereinChatSetupState()
    done.begin(in: "done-thread")
    done.selectPersonName("Sam", in: "done-thread")
    done.selectHarness(.claude, in: "done-thread", needsConnection: false)
    done.complete(model: "", in: "done-thread")
    done.answerAbout(in: "done-thread")
    try check(done.phase == .complete && !done.holdsCheckIns(firstRunFinished: false), "Finished setup lets check-ins go")
  }

  /// Setup calls the person by their Mac account's name instead of asking, when it is a name.
  static func setupName(_ check: Check) throws {
    typealias S = SereinChatSetupState
    try check(S.likelyName(fullName: "Ziwen Xu") == "Ziwen", "A full name gives its first name")
    try check(S.likelyName(fullName: "  Ana  ") == "Ana", "One capitalized name is taken as it is")
    try check(S.likelyName(fullName: "Mary-Jane O'Neil") == "Mary-Jane", "A hyphenated first name stays whole")
    try check(S.likelyName(fullName: "ziwenxu") == nil, "A lower-case login name is not what the person goes by")
    try check(S.likelyName(fullName: "user123") == nil && S.likelyName(fullName: "") == nil, "Digits or nothing: setup asks")
    try check(S.likelyName(fullName: "José García") == "José", "Accented letters are a name too")
  }
}
#endif
