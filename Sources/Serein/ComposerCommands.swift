import AppKit
import SereinCore
import SwiftUI

/// One menu belongs to one composer and one thread. No catalog lookup starts a harness.
@MainActor final class ComposerCommands: ObservableObject {
  static let shared = ComposerCommands()
  @Published var highlighted = 0
  @Published var owner = ""
  @Published var rows: [SlashCommand] = []
  @Published var query = ""
  private var binding = ""
  private var dismissed = ""
  private var advertisements: [String: [SlashCommand]] = [:]
  private weak var agent: AgentModel?
  private weak var browser: BrowserModel?
  /// The person's shortcuts follow Serein's own commands. Their names never match a command (PromptShortcuts.reserved).
  func catalog(_ agent: AgentModel) -> [SlashCommand] {
    var entries = SlashCommands.catalog(agent.provider.driver)
    entries.insert(contentsOf: PromptShortcuts.commands(ShortcutBook.shared.shortcuts), at: SlashCommands.shared.count)
    if let driver = agent.provider.driver {
      entries.append(SlashCommand("terminal", "Open \(driver.displayName)’s own command interface", .terminal, driver: driver))
      if let session = agent.nativeSessionID {
        for entry in advertisements["\(driver.rawValue)|\(session)"] ?? [] where !entries.contains(where: { $0.name == entry.name }) {
          entries.append(entry)
        }
      }
    }
    return entries
  }
  func receive(_ update: [String: Any], driver: HarnessDriver, session: String) {
    guard let entries = SlashCommands.advertised(update, driver: driver) else { return }
    if advertisements.count >= 64 { advertisements.removeAll() }
    advertisements["\(driver.rawValue)|\(session)"] = entries
    if let agent, agent.provider.driver == driver, agent.nativeSessionID == session,
      ComposerDropdown.shared.open?.kind == .commands {
      rows = SlashCommands.filter(catalog(agent), query: query)
      highlighted = min(highlighted, max(0, rows.count - 1))
    }
  }
  func update(agent: AgentModel, browser: BrowserModel, owner: String, focused: Bool, selection: NSRange) {
    let key = "\(owner)|\(agent.conversationID)|\(agent.provider.rawValue)|\(agent.draft)"
    if !focused || selection.length != 0 || selection.location != (agent.draft as NSString).length {
      close(owner: owner); return
    }
    guard let query = SlashCommands.query(agent.draft) else { close(owner: owner); dismissed = ""; return }
    guard key != dismissed else { close(owner: owner); return }
    dismissed = ""
    self.agent = agent; self.browser = browser; self.owner = owner
    if binding != key { highlighted = 0; binding = key }
    self.query = query
    rows = SlashCommands.filter(catalog(agent), query: query)
    ComposerDropdown.shared.open = .init(kind: .commands, owner: owner)
  }
  func close(owner: String? = nil, dismiss: Bool = false) {
    guard owner == nil || self.owner == owner else { return }
    if dismiss { dismissed = binding }
    if ComposerDropdown.shared.open?.kind == .commands { ComposerDropdown.shared.close() }
  }
  func key(_ event: NSEvent, owner: String) -> Bool {
    guard self.owner == owner, ComposerDropdown.shared.open == .init(kind: .commands, owner: owner),
      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
    switch event.keyCode {
    case 53: close(dismiss: true); return true
    case 125, 126:
      if !rows.isEmpty { highlighted = (highlighted + (event.keyCode == 125 ? 1 : rows.count - 1)) % rows.count }
      return true
    case 48:
      choose(complete: true); return true
    case 36, 76:
      if rows.isEmpty { unknown() } else { choose(complete: false) }
      return true
    default: return false
    }
  }
  func choose(_ index: Int? = nil, complete: Bool = false) {
    guard let agent, let browser, rows.indices.contains(index ?? highlighted) else { return }
    let row = rows[index ?? highlighted]
    guard binding == "\(owner)|\(agent.conversationID)|\(agent.provider.rawValue)|\(agent.draft)" else { close(); return }
    close(dismiss: true)
    if complete {
      agent.draft = "/\(row.name) "
      return
    }
    execute(row, arguments: "", agent: agent, browser: browser, owner: owner)
  }
  private func unknown() {
    guard let agent else { return }
    agent.error = "Unknown command. Type /help, or begin with // to send a literal slash."
    close(dismiss: true)
  }
  /// Both Return and the send/queue buttons call this before sending. Unknown slash words
  /// cannot silently enter auto-routing, a linked CLI, or a model request.
  @discardableResult func submit(agent: AgentModel, browser: BrowserModel, owner: String) -> Bool {
    guard let invocation = SlashCommands.parse(agent.draft) else {
      if agent.draft == "/" { return true }
      return false
    }
    guard let row = catalog(agent).first(where: { $0.name == invocation.name })
      ?? SlashCommands.find(invocation.name, driver: agent.provider.driver) else {
      agent.error = "Unknown command /\(invocation.name). Type /help, or begin with // to send it literally."
      return true
    }
    execute(row, arguments: invocation.arguments, agent: agent, browser: browser, owner: owner)
    return true
  }
  func execute(_ row: SlashCommand, arguments: String, agent: AgentModel, browser: BrowserModel, owner: String) {
    close(dismiss: true)
    if !arguments.isEmpty && row.action != .plan && row.action != .terminal && row.action != .native {
      agent.error = "/\(row.name) takes no arguments. Your draft has been kept."; return
    }
    if agent.running && ![.stop, .status, .help, .settings, .mcp, .agents, .usage, .newChat, .shortcut].contains(row.action) {
      agent.error = "Wait for this task to finish, or use /stop before /\(row.name)."; return
    }
    if let driver = row.driver, driver != agent.provider.driver {
      agent.error = "The harness changed. Open / again to choose its command."; return
    }
    agent.error = nil
    switch row.action {
    case .newChat:
      // The composer stays where it is and now writes to a fresh thread; it never attaches a page.
      // Like New chat, the thread starts on Settings' default, not on this chat's pick.
      agent.clear()
      agent.draft = ""
    case .model, .harness:
      agent.draft = ""
      ComposerDropdown.shared.open = .init(kind: .modelAndTraits, owner: owner)
    case .plan:
      guard arguments.isEmpty || ["on", "off"].contains(arguments.lowercased()) else {
        agent.error = "Use /plan, /plan on, or /plan off."; return
      }
      guard !agent.repliesInApp else { agent.error = "Plan-first mode is available for Serein tasks. This chat continues in its own CLI."; return }
      let context = ComposerContext.shared
      context.planMode = arguments.isEmpty ? !context.planMode : arguments.lowercased() == "on"
      agent.draft = ""
      ToastCenter.shared.show(context.planMode ? "Plan first is on" : "Plan first is off")
    case .stop: agent.cancel(); agent.draft = ""
    case .settings, .mcp, .agents, .usage:
      let section: String = switch row.action { case .mcp: "MCP connection"; case .agents: "Agents"; case .usage: "Usage"; default: "General" }
      UserDefaults.standard.set(section, forKey: "serein.settingsSection")
      browser.requestedSettingsSection = section
      agent.draft = ""; browser.showSettings = true
    case .status:
      agent.draft = ""
      ToastCenter.shared.show("\(agent.provider.name) · \(agent.model.isEmpty ? "Default model" : agent.model) · \(agent.running ? "Working" : "Ready") · \(agent.mode.rawValue)")
    case .help:
      let alert = NSAlert()
      alert.messageText = "Commands for \(agent.provider.name)"
      alert.informativeText = "Type / to search. ↑ ↓ selects, Tab completes, Return chooses, Esc closes.\n\nSerein commands act here. Rows marked Terminal open a handoff for the harness’s own interface; their command is never sent as an ordinary chat prompt. // sends a literal slash.\n\nHarness commands depend on your installed version. ACP commands advertised by the current session also appear in the menu.\n\nYour saved shortcuts are listed after Serein’s commands. Choosing one puts its words in your draft to edit and send; it never sends by itself."
      alert.addButton(withTitle: "Done")
      if agent.provider.driver != nil { alert.addButton(withTitle: "Harness documentation") }
      if alert.runModal() == .alertSecondButtonReturn, let driver = agent.provider.driver, let url = URL(string: SlashCommands.docs(driver)) { NSWorkspace.shared.open(url) }
      agent.draft = ""
    case .native:
      guard let name = row.nativeName, let driver = row.driver, driver.wire == .acp,
        SlashCommands.nativeACPNames.contains(name), agent.nativeSessionID != nil,
        agent.mode != .auto, agent.mode != .library, !agent.repliesInApp else {
        agent.error = "This command needs a resumable Serein session on the selected harness."; return
      }
      guard arguments.isEmpty else {
        agent.error = "This session command takes no arguments in Serein."; return
      }
      agent.send("/" + name, chips: .empty, plan: false, nativeCommand: name)
      if agent.running { agent.draft = "" }
    case .terminal:
      handoff(row, arguments: arguments, agent: agent, browser: browser)
    case .shortcut:
      // Only the words go into the draft, exactly: nothing is sent and no card is answered.
      guard let shortcut = ShortcutBook.shared.named(row.name) else {
        agent.error = "That shortcut was deleted. Your draft has been kept."; return
      }
      agent.draft = shortcut.text
    }
  }
  private func handoff(_ row: SlashCommand, arguments: String, agent: AgentModel, browser: BrowserModel) {
    guard let driver = row.driver else { return }
    let text = row.nativeName.map { "/" + $0 + (arguments.isEmpty ? "" : " " + arguments) } ?? "/"
    let alert = NSAlert()
    alert.messageText = "Use \(text) in \(driver.displayName)"
    // Never resume Serein's isolated session outside its sandbox or share its scoped context
    // with a harness's own configuration. This handoff starts a separate terminal session.
    alert.informativeText = "This command uses \(driver.displayName)’s terminal interface. Open a separate session with the harness’s own settings, then paste the copied command. It will not change or compact this Serein chat.\n\n\(text)"
    alert.addButton(withTitle: "Copy and open terminal")
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Copy only")
    let choice = alert.runModal()
    guard choice != .alertSecondButtonReturn else { return }
    if choice == .alertFirstButtonReturn {
      guard HarnessRegistry.shared.executable(agent.provider) != nil else {
        agent.error = "Set up \(driver.displayName) in Settings › AI apps first."; return
      }
      if HarnessActions.shared.job?.session.running == true {
        agent.error = "A harness terminal is already running. Close it before opening another."; return
      }
      let folder = agent.mode == .project ? browser.projects.first { $0.id == agent.projectID }?.path : nil
      let command = HarnessCommands.interactive(driver, folder: folder)
      guard HarnessActions.shared.run(command, driver: driver) != nil else { agent.error = "Could not open the harness terminal."; return }
    }
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    agent.draft = ""
    ToastCenter.shared.show("Copied \(text). Paste it in \(driver.displayName)’s terminal.")
  }
}

