import Carbon.HIToolbox
import SereinCore

/// A shortcut that works while another app is in front (Relay's summon and kill switch). Carbon
/// hot keys need no Accessibility access, and macOS refuses one another app already holds.
@MainActor final class GlobalHotKey {
  private static var handlers: [UInt32: () -> Void] = [:]
  private static var releases: [UInt32: () -> Void] = [:]
  private static var nextID: UInt32 = 1
  private static var installed = false
  private var ref: EventHotKeyRef?
  private let id: UInt32

  /// nil when the text is not a shortcut or macOS refused it.
  /// `release` runs when the keys are let go (hold-to-talk).
  init?(_ text: String, release: (() -> Void)? = nil, action: @escaping () -> Void) {
    guard let key = RelayHotKey.parse(text) else { return nil }
    Self.install()
    id = Self.nextID
    Self.nextID += 1
    var hotKey: EventHotKeyRef?
    let status = RegisterEventHotKey(
      key.keyCode, key.modifiers, EventHotKeyID(signature: OSType(0x5352_4C59), id: id),  // 'SRLY'
      GetApplicationEventTarget(), 0, &hotKey)
    guard status == noErr, let hotKey else { return nil }
    ref = hotKey
    Self.handlers[id] = action
    Self.releases[id] = release
  }
  func unregister() {
    if let ref { UnregisterEventHotKey(ref) }
    ref = nil
    Self.handlers[id] = nil
    Self.releases[id] = nil
  }
  private static func install() {
    guard !installed else { return }
    installed = true
    var specs = [
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
      var hotKey = EventHotKeyID()
      GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
      let id = hotKey.id
      let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
      DispatchQueue.main.async {
        MainActor.assumeIsolated { (released ? GlobalHotKey.releases[id] : GlobalHotKey.handlers[id])?() }
      }
      return noErr
    }, specs.count, &specs, nil, nil)
  }
}
