import AVFoundation
import SereinCore
import SwiftUI

/// Level-only microphone check. Nothing is recognized or stored.
@MainActor final class MicMeter: ObservableObject {
  /// Meters running now: the wake phrase lets go of the microphone meanwhile.
  private(set) static var active = 0
  @Published var level: Float = 0
  @Published var running = false {
    didSet {
      guard running != oldValue else { return }
      Self.active += running ? 1 : -1
      NotificationCenter.default.post(name: Dictation.claimsChanged, object: nil)
    }
  }
  @Published var message: String?
  private let engine = AVAudioEngine()
  func toggle() {
    if running { return stop() }
    message = nil
    Task {
      guard await AVCaptureDevice.requestAccess(for: .audio) else {
        message = "Allow the microphone for Serein in System Settings > Privacy & Security."
        return
      }
      let format = engine.inputNode.outputFormat(forBus: 0)
      guard format.sampleRate > 0 else {
        message = "No microphone is available."
        return
      }
      engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) {
        [weak self] buffer, _ in
        var peak: Float = 0
        if let data = buffer.floatChannelData?[0] {
          for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
        }
        Task { @MainActor in self?.level = min(1, peak * 3) }
      }
      do {
        engine.prepare()
        try engine.start()
        running = true
      } catch {
        engine.inputNode.removeTap(onBus: 0)
        message = error.localizedDescription
      }
    }
  }
  func stop() {
    guard running else { return }
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
    running = false
    level = 0
  }
}

