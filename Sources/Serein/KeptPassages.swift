import SereinCore
import SwiftUI

/// Kept passages: capture with a text-quote anchor, highlight again on revisit, list per page.
@MainActor final class KeptPassages: ObservableObject {
  static let shared = KeptPassages()
  /// Mark IDs that were found on the page, by tab.
  @Published var found: [String: Set<String>] = [:]
  private static let source: String? = {
    guard let url = Bundle.assets.url(forResource: "KeptPassages", withExtension: "js") else {
      return nil
    }
    return try? String(contentsOf: url)
  }()

  func forget(_ tabID: String) { found[tabID] = nil }

  /// Only normal tabs on pages that are not sign-in, payment or account pages.
  func eligible(_ tab: BrowserTab) -> Bool {
    !tab.privateMode && tab.owner == nil && !tab.sleeping && !tab.address.isEmpty
      && !SensitivePage.isSensitive(address: tab.address)
  }
  /// Loads the helper into the page and returns false when the page holds a password or card field.
  private func prepare(_ tab: BrowserTab) async -> Bool {
    guard eligible(tab), let source = Self.source else { return false }
    _ = try? await tab.script(source + "\n0;")
    let sensitive = (try? await tab.script("globalThis.__sereinKept.sensitive()")) as? Bool
    return sensitive == false
  }
  func marks(on tab: BrowserTab, in marks: [Mark]) -> [Mark] {
    let key = PageIdentity.key(tab.address)
    return marks.filter { !$0.quote.isEmpty && PageIdentity.key($0.url) == key }
  }
  /// The selected text (first 1,000 characters) and its anchor. Selections inside form fields
  /// and anything on a sensitive page are not read.
  func capture(in tab: BrowserTab) async -> (quote: String, anchor: KeptAnchor?) {
    guard await prepare(tab),
      let result = try? await tab.script("globalThis.__sereinKept.capture()") as? [String: Any],
      let exact = result["exact"] as? String
    else { return ("", nil) }
    let anchor = KeptAnchor(
      prefix: result["prefix"] as? String ?? "", exact: exact,
      suffix: result["suffix"] as? String ?? "")
    return (anchor.exact, anchor)
  }
  func restore(in tab: BrowserTab, marks all: [Mark]) {
    let mine = marks(on: tab, in: all)
    guard !mine.isEmpty else {
      found[tab.id] = nil
      return
    }
    Task {
      guard await prepare(tab) else { return }
      let items: [[String: Any]] = mine.map {
        [
          "id": $0.id, "exact": $0.anchor?.exact ?? $0.quote, "prefix": $0.anchor?.prefix ?? "",
          "suffix": $0.anchor?.suffix ?? "",
        ]
      }
      let reply = try? await tab.script("globalThis.__sereinKept.setKept(\(jsonString(items)))")
      let ids = (reply as? [String: Any])?["kept"] as? [String] ?? []
      found[tab.id] = Set(ids)
    }
  }
  func jump(_ mark: Mark, in tab: BrowserTab) {
    Task {
      _ = try? await tab.script(
        "globalThis.__sereinKept && globalThis.__sereinKept.jump('kept',\(jsonString(mark.id)))")
    }
  }

  // Start-page resurfacing.
  static let resurfaceKey = "serein.resurfaceKept"
}

/// "Kept on this page" list.
struct KeptOnPage: View {
  @ObservedObject var browser: BrowserModel
  let tab: BrowserTab
  @ObservedObject private var kept = KeptPassages.shared
  @Environment(\.palette) var p
  var items: [Mark] { kept.marks(on: tab, in: browser.marks) }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Kept on this page").font(UIStyle.metaStrong)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          ForEach(items) { mark in
            let here = kept.found[tab.id]?.contains(mark.id) == true
            VStack(alignment: .leading, spacing: 4) {
              Text(String(mark.quote.prefix(240))).font(UIStyle.meta).lineLimit(4)
              HStack {
                Text(mark.date.formatted(date: .abbreviated, time: .omitted)).font(UIStyle.micro).foregroundStyle(p.secondary)
                Spacer()
                if here {
                  Button("Show") { kept.jump(mark, in: tab) }.buttonStyle(QuietButton())
                } else {
                  Text("Not on the page now").font(UIStyle.micro).foregroundStyle(p.secondary)
                }
              }
            }.padding(10).background(
              p.track, in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
          }
        }
      }.frame(maxHeight: 260)
    }.padding(14).frame(width: UIStyle.wide(340))
  }
}

/// One passage you kept a while ago, offered again on the start page.
struct ResurfacedPassages: View {
  @ObservedObject var browser: BrowserModel
  @AppStorage(KeptPassages.resurfaceKey) private var enabled = true
  @State private var shown: [String: Int] = [:]
  @State private var loaded = false
  @Environment(\.palette) var p
  var due: [(mark: Mark, stage: Int)] {
    guard enabled else { return [] }
    return Array(KeptResurface.due(marks: browser.marks, shown: shown).prefix(2))
  }
  var body: some View {
    VStack(spacing: 10) {
      ForEach(due, id: \.mark.id) { item in
        VStack(alignment: .leading, spacing: 8) {
          Text(KeptResurface.label(stage: item.stage)).font(UIStyle.micro)
            .foregroundStyle(p.accent)
          Text(String(item.mark.quote.prefix(260))).font(UIStyle.reading)
            .lineLimit(5)
          Text(item.mark.title).font(UIStyle.micro).foregroundStyle(p.secondary).lineLimit(1)
          HStack {
            Button("Open page") {
              acknowledge(item)
              browser.newTab(item.mark.url)
            }.buttonStyle(QuietButton())
            Button("Not now") { acknowledge(item) }.buttonStyle(QuietButton())
            Spacer()
          }
        }.padding(16).frame(maxWidth: 680, alignment: .leading).background(
          p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius)
        ).overlay(RoundedRectangle(cornerRadius: UIStyle.panelRadius).stroke(p.line))
      }
    }.padding(.top, due.isEmpty ? 0 : 22).onAppear {
      guard !loaded else { return }
      loaded = true
      shown = browser.library.load([String: Int].self, from: "index/resurfaced.json") ?? [:]
    }
  }
  func acknowledge(_ item: (mark: Mark, stage: Int)) {
    shown[item.mark.id] = item.stage
    try? browser.library.save(shown, to: "index/resurfaced.json")
  }
}

/// Settings row for the opt-out.
struct KeptSettingsRow: View {
  @AppStorage(KeptPassages.resurfaceKey) private var enabled = true
  var body: some View {
    Toggle("Bring back kept passages after a day, a week, a month and three months", isOn: $enabled)
  }
}
