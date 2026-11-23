import SereinCore
import SwiftUI

struct LibraryView: View {
  @StateObject private var recall = LocalRecall()
  @State private var semantic = false
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  let kind: String
  @State var search = ""
  @Environment(\.palette) var p
  var count: Int { kind == "history" ? browser.visits.count : browser.marks.count }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      PageHeader(
        kind == "history" ? "History" : "Saved passages",
        subtitle: kind == "history"
          ? "\(count) visits · a private, searchable history, right here on your Mac."
          : "\(count) \(count == 1 ? "passage or link" : "passages and links") you wanted to come back to.")
      HStack(spacing: 12) {
        HStack(spacing: 8) {
          InterfaceIcon(systemName: "magnifyingglass", size: 13).foregroundStyle(p.faint)
          TextField("Search by title, address, or remembered words", text: $search)
            .textFieldStyle(.plain).textInputCursor().font(UIStyle.body).onSubmit {
              if semantic {
                recall.search(search, visits: browser.visits, library: browser.library.root)
              }
            }
        }.padding(.horizontal, 12).frame(height: 32)
          .background(p.track, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
        if kind == "history" {
          Toggle("By meaning", isOn: $semantic).toggleStyle(SereinSwitchStyle()).font(UIStyle.meta)
            .onChange(of: semantic) { _, value in
              if value && !search.isEmpty {
                recall.search(search, visits: browser.visits, library: browser.library.root)
              }
            }
        }
      }
      if semantic {
        HStack {
          if recall.searching { ProgressView().controlSize(.small) }
          Text(recall.message ?? "On-device English search · Press Return to search by meaning")
            .role(.meta)
        }
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if kind == "history" {
            let filtered =
              semantic && !search.isEmpty
              ? recall.matches
              : browser.visits.filter {
                search.isEmpty
                  || "\($0.title) \($0.url) \($0.textExcerpt)".localizedCaseInsensitiveContains(
                    search)
              }
            if filtered.isEmpty { empty }
            ForEach(filtered.prefix(200)) { v in
              LibraryRow(
                icon: "clock", title: v.title, url: v.url,
                detail: v.date.formatted(date: .abbreviated, time: .shortened)
              ) { browser.openInDefaultBrowser(v.url) }
            }
          } else {
            let filtered = browser.marks.filter {
              search.isEmpty || "\($0.title) \($0.quote)".localizedCaseInsensitiveContains(search)
            }
            if filtered.isEmpty { empty }
            ForEach(filtered) { m in
              LibraryRow(
                icon: "bookmark", title: m.title, url: m.url,
                detail: m.quote.isEmpty ? "Saved link" : m.quote,
                open: { browser.openInDefaultBrowser(m.url) },
                remove: { browser.removeMarkWithUndo(m) })
            }
          }
        }.padding(.horizontal, -10)  // Hover washes bleed into the gutter; text aligns with the title.
      }
    }.pageColumn().foregroundStyle(p.ink).background(p.background)
      // The history list and its search cover every saved day, not only the launch window.
      .task { if kind == "history" { await browser.loadAllVisits() } }
  }
  var empty: some View {
    VStack(alignment: .leading, spacing: 8) {
      InterfaceIcon(systemName: kind == "history" ? "clock" : "bookmark", size: 20)
        .foregroundStyle(p.faint)
      Text(search.isEmpty ? "Nothing here just yet." : "No matching pages.").role(.section)
      Text(
        search.isEmpty
          ? "Text you keep from a page shows up here."
          : "Try a different title, site, or phrase."
      ).role(.meta)
    }.padding(.vertical, 24).frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// One library entry. The whole row opens the page; Open and Remove sit inside the row,
/// vertically centered, and appear on hover (always available to VoiceOver as actions).
struct LibraryRow: View {
  var icon: String
  var title: String
  var url: String
  var detail: String
  var open: () -> Void
  var remove: (() -> Void)? = nil
  @State private var hovered = false
  @Environment(\.palette) var p
  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Button(action: open) {
        HStack(alignment: .top, spacing: 12) {
          InterfaceIcon(systemName: icon, size: 14).foregroundStyle(p.faint).frame(width: 16)
            .padding(.top, 2)
          VStack(alignment: .leading, spacing: 4) {
            Text(title).font(UIStyle.bodyStrong).lineLimit(1)
            Text(detail).role(.meta).lineLimit(2)
            Text(URL(string: url)?.host ?? url).role(.micro).lineLimit(1)
          }
          Spacer(minLength: 0)
        }.contentShape(Rectangle())
      }.buttonStyle(.pressable).help(url).accessibilityLabel("Open \(title)")
      HStack(spacing: 2) {
        Button(action: open) {
          InterfaceIcon(systemName: "arrow.up.right", size: 13).frame(width: 28, height: 28)
        }.buttonStyle(.pressable).foregroundStyle(p.secondary).help("Open").accessibilityHidden(true)
        if let remove {
          Button(action: remove) {
            InterfaceIcon(systemName: "trash", size: 13).frame(width: 28, height: 28)
          }.buttonStyle(.pressable).foregroundStyle(p.secondary).help("Remove from saved")
            .accessibilityLabel("Remove \(title) from saved")
        }
      }.opacity(hovered ? 1 : 0)
    }.padding(.vertical, 12).padding(.horizontal, 10)
      .background(hovered ? p.hover : .clear, in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
      .overlay(alignment: .bottom) { Rectangle().fill(p.line).frame(height: 1).padding(.horizontal, 10) }
      .onHover { hovered = $0 }
  }
}
