#if DEBUG
import Foundation
import SereinCore

/// "Let Serein read my whole Mac" (`MacFiles`): the home folder and drives open, every closed
/// place still closed, and the switch off unless stored on. Paths only; nothing is read.
extension AssistantCoreChecks {
  static func macFiles(_ check: Check) throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let library = home.appendingPathComponent("Library/Application Support/Serein/Library")
    let closed = AgentFileGuard.sereinPrivateRoots(home: home, library: library)
    func allows(_ path: String) -> Bool { MacFiles.allows(path, home: home, privateRoots: closed) }
    try check(allows(home.appendingPathComponent("Documents/Posts/2026-11-02.md").path),
      "A post in Documents can be read")
    try check(allows("/Volumes/Drive/Notes/idea.txt"), "A file on a mounted drive can be read")
    try check(allows("~/Desktop/plan.pdf"), "A ~ path is the home folder")
    try check(!allows("/etc/passwd") && !allows("/Applications/Serein.app/Contents/Info.plist"),
      "Nothing outside the home folder and drives")
    try check(!allows(home.appendingPathComponent(".ssh/id_ed25519").path), "SSH keys stay closed")
    try check(!allows(home.appendingPathComponent("Library/Mail/V10/x.emlx").path)
      && !allows(home.appendingPathComponent("Library/Messages/chat.db").path),
      "Mail and Messages stay closed")
    try check(!allows(home.appendingPathComponent("Library/Keychains/login.keychain-db").path)
      && !allows(home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Cookies").path),
      "Keychains and browser cookies stay closed")
    try check(!allows(home.appendingPathComponent("Library/Preferences/x.plist").path), "All of ~/Library stays closed")
    try check(!allows(home.appendingPathComponent(".claude/settings.json").path)
      && !allows(home.appendingPathComponent(".codex/auth.json").path), "AI apps' sign-ins stay closed")
    try check(!allows(home.appendingPathComponent("Code/app/.env").path)
      && !allows(home.appendingPathComponent("Downloads/passwords.csv").path)
      && !allows(home.appendingPathComponent("Documents/cert.p12").path), "Credential files stay closed anywhere")
    try check(!allows(home.appendingPathComponent("Documents/../.ssh/config").path), "Climbing out with .. is resolved first")
    try check(allows(home.appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents/Brain/post.md").path),
      "iCloud Drive, Obsidian vaults included, is the person's documents")
    try check(!allows(home.appendingPathComponent("Library/Mail/V10/x.emlx").path)
      && !allows(home.appendingPathComponent("Library/Mobile Documents/../Cookies/Cookies.binarycookies").path),
      "The rest of Library stays closed, even by climbing out of iCloud Drive")
    let suite = "serein.checks.macFiles." + UUID().uuidString
    guard let store = UserDefaults(suiteName: suite) else { throw SereinError.invalid("No scratch settings") }
    defer { store.removePersistentDomain(forName: suite) }
    try check(MacFiles.readsWholeMac(defaults: store), "On from the start: the person's Mac already holds who they are")
    store.set(false, forKey: MacFiles.wholeMacKey)
    try check(!MacFiles.readsWholeMac(defaults: store), "Off once the person turns it off")
    try check(MacFiles.pages(for: 0) == 1 && MacFiles.range(page: 1, of: 0) == 0..<0, "An empty file is one page")
    try check(MacFiles.pages(for: 3_000) == 1 && MacFiles.range(page: 2, of: 3_000) == nil, "A short file is just the skim")
    try check(MacFiles.range(page: 1, of: 50_000) == 0..<3_000, "Page 1 is a 3,000-character skim")
    try check(MacFiles.pages(for: 50_000) == 4 && MacFiles.range(page: 2, of: 50_000) == 3_000..<23_000
      && MacFiles.range(page: 4, of: 50_000) == 43_000..<50_000, "Later pages are 20,000 characters, ending at the end")
    try check(MacFiles.range(page: 0, of: 50_000) == nil && MacFiles.range(page: 5, of: 50_000) == nil, "No page outside the file")
    try check(MacFiles.tools.count == MacFiles.toolNames.count
      && MacFiles.tools.allSatisfy { MacFiles.toolNames.contains($0["name"] as? String ?? "") }
      && RelayTools.names.isSuperset(of: MacFiles.toolNames), "Every file tool is declared and listed for Relay")
    // Reading turns on only from the person's click: a tool call can show the card, never store a yes.
    typealias Call = MacFiles.Call
    func call(on: Bool = false, personStarted: Bool = true, mayOffer: Bool = true, declinedHere: Bool = false) -> Call {
      MacFiles.call(on: on, personStarted: personStarted, mayOffer: mayOffer, declinedHere: declinedHere)
    }
    let turns = [true, false]
    let whileOff = turns.flatMap { started in turns.flatMap { offer in turns.map { declined in
      call(personStarted: started, mayOffer: offer, declinedHere: declined)
    } } }
    try check(whileOff.allSatisfy { $0 != .read && $0.refusal != nil },
      "While reading is off no file tool call reads, whoever started the turn")
    try check(call() == .offer && call(declinedHere: true) == .declined
      && call(personStarted: false, mayOffer: false) == .off && call(mayOffer: false) == .off,
      "Asked about files while reading is off, Serein shows the card: not again after Not now in that chat, and only in a turn the person started")
    try check(call(on: true) == .read && call(on: true).refusal == nil
      && call(on: true, personStarted: false) == .unattended,
      "Once the person allowed it, files are read in turns they started and no others")
    let offered = try? SereinSetup.topic(["topic": "files"])
    let withValue = try? SereinSetup.topic(["topic": "files", "on": true])
    try check(offered == .files && withValue == nil, "The assistant's offer names the card and can carry no value")
    let said = [Call.offer, .declined, .off].compactMap(\.refusal).joined() + MacFiles.promptLine(readsWholeMac: false)
    try check(!said.contains("Settings ›") && MacFiles.promptLine(readsWholeMac: false).contains("setup_offer with topic files"),
      "While reading is off the assistant is pointed at the card in the chat, never at Settings")
    try check(MacFiles.consent.contains("never changes, moves or deletes") && MacFiles.consent.contains("sent to your AI app")
      && MacFiles.macAsks.contains("Allow is enough") && !MacFiles.macAsks.contains("Full Disk Access"),
      "The consent says it is read-only and where it goes; macOS's own prompts are enough")
  }

  /// The bundled UI SDK skill: listed for Serein, with its references, and aimed at web pages only.
  static func uiSDKSkill(_ check: Check) throws {
    guard let skill = PluginHost.builtInSkills.first(where: { $0.name == "ui-sdk" }) else {
      throw SereinError.invalid("The bundled ui-sdk skill is missing.")
    }
    try check(skill.description.contains("web page") && skill.description.contains("Not for Serein's own native screens"),
      "The ui-sdk skill is for web pages Serein builds, never its own screens")
    try check(skill.instructions.contains("## In Serein") && skill.instructions.contains("agent_start"),
      "The ui-sdk skill says how to brief an agent that builds a site")
    let files = SkillParser.files(of: skill)
    try check(["references/build-interface.md", "references/agent-ready.md", "references/web-components.md"]
      .allSatisfy { name in files.contains { $0.hasSuffix(name) } }, "The ui-sdk skill's references ship with it")
  }

  static func codeFormat(_ check: Check) throws {
    let F = CodeFormat.self
    try check(F.name("x", language: "swift") == "Swift" && F.name("x", language: "ts") == "TypeScript"
      && F.name("x", language: "dockerfile") == "Dockerfile", "A labelled code box reads its format by name")
    try check(F.name("Vercel just killed the component library!!\n\nStill in beta.", language: nil) == "Text",
      "An unlabelled post draft reads Text")
    try check(F.name("{\"a\": 1}", language: nil) == "JSON", "Unlabelled JSON reads JSON")
    try check(F.name("$ swift build\n", language: nil) == "Shell" && F.name("git status", language: nil) == "Shell",
      "Unlabelled commands read Shell")
    try check(F.name("## Plan\n- one\n- two", language: nil) == "Markdown", "Unlabelled Markdown reads Markdown")
    try check(F.name("let value = 1\nprint(value)", language: nil) == "Code", "Unlabelled code reads Code")
    try check(F.name("{ not json", language: nil) != "JSON", "Broken JSON is not called JSON")
  }
  static func cardPlacement(_ check: Check) throws {
    let P = ApprovalPlacement.self
    try check(P.place(chatOnScreen: false, barShown: false, windowKey: false, frontFullScreen: false, screenAvailable: true,
      chatVisible: true) == .notificationOnly, "A card with Serein's chat on screen beside another app stays in the chat")
    try check(P.place(chatOnScreen: false, barShown: false, windowKey: false, frontFullScreen: false, screenAvailable: true) == .bar,
      "A card while Serein is out of view opens the bar")
    try check(P.place(chatOnScreen: false, barShown: true, windowKey: false, frontFullScreen: false, screenAvailable: true,
      chatVisible: true) == .barUp, "A bar already up keeps its card")
    try check(RelayPrompt.virtualMacState(.paused, setup: nil).contains("wakes it")
      && RelayPrompt.virtualMacState(.stopped, setup: nil).contains("wakes it"),
      "An asleep virtual Mac reads as usable, not unavailable")
    try check(RelayPrompt.virtualMacState(.running, setup: nil) == "ready for computer_* tools", "A running Mac is ready")
    try check(MacComputerPolicy.takesPrivateChats(internet: false) && MacComputerPolicy.takesPrivateChats(internet: true),
      "Serein's own Mac is Serein's: every chat may use it")
    try check(MacComputerPolicy.networkOn(stored: nil) && MacComputerPolicy.networkOn(stored: true)
      && !MacComputerPolicy.networkOn(stored: false), "Serein's Mac is online by default; the person's Off holds")
    try check(MacVirtualComputer.resumeTag(build: "abc", online: false) == "abc"
      && MacVirtualComputer.resumeTag(build: "abc", online: true) != "abc",
      "Memory saved offline or by an older Serein never restores onto a Mac with a network card")
    try check((try? SereinSetup.topic(["topic": "files"])) == .files, "Serein can offer reading the Mac on a card")
    let offLine = MacFiles.promptLine(readsWholeMac: false)
    try check(offLine.contains("setup_offer with topic files") && offLine.contains("never guess"),
      "With reading off, Serein offers the card instead of sending the person to Settings")
    try check(MacFiles.promptLine(readsWholeMac: true).contains("Before saying you do not know"),
      "With reading on, Serein looks on the Mac before saying it does not know")
  }
}
#endif
