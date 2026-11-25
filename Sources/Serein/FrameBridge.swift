import Foundation
import SereinCore
import WebKit

/// Page-world messages. Navigation notices only. A frame id posted here is ignored, so a page
/// cannot write `tab.frames`.
@MainActor final class PageNavBridge: NSObject, WKScriptMessageHandler {
  weak var tab: BrowserTab?
  init(tab: BrowserTab) { self.tab = tab }
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard let tab, message.world.name == nil else { return }
    guard let body = message.body as? String, let reason = RouteNote.reason(body: body) else { return }
    let origin = message.frameInfo.securityOrigin
    let page = tab.web.url
    let blank = !message.frameInfo.isMainFrame && RouteNote.blankChild(scheme: origin.protocol)
    guard RouteNote.allowed(
      mainFrame: message.frameInfo.isMainFrame,
      frameScheme: origin.protocol, frameHost: origin.host, framePort: origin.port,
      pageScheme: page?.scheme ?? "", pageHost: page?.host ?? "", pagePort: page?.port ?? 0)
      || blank
    else { return }
    // A blank child stales the yes and does not replace the frame the reader is bound to.
    tab.noteFrameChange(
      message.frameInfo, because: reason, url: message.frameInfo.request.url?.absoluteString ?? "",
      blankChild: blank && FrameBump.keepsReaderFrame(blankChild: true))
  }
}

@MainActor final class FrameBridge: NSObject, WKScriptMessageHandler {
  weak var tab: BrowserTab?
  init(tab: BrowserTab) { self.tab = tab }
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard let tab else { return }
    // Frame ids and any route note on this name come from the page-reader world only.
    // The page world has its own handler and cannot land here.
    guard message.world.name == BrowserTab.world.name else { return }
    // A Shift-hovered link, posted by PageKit: Serein previews it in a split's other pane.
    // Only http and https, and only after the world check, so a page cannot post this itself.
    if let body = message.body as? String, body.hasPrefix("preview:"), body.count <= 2_048,
      let url = URL(string: String(body.dropFirst("preview:".count))),
      let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme)
    {
      tab.onPreviewLink?(url)
      return
    }
    // A step the person took in a tab they record (Show me once). After the world check, so a
    // page cannot post one; only the top document records, so a frame's page cannot add steps.
    if let body = message.body as? String, body.hasPrefix("step:") {
      if message.frameInfo.isMainFrame, body.count <= 4_096 { tab.onUserStep?(String(body.dropFirst("step:".count))) }
      return
    }
    // pushState, replaceState, and hash changes. A frame id is never this word.
    // A cross-origin frame cannot advance the page the person is looking at.
    if let body = message.body as? String, let reason = RouteNote.reason(body: body) {
      let origin = message.frameInfo.securityOrigin
      let page = tab.web.url
      let blank = !message.frameInfo.isMainFrame && RouteNote.blankChild(scheme: origin.protocol)
      guard RouteNote.allowed(
        mainFrame: message.frameInfo.isMainFrame,
        frameScheme: origin.protocol, frameHost: origin.host, framePort: origin.port,
        pageScheme: page?.scheme ?? "", pageHost: page?.host ?? "", pagePort: page?.port ?? 0)
        || blank
      else { return }
      tab.noteFrameChange(
        message.frameInfo, because: reason, url: message.frameInfo.request.url?.absoluteString ?? "",
        blankChild: blank && FrameBump.keepsReaderFrame(blankChild: true))
      return
    }
    guard let id = message.body as? String, id.count <= 100,
      id.range(of: "^[a-f0-9-]+$", options: .regularExpression) != nil,
      let url = message.frameInfo.request.url,
      (try? BrowserPolicy.url(url.absoluteString)) != nil
    else { return }
    // A page with very many frames cannot wipe the registry; extra frames stay unregistered,
    // and unregistered frames make the page count as sensitive (`hasUserSteps`).
    if tab.frames.count >= 256 && tab.frames[id] == nil { return }
    // Re-registration on page reads replaces obsolete frame handles.
    tab.frames[id] = message.frameInfo
  }
}
/// A human-verification check (a CAPTCHA) on a task's page. Serein never answers one and asks no
/// service about it: the takeover card opens on its own (`BrowserModel.botCheck`), the person
/// finishes the check and hands the tab back, and the task carries on meanwhile.
struct VerificationCheck: LocalizedError {
  /// The site the person is on, not the check provider's.
  let host: String
  var message: String { Boundary.botCheck.blocked.text }
  var errorDescription: String? { message }
  /// What the agent gets instead of the action.
  func result(tab: String) -> [String: Any] {
    ["reason": "captcha", "message": message, "tab": tab]
  }
  /// A read of a page with an inline check (a widget in a form): the rest of the page stays the agent's.
  static let inlineNote = "This page shows a verification check. Go on with the rest of the page and leave the "
    + "check alone: it is the user's, and no action inside it goes through. If the task cannot go on until it "
    + "is done, open a takeover card for this tab with ask_person_takeover and keep working on the rest."
}