struct ComposerCommandMenu: View {
  @ObservedObject var commands = ComposerCommands.shared
  @ObservedObject var agent: AgentModel
  @Environment(\.palette) var p
  static var rowHeight: CGFloat { UIStyle.wide(30) }
  static var headerHeight: CGFloat { UIStyle.wide(28) }
  static var footerHeight: CGFloat { UIStyle.wide(24) }
  static func height(count: Int) -> CGFloat {
    headerHeight + footerHeight + 2 + 8 + CGFloat(max(1, min(7, count))) * rowHeight
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 5) {
        Text("Commands").font(UIStyle.micro)
        Spacer()
        HarnessGlyph(provider: agent.provider, size: 11, tinted: false)
        Text(agent.provider.name).font(UIStyle.micro)
      }.foregroundStyle(p.secondary).padding(.horizontal, 10).frame(height: Self.headerHeight)
      Rectangle().fill(p.line).frame(height: 1)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            if commands.rows.isEmpty {
              Text("No matching commands").font(UIStyle.micro).foregroundStyle(p.secondary)
                .padding(.horizontal, 10).frame(height: Self.rowHeight)
            }
            ForEach(Array(commands.rows.enumerated()), id: \.element.id) { index, row in
              Button { commands.choose(index) } label: {
                HStack(spacing: 10) {
                  Text("/" + row.name).font(UIStyle.metaStrong).foregroundStyle(p.ink)
                    .lineLimit(1).layoutPriority(1)
                  Text(row.summary).font(UIStyle.micro).foregroundStyle(p.secondary)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                  if row.action == .terminal {
                    InterfaceIcon(systemName: "arrow.up.right", size: 10).foregroundStyle(p.faint)
                  } else if row.action == .native {
                    Text("Session").font(UIStyle.micro).foregroundStyle(p.faint)
                  } else if row.action == .shortcut {
                    Text("Shortcut").font(UIStyle.micro).foregroundStyle(p.faint)
                  }
                }.padding(.horizontal, 8).frame(height: Self.rowHeight)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .background(index == commands.highlighted ? p.selected : .clear, in: RoundedRectangle(cornerRadius: 5))
                  .contentShape(Rectangle())
              }.buttonStyle(.pressable).id(row.id)
                .help(row.summary + (row.action == .terminal ? " · Opens a separate terminal session" : row.action == .shortcut ? " · Puts these words in your draft" : ""))
                .accessibilityLabel("/\(row.name), \(row.summary), \(row.action == .terminal ? "Terminal" : row.action == .native ? "This session" : row.action == .shortcut ? "Your shortcut, fills the draft" : "Serein")")
                .accessibilityAddTraits(index == commands.highlighted ? .isSelected : [])
            }
          }.padding(4)
        }.onChange(of: commands.highlighted) { _, index in
          if commands.rows.indices.contains(index) { proxy.scrollTo(commands.rows[index].id) }
        }.onChange(of: commands.query) { _, _ in
          if let first = commands.rows.first { proxy.scrollTo(first.id, anchor: .top) }
        }
      }
      Rectangle().fill(p.line).frame(height: 1)
      HStack {
        Text("↑↓ select   ⇥ complete")
        Spacer()
        Text("↵ run   esc close")
      }.font(UIStyle.micro).foregroundStyle(p.faint)
        .padding(.horizontal, 10).frame(height: Self.footerHeight)
    }.accessibilityElement(children: .contain).accessibilityLabel("Slash commands")
  }
}

