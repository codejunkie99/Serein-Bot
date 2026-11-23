import SereinCore
import SwiftUI
import WebKit

@MainActor final class DownloadCenter: NSObject, ObservableObject, WKDownloadDelegate {
  static let shared = DownloadCenter()
  enum State { case choosing, downloading, complete, failed, cancelled }
  struct Item: Identifiable {
    var id: UUID
    var name: String
    var url: URL?
    var state: State = .choosing
    var detail: String?
    var progress: Double = 0
    var received: Int64 = 0
    var total: Int64 = 0
    var download: WKDownload?
    var resumeData: Data?
    var resuming = false
    weak var web: WKWebView?
    /// The website data store of the tab that started it. A resume uses only this store, so a
    /// private download never continues with normal cookies, or the other way round.
    weak var store: WKWebsiteDataStore?
    var isPrivate = false
    /// When the download began, for "Clear browsing data" time ranges.
    var startedAt = Date()
    var status: String {
      switch state {
      case .choosing: return "Choosing destination…"
      case .downloading:
        let done = Bytes.file(received)
        if total > 0 {
          return "\(Int(progress * 100))% · \(done) of \(Bytes.file(total))"
        }
        return done
      case .complete: return "Complete"
      case .failed: return detail ?? "Stopped"
      case .cancelled: return "Cancelled"
      }
    }
    var canResume: Bool { state == .failed && resumeData != nil }
  }
  @Published var items: [Item] = []
  private var ids: [ObjectIdentifier: UUID] = [:]
  private var observations: [UUID: NSKeyValueObservation] = [:]
  /// When each download last published its progress. WebKit reports every chunk it receives;
  /// the toolbar shows a percent, so ten updates a second are enough.
  private var progressShown: [UUID: Date] = [:]
  var activeCount: Int { items.filter { $0.state == .downloading || $0.state == .choosing }.count }
  func accept(_ download: WKDownload) {
    let id = UUID()
    var item = Item(id: id, name: "Download", download: download)
    item.web = download.webView
    item.store = download.webView?.configuration.websiteDataStore
    item.isPrivate = download.webView?.configuration.websiteDataStore.isPersistent == false
    items.insert(item, at: 0)
    bind(download, to: id)
  }
  private func bind(_ download: WKDownload, to id: UUID) {
    ids[ObjectIdentifier(download)] = id
    download.delegate = self
    observations[id] = download.progress.observe(\.fractionCompleted, options: [.new]) {
      [weak self] progress, _ in
      let fraction = progress.fractionCompleted
      let done = progress.completedUnitCount
      let total = progress.totalUnitCount
      Task { @MainActor in
        guard let self else { return }
        let now = Date()
        if fraction < 1, let shown = self.progressShown[id], now.timeIntervalSince(shown) < 0.1 { return }
        guard let i = self.items.firstIndex(where: { $0.id == id }),
          self.items[i].state == .downloading
        else { return }
        self.progressShown[id] = now
        self.items[i].progress = fraction
        self.items[i].received = done
        self.items[i].total = max(total, 0)
      }
    }
  }
  func download(
    _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
    completionHandler: @escaping (URL?) -> Void
  ) {
    guard let id = ids[ObjectIdentifier(download)],
      let index = items.firstIndex(where: { $0.id == id })
    else {
      completionHandler(nil)
      return
    }
    // A resumed download goes back to the file it was writing.
    if items[index].resuming, let url = items[index].url {
      items[index].resuming = false
      items[index].state = .downloading
      completionHandler(url)
      return
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = URL(fileURLWithPath: suggestedFilename).lastPathComponent
    panel.begin { result in
      Task { @MainActor in
        guard let id = self.ids[ObjectIdentifier(download)],
          let index = self.items.firstIndex(where: { $0.id == id })
        else {
          completionHandler(nil)
          return
        }
        if result == .OK, let url = panel.url {
          self.items[index].name = url.lastPathComponent
          self.items[index].url = url
          self.items[index].state = .downloading
          completionHandler(url)
        } else {
          self.items[index].state = .cancelled
          self.items[index].download = nil
          completionHandler(nil)
        }
      }
    }
  }
  func downloadDidFinish(_ download: WKDownload) { finish(download, state: .complete) }
  func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
    finish(download, state: .failed, detail: error.localizedDescription, resumeData: resumeData)
  }
  private func finish(
    _ download: WKDownload, state: State, detail: String? = nil, resumeData: Data? = nil
  ) {
    guard let id = ids.removeValue(forKey: ObjectIdentifier(download)) else { return }
    observations.removeValue(forKey: id)
    progressShown.removeValue(forKey: id)
    helpers.removeValue(forKey: id)
    guard let i = items.firstIndex(where: { $0.id == id }) else { return }
    items[i].state = state
    items[i].detail = detail
    items[i].resumeData = resumeData
    items[i].download = nil
    if state == .complete { items[i].progress = 1 }
  }
  func cancel(_ id: UUID) {
    guard let item = items.first(where: { $0.id == id }), let download = item.download else {
      return
    }
    download.cancel { _ in }
    finish(download, state: .cancelled)
  }
  /// Cancels everything still running; used when the person quits anyway.
  func cancelAll() {
    for item in items where item.download != nil { cancel(item.id) }
  }
  /// Continues a stopped download from the data WebKit kept, into the same file, in a web view
  /// that uses the same website data store as the tab that started it. When that store is gone
  /// (a private window was closed), the download can't continue and says so.
  func resume(_ id: UUID, in web: WKWebView?) {
    guard let i = items.firstIndex(where: { $0.id == id }), let data = items[i].resumeData else {
      return
    }
    guard let store = items[i].store else {
      items[i].detail =
        items[i].isPrivate
        ? "This download started in a private window that is now closed, so it can't continue."
        : "The window this download started in is closed, so it can't continue."
      items[i].resumeData = nil
      return
    }
    let candidates =
      [web, items[i].web].compactMap { $0 }
      + NSApp.windows.flatMap { $0.contentView?.webViews ?? [] }
    let host: WKWebView
    if let match = candidates.first(where: { $0.configuration.websiteDataStore === store }) {
      host = match
    } else {
      // No tab uses that store any more; a hidden web view with the same store carries it.
      let config = WKWebViewConfiguration()
      config.websiteDataStore = store
      config.applicationNameForUserAgent = BrowserTab.safariAgentSuffix
      host = WKWebView(frame: .zero, configuration: config)
      helpers[id] = host
    }
    items[i].resumeData = nil
    items[i].resuming = true
    items[i].state = .downloading
    items[i].detail = nil
    host.resumeDownload(fromResumeData: data) { [weak self] download in
      // WebKit calls back on the main thread; bind before any delegate event can arrive.
      MainActor.assumeIsolated {
        guard let self, let i = self.items.firstIndex(where: { $0.id == id }) else { return }
        self.items[i].download = download
        self.bind(download, to: id)
      }
    }
  }
  /// Hidden web views that carry a resumed download whose tab is gone.
  private var helpers: [UUID: WKWebView] = [:]
  func clearFinished() { items.removeAll { $0.download == nil && $0.state != .downloading } }
  /// A file the person kept from a task's shelf (TaskShelf.keep), listed like a finished download.
  func kept(_ url: URL) {
    items.insert(Item(id: UUID(), name: url.lastPathComponent, url: url, state: .complete, progress: 1), at: 0)
  }
}
extension NSView {
  fileprivate var webViews: [WKWebView] {
    if let web = self as? WKWebView { return [web] }
    return subviews.flatMap(\.webViews)
  }
}
struct DownloadsView: View {
  @StateObject private var downloads = DownloadCenter.shared
  @Environment(\.palette) var p
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if downloads.items.isEmpty {
        Text("No downloads this session.").font(UIStyle.font(12)).foregroundStyle(p.secondary)
      }
      ForEach(downloads.items) { item in
        HStack(spacing: 12) {
          Image(systemName: "arrow.down.document").font(UIStyle.reading).foregroundStyle(p.faint)
            .frame(width: 16).accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 4) {
            Text(item.name).font(UIStyle.body).lineLimit(1).truncationMode(.tail)
            if item.state == .downloading, item.total > 0 {
              ProgressView(value: item.progress).progressViewStyle(.linear).tint(p.accent)
                .accessibilityLabel("Download progress")
            }
            Text(item.status).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(2)
          }
          Spacer()
          if item.download != nil {
            Button("Cancel") { downloads.cancel(item.id) }
          } else if item.canResume {
            Button("Resume") { downloads.resume(item.id, in: nil) }
          }
          if let url = item.url, item.state == .complete || item.canResume {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
          }
        }.padding(.vertical, 12).overlay(alignment: .bottom) {
          Rectangle().fill(p.line).frame(height: 1)
        }
      }
      if downloads.items.contains(where: { $0.download == nil && $0.state != .downloading }) {
        Button("Clear list") { downloads.clearFinished() }.padding(.top, 10)
      }
    }.foregroundStyle(p.ink).buttonStyle(QuietButton()).controlSize(.small)
  }
}

