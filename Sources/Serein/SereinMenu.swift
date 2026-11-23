import AppKit
import SereinCore
import SwiftUI

// Serein's own "…" menus: an in-window panel drawn by the shell, not an NSMenu. Rows carry a
// leading icon, a label and an optional trailing shortcut, checkmark or submenu chevron; section
// headers and dividers group them; destructive rows use the danger color. The keyboard moves
// through rows (↑↓, → and ← for submenus, Return, Escape, type-to-select). Right-click context
// menus stay native.

/// One row of a Serein menu.
struct SereinMenuItem: Identifiable {
  enum Kind { case action, submenu, header, divider, note }
  let id = UUID().uuidString
  var kind: Kind
  var title = ""
  var icon: String?
  var shortcut: String?
  /// Quiet trailing words (a time), in secondary text.
  var detail: String?
  /// No leading icon column: for a menu whose rows have no icons (Past chats), so titles line up
  /// with the header.
  var iconColumn = true
  /// An assistant's petal in its tint (`AssistantMark`) instead of the template icon.
  var iconTint: String?
  /// That assistant's own icon (`RelayProfile.icon`) and whose it is, for a picture.
  var assistantIcon: AssistantIcon?
  var assistantID: String?
  /// An assistant's state: its glyph and words before the checkmark (the header picker).
  var state: SereinStatus?
  var checked = false
  var destructive = false
  var disabled = false
  var action: (() -> Void)?
  var children: [SereinMenuItem] = []
  /// An AI app's mark at the trailing edge (`ModelMonogram`): the app an assistant thinks with now.
  var mark: Provider? = nil
  /// That mark in the leading icon column instead: a row that is an AI app (the connect menu).
  var markLeads = false

  /// Rows the pointer and keyboard can land on.
  var selectable: Bool {
    switch kind {
    case .action: return !disabled
    case .submenu: return !disabled && !children.isEmpty
    default: return false
    }
  }
  var height: CGFloat {
    switch kind {
    case .divider: return SereinMenuMetrics.divider
    case .header: return SereinMenuMetrics.header
    default: return SereinMenuMetrics.row
    }
  }

  static func action(
    _ title: String, icon: String? = nil, shortcut: String? = nil, checked: Bool = false,
    destructive: Bool = false, disabled: Bool = false, _ action: @escaping () -> Void
  ) -> SereinMenuItem {
    SereinMenuItem(
      kind: .action, title: title, icon: icon, shortcut: shortcut, checked: checked,
      destructive: destructive, disabled: disabled, action: action)
  }
  /// An assistant's row: its mark (the petal in its tint, or its icon), its name, its state and the
  /// check when active.
  static func assistant(
    _ profile: RelayProfile, state: SereinStatus?, checked: Bool = false, _ action: @escaping () -> Void
  ) -> SereinMenuItem {
    SereinMenuItem(
      kind: .action, title: profile.name, icon: "serein.mark", iconTint: profile.colour ?? "indigo",
      assistantIcon: profile.icon, assistantID: profile.id, state: state, checked: checked, action: action)
  }
  /// A row with no icon column and quiet trailing words: “Find the best-rated ramen near me   1 d”.
  static func entry(_ title: String, detail: String?, _ action: @escaping () -> Void) -> SereinMenuItem {
    SereinMenuItem(kind: .action, title: title, detail: detail, iconColumn: false, action: action)
  }
  /// An AI app's row: its mark first, its name, and its next step in quiet words (Sign in, Install).
  static func app(_ choice: WelcomeChoice, detail: String?, _ action: @escaping () -> Void) -> SereinMenuItem {
    SereinMenuItem(
      kind: .action, title: choice.name, detail: detail, action: action,
      mark: Provider(choice.driver), markLeads: true)
  }
  static func submenu(
    _ title: String, icon: String? = nil, disabled: Bool = false,
    @SereinMenuBuilder _ children: () -> [SereinMenuItem]
  ) -> SereinMenuItem {
    SereinMenuItem(kind: .submenu, title: title, icon: icon, disabled: disabled, children: children())
  }
  static func header(_ title: String) -> SereinMenuItem { SereinMenuItem(kind: .header, title: title) }
  static var divider: SereinMenuItem { SereinMenuItem(kind: .divider) }
  /// A quiet line that cannot be chosen ("No saved passwords for this site").
  static func note(_ title: String) -> SereinMenuItem { SereinMenuItem(kind: .note, title: title) }
}

