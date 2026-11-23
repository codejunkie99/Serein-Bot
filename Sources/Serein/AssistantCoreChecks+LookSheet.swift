#if DEBUG
import Foundation
import SereinCore

/// The customise sheet (RelayLookSheet.swift): what it lists, what Save stores, and that Cancel stores nothing.
extension AssistantCoreChecks {
  static func lookSheet(_ check: Check) throws {
    let presets: [RelayLook] = RelayLook.presets
    try check(presets.count >= 3, "Serein has at least three looks to choose from")
    let ember: RelayLook = presets[presets.count > 3 ? 3 : 1]
    let other: RelayLook.Palette = presets[2].palette

    var draft = RelayLookDraft(worn: .serein)
    try check(
      draft.looks == presets && draft.colours == presets.map(\.palette) && draft.colours.first == RelayLook.serein.palette,
      "Wearing a preset, the sheet lists every preset and each preset's colour once, the worn one first")
    try check((try draft.saved()) == nil, "Save with nothing picked stores nothing")

    draft.choose(ember)
    try check(draft.palette == ember.palette && (try draft.chosen()) == ember, "A look comes in its own colour")
    draft.choose(other)
    let saved: RelayLook? = try draft.saved()
    try check(
      saved?.palette == other && saved?.states == ember.states && saved?.name == ember.name && saved?.problems().isEmpty == true,
      "A colour picked after a look recolours it, and the result is a whole look that passes `applying`")

    var store = RelayLookStore()
    let before: RelayLookStore = store
    var cancelled = RelayLookDraft(worn: store.look)
    cancelled.choose(ember)
    cancelled.choose(other)
    try check(store == before, "Cancel stores nothing: picks live in the draft until Save")
    if let saved { store.set(saved, by: .you) }
    try check(store.look == saved && store.current.by == .you && store.history.count == 1,
              "Save stores the chosen look as the person's, with the old one kept for Undo")

    var back = RelayLookDraft(worn: ember)
    back.choose(other)
    back.choose(ember)
    try check((try back.saved()) == nil, "Picking the worn look again stores nothing")

    let designed: RelayLook = try RelayLook.serein.applying(["name": "Mint", "palette": ["primary": "#22cc88", "rim": "#aaffdd"]])
    let custom = RelayLookDraft(worn: designed)
    try check(
      custom.looks.first == designed && custom.looks.count == presets.count + 1
        && custom.colours.first == designed.palette && custom.colours.count == presets.count + 1
        && RelayLookDraft.name(of: designed.palette) == "Current" && RelayLookDraft.name(of: ember.palette) == ember.name,
      "A look Serein designed is listed first, with its colour first as Current")
    var recoloured = RelayLookDraft(worn: ember)
    recoloured.choose(RelayLook.serein.palette)
    let wornAfter: RelayLook = try recoloured.chosen()
    let after = RelayLookDraft(worn: wornAfter)
    try check(
      after.title(of: wornAfter) == "Yours" && after.title(of: ember) == ember.name && custom.title(of: designed) == "Mint",
      "A preset saved in another colour reads Yours, so no two tiles share a name")
    try check(!RelayLookDraft.designPrompt.isEmpty, "Design one has words to draft")
  }
}
#endif