enum HistoryImporter {
  static func read(_ url: URL) throws -> [Visit] {
    try BrowserDataReader.history(url).0
  }
}
extension BrowserModel {
  func importHistory() {
    let panel = NSOpenPanel()
    panel.message =
      "Choose a Chromium History, Firefox places.sqlite, or Safari History.db file. Serein reads it without changing it."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      do {
        let imported = try await Task.detached { try HistoryImporter.read(url) }.value
        let existing = Set(visits.map { $0.url + "|" + String(Int($0.date.timeIntervalSince1970)) })
        let fresh = imported.filter {
          !existing.contains($0.url + "|" + String(Int($0.date.timeIntervalSince1970)))
        }
        for visit in fresh {
          try library.append(visit, to: "history/\(Self.dayKey(visit.date)).jsonl")
        }
        visits = (visits + fresh).sorted { $0.date > $1.date }
        notice = "Imported \(fresh.count) visits."
      } catch { notice = error.localizedDescription }
    }
  }
}

extension BrowserModel {
  func importCookies() {
    let panel = NSOpenPanel()
    panel.message =
      "Choose a Netscape cookies.txt export. This imports website sign-ins for pages you open in Serein."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let bytes = try Data(contentsOf: url)
      guard bytes.count < 10_000_000 else {
        throw SereinError.invalid("Cookie export must be smaller than 10 MB")
      }
      let text = String(decoding: bytes, as: UTF8.self)
      var cookies: [HTTPCookie] = []
      for raw in text.split(separator: "\n") {
        var line = String(raw).trimmingCharacters(in: .newlines)
        var httpOnly = false
        if line.hasPrefix("#HttpOnly_") {
          httpOnly = true
          line = String(line.dropFirst(10))
        }
        if line.hasPrefix("#") { continue }
        let fields = line.components(separatedBy: "\t")
        guard fields.count == 7 else { continue }
        let domain = fields[0]
        guard domain.range(of: "^\\.?[a-zA-Z0-9.-]+$", options: .regularExpression) != nil,
          !fields[5].isEmpty, fields[2].hasPrefix("/"), let expires = TimeInterval(fields[4]),
          expires.isFinite
        else { continue }
        var props: [HTTPCookiePropertyKey: Any] = [
          .domain: domain, .path: fields[2], .secure: fields[3] == "TRUE" ? "TRUE" : "FALSE",
          .name: fields[5], .value: fields[6],
        ]
        if expires > 0 { props[.expires] = Date(timeIntervalSince1970: expires) }
        if httpOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let cookie = HTTPCookie(properties: props) { cookies.append(cookie) }
      }
      guard !cookies.isEmpty else {
        throw SereinError.invalid("No valid Netscape-format cookies found")
      }
      let alert = NSAlert()
      alert.messageText = "Import \(cookies.count) website cookies?"
      alert.informativeText =
        "This may sign you in or replace existing site sessions in Serein. Import only an export you trust. The source file is unchanged."
      alert.addButton(withTitle: "Import sign-ins")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
      Task {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in cookies { await store.setCookie(cookie) }
        notice = "Imported \(cookies.count) cookies into regular tabs."
      }
    } catch { notice = error.localizedDescription }
  }
}