@resultBuilder enum SereinMenuBuilder {
  static func buildExpression(_ item: SereinMenuItem) -> [SereinMenuItem] { [item] }
  static func buildExpression(_ items: [SereinMenuItem]) -> [SereinMenuItem] { items }
  static func buildBlock(_ parts: [SereinMenuItem]...) -> [SereinMenuItem] { parts.flatMap { $0 } }
  static func buildOptional(_ part: [SereinMenuItem]?) -> [SereinMenuItem] { part ?? [] }
  static func buildEither(first: [SereinMenuItem]) -> [SereinMenuItem] { first }
  static func buildEither(second: [SereinMenuItem]) -> [SereinMenuItem] { second }
  static func buildArray(_ parts: [[SereinMenuItem]]) -> [SereinMenuItem] { parts.flatMap { $0 } }
}

enum SereinMenuMetrics {
  static let row: CGFloat = 30
  static let header: CGFloat = 26
  static let divider: CGFloat = 9
  static let inset: CGFloat = 4
  static let width: CGFloat = 248
  static func height(_ items: [SereinMenuItem]) -> CGFloat {
    items.reduce(0) { $0 + $1.height } + 2 * inset
  }
}

/// The open menu, its open submenus and the highlighted row at each level. One per window shell.
@MainActor final class SereinMenuCenter: ObservableObject {
  static let shared = SereinMenuCenter()
  /// The shell's coordinate space; triggers report their frames in it.
  nonisolated static let space = "SereinMenuSpace"
  struct Presented {
    var trigger: String
    var label: String
    var items: [SereinMenuItem]
    var anchor: CGRect
    var width: CGFloat
    var leading: Bool
  }
  @Published private(set) var presented: Presented?
  /// Submenu row indices from the root menu down.
  @Published private(set) var path: [Int] = []
  /// The highlighted row per level (root first).
  @Published private(set) var highlight: [Int?] = [nil]
  private var monitor: Any?
  private var typed = ""
  private var typedAt = Date.distantPast

