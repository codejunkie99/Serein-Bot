import SereinCore

/// Page bookmarks are marks with no quote, kept in the same store as saved pages and passages.
extension BrowserModel {
  var bookmarks: [Mark] { marks.filter { $0.quote.isEmpty }.sorted { $0.date < $1.date } }
  func bookmark(for address: String) -> Mark? {
    marks.first { $0.quote.isEmpty && PageIdentity.key($0.url) == PageIdentity.key(address) }
  }
  func saveMarks() {
    do { try library.save(marks, to: "marks/saved.json") } catch { notice = error.localizedDescription }
  }
  func addBookmark(title: String, url: String) {
    guard bookmark(for: url) == nil else { return }
    marks.insert(Mark(title: title, url: url, quote: ""), at: 0)
    saveMarks()
  }
  func renameBookmark(_ id: String, to title: String) {
    guard let index = marks.firstIndex(where: { $0.id == id }) else { return }
    marks[index].title = title
    saveMarks()
  }
  func removeBookmark(_ id: String) {
    marks.removeAll { $0.id == id }
    saveMarks()
  }
}
