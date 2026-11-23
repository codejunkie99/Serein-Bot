#if DEBUG
import AppKit
import Foundation
import SereinCore
import SwiftUI

/// An AI app's key failed: the chat says so and names the app, and for OpenCode one card takes a
/// new key that goes to OpenCode only, then sends the person's message again once.
extension AssistantCoreChecks {
  static func keyFailure(_ check: Check) throws {
    let openCode = "This API key has expired. Create a new API key in OpenCode Console and replace it in your client "
      + "or secret store. Signing in again will not renew this key. Manage your API keys at https://opencode.ai/auth"
    let anthropic = #"401 {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
    let openAI = "Incorrect API key provided: sk-proj-abc1***wxyz. You can find your API key at https://platform.openai.com/account/api-keys."
    try check(
      KeyFailure.of(openCode) == .expired && KeyFailure.of("Your API key is expired.") == .expired,
      "OpenCode's own expired-key sentence reads as an expired key")
    try check(
      KeyFailure.of(anthropic) == .notAccepted && KeyFailure.of(openAI) == .notAccepted
        && KeyFailure.of("Your API key was revoked.") == .notAccepted && KeyFailure.of("Invalid API key · Please run /login") == .notAccepted,
      "Anthropic's invalid x-api-key, OpenAI's incorrect key and a revoked key read as a key not accepted")
    try check(
      KeyFailure.of("401") == .notAccepted && KeyFailure.of("Request failed with status code 401") == .notAccepted
        && KeyFailure.of("Unauthorized") == .notAccepted,
      "A bare 401 or Unauthorized reads as a key not accepted")
    try check(
      KeyFailure.of(nil) == nil && KeyFailure.of("") == nil && KeyFailure.of("The model is busy. Try later.") == nil
        && KeyFailure.of("Rate limit reached. Try again in 20 s.") == nil && KeyFailure.of("Prompt is 4013 tokens long.") == nil
        && KeyFailure.of("Codex exited (1). See /tmp/log") == nil
        && KeyFailure.of(String(repeating: "x", count: 600) + " key has expired") == nil,
      "Other errors, numbers that only hold 401, and long logs are no key failure")

    let F = TurnFailure.self
    try check(
      F.couldNotAnswer("Serein", reason: openCode, app: "OpenCode") == "Serein could not answer. OpenCode's key has expired."
        && F.couldNotAnswer("Scout", reason: anthropic, app: "Claude Code") == "Scout could not answer. Claude Code's key was not accepted.",
      "The failure line names the AI app whose key failed, in plain words")
    try check(
      F.couldNotAnswer("Serein", reason: openCode) == "Serein could not answer."
        && F.couldNotAnswer("Scout", reason: "The model is busy. Try later.", app: "OpenCode") == "Scout could not answer. The model is busy."
        && F.plainReason(openCode) == nil,
      "Without the app's name, and for any other reason, the line and plainReason stay as they were")
    let fake = "test-not-a-real-key"
    let echoed = F.couldNotAnswer("Serein", reason: "Incorrect API key provided: \(fake)", app: "OpenCode")
    let lineWords = Set(echoed.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
    try check(
      !echoed.contains(fake) && ReceiptCopy.bannedWords.isDisjoint(with: lineWords),
      "The failure line never repeats a key the app's error echoed, and holds no feature word")

    var ask = KeyFailure.Ask()
    try check(!ask.begin("   ") && ask.step == .asking, "Save with a blank field hands nothing over")
    try check(ask.begin(fake) && ask.step == .handing && !String(describing: ask).contains(fake),
      "Save hands the key over and the card keeps no copy of it")
    try check(!ask.begin(fake), "A second Save while the key is on its way hands nothing more over")
    ask.decline()
    try check(ask.step == .handing, "Escape or Not now cannot cut a hand-over short")
    let refusal: String = MainActor.assumeIsolated { OpenCodeKey.refusal }
    try check(!ask.handed(refusal) && ask.step == .asking && ask.refusal == refusal,
      "A failed hand-over says one plain sentence, keeps the field, and sends nothing")
    try check(ask.begin(fake) && ask.handed(nil) && ask.step == .saved && ask.refusal == nil,
      "A key OpenCode took sends the person's message again")
    try check(!ask.handed(nil) && !ask.begin(fake), "The message goes again once only, and a saved card takes no more keys")
    var later = KeyFailure.Ask()
    later.decline()
    try check(later.step == .declined && !later.begin(fake), "Not now settles the card with no key")

    let copy: [String] = MainActor.assumeIsolated {
      [OpenCodeKeyCard.heading(.expired), OpenCodeKeyCard.heading(.notAccepted), OpenCodeKeyCard.whereToMake,
       OpenCodeKeyCard.note("Serein"), OpenCodeKeyCard.saved, OpenCodeKeyCard.declined, OpenCodeKey.refusal]
    }
    try check(
      copy[0] == "Your OpenCode key has expired" && copy[2].contains("OpenCode Console") && !copy.contains { $0.contains("http") }
        && !copy.contains { $0.contains(fake) },
      "The card's heading says the key expired, names OpenCode Console as text with no link, and never holds a key")

    try check(
      OpenCodeAPI.keyRoute(model: "opencode-go/glm-5.3-flash") == "api/integration/opencode-go/connect/key"
        && OpenCodeAPI.keyRoute(model: "glm-5.3-flash") == nil && OpenCodeAPI.keyRoute(model: "/glm") == nil,
      "The key goes to the failed model's provider on OpenCode 2's own connect-key route, and a model with no provider stops it")

    // SEREIN_KEY_CARD_PREVIEW=<folder> draws the failure line and the card offscreen, no window.
    if let folder = ProcessInfo.processInfo.environment["SEREIN_KEY_CARD_PREVIEW"] {
      try MainActor.assumeIsolated { try drawKeyCard(into: URL(fileURLWithPath: folder)) }
    }
  }

  @MainActor private static func drawKeyCard(into folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let line = TurnFailure.couldNotAnswer("Serein", reason: "This API key has expired. Create a new API key in OpenCode Console.", app: "OpenCode")
    for palette in [Palette.light, .dusk] {
      let content = VStack(alignment: .leading, spacing: 12) {
        TurnFailureLine(words: line, attempt: 2, retry: {}, retryTitle: "Try again")
        OpenCodeKeyCard(failure: .expired, model: "opencode-go/glm-5.3-flash", assistant: "Serein") {}
      }
      .frame(width: 560, alignment: .leading).padding(20)
      .environment(\.palette, palette).environment(\.colorScheme, palette.isDark ? .dark : .light)
      .environment(\.sereinReducedEffects, true).background(palette.background)
      let renderer = ImageRenderer(content: content)
      renderer.scale = 2
      guard let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw SereinError.invalid("The key card could not be drawn.")
      }
      try data.write(to: folder.appendingPathComponent("key-card-\(palette.isDark ? "dark" : "light").png"))
    }
  }
}
#endif
