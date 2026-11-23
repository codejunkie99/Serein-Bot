import AVFoundation
import AppKit
import Combine
import SereinCore
import Speech

/// Settings › Voice › Say “Serein” to ask. While it is on (and ⌥Space is), the microphone
/// listens on this Mac, with on-device recognition only, for Serein's name; the menu bar item
/// shows a microphone meanwhile. On the name, the ⌥Space bar opens with the words that follow,
/// and they go to Serein after a pause, as a message typed there would. Nothing heard before the
/// name is kept: each recognition is dropped whole when it restarts. It never answers a card: it
/// keeps off the microphone while one waits, and a request only ever goes through `sendFromBar`.
@MainActor final class WakeListener: ObservableObject {
  static let shared = WakeListener()
  /// A GateSettings key: off, and off while relay/gates.json cannot be read.
  static let enabledKey = "serein.talk.wakePhrase"
  static var enabled: Bool { GateSettings.shared.bool(forKey: enabledKey) }

  enum State: Equatable {
    /// The switch or ⌥Space is off.
    case off
    /// It cannot listen: no on-device language, no permission, no microphone.
    case unavailable(String)
    /// Serein speaks, a call or dictation has the microphone, a card waits, or the screen is locked.
    case paused(String)
    /// The microphone is on, waiting for the name.
    case listening
    /// The name was heard: the bar shows what follows it.
    case hearing
    var micOn: Bool { self == .listening || self == .hearing }
  }
  @Published private(set) var state = State.off

  private weak var controller: RelayController?
  private let engine = AVAudioEngine()
  private let feed = RecognitionFeed()
  private var hasTap = false
  private var recognizer: SFSpeechRecognizer?
  private var language: String?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  /// Bumped by every new recognition and every stop: a result from an older one is ignored.
  private var generation = 0
  private var startedAt = Date.distantPast
  private var restartTimer: Task<Void, Never>?
  private var hearingTimer: Task<Void, Never>?
  private var resumeTimer: Task<Void, Never>?
  /// When the name was heard, the words after it, and when they last changed.
  private var heardAt = Date.distantPast
  private var words = ""
  private var changedAt = Date.distantPast
  /// The recognition that ended on the name is over: a fresh one follows, and its whole
  /// transcript comes after these words (nil otherwise).
  private var followOn: String?
  /// Recognitions in a row that ended within 2 s: after three it stops and says so.
  private var quickFailures = 0
  private var locked = false
  /// Another user's session is in front; the Mac is asleep. Kept apart, so waking never resumes
  /// listening under someone else's session.
  private var sessionAway = false
  private var asleep = false
  private var observers: [NSObjectProtocol] = []
  private var cardWatch: AnyCancellable?

  private init() {}

