import SereinCore
import SwiftUI

// MARK: - Keel's picker tokens

/// Keel's harness/model picker, reproduced: sizes, radii and colours follow
/// `crates/ui/src/pickers.rs` (render_harness_model_popover), `popover.rs` (popover_card,
/// kbd_hint) and `theme.rs` (ink / hairline / wash, violet-400 rail bar, neutral text).
enum KeelPicker {
  /// Wide enough for a row's route tag and its usage column beside the model name; wider with
  /// large text.
  static var width: CGFloat { UIStyle.wide(420) }
  static let height: CGFloat = 346  // max-h-86.5
  static let radius: CGFloat = 12
  static let railWidth: CGFloat = 44
  static let railTab: CGFloat = 36
  static let searchHeight: CGFloat = 46
  static let pillHeight: CGFloat = 32
  /// A row's trailing column: its route tag over its usage estimate.
  static let routeColumn: CGFloat = 60
  static var traitsWidth: CGFloat { UIStyle.wide(288) }

  static func surface(_ dark: Bool) -> Color { dark ? Color(hex: 0x161616) : .white }
  static func text(_ dark: Bool) -> Color { dark ? Color(hex: 0xEBEBEB) : Color(hex: 0x1A1A1A) }
  static func muted(_ dark: Bool) -> Color { dark ? Color(hex: 0xB5B5B5) : Color(hex: 0x737373) }
  /// ink(alpha): soft-white in dark, black in light.
  static func ink(_ dark: Bool, _ alpha: Double) -> Color {
    dark ? Color.white.opacity(alpha) : Color.black.opacity(alpha)
  }
  static func hairline(_ dark: Bool, _ alpha: Double) -> Color {
    dark ? Color.white.opacity(alpha) : Color.black.opacity(min(0.5, alpha * 1.4))
  }
  /// wash(alpha): the selected-card fill.
  static func wash(_ dark: Bool, _ alpha: Double) -> Color {
    dark ? Color(white: 0.92).opacity(alpha) : Color(white: 0.10).opacity(alpha * 0.6)
  }
  /// picker_purple: violet-400 in dark, violet-600 in light.
  static func purple(_ dark: Bool) -> Color { dark ? Color(hex: 0xA78BFA) : Color(hex: 0x7C3AED) }
  static let warning = Color(hex: 0xFBBF24)
  static let claudeOrange = Color(hex: 0xD97757)
}

// MARK: - Dropdown state

/// Which composer dropdown is open. The dropdown itself is drawn by `ComposerDropdownLayer` at
/// the top of the window, pinned to the trigger's top-left like Keel's `pinned_layer`, so it is
/// never clipped by the composer's glass.
@MainActor final class ComposerDropdown: ObservableObject {
  static let shared = ComposerDropdown()
  /// `modelAndTraits`: the composer's one menu, the model list over reasoning and Plan.
  /// `workOn`: the composer's `+` (WorkOnPicker).
  /// `mentions`: the @ picker of assistants and teams in Serein's composer (AssistantMentions).
  /// `addList`: the "+" list of Serein's message bar (ComposerAddList.swift).
  enum Kind: Hashable { case models, traits, modelAndTraits, workOn, commands, mentions, addList }
  /// Which dropdown, on which composer (several can be on screen: the floating one, the
  /// thread's, the task panel's). An empty owner matches any composer (previews).
  struct Target: Hashable {
    var kind: Kind
    var owner: String
  }
  @Published var open: Target?
  func toggle(_ kind: Kind, owner: String) {
    let target = Target(kind: kind, owner: owner)
    open = open == target ? nil : target
  }
  func close() { open = nil }
}

struct ComposerDropdownAnchorKey: PreferenceKey {
  static var defaultValue: [ComposerDropdown.Target: Anchor<CGRect>] { [:] }
  static func reduce(
    value: inout [ComposerDropdown.Target: Anchor<CGRect>],
    nextValue: () -> [ComposerDropdown.Target: Anchor<CGRect>]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
  }
}

/// Draws the open dropdown above (or, near the top edge, below) its trigger, with a full-window
/// catcher behind it that closes on a click outside (Keel `on_mouse_down_out`).
struct ComposerDropdownLayer: View {
  @ObservedObject var agent: AgentModel
  /// Needed only by `workOn`; Settings has no composer `+`.
  var browser: BrowserModel?
  @ObservedObject private var dropdown = ComposerDropdown.shared
  @ObservedObject private var commands = ComposerCommands.shared
  /// The @ picker's rows, so its height follows the query.
  @ObservedObject private var mentions = AssistantMentions.shared
  /// The "+" list's rows, so its height follows the filter.
  @ObservedObject private var addList = ComposerAddList.shared
  var anchors: [ComposerDropdown.Target: Anchor<CGRect>]
  @Environment(\.palette) var p
  func anchor(for target: ComposerDropdown.Target) -> Anchor<CGRect>? {
    anchors[target] ?? (target.owner.isEmpty ? anchors.first { $0.key.kind == target.kind }?.value : nil)
  }
  var body: some View {
    GeometryReader { geometry in
      if let target = dropdown.open, let anchor = anchor(for: target) {
        let kind = target.kind
        let trigger = geometry[anchor]
        let size: CGSize = switch kind {
        case .commands:
          CGSize(width: min(max(trigger.width, UIStyle.wide(280)), UIStyle.wide(420), geometry.size.width - 16),
            height: min(ComposerCommandMenu.height(count: commands.rows.count), max(100, max(trigger.minY, geometry.size.height - trigger.maxY) - 16)))
        case .mentions:
          CGSize(width: min(max(trigger.width, UIStyle.wide(280)), UIStyle.wide(420), geometry.size.width - 16),
            height: min(AssistantMentionMenu.height(count: mentions.rows.count),
                        max(100, max(trigger.minY, geometry.size.height - trigger.maxY) - 16)))
        case .workOn: CGSize(width: WorkOnPicker.width, height: 0)
        case .models: CGSize(width: KeelPicker.width, height: KeelPicker.height)
        case .traits: CGSize(width: KeelPicker.traitsWidth, height: EffortLadder.height(agent))
        case .modelAndTraits:
          CGSize(width: KeelPicker.width, height: KeelPicker.height + 1 + EffortLadder.height(agent, showsAccess: false))
        // The "+" list is as wide as the message bar it opens from.
        case .addList:
          CGSize(width: min(trigger.width, geometry.size.width - 16),
            height: min(ComposerAddListView.height(addList.groups), max(100, max(trigger.minY, geometry.size.height - trigger.maxY) - 16)))
        }
        // WorkOnPicker sizes itself: it opens on the side with more room, pinned to the trigger.
        let opensAbove: Bool = Self.opensAboveTrigger(kind, trigger: trigger, room: geometry.size, height: size.height)
        let room = kind == .workOn ? (opensAbove ? trigger.minY : geometry.size.height - trigger.maxY) - 16 : size.height
        let y = opensAbove ? trigger.minY - 8 - room : trigger.maxY + 8
        let x = min(max(8, trigger.minX), geometry.size.width - size.width - 8)
        ZStack(alignment: .topLeading) {
          Color.clear.contentShape(Rectangle()).onTapGesture {
            ComposerCommands.shared.close(dismiss: true)
            AssistantMentions.shared.close(dismiss: true)
            ComposerAddList.shared.close(dismiss: true)
            dropdown.close()
          }
          Group {
            switch kind {
            case .commands: ComposerCommandMenu(agent: agent)
            case .mentions: AssistantMentionMenu()
            case .addList: ComposerAddListView()
            case .workOn:
              if let browser { WorkOnPicker(browser: browser, agent: agent) { dropdown.close() } }
            // Only Settings opens the list alone: there a pick sets the default for new chats.
            case .models: ModelPickerView(agent: agent, setsDefault: true) { dropdown.close() }
            case .traits: EffortLadder(agent: agent)
            case .modelAndTraits:
              VStack(spacing: 0) {
                ModelPickerView(agent: agent) { dropdown.close() }.frame(height: KeelPicker.height)
                Rectangle().fill(KeelPicker.hairline(p.isDark, 0.08)).frame(height: 1)
                EffortLadder(agent: agent, showsAccess: false, width: KeelPicker.width)
              }
            }
          }.frame(width: size.width, height: kind == .workOn ? nil : size.height)
            .modifier(ComposerDropdownChrome(addList: kind == .addList))
            .frame(height: room, alignment: opensAbove ? .bottom : .top)
            .offset(x: x, y: y)
        }
      }
    }
  }
  /// Above the trigger or under it. WorkOnPicker takes the side with more room; the "+" list
  /// opens under the bar when it fits there, as the board draws it (so above a bar at the foot of
  /// the chat); every other dropdown opens above when it fits there.
  static func opensAboveTrigger(_ kind: ComposerDropdown.Kind, trigger: CGRect, room: CGSize, height: CGFloat) -> Bool {
    let below: CGFloat = room.height - trigger.maxY
    switch kind {
    case .workOn: return trigger.minY > below
    case .addList: return below - 16 < height
    case .models, .traits, .modelAndTraits, .commands, .mentions: return trigger.minY - 16 >= height
    }
  }
}

