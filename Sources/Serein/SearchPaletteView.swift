import SereinCore
import SwiftUI

/// Whether the Search palette shows over the main window. The sidebar's Search, File › Search (⌘K)
/// and `app_open search` open it; Escape, a click outside it or opening a row closes it.
@MainActor final class SearchPaletteCenter: ObservableObject {
  static let shared = SearchPaletteCenter()
  @Published var open = false
}

/// The palette over the dimmed window (`SearchPalette` holds its list rules). It fades in; nothing
/// slides or resizes.
struct SearchPaletteLayer: View {
  let browser: BrowserModel
  let agent: AgentModel
  @ObservedObject private var center = SearchPaletteCenter.shared
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  var body: some View {
    ZStack(alignment: .top) {
      if center.open {
        p.scrim.contentShape(Rectangle()).onTapGesture { center.open = false }.accessibilityHidden(true)
        SearchPalettePanel(browser: browser, agent: agent) { center.open = false }
          .padding(.top, 88).padding([.horizontal, .bottom], 16)
      }
    }.animation(systemReduceMotion || previewReducedEffects ? nil : .easeOut(duration: 0.12), value: center.open)
  }
}

private struct SearchPalettePanel: View {
  let browser: BrowserModel
  let agent: AgentModel
  var close: () -> Void

  /// What a row opens, and what its left edge draws.
  enum Target {
    case assistant(RelayProfile, unread: Bool)
    case chat(ProjectChat)
    case settings(SettingsCategory)
  }
  /// The rows the sidebar and History hold in memory, read once as the palette opens.
  struct Listing {
    var assistants: [SearchPalette.Row] = []
    var chats: [SearchPalette.Row] = []
    var settings: [SearchPalette.Row] = []
    var targets: [String: Target] = [:]
  }

  @State private var listing = Listing()
  @State private var query = ""
  /// The highlighted row, counted through every section.
  @State private var active = 0
  @FocusState private var focused: Bool
  @Environment(\.palette) private var p

  var body: some View {
    let sections: [SearchPalette.Section] = SearchPalette.sections(
      query: query, assistants: listing.assistants, chats: listing.chats, settings: listing.settings)
    let rows: [SearchPalette.Row] = sections.flatMap(\.rows)
    let shape = RoundedRectangle(cornerRadius: AssistantMetrics.sheetRadius, style: .continuous)
    VStack(spacing: 0) {
      field(rows)
      Rectangle().fill(p.line).frame(height: UIStyle.hairline)
      // Short lists show whole; the panel stops at its height and the list scrolls inside it.
      ViewThatFits(in: .vertical) {
        list(sections)
        ScrollViewReader { reader in
          ScrollView { list(sections) }.scrollIndicators(.never)
            .onChange(of: active) { _, now in if rows.indices.contains(now) { reader.scrollTo(rows[now].id) } }
        }
      }
    }.frame(maxWidth: 640)
      .background(shape.fill(p.panel))
      .overlay(shape.strokeBorder(p.line, lineWidth: UIStyle.hairline))
      .clipShape(shape)
      .shadow(color: p.shadow(0.25), radius: 10, y: 10)
      // After the panel's fill, so a short list gets a short panel instead of a tall one with the field in its middle.
      .frame(maxHeight: 560, alignment: .top)
      .background {
        Button("") { close() }.keyboardShortcut(.cancelAction).hidden()
        ForEach(0..<SearchPalette.hintCount, id: \.self) { n in
          Button("") {
            let shown: [SearchPalette.Row] = sections.first { $0.kind == .assistants }?.rows ?? []
            if shown.indices.contains(n) { open(shown[n]) }
          }.keyboardShortcut(KeyEquivalent(Character(String(n + 1))), modifiers: .command).hidden()
        }
      }
      .onChange(of: query) { _, _ in active = 0 }
      .onAppear {
        listing = Self.read(browser: browser, agent: agent)
        focused = true
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Search")
      .accessibilityAddTraits(.isModal)
  }

  private func field(_ rows: [SearchPalette.Row]) -> some View {
    HStack(spacing: 10) {
      InterfaceIcon(systemName: "magnifyingglass", size: 16).foregroundStyle(p.secondary)
      TextField("Search assistants, chats, settings…", text: $query).textFieldStyle(.plain).textInputCursor()
        .font(UIStyle.font(16)).focused($focused)
        .onKeyPress(.downArrow) {
          active = DestinationSearch.move(active, by: 1, count: rows.count)
          return .handled
        }
        .onKeyPress(.upArrow) {
          active = DestinationSearch.move(active, by: -1, count: rows.count)
          return .handled
        }
        .onKeyPress(.return) {
          if rows.indices.contains(active) { open(rows[active]) }
          return .handled
        }
        .onKeyPress(.escape) {
          close()
          return .handled
        }
        .accessibilityLabel("Search assistants, chats and settings")
    }.padding(.horizontal, 16).frame(height: UIStyle.headerHeight + 8)
  }

  private func list(_ sections: [SearchPalette.Section]) -> some View {
    var start = 0
    var starts: [SearchPalette.Kind: Int] = [:]
    for section in sections {
      starts[section.kind] = start
      start += section.rows.count
    }
    return VStack(alignment: .leading, spacing: 12) {
      if sections.isEmpty {
        Text("No matches.").font(UIStyle.body).foregroundStyle(p.secondary).padding(.horizontal, 8).padding(.vertical, 6)
      }
      ForEach(sections) { section in
        VStack(alignment: .leading, spacing: 2) {
          Text(section.kind.heading).font(UIStyle.font(11.5, weight: .medium)).foregroundStyle(p.faint)
            .padding(.horizontal, 8).padding(.bottom, 4).accessibilityAddTraits(.isHeader)
          ForEach(Array(section.rows.enumerated()), id: \.element.id) { offset, row in
            rowButton(row, index: (starts[section.kind] ?? 0) + offset,
                     hint: section.kind == .assistants ? SearchPalette.hint(offset) : nil)
          }
        }
      }
    }.padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 10).frame(maxWidth: .infinity, alignment: .leading)
  }

