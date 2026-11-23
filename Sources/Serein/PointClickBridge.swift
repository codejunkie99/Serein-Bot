import AppKit
import SereinCore
import WebKit

extension BrowserModel {
  /// The page's view as click_point compares it: PageKit's document, viewport and scroll, with the
  /// tab's page version and host. Nil when the page cannot say.
  func pointView(_ tab: BrowserTab) async -> PointClick.View? {
    PointClick.View(
      try? await tab.script("globalThis.__serein.view()"), pageVersion: tab.pageVersion, host: tab.web.url?.host ?? "")
  }

  /// One picture of the tab for the agent or the card. What the user typed in their own fields,
  /// and text that shows it or a credential, is made transparent for the picture in every frame,
  /// confirmed transparent again after it, and shown again; anything that cannot be confirmed is
  /// not pictured. The page's view on both sides of the picture comes with it: click_point maps a
  /// picture onto the page only if the view held still around it.
  func blankedSnapshot(_ tab: BrowserTab) async throws
    -> (image: NSImage, bitmap: NSBitmapImageRep, png: Data, before: PointClick.View?, after: PointClick.View?)
  {
    let refused = SereinError.invalid(
      "Serein could not hide every password, card number or code on this page, so it is not pictured. Read it instead.")
    guard await tab.blankSecrets("blank") else {
      await tab.unblankSecrets()
      throw refused
    }
    let config = WKSnapshotConfiguration()
    config.snapshotWidth = 1000
    let before = await pointView(tab)
    let image: NSImage
    do {
      image = try await tab.web.takeSnapshot(configuration: config)
    } catch {
      await tab.unblankSecrets()
      throw error
    }
    // The page may have changed while the picture was taken (a new field, a value shown
    // again): confirm before the fields come back, and discard the picture if not.
    let stillBlank = await tab.blankSecrets("confirmBlank")
    let after = await pointView(tab)
    await tab.unblankSecrets()
    guard stillBlank else { throw refused }
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else { throw SereinError.invalid("Screenshot unavailable") }
    return (image, bitmap, png, before, after)
  }

  /// Keeps a screenshot for this task's next click_point in the tab, only when the page's view was
  /// the same on both sides of the picture. Otherwise the tab has none, and click_point asks for a
  /// new screenshot. In memory only: only its size and view are kept.
  func notePointShot(
    _ tab: BrowserTab, task id: String, before: PointClick.View?, after: PointClick.View?, width: Int, height: Int
  ) {
    guard let before, before == after, width > 0, height > 0 else {
      tasks[id]?.shots[tab.id] = nil
      return
    }
    tasks[id]?.shots[tab.id] = PointClick.Shot(width: width, height: height, view: before)
  }