/// The same command interception and menu anchor for both composer surfaces.
struct CommandComposerInput: View {
  var placeholder: String
  @ObservedObject var agent: AgentModel
  @ObservedObject var browser: BrowserModel
  var owner: String
  @Binding var focused: Bool
  var minHeight: CGFloat = 22
  var maxHeight: CGFloat = 200
  var lineSpacing: CGFloat = 4
  var label = "Task message"
  var onReturn: (Bool) -> Void
  @State private var selection = NSRange(location: 0, length: 0)
  var body: some View {
    ComposerInput(placeholder: placeholder, text: $agent.draft, focused: $focused,
      minHeight: minHeight, maxHeight: maxHeight, lineSpacing: lineSpacing, label: label,
      onReturn: { option in
        if !ComposerCommands.shared.submit(agent: agent, browser: browser, owner: owner) { onReturn(option) }
      }, onCommandKey: { ComposerCommands.shared.key($0, owner: owner) }, onSelection: {
        selection = $0; refresh(selection: $0)
      }, moveCaretToEndOnChange: true)
      .anchorPreference(key: ComposerDropdownAnchorKey.self, value: .bounds) {
        [ComposerDropdown.Target(kind: .commands, owner: owner): $0]
      }
      .onChange(of: agent.draft) { _, _ in refresh() }
      .onChange(of: agent.provider) { _, _ in refresh() }
      .onChange(of: agent.conversationID) { _, _ in ComposerCommands.shared.close(owner: owner, dismiss: true) }
      .onChange(of: focused) { _, _ in refresh() }
      .onDisappear { ComposerCommands.shared.close(owner: owner) }
  }
  private func refresh(selection: NSRange? = nil) {
    ComposerCommands.shared.update(agent: agent, browser: browser, owner: owner, focused: focused, selection: selection ?? self.selection)
  }
}