  /// From `RelayController.install`: follows the switch, ⌥Space, dictation, cards and the lock screen.
  func attach(_ controller: RelayController) {
    self.controller = controller
    defer { refresh() }
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: GateSettings.changed, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.refresh() }
      },
      // A dictation takes the microphone at once; once none holds it, listening resumes a moment
      // later (a dictation that restarts never sees the wake phrase in between).
      // The same for a kept recording playing and the Test microphone meter.
      center.addObserver(forName: Dictation.claimsChanged, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          if Self.audioBusy { self.refresh() } else { self.refreshSoon() }
        }
      },
      // Another microphone or a changed input format stops the engine: start again on it.
      center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.state.micOn else { return }
          self.stop()
          self.refresh()
        }
      },
    ]
    let distributed = DistributedNotificationCenter.default()
    // The keyboard's language may change the recognition language: a new recognition takes it,
    // and an unsupported one that becomes supported arms again.
    observers.append(distributed.addObserver(
      forName: Notification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"), object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        if self.state == .listening, TalkLanguageSupport.resolved() != self.language { self.listen() } else { self.refresh() }
      }
    })
    for (name, value) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
      observers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.locked = value
          self?.refresh()
        }
      })
    }
    // Another user's session in front, or the Mac asleep: nobody here is asking.
    let workspace = NSWorkspace.shared.notificationCenter
    let sessions: [(Notification.Name, Bool)] = [
      (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false),
    ]
    for (name, value) in sessions {
      observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.sessionAway = value
          self?.refresh()
        }
      })
    }
    let sleep: [(Notification.Name, Bool)] = [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)]
    for (name, value) in sleep {
      observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.asleep = value
          self?.refresh()
        }
      })
    }
    // Read after the change lands (`@Published` sends before it does).
    cardWatch = controller.relay.$approvals.map { !$0.isEmpty }
      .combineLatest(controller.relay.$questionForms.map { !$0.isEmpty }, controller.relay.$consentWaiting)
      .map { $0 || $1 || $2 }
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.refresh() }
  }

  /// Settings › Voice: asks macOS for speech recognition and the microphone. True when both are allowed.
  static func requestAccess() async -> Bool {
    let speech = await withCheckedContinuation { (done: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
      SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) }
    }
    guard speech == .authorized else { return false }
    return await AVCaptureDevice.requestAccess(for: .audio)
  }

  /// Puts the microphone on or off to match everything it follows. Called on each change.
  func refresh() {
    resumeTimer?.cancel()
    resumeTimer = nil
    let next = wanted()
    guard next == .listening else {
      stop()
      state = next
      return
    }
    if !state.micOn { start() }
  }
  private func refreshSoon() {
    resumeTimer?.cancel()
    resumeTimer = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(CallVoice.echoGuard * 1_000_000_000))
      guard !Task.isCancelled else { return }
      self?.refresh()
    }
  }
  /// A dictation, the Test microphone meter or a kept recording has the microphone or the speakers.
  private static var audioBusy: Bool { Dictation.claimed > 0 || MicMeter.active > 0 || RecordingPlayer.active > 0 }
  /// A card, question, consent or Mac approval waits for the person: a request is never sent then.
  private var waiting: Bool {
    guard let relay = controller?.relay else { return true }
    return MacApproval.isOpen || !relay.approvals.isEmpty || !relay.questionForms.isEmpty || relay.consentWaiting
  }
  private func wanted() -> State {
    guard Self.enabled, RelayOrchestrator.enabled, let controller, !RunMode.automated, !RunMode.stress else { return .off }
    if locked || sessionAway || asleep { return .paused("Paused while the screen is locked.") }
    // Half-duplex: never while Serein speaks, and only `CallVoice.echoGuard` after it stopped.
    let quiet = controller.spokeUntil.addingTimeInterval(CallVoice.echoGuard)
    if controller.talking || quiet > Date() {
      if !controller.talking { resume(at: quiet) }
      return .paused("Paused while Serein speaks.")
    }
    if controller.callMode { return .paused("Paused during a call.") }
    if Dictation.claimed > 0 { return .paused("Paused while you dictate.") }
    if MicMeter.active > 0 { return .paused("Paused while the microphone is tested.") }
    if RecordingPlayer.active > 0 { return .paused("Paused while a recording plays.") }
    if waiting { return .paused("Paused while Serein waits for your answer.") }
    return .listening
  }
  private func resume(at date: Date) {
    resumeTimer?.cancel()
    resumeTimer = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(max(0, date.timeIntervalSinceNow) * 1_000_000_000))
      guard !Task.isCancelled else { return }
      self?.refresh()
    }
  }

  // MARK: the microphone

  private func start() {
    guard SFSpeechRecognizer.authorizationStatus() == .authorized,
      AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    else {
      state = .unavailable("Allow the microphone and speech recognition for Serein in System Settings › Privacy & Security.")
      return
    }
    guard makeRecognizer() else { return }
    let node = engine.inputNode
    let format = node.outputFormat(forBus: 0)
    guard format.sampleRate > 0 else {
      state = .unavailable("No microphone is available.")
      return
    }
    let feed = self.feed
    node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in feed.append(buffer) }
    hasTap = true
    do {
      engine.prepare()
      try engine.start()
    } catch {
      stop()
      state = .unavailable(error.localizedDescription)
      return
    }
    state = .listening
    quickFailures = 0
    listen()
  }
  /// The recognizer for the language Settings › Voice resolves to now. False (and unavailable)
  /// when that language cannot be recognized on this Mac: it never falls back to the network.
  private func makeRecognizer() -> Bool {
    guard let id = TalkLanguageSupport.resolved() else {
      stop()
      state = .unavailable("No language on this Mac can recognize speech without the network.")
      return false
    }
    if id == language, recognizer != nil { return true }
    guard let next = SFSpeechRecognizer(locale: Locale(identifier: id)), next.supportsOnDeviceRecognition else {
      stop()
      state = .unavailable("On-device recognition is unavailable for this language on this Mac.")
      return false
    }
    recognizer = next
    language = id
    return true
  }
  /// A fresh recognition on the running microphone. The one before ends, and all it heard with it.
  private func listen(after delay: TimeInterval = 0) {
    generation += 1
    let current = generation
    feed.set(nil)
    task?.cancel()
    request?.endAudio()
    task = nil
    request = nil
    restartTimer?.cancel()
    guard delay <= 0 else {
      restartTimer = Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard !Task.isCancelled, let self, self.generation == current, self.state == .listening else { return }
        self.listen()
      }
      return
    }
    // The language may follow the keyboard: each recognition takes the current one.
    guard makeRecognizer(), let recognizer else { return }
    let next = SFSpeechAudioBufferRecognitionRequest()
    next.requiresOnDeviceRecognition = true
    next.shouldReportPartialResults = true
    next.contextualStrings = [WakePhrase.name]
    request = next
    feed.set(next)
    startedAt = Date()
    task = recognizer.recognitionTask(with: next) { [weak self] result, error in
      let text = result?.bestTranscription.formattedString
      let ended = result?.isFinal == true || error != nil
      Task { @MainActor in self?.heard(text, ended: ended, generation: current) }
    }
    restartTimer = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(WakePhrase.restart * 1_000_000_000))
      guard !Task.isCancelled, let self, self.generation == current, self.state == .listening else { return }
      self.listen()
    }
  }
  private func heard(_ text: String?, ended: Bool, generation current: Int) {
    guard current == generation, state.micOn else { return }
    if !ended, text != nil { quickFailures = 0 }
    let asked: String?
    if let followOn {
      // The whole of the follow-on recognition is the request, after what the first one heard.
      asked = text.map { more in [followOn, more].filter { !$0.isEmpty }.joined(separator: " ") } ?? followOn
    } else {
      asked = text.flatMap(WakePhrase.request(in:))
    }
    if state == .listening {
      if let asked {
        begin(asked)
        // The recognizer finished on the name (a pause after it): what follows needs a fresh one.
        if ended, state == .hearing {
          followOn = asked
          listen()
          restartTimer?.cancel()
          restartTimer = nil
        }
      } else if ended {
        // It ended on its own; one that fails at once waits before the next, and three in a row
        // stop it (the recognizer is not ready for this language), saying so.
        let quick = Date().timeIntervalSince(startedAt) < 2
        quickFailures = quick ? quickFailures + 1 : 0
        guard quickFailures < 3 else {
          stop()
          state = .unavailable("Speech recognition on this Mac isn't ready for this language.")
          return
        }
        listen(after: quick ? 2 : 0)
      }
      return
    }
    if let asked, asked != words {
      words = asked
      changedAt = Date()
      controller?.wakeHeard(asked)
    }
    if ended { finishHearing(send: true) }
  }
  /// The name: the bar opens, and what follows is sent after `WakePhrase.silence`, or at `limit`.
  private func begin(_ asked: String) {
    // Never over a Mac approval: the bar would take the keyboard from it.
    if MacApproval.isOpen {
      listen()
      return
    }
    restartTimer?.cancel()
    restartTimer = nil
    followOn = nil
    state = .hearing
    heardAt = Date()
    changedAt = heardAt
    words = asked
    controller?.wakeHeard(asked)
    hearingTimer?.cancel()
    hearingTimer = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled, let self, self.state == .hearing else { return }
        let now = Date()
        if now.timeIntervalSince(self.heardAt) >= WakePhrase.limit
          || (self.words.isEmpty
            ? now.timeIntervalSince(self.heardAt) >= WakePhrase.nothingSaid
            : now.timeIntervalSince(self.changedAt) >= WakePhrase.silence)
        {
          self.finishHearing(send: true)
          return
        }
      }
    }
  }
  /// Cancel on the bar, or Esc: nothing is sent, and listening starts afresh.
  func cancel() {
    guard state == .hearing else { return }
    finishHearing(send: false)
  }
  private func finishHearing(send: Bool) {
    hearingTimer?.cancel()
    hearingTimer = nil
    // Checked now, not only through `cardWatch` (which lands a moment later): a card or Mac
    // approval that came meanwhile drops the request, and the bar stays for it.
    let waiting = self.waiting
    let asked = send && !waiting ? words : ""
    words = ""
    followOn = nil
    state = .listening
    // A fresh recognition first: the request leaves nothing behind it.
    listen()
    controller?.wakeFinished(asked, dismiss: !waiting)
  }
  private func stop() {
    generation += 1
    restartTimer?.cancel()
    restartTimer = nil
    hearingTimer?.cancel()
    hearingTimer = nil
    let wasHearing = state == .hearing
    words = ""
    followOn = nil
    feed.set(nil)
    task?.cancel()
    task = nil
    request?.endAudio()
    request = nil
    if hasTap {
      engine.stop()
      engine.inputNode.removeTap(onBus: 0)
      hasTap = false
    }
    if state.micOn { state = .off }
    // Paused mid-request (⌥Space held, a card, the lock screen): nothing is sent; the bar stays
    // for whatever took over.
    if wasHearing { controller?.wakeFinished("", dismiss: false) }
  }
}

/// The microphone's way to the current recognition: the audio thread appends to whichever one is
/// current, so a restart swaps it without stopping the microphone (WakeListener, Dictation).
final class RecognitionFeed: @unchecked Sendable {
  private let lock = NSLock()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  func set(_ next: SFSpeechAudioBufferRecognitionRequest?) {
    lock.lock()
    request = next
    lock.unlock()
  }
  func append(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    let current = request
    lock.unlock()
    current?.append(buffer)
  }
}