  /// click_point: a click at a spot in this task's latest screenshot of the tab. Refused in a
  /// scheduled run, at a verification check, on a page with the person's own fields, over a frame,
  /// and when anything moved since the screenshot. A click follows the task's level; a card shows
  /// the screenshot and a ring at the spot, and its answer is never remembered. After the yes the
  /// page version, host, document, viewport, scroll and the element under the spot must be the
  /// ones approved. A real control there is clicked through the element path (`frameAction`) with
  /// its usual checks; anything else gets mouse events at the spot from PageKit, never OS input.
  func clickPoint(_ tab: BrowserTab, task id: String, arguments a: [String: Any]) async throws -> Any {
    let relay = relayTask(id, tasks[id])
    guard !isUnattended(task: id) else { throw SereinError.invalid(PointClick.scheduledMessage) }
    // Each screenshot serves one click, whatever its outcome: the next card shows the page as it is.
    guard let shot = tasks[id]?.shots.removeValue(forKey: tab.id) else { throw SereinError.invalid(PointClick.noShot) }
    guard let x = (a["x"] as? NSNumber)?.doubleValue, let y = (a["y"] as? NSNumber)?.doubleValue,
      let spot = shot.spot(x: x, y: y)
    else { throw SereinError.invalid(PointClick.outside) }
    // The address as it is: one URL cannot parse is still judged, never skipped.
    if !tab.address.isEmpty { try await authorizeSite(tab.address, taskID: id) }
    if let check = await tab.verificationCheck() { throw check }
    if await tab.hasUserSteps() { throw SereinError.invalid(HandBack.message) }
    let found = try await pointTarget(tab, spot)
    guard found.view == shot.view else { throw SereinError.invalid(PointClick.changed) }
    let host = found.view.host
    let (gate, rated, reading) = await pointGate(tab, found)
    guard !gate.elementID.isEmpty else { throw SereinError.invalid(PointClick.changed) }
    let intent = ApprovalGate.record(gate, effect: rated, mint: { UUID().uuidString })
    if let pending = tasks[id]?.pendingApprovals {
      tasks[id]?.pendingApprovals = ApprovalGate.mergePending(pending, intent)
    }
    // Judged as unknown or higher, then the door at the task's own standing.
    let effect = PointClick.effect(rated)
    var judged = gate
    judged.effect = effect
    let readback = ActionAdmission.readback(effect: effect, label: gate.label ?? "", reading: reading)
    let pays: ApprovalDoor.PaySense =
      effect != .pay ? .no : readback.readable ? .yes(amount: readback.amount) : .unreadable
    let decision = try ApprovalDoor.answer(
      .init(.action(judged), standing(task: id, else: RelayOrchestrator.standing(relay, present: !isUnattended(task: id))),
            site: SiteRules.rule(for: tab.address), taskID: id),
      facts: .init(
        secureField: false, botCheck: false, pays: pays, covered: false, path: nil, hostKeyChanged: nil,
        runsAnything: false, ref: "")
    ).decision()
    let answer: ApprovalGate.HumanAnswer
    if decision == .auto {
      answer = .yes
    } else {
      guard let askRelay = relay ?? RelayOrchestrator.shared else { throw SereinError.invalid(ActionAdmission.needsPerson) }
      // The card shows the page as it is now, not as the agent saw it: an overlay that came since
      // leaves the view alike but not the picture. Card only: never sent to the agent or saved.
      let fresh = try await blankedSnapshot(tab)
      guard fresh.before == shot.view, fresh.after == shot.view else { throw SereinError.invalid(PointClick.changed) }
      let freshWidth = fresh.bitmap.pixelsWide, freshHeight = fresh.bitmap.pixelsHigh
      guard let picture = PointPicture.marked(
        fresh.png, x: x / Double(shot.width) * Double(freshWidth), y: y / Double(shot.height) * Double(freshHeight),
        width: freshWidth, height: freshHeight)
      else { throw SereinError.invalid(PointClick.noShot) }
      answer = await askRelay.confirmAnswer(
        PointClick.cardTitle(host: host),
        PointClick.cardDetail(what: AgentPrivacy.redact(found.target.what), control: found.target.control, summary: readback.summary),
        button: "Allow once", thread: threadID(forTask: id), site: host, picture: picture)
    }
    guard tasks[id]?.finished == false else { throw SereinError.invalid("The task ended while awaiting approval") }
    guard answer == .yes else {
      throw SereinError.invalid(ActionAdmission.blocked(answer: answer, decision: decision, effectChanged: false))
    }
    // The pointer goes to the spot before the press check, so nothing waits between it and the press.
    await tab.pointAgent(at: CGPoint(x: spot.x, y: spot.y))
    // The press check: the same page, view and element under the spot, and the same rating.
    if let check = await tab.verificationCheck() { throw check }
    if await tab.hasUserSteps() { throw SereinError.invalid(HandBack.message) }
    let now = try await pointTarget(tab, spot)
    let (liveGate, liveEffect, _) = await pointGate(tab, now)
    guard now.target.control == found.target.control,
      ApprovalGate.pressCheck(
        intent: intent, answer: answer, liveElement: liveGate.elementID, liveVersion: liveGate.pageVersion,
        liveEffect: liveEffect) == .proceed
    else { throw SereinError.invalid(PointClick.changed) }
    // The site may have been set to Never while the card waited.
    try checkSiteRule(tab)
    guard !tab.sleeping, tasks[id]?.finished == false else { throw SereinError.invalid("The task ended during this operation") }
    if now.target.control {
      // A real control: the element path, with its own recheck, pointer, check and read-back.
      var press = intent
      press.pageVersion = shot.view.pageVersion
      return try await tab.frameAction(
        name: "click", arguments: ["ref": now.target.ref], allowed: { [weak self] in self?.tasks[id] != nil },
        binding: press)
    }
    guard tab.pageVersion == shot.view.pageVersion else { throw SereinError.invalid(PointClick.changed) }
    let raw: Any?
    do {
      raw = try await tab.web.callAsyncJavaScript(
        "return globalThis.__serein.pointAct(x, y, want)",
        arguments: [
          "x": spot.x, "y": spot.y,
          "want": [
            "document": shot.view.document, "width": shot.view.width, "height": shot.view.height,
            "x": shot.view.scrollX, "y": shot.view.scrollY, "bind": intent.elementID,
          ] as [String: Any],
        ],
        in: nil, contentWorld: BrowserTab.world)
    } catch {
      let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
      throw SereinError.invalid(detail ?? error.localizedDescription)
    }
    let acted = raw as? [String: Any] ?? [:]
    if acted["reason"] as? String == "captcha" { throw VerificationCheck(host: tab.verificationHost) }
    guard acted["performed"] != nil else { throw SereinError.invalid(PointClick.changed) }
    return acted
  }