  func isOpen(_ trigger: String) -> Bool { presented?.trigger == trigger }
  func toggle(_ menu: Presented) {
    if presented?.trigger == menu.trigger { close() } else { present(menu) }
  }
  func present(_ menu: Presented, highlightFirst: Bool = false) {
    presented = menu
    path = []
    highlight = [highlightFirst ? MenuNavigation.first(menu.items.map(\.selectable)) : nil]
    startMonitor()
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
      .announcement: "\(menu.label) menu", .priority: NSAccessibilityPriorityLevel.low.rawValue,
    ])
  }
  func close() {
    presented = nil
    path = []
    highlight = [nil]
    typed = ""
    stopMonitor()
  }
  /// The rows shown at `level` (0 is the root menu).
  func items(level: Int) -> [SereinMenuItem] {
    guard var items = presented?.items else { return [] }
    for index in path.prefix(level) {
      guard items.indices.contains(index) else { return [] }
      items = items[index].children
    }
    return items
  }
  var levels: Int { presented == nil ? 0 : path.count + 1 }

  func hover(level: Int, index: Int) {
    let rows = items(level: level)
    guard rows.indices.contains(index), rows[index].selectable else { return }
    var marks = Array(highlight.prefix(level + 1))
    while marks.count < level + 1 { marks.append(nil) }
    marks[level] = index
    var trail = Array(path.prefix(level))
    if rows[index].kind == .submenu {
      trail.append(index)
      marks.append(nil)
    }
    path = trail
    highlight = marks
  }
  /// Return, a click or VoiceOver's press: runs the row, or opens its submenu.
  func activate(level: Int, index: Int) {
    let rows = items(level: level)
    guard rows.indices.contains(index), rows[index].selectable else { return }
    let row = rows[index]
    if row.kind == .submenu {
      openSubmenu(level: level, index: index)
      return
    }
    let action = row.action
    close()
    DispatchQueue.main.async { action?() }
  }
  func openSubmenu(level: Int, index: Int) {
    let rows = items(level: level)
    guard rows.indices.contains(index), rows[index].kind == .submenu else { return }
    path = Array(path.prefix(level)) + [index]
    var marks = Array(highlight.prefix(level + 1))
    while marks.count < level + 1 { marks.append(nil) }
    marks[level] = index
    marks.append(MenuNavigation.first(rows[index].children.map(\.selectable)))
    highlight = marks
  }

  // MARK: Keyboard

  private func startMonitor() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
      let swallow = MainActor.assumeIsolated { self?.key(event) ?? false }
      return swallow ? nil : event
    }
  }
  private func stopMonitor() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }
  /// Handles one key while the menu is open; true when it was used.
  private func key(_ event: NSEvent) -> Bool {
    guard presented != nil else { return false }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags.contains(.command) || flags.contains(.control) {
      // Shortcuts close the menu and still run.
      close()
      return false
    }
    let level = levels - 1
    let rows = items(level: level)
    let selectable = rows.map(\.selectable)
    let current = highlight.indices.contains(level) ? highlight[level] : nil
    switch event.keyCode {
    case 53:  // Escape: close the innermost submenu, then the menu.
      if path.isEmpty { close() } else { back() }
    case 48: close()  // Tab
    case 125, 126:  // Down, Up
      setHighlight(level, MenuNavigation.move(selectable, from: current, step: event.keyCode == 125 ? 1 : -1))
    case 124:  // Right opens a highlighted submenu.
      if let current, rows.indices.contains(current), rows[current].kind == .submenu, rows[current].selectable {
        openSubmenu(level: level, index: current)
      }
    case 123:  // Left closes a submenu.
      if !path.isEmpty { back() }
    case 36, 76, 49:  // Return, Enter, Space
      if let current { activate(level: level, index: current) }
    default:
      guard let text = event.charactersIgnoringModifiers, text.count == 1,
        text.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
      else { return true }
      if Date().timeIntervalSince(typedAt) > 0.8 { typed = "" }
      typed += text
      typedAt = Date()
      if let found = MenuNavigation.match(rows.map(\.title), selectable: selectable, typed: typed, from: current) {
        setHighlight(level, found)
      }
    }
    return true
  }
  private func setHighlight(_ level: Int, _ index: Int?) {
    var marks = Array(highlight.prefix(level + 1))
    while marks.count < level + 1 { marks.append(nil) }
    marks[level] = index
    highlight = marks
    // Moving within a level closes deeper submenus.
    path = Array(path.prefix(level))
  }
  private func back() {
    path.removeLast()
    highlight = Array(highlight.prefix(path.count + 1))
  }
}

/// A trigger for a Serein menu: any label, usually the "…" icon. The rows are built when it opens.
struct SereinMenuButton<Label: View>: View {
  var label: String
  var help: String?
  var width: CGFloat = SereinMenuMetrics.width
  /// Opens toward the trailing edge from the trigger's leading edge (default: aligned to its
  /// trailing edge, opening leftward).
  var leading = false
  /// A preview notification that opens this menu (synthetic captures only).
  var previewNotification: String?
  var items: () -> [SereinMenuItem]
  @ViewBuilder var content: () -> Label
  @ObservedObject private var center = SereinMenuCenter.shared
  @State private var id = UUID().uuidString
  @State private var frame: CGRect = .zero
  @Environment(\.palette) var p
  init(
    _ label: String, help: String? = nil, width: CGFloat = SereinMenuMetrics.width, leading: Bool = false,
    previewNotification: String? = nil, @SereinMenuBuilder items: @escaping () -> [SereinMenuItem],
    @ViewBuilder label content: @escaping () -> Label
  ) {
    self.label = label
    self.help = help
    self.width = width
    self.leading = leading
    self.previewNotification = previewNotification
    self.items = items
    self.content = content
  }
  var open: Bool { center.isOpen(id) }
  func menu() -> SereinMenuCenter.Presented {
    .init(trigger: id, label: label, items: items(), anchor: frame, width: width, leading: leading)
  }
  var body: some View {
    Button { center.toggle(menu()) } label: { content() }
      .background(open ? p.selected : .clear, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SereinMenuCenter.space)) } action: {
        frame = $0
      }
      .help(help ?? label)
      .accessibilityLabel(label)
      .accessibilityHint("Opens a menu")
      .accessibilityValue(open ? "Open" : "")
      .preference(key: SereinMenuOpen.self, value: open)
      .onReceive(NotificationCenter.default.publisher(for: Notification.Name(previewNotification ?? "SereinNoPreview"))) { _ in
        guard previewNotification != nil, CommandLine.arguments.contains("--ui-preview") else { return }
        let shown = menu()
        center.present(shown, highlightFirst: true)
        if let first = shown.items.firstIndex(where: { $0.kind == .submenu && $0.selectable }) {
          center.openSubmenu(level: 0, index: first)
        }
      }
  }
}