/// A dropdown's plate: Keel's surface, hairline and corner for the pickers; the "+" list sits on
/// the personal-assistant screens' `raised` plane with a 1-point `line` ring and the board's
/// 18-point corner.
private struct ComposerDropdownChrome: ViewModifier {
  let addList: Bool
  @Environment(\.palette) private var p
  @ViewBuilder func body(content: Content) -> some View {
    if addList {
      let shape = RoundedRectangle(cornerRadius: AssistantMetrics.sheetRadius, style: .continuous)
      content.background(p.raised, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(p.line, lineWidth: 1))
        .shadow(color: .black.opacity(p.isDark ? 0.5 : 0.18), radius: 24, y: 12)
    } else {
      content.background(KeelPicker.surface(p.isDark), in: RoundedRectangle(cornerRadius: KeelPicker.radius))
        .overlay(RoundedRectangle(cornerRadius: KeelPicker.radius).stroke(KeelPicker.hairline(p.isDark, 0.10)))
        .clipShape(RoundedRectangle(cornerRadius: KeelPicker.radius))
        .shadow(color: .black.opacity(p.isDark ? 0.5 : 0.18), radius: 24, y: 12)
    }
  }
}

/// Keel's ghost pill (composer `pill`): 32 high, 10 side padding, 6 gap, 8 radius, 12 medium,
/// muted text that brightens on hover or while its dropdown is open; no border, no caret.
struct DropdownPill<Label: View>: View {
  var kind: ComposerDropdown.Kind
  /// The composer this pill belongs to; see ComposerDropdown.Target.
  var owner: String
  var help: String
  @ViewBuilder var label: () -> Label
  @ObservedObject private var dropdown = ComposerDropdown.shared
  @State private var hovered = false
  @Environment(\.palette) var p
  var open: Bool { dropdown.open == ComposerDropdown.Target(kind: kind, owner: owner) }
  var body: some View {
    Button {
      dropdown.toggle(kind, owner: owner)
    } label: {
      HStack(spacing: 6) { label() }
        .font(UIStyle.font(12))
        .foregroundStyle(open || hovered ? KeelPicker.text(p.isDark) : p.secondary)
        .padding(.horizontal, 10).frame(height: KeelPicker.pillHeight)
        .fixedSize()
        .background(
          open || hovered ? KeelPicker.ink(p.isDark, 0.06) : .clear,
          in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
    }.buttonStyle(.pressable).onHover { hovered = $0 }.help(help)
      .anchorPreference(key: ComposerDropdownAnchorKey.self, value: .bounds) {
        [ComposerDropdown.Target(kind: kind, owner: owner): $0]
      }
      .animation(.easeInOut(duration: 0.15), value: hovered)
  }
}

// MARK: - Model picker

/// Rail of harnesses on the left (favourites star and Backups on top, then one mark per harness
/// with its status), a search box over the model list on the right. Rows are a letter tile and two lines
/// (model name over the harness name and capabilities), the route's cost tag (free, your key,
/// your plan, ModelRoute), a check on the chat's route, a ⌘N jump chip and a star. Every harness
/// Serein knows is listed: a route that cannot answer now (not installed, off, signed out) stays
/// greyed with its reason and cannot be picked. Legacy models fold into one row per harness.
/// Searching hides the rail and spans every harness. Arrow keys move one highlight, Return
/// picks, ⌘1–9 jump, Escape closes.
struct ModelPickerView: View {
  @ObservedObject var agent: AgentModel
  /// The chat a pick switches (a chat header's pill); nil is the selected thread (the composer).
  var chat: String? = nil
  /// Settings › AI apps › New chats start with: a pick sets the engine new chats start on
  /// (AgentModel.taskDefault) and no chat changes.
  var setsDefault = false
  /// The inspector's model pill: a pick sets this assistant's own route
  /// (RelayOrchestrator.chooseRoute), under the same switch rules as a chat's.
  var assistant: String? = nil
  var done: () -> Void
  @ObservedObject private var codexCatalog = CodexCatalog.shared
  @ObservedObject private var registry = HarnessRegistry.shared
  @ObservedObject private var favorites = ModelFavorites.shared
  @ObservedObject private var usage = RouteUsage.shared
  @State private var query = ""
  @State private var rail: Rail = .harness
  @State private var viewed: Provider = .codex
  @State private var active = 0
  @State private var legacyOpen: Set<Provider> = []
  @FocusState private var focused: Bool
  @Environment(\.palette) var p
  var dark: Bool { p.isDark }