extension BrowserModel {
  /// Asks, classifies, and presses. If the effect changed between the yes and the press,
  /// the yes is thrown out and the person is asked again. That retry happens once.
  func runWebAction(
    name: String, arguments: [String: Any], tab: BrowserTab, taskID: String,
    admitted: ApprovalGate.ActionIntent? = nil, allowed: @escaping () -> Bool
  ) async throws -> Any {
    let binding = try await admitWebAction(
      name: name, arguments: arguments, tab: tab, taskID: taskID, admitted: admitted)
    do {
      return try await tab.frameAction(name: name, arguments: arguments, allowed: allowed, binding: binding)
    } catch {
      guard (error as? SereinError)?.errorDescription == ActionAdmission.effectChanged else { throw error }
      let again = try await admitWebAction(
        name: name, arguments: arguments, tab: tab, taskID: taskID, admitted: nil)
      return try await tab.frameAction(name: name, arguments: arguments, allowed: allowed, binding: again)
    }
  }

  /// A bot check on a task's tab: the takeover card opens for the person (once per tab), and the
  /// model gets the botCheck Blocked line as a normal result.
  func botCheck(_ check: VerificationCheck, tab id: String, task: String) -> [String: Any] {
    if let tab = tasks[task]?.tabs.first(where: { $0.id == id }) {
      _ = askPersonTakeover(tab, task: task, reason: "This page checks that a person is there.")
    }
    return check.result(tab: id)
  }
}

