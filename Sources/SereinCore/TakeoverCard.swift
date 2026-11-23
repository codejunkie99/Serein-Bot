import Foundation

public enum TakeoverCard {
  public enum Ending: Sendable { case handedBack, dismissed }
  public static let tool = "ask_person_takeover"
  public static let description =
    "Show the user this tab's live page in a takeover card, for a step only they can do on the live page: a CAPTCHA, bot check or sign-in check. reason is one short sentence for them. Returns at once; keep working on the rest of the task. Leave this tab alone until Serein's message says they handed it back."
  public static let promptLine =
    "When a CAPTCHA, bot check or sign-in check blocks a tab, call ask_person_takeover with that tab and a short reason. It returns at once: keep working on the rest of the task meanwhile, and carry on in that tab when Serein says it is handed back. Never solve a CAPTCHA yourself."
  public static let asked =
    "Asked the user in a takeover card. Keep working on the rest of the task and leave this tab alone; Serein sends you a message when they hand it back."
  public static let held =
    "The user has this tab in the takeover card now. Keep working on the rest of the task; Serein sends you a message when they hand it back."
  public static func followUp(host: String, tab: String, ending: Ending) -> String {
    ending == .handedBack
      ? "I did the step on \(host) and handed tab \(tab) back. If tab \(tab) is among your tabs, read it again before you act; if not, open the page again. Then carry on with the task."
      : "I closed the takeover card on \(host) without doing the step. Carry on with the rest of the task another way."
  }
}
