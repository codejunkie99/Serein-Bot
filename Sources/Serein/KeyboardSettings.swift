import AppKit
import SereinCore
import SwiftUI

/// Settings › General › Keyboard shortcuts. Menu shortcuts are read from the live main menu, so a new menu item shows up
/// here without a second list to maintain. Shortcuts that are not menu items are added by the catalog.
struct KeyboardSettings: View {
  @Environment(\.palette) private var p
  @State private var query = ""
  @AppStorage(TalkKey.defaultsKey) private var keyName = TalkKey.fn.rawValue

  static func menuEntries() -> [ShortcutEntry] {
    guard let bar = NSApp.mainMenu else { return [] }
    var out: [ShortcutEntry] = []
    func walk(_ menu: NSMenu, group: String) {
      for item in menu.items where !item.isSeparatorItem && !item.isAlternate {
        if let sub = item.submenu {
          walk(sub, group: group)
        } else if !item.keyEquivalent.isEmpty {
          let keys = ShortcutCatalog.display(
            key: item.keyEquivalent, flags: item.keyEquivalentModifierMask.rawValue)
          out.append(ShortcutEntry(group: group, title: item.title, keys: keys))
        }
      }
    }
    for top in bar.items {
      guard let menu = top.submenu else { continue }
      let name = menu.title.isEmpty ? "Serein" : menu.title
      walk(menu, group: name == "" ? "Serein" : name)
    }
    return out
  }

  var body: some View {
    let key = TalkKey(rawValue: keyName) ?? .fn
    let all = Self.menuEntries() + ShortcutCatalog.extras(talkKeyTitle: key.title)
    let shown = ShortcutCatalog.filter(all, query: query)
    VStack(alignment: .leading, spacing: 24) {
      HStack(spacing: 8) {
        InterfaceIcon(systemName: "magnifyingglass", size: 13).foregroundStyle(p.faint)
        TextField("Search shortcuts", text: $query).textFieldStyle(.plain).textInputCursor()
          .accessibilityLabel("Search shortcuts")
      }.padding(.horizontal, 10).frame(height: 30)
        .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: UIStyle.controlRadius).stroke(p.borderStrong))
      if shown.isEmpty {
        Text("No shortcut matches “\(query)”.").role(.meta)
      }
      ForEach(ShortcutCatalog.group(shown), id: \.name) { group in
        SettingsGroup(group.name) {
          ForEach(Array(group.entries.enumerated()), id: \.offset) { _, entry in
            HStack {
              Text(entry.title)
              Spacer()
              Text(entry.keys).font(UIStyle.monoMeta).foregroundStyle(p.secondary)
            }.padding(.vertical, 2)
          }
        }
      }
      SettingsNote("Shortcuts follow the menu bar. Hold-to-talk is set in Talking.")
    }
  }
}
