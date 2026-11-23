import Foundation

/// Settings › Appearance. System follows macOS and is the default.
public enum AppearancePreference: String, CaseIterable, Sendable {
  case system, light, dark
  public static let defaultsKey = "serein.appearance"
  /// Unknown or missing values fall back to System.
  public init(stored: String?) {
    self = stored.flatMap(AppearancePreference.init(rawValue:)) ?? .system
  }
  public var label: String {
    switch self {
    case .system: return "System"
    case .light: return "Light"
    case .dark: return "Dark"
    }
  }
  /// The palette to draw with, given whether macOS itself is currently dark.
  public func resolve(systemIsDark: Bool) -> AppearanceScheme {
    switch self {
    case .system: return systemIsDark ? .dark : .light
    case .light: return .light
    case .dark: return .dark
    }
  }
}

public enum AppearanceScheme: String, Sendable {
  case light, dark
  /// "Darken light webpages" only applies while the app itself is dark.
  public func darkensPages(setting: Bool) -> Bool { self == .dark && setting }
  /// Whether a hologram is drawn as ink (for a light backdrop) or as light. In Serein's own
  /// windows the backdrop is Serein's palette. The ⌥Space hologram floats over other apps, which
  /// follow macOS: light on a white page showed almost nothing while Serein alone was dark.
  public static func hologramInk(sereinIsDark: Bool, macIsDark: Bool, overOtherApps: Bool) -> Bool {
    !(overOtherApps ? macIsDark : sereinIsDark)
  }
}

/// A translucent token: a base color laid over whatever is beneath it.
public struct ThemeWash: Equatable, Sendable {
  public var rgb: UInt32
  public var alpha: Double
  public init(_ rgb: UInt32, _ alpha: Double) {
    self.rgb = rgb
    self.alpha = alpha
  }
}

/// One assistant tint: the key a profile stores (`AssistantColour.all`), the word the editor's
/// swatch reads, and its sRGB value in this palette.
public struct AssistantTint: Equatable, Sendable {
  public var key: String
  public var name: String
  public var rgb: UInt32
  public init(_ key: String, _ name: String, _ rgb: UInt32) {
    self.key = key
    self.name = name
    self.rgb = rgb
  }
}

/// The color tokens of one palette, as sRGB values. `Palette` in the app reads these, so the
/// contrast checks below always test the colors that are drawn.
public struct ThemeTokens: Equatable, Sendable {
  public var background, sidebar, card, panel, overlay, raised: UInt32
  public var ink, secondary, faint, accent, accentStrong: UInt32
  /// The keyboard's ring on a control that draws its own chrome (`keyboardFocusRing`), and the frame
  /// round a computer screen the person controls.
  public var focus: UInt32
  public var solid, onSolid, onAccent: UInt32
  public var success, danger, warning: UInt32
  public var privateBackground, privateAccent: UInt32
  public var line, borderStrong, hover, selected, scrim, bubble, track: ThemeWash
  /// The eight assistant tints, in the order new assistants take them. Only an assistant's petal
  /// and the editor's swatch use them; none is the warning amber, the danger red or the success
  /// green, so a petal never reads as a state. Indigo, the main assistant's, is a violet-blue
  /// apart from the blue `accent`.
  public var assistantTints: [AssistantTint]
  public func assistantTint(_ key: String?) -> UInt32 {
    assistantTints.first { $0.key == AssistantColour.key(key) }?.rgb ?? accent
  }

