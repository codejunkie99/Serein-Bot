import SereinCore
import SwiftUI

/// The parts of Settings open in the main window like a tab (option B): the card's 44-point
/// header row (where Settings is, the search field and close) and the slim page list beside the
/// page, both on the card's own colour so the window keeps one sidebar and one card. The
/// Marketplace, which opens the same way, uses the same header row.

/// The card's first row while Settings shows: "⚙ Settings › AI apps › Mac access", then the
/// search field and ×. Each level above the open one is a button back to it; the one just above
/// takes Esc, and on a page itself × does. With the sidebar hidden the row first clears the
/// traffic lights and holds Show sidebar, as every other view's first row does.
struct SettingsTabHeader: View {
  /// The open page's label, then the title of each sub-page level under it.
  let levels: [String]
  @Binding var query: String
  /// Opens level `depth`: 0 is the page itself, 1 its first sub-page, and so on.
  let go: (Int) -> Void
  let close: () -> Void
  var sidebarHidden = false
  var fullScreen = false
  var showSidebar: () -> Void = {}
  /// The trail's first word and glyph, and what search and close name: Settings by default, or
  /// the Marketplace.
  var root = "Settings"
  var rootIcon = "gearshape"
  var searchPrompt = "Search settings…"
  @Environment(\.palette) private var p

  var body: some View {
    HStack(spacing: 8) {
      if sidebarHidden {
        Color.clear.frame(width: fullScreen ? 4 : UIStyle.trafficLightGutter).accessibilityHidden(true)
        Button(action: showSidebar) {
          InterfaceIcon(systemName: "sidebar.left", size: 16)
        }.buttonStyle(ToolbarIconButton()).help("Show sidebar").accessibilityLabel("Show sidebar")
      }
      trail.layoutPriority(1)
      Spacer(minLength: 12)
      SettingsSearchField(query: $query, prompt: searchPrompt, label: "Search \(root)")
        .frame(minWidth: 150, idealWidth: 240, maxWidth: 240)
      Button(action: close) {
        InterfaceIcon(systemName: "xmark", size: 13).frame(width: 28, height: 28).contentShape(Rectangle())
      }
      .buttonStyle(ToolbarIconButton())
      .keyboardShortcut(levels.count == 1 ? .cancelAction : nil)
      .help(levels.count == 1 ? "Close \(root) · Esc" : "Close \(root)")
      .accessibilityLabel("Close \(root)")
    }
    .padding(.leading, sidebarHidden ? 0 : 14).padding(.trailing, 8)
    .frame(height: UIStyle.headerHeight)
  }

  /// "⚙ Settings › Page › Sub-page": the last level in `ink` medium, the ones above it buttons.
  private var trail: some View {
    HStack(spacing: 6) {
      InterfaceIcon(systemName: rootIcon, size: 13).foregroundStyle(p.secondary).accessibilityHidden(true)
      Text(verbatim: root).font(UIStyle.body).foregroundStyle(p.secondary).lineLimit(1).fixedSize()
      ForEach(Array(levels.enumerated()), id: \.offset) { depth, title in
        InterfaceIcon(systemName: "chevron.right", size: 10).foregroundStyle(p.faint).accessibilityHidden(true)
        if depth == levels.count - 1 {
          Text(verbatim: title).font(UIStyle.body).foregroundStyle(p.ink).lineLimit(1).truncationMode(.middle)
            .accessibilityAddTraits(.isHeader)
        } else {
          SettingsTrailLink(title: title, isParent: depth == levels.count - 2) { go(depth) }
        }
      }
    }
    .accessibilityElement(children: .contain).accessibilityLabel("Where you are in \(root)")
  }
}

/// A level above the open one in the header's trail: `secondary`, `ink` on hover. The level just
/// above takes Esc, so Esc goes back one level before it closes Settings.
private struct SettingsTrailLink: View {
  let title: String
  let isParent: Bool
  let action: () -> Void
  @State private var hovered = false
  @Environment(\.palette) private var p
  var body: some View {
    Button(action: action) {
      Text(verbatim: title).font(UIStyle.body).foregroundStyle(hovered ? p.ink : p.secondary)
        .lineLimit(1).truncationMode(.middle).contentShape(Rectangle())
    }
    .buttonStyle(.pressable)
    .onHover { hovered = $0 }
    .keyboardShortcut(isParent ? .cancelAction : nil)
    .help(isParent ? "Back to \(title) · Esc" : "Back to \(title)")
    .accessibilityLabel("Back to \(title)")
  }
}

