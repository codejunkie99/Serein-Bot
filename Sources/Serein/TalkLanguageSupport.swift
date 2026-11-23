import Carbon.HIToolbox
import Foundation
import Speech
import SereinCore

/// What Apple Speech can recognize on this Mac without the network, and which of it to use now.
enum TalkLanguageSupport {
  private static var cached: [String]?

  /// Every locale that recognizes on-device. Probed once per launch.
  static func supported() -> [String] {
    if let cached { return cached }
    let ids = SFSpeechRecognizer.supportedLocales().filter {
      SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true
    }.map(\.identifier)
    cached = ids
    return ids
  }

  static func choices() -> [TalkLanguage.Choice] {
    TalkLanguage.choices(
      supported: supported().map { id in
        (id, Locale.current.localizedString(forIdentifier: id) ?? id)
      })
  }

  /// Languages of the current keyboard input source, e.g. ["fr"].
  static func keyboardLanguages() -> [String] {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
      let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
    else { return [] }
    return (Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String]) ?? []
  }

  static var preference: String {
    UserDefaults.standard.string(forKey: TalkLanguage.defaultsKey) ?? TalkLanguage.system
  }

  /// The locale identifier to recognize in right now, or nil when this Mac has none for the choice.
  static func resolved() -> String? {
    TalkLanguage.resolve(
      preference: preference, supported: supported(), system: Locale.preferredLanguages,
      keyboard: keyboardLanguages())
  }
}