  /// `backups`: the ordered routes a failing chat moves to (ModelBackupsList).
  enum Rail { case favorites, harness, backups }
  enum Item: Identifiable {
    case model(Row)
    case legacy(Provider, Int)
    var id: String {
      switch self {
      case .model(let row): return row.id
      case .legacy(let provider, _): return "legacy:" + provider.rawValue
      }
    }
  }
  struct Row: Identifiable {
    var provider: Provider
    var model: HarnessModel
    var route: ModelRoute
    var choice: ModelChoice { model.choice }
    var id: String { ModelFavorites.key(provider, model.id) }
  }
  /// The chat's engine and destination, which the check mark, the rail and the footer follow;
  /// in Settings, the default's engine with no destination of its own.
  var engine: AgentModel.ChatEngine {
    if let assistant, let relay = RelayOrchestrator.shared { return relay.chatEngine(ofAssistant: assistant) }
    guard setsDefault else { return agent.engine(of: chat ?? agent.conversationID) }
    let d = agent.taskDefault
    return AgentModel.ChatEngine(provider: d.provider, model: d.model, mode: .answer, link: nil, edits: false, permission: .supervised)
  }

  /// Every harness, the ones ready on this Mac first; the rest stay listed, greyed with why.
  var providers: [Provider] {
    let all = Provider.allCases.filter { agent.available[$0] != nil } + Provider.allCases.filter { agent.available[$0] == nil }
    let engine = self.engine
    guard [.project, .library].contains(engine.mode) else { return all }
    // A chat from another app keeps its own harness, whose CLI answers it there.
    let linked = engine.link.flatMap { HarnessDriver(rawValue: $0.driver) }.map(Provider.init)
    return all.filter { $0 == linked || ($0.driver.map(HarnessPolicy.fileDrivers.contains) ?? false) }
  }
  /// One row per model the harness lists; none are made up.
  func models(_ provider: Provider) -> [Row] {
    _ = codexCatalog.models
    let shown = registry.models(provider)
    var routes = agent.routes(provider, models: shown.map(\.id), project: engine.mode == .project)
    // An assistant thinks only with a harness that is given Serein's tools and may run its Main
    // chat (mode "anywhere"): a model endpoint, or a harness the policy refuses there, is greyed.
    if assistant != nil, let why = RelayOrchestrator.assistantRouteRefusal(provider) {
      routes = routes.map { route in
        var greyed = route
        greyed.reason = greyed.reason ?? why
        return greyed
      }
    }
    return zip(shown, routes).map { Row(provider: provider, model: $0, route: $1) }
  }
  var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
  /// Search spans every harness; favourites mix harnesses; otherwise the viewed harness
  /// with its starred rows floated to the top and legacy models folded at the end.
  var items: [Item] {
    // The Backups pane lists no picks: Return and ⌘1–9 do nothing there.
    if rail == .backups && !searching { return [] }
    let all = providers.flatMap(models)
    if searching {
      let needle = query.trimmingCharacters(in: .whitespaces)
      return all.filter {
        $0.model.name.localizedCaseInsensitiveContains(needle)
          || $0.model.id.localizedCaseInsensitiveContains(needle)
          || ($0.model.subProvider ?? "").localizedCaseInsensitiveContains(needle)
          || $0.provider.name.localizedCaseInsensitiveContains(needle)
      }.map(Item.model)
    }
    if rail == .favorites { return all.filter { favorites.contains($0.id) }.map(Item.model) }
    let own = models(viewed)
    let current = own.filter { !$0.model.isLegacy }
    let legacy = own.filter(\.model.isLegacy)
    // Starred first, then the harness's default, then new models, then the rest in the harness's order.
    let starred = current.filter { favorites.contains($0.id) }
    let rest = current.filter { !favorites.contains($0.id) }
    let listed = rest.filter { !$0.model.id.isEmpty }
    var out = (starred + rest.filter { $0.model.id.isEmpty } + listed.filter(\.model.isNew)
      + listed.filter { !$0.model.isNew }).map(Item.model)
    if !legacy.isEmpty {
      out.append(.legacy(viewed, legacy.count))
      if legacyOpen.contains(viewed) { out += legacy.map(Item.model) }
    }
    return out
  }
  func isSelected(_ row: Row) -> Bool {
    let engine = self.engine
    let id = registry.chosen(engine.provider, engine.model)?.id ?? ClaudeModelID.split(engine.model).base
    return row.provider == engine.provider && row.model.id == id
  }
  func isSelected(_ item: Item) -> Bool {
    if case .model(let row) = item { return isSelected(row) }
    return false
  }

