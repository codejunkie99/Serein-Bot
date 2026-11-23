import AppKit
import ObjectiveC
import SereinCore
import WebKit

/// Element pointing: ⇧⌘E, or "Send This Element to a Task" in the page's context menu.
@MainActor enum PagePointer {
  static let source: String =
    (Bundle.assets.url(forResource: "PagePoint", withExtension: "js")).flatMap {
      try? String(contentsOf: $0)
    }.map(SensitiveFields.script) ?? ""
  /// The user script for `BrowserTab` (main frame, SereinPageReader world).
  static var userScript: WKUserScript {
    WKUserScript(
      source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: BrowserTab.world)
  }
  /// Loads the picker into a page that started before the user script existed.
  static func ensure(_ tab: BrowserTab) async throws {
    if (try? await tab.script("typeof globalThis.__sereinPoint")) as? String == "object" { return }
    _ = try await tab.script(source + "\n;0")
  }

  /// Starts the picker on the current tab; chosen elements become composer chips.
  static func point(browser: BrowserModel) {
    let context = ComposerContext.shared
    guard browser.section == ShellSection.browser, let tab = browser.active, !tab.sleeping else {
      browser.notice = "Open a page first, then point at part of it."
      return
    }
    guard !tab.privateMode else {
      browser.notice = "Private tabs are never shared with agents."
      return
    }
    if context.pointing {
      cancel(tab)
      return
    }
    let room = PageContext.maxElements - context.elements.count
    guard room > 0 else {
      browser.notice = "Up to \(PageContext.maxElements) elements. Remove one to point again."
      return
    }
    NotificationCenter.default.post(name: Notification.Name("SereinPointStarted"), object: nil)
    tab.web.window?.makeFirstResponder(tab.web)
    context.pointing = true
    Task {
      defer { context.pointing = false }
      do {
        try await ensure(tab)
        let raw = try await tab.web.callAsyncJavaScript(
          "return await globalThis.__sereinPoint.start(max)", arguments: ["max": room], in: nil,
          contentWorld: BrowserTab.world)
        await accept(raw, from: tab, browser: browser)
      } catch {
        browser.notice = "Pointing stopped: the page changed or did not respond."
      }
    }
  }
  static func cancel(_ tab: BrowserTab) {
    // Reset right away, so a page that never answers cannot leave pointing stuck.
    ComposerContext.shared.pointing = false
    Task { _ = try? await tab.script("globalThis.__sereinPoint && globalThis.__sereinPoint.cancel()") }
  }
  /// The element under the last right-click.
  static func pointFromContextMenu(_ tab: BrowserTab, browser: BrowserModel) {
    guard !tab.privateMode else { return }
    guard ComposerContext.shared.elements.count < PageContext.maxElements else {
      browser.notice = "Up to \(PageContext.maxElements) elements. Remove one to point again."
      return
    }
    Task {
      let raw = try? await tab.script("globalThis.__sereinPoint.fromContext()")
      await accept(raw, from: tab, browser: browser)
    }
  }
  /// Decodes the picker result, adds framework source hints and pictures, then opens a composer.
  static func accept(_ raw: Any?, from tab: BrowserTab, browser: BrowserModel) async {
    guard let result = raw as? [String: Any], result["cancelled"] as? Bool == false,
      let picks = result["picks"] as? [[String: Any]], !tab.privateMode
    else { return }
    // Frames are probed too, failing closed: secrets in a frame, a frame that does not answer,
    // or frames Serein could not check make the whole page count as sensitive.
    let framesSensitive = await withTimeout(2) { await tab.hasUserSteps() } ?? true
    let pageSensitive = (result["sensitive"] as? Bool ?? true) || framesSensitive
    let hintScript = (try? await tab.script("globalThis.__sereinPoint.hintScript")) as? String
    var elements: [PageContext.Element] = []
    for pick in picks {
      guard var element = decode(pick) else { continue }
      element.sensitive = element.sensitive || pageSensitive
      if let hintScript {
        // Page-world code: the page can tamper with it, so it gets one second at most.
        let path = element.cssPath
        let hints = await withTimeout(1) { () -> [String] in
          let value = try? await tab.web.callAsyncJavaScript(
            "return (\(hintScript))(path)", arguments: ["path": path], in: nil,
            contentWorld: .page)
          return ((value as? [Any]) ?? []).compactMap { $0 as? String }
        }
        element.sources += (hints ?? []).prefix(3)
      }
      if !element.sensitive { element.picture = await picture(of: element, in: tab) }
      elements.append(PageContext.downgraded(element))
    }
    // The page may have changed while the pictures were taken: check again, and on any change
    // keep only positions and styles.
    if elements.contains(where: { $0.picture != nil }) {
      let mainNow = (try? await tab.script("globalThis.__sereinPoint.sensitive()")) as? Bool ?? true
      let framesNow = await withTimeout(2) { await tab.hasUserSteps() } ?? true
      if mainNow || framesNow {
        for i in elements.indices {
          if let path = elements[i].picture { try? FileManager.default.removeItem(atPath: path) }
          elements[i].sensitive = true
          elements[i] = PageContext.downgraded(elements[i])
        }
      }
    }
    let context = ComposerContext.shared
    guard !tab.privateMode else { return }
    if context.askOpen {
      // The pointed elements join the page thread's composer in the task panel.
      guard let merged = PageContext.adding(elements, to: context.elements) else { return }
      context.elements = merged
      await context.detectDevServer(tab, browser: browser)
      context.wantsComposerFocus = true
      context.focusComposer &+= 1
    } else {
      // Serein's composer gets the pointed part as a chip only (untrusted data, never words).
      // The task composer's context is left alone, so nothing rides along with a later task.
      // Serein cannot read the task's private picture folder, so the pictures are dropped.
      for path in elements.compactMap(\.picture) { try? FileManager.default.removeItem(atPath: path) }
      guard let picked = PageContext.adding(elements, to: []) else { return }
      let shown = picked.map { element -> PageContext.Element in
        var out = element
        out.picture = nil
        return out
      }
      let named = shown.first.map { $0.name.isEmpty ? $0.text : $0.name } ?? ""
      let page = AgentPrivacy.redact(tab.title)
      let title = named.isEmpty
        ? "Part of “\(TabText.clip(page.isEmpty ? "this page" : page, 40))”"
        : "“\(TabText.clip(AgentPrivacy.redact(named), 40))”"
      let body = shown.enumerated().map { PageContext.render($1, index: $0 + 1) }.joined(separator: "\n")
      SereinRouter.show(attach: SereinAttachment(title: title, icon: "cursorarrow.rays", body: body))
    }
  }
  static func decode(_ pick: [String: Any]) -> PageContext.Element? {
    var object = pick
    object["id"] = UUID().uuidString
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(withJSONObject: object),
      let element = try? JSONDecoder().decode(PageContext.Element.self, from: data)
    else { return nil }
    var out = element
    out.text = AgentPrivacy.redact(out.text, limit: PageContext.elementTextLimit)
    out.sources = Array(out.sources.prefix(3))
    out.picture = nil
    return out
  }
  /// A PNG of the element's visible area via `takeSnapshot`.
  static func picture(of element: PageContext.Element, in tab: BrowserTab) async -> String? {
    let web = tab.web
    let zoom = web.pageZoom * web.magnification
    let r = element.rect
    let rect = CGRect(x: r.x * zoom, y: r.y * zoom, width: r.width * zoom, height: r.height * zoom)
      .insetBy(dx: -4, dy: -4).intersection(web.bounds)
    guard !rect.isNull, rect.width >= 4, rect.height >= 4 else { return nil }
    let config = WKSnapshotConfiguration()
    config.rect = rect
    config.afterScreenUpdates = true
    if rect.width > 1200 { config.snapshotWidth = 1200 }
    guard let image = try? await web.takeSnapshot(configuration: config),
      let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]), png.count < 3_000_000,
      let url = try? ComposerContext.attachmentURL(name: "element")
    else { return nil }
    do {
      try png.write(to: url, options: .atomic)
      return url.path
    } catch { return nil }
  }

  // MARK: Page context menu

  private static var installed = false
  /// Adds "Send This Element to a Task" to the context menu of regular tabs in the main window.
  static func installContextMenu() {
    guard !installed else { return }
    installed = true
    let selector = #selector(NSView.willOpenMenu(_:with:))
    guard let method = class_getInstanceMethod(WKWebView.self, selector) else { return }
    typealias Original = @convention(c) (AnyObject, Selector, NSMenu, NSEvent) -> Void
    let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
    let block: @convention(block) (AnyObject, NSMenu, NSEvent) -> Void = { view, menu, event in
      original(view, selector, menu, event)
      if let web = view as? WKWebView { MainActor.assumeIsolated { decorate(menu, web: web) } }
    }
    let replacement = imp_implementationWithBlock(block)
    // Add an override on WKWebView itself when it only inherits NSView's method.
    if !class_addMethod(WKWebView.self, selector, replacement, method_getTypeEncoding(method)) {
      method_setImplementation(method, replacement)
    }
  }
  static func decorate(_ menu: NSMenu, web: WKWebView) {
    guard let browser = BrowserContext.browser,
      let tab = browser.tabs.first(where: { $0.web === web }), !tab.privateMode, tab.owner == nil
    else { return }
    let item = NSMenuItem(
      title: "Send This Element to a Task", action: #selector(MenuTarget.sendElement(_:)),
      keyEquivalent: "")
    item.target = MenuTarget.shared
    item.representedObject = web
    let ask = NSMenuItem(
      title: "Ask Serein About This Page", action: #selector(MenuTarget.askPage(_:)), keyEquivalent: "")
    ask.target = MenuTarget.shared
    ask.representedObject = web
    menu.insertItem(.separator(), at: 0)
    menu.insertItem(ask, at: 0)
    menu.insertItem(item, at: 0)
  }
  final class MenuTarget: NSObject {
    static let shared = MenuTarget()
    @objc func sendElement(_ item: NSMenuItem) {
      MainActor.assumeIsolated {
        guard let web = item.representedObject as? WKWebView, let browser = BrowserContext.browser,
          let tab = browser.tabs.first(where: { $0.web === web })
        else { return }
        PagePointer.pointFromContextMenu(tab, browser: browser)
      }
    }
    @objc func askPage(_ item: NSMenuItem) {
      MainActor.assumeIsolated {
        guard let browser = BrowserContext.browser else { return }
        ComposerContext.shared.openAsk(browser: browser)
      }
    }
  }
}

extension AppDelegate {
}
