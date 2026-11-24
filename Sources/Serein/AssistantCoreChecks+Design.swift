#if DEBUG
import Foundation
import SereinCore

/// The design system's pure rules: every text pair in both palettes reaches 4.5:1 and every
/// icon or ring pair 3:1 (WCAG 2), Settings search finds pages by everyday words, the loading
/// ladder's stages, and the spacing the owner set (cards 16, gaps 12, one bubble corner).
extension AssistantCoreChecks {
  static func design(_ check: Check) throws {
    try check(abs(Contrast.ratio(0x000000, 0xFFFFFF) - 21) < 0.001, "Black on white measures 21:1")
    try check(abs(Contrast.ratio(0x777777, 0x777777) - 1) < 0.001, "A color on itself measures 1:1")
    try check(Contrast.composite(ThemeWash(0xFFFFFF, 0.5), over: 0x000000) == 0x808080, "Half white over black is mid grey")
    for scheme in [AppearanceScheme.light, .dark] {
      let tokens: ThemeTokens = .tokens(scheme)
      for pair in tokens.textPairs {
        let ratio: Double = Contrast.ratio(pair.foreground, pair.background)
        try check(ratio >= 4.5, "\(scheme.rawValue) \(pair.name) reaches 4.5:1 (\(String(format: "%.2f", ratio)))")
      }
      for pair in tokens.iconPairs {
        let ratio: Double = Contrast.ratio(pair.foreground, pair.background)
        try check(ratio >= 3, "\(scheme.rawValue) \(pair.name) reaches 3:1 (\(String(format: "%.2f", ratio)))")
      }
      try check(tokens.textPairs.contains { $0.name == "indigo/sidebar" }, "\(scheme.rawValue) indigo, the main assistant's tint, is measured too")
    }

    func found(_ query: String) -> [String] { SettingsCategory.search(query).map(\.id) }
    try check(found("mic") == ["Talking"], "Searching mic finds Voice")
    try check(found("Microphone") == ["Talking"], "Searching Microphone finds Voice in any case")
    try check(found("dark") == ["General"], "Searching dark finds General, where the theme is")
    try check(found("dark mode") == ["General"], "Every word of a search must match")
    try check(found("théme") == ["General"], "Accents are ignored")
    try check(found("ai") == ["Agents", "Passwords"], "ai finds AI apps, and the Vault, whose sentence names the AI")
    try check(found("talk") == ["Talking"] && found("alking").isEmpty, "A word matches from its start: alking does not find Talking")
    try check(found("shortcut") == ["General"], "Searching shortcut finds General, where the shortcuts are")
    try check(found("credentials") == ["Passwords"] && found("vault") == ["Passwords"], "Searching credentials or vault finds the Vault")
    try check(found("voice") == ["Talking"], "A page's label still finds it")
    try check(found("history") == ["Privacy"], "An alias still finds its page")
    try check(found("zzz").isEmpty, "A search nothing matches keeps no page")
    try check(found("  ") == SettingsCategory.all.map(\.id), "An empty search keeps every page in list order")
    let ids: Set<String> = Set(SettingsCategory.all.map(\.id))
    try check(Set(SettingsCategory.synonyms.keys).isSubset(of: ids), "Every synonym names a page that exists")
    try check(SettingsCategory.resolve("mic").id == SettingsCategory.general, "A synonym never opens a page by name")

    try check(LoadingStage(waited: 0) == .blank, "A load shows nothing at first")
    try check(LoadingStage(waited: 0.19) == .blank, "A load under 0.2 seconds never flashes a skeleton")
    try check(LoadingStage(waited: 0.2) == .skeleton, "From 0.2 seconds a skeleton shows")
    try check(LoadingStage(waited: 7.9) == .skeleton, "The skeleton holds until 8 seconds")
    try check(LoadingStage(waited: 8) == .slow, "From 8 seconds a plain line says it is slow")
    try check(LoadingStage.moments == [0.2, 8], "The ladder changes at 0.2 and 8 seconds, in order")

    try check(AssistantMetrics.cardGap == 12, "Cards sit 12 apart")
    try check(UIStyle.bubbleRadius == AssistantMetrics.bubbleRadius && AssistantMetrics.bubbleRadius == 18, "Every chat bubble has one 18-point corner")
    try check(UIStyle.focusRing == 2, "The keyboard's ring is 2 points")
    try check(Set(AssistantInspector.Tab.allCases) == [.activity, .library, .details],
              "The inspector defines only what it draws: Activity, Library, and Details from its settings button")
    try check(AssistantInspector.Tab(rawValue: "tasks") == nil && AssistantInspector.Tab(rawValue: "computer") == nil,
              "Tasks is part of Activity, so no Tasks tab is left to show")
  }
}
#endif