/// Whether a menu button's menu is open, for a trigger that shows only on hover.
struct SereinMenuOpen: PreferenceKey {
  static let defaultValue = false
  static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Draws the open menu and its submenus over the whole shell, with a click-outside catcher.
struct SereinMenuLayer: View {
  @ObservedObject private var center = SereinMenuCenter.shared
  @Environment(\.palette) var p
  @Environment(\.accessibilityReduceMotion) var systemReduceMotion
  @Environment(\.sereinReducedEffects) var previewReducedEffects
  var reduceMotion: Bool { systemReduceMotion || previewReducedEffects }
  var body: some View {
    GeometryReader { geometry in
      if let shown = center.presented {
        let frames = Self.frames(center: center, shown: shown, size: geometry.size)
        ZStack(alignment: .topLeading) {
          Color.black.opacity(0.001).contentShape(Rectangle())
            .onTapGesture { center.close() }
            .accessibilityHidden(true)
          ForEach(Array(frames.enumerated()), id: \.offset) { level, frame in
            panel(level: level, label: level == 0 ? shown.label : center.items(level: level - 1)[center.path[level - 1]].title)
              .frame(width: frame.width, height: frame.height)
              .offset(x: frame.minX, y: frame.minY)
              .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
          }
        }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
      }
    }.animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: center.presented?.trigger)
  }

  /// Each level's frame: the root under its trigger (above it when there is no room), each
  /// submenu beside its row (on the other side when there is no room). Kept 8 points inside.
  static func frames(center: SereinMenuCenter, shown: SereinMenuCenter.Presented, size: CGSize) -> [CGRect] {
    var out: [CGRect] = []
    let width = UIStyle.wide(shown.width)
    let margin: CGFloat = 8
    for level in 0..<center.levels {
      let rows = center.items(level: level)
      let height = min(SereinMenuMetrics.height(rows), max(60, size.height - 2 * margin))
      var x: CGFloat
      var y: CGFloat
      if level == 0 {
        x = shown.leading ? shown.anchor.minX : shown.anchor.maxX - width
        y = shown.anchor.maxY + 4
        if y + height > size.height - margin { y = shown.anchor.minY - 4 - height }
      } else {
        let parent = out[level - 1]
        let index = center.path[level - 1]
        let above = center.items(level: level - 1).prefix(index).reduce(0) { $0 + $1.height }
        x = parent.maxX - 2
        if x + width > size.width - margin { x = parent.minX - width + 2 }
        y = parent.minY + above
      }
      x = min(max(margin, x), max(margin, size.width - width - margin))
      y = min(max(margin, y), max(margin, size.height - height - margin))
      out.append(CGRect(x: x, y: y, width: width, height: height))
    }
    return out
  }