  /// Grok's dark set: flat planes, every grey #F5F5F5 at an alpha (secondary and faint are
  /// those alphas flattened over #121212), no shadows. Accent is one step lighter than Grok's
  /// #1680F3 (4.25:1 on `overlay`) so small accent text clears 4.5:1 on every plane.
  public static let dark = ThemeTokens(
    background: 0x121212, sidebar: 0x0E0E0E, card: 0x121212, panel: 0x161616, overlay: 0x1F1F1F,
    raised: 0x1F1F1F,
    ink: 0xF5F5F5, secondary: 0xA8A8A8, faint: 0x8D8D8D, accent: 0x1E87F6, accentStrong: 0x126FD4,
    focus: 0x1884FC,
    solid: 0xF5F5F5, onSolid: 0x121212, onAccent: 0xFFFFFF,
    success: 0x00BA69, danger: 0xFF6463, warning: 0xE28600,
    privateBackground: 0x0B090F, privateAccent: 0xB79CFF,
    line: ThemeWash(0xF5F5F5, 0.102), borderStrong: ThemeWash(0xF5F5F5, 0.22),
    hover: ThemeWash(0xF5F5F5, 0.059), selected: ThemeWash(0xF5F5F5, 0.078),
    scrim: ThemeWash(0x000000, 0.70), bubble: ThemeWash(0xF5F5F5, 0.059),
    track: ThemeWash(0xF5F5F5, 0.059),
    assistantTints: [
      AssistantTint("sky", "Sky", 0x5EB1FF), AssistantTint("teal", "Teal", 0x3CC7C0),
      AssistantTint("violet", "Violet", 0xB48CFF), AssistantTint("rose", "Rose", 0xFF7EB3),
      AssistantTint("tangerine", "Tangerine", 0xFF9A5C), AssistantTint("moss", "Moss", 0xA3C76A),
      AssistantTint("slate", "Slate", 0xA8B3C7), AssistantTint("indigo", "Indigo", 0x7C86FF),
    ])

  /// Grok's light set: chrome #FCFCFC, sidebar #F5F5F5, panes white, every grey #1C1C1C at an
  /// alpha (secondary flattened over #FCFCFC). Faint and accent are one step darker than Grok's
  /// tertiary and action blue, and success and warning darker than the earlier #00854A and #AA6300
  /// (4.32 and 4.29:1 on the sidebar), so small text clears 4.5:1 there.
  public static let light = ThemeTokens(
    background: 0xFCFCFC, sidebar: 0xF5F5F5, card: 0xFCFCFC, panel: 0xFFFFFF, overlay: 0xFFFFFF,
    raised: 0xFFFFFF,
    ink: 0x1C1C1C, secondary: 0x646464, faint: 0x707070, accent: 0x126FD4, accentStrong: 0x126FD4,
    focus: 0x1E86FC,
    solid: 0x1C1C1C, onSolid: 0xFCFCFC, onAccent: 0xFFFFFF,
    success: 0x008048, danger: 0xCD2834, warning: 0xA35F00,
    privateBackground: 0xF5F1FC, privateAccent: 0x6A3FCB,
    line: ThemeWash(0x1C1C1C, 0.122), borderStrong: ThemeWash(0x1C1C1C, 0.239),
    hover: ThemeWash(0x1C1C1C, 0.059), selected: ThemeWash(0x1C1C1C, 0.078),
    scrim: ThemeWash(0x000000, 0.50), bubble: ThemeWash(0x1C1C1C, 0.059),
    track: ThemeWash(0x1C1C1C, 0.059),
    assistantTints: [
      AssistantTint("sky", "Sky", 0x0A5CA8), AssistantTint("teal", "Teal", 0x0D6B64),
      AssistantTint("violet", "Violet", 0x7136D6), AssistantTint("rose", "Rose", 0xB3165A),
      AssistantTint("tangerine", "Tangerine", 0xA3410D), AssistantTint("moss", "Moss", 0x4A661D),
      AssistantTint("slate", "Slate", 0x4B5568), AssistantTint("indigo", "Indigo", 0x4F46E5),
    ])

  public static func tokens(_ scheme: AppearanceScheme) -> ThemeTokens {
    scheme == .dark ? .dark : .light
  }