  var body: some View {
    HStack(spacing: 0) {
      if !searching { railColumn }
      VStack(spacing: 0) {
        searchRow
        let items = self.items
        if rail == .backups && !searching {
          ModelBackupsList(agent: agent)
        } else if items.isEmpty {
          Text(emptyText).font(UIStyle.font(12)).foregroundStyle(KeelPicker.muted(dark))
            .multilineTextAlignment(.center).padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollViewReader { proxy in
            ScrollView {
              LazyVStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                  switch item {
                  case .model(let row): modelRow(row, index: index).id(item.id)
                  case .legacy(let provider, let count): legacyRow(provider, count: count, index: index).id(item.id)
                  }
                }
              }.padding(.horizontal, 6).padding(.vertical, 6)
            }.onChange(of: active) { _, index in
              if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
            }
          }
        }
        if let driver = signedOut {
          signInFooter(driver)
        } else if let note = footer {
          Text(note).font(UIStyle.font(11)).foregroundStyle(KeelPicker.muted(dark))
            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(KeelPicker.hairline(dark, 0.08)).frame(height: 1) }
            .accessibilityLabel(note)
        }
      }.background(KeelPicker.ink(dark, 0.02))
        .overlay(alignment: .leading) {
          if !searching { Rectangle().fill(KeelPicker.hairline(dark, 0.07)).frame(width: 1) }
        }
    }.font(UIStyle.font(13)).foregroundStyle(KeelPicker.text(dark))
      .onChange(of: query) { _, _ in active = 0 }
      .onChange(of: rail) { _, _ in active = items.firstIndex(where: isSelected) ?? 0 }
      .onChange(of: viewed) { _, _ in active = items.firstIndex(where: isSelected) ?? 0 }
      .onAppear {
        let current = engine.provider
        viewed = providers.contains(current) ? current : providers.first ?? .codex
        rail = favorites.keys.isEmpty ? .harness : .favorites
        active = items.firstIndex(where: isSelected) ?? 0
        focused = true
      }
      .background {
        // ⌘1–⌘9 jump to a visible row.
        ForEach(0..<9, id: \.self) { n in
          Button("") { pick(n) }
            .keyboardShortcut(KeyEquivalent(Character(String(n + 1))), modifiers: .command).hidden()
        }
      }
  }

  var emptyText: String {
    if searching { return "No models found" }
    if rail == .harness { return "\(viewed.name) lists no models yet" }
    return "No starred models yet — hit a row's star"
  }
  /// The viewed harness when its CLI reports no sign-in: its rows stay greyed, and the footer
  /// offers the provider's own sign-in and a fresh check instead of the verdict.
  var signedOut: HarnessDriver? {
    guard rail == .harness, !searching, let driver = viewed.driver, registry.snapshot(viewed)?.signedIn == false
    else { return nil }
    return driver
  }
  /// "Sign in" runs the provider's own login in Serein's terminal (no token is read); "Check
  /// again" probes now, so a sign-in made elsewhere re-enables the rows without leaving Serein.
  func signInFooter(_ driver: HarnessDriver) -> some View {
    let checking = registry.refreshing.contains(driver)
    return VStack(alignment: .leading, spacing: 6) {
      Text("Not signed in to \(viewed.name). Sign in, then check again.").font(UIStyle.font(11))
        .foregroundStyle(KeelPicker.muted(dark)).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 6) {
        Button("Sign in") {
          HarnessActions.shared.run(HarnessCommands.signIn(driver, version: registry.snapshots[driver]?.version), driver: driver)
          done()
        }.buttonStyle(QuietButton()).help("Runs \(HarnessCommands.signIn(driver, version: registry.snapshots[driver]?.version).display) in Serein's terminal")
          .accessibilityLabel("Sign in to \(viewed.name)")
        Button("Check again") { Task { await registry.refresh(driver, force: true) } }
          .buttonStyle(QuietButton()).disabled(checking)
          .accessibilityLabel("Check \(viewed.name) sign-in again")
        if checking { ProgressView().controlSize(.mini) }
      }
    }.padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .top) { Rectangle().fill(KeelPicker.hairline(dark, 0.08)).frame(height: 1) }
  }
  /// Why the viewed harness is not offered for this chat's destination, when it is not.
  var footer: String? {
    let engine = self.engine
    guard !searching, rail == .harness, engine.mode != .auto else { return nil }
    return registry.verdict(viewed, mode: engine.mode.runKey, edits: engine.edits, permission: engine.permission).reason
  }

  // MARK: rail (t3 ModelPickerSidebar)

  var railColumn: some View {
    VStack(spacing: 4) {
      RailTab(selected: rail == .favorites, help: "Starred models", badge: nil, action: { rail = .favorites }) {
        InterfaceIcon(systemName: "star.fill", size: 17)
          .foregroundStyle(rail == .favorites ? KeelPicker.text(dark) : KeelPicker.muted(dark).opacity(0.75))
      }
      RailTab(selected: rail == .backups, help: "Backups: tried in order when a chat's model fails", badge: nil,
              action: { rail = .backups }) {
        InterfaceIcon(systemName: "arrow.triangle.branch", size: 16)
          .foregroundStyle(rail == .backups ? KeelPicker.text(dark) : KeelPicker.muted(dark).opacity(0.75))
      }
      Rectangle().fill(KeelPicker.hairline(dark, 0.08)).frame(height: 1)
        .padding(.horizontal, -4).padding(.vertical, 1)
      ScrollView(.vertical, showsIndicators: false) {
      VStack(spacing: 4) {
      ForEach(providers) { provider in
        let on = rail == .harness && viewed == provider
        let snapshot = registry.snapshot(provider)
        RailTab(
          selected: on, help: provider.name + " — " + (snapshot?.message ?? agent.auth[provider] ?? "Not checked yet."),
          badge: railBadge(snapshot),
          action: {
            rail = .harness
            viewed = provider
          }
        ) {
          HarnessGlyph(provider: provider, size: 18, tinted: true)
            .foregroundStyle(on ? KeelPicker.text(dark) : KeelPicker.muted(dark))
            .opacity(agent.available[provider] == nil ? 0.45 : 1)
        }
      }
      }
      }
    }.padding(4).frame(width: KeelPicker.railWidth)
  }
  /// Amber for an available update or a missing sign-in; none when ready.
  func railBadge(_ s: HarnessSnapshot?) -> Color? {
    switch s?.status {
    case .needsUpdate?: return KeelPicker.warning
    case .needsSignIn?: return KeelPicker.warning
    case .error?: return p.danger
    default: return nil
    }
  }
  private struct RailTab<L: View>: View {
    var selected: Bool
    var help: String
    var badge: Color?
    var action: () -> Void
    @ViewBuilder var label: () -> L
    @State private var hovered = false
    @Environment(\.palette) var p
    var body: some View {
      Button(action: action) {
        label().frame(width: KeelPicker.railTab, height: KeelPicker.railTab).contentShape(Rectangle())
          .background(
            hovered && !selected ? KeelPicker.ink(p.isDark, 0.06) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
          )
          .overlay(alignment: .topTrailing) {
            if let badge {
              Circle().fill(badge).frame(width: 6, height: 6).padding(5).accessibilityHidden(true)
            }
          }
          .overlay(alignment: .trailing) {
            // The selected tab wears a 3-point accent bar hugging the rail's right edge.
            if selected {
              RoundedRectangle(cornerRadius: 1.5).fill(KeelPicker.purple(p.isDark))
                .frame(width: 3, height: 18).offset(x: 4)
            }
          }
      }.buttonStyle(.pressable).onHover { hovered = $0 }.help(help).accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
  }

  // MARK: search row

  var searchRow: some View {
    HStack(spacing: 8) {
      InterfaceIcon(systemName: "magnifyingglass", size: 14)
        .foregroundStyle(KeelPicker.muted(dark).opacity(0.7))
      TextField("Search models…", text: $query).textFieldStyle(.plain).textInputCursor().font(UIStyle.font(13))
        .focused($focused)
        .onKeyPress(.downArrow) {
          active = DestinationSearch.move(active, by: 1, count: items.count)
          return .handled
        }
        .onKeyPress(.upArrow) {
          active = DestinationSearch.move(active, by: -1, count: items.count)
          return .handled
        }
        .onKeyPress(.return) {
          pick(active)
          return .handled
        }
        .onKeyPress(.escape) {
          done()
          return .handled
        }
        .accessibilityLabel("Search models")
      if let update { UpdateButton(update: update, busy: registry.refreshing.contains(update.driver)) { done() } }
    }.padding(.horizontal, 10).frame(height: KeelPicker.searchHeight)
      .overlay(alignment: .bottom) { Rectangle().fill(KeelPicker.hairline(dark, 0.08)).frame(height: 1) }
  }

  /// The viewed harness's update, when it has one: a newer release its own update check found,
  /// or a version older than Serein needs. Its models come with the update.
  var update: Update? {
    guard !searching, rail == .harness, let driver = viewed.driver, let s = registry.snapshot(viewed), s.installed
    else { return nil }
    if s.needsUpdate {
      return Update(driver: driver, help: "Update \(viewed.name)\(s.latestVersion.map { " to \($0)" } ?? "") for its newest models.")
    }
    // Too old for Serein (Claude Code or Codex below its floor): every request is refused.
    if s.tooOld, let minimum = driver.minimumCLIVersion {
      return Update(driver: driver, help: "Update \(viewed.name) to \(minimum) or later. This version is too old for Serein.")
    }
    return nil
  }
  struct Update {
    var driver: HarnessDriver
    var help: String
  }
  /// Runs the harness's own update command in Serein's terminal window. When it ends, the CLI
  /// change on disk refreshes the model list (ModelSourceWatcher).
  private struct UpdateButton: View {
    var update: Update
    var busy: Bool
    var opened: () -> Void
    @State private var hovered = false
    @Environment(\.palette) var p
    var body: some View {
      Button {
        let real = HarnessRegistry.shared.snapshots[update.driver]?.path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        HarnessActions.shared.run(HarnessCommands.update(update.driver, installedAt: real), driver: update.driver)
        opened()
      } label: {
        Group {
          if busy {
            ProgressView().controlSize(.mini)
          } else {
            // Amber on dark, black on light.
            InterfaceIcon(systemName: "arrow.clockwise", size: 13)
              .foregroundStyle(p.isDark ? KeelPicker.warning : Color.black)
          }
        }.frame(width: 24, height: 24).contentShape(Rectangle())
          .background(hovered ? KeelPicker.ink(p.isDark, 0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
      }.buttonStyle(.pressable).disabled(busy).onHover { hovered = $0 }
        .help(update.help).accessibilityLabel(update.help)
    }
  }

  // MARK: rows

  func modelRow(_ row: Row, index: Int) -> some View {
    let selected = isSelected(row)
    let starred = favorites.contains(row.id)
    let route = row.route
    let second = [row.provider.name, row.model.subProvider].compactMap { $0 }.joined(separator: " · ")
    let caps = route.caps.map(\.label).joined(separator: " · ")
    // A greyed route says why on its second line; an open one says whose it is and what it can do.
    let detail = route.reason ?? second + " · " + caps
    return HStack(spacing: 8) {
      ModelMonogram(provider: row.provider, size: 24)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(row.model.name).font(UIStyle.font(12.5, weight: .medium))
            .foregroundStyle(KeelPicker.text(dark)).lineLimit(1)
          if registry.isUnavailable(row.provider, row.model.id) {
            Text("Unavailable").font(UIStyle.font(10)).foregroundStyle(KeelPicker.warning)
              .padding(.horizontal, 5).padding(.vertical, 1)
              .background(KeelPicker.warning.opacity(0.14), in: Capsule())
              .help("\(row.provider.name) refused this model earlier in this session.")
          } else if row.model.isNew {
            Text("New").font(UIStyle.font(10)).foregroundStyle(KeelPicker.purple(dark))
              .padding(.horizontal, 5).padding(.vertical, 1)
              .background(KeelPicker.purple(dark).opacity(0.14), in: Capsule())
          }
        }
        Text(detail).font(UIStyle.font(11))
          .foregroundStyle(KeelPicker.muted(dark).opacity(0.7)).lineLimit(1)
      }
      Spacer(minLength: 6)
      VStack(alignment: .trailing, spacing: 2) {
        RouteTag(cost: route.costClass)
        usageCell(route)
      }.frame(width: KeelPicker.routeColumn, alignment: .trailing)
      InterfaceIcon(systemName: "checkmark", size: 11)
        .foregroundStyle(KeelPicker.text(dark)).opacity(selected ? 1 : 0).frame(width: 14)
        .accessibilityHidden(true)
      if route.selectable, index < 9 {
        // popover::kbd_hint
        Text("⌘\(index + 1)").font(UIStyle.mono(10))
          .foregroundStyle(KeelPicker.muted(dark).opacity(0.6))
          .padding(.horizontal, 5).padding(.vertical, 1)
          .background(KeelPicker.ink(dark, 0.05), in: RoundedRectangle(cornerRadius: 5))
          .accessibilityHidden(true)
      }
      // Starring never picks, so a greyed row keeps its star (and can leave Starred).
      StarButton(starred: starred, name: row.model.name) { favorites.toggle(row.id) }
    }.padding(.horizontal, 8).padding(.vertical, 6)
      .opacity(route.selectable ? 1 : 0.45)
      .background(
        selected ? KeelPicker.wash(dark, 0.11) : index == active ? KeelPicker.ink(dark, 0.05) : .clear,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(selected ? KeelPicker.hairline(dark, 0.09) : .clear)
      )
      .contentShape(Rectangle())
      .onTapGesture { pick(index) }
      // One moving highlight: hovering moves the keyboard cursor.
      .onHover { if $0 { active = index } }
      .help(routeHelp(row))
      // One element whose press picks; with .combine the star, its only button, took the press.
      .accessibilityElement(children: .ignore)
      .accessibilityAction { pick(index) }
      .accessibilityAction(named: starred ? "Unstar" : "Star") { favorites.toggle(row.id) }
      .accessibilityLabel("\(row.model.name), \(second), \(route.costClass.label), \(caps)\(row.model.isNew ? ", new" : "")")
      .accessibilityValue([route.reason, usage.line(usage.summary(route.id))].compactMap { $0 }.joined(separator: ", "))
      .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
  }
  /// What Serein counted on this route this period (RouteUsage): calls · tokens with "est." or
  /// "CLI", only the tokens when the calls do not fit; the full line in its help.
  /// Amber once the route's warn level (Settings › Usage) is reached; a greyed route shows 0.
  func usageCell(_ route: ModelRoute) -> some View {
    let summary = usage.summary(route.id)
    let warn = usage.crossed(route.id, summary)
    return ViewThatFits(in: .horizontal) {
      Text(summary.compact)
      Text(summary.calls > 0 ? summary.tokensTag : summary.compact).minimumScaleFactor(0.8)
    }
    .font(UIStyle.font(10)).monospacedDigit()
    .foregroundStyle(warn ? p.warning : KeelPicker.muted(dark).opacity(0.7))
    .lineLimit(1).frame(height: 12)
    .help(usage.line(summary) + (warn ? " · past your warning level" : ""))
  }
  /// A greyed row's reason with what fixes it (the install or sign-in command); an open row's
  /// blurb.
  func routeHelp(_ row: Row) -> String {
    guard let reason = row.route.reason else { return row.model.blurb }
    guard let driver = row.provider.driver else { return reason }
    if !row.route.installed { return reason + "\nInstall: " + driver.installHint }
    if registry.snapshot(row.provider)?.signedIn == false { return reason + "\n" + (driver.signInCommand ?? driver.signInHint) }
    return reason
  }
  func legacyRow(_ provider: Provider, count: Int, index: Int) -> some View {
    let open = legacyOpen.contains(provider)
    return HStack(spacing: 8) {
      InterfaceIcon(systemName: "chevron.right", size: 10)
        .rotationEffect(.degrees(open ? 90 : 0))
        .foregroundStyle(KeelPicker.muted(dark))
      Text("Legacy models · \(count) \(count == 1 ? "model" : "models")").font(UIStyle.font(12))
        .foregroundStyle(KeelPicker.muted(dark))
      Spacer()
    }.padding(.horizontal, 8).frame(height: 30)
      .background(index == active ? KeelPicker.ink(dark, 0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
      .contentShape(Rectangle())
      .onTapGesture { pick(index) }
      .onHover { if $0 { active = index } }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Legacy models, \(count)").accessibilityValue(open ? "Expanded" : "Collapsed")
      .accessibilityAddTraits(.isButton)
  }
  private struct StarButton: View {
    var starred: Bool
    var name: String
    var toggle: () -> Void
    @State private var hovered = false
    @Environment(\.palette) var p
    var body: some View {
      Button(action: toggle) {
        InterfaceIcon(systemName: starred ? "star.fill" : "star", size: 13)
          .foregroundStyle(starred ? KeelPicker.warning : KeelPicker.muted(p.isDark).opacity(0.45))
          .frame(width: 22, height: 22).contentShape(Rectangle())
          .background(hovered ? KeelPicker.ink(p.isDark, 0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
      }.buttonStyle(.pressable).onHover { hovered = $0 }
        .help(starred ? "Unstar" : "Star")
        .accessibilityLabel(starred ? "Unstar \(name)" : "Star \(name)")
    }
  }

  func pick(_ index: Int) {
    let items = self.items
    guard items.indices.contains(index) else { return }
    switch items[index] {
    case .legacy(let provider, _):
      if legacyOpen.contains(provider) { legacyOpen.remove(provider) } else { legacyOpen.insert(provider) }
    case .model(let row):
      // A greyed route is not clickable: its reason stays on its row.
      guard row.route.selectable else { return }
      if let assistant {
        RelayOrchestrator.shared?.chooseRoute(row.route, for: assistant)
      } else if setsDefault {
        // Settings: only the default changes; no chat moves and no card is declined.
        let d = agent.taskDefault
        agent.taskDefault = RoutedChoice(
          provider: row.provider, model: row.model.id,
          effort: AgentModel.effort(for: row.model, keeping: d.effort, sameProvider: d.provider == row.provider))
      } else {
        agent.switchModel(chat: chat ?? agent.conversationID, route: row.route)
      }
      done()
    }
  }
}

/// A route's cost, exactly one per row: free, your key or your plan.
struct RouteTag: View {
  var cost: ModelRoute.CostClass
  @Environment(\.palette) var p
  var body: some View {
    Text(cost.label).font(UIStyle.font(10)).foregroundStyle(KeelPicker.muted(p.isDark)).lineLimit(1).fixedSize()
      .padding(.horizontal, 5).padding(.vertical, 1)
      .background(KeelPicker.ink(p.isDark, 0.06), in: Capsule())
      .help(Self.help(cost))
  }
  static func help(_ cost: ModelRoute.CostClass) -> String {
    switch cost {
    case .free: return "Free: your own model server, no key"
    case .yourKey: return "Your key: billed to your own API key"
    case .yourPlan: return "Your plan: runs on the plan you signed in to in the provider's own app"
    }
  }
}

/// Displays a provider logo, harness tile or monogram.
struct ModelMonogram: View {
  var provider: Provider
  var size: CGFloat = 22
  @Environment(\.palette) var p
  var letters: String {
    let all = Provider.allCases
    guard let index = all.firstIndex(of: provider) else { return ModelRoutes.monogram(provider.name) }
    return ModelRoutes.monograms(all.map { $0.name })[index]
  }
  var body: some View {
    if let brand = HarnessGlyph.colourBrand(provider) {
      BrandLogo(brand, size: size).accessibilityHidden(true)
    } else if provider.driver != nil {
      HarnessTile(provider: provider, size: size)
    } else {
      Text(letters)
        .font(UIStyle.font(size * 0.42, weight: .semibold)).foregroundStyle(p.ink).lineLimit(1)
        .frame(width: size, height: size)
        .background(p.track, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .accessibilityHidden(true)
    }
  }
}

/// The chat header's engine, under its title: a letter tile and the model's name, 18 high so
/// both lines fit the 44-point header. It opens the model list for this chat only; a pick
/// switches this chat and nothing else (AgentModel.switchModel).
struct ModelPill: View {
  @ObservedObject var agent: AgentModel
  /// The chat it switches; nil is the selected thread.
  var chat: String? = nil
  /// A narrow header shows the tile alone; the name stays in its help and VoiceOver value.
  var compact = false
  /// The inspector's pill: this assistant's own engine, with a chevron; a pick sets its route.
  var assistant: (id: String, name: String)? = nil
  /// In the chat's top row: this high, in the same capsule as the assistant's name pill beside it.
  var headerHeight: CGFloat? = nil
  /// Under Serein's message bar: the name alone in `meta`, no tile or chevron.
  var quiet = false
  @ObservedObject private var registry = HarnessRegistry.shared
  @State private var open = false
  @Environment(\.palette) var p
  init(agent: AgentModel, chat: String? = nil, compact: Bool = false, assistant: (id: String, name: String)? = nil,
       headerHeight: CGFloat? = nil, quiet: Bool = false) {
    self.quiet = quiet
    self.agent = agent
    self.chat = chat
    self.compact = compact
    self.assistant = assistant
    self.headerHeight = headerHeight
  }
  var body: some View {
    let engine = assistant.flatMap { who in RelayOrchestrator.shared?.chatEngine(ofAssistant: who.id) }
      ?? agent.engine(of: chat ?? agent.conversationID)
    let name = Self.name(engine)
    let choose: String = assistant.map { "Choose the model \($0.name) thinks with." } ?? "Choose the model for this chat."
    let label: String = assistant.map { "Model for \($0.name)" } ?? "Model for this chat"
    Button { open.toggle() } label: {
      if quiet {
        Text(name).font(UIStyle.meta).foregroundStyle(p.ink).lineLimit(1).truncationMode(.tail)
          .frame(maxWidth: 160, alignment: .trailing)
          .padding(.horizontal, 4).frame(height: 24).contentShape(Rectangle())
      } else {
      HStack(spacing: 5) {
        ModelMonogram(provider: engine.provider, size: 14)
        if !compact {
          Text(name).font(UIStyle.meta).foregroundStyle(p.ink).lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: 160, alignment: .leading)
        }
        if assistant != nil { InterfaceIcon(systemName: "chevron.down", size: 9).foregroundStyle(p.faint) }
      }.padding(.leading, headerHeight == nil ? 2 : 8).padding(.trailing, headerHeight != nil ? 10 : compact ? 2 : 7)
        .frame(height: headerHeight ?? UIStyle.wide(18))
        .background(headerHeight == nil ? Color.clear : p.pill, in: Capsule())
        // The assistant's pill (the inspector) takes a 24-point press area; the capsule stays 18
        // high. A chat header's pill keeps its 18, so both header lines fit.
        .padding(.vertical, assistant == nil || headerHeight != nil ? 0 : 3)
        .contentShape(Rectangle())
      }
    }.buttonStyle(AssistantPressStyle()).fixedSize()
      .help("\(engine.provider.name) · \(name). " + choose)
      .accessibilityLabel(label)
      .accessibilityValue("\(name), \(engine.provider.name)")
      .popover(isPresented: $open, arrowEdge: .bottom) {
        ModelPickerView(agent: agent, chat: chat, assistant: assistant?.id) { open = false }
          .frame(width: KeelPicker.width, height: KeelPicker.height)
          .background(KeelPicker.surface(p.isDark))
          .environment(\.palette, p)
      }
  }
  /// The model's listed name (the listed default for an empty id), else a readable form of its id.
  @MainActor static func name(_ engine: AgentModel.ChatEngine) -> String {
    let base = ClaudeModelID.split(engine.model).base
    if let listed = HarnessRegistry.shared.chosen(engine.provider, engine.model) { return listed.name }
    return base.isEmpty ? engine.provider.shortName : ModelBadge.display(base, provider: engine.provider.shortName)
  }
}

extension AgentModel {
  /// What a chat answers with and where it works.
  struct ChatEngine {
    var provider: Provider
    var model: String
    var mode: TaskMode
    var link: SessionLink?
    var edits: Bool
    var permission: RunPermissionMode
  }
  /// The selected thread's live choice, else the chat's saved record with a task reply's chosen
  /// model (what its next turn launches with, `ComposerFlow.dispatchToTask`).
  func engine(of id: String) -> ChatEngine {
    if id == conversationID {
      return ChatEngine(provider: provider, model: model, mode: mode, link: link,
                        edits: mode == .project && allowProjectEdits, permission: permission)
    }
    let thread = openThreadItem(id)
    let run = hub.latest(for: id)
    return ChatEngine(
      provider: thread?.provider ?? run?.spec.provider ?? provider,
      model: flow.taskChoices[id]?.model ?? thread?.model ?? run?.spec.model ?? "",
      mode: thread?.mode ?? run?.spec.mode ?? .answer, link: thread?.link,
      edits: RelayOrchestrator.shared?.child(id)?.edits ?? false, permission: .supervised)
  }
  /// A harness's routes as the model list shows them (ModelRoutes): installed from `available`,
  /// your key from its Keychain key's presence (or a key name left in its environment), free or
  /// a provider connection's model free on a keyless local server and your key otherwise
  /// (ProviderStore). No key or token value is read. `project`: the routes are for a project
  /// task, which a direct connection cannot run: it has Serein's hosted tools, no files or shell.
  func routes(_ provider: Provider, models: [String], project: Bool = false) -> [ModelRoute] {
    guard let driver = provider.driver else { return [] }
    let registry = HarnessRegistry.shared
    let connections = ProviderStore.shared.enabled
    let found = available[provider] != nil
    return ModelRoutes.harness(
      instance: registry.instance(driver), snapshot: registry.snapshot(provider), found: found,
      hasKey: registry.hasKey(driver), models: models
    ).map { route in
      var route = route
      guard driver == .claude || driver == .opencode,
        let c = ProviderRun.connection(forModel: route.model, wire: driver == .claude ? .anthropic : .openai, in: connections)
      else {
        if driver == .opencode, let note = ProviderStore.shared.unmovedNote(model: route.model) { route.reason = note }
        return route
      }
      route.costClass = c.keyless ? .free : .yourKey
      if c.directHTTP == true, driver == .opencode {
        route.installed = true
        route.reason = project ? "\(c.name) is a direct connection with no file or shell tools, so it cannot run a project task." : nil
        return route
      }
      // A saved Local model route reads as OpenCode now.
      if driver == .opencode, !found, registry.snapshot(provider)?.checkedAt != nil {
        route.reason = "\(c.name) runs through OpenCode, which is not installed. Settings › AI apps can install it."
      }
      return route
    }
  }
  /// Moves one chat to another route. Only that chat changes: another chat keeps its own record,
  /// and new chats keep starting on Settings' default (taskDefault). A real change drops what the
  /// old engine was asking: the chat's pending intents are emptied, its open cards answered no
  /// (RelayOrchestrator.declineApprovals) and its one-time sign-ins approval revoked
  /// (WebTaskGrant), so a yes given to one model is never spent by another; any later step mints
  /// a fresh intent and asks again (ApprovalGate.record). The next turn launches the new route (a
  /// changed harness or model also changes a warm process's key, Engines.start).
  /// If that route fails, the chat moves only to one of its backups (AgentModel.fallBack); with
  /// none that can answer, it shows its error and stays on it.
  func switchModel(chat id: String, route: ModelRoute) {
    guard route.selectable else { return }
    let target = Provider(rawValue: route.provider)
    let before = engine(of: id)
    let chosen = HarnessRegistry.shared.models(target).first { $0.id == route.model } ?? HarnessModel(id: route.model, name: route.model)
    if id == conversationID {
      choose(target, chosen)
      routedFrom = nil
      saveConversation()
    } else {
      // A task Serein started: its record is what its next reply (and agent_send) launches.
      guard let browser, let i = conversations.firstIndex(where: { $0.id == id }) else { return }
      let effort = Self.effort(
        for: chosen, keeping: flow.taskChoices[id]?.effort ?? conversations[i].effort ?? "medium",
        sameProvider: conversations[i].provider == target)
      conversations[i].provider = target
      conversations[i].model = route.model
      conversations[i].effort = effort
      conversations[i].routedFrom = nil
      flow.setTaskChoice(id, model: route.model, effort: effort)
      do { try browser.library.save(conversations, to: "sessions/threads.json") } catch {
        self.error = error.localizedDescription
      }
    }
    guard before.provider != target || ClaudeModelID.split(before.model).base != route.model else { return }
    // A pick made by hand retires an automatic move's banner, so its Undo cannot revert the pick.
    ModelBackups.shared.notices[id] = nil
    dropApprovals(chat: id)
  }
  /// What a chat's old engine was asking goes when its engine changes: its pending intents are
  /// emptied, its open cards answered no and its one-time sign-ins approval revoked, so a yes given
  /// to one model is never spent by another. A chat's switch (switchModel) and an assistant's own
  /// route on its Main chat (RelayOrchestrator.chooseRoute).
  func dropApprovals(chat id: String) {
    for run in hub.runs where run.spec.threadID == id {
      browser?.tasks[run.taskID]?.pendingApprovals = []
    }
    RelayOrchestrator.shared?.declineApprovals(thread: id)
    // "Allow signing in" was given to the old engine (its sheet names it); the new one asks again.
    WebTaskGrant.shared.revoke(thread: id)
  }
}

/// Starred models, kept in user defaults as "Provider:model" keys.
@MainActor final class ModelFavorites: ObservableObject {
  static let shared = ModelFavorites()
  private static let defaultsKey = "serein.modelFavorites"
  @Published private(set) var keys: Set<String>
  init() {
    keys = Set(UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [])
  }
  nonisolated static func key(_ provider: Provider, _ model: String) -> String {
    provider.rawValue + ":" + model
  }
  func contains(_ key: String) -> Bool { keys.contains(key) }
  func toggle(_ key: String) {
    if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
    UserDefaults.standard.set(Array(keys).sorted(), forKey: Self.defaultsKey)
  }
}

// MARK: - Traits (reasoning ladder, context, access + plan)

/// Keel's traits dropdown: a "Reasoning" heading over a ladder of 6-point bars filled in accent
/// up to the chosen level with the level names beneath (the levels the chosen model offers),
/// a 1M context switch when the model has one, the run's access mode, then the thread's
/// plan-first switch.
struct EffortLadder: View {
  @ObservedObject var agent: AgentModel
  /// Off under the composer's model list: there the project chip holds the access level.
  var showsAccess = true
  var width = KeelPicker.traitsWidth
  @ObservedObject private var context = ComposerContext.shared
  @ObservedObject private var registry = HarnessRegistry.shared
  @Environment(\.palette) var p
  static func label(_ level: String) -> String { HarnessOption.effortLabel(level) }
  /// The effort word beside the chosen model's name, when that model has effort levels.
  @MainActor static func shown(_ agent: AgentModel) -> String? {
    HarnessOption.effortShown(agent.effort, levels: levels(agent))
  }
  @MainActor static func model(_ agent: AgentModel) -> HarnessModel? { model(agent.provider, agent.model) }
  @MainActor static func model(_ provider: Provider, _ id: String) -> HarnessModel? {
    HarnessRegistry.shared.chosen(provider, id) ?? HarnessRegistry.shared.models(provider).first { $0.isDefault }
  }
  /// The levels the chosen model's app lists for it; none hides the ladder.
  @MainActor static func levels(_ agent: AgentModel) -> [String] { levels(agent.provider, agent.model) }
  @MainActor static func levels(_ provider: Provider, _ id: String) -> [String] { model(provider, id)?.effortLevels ?? [] }
  @MainActor static func hasContext(_ agent: AgentModel) -> Bool {
    agent.provider == .claude && model(agent)?.contextChoices.contains("1m") == true
  }
  @MainActor static func height(_ agent: AgentModel, showsAccess: Bool = true) -> CGFloat {
    // 66: the "Reasoning" heading and its ladder, with their gaps.
    (showsAccess ? 222 : 126) + (hasContext(agent) ? 30 : 0) - (levels(agent).isEmpty ? 66 : 0)
  }
  var body: some View {
    let dark = p.isDark
    let levels = Self.levels(agent)
    VStack(alignment: .leading, spacing: 10) {
      if !levels.isEmpty {
        Text("Reasoning").font(UIStyle.font(11))
          .foregroundStyle(KeelPicker.muted(dark)).padding(.horizontal, 4)
        HStack(spacing: 3) {
          let current = levels.firstIndex(of: agent.effort) ?? min(1, levels.count - 1)
          ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
            Button {
              agent.effort = level
            } label: {
              VStack(spacing: 7) {
                Capsule().fill(index <= current ? KeelPicker.purple(dark) : KeelPicker.ink(dark, 0.12))
                  .frame(height: 6)
                Text(Self.label(level)).font(UIStyle.font(11)).lineLimit(1).minimumScaleFactor(0.8)
                  .foregroundStyle(index == current ? KeelPicker.text(dark) : KeelPicker.muted(dark))
              }.frame(maxWidth: .infinity).padding(.vertical, 4).contentShape(Rectangle())
            }.buttonStyle(.pressable).accessibilityLabel("Effort \(Self.label(level))")
              .accessibilityAddTraits(index == current ? .isSelected : [])
          }
        }
      }
      if Self.hasContext(agent) {
        Toggle(isOn: Binding(
          get: { ClaudeModelID.split(agent.model).longContext },
          set: { agent.model = ClaudeModelID.join(ClaudeModelID.split(agent.model).base, longContext: $0) }
        )) {
          Text("1M-token context").font(UIStyle.font(12)).foregroundStyle(KeelPicker.text(dark))
        }.toggleStyle(SereinSwitchStyle()).padding(.horizontal, 4)
      }
      if showsAccess { access(dark) }
      Rectangle().fill(KeelPicker.hairline(dark, 0.08)).frame(height: 1).padding(.vertical, 2)
      Toggle(isOn: $context.planMode) {
        Text("Plan first, change nothing").font(UIStyle.font(12))
          .foregroundStyle(KeelPicker.text(dark))
      }.toggleStyle(SereinSwitchStyle()).padding(.horizontal, 4)
    }.padding(10).frame(width: width, height: Self.height(agent, showsAccess: showsAccess), alignment: .top)
  }
  @ViewBuilder func access(_ dark: Bool) -> some View {
    Rectangle().fill(KeelPicker.hairline(dark, 0.08)).frame(height: 1).padding(.vertical, 2)
    Text("Access").font(UIStyle.font(11))
      .foregroundStyle(KeelPicker.muted(dark)).padding(.horizontal, 4)
    HStack(spacing: 3) {
      ForEach(RunPermissionMode.allCases, id: \.self) { mode in
        let on = agent.permission == mode
        Button {
          choose(mode)
        } label: {
          VStack(spacing: 4) {
            Image(systemName: mode.icon).font(.system(size: 12, weight: .medium))
            Text(mode == .autoAcceptEdits ? "Edits" : mode == .fullAccess ? "Full" : mode.label)
              .font(UIStyle.font(11)).lineLimit(1)
          }.foregroundStyle(on ? KeelPicker.text(dark) : KeelPicker.muted(dark))
            .frame(maxWidth: .infinity).frame(height: 40)
            .background(on ? KeelPicker.wash(dark, 0.11) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.pressable).help(mode.label + ". " + mode.detail)
          .accessibilityLabel(mode.label).accessibilityHint(mode.detail)
          .accessibilityAddTraits(on ? .isSelected : [])
      }
    }
  }
  /// Full access asks once per project; Auto and Full access need a project.
  func choose(_ mode: RunPermissionMode) {
    if mode == .fullAccess {
      let project = agent.mode == .project ? agent.projectID : nil
      guard FullAccessConsent.request(projectID: project, projectName: nil) else {
        if project == nil { agent.error = "Full access works only in a project. Choose one first." }
        return
      }
    }
    agent.permission = mode
  }
}
