import Foundation

/// "Cmd-S", "Shift-Cmd-Z", "Return", "Down": a key name with optional modifiers, resolved to the
/// virtual key code and modifier set a keyboard event needs.
public struct MacKey: Equatable {
  public var code: Int
  public var command = false
  public var shift = false
  public var option = false
  public var control = false
  public init(code: Int, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
    self.code = code
    self.command = command
    self.shift = shift
    self.option = option
    self.control = control
  }
  static let named: [String: Int] = [
    "return": 36, "enter": 36, "keypadenter": 76, "kpenter": 76, "numpadenter": 76,
    "tab": 48, "space": 49, "delete": 51, "backspace": 51,
    "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
    "f9": 101, "f10": 109, "f11": 103, "f12": 111,
  ]
  static let letters: [Character: Int] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
    "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
    "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
    "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
    ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
  ]
  /// "Cmd+Return", "cmd-return" or "Return": the lower-cased parts, split on "-" and "+" exactly
  /// as `parse` splits them.
  static func parts(_ text: String) -> [String] {
    // "-" is both the separator and a key: a trailing "-" (or a lone one) names the minus key.
    var parts = text.split(whereSeparator: { $0 == "-" || $0 == "+" }).map { $0.lowercased() }
    if text == "-" || (text.count > 2 && text.hasSuffix("--")) { parts.append("-") }
    return parts
  }
  /// The key itself and whether a modifier is held, for judging a step: “Cmd+Return” and
  /// “Cmd-Return” both read ("return", true). The same split `parse` uses, so a key that runs
  /// is always judged as the key it is.
  public static func judged(_ text: String) -> (base: String, modified: Bool) {
    let parts = Self.parts(text)
    return (parts.last ?? "", parts.count > 1)
  }
  /// nil when the name is not a key this surface sends (so arbitrary text never leaks through).
  public static func parse(_ text: String) -> MacKey? {
    let parts = Self.parts(text)
    guard let last = parts.last, !last.isEmpty else { return nil }
    var key: MacKey
    if let code = named[last] {
      key = MacKey(code: code)
    } else if last.count == 1, let code = letters[Character(last)] {
      key = MacKey(code: code)
    } else {
      return nil
    }
    for modifier in parts.dropLast() {
      switch modifier {
      case "cmd", "command", "⌘": key.command = true
      case "shift", "⇧": key.shift = true
      case "opt", "option", "alt", "⌥": key.option = true
      case "ctrl", "control", "⌃": key.control = true
      default: return nil
      }
    }
    return key
  }
}
