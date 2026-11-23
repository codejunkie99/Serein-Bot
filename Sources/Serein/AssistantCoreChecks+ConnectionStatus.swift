#if DEBUG
import Foundation
import SereinCore

/// Settings › Connections rows: a word or two, with the details behind the chevron and info button.
extension AssistantCoreChecks {
  static func connectionStatus(_ check: Check) throws {
    let W = ConnectionStatusWords.self
    try check(W.words(isOn: false, blockedByMacOS: false) == "Off", "An app that is off reads Off")
    try check(W.words(isOn: false, blockedByMacOS: true) == "Off", "An app that is off reads Off even when macOS blocks it")
    try check(W.words(isOn: true, blockedByMacOS: false) == "On", "An app that is on reads On")
    try check(W.words(isOn: true, blockedByMacOS: true) == "Blocked by macOS", "An app macOS blocks says so")
    for words in [W.on, W.off, W.blocked] {
      try check(words.split(separator: " ").count <= 3 && !words.contains("·"), "A status stays a few words: \(words)")
    }
    let info = W.onThisMacInfo
    try check(info.contains("always asks you first") && info.contains("no password or token"),
      "The info button keeps the privacy and account facts the panel used to print")
  }
}
#endif
