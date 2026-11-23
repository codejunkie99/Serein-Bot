import SereinCore

/// Ephemeral, host-owned conversation controls. Agent tool arguments select a topic, never a
/// setting value. Actual changes are made only by the person's native card interaction.
@MainActor private final class SereinSetupOffers {
  static let shared = SereinSetupOffers()
  var state = SereinSetup.Offers()
}

extension RelayOrchestrator {
  var setupOffersHere: [SereinSetup.Topic] {
    SereinSetupOffers.shared.state.topic(in: threadID).map { [$0] } ?? []
  }
  var dismissedSetupOffersHere: [SereinSetup.Topic] {
    SereinSetupOffers.shared.state.dismissed(in: threadID)
  }
  func offerSetup(_ topic: SereinSetup.Topic) {
    guard SereinSetupOffers.shared.state.topic(in: threadID) != topic else { return }
    objectWillChange.send()
    SereinSetupOffers.shared.state.offer(topic, in: threadID)
  }
  /// Once the person depends on schedules (a timed request, the morning brief or check-ins),
  /// Open at login is offered in this chat, unless Serein already opens then, this copy cannot,
  /// or they said Not now to it before.
  func offerLoginIfUseful() {
    let scheduled = reminders.contains { $0.action && $0.paused != true } || proactiveLevel != .off
    guard SereinSetup.offersLogin(scheduled: scheduled, opensAtLogin: LoginLaunch.enabled, packaged: LoginLaunch.packaged,
                                  declined: LoginLaunch.declined),
      !dismissedSetupOffersHere.contains(.login) else { return }
    offerSetup(.login)
  }
  func offerFollowIfUseful() {
    guard SereinSetup.offersFollow(on: ScreenTrailWatch.enabled, declined: ScreenTrailWatch.declined,
                                   cardWaiting: !setupOffersHere.isEmpty) else { return }
    offerSetup(.follow)
  }
  /// After a dictation in English that Apple Speech heard: the speech model is offered in this
  /// chat, unless this Mac has it or cannot run it, a setup question or another card is waiting,
  /// or the person said Not now to it before.
  func offerSpeechIfUseful() {
    guard !SereinChatSetup.shared.isActive(in: self),
      SereinSetup.offersSpeech(supported: SpeechEngine.supported, there: SpeechEngine.modelFile() != nil,
                               declined: SpeechModelDownload.declined, cardWaiting: !setupOffersHere.isEmpty)
    else { return }
    offerSetup(.speech)
  }
  func dismissSetupOffer(_ topic: SereinSetup.Topic, declined: Bool = true) {
    guard SereinSetupOffers.shared.state.topic(in: threadID) == topic else { return }
    objectWillChange.send()
    SereinSetupOffers.shared.state.dismiss(topic, in: threadID, declined: declined)
  }
}