extension BrowserTab {
  var verificationHost: String { web.url?.host ?? URL(string: address)?.host ?? "this site" }
  /// The check that stops this action (PageKit `challenge` with `blocks`): an interstitial or a
  /// check covering the page, or the action's target inside a check. The main document is asked,
  /// and so is the document the ref points into, so a press inside a check's own frame is caught
  /// while the page around it shows only an inline check. With `anyShown` every visible check
  /// counts: a finish at one, and an accessibility press, which has no page element to test.
  /// Unreadable is nil: the action that follows fails on the same page anyway.
  func verificationCheck(_ arguments: [String: Any] = [:], anyShown: Bool = false) async -> VerificationCheck? {
    let ref = arguments["ref"] as? String ?? ""
    var documents: [WKFrameInfo?] = [nil]
    if let frame = try? actionFrame(arguments), !frame.isMainFrame { documents.append(frame) }
    for frame in documents {
      guard let found = try? await script(
        "globalThis.__serein.challenge(\(jsonString(ref)))", frame: frame) as? [String: Any]
      else { continue }
      if anyShown || found["blocks"] as? Bool == true { return VerificationCheck(host: verificationHost) }
    }
    return nil
  }
  func frameOutline(start: Int, frameID: String?) async throws -> [String: Any] {
    let frame: WKFrameInfo?
    if let frameID {
      guard let target = frames[frameID], !target.isMainFrame else {
        throw SereinError.invalid("Unknown frame. Read the tab again.")
      }
      frame = target
    } else {
      frame = nil
    }
    var result = try await readDocument(start: start, frame: frame)
    // The frame's window size is for FrameMap only.
    result["viewport"] = nil
    if frameID == nil {
      result["frames"] = frames.filter { !$0.value.isMainFrame }.map { id, info in
        [
          "frame": id, "url": info.request.url?.absoluteString ?? "",
          "origin": info.securityOrigin.protocol + "://" + info.securityOrigin.host
            + (info.securityOrigin.port == 0 ? "" : ":\(info.securityOrigin.port)"),
        ]
      }.sorted { $0["frame", default: ""] < $1["frame", default: ""] }
    }
    if let frameID { result["frame"] = frameID }
    return result
  }
  /// One document's PageKit read. A read that fails while the document is replaced (PageKit not
  /// there yet, a frame mid-navigation) is tried again 300 ms later, up to 3 tries in all; the
  /// last error is the one the agent gets.
  private func readDocument(start: Int, frame: WKFrameInfo?) async throws -> [String: Any] {
    var tries = 0
    while true {
      tries += 1
      do {
        if let value = try await script("globalThis.__serein.read(\(max(0, start)))", frame: frame) as? [String: Any] {
          return value
        }
        if tries >= 3 { return [:] }
      } catch {
        if tries >= 3 || sleeping { throw error }
      }
      try? await Task.sleep(nanoseconds: 300_000_000)
    }
  }
  /// The reads of this page's child frames for one map of the page (FrameMap), in frame-id order.
  /// It stops once `shown` visible frames are found (the top document's count), after
  /// FrameMap.readLimit frames, or after FrameMap.readBudget seconds. A frame `admits` refuses (a
  /// site the person or the assistant keeps agents off) and a frame that does not answer are left out.
  func childFrameReads(shown: Int, admits: (URL) -> Bool) async -> [FrameMap.Child] {
    let started = Date()
    var children: [FrameMap.Child] = []
    var visible = 0
    for (id, info) in frames.filter({ !$0.value.isMainFrame }).sorted(by: { $0.key < $1.key }) {
      guard visible < shown, children.count < FrameMap.readLimit,
        Date().timeIntervalSince(started) < FrameMap.readBudget, !sleeping
      else { break }
      guard let url = info.request.url, admits(url),
        let page = try? await script("globalThis.__serein.read(0)", frame: info) as? [String: Any]
      else { continue }
      if FrameMap.isVisible(page) { visible += 1 }
      let origin = info.securityOrigin
      let site = origin.host.isEmpty ? (url.host ?? "") : origin.host + (origin.port == 0 ? "" : ":\(origin.port)")
      children.append(FrameMap.Child(id: id, site: site, page: page))
    }
    return children
  }
  /// The frame an action's ref points at. A stale frame is an error the caller refuses.
  func actionFrame(_ arguments: [String: Any]) throws -> WKFrameInfo? {
    if let ref = arguments["ref"] as? String, ref.hasPrefix("e"), let end = ref.firstIndex(of: "_") {
      let document = String(ref[ref.index(after: ref.startIndex)..<end])
      guard let target = frames[document] else {
        throw SereinError.invalid("Stale frame reference. Read the tab again.")
      }
      return target
    } else if let id = arguments["frame"] as? String {
      guard let target = frames[id] else { throw SereinError.invalid("Unknown frame") }
      return target
    }
    return nil
  }

  /// The site of the document an action lands in, routed as `frameAction` routes it: an
  /// accessibility ref and a top-document ref act in the tab's own page; a child frame's ref acts
  /// in that frame, whose site is its own origin, not the tab's. nil when the frame is gone or
  /// has no host of its own (sandboxed, opaque): a person's words then cover nothing there.
  func actionSite(_ arguments: [String: Any]) -> String? {
    let top = URL(string: address)?.host
    if (arguments["ref"] as? String)?.hasPrefix("x") == true { return top }
    let frame: WKFrameInfo?
    do { frame = try actionFrame(arguments) } catch { return nil }
    guard let frame, !frame.isMainFrame else { return top }
    let host = frame.securityOrigin.host
    return host.isEmpty ? nil : host
  }

  /// Whether the control `pressed` sits in the form of field `field` (a secure card's filled field,
  /// kept across reads), in the press's frame. False when either is gone or the field has no form.
  func sharesForm(_ field: String, _ pressed: String, arguments: [String: Any]) async -> Bool {
    guard let frame = try? actionFrame(arguments) else { return false }
    let value = try? await script(
      "globalThis.__serein.sameForm(\(jsonString(field)),\(jsonString(pressed)))", frame: frame)
    return value as? Bool == true
  }

