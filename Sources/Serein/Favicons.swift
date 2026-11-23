import AppKit
import SereinCore
import SwiftUI
import WebKit

/// Site icons for tab rows, omnibox rows and agent tab rows (`SiteIconPlan` in SereinCore sets
/// the order). When a navigation starts, the cached icon for the site shows at once; without one,
/// `/favicon.ico` and `/apple-touch-icon.png` are requested in parallel with the page. When the
/// page finishes, its `<link rel=icon>` list is read in Serein's isolated content world and the
/// declared icon replaces the guess. Every fetch uses an ephemeral session that sends and keeps no
/// cookies, skips hosts content blocking blocks, and scales the file to 32×32. Icons are cached
/// per site under Library/Caches (a week until refetched, a month until deleted, 4 MB at most).
/// Private tabs never trigger a fetch or a cache write and always draw the generic globe;
/// isolated agent tabs may show an icon that is already cached, but never fetch one.
@MainActor final class FaviconStore: ObservableObject {
  static let shared = FaviconStore()
  /// Decoded icons by cache key (`SiteIconPlan.cacheKey`).
  @Published private(set) var icons: [String: NSImage] = [:]
  /// Where each showing icon came from, so a late probe never replaces a declared icon.
  private var sources: [String: SiteIconPlan.Source] = [:]
  private var missing: Set<String> = []
  private var probing: Set<String> = []
  private var declaring: Set<String> = []
  /// A cached icon is refreshed after a week.
  static let maxAge = SiteIconPlan.maxAge