  /// PageKit's view and what is under the spot, read in one call. A refusal is thrown.
  private func pointTarget(_ tab: BrowserTab, _ spot: (x: Double, y: Double)) async throws
    -> (view: PointClick.View, target: PointClick.Target)
  {
    let raw = try await tab.script("globalThis.__serein.atPoint(\(spot.x),\(spot.y))")
    guard let view = PointClick.View(raw, pageVersion: tab.pageVersion, host: tab.web.url?.host ?? ""),
      let target = PointClick.Target(raw)
    else { throw SereinError.invalid(PointClick.changed) }
    switch target.refused {
    case nil: return (view, target)
    case "captcha"?: throw VerificationCheck(host: tab.verificationHost)
    case "yours"?: throw SereinError.invalid(HandBack.message)
    case "frame"?: throw SereinError.invalid(PointClick.frameMessage)
    default: throw SereinError.invalid(PointClick.nothingMessage)
    }
  }

  /// The gate's view of a click on the element under the spot, read live as `click` reads one, its
  /// rating and the page reading. The page version slot holds the point's stamp (PointClick.stamp).
  private func pointGate(_ tab: BrowserTab, _ found: (view: PointClick.View, target: PointClick.Target)) async
    -> (ApprovalGate.GateAction, ApprovalGate.Effect, PageSnapshot)
  {
    let arguments: [String: Any] = ["ref": found.target.ref]
    let live = await tab.elementFacts(name: "click", arguments: arguments)
    var gate = ActionAdmission.action(
      name: "click", arguments: arguments, site: found.view.host,
      pageVersion: PointClick.stamp(found.view, what: found.target.what), live: live)
    // A node that cannot be read binds to nothing, so the press check refuses it.
    if !live.connected { gate.elementID = "" }
    return (gate, gate.effect ?? ApprovalGate.resolved(gate), live.reading)
  }
}

/// The card's picture: the screenshot, small, with a ring and a cross at the spot. White with a
/// dark edge, as the agent pointer is drawn, so it reads on any page.
enum PointPicture {
  static let width: CGFloat = 360

  static func marked(_ png: Data, x: Double, y: Double, width pixels: Int, height: Int) -> NSImage? {
    guard let source = NSImage(data: png), pixels > 0, height > 0 else { return nil }
    let size = NSSize(width: width, height: width * CGFloat(height) / CGFloat(pixels))
    let image = NSImage(size: size, flipped: true) { rect in
      source.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
      let center = NSPoint(x: x / Double(pixels) * rect.width, y: y / Double(height) * rect.height)
      let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18))
      let cross = NSBezierPath()
      cross.move(to: NSPoint(x: center.x - 4, y: center.y))
      cross.line(to: NSPoint(x: center.x + 4, y: center.y))
      cross.move(to: NSPoint(x: center.x, y: center.y - 4))
      cross.line(to: NSPoint(x: center.x, y: center.y + 4))
      for path in [ring, cross] {
        NSColor.black.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 4
        path.stroke()
        NSColor.white.setStroke()
        path.lineWidth = 2
        path.stroke()
      }
      return true
    }
    image.accessibilityDescription = PointClick.pictureLabel
    return image
  }
}
