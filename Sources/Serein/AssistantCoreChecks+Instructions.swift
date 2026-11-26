#if DEBUG
import Foundation
import SereinCore

/// One Instructions box per assistant (`AssistantInstructions`): what it shows, where it saves,
/// the one-time move of the old fields, and the assistant page's sections. No window, no model.
extension AssistantCoreChecks {
  static func instructionsBox(_ check: Check) throws {
    // Serein's instructions are free text now: the person's own lines, blank lines and all.
    let free = RelayPersona(rules: "  Keep replies short.\n\nNever book before asking.\nOne\nTwo\nThree\nFour\nFive  ")
    try check(free.sanitized()?.rules == "Keep replies short.\n\nNever book before asking.\nOne\nTwo\nThree\nFour\nFive",
      "Serein's instructions keep the person's lines, more than six of them, trimmed only at the ends")
    let long = RelayPersona(rules: String(repeating: "a", count: AssistantInstructions.limit + 50))
    try check(long.sanitized()?.rules.count == AssistantInstructions.limit, "Serein's instructions stop at the box's limit")
    try check(RelayPersona(name: "Serein", rules: "Keep replies short.\nNo emoji.").prompt()
      .hasSuffix("Serein asks before actions whatever they say.\nKeep replies short.\nNo emoji."),
      "The prompt carries the instructions as typed, after the line that they grant nothing")

    let scoped = AssistantScope(destinations: [.web], instructions: "Who you are: Plans trips.\nPrefer trains.")
    let oldSerein = RelayPersona(name: "Serein", about: "I run a coffee shop", rules: "Never book before asking.")
    try check(AssistantInstructions.savesInPersona(scope: scoped, main: true)
      && AssistantInstructions.savesInPersona(scope: nil, main: false)
      && !AssistantInstructions.savesInPersona(scope: scoped, main: false),
      "Serein's box and a box of an assistant with no scope save in the persona; another assistant's in its scope")
    try check(AssistantInstructions.text(persona: oldSerein, scope: scoped, main: true)
      == "About me: I run a coffee shop\nNever book before asking.\nWho you are: Plans trips.\nPrefer trains.",
      "Serein's box shows every old field still in force, its persona's first")
    try check(AssistantInstructions.text(persona: oldSerein, scope: scoped, main: false)
      == "Who you are: Plans trips.\nPrefer trains.\nAbout me: I run a coffee shop\nNever book before asking.",
      "Another assistant's box shows its scope's words first, then any left in its persona")

    // The one-time move.
    let moved = AssistantInstructions.merged(persona: oldSerein, scope: scoped, main: true)
    try check(moved?.persona == RelayPersona(name: "Serein", rules: "About me: I run a coffee shop\nNever book before asking.\nWho you are: Plans trips.\nPrefer trains.")
      && moved?.scopeInstructions == "",
      "Serein's line about you and its job and extra instructions move into its persona; its scope keeps only what it may use")
    try check(AssistantInstructions.merged(persona: oldSerein, scope: nil, main: true)?.scopeInstructions == nil,
      "Serein with no scope gets no scope from the move, so it keeps following the person's places")
    try check(AssistantInstructions.merged(persona: RelayPersona(name: "Serein", rules: "No emoji."), scope: nil, main: true) == nil,
      "Words already in one place are not moved again")
    let other = AssistantInstructions.merged(
      persona: RelayPersona(name: "Planner", rules: "Prefer window seats."), scope: scoped, main: false)
    try check(other?.persona == RelayPersona(name: "Planner")
      && other?.scopeInstructions == "Who you are: Plans trips.\nPrefer trains.\nPrefer window seats.",
      "Another assistant's persona words move into its scope, and its name stays")
    try check(AssistantInstructions.merged(persona: RelayPersona(name: "Planner", rules: "Prefer window seats."), scope: nil, main: false) == nil,
      "An assistant with no scope keeps its words in its persona, where they do not fix its places")
    let full = AssistantScope(destinations: [.web], instructions: String(repeating: "b", count: AssistantInstructions.limit - 5))
    try check(AssistantInstructions.merged(persona: oldSerein, scope: full, main: true) == nil,
      "Words that would not fit together stay where they are, in force, rather than lose any")

    // Saving the box.
    let save = AssistantInstructions.saved("  Short replies.  ", persona: oldSerein, scope: scoped, main: true)
    try check(save.persona == RelayPersona(name: "Serein", rules: "Short replies.") && save.scopeInstructions == "",
      "Saving Serein's box writes its persona and empties its scope's old words")
    try check(AssistantInstructions.saved("Short replies.", persona: RelayPersona(name: "Serein"), scope: AssistantScope(destinations: [.web]), main: true)
      .scopeInstructions == nil, "A scope with no words is left as it is")
    let saveOther = AssistantInstructions.saved("Prefer trains.", persona: RelayPersona(name: "Planner", rules: "Old."), scope: scoped, main: false)
    try check(saveOther.persona == RelayPersona(name: "Planner") && saveOther.scopeInstructions == "Prefer trains.",
      "Saving another assistant's box writes its scope and empties its persona's words")

    // The page: Instructions and Routines shown, the detail under Advanced, old links still open.
    try check(AssistantSettingsKey.order == [AssistantSettingsKey.does, AssistantSettingsKey.routines]
      && AssistantSettingsKey.advanced == [AssistantSettingsKey.apps, AssistantSettingsKey.memory, AssistantSettingsKey.asks, AssistantSettingsKey.links],
      "An assistant's page shows Instructions and Routines, with Apps, Memory, Asks first and Links under Advanced")
    try check(AssistantSettingsKey.titles[AssistantSettingsKey.does] == "Instructions"
      && AssistantSettingsKey.all == Set(AssistantSettingsKey.order + AssistantSettingsKey.advanced) && AssistantSettingsKey.all.count == 6,
      "Every old sub-page is still a section a link can open")
  }
}
#endif