  /// Caches/Serein/Favicons, or a folder inside a test or preview library so checks never touch
  /// the user's caches.
  let folder: URL = {
    if let data = ProcessInfo.processInfo.environment["SEREIN_DATA_DIR"], data.hasPrefix("/") {
      return URL(fileURLWithPath: data).appendingPathComponent("caches/favicons", isDirectory: true)
    }
    return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Serein/Favicons", isDirectory: true)
  }()

  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCache = nil
    config.urlCredentialStorage = nil
    config.timeoutIntervalForRequest = 8
    config.timeoutIntervalForResource = 12
    config.httpAdditionalHeaders = ["Accept": "image/*"]
    return URLSession(configuration: config)
  }()

  /// User-private tabs always show the globe.
  static func isPrivate(_ tab: BrowserTab) -> Bool {
    tab.privateMode && tab.owner == nil && tab.takenFrom == nil
  }
  /// Only regular, user-owned tabs fetch icons; previews never reach the network.
  static func mayFetch(_ tab: BrowserTab) -> Bool {
    !CommandLine.arguments.contains("--ui-preview") && !tab.privateMode && tab.owner == nil
      && !tab.isSourceView
  }
  private func file(_ key: String) -> URL { folder.appendingPathComponent(key + ".png") }
  /// Marks when the page's declared icon was last fetched for a site.
  private func marker(_ key: String) -> URL { folder.appendingPathComponent(key + ".declared") }
  private func age(_ url: URL) -> TimeInterval? {
    guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
      as? Date
    else { return nil }
    return Date().timeIntervalSince(modified)
  }
  func cacheState(_ key: String) -> SiteIconPlan.CacheState {
    guard let age = age(file(key)) else { return icons[key] == nil ? .missing : .fresh }
    return age < Self.maxAge ? .fresh : .stale
  }

  /// The icon to draw, from memory or the disk cache. Never fetches.
  func icon(for tab: BrowserTab) -> NSImage? {
    icon(address: tab.address, privateTab: Self.isPrivate(tab))
  }
  /// The cached icon for an address (omnibox and history rows). Never fetches.
  func icon(address: String, privateTab: Bool) -> NSImage? {
    guard !privateTab, let key = SiteIconPlan.cacheKey(address: address) else { return nil }
    if let image = icons[key] { return image }
    if missing.contains(key) { return nil }
    guard let image = NSImage(contentsOf: file(key)) else {
      missing.insert(key)
      return nil
    }
    // Published on the next turn: this runs while a view body is being computed.
    DispatchQueue.main.async {
      if self.icons[key] == nil {
        self.icons[key] = image
        self.sources[key] = .cached
      }
    }
    return image
  }

  /// Called when a navigation starts (`didStartProvisionalNavigation`), before the page loads.
  func navigationStarted(_ tab: BrowserTab, url: URL?) {
    guard let page = url, let key = SiteIconPlan.cacheKey(for: page) else { return }
    let plan = SiteIconPlan.onStart(
      page: page, privateTab: Self.isPrivate(tab), mayFetch: Self.mayFetch(tab),
      cache: cacheState(key), blocked: ContentBlocking.shared.blocksIcons(host: page.host ?? ""))
    if plan.showCached { _ = icon(address: page.absoluteString, privateTab: false) }
    guard !plan.probe.isEmpty, !probing.contains(key) else { return }
    probing.insert(key)
    let urls = plan.probe
    Task {
      defer { probing.remove(key) }
      // Both conventional locations at once; the first in preference order that decodes wins.
      async let first = fetch(urls[0])
      async let second = urls.count > 1 ? fetch(urls[1]) : nil
      let results = await [first, second]
      // A private-equivalent tab never writes the cache, even if it changed mid-flight.
      guard Self.mayFetch(tab), let png = results.compactMap({ $0 }).first else { return }
      store(png, key: key, source: .probe)
    }
  }

  /// Called when a page finishes loading in a regular (non-private, user-owned) tab: the page's
  /// declared icon replaces the guess, at most once a week per site.
  func refresh(_ tab: BrowserTab) async {
    guard Self.mayFetch(tab), let page = URL(string: tab.address),
      let key = SiteIconPlan.cacheKey(for: page), !declaring.contains(key)
    else { return }
    if let age = age(marker(key)), age < Self.maxAge, cacheState(key) == .fresh {
      if icons[key] == nil { _ = icon(address: page.absoluteString, privateTab: false) }
      return
    }
    guard !ContentBlocking.shared.blocksIcons(host: page.host ?? "") else { return }
    declaring.insert(key)
    defer { declaring.remove(key) }
    let source = """
      Array.from(document.querySelectorAll('link[rel]')).slice(0, 40).map(l => ({
        href: String(l.href || ''), rel: String(l.rel || ''),
        sizes: String(l.getAttribute('sizes') || ''), type: String(l.type || '') }))
      """
    let raw = (try? await tab.script(source)) as? [[String: Any]] ?? []
    let candidates = raw.map {
      FaviconChoice.Candidate(href: $0["href"] as? String ?? "", rel: $0["rel"] as? String ?? "",
        sizes: $0["sizes"] as? String ?? "", type: $0["type"] as? String ?? "")
    }
    // The tab may have moved on or become private-equivalent while the script ran.
    guard SiteIconPlan.cacheKey(address: tab.address) == key, Self.mayFetch(tab),
      let target = FaviconChoice.best(candidates, page: page)
    else { return }
    let declared = target.path != "/favicon.ico"
    var urls: [URL] = []
    if declared {
      urls.append(target)
      if icons[key] == nil, let fallback = FaviconChoice.best([], page: page) { urls.append(fallback) }
    } else if icons[key] == nil {
      // No declared icon and the probe found nothing yet: try /favicon.ico once more.
      urls.append(target)
    }
    for url in urls {
      // A declared icon may live on another host; blocking applies to that host too.
      guard !ContentBlocking.shared.blocksIcons(host: url.host ?? "") else { continue }
      if let png = await fetch(url) {
        store(png, key: key, source: declared && url == target ? .declared : .probe)
        break
      }
    }
    touch(marker(key))
  }

  /// Writes an icon to memory and disk and trims the cache.
  private func store(_ png: Data, key: String, source: SiteIconPlan.Source) {
    guard let image = NSImage(data: png), SiteIconPlan.replaces(sources[key] ?? .none, with: source)
    else { return }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try? png.write(to: file(key), options: .atomic)
    icons[key] = image
    sources[key] = source
    missing.remove(key)
    trim()
  }
  private func touch(_ url: URL) {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    if FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    } else {
      FileManager.default.createFile(atPath: url.path, contents: Data())
    }
  }
  private var lastTrim = Date.distantPast
  /// Deletes expired icons, then the oldest, so the folder stays within its caps.
  private func trim() {
    guard Date().timeIntervalSince(lastTrim) > 60 else { return }
    lastTrim = Date()
    let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: keys)
    else { return }
    let entries = files.compactMap { url -> SiteIconPlan.CacheEntry? in
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
      return SiteIconPlan.CacheEntry(
        name: url.lastPathComponent, bytes: values.fileSize ?? 0,
        modified: values.contentModificationDate ?? .distantPast)
    }
    for name in SiteIconPlan.prune(entries, now: Date()) {
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
      if name.hasSuffix(".png") {
        let key = String(name.dropLast(4))
        icons[key] = nil
        sources[key] = nil
      }
    }
  }
  /// Drops one site's icon from memory and disk (checks start from a known state).
  func forget(key: String) {
    icons[key] = nil
    sources[key] = nil
    missing.remove(key)
    try? FileManager.default.removeItem(at: file(key))
    try? FileManager.default.removeItem(at: marker(key))
  }

  /// Downloads one icon without cookies and returns it as a 32×32 PNG, or nil.
  private func fetch(_ url: URL) async -> Data? {
    guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
    var request = URLRequest(url: url)
    request.httpShouldHandleCookies = false
    guard let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      data.count > 0, data.count <= FaviconChoice.maxBytes,
      let image = NSImage(data: data), image.size.width > 0, image.size.height > 0
    else { return nil }
    let side = Int(FaviconChoice.target)
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    rep.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero,
      operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
  }

  /// Synthetic previews draw a lettered tile instead of fetching anything.
  func seedPreview(host: String, letter: String, color: NSColor) {
    let side: CGFloat = 32
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
      color.setFill()
      NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
      let text = NSAttributedString(string: letter, attributes: [
        .font: NSFont.systemFont(ofSize: 19, weight: .bold), .foregroundColor: NSColor.white,
      ])
      let size = text.size()
      text.draw(at: NSPoint(x: (side - size.width) / 2, y: (side - size.height) / 2))
      return true
    }
    let key = host.lowercased()
    icons[key] = image
    sources[key] = .declared
  }
}

/// A tab's site icon at 16 points, or the generic globe.
struct SiteIcon: View {
  @ObservedObject var tab: BrowserTab
  var size: CGFloat = 16
  var body: some View {
    SiteIconImage(address: tab.address, privateTab: FaviconStore.isPrivate(tab), size: size)
  }
}

/// The cached site icon for an address, or `fallback` (the globe by default). Never fetches.
struct SiteIconImage: View {
  var address: String
  var privateTab = false
  var size: CGFloat = 16
  var fallback = "globe"
  @ObservedObject private var store = FaviconStore.shared
  @Environment(\.palette) var p
  var body: some View {
    if let image = store.icon(address: address, privateTab: privateTab) {
      Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 3.5))
        .accessibilityHidden(true)
    } else {
      InterfaceIcon(systemName: fallback, size: size - 2)
        .foregroundStyle(p.secondary).frame(width: size, height: size)
        .accessibilityHidden(true)
    }
  }
}