  func panel(level: Int, label: String) -> some View {
    let rows = center.items(level: level)
    let mark = center.highlight.indices.contains(level) ? center.highlight[level] : nil
    let openRow = center.path.indices.contains(level) ? center.path[level] : nil
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    return ScrollView(.vertical) {
      VStack(spacing: 0) {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
          SereinMenuRow(
            item: row, highlighted: mark == index || openRow == index,
            hover: { center.hover(level: level, index: index) },
            activate: { center.activate(level: level, index: index) })
        }
      }.padding(SereinMenuMetrics.inset)
    }.scrollIndicators(.never).scrollBounceBehavior(.basedOnSize)
      // Grok's `.menu`: the opaque pane, a 0.5 line and `--shadow-popover` (none in dark).
      .background(shape.fill(p.panel))
      .overlay(shape.strokeBorder(p.line, lineWidth: UIStyle.hairline))
      .clipShape(shape)
      .shadow(color: p.shadow(0.25), radius: 10, y: 10)
      .shadow(color: p.shadow(0.2), radius: 3, y: 4)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("\(label) menu")
      .accessibilityAddTraits(.isModal)
  }
}

/// One row: icon, label, then a checkmark, shortcut or submenu chevron.
struct SereinMenuRow: View {
  var item: SereinMenuItem
  var highlighted: Bool
  var hover: () -> Void
  var activate: () -> Void
  @Environment(\.palette) var p
  var tint: Color { item.disabled ? p.faint : item.destructive ? p.danger : p.ink }
  var body: some View {
    switch item.kind {
    case .divider:
      Rectangle().fill(p.line).frame(height: 1).padding(.horizontal, 6)
        .frame(height: item.height).accessibilityHidden(true)
    case .header:
      Text(item.title).font(UIStyle.font(12)).foregroundStyle(p.faint)
        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
        .padding(.top, 6).padding(.bottom, 4).frame(height: item.height).accessibilityAddTraits(.isHeader)
    case .note:
      Text(item.title).font(UIStyle.meta).foregroundStyle(p.faint).lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: item.height)
    case .action, .submenu:
      Button(action: activate) {
        HStack(spacing: 8) {
          if item.icon != nil || item.iconColumn {
            Group {
              if item.markLeads, let mark = item.mark {
                ModelMonogram(provider: mark, size: 16)
              } else if let iconTint = item.iconTint {
                AssistantMark(tint: iconTint, size: 16, icon: item.assistantIcon, owner: item.assistantID)
                  .opacity(item.disabled ? 0.4 : 1)
              } else if let icon = item.icon {
                InterfaceIcon(systemName: icon, size: 13)
              } else {
                Color.clear
              }
            }.frame(width: 16, height: 16).foregroundStyle(item.destructive && !item.disabled ? p.danger : item.disabled ? p.faint : p.secondary)
          }
          Text(item.title).font(UIStyle.body).tracking(0.195).foregroundStyle(tint).lineLimit(1).truncationMode(.tail)
          Spacer(minLength: 8)
          if let detail = item.detail {
            Text(detail).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1).fixedSize()
          }
          if let state = item.state, state != .ready {
            // The glyph, then the words (the spinner already carries a working count).
            HStack(spacing: 4) {
              SereinStatusGlyph(status: state)
              if let words = state.rowWords, !state.spins {
                Text(words).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1).fixedSize()
              }
            }
          }
          if let mark = item.mark, !item.markLeads { ModelMonogram(provider: mark, size: 16) }
          if item.checked {
            InterfaceIcon(systemName: "checkmark", size: 11).foregroundStyle(item.disabled ? p.faint : p.ink)
          }
          if let shortcut = item.shortcut {
            Text(shortcut).font(UIStyle.font(12)).foregroundStyle(p.faint).fixedSize()
          }
          if item.kind == .submenu {
            InterfaceIcon(systemName: "chevron.right", size: 9).foregroundStyle(p.faint)
          }
        }.padding(.horizontal, 10).frame(height: item.height).contentShape(Rectangle())
          .background(highlighted && item.selectable ? p.hover : .clear,
            in: RoundedRectangle(cornerRadius: UIStyle.controlRadius, style: .continuous))
      }.buttonStyle(.pressable).disabled(!item.selectable)
        .onHover { if $0 { hover() } }
        .accessibilityLabel([item.title, item.detail, item.state?.spoken].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(item.checked ? "Checked" : "")
        .accessibilityHint(item.kind == .submenu ? "Opens a submenu" : item.shortcut.map { "Shortcut \($0)" } ?? "")
        .accessibilityAddTraits(item.checked ? .isSelected : [])
    }
  }
}