  /// The live control, or disconnected when it cannot be read. A page-level action has no element.
  func elementFacts(name: String, arguments: [String: Any]) async -> ActionAdmission {
    let ref = arguments["ref"] as? String ?? ""
    if ref.isEmpty {
      return .page
    }
    if ref.hasPrefix("x") {
      let label = (arguments["name"] as? String) ?? (arguments["label"] as? String) ?? ""
      return ActionAdmission(
        connected: true, bind: ref, label: label, submits: false, formTarget: nil, nearbyAmount: false,
        secret: false)
    }
    let frame: WKFrameInfo?
    do { frame = try actionFrame(arguments) } catch { return .disconnected }
    do {
      let value = try await script(
        "globalThis.__serein.describe(\(jsonString(ref)),\(jsonString(name)),\(jsonString(arguments)))",
        frame: frame)
      guard let raw = value as? [String: Any] else { return .disconnected }
      if raw["connected"] as? Bool == false { return .disconnected }
      let reading = await readingWithSiblings(PageReading.snapshot(raw), action: frame)
      return ActionAdmission(
        connected: reading.connected,
        bind: reading.bind,
        label: reading.label,
        submits: reading.submits,
        formTarget: nil,
        nearbyAmount: false,
        secret: reading.secret,
        reading: reading)
    } catch {
      return .disconnected
    }
  }

  /// The action frame's reading plus every other frame. A card or a 3DS frame beside the
  /// button is part of the pre-press re-rate. A frame that cannot be read still contributes
  /// its address, so a payment host is not dropped.
  private func readingWithSiblings(_ primary: PageSnapshot, action: WKFrameInfo?) async -> PageSnapshot {
    var siblings: [PageSnapshot] = []
    for info in frames.values where info !== action && !(action == nil && info.isMainFrame) {
      if let raw = try? await script(PageReading.siblingScan, frame: info.isMainFrame ? nil : info) as? [String: Any] {
        siblings.append(PageReading.snapshot(raw))
      }
      let address = info.request.url?.absoluteString ?? ""
      if !address.isEmpty {
        siblings.append(PageReading.frameHint(src: address, title: "", name: "", id: ""))
      }
    }
    return PageReading.withSiblings(primary, siblings: siblings)
  }

