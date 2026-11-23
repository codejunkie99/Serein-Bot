#if DEBUG
import Foundation
import SereinCore

/// The Marketplace's pure rules (`MarketplacePlace`, `MarketplaceRules`): the header's trail,
/// where Esc goes, what a group shows before See all, and the order of Your apps.
extension AssistantCoreChecks {
  static func marketplace(_ check: Check) throws {
    try check(ShellSection.marketplace != ShellSection.settings, "The Marketplace has a section of its own")
    try check(!ShellSection.all.contains(ShellSection.marketplace), "The Marketplace is not a plain section, like Settings")
    try check(
      SereinLayout.place(section: ShellSection.marketplace, besideOn: true, peek: false, compact: false, room: 2000, minWidth: 320) == .hidden,
      "Serein beside waits while the Marketplace shows")

    try check(MarketplacePlace.apps.levels == ["Apps"], "Apps stands alone in the trail")
    try check(MarketplacePlace.category(.code).levels == ["Apps", "Code"], "A group sits under Apps in the trail")
    try check(MarketplacePlace.category(.code).parent == .apps, "Esc from a group goes back to Apps")
    try check(MarketplacePlace.teams.parent == nil && MarketplacePlace.app("linear").parent == nil, "A column row has no parent, so Esc closes")
    try check(MarketplacePlace.category(.finance).columnRow == .apps, "A group keeps Apps selected in the column")
    try check(MarketplacePlace.app("linear").label == "Linear", "An added app's page is named after the app")
    try check(MarketplacePlace.app("no-such-app").label == "App", "An unknown app id still has a name")

    let five = MarketplaceRules.preview([1, 2, 3, 4, 5])
    try check(five.shown == [1, 2, 3, 4] && five.more, "A group of five shows four and See all")
    let four = MarketplaceRules.preview([1, 2, 3, 4])
    try check(four.shown == [1, 2, 3, 4] && !four.more, "A group of four shows all and no See all")
    try check(MarketplaceRules.preview([1, 2], limit: -1).shown.isEmpty, "A negative limit shows nothing")

    let order = MarketplaceRules.yourApps([
      (id: "figma", state: .off), (id: "notion", state: .working), (id: "asana", state: .notSetUp),
      (id: "sentry", state: .needsAttention(reason: "Sign-in expired.")), (id: "linear", state: .working),
      (id: "vercel", state: .testing),
    ])
    try check(order == ["sentry", "vercel", "notion", "linear", "figma"], "Your apps: needs you, testing, working, off; not set up left out")
    try check(MarketplaceRules.yourApps([]).isEmpty, "No app added, no Your apps")

    // A connect card follows the account live (ConnectChatCard): what each answer may do.
    guard let link = ConnectLink(app: "gmail", kind: .composio) else { throw SereinError.invalid("FAIL: a Gmail link") }
    let start = Date(timeIntervalSince1970: 0)
    var waiting = ConnectFlow(card: "c1", link: link)
    _ = waiting.next(.connect(keyKept: true), now: start)
    _ = waiting.next(.linkOpened, now: start)
    try check(waiting.next(.statusReady, now: start) == .carryOn(card: "c1"), "An account that arrives while the card waits carries on")
    try check(waiting.next(.statusReady, now: start) == .nothing && waiting.carriedOn, "It carries on once")
    var late = ConnectFlow(card: "c2", link: link)
    _ = late.next(.connect(keyKept: true), now: start)
    _ = late.next(.linkOpened, now: start)
    _ = late.next(.statusWaiting, now: start.addingTimeInterval(ConnectFlow.maxWait + 1))
    try check(late.state == .failed(reason: ConnectFlow.timeoutReason), "The wait runs out after maxWait")
    try check(late.next(.statusReady, now: start) == .nothing && late.state == .ready && !late.carriedOn,
      "A sign-in that finished after the wait shows connected and sends nothing by itself")
    try check(late.next(.continued, now: start) == .carryOn(card: "c2"), "Continue then carries on, once, on the person's press")
  }
}
#endif
