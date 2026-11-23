import WebKit

/// macOS exposes element fullscreen publicly, but its PiP opt-in still lives on preferences.
/// Keep that compatibility switch guarded, isolated and limited to media presentation.
@MainActor enum BrowserMedia {
  private static let pipGetter = NSSelectorFromString("_allowsPictureInPictureMediaPlayback")
  private static let pipSetter = NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")
  static func configure(_ configuration: WKWebViewConfiguration) {
    configuration.preferences.isElementFullscreenEnabled = true
    let preferences = configuration.preferences
    if preferences.responds(to: pipGetter), preferences.responds(to: pipSetter) {
      preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
    }
  }
  static func allowsPictureInPicture(_ configuration: WKWebViewConfiguration) -> Bool {
    let preferences = configuration.preferences
    guard preferences.responds(to: pipGetter) else { return false }
    return preferences.value(forKey: "_allowsPictureInPictureMediaPlayback") as? Bool == true
  }
}
