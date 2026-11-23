#if DEBUG
import Foundation
import SereinCore

/// The switches that were only in Settings each have a card (SereinSetup.swift), offered one at a time.
extension AssistantCoreChecks {
  static func setupSwitches(_ check: Check) throws {
    let switches: [String: SereinSetup.Topic] = [
      "dock": .dock, "show_and_tell": .showAndTell, "wake": .wake, "background": .background,
      "downloads": .downloads, "awake": .awake,
    ]
    try check(
      switches.allSatisfy { (try? SereinSetup.topic(["topic": $0.key])) == $0.value }
        && (try? SereinSetup.topic(["topic": "cloud_voice"])) == nil
        && (try? SereinSetup.topic(["topic": "dock", "on": true])) == nil,
      "The dock, show and tell, the wake phrase, background work, task downloads and keep awake are each a topic the assistant can offer, and a topic carries no setting value")

    func next(_ topic: SereinSetup.Topic, on: Bool = false, dismissed: [SereinSetup.Topic] = []) -> SereinSetup.Topic? {
      SereinSetup.next(after: topic, on: on, dismissed: dismissed)
    }
    try check(
      next(.login) == .awake && next(.follow) == .showAndTell
        && next(.login, on: true) == nil && next(.login, dismissed: [.awake]) == nil
        && next(.follow, on: true) == nil && next(.follow, dismissed: [.showAndTell]) == nil,
      "A yes to Open at login leads to keep awake and a yes to following along leads to show and tell, unless that is on or was put away in this chat")
    try check(
      SereinSetup.Topic.allCases.allSatisfy { first in next(first).flatMap { next($0) } == nil }
        && switches.values.allSatisfy { next($0) == nil },
      "One card follows a yes at most: never a third, and a switch's card leads to no other")

    var offers = SereinSetup.Offers()
    offers.offer(.dock, in: "chat")
    offers.offer(.awake, in: "chat")
    try check(offers.topic(in: "chat") == .awake, "A chat holds one card at a time, however many switches are offered")
  }
}
#endif