/// The @ picker in Serein's composer: "@" at the start of the draft or after a space opens a
/// list of assistants and teams (prefix matches first, then substrings; the chat's own assistant
/// last and not pickable). Choosing puts "@Writer " at the front of the draft, so BT1's mention
/// routing (`TeamMention.parse`) sends the words to Writer; the To chip above the field shows it.
@MainActor final class AssistantMentions: ObservableObject {
  static let shared = AssistantMentions()
  static let owner = "serein"
  struct Row: Identifiable, Equatable {
    enum Kind: Equatable { case assistant(RelayProfile), team(AssistantGroup) }
    var kind: Kind
    var name: String
    var words: String
    var status: SereinStatus?
    var speaksFirst = true
    /// The chat on screen belongs to this assistant: listed, dimmed, not pickable.
    var current = false
    var id: String {
      switch kind {
      case .assistant(let profile): return "a:" + profile.id
      case .team(let group): return "t:" + group.id
      }
    }
  }
  @Published var rows: [Row] = []
  @Published var highlighted = 0
  @Published var query = ""
  /// The To chip: who the draft's leading mention names, kept in step with the draft.
  @Published private(set) var recipient: TeamMention?
  private var dismissed = ""
  private var monitor: Any?
  private weak var relay: RelayOrchestrator?