  /// Text/background pairs that carry body or small text and must reach 4.5:1.
  /// `faint` on `raised` is excluded: only icons use it there.
  public var textPairs: [(name: String, foreground: UInt32, background: UInt32)] {
    var pairs: [(String, UInt32, UInt32)] = []
    let planes: [(String, UInt32)] = [
      ("background", background), ("sidebar", sidebar), ("card", card), ("panel", panel),
      ("overlay", overlay),
    ]
    let inks: [(String, UInt32)] = [
      ("ink", ink), ("secondary", secondary), ("faint", faint), ("accent", accent),
      ("success", success), ("danger", danger), ("warning", warning),
    ]
    for (inkName, inkValue) in inks {
      for (planeName, planeValue) in planes { pairs.append(("\(inkName)/\(planeName)", inkValue, planeValue)) }
    }
    pairs.append(("ink/raised", ink, raised))
    pairs.append(("secondary/raised", secondary, raised))
    for (planeName, planeValue) in [("background", background), ("sidebar", sidebar), ("card", card)] {
      pairs.append(("ink/selected·\(planeName)", ink, Contrast.composite(selected, over: planeValue)))
      pairs.append(("secondary/selected·\(planeName)", secondary, Contrast.composite(selected, over: planeValue)))
      pairs.append(("ink/hover·\(planeName)", ink, Contrast.composite(hover, over: planeValue)))
    }
    pairs.append(("ink/bubble·background", ink, Contrast.composite(bubble, over: background)))
    // The ⌥Space bar's reply card: your words in a bubble on the panel card.
    pairs.append(("ink/bubble·panel", ink, Contrast.composite(bubble, over: panel)))
    pairs.append(("ink/track·background", ink, Contrast.composite(track, over: background)))
    // The Working strip's chips and a task's pill: the detail in secondary on the track capsule.
    pairs.append(("secondary/track·background", secondary, Contrast.composite(track, over: background)))
    // Assistant petals on every plane they sit on, the sidebar's washes included.
    for tint in assistantTints {
      for (planeName, planeValue) in planes + [("raised", raised)] {
        pairs.append(("\(tint.key)/\(planeName)", tint.rgb, planeValue))
      }
      pairs.append(("\(tint.key)/hover·sidebar", tint.rgb, Contrast.composite(hover, over: sidebar)))
      pairs.append(("\(tint.key)/selected·sidebar", tint.rgb, Contrast.composite(selected, over: sidebar)))
    }
    pairs.append(("onSolid/solid", onSolid, solid))
    pairs.append(("privateAccent/privateBackground", privateAccent, privateBackground))
    pairs.append(("ink/privateBackground", ink, privateBackground))
    return pairs.map { (name: $0.0, foreground: $0.1, background: $0.2) }
  }

  /// Pairs that carry only icons, rings or large text and must reach 3:1: `faint` icons on
  /// `raised`, the focus ring on every plane, and the white glyph on an accent plate (send, a step's check).
  public var iconPairs: [(name: String, foreground: UInt32, background: UInt32)] {
    var pairs: [(String, UInt32, UInt32)] = [("faint/raised", faint, raised), ("onAccent/accent", onAccent, accent)]
    let planes: [(String, UInt32)] = [
      ("background", background), ("sidebar", sidebar), ("card", card), ("panel", panel),
      ("overlay", overlay), ("raised", raised),
    ]
    for (planeName, planeValue) in planes { pairs.append(("focus/\(planeName)", focus, planeValue)) }
    return pairs.map { (name: $0.0, foreground: $0.1, background: $0.2) }
  }
}

/// WCAG 2 relative luminance and contrast ratio for sRGB hex colors.
public enum Contrast {
  public static func luminance(_ rgb: UInt32) -> Double {
    func channel(_ shift: UInt32) -> Double {
      let c = Double((rgb >> shift) & 255) / 255
      return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
  }
  public static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
    let la = luminance(a), lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  }
  /// The opaque color a wash produces over an opaque plane (straight sRGB alpha blending).
  public static func composite(_ wash: ThemeWash, over base: UInt32) -> UInt32 {
    func mix(_ shift: UInt32) -> UInt32 {
      let top = Double((wash.rgb >> shift) & 255), bottom = Double((base >> shift) & 255)
      return UInt32((top * wash.alpha + bottom * (1 - wash.alpha)).rounded()) << shift
    }
    return mix(16) | mix(8) | mix(0)
  }
}
