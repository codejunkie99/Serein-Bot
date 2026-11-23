import SereinCore
import SwiftUI
import WebKit

extension BrowserTab {
  func beginFind() {
    ext.findVisible = true
    ext.findFocus += 1
  }

  func closeFind() {
    ext.findVisible = false
    ext.findCount = 0
    ext.findIndex = 0
    ext.findMatched = false
    Task { _ = try? await script("getSelection().removeAllRanges()") }
  }
  /// Searches for the current query. `fresh` is true when the text changed.
  func runFind(forward: Bool = true, fresh: Bool = false) async {
    let query = ext.findQuery
    guard !query.isEmpty else {
      ext.findCount = 0
      ext.findIndex = 0
      ext.findMatched = false
      return
    }
    let config = WKFindConfiguration()
    config.backwards = !forward
    config.caseSensitive = false
    config.wraps = true
    let found = (try? await web.find(query, configuration: config))?.matchFound ?? false
    guard query == ext.findQuery else { return }
    ext.findMatched = found
    if fresh {
      let script = """
        ((q)=>{const t=(document.body?document.body.innerText:'').toLowerCase();q=q.toLowerCase();let n=0,i=0;while(q&&(i=t.indexOf(q,i))>=0){n++;i+=q.length}return n})(\(jsonString(query)))
        """
      ext.findCount = (try? await self.script(script)) as? Int ?? 0
      ext.findIndex = found && ext.findCount > 0 ? 1 : 0
    } else if found, ext.findCount > 0 {
      let next = ext.findIndex + (forward ? 1 : -1)
      ext.findIndex = next > ext.findCount ? 1 : next < 1 ? ext.findCount : next
    }
  }
}

struct FindBar: View {
  @ObservedObject var tab: BrowserTab
  @ObservedObject var ext: TabExtras
  @FocusState private var focused: Bool
  @Environment(\.palette) var p
  var summary: String {
    if ext.findQuery.isEmpty { return "" }
    // WebKit's own result decides whether anything matched; the page-text count is only a guide.
    if !ext.findMatched { return "No matches" }
    return ext.findCount == 0 ? "Found" : "\(min(max(ext.findIndex, 1), ext.findCount)) of \(ext.findCount)"
  }
  var body: some View {
    HStack(spacing: 8) {
      InterfaceIcon(systemName: "magnifyingglass", size: 13).foregroundStyle(p.secondary)
      TextField("Find in page", text: $ext.findQuery).textFieldStyle(.plain).textInputCursor().font(
        UIStyle.meta
      ).frame(width: 200).focused($focused).onSubmit { Task { await tab.runFind() } }
        .onExitCommand { tab.closeFind() }
      Text(summary).font(UIStyle.microMono).foregroundStyle(p.secondary).frame(minWidth: 62)
      Button {
        Task { await tab.runFind(forward: false) }
      } label: {
        InterfaceIcon(systemName: "chevron.up", size: 13)
      }.buttonStyle(QuietButton()).disabled(!ext.findMatched).help("Previous match (⇧⌘G)")
        .accessibilityLabel("Previous match")
      Button {
        Task { await tab.runFind() }
      } label: {
        InterfaceIcon(systemName: "chevron.down", size: 13)
      }.buttonStyle(QuietButton()).disabled(!ext.findMatched).help("Next match (⌘G)")
        .accessibilityLabel("Next match")
      Button {
        tab.closeFind()
      } label: {
        InterfaceIcon(systemName: "xmark", size: 12)
      }.buttonStyle(QuietButton()).help("Close").accessibilityLabel("Close find")
    }.padding(.horizontal, 10).padding(.vertical, 6).darkGlass(UIStyle.panelRadius)
      .shadow(color: p.shadow(0.28), radius: 16, y: 8)
      .onAppear { focused = true }
      .onChange(of: ext.findFocus) { _, _ in focused = true }
      .onChange(of: ext.findQuery) { _, _ in Task { await tab.runFind(fresh: true) } }
  }
}
