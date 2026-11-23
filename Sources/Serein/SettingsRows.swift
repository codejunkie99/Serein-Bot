import SereinCore
import SwiftUI

/// The row kinds of Settings' pages (boards 14 and 15), built on `SettingsListRow`: one row per
/// decision, each with its current answer in words. A summary row opens a sub-page (or does its
/// one action) with a chevron that does not turn; a switch row applies at once; a choice row is a
/// small menu. Rows sit in one card (`SettingsRowList`) with a hairline between them. Forms on a
/// sub-page use `SettingsBlock`, the same card with 16 points between its controls.

/// A caption over a card: 12, `secondary`, with an optional info popover for the long text.
struct SettingsRowsCaption: View {
  let title: String
  var info: String?
  @Environment(\.palette) private var p
  init(_ title: String, info: String? = nil) {
    self.title = title
    self.info = info
  }
  var body: some View {
    HStack(spacing: 4) {
      Text(verbatim: title).font(AssistantType.meta).foregroundStyle(p.secondary)
        .accessibilityAddTraits(.isHeader)
      if let info { InfoPopoverButton(text: info, label: "About \(title.lowercased())") }
    }.padding(.leading, 2).id(title)
  }
}

/// A section of rows: its caption (none when empty) over one card, and one optional sentence
/// under it, as Grok's `.cfg-card`: radius 12, 4 points in, a 0.5 hairline round it. Every row
/// draws a hairline at its top; the card hides the first one.
struct SettingsRowList<Rows: View>: View {
  let title: String
  var info: String?
  var note: String?
  @ViewBuilder var rows: () -> Rows
  @Environment(\.palette) private var p
  @Environment(\.settingsSectionTitle) private var section
  init(_ title: String = "", info: String? = nil, note: String? = nil, @ViewBuilder rows: @escaping () -> Rows) {
    self.title = title
    self.info = info
    self.note = note
    self.rows = rows
  }
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    VStack(alignment: .leading, spacing: 8) {
      if !title.isEmpty, !repeatsSection(title, section) { SettingsRowsCaption(title, info: info) }
      VStack(alignment: .leading, spacing: 0, content: rows)
        // The first row's hairline sits above the list's top edge, where the clip hides it.
        .padding(.top, -0.5).clipped()
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.card)
        .clipShape(shape)
        .overlay(shape.strokeBorder(p.hairline, lineWidth: UIStyle.hairline))
      if let note {
        Text(verbatim: note).font(AssistantType.meta).foregroundStyle(p.secondary)
          .fixedSize(horizontal: false, vertical: true).padding(.leading, 2)
      }
    }
  }
}

/// A form on a sub-page: its caption over one card whose controls sit 16 points apart; a
/// `SettingsNote` tucks in 4 points under the control it explains (as in `SettingsGroup`).
struct SettingsBlock<Content: View>: View {
  let title: String
  var info: String?
  @ViewBuilder var content: () -> Content
  @Environment(\.palette) private var p
  @Environment(\.settingsSectionTitle) private var section
  init(_ title: String, info: String? = nil, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.info = info
    self.content = content
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !title.isEmpty, !repeatsSection(title, section) { SettingsRowsCaption(title, info: info) }
      VStack(alignment: .leading, spacing: 16, content: content).font(UIStyle.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).settingsCard()
    }
  }
}

/// A summary row: its mark, title and current answer, and a chevron that does not turn. A click
/// anywhere on the row opens its sub-page, or does its one action (`hint` says which).
/// `danger` draws the title in `danger` (a delete, as the last row).
struct SettingsSummaryRow<Mark: View>: View {
  let title: String
  let answer: String
  var tone: Color?
  var danger = false
  var hint = "Opens its page"
  let open: () -> Void
  @ViewBuilder var mark: () -> Mark
  @State private var hovered = false
  @Environment(\.palette) private var p
  var body: some View {
    Button(action: open) {
      SettingsListRow(name: title, status: answer, statusTint: tone, expandable: false) {
        mark()
      } trailing: {
        InterfaceIcon(systemName: "chevron.right", size: 12).foregroundStyle(p.secondary).opacity(0.6)
      } live: {
        EmptyView()
      } details: {
        EmptyView()
      }
      .foregroundStyle(danger ? p.danger : p.ink)
      .background(hovered ? p.hover : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.pressable)
    .onHover { hovered = $0 }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title), \(answer)")
    .accessibilityHint(hint)
    .accessibilityAddTraits(.isButton)
  }
}