  /// One button that reads the name, then the line. The highlight and the key hint are the model
  /// picker's (`ModelPickerView.modelRow`).
  private func rowButton(_ row: SearchPalette.Row, index: Int, hint: String?) -> some View {
    let target: Target? = listing.targets[row.id]
    var unread = false
    if case .assistant(_, let mark)? = target { unread = mark }
    return Button { open(row) } label: {
      HStack(spacing: 10) {
        Group {
          switch target {
          case .assistant(let profile, _)?: AssistantMark(profile: profile, size: 28)
          case .chat(let chat)?: HarnessGlyph(provider: chat.provider, size: 13, tinted: true)
          case .settings(let page)?: InterfaceIcon(systemName: page.icon, size: 15).foregroundStyle(p.secondary)
          case nil: EmptyView()
          }
        }.frame(width: 28, height: 28)
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: row.title).font(UIStyle.bodyStrong).foregroundStyle(p.ink).lineLimit(1).truncationMode(.tail)
          if let line = row.line {
            Text(verbatim: line).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.tail)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
        if unread { Circle().fill(p.accent).frame(width: 8, height: 8) }
        if let hint {
          Text(hint).font(UIStyle.mono(10)).foregroundStyle(p.faint)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(p.track, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
        }
      }.padding(.horizontal, 8).padding(.vertical, 6)
        .background(index == active ? p.selected : .clear, in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
        .contentShape(Rectangle())
    }.buttonStyle(.plain)
      // One moving highlight: hovering moves the keyboard's.
      .onHover { if $0 { active = index } }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(row.line.map { "\(row.title), \($0)" } ?? row.title)
      .accessibilityValue(unread ? "Unread" : "")
      .accessibilityAddTraits(index == active ? [.isButton, .isSelected] : .isButton)
      .accessibilityAction { open(row) }
      .id(row.id)
  }

  private func open(_ row: SearchPalette.Row) {
    guard let target = listing.targets[row.id] else { return }
    close()
    switch target {
    case .assistant(let profile, _):
      // As its sidebar row: it answers, then its chat shows full.
      guard let relay = SereinSurface.controller?.relay else { return }
      let board = AssistantSidebarState.shared
      board.lastClicked = (nil, profile.id)
      let switching: Bool = relay.team.activeID != profile.id
      guard relay.openAssistant(profile.id) else { return }
      if switching { board.switched() }
      SereinRouter.showFull()
    case .chat(let chat):
      SessionOpen.open(chat, agent: agent)
    case .settings(let page):
      UserDefaults.standard.set(page.id, forKey: "serein.settingsSection")
      browser.requestedSettingsSection = page.id
      browser.showSettings = true
    }
  }

  /// Serein, then its crew in the sidebar's order (`AssistantSidebarState.rowKeys`); what History
  /// lists, newest first; the Settings pages in their order. Nothing is loaded from disk for this
  /// but an assistant's small state file the first time its Main chat is looked up.
  @MainActor static func read(browser: BrowserModel, agent: AgentModel) -> Listing {
    var out = Listing()
    if let relay = SereinSurface.controller?.relay {
      let main: RelayProfile? = relay.team.main
      let marked: Set<String> = AssistantRowState.shared.unread
      for profile in [main].compactMap({ $0 }) + relay.team.profiles.filter({ $0.id != main?.id }) {
        let row = SearchPalette.Row(id: "assistant:" + profile.id, title: profile.name, line: relay.rowPreview(profile.id)?.text)
        let unread: Bool = marked.contains(profile.id) || (profile.id == relay.team.activeID && SereinSurface.main.unread)
        out.assistants.append(row)
        out.targets[row.id] = .assistant(profile, unread: unread)
      }
    }
    let projects: [String: String] = Dictionary(browser.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    for chat in ProjectChatIndex.listed(browser: browser, agent: agent).all {
      let place: String = chat.projectID.flatMap { projects[$0] } ?? chat.provider.name
      let line: String = [place, RelativeTimeShort.text(chat.date)].compactMap { $0 }.joined(separator: " · ")
      out.chats.append(SearchPalette.Row(id: chat.id, title: chat.title, line: line))
      out.targets[chat.id] = .chat(chat)
    }
    for page in SettingsCategory.all {
      let row = SearchPalette.Row(id: "settings:" + page.id, title: page.label)
      out.settings.append(row)
      out.targets[row.id] = .settings(page)
    }
    return out
  }
}
