import Foundation

/// A check that a person is there (a CAPTCHA, a press-and-hold, a bot interstitial): one list for
/// the web (PageKit.js, filled in by SensitiveFields.script) and for the Mac and Serein's
/// computer (ComputerHold.personOnly, FreshRead), so no path knows fewer. Widen only. Every
/// pattern is valid both as an ICU and as a JavaScript regular expression.
public enum BotCheck {
  /// A check service's own hosts. PageKit reads them from frame addresses; Cua Driver shows no
  /// address, so on Serein's computer they count only where a label names one.
  public static let hosts = ["challenges.cloudflare.com", "arkoselabs.com", "geetest.com"]
  /// The widgets a page draws for one (CSS: PageKit only, the driver shows no class).
  public static let widgets = ".g-recaptcha,.h-captcha,.cf-turnstile,#px-captcha,#FunCaptcha"
  /// Words that ask the person to prove they are one, wherever they show: on a control, a frame or
  /// a field, and on a short page's own text (FreshRead). A note that names a check ("protected by
  /// reCAPTCHA") is none.
  public static let asks =
    #"not a robot|are you a robot|(verify|confirm) (that )?you(['’]| a)re (a )?human|verifying you are human|human verification"#
    + #"|security challenge|verification challenge|press (and|&) hold|start puzzle|click to verify(?!\s*\w)|anti-?robot|i['’]?m a human"#
    + #"|type (the )?characters( you see)?|slide to verify|select all (the )?(images|squares) (with|containing|of)"#
    + #"|(solve|complete|enter|type) the captcha|checking (if the site connection is secure|your browser)|unusual traffic"#
    // An image check's own words (Securimage, WordPress, phpBB). "Enter the code" alone, or "from
    // your app", is a sign-in code's: only a code shown, seen or in a picture is a check's.
    + #"|(enter|type) the (code|text|characters|letters|words?) (shown|you see|(in|from|on) the (image|picture))"#
    + #"|(code|text|characters|letters) (is |are )?(shown|displayed) in the (image|picture)|(enter|type) the code exactly as it appears"#
  /// A control's, a frame's or a field's own words (case-insensitive).
  public static let names = "captcha|" + asks + "|" + hosts.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
  /// An interstitial's own words (case-insensitive, `^` at each line): the verify and confirm
  /// phrasings open a line or a sentence, or follow "please", "let's" or "need to", so a note
  /// about checks is not one.
  public static let words =
    #"(^|[\n.!?]\s*|please |let['’]s |need to )((verify(ing)?|confirm) (that )?you(['’]| a)re ((a )?human|not a robot)"#
    + #"|make sure you(['’]| a)re not a robot|select all (the )?(images|squares) (with|containing|of)|(type|enter) the characters( you see)?)"#
    + #"|checking (if the site connection is secure|your browser before (accessing|you access))"#
    + #"|press (and|&) hold (the button )?to (confirm|verify|prove)|unusual traffic from your (computer )?network"#
  /// A page under this many shown characters is short: an interstitial runs 300 to 700.
  public static let shortPage = 1500
  /// How many rows of a read (elements of a page, PageKit) an image check's picture, its field and
  /// its words sit within: the forum checks measured run 2 to 12 apart, an article's picture and a
  /// search box far more.
  public static let near = 16
  /// A sum a check asks to be answered ("What is 3 + 4?"): one only beside a check's name.
  public static let sums = #"what is \d+ ?(\+|plus|-|minus|x|×|\*|times) ?\d+"#
  /// An image check's presses beside its picture and field: a new picture or the code read aloud.
  public static let redraws = #"refresh|reload|(new|another|different) (code|image|picture)|audio|listen|can['’]?t read"#
  /// Applies only to a button next to a confirmed challenge and its answer field.
  public static let confirms = #"^\s*(verify( answer)?|check answer|submit answer)\s*$"#
  public static let redrawReach = 4
  /// Words that make a press or a picture the page's own, never a check's: an upload's picker
  /// ("Choose a different image") and a code to scan with a sign-in app.
  public static let owns = #"choose|upload|browse|select|\bqr\b|barcode"#
  /// A field's words that take a check's answer ("Confirmation code", "What is 3 + 4?").
  public static let answers = "code|characters|letters|answer|verif|security|" + sums + "|" + names
  /// Words that ask for what a picture beside them shows, or name it as a check. Counted only
  /// within `near` of a picture, never page-wide. "Above" and "below" count only where the picture
  /// is (`over`, `under`): a sign-in page's "enter the code below" has its logo above.
  public static let imageWords =
    #"(image|visual) verification|verification image|security image|what code is (in|on) the (image|picture)"#
    + #"|(enter|type)\b.{0,40}\b(letters|characters|text|code|digits|words?)\b.{0,40}\b(image|picture|opposite)"#
  public static let over = #"(enter|type)\b.{0,40}\b(letters|characters|text|code|digits|words?)\b.{0,40}\babove"#
  public static let under = #"(enter|type)\b.{0,40}\b(letters|characters|text|code|digits|words?)\b.{0,40}\bbelow"#
  /// What Chromium and Cua Driver write where a row has no name of its own: Chromium's note on a
  /// picture with no alt (also after a name it finds unhelpful, "Your avatar"), the driver's notes,
  /// and the object mark a parent shows for each child.
  public static let noName =
    #"To get missing image descriptions, open the context menu\.?|off-screen: scroll it into view before a pixel action; element actions still reach it"#
    + #"|unlabell?ed [a-z ]+; \d+[a-z]* of \d+ [a-z ]+ in this window;?|\uFFFC"#

  /// A whole page that is a check, as PageKit's `challenge` reads one: a short page whose title or
  /// first lines say `words`.
  public static func interstitial(title: String, text: String) -> Bool {
    text.count < shortPage && (title + "\n" + text.prefix(600)).range(of: "(?im)" + words, options: .regularExpression) != nil
  }
}