  /// "@wr" at the end of `draft`, at its start or after whitespace; nil otherwise.
  static func query(_ draft: String) -> String? {
    guard let at = draft.lastIndex(of: "@") else { return nil }
    let before = draft[..<at]
    guard before.isEmpty || before.last?.isWhitespace == true else { return nil }
    let word = draft[draft.index(after: at)...]
    guard !word.contains(where: \.isWhitespace), !word.contains("@") else { return nil }
    return String(word)
  }
  /// Every assistant and team as a row, filtered: prefix matches, then substrings, assistants
  /// before teams, the current chat's assistant last.
  static func rows(query: String, relay: RelayOrchestrator, states: [String: SereinStatus]) -> [Row] {
    let active = relay.team.activeID
    let q = query.lowercased()
    func match(_ name: String) -> Int { name.lowercased().hasPrefix(q) ? 0 : name.lowercased().contains(q) ? 1 : q.isEmpty ? 0 : 2 }
    var assistants = relay.team.profiles.map { profile -> Row in
      let teams = relay.team.groups(of: profile.id)
      var words = teams.map(\.name).joined(separator: ", ")
      if teams.contains(where: { $0.leadID == profile.id }) { words += words.isEmpty ? "Lead" : ", Lead" }
      return Row(kind: .assistant(profile), name: profile.name, words: profile.id == active ? "This chat" : words,
                 status: states[profile.id], speaksFirst: relay.speaksFirst(profile) != .off, current: profile.id == active)
    }.filter { match($0.name) < 2 }
    assistants.sort { a, b in
      let left: (Int, Int) = (a.current ? 1 : 0, match(a.name))
      let right: (Int, Int) = (b.current ? 1 : 0, match(b.name))
      return left < right
    }
    let teams = relay.team.teams.map { group -> Row in
      let lead = group.leadID.map { "Lead: " + relay.profileName($0) }
      let status = AssistantBoard.pressing(group.memberIDs.compactMap { states[$0] })
      return Row(kind: .team(group), name: group.name,
                 words: ["\(group.memberIDs.count) assistant\(group.memberIDs.count == 1 ? "" : "s")", lead].compactMap { $0 }.joined(separator: " · "), status: status)
    }.filter { match($0.name) < 2 }.sorted { match($0.name) < match($1.name) }
    let others = assistants.filter { !$0.current } + teams
    return others + assistants.filter(\.current)
  }
  func update(relay: RelayOrchestrator, draft: String, focused: Bool, states: [String: SereinStatus]) {
    self.relay = relay
    recipient = TeamMention.parse(draft, in: relay.team)?.mention
    // "@" and one word at the start of the draft open the "+" list instead (ComposerAddList.swift),
    // outside a team chat; "@" later in the draft is still this list's.
    if ComposerAddList.atWord(draft, relay: relay) != nil {
      close()
      return
    }
    guard focused, relay.team.profiles.count > 1, let query = Self.query(draft) else { close(); dismissed = ""; return }
    let key = relay.threadID + "|" + draft
    guard key != dismissed else { close(); return }
    if self.query != query { highlighted = 0 }
    self.query = query
    rows = Self.rows(query: query, relay: relay, states: states)
    if ComposerDropdown.shared.open?.kind != .mentions {
      ComposerDropdown.shared.open = .init(kind: .mentions, owner: Self.owner)
      startMonitor()
    }
  }
  func close(dismiss: Bool = false) {
    if dismiss, let relay { dismissed = relay.threadID + "|" + SereinSurface.main.draft }
    if ComposerDropdown.shared.open?.kind == .mentions { ComposerDropdown.shared.close() }
    stopMonitor()
  }
  private func startMonitor() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let swallow = MainActor.assumeIsolated { self?.key(event) ?? false }
      return swallow ? nil : event
    }
  }
  private func stopMonitor() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }
  /// ↑↓ move, ⇥ completes the name, ↵ chooses, Esc closes (and stays closed for this draft).
  private func key(_ event: NSEvent) -> Bool {
    guard ComposerDropdown.shared.open?.kind == .mentions,
      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
    switch event.keyCode {
    case 53: close(dismiss: true); return true
    case 125, 126:
      let pickable = rows.indices.filter { !rows[$0].current }
      guard !pickable.isEmpty else { return true }
      let at = pickable.firstIndex(of: highlighted) ?? 0
      highlighted = pickable[(at + (event.keyCode == 125 ? 1 : pickable.count - 1)) % pickable.count]
      return true
    case 48, 36, 76:
      // Nothing to pick ("ping @john"): the picker closes and the key does what it always does.
      guard rows.contains(where: { !$0.current }) else { close(dismiss: true); return false }
      choose(complete: event.keyCode == 48)
      return true
    default: return false
    }
  }
  /// The draft's "@wr" becomes "@Writer " at the front, so the mention routes (`routeMention`).
  func choose(_ index: Int? = nil, complete: Bool = false) {
    guard rows.indices.contains(index ?? highlighted) else { return }
    let row = rows[index ?? highlighted]
    guard !row.current else { return }
    let surface = SereinSurface.main
    var draft = surface.draft
    if let at = draft.lastIndex(of: "@") { draft = String(draft[..<at]) }
    let rest = draft.trimmingCharacters(in: .whitespaces)
    surface.draft = "@" + row.name + " " + rest
    close(dismiss: true)
    if let relay { recipient = TeamMention.parse(surface.draft, in: relay.team)?.mention }
  }
  /// × on the To chip: the leading mention goes, the words stay.
  func removeRecipient() {
    guard let relay, let parsed = TeamMention.parse(SereinSurface.main.draft, in: relay.team) else { return }
    SereinSurface.main.draft = parsed.rest
    recipient = nil
  }
  /// "To Writer" / "To Trip planner" and the petal or team glyph for the chip.
  func recipientName() -> (name: String, profile: RelayProfile?, team: Bool)? {
    guard let relay, let recipient else { return nil }
    switch recipient {
    case .assistant(let id):
      guard id != relay.team.activeID, let profile = relay.team.profiles.first(where: { $0.id == id }) else { return nil }
      return (profile.name, profile, false)
    case .team(let id):
      guard let group = relay.team.group(id) else { return nil }
      return (group.name, nil, true)
    }
  }
}