/// Settings' page list, inside the card on the card's own colour: the pages in 30-point rows
/// (glyph and label) under their captions (the first group has none). The open page sits on
/// `selected` with its glyph in `ink`; the rest wash on hover. A search keeps the captions of the
/// groups it still has pages in.
struct SettingsPageList: View {
  let query: String
  /// The open page's id.
  let selected: String
  let open: (String) -> Void
  @Environment(\.palette) private var p

  /// The list's width at the usual text size; it grows with the text so labels keep their room.
  static var width: CGFloat { (204 * UIStyle.textScale).rounded() }

  private var groups: [(group: String, pages: [SettingsCategory])] {
    SettingsCategory.grouped(SettingsCategory.search(query))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 1) {
        if groups.isEmpty {
          Text("No settings match.").font(AssistantType.meta).foregroundStyle(p.secondary)
            .padding(.horizontal, 10).padding(.top, 8)
        }
        ForEach(groups, id: \.group) { section in
          if !section.group.isEmpty {
            Text(verbatim: section.group).font(AssistantType.meta).foregroundStyle(p.secondary)
              .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 6)
              .accessibilityAddTraits(.isHeader)
          }
          ForEach(section.pages) { page in
            SettingsPageListRow(page: page, selected: page.id == selected) { open(page.id) }
          }
        }
      }.padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 20)
    }
    .scrollIndicators(.never)
    .frame(width: Self.width).frame(maxHeight: .infinity, alignment: .top)
    .accessibilityElement(children: .contain).accessibilityLabel("Settings pages")
  }
}

/// One page in Settings' list: its glyph and label, 30 high.
private struct SettingsPageListRow: View {
  let page: SettingsCategory
  let selected: Bool
  let action: () -> Void
  @State private var hovered = false
  @Environment(\.palette) private var p
  @Environment(\.reducesMotion) private var reduceMotion

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        InterfaceIcon(systemName: page.icon, size: 14)
          .foregroundStyle(selected ? p.ink : p.secondary).frame(width: 18)
        Text(verbatim: page.label).font(UIStyle.body)
          .foregroundStyle(p.ink).lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10).frame(height: 30)
      .background(
        RoundedRectangle(cornerRadius: UIStyle.rowRadius, style: .continuous)
          .fill(selected ? p.selected : (hovered ? p.hover : .clear))
      )
      .contentShape(RoundedRectangle(cornerRadius: UIStyle.rowRadius, style: .continuous))
    }
    .buttonStyle(.pressable)
    .onHover { inside in
      if reduceMotion { hovered = inside } else { withAnimation(.easeOut(duration: 0.12)) { hovered = inside } }
    }
    .accessibilityLabel(page.label)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// The search field in the header: a magnifying glass, "Search settings…", and a clear button
/// once something is typed. 28 high on `track` with a `line` ring that turns `borderStrong` with
/// focus.
private struct SettingsSearchField: View {
  @Binding var query: String
  var prompt = "Search settings…"
  var label = "Search settings"
  @FocusState private var focused: Bool
  @Environment(\.palette) private var p

  var body: some View {
    HStack(spacing: 8) {
      InterfaceIcon(systemName: "magnifyingglass", size: 12).foregroundStyle(p.faint)
        .accessibilityHidden(true)
      TextField(prompt, text: $query)
        .textFieldStyle(.plain).font(AssistantType.body).foregroundStyle(p.ink)
        .focused($focused)
        .accessibilityLabel(label)
      if !query.isEmpty {
        Button { query = "" } label: {
          InterfaceIcon(systemName: "xmark.circle.fill", size: 12).foregroundStyle(p.faint)
            .frame(width: 18, height: 18).contentShape(Rectangle())
        }.buttonStyle(.pressable).help("Clear search").accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 10).frame(height: 28)
    .background(p.track, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(focused ? p.borderStrong : p.line, lineWidth: UIStyle.hairline)
    )
    .contentShape(Rectangle())
    .onTapGesture { focused = true }
  }
}