/// A switch row: its mark, title, current answer and the switch, which applies at once. `label`
/// is what VoiceOver reads for the switch (the title when nil); `info`, the long explanation, is
/// in a popover beside the switch.
struct SettingsSwitchRow<Mark: View>: View {
  let title: String
  let answer: String
  @Binding var isOn: Bool
  var label: String?
  var info: String?
  @ViewBuilder var mark: () -> Mark
  var body: some View {
    SettingsListRow(name: title, status: answer, expandable: false) {
      mark()
    } trailing: {
      HStack(spacing: 8) {
        if let info { InfoPopoverButton(text: info, label: "About \(title.lowercased())") }
        SettingsRowSwitch(label: label ?? title, isOn: $isOn)
      }
    } live: {
      EmptyView()
    } details: {
      EmptyView()
    }
  }
}

/// One choice of a choice row.
struct SettingsChoice<Value: Hashable>: Hashable {
  let value: Value
  let label: String
}

/// A choice row: its mark, title, current answer and a small menu of choices, which applies at
/// once; `info`, the long explanation, is in a popover beside the menu.
struct SettingsChoiceRow<Mark: View, Value: Hashable>: View {
  let title: String
  let answer: String
  @Binding var selection: Value
  let choices: [SettingsChoice<Value>]
  var info: String?
  @ViewBuilder var mark: () -> Mark
  @Environment(\.palette) var p
  var body: some View {
    SettingsListRow(name: title, status: answer, expandable: false) {
      mark()
    } trailing: {
      HStack(spacing: 8) {
        if let info { InfoPopoverButton(text: info, label: "About \(title.lowercased())") }
        SettingsPopUp(title, selection: $selection, choices: choices, showsTitle: false)
      }
    } live: {
      EmptyView()
    } details: {
      EmptyView()
    }
  }
}

