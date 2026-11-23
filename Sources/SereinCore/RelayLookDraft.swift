import Foundation

/// The customise sheet's choice: a look and a colour, held apart from the stored look until Save.
/// Cancel drops it, so nothing it picked reaches `RelayLookStore`.
public struct RelayLookDraft: Equatable, Sendable {
  /// The look Serein wears now.
  public let worn: RelayLook
  public private(set) var look: RelayLook
  public private(set) var palette: RelayLook.Palette

  public init(worn: RelayLook) {
    self.worn = worn
    look = worn
    palette = worn.palette
  }

  /// What Settings' "Ask Serein for a new look" sends and the sheet's "Design one" drafts.
  public static let designPrompt = "Design yourself a new look for me. Read your design-your-look skill, surprise me, then show me the tour."

  /// The colours: every preset's palette once, after the worn one when no preset wears it.
  public var colours: [RelayLook.Palette] {
    var out: [RelayLook.Palette] = RelayLook.presets.contains { $0.palette == worn.palette } ? [] : [worn.palette]
    for palette in RelayLook.presets.map(\.palette) where !out.contains(palette) { out.append(palette) }
    return out
  }
  /// The looks: the presets, after the worn one when Serein designed it.
  public var looks: [RelayLook] {
    (RelayLook.presets.contains(worn) ? [] : [worn]) + RelayLook.presets
  }
  /// A look's tile title: a preset saved in another colour keeps the preset's name, so the worn one says Yours.
  public func title(of look: RelayLook) -> String {
    look == worn && !RelayLook.presets.contains(worn) && RelayLook.presets.contains { $0.name == worn.name }
      ? "Yours" : look.name
  }
  /// A colour's name for VoiceOver: the preset that wears it, or Current.
  public static func name(of palette: RelayLook.Palette) -> String {
    RelayLook.presets.first { $0.palette == palette }?.name ?? "Current"
  }

  /// A look comes in its own colour; a colour picked after it recolours it.
  public mutating func choose(_ look: RelayLook) {
    self.look = look
    palette = look.palette
  }
  public mutating func choose(_ palette: RelayLook.Palette) { self.palette = palette }

  /// The look in the chosen colour, through `applying` like every other look.
  public func chosen() throws -> RelayLook {
    try look.applying(["palette": ["primary": palette.primary, "rim": palette.rim]])
  }
  /// What Save stores, or nil when it would change nothing.
  public func saved() throws -> RelayLook? {
    let next: RelayLook = try chosen()
    return next == worn ? nil : next
  }
}
