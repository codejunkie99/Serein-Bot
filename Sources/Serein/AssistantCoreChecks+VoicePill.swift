#if DEBUG
import Foundation
import SereinCore

/// The voice pill (VoicePill.swift): its phases, how its mark moves, and what happens to the words.
extension AssistantCoreChecks {
  static func voicePill(_ check: Check) throws {
    var pill = VoicePill()
    try check(!pill.shown && pill.end(heard: "hello") == .drop, "A pill that never grew sends nothing")

    pill.begin(latched: false)
    try check(pill.phase == .waiting && pill.level == 0 && pill.turn == 0, "A hold grows the pill with the mark still")
    pill.hear(0.9)
    try check(pill.level == 0 && pill.turn == 0, "The mark holds still until the microphone opens")
    pill.micOpened()
    try check(pill.phase == .listening, "The open microphone makes the pill listen")
    pill.hear(1)
    try check(pill.level == 1, "The mark swells at once with the voice")
    pill.hear(0)
    try check(pill.level > 0 && pill.level < 1, "The swell eases down after the voice")

    var rested = pill
    for _ in 0..<40 { rested.hear(0) }
    var quiet = rested
    var loud = rested
    let start = rested.turn
    for _ in 0..<10 {
      quiet.hear(0.05)
      loud.hear(0.9)
    }
    try check(quiet.turn > start && loud.turn - start > (quiet.turn - start) * 3,
      "The orbits always turn while listening, and a louder voice turns them faster")
    let before = pill.turn
    for _ in 0..<100 { pill.hear(.nan) }
    try check(pill.level >= 0 && pill.level <= 1 && pill.turn >= before,
      "The swell stays in range and the spin never runs backwards, whatever the microphone reads")

    pill.release()
    try check(pill.phase == .sending && pill.shown && pill.level == 0, "Letting go keeps the pill while the words are finished")
    let settled = pill.turn
    pill.hear(1)
    try check(pill.level == 0 && pill.turn == settled, "A reading after the release moves nothing")
    try check(pill.end(heard: "  Book a table for two \n") == .send("Book a table for two") && !pill.shown,
      "The words go to Serein trimmed, and the pill goes back to rest")
    try check(!pill.shown && pill.end(heard: "Book a table for two") == .drop,
      "The pill ends once: a second end sends nothing")

    pill.begin(latched: true)
    pill.micOpened()
    try check(pill.latched, "The menu bar button starts a pill that takes a click to end")
    pill.release()
    try check(pill.end(heard: "What is on today") == .send("What is on today") && !pill.latched,
      "A click sends the button's words the way a release does")

    pill.begin(latched: false)
    pill.micOpened()
    pill.release()
    try check(pill.end(heard: " \n ") == .drop && !pill.shown, "Silence sends nothing and the pill goes back to rest")

    pill.begin(latched: false)
    pill.micOpened()
    pill.hear(0.5)
    pill.cancel()
    try check(!pill.shown && pill.level == 0 && pill.end(heard: "never sent") == .drop,
      "A cancelled hold, or a microphone that never opens, sends nothing")

    // The talk shortcut, recorded from a key press or set by chat (`talk_shortcut`, `talk_pill`).
    try check(RelayHotKey.text(keyCode: 49, modifiers: 0x800) == "opt+space"
      && RelayHotKey.text(keyCode: 40, modifiers: 0x1200) == "ctrl+shift+k" && RelayHotKey.text(keyCode: 96, modifiers: 0) == "f5",
      "A key pressed with its modifiers becomes the shortcut Serein listens for")
    try check(RelayHotKey.text(keyCode: 0, modifiers: 0) == nil && RelayHotKey.text(keyCode: 0, modifiers: 0x200) == nil
      && RelayHotKey.text(keyCode: 999, modifiers: 0x800) == nil,
      "A plain letter, a Shift letter or an unknown key is never taken as the shortcut")
    for code: UInt32 in [0, 49, 47, 122] {
      let text = RelayHotKey.text(keyCode: code, modifiers: 0x1800)
      try check(text.flatMap(RelayHotKey.parse) == RelayHotKey(keyCode: code, modifiers: 0x1800),
        "A recorded shortcut reads back as the same keys (\(text ?? "none"))")
    }
    try check(AgentSetting.talkShortcut.parse(" Ctrl + Shift + K ") as? String == "ctrl+shift+k"
      && AgentSetting.talkShortcut.parse("k") == nil && AgentSetting.talkShortcut.parse("shift+k") == nil,
      "Asking in the chat for a new talk shortcut takes a real shortcut and refuses a plain key")
    try check(AgentSetting.talkPill.parse("off") as? Bool == false && AgentSetting.talkPill.parse("on") as? Bool == true
      && AgentSetting.talkShortcut.page == "Relay" && AgentSetting.talkPill.page == "Relay"
      && !SettingsDenylist.refuses(AgentSetting.talkShortcut.rawValue) && !SettingsDenylist.refuses(AgentSetting.talkPill.rawValue)
      && !SettingsDenylist.refuses(RelayController.pillKey),
      "The chat can turn the pill off or on and change the shortcut, and Settings shows both on the Ask from any app page")

    // On by default, with Fn taken from macOS's own Globe action (GlobeConflict.takeover).
    let fresh = AssistantMigration.plan(freshInstall: true, enabled: nil, proactive: nil, autopilot: nil, learnsNotes: nil)
    try check(GlobalAccess.newInstallDefault && fresh.contains(.bool(AssistantMigration.enabledKey, true)),
      "A new install can talk to Serein from any app from the start")
    try check(GlobeConflict.takeover(fnCalls: true, current: 2, saved: nil) == .take(saving: 2)
      && GlobeConflict.takeover(fnCalls: true, current: nil, saved: nil) == .take(saving: GlobeConflict.systemDefault)
      && GlobeConflict.takeover(fnCalls: true, current: 3, saved: 2) == .take(saving: 3),
      "While Fn calls Serein, the emoji picker, input source or Dictation on Globe is turned off, keeping what it was")
    try check(GlobeConflict.takeover(fnCalls: true, current: GlobeConflict.doNothing, saved: 2) == .keep
      && GlobeConflict.warning(for: .fn, usage: GlobeConflict.doNothing) == nil,
      "Once Globe does nothing, Fn goes to Serein alone and Settings shows no warning")
    try check(GlobeConflict.takeover(fnCalls: false, current: GlobeConflict.doNothing, saved: 1) == .giveBack(1)
      && GlobeConflict.takeover(fnCalls: false, current: 3, saved: 1) == .forget
      && GlobeConflict.takeover(fnCalls: false, current: 2, saved: nil) == .keep,
      "Turning Fn off gives Globe back what it did, unless the person chose another action meanwhile")
  }
}
#endif