  /// `allowed` is asked again after the pointer reaches the element: Stop or Take over during
  /// the glide ends the task, and nothing may act after that.
  /// `binding` is the approval. The live element is checked again after the pointer arrives.
  func frameAction(
    name: String, arguments: [String: Any], allowed: () -> Bool = { true },
    binding: ApprovalGate.ActionIntent
  ) async throws -> Any {
    try await recheck(binding, name: name, arguments: arguments)
    if let ref = arguments["ref"] as? String, ref.hasPrefix("x") {
      // An approval never covers a press in a verification check, however long the ask took. An
      // accessibility ref has no page element to test, so any check the page shows counts.
      if let check = await verificationCheck(arguments, anyShown: true) { throw check }
      return try await PageAX.press(self, ref: ref, name: name, allowed: allowed)
    }
    let frame = try actionFrame(arguments)
    // Serein's own pointer glides to the element first, so the user can follow the agent. The
    // page only reports the spot; in a sub-frame the spot is relative to that frame.
    if ["click", "type", "select", "hover", "key"].contains(name), let ref = arguments["ref"] as? String,
      let spot = try? await script("globalThis.__serein.target(\(jsonString(ref)))", frame: frame) as? [String: Any],
      let x = (spot["x"] as? NSNumber)?.doubleValue, let y = (spot["y"] as? NSNumber)?.doubleValue
    {
      await pointAgent(at: CGPoint(x: x, y: y))
    }
    guard allowed() else { throw SereinError.invalid("The task ended during this operation") }
    try await recheck(binding, name: name, arguments: arguments)
    // A check can appear while the pointer glides (a page loads one late). An approval never covers
    // it: `act` refuses in its own document (needs_user, captcha). An act in a sub-frame cannot see
    // the main page, so the main page is asked here first.
    if frame.map({ !$0.isMainFrame }) ?? false,
      let found = try? await script("globalThis.__serein.challenge('')") as? [String: Any],
      found["blocks"] as? Bool == true
    {
      throw VerificationCheck(host: verificationHost)
    }
    // The main-document check above can suspend too. A revoked task or changed page must not
    // reach either action path after that await.
    guard allowed() else { throw SereinError.invalid("The task ended during this operation") }
    guard !sleeping, pageVersion == binding.pageVersion else { throw SereinError.invalid(ActionAdmission.pageChanged) }
    if binding.effect == .pay || binding.effect == .send || binding.effect == .delete {
      // PageKit clears refs after input. Its private async call keeps the exact node only
      // until the handler's microtasks have drained; no stale ref or label is resolved again.
      guard !sleeping else { throw SereinError.invalid("This tab is asleep.") }
      guard allowed() else { throw SereinError.invalid("The task ended during this operation") }
      let raw: Any?
      do {
        raw = try await web.callAsyncJavaScript(
          "return await globalThis.__serein.actAndDescribe(action, values)",
          arguments: ["action": name, "values": arguments], in: frame, contentWorld: Self.world)
      } catch {
        // The press tore its own page down on the way out (a link, a submit): it ran.
        if pageVersion != binding.pageVersion { return Self.pressedThenMoved }
        let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
        throw SereinError.invalid(detail ?? error.localizedDescription)
      }
      guard allowed() else { throw SereinError.invalid("The task ended during this operation") }
      // From here the press has run: a page that moved on is reported as pressed and unchecked,
      // never as "nothing was pressed", so an agent reads the page instead of pressing again.
      guard !sleeping, pageVersion == binding.pageVersion else { return Self.pressedThenMoved }
      guard let packet = raw as? [String: Any], let acted = packet["result"] else {
        throw SereinError.invalid("Serein could not read back what that did, so it is not reporting it as done.")
      }
      if (acted as? [String: Any])?["reason"] as? String == "captcha" {
        throw VerificationCheck(host: verificationHost)
      }
      guard let described = packet["reading"] as? [String: Any] else {
        throw SereinError.invalid("Serein could not read back what that did, so it is not reporting it as done.")
      }
      let reading = await readingWithSiblings(PageReading.snapshot(described), action: frame)
      guard allowed() else { throw SereinError.invalid("The task ended during this operation") }
      guard !sleeping, pageVersion == binding.pageVersion else { return Self.pressedThenMoved }
      let after = ActionAdmission.readback(effect: binding.effect, label: reading.label, reading: reading)
      guard reading.bind == binding.elementID, ActionAdmission.readBackHolds(after, live: reading) else {
        throw SereinError.invalid("Serein could not read back what that did, so it is not reporting it as done.")
      }
      return acted
    }
    let acted = try await script(
      "globalThis.__serein.act(\(jsonString(name)),\(jsonString(arguments)))", frame: frame)
    if (acted as? [String: Any])?["reason"] as? String == "captcha" { throw VerificationCheck(host: verificationHost) }
    return acted
  }

  /// What a high-stakes press answers when it ran and the page moved on before its read-back.
  static let pressedThenMoved: [String: Any] = ["pressed": true, "checked": false, "note": ActionAdmission.pressedThenMoved]

  /// Classifies the live control again, then allows the press only when the element,
  /// the page version and the effect are still the ones that were approved.
  /// An effect change throws the yes out. The caller asks again. It does not press.
  private func recheck(_ binding: ApprovalGate.ActionIntent, name: String, arguments: [String: Any]) async throws {
    let live = await elementFacts(name: name, arguments: arguments)
    guard live.connected else { throw SereinError.invalid(ActionAdmission.pageChanged) }
    let gate = ActionAdmission.action(
      name: name, arguments: arguments, site: web.url?.host, pageVersion: pageVersion, live: live)
    guard binding.passwordForm == gate.passwordForm else { throw SereinError.invalid(ActionAdmission.effectChanged) }
    // The same classification as the ask, on the reading taken just now.
    let effect = gate.effect ?? ApprovalGate.resolved(gate)
    switch ApprovalGate.pressCheck(
      intent: binding, answer: .yes, liveElement: live.bind, liveVersion: pageVersion, liveEffect: effect)
    {
    case .proceed: return
    case .effectChanged: throw SereinError.invalid(ActionAdmission.effectChanged)
    case .refused: throw SereinError.invalid(ActionAdmission.pageChanged)
    }
  }
}