/// The @ picker's rows: petal (or `person.2`), name, the teams it is in (or a team's count and
/// lead), and its state glyph with the moon for Never when idle.
struct AssistantMentionMenu: View {
  @ObservedObject var mentions = AssistantMentions.shared
  @Environment(\.palette) var p
  static func height(count: Int) -> CGFloat {
    let rows: CGFloat = CGFloat(max(1, min(7, count)))
    let chrome: CGFloat = ComposerCommandMenu.headerHeight + ComposerCommandMenu.footerHeight + 2 + 8
    return chrome + rows * ComposerCommandMenu.rowHeight
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack { Text("Send to").font(UIStyle.micro); Spacer() }
        .foregroundStyle(p.secondary).padding(.horizontal, 10).frame(height: ComposerCommandMenu.headerHeight)
      Rectangle().fill(p.line).frame(height: 1)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            if mentions.rows.allSatisfy(\.current) {
              Text("No assistant or team called “\(mentions.query)”").font(UIStyle.micro).foregroundStyle(p.secondary)
                .padding(.horizontal, 10).frame(height: ComposerCommandMenu.rowHeight)
            }
            ForEach(Array(mentions.rows.enumerated()), id: \.element.id) { index, row in
              Button { mentions.choose(index) } label: {
                HStack(spacing: 8) {
                  switch row.kind {
                  case .assistant(let profile): AssistantMark(profile: profile, size: 14)
                  case .team: Image(systemName: "person.2").font(.system(size: 12)).foregroundStyle(p.secondary).frame(width: 14)
                  }
                  Text(row.name).font(UIStyle.metaStrong).foregroundStyle(p.ink).lineLimit(1).layoutPriority(1)
                  Text(row.words).font(UIStyle.micro).foregroundStyle(p.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                  if let status = row.status {
                    SereinStatusGlyph(status: status)
                    if status == .ready, !row.speaksFirst {
                      InterfaceIcon(systemName: "moon", size: 10).foregroundStyle(p.faint)
                    }
                  }
                }.padding(.horizontal, 8).frame(height: ComposerCommandMenu.rowHeight)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .opacity(row.current ? 0.5 : 1)
                  .background(index == mentions.highlighted && !row.current ? p.selected : .clear, in: RoundedRectangle(cornerRadius: 5))
                  .contentShape(Rectangle())
              }.buttonStyle(.pressable).id(row.id).disabled(row.current)
                .accessibilityLabel([row.name, row.words, row.status?.spoken].compactMap { $0 }.joined(separator: ", "))
                .accessibilityAddTraits(index == mentions.highlighted ? .isSelected : [])
            }
          }.padding(4)
        }.onChange(of: mentions.highlighted) { _, index in
          if mentions.rows.indices.contains(index) { proxy.scrollTo(mentions.rows[index].id) }
        }
      }
      Rectangle().fill(p.line).frame(height: 1)
      HStack {
        Text("↑↓ select   ⇥ complete")
        Spacer()
        Text("↵ choose   esc close")
      }.font(UIStyle.micro).foregroundStyle(p.faint)
        .padding(.horizontal, 10).frame(height: ComposerCommandMenu.footerHeight)
    }.accessibilityElement(children: .contain).accessibilityLabel("Send to: assistants and teams")
  }
}
