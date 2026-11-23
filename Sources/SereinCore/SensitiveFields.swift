import Foundation

/// The words that make a field, or a control that reveals one, the person's own. One list for
/// the page scripts (PageKit, PagePoint, PasswordCapture) and for recipes, so they cannot drift.
/// Widen only, never narrow. Every pattern is valid both as an ICU and as a JavaScript regular
/// expression (no lookbehind) and holds no quote or backslash, so it can sit in a script literal.
public enum SensitiveFields {
  /// Recovery and backup secrets: codes that sign in without the password, and wallet seeds.
  public static let recovery = "recovery.?(code|key)|backup.?code|seed.?phrase"
  /// A field's name, id, label or placeholder (case-insensitive): passwords, cards, codes,
  /// keys, recovery secrets and CAPTCHAs.
  public static let names =
    "card|cvv|cvc|security.?code|password|passwd|passcode|token|secret|api.?key|passphrase|credential"
    + "|otp|one.?time|verification.?code|2fa|two.?factor|mfa|auth(entication)?.?code|pin.?code|"
    + recovery + "|captcha|(^|[^a-z])pin([^a-z]|$)"
  /// A pressable control's own words (aria-label, title, visible text): one that reveals or
  /// takes a secret ("Show recovery code") is the person's. Narrower than `names`, because a
  /// control's visible text is longer and looser than a field's name.
  public static let controls =
    "password|passwd|passcode|" + recovery + "|one.?time.?code|security.?code|api.?key|secret.?key|private.?key"

  /// The page script with its placeholders filled, BotCheck's lists among them. Each placeholder's
  /// default (a script loaded without this) fails closed: every field is secret, every frame and
  /// element a check.
  public static func script(_ source: String) -> String {
    func literal(_ value: some Encodable) -> String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = .withoutEscapingSlashes
      return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "''"
    }
    return [
      ("/*SENSITIVE_NAMES*/''", "'" + names + "'"), ("/*SENSITIVE_CONTROLS*/''", "'" + controls + "'"),
      ("/*SENSITIVE_RECOVERY*/''", "'" + recovery + "'"), ("/*CHECK_HOSTS*/[]", literal(BotCheck.hosts)),
      ("/*CHECK_WIDGETS*/'*'", literal(BotCheck.widgets)), ("/*CHECK_NAMES*/''", literal(BotCheck.names)),
      ("/*CHECK_WORDS*/''", literal(BotCheck.words)), ("/*CHECK_ASKS*/''", literal(BotCheck.asks)), ("/*CHECK_SUMS*/''", literal(BotCheck.sums)),
      ("/*CHECK_ANSWERS*/''", literal(BotCheck.answers)), ("/*CHECK_REDRAWS*/''", literal(BotCheck.redraws)),
      ("/*CHECK_CONFIRMS*/''", literal(BotCheck.confirms)),
      ("/*CHECK_OWNS*/'(?!)'", literal(BotCheck.owns)), ("/*CHECK_IMAGE_WORDS*/''", literal(BotCheck.imageWords)),
      ("/*CHECK_OVER*/''", literal(BotCheck.over)), ("/*CHECK_UNDER*/''", literal(BotCheck.under)),
      ("/*CHECK_NEAR*/1e9", String(BotCheck.near)), ("/*CHECK_REACH*/1e9", String(BotCheck.redrawReach)),
    ].reduce(source) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
  }
}