struct TalkingSettings: View {
  @Environment(\.palette) var p
  @AppStorage(TalkKey.enabledKey) private var enabled = false
  @AppStorage(TalkKey.defaultsKey) private var keyName = TalkKey.fn.rawValue
  @AppStorage(TalkKey.keepKey) private var keep = false
  @GateStorage(FeaturePolicy.key(.proofreading), unreadable: false) private var proofread = true
  @StateObject private var meter = MicMeter()
  @AppStorage(TalkLanguage.defaultsKey) private var language = TalkLanguage.system
  @State private var languages: [TalkLanguage.Choice] = []
  @State private var usage = GlobeConflict.current()
  @State private var guided = false
  @GateStorage(WakeListener.enabledKey, unreadable: false) private var wake = false
  @AppStorage(RelayOrchestrator.enabledKey) private var summonOn = false
  @AppStorage(RelayOrchestrator.summonKey) private var summon = RelayHotKey.summon
  @ObservedObject private var listener = WakeListener.shared
  /// Serein talks: moved here from Settings › Serein, so voice has one page.
  @AppStorage(RelayController.speakKey) private var speak = false
  @AppStorage(RelayController.speakProgressKey) private var speakProgress = true
  @GateStorage(RelayController.voiceAnswersKey) private var voiceAnswers = false
  /// Why turning the wake phrase on did not take (macOS said no to the microphone or speech).
  @State private var wakeRefused: String?
  private var key: TalkKey { TalkKey(rawValue: keyName) ?? .fn }
  /// Settings › Voice (id "Talking"), in two sections and Privacy: You talk (guided setup, push
  /// to talk and its key, the wake phrase, the language, the microphone test), Serein talks (read
  /// replies aloud, progress in calls, answers by voice) and Privacy (fix mishearings, keep
  /// recordings). Every note that says what is never sent or allowed stays in view.
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      // Everyday (docs/demos/simple-settings.decision.md): how you talk and whether Serein reads its
      // replies aloud. Setup, calls and what is kept fold under Advanced.
      SettingsBlock("You talk") {
        pushToTalk
        Divider().overlay(p.line)
        wakePhrase
        Divider().overlay(p.line)
        languageRows
      }
      SettingsBlock("Serein talks") {
        Toggle("Read replies aloud", isOn: $speak)
        SettingsNote("Speech is recognized on this Mac where it can be. In a call, replies are always read aloud, and holding the round button talks.")
      }
      SettingsAdvanced(page: "Talking", count: 6) {
      SettingsBlock("Setup and microphone") {
        guidedSetup
        Divider().overlay(p.line)
        microphone
      }.onDisappear { meter.stop() }
      inCalls
      SettingsBlock("Privacy") {
        Toggle("Fix likely mishearings and drop fillers with my AI app", isOn: $proofread)
        SettingsNote(
          "Only when the recognizer is unsure of a word, and never on private pages. That short text goes to your AI app and uses your allowance.")
        Toggle("Keep my recordings for 30 days", isOn: $keep)
        SettingsNote(
          keep
            ? "Recordings stay on this Mac for 30 days. Private pages keep nothing."
            : "Off. Audio is not saved.")
        if keep { TalkRecordingsList() }
      }
      }
    }.onDisappear { meter.stop() }
      .task { languages = TalkLanguageSupport.choices() }
  }
  @ViewBuilder private var guidedSetup: some View {
    if guided {
      TalkingWizard()
    } else {
      HStack {
        Text("Check the microphone, pick a key and try a sentence.").role(.meta)
        Spacer()
        Button("Start guided setup") { guided = true }
      }
    }
  }
  @ViewBuilder private var pushToTalk: some View {
    Toggle("Hold a key to talk instead of typing", isOn: $enabled)
    SettingsNote(
      "Hold the key while Serein is in front, say it, and let go. Your words go into the field you are typing in, or are copied when no field has focus.")
    SettingsPopUp("Key", selection: $keyName, choices: TalkKey.allCases.map { SettingsChoice(value: $0.rawValue, label: $0.title) })
      .disabled(!enabled)
    if let warning = GlobeConflict.warning(for: key, usage: usage) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        InterfaceIcon(systemName: "exclamationmark.triangle", size: 13).foregroundStyle(p.warning)
        Text(warning).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button("Check again") { usage = GlobeConflict.current() }.buttonStyle(QuietButton())
      }.font(UIStyle.meta)
    }
  }
  @ViewBuilder private var wakePhrase: some View {
    Toggle("Say “Serein” to ask", isOn: Binding(get: { wake }, set: { setWake($0) }))
      // Turning it on needs ⌥Space (its bar) and a language this Mac recognizes on-device.
      .disabled(!wake && (!summonOn || TalkLanguageSupport.resolved() == nil))
    SettingsNote(wakeNote)
  }
  @ViewBuilder private var languageRows: some View {
    SettingsPopUp("Language", selection: $language, choices: languages.map { SettingsChoice(value: $0.id, label: $0.title) }, menuWidth: 260)
      .disabled(languages.isEmpty)
    SettingsNote(languageNote)
  }
  @ViewBuilder private var microphone: some View {
    HStack(spacing: 12) {
      Button(meter.running ? "Stop test" : "Test microphone") { meter.toggle() }
        .buttonStyle(QuietButton())
      Spacer()
      ZStack(alignment: .leading) {
        Capsule().fill(p.track)
        Capsule().fill(p.accent).frame(width: max(4, 160 * CGFloat(meter.level)))
      }.frame(width: 160, height: 4).accessibilityElement().accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(meter.level * 100)) percent")
    }
    if let message = meter.message { SettingsNote(message) }
    HStack(spacing: 6) {
      Text("Recognition runs on this Mac with Apple Speech.").role(.meta)
      InfoPopoverButton(
        text:
          "Serein requires on-device recognition, so there is no speech model to download. Language availability depends on the models macOS has installed. Serein asks for microphone and speech-recognition access the first time you talk.",
        label: "About speech recognition")
    }
  }
  /// Under Advanced: Speak progress in calls and Answer low-risk questions by voice, each with its
  /// note. Read replies aloud is in view above.
  private var inCalls: some View {
    SettingsBlock("In calls", info: "In a call, say “decline” to answer any question no. With “Answer low-risk questions by voice” on, “allow” answers clicks, typing, scrolling and going to a page: Serein reads the step back and allows it only after you say “yes”. Sending, posting, paying, deleting, booking, installing and settings always need a click. The microphone is closed while Serein speaks.") {
      Toggle("Speak progress in calls", isOn: $speakProgress)
      SettingsNote("Short lines about what Serein is doing, and each question it asks, in its own words. Text from a page is never read out.")
      Toggle("Answer low-risk questions by voice", isOn: $voiceAnswers)
      SettingsNote("In a call, say “allow” for a click, typing, scrolling or going to a page, then “yes” after Serein reads the step back. Sending, posting, paying, deleting, booking, installing and settings always need a click.")
    }
  }
  /// On: asks macOS for speech recognition and the microphone first, and stays off if either is refused.
  private func setWake(_ on: Bool) {
    wakeRefused = nil
    guard on else {
      wake = false
      return
    }
    Task {
      if await WakeListener.requestAccess() {
        wake = true
      } else {
        wakeRefused = "Allow the microphone and speech recognition for Serein in System Settings › Privacy & Security."
      }
    }
  }
  private var wakeNote: String {
    let shortcut = RelayHotKey.symbols(summon)
    let about = "Serein listens on this Mac for its name, opens the \(shortcut) bar with what you say next and sends it when you pause. Nothing said before “Serein” is kept, and approvals still need you."
    if let wakeRefused { return wakeRefused }
    if !summonOn { return "Needs “Ask Serein from any app with \(shortcut)” in Settings › Assistants › Ask from any app. " + about }
    if !wake {
      if TalkLanguageSupport.resolved() == nil {
        return "No language on this Mac can recognize speech without the network, so Serein can't listen for its name."
      }
      return about
    }
    switch listener.state {
    case .off: return about
    case .listening, .hearing:
      return about + " Listening now; the menu bar shows a microphone. Paused while Serein speaks, during a call or dictation, and while the screen is locked."
    case .paused(let why), .unavailable(let why): return why + " " + about
    }
  }
  private var languageNote: String {
    guard let id = TalkLanguageSupport.resolved() else {
      return "No language on this Mac can recognize speech without the network."
    }
    let name = Locale.current.localizedString(forIdentifier: id) ?? id
    return language == TalkLanguage.automatic
      ? "Follows your keyboard when its language is supported. Right now: \(name)."
      : "Listening for \(name). Only languages that work on this Mac are listed."
  }
}