/// "More" as the last row of a card: the rarely used rows fold under it, in the same card. Its
/// answer names what is inside. The rows appear at once; only the chevron turns.
struct SettingsMoreRows<Rows: View>: View {
  let answer: String
  @ViewBuilder var rows: () -> Rows
  @State private var open: Bool
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  init(answer: String, open: Bool = false, @ViewBuilder rows: @escaping () -> Rows) {
    self.answer = answer
    self.rows = rows
    _open = State(initialValue: open)
  }
  var body: some View {
    let reduce: Bool = systemReduceMotion || previewReducedEffects
    VStack(alignment: .leading, spacing: 0) {
      Button { open.toggle() } label: {
        SettingsListRow(name: "More", status: answer, expandable: false) {
          SettingsGlyphTile(systemName: "ellipsis")
        } trailing: {
          InterfaceIcon(systemName: "chevron.right", size: 11).foregroundStyle(p.faint)
            .rotationEffect(.degrees(open ? 90 : 0))
            .animation(reduce ? nil : Motion.swap, value: open)
            .frame(width: 24, height: 24)
        } live: {
          EmptyView()
        } details: {
          EmptyView()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.pressable)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("More, \(answer)")
      .accessibilityValue(open ? "Shown" : "Hidden")
      .accessibilityHint(open ? "Hides these settings" : "Shows these settings")
      .accessibilityAddTraits(.isButton)
      if open { rows() }
    }
  }
}

/// A row with no setting yet: a glyph and one line on how one arrives. With one quiet action at
/// most (`action`, titled `actionTitle`).
struct SettingsEmptyRow: View {
  let glyph: String
  let text: String
  var actionTitle: String?
  var action: (() -> Void)?
  @Environment(\.palette) private var p
  var body: some View {
    HStack(spacing: 12) {
      SettingsGlyphTile(systemName: glyph).accessibilityHidden(true)
      Text(verbatim: text).font(AssistantType.meta).foregroundStyle(p.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      if let actionTitle, let action {
        Button(actionTitle, action: action).buttonStyle(QuietButton())
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 8).frame(minHeight: 52)
    .settingsRowHairline()
  }
}

extension View {
  /// The hairline every settings row draws at its top (`SettingsRowList` hides the first one),
  /// for a row that is not a `SettingsListRow`.
  func settingsRowHairline() -> some View { modifier(SettingsRowHairline()) }
  /// The settings card's ground: radius 12 and a 0.5 hairline, as Grok's `.cfg-card`.
  func settingsCard() -> some View { modifier(SettingsCard()) }
}
private struct SettingsCard: ViewModifier {
  @Environment(\.palette) private var p
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    content.background(p.card, in: shape).overlay(shape.strokeBorder(p.hairline, lineWidth: UIStyle.hairline))
  }
}
private struct SettingsRowHairline: ViewModifier {
  @Environment(\.palette) private var p
  func body(content: Content) -> some View {
    content.overlay(alignment: .top) { Rectangle().fill(p.hairline).frame(height: 0.5) }
  }
}

/// An AI app's logo on the row's plate (Claude, Codex, Gemini in their own colours; the others
/// as their mark).
struct SettingsLogoTile: View {
  let provider: Provider
  @Environment(\.palette) private var p
  var body: some View {
    HarnessGlyph(provider: provider, size: 18, tinted: true, logo: true)
      .frame(width: 30, height: 30)
      .background(p.track, in: RoundedRectangle(cornerRadius: 7))
  }
}

/// Every choice in Settings (docs/demos/settings-menus.decision.md): the pill with the current
/// answer, which opens Serein's own menu with a check on the current choice, never the system's
/// pop-up. With `showsTitle` the title sits at the leading edge and the pill at the trailing one,
/// as a form's row; without it, the pill alone (a row's trailing control, a labelled HStack).
/// Disabled, it dims and opens nothing.
struct SettingsPopUp<Value: Hashable>: View {
  let title: String
  @Binding var selection: Value
  let choices: [SettingsChoice<Value>]
  var showsTitle = true
  var menuWidth: CGFloat = 220
  @Environment(\.isEnabled) private var enabled
  init(_ title: String, selection: Binding<Value>, choices: [SettingsChoice<Value>], showsTitle: Bool = true, menuWidth: CGFloat = 220) {
    self.title = title
    _selection = selection
    self.choices = choices
    self.showsTitle = showsTitle
    self.menuWidth = menuWidth
  }
  private var current: String { choices.first { $0.value == selection }?.label ?? "" }
  var body: some View {
    if showsTitle, !title.isEmpty {
      HStack(spacing: 12) {
        Text(verbatim: title)
        Spacer(minLength: 12)
        menu
      }
    } else {
      menu
    }
  }
  private var menu: some View {
    SereinMenuButton(title, help: title, width: menuWidth) {
      for choice in choices {
        SereinMenuItem.action(choice.label, checked: choice.value == selection) { selection = choice.value }
      }
    } label: { SettingsChoicePill(label: current) }
    .buttonStyle(.plain).fixedSize()
    .opacity(enabled ? 1 : 0.45).allowsHitTesting(enabled)
    .accessibilityLabel(title).accessibilityValue(current)
  }
}

/// The pill a choice shows: its answer in 13 `ink` and a 10-point chevron in `secondary`, 28 high
/// on `track` with a `line` ring (Grok's `.cfg-select`).
struct SettingsChoicePill: View {
  let label: String
  @Environment(\.palette) private var p
  var body: some View {
    HStack(spacing: 4) {
      Text(verbatim: label).lineLimit(1).truncationMode(.middle)
      InterfaceIcon(systemName: "chevron.down", size: 10).foregroundStyle(p.secondary)
    }
    .font(UIStyle.font(13)).foregroundStyle(p.ink)
    .padding(.leading, 10).padding(.trailing, 8).frame(height: 28)
    .frame(maxWidth: 240)
    .background(p.track, in: Capsule())
    .overlay(Capsule().strokeBorder(p.line, lineWidth: UIStyle.hairline))
    .contentShape(Capsule())
  }
}

/// Serein's own text field, in place of the system's rounded border: the choice pill's `track` fill and
/// `line` hairline at 28 high, 13-point `ink` text, and the `focus` colour as the ring while typing.
/// `.textFieldStyle(.serein)`; it styles secure fields the same way.
struct SereinFieldStyle: TextFieldStyle {
  func _body(configuration: TextField<Self._Label>) -> some View { Field(content: configuration) }
  private struct Field<Content: View>: View {
    let content: Content
    @FocusState private var focused: Bool
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    var body: some View {
      let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
      content.textFieldStyle(.plain).font(UIStyle.font(13)).foregroundStyle(p.ink)
        .focused($focused)
        .padding(.horizontal, 10).padding(.vertical, 5).frame(minHeight: 28)
        .background(p.track, in: shape)
        .overlay(shape.strokeBorder(focused ? p.focus : p.line, lineWidth: focused ? 1.5 : UIStyle.hairline))
        .contentShape(shape)
        .opacity(enabled ? 1 : 0.5)
        .animation(.easeOut(duration: 0.12), value: focused)
    }
  }
}

extension TextFieldStyle where Self == SereinFieldStyle {
  static var serein: SereinFieldStyle { SereinFieldStyle() }
}
