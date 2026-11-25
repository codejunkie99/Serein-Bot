import Foundation
import SereinCore
import UniformTypeIdentifiers
import WebKit

/// The upload tool: a file the person attached to this turn goes into a page's file field, after
/// a card that names the file and the site. Never under Autopilot (a task at Proactive needs no
/// card), never in a scheduled run (ApprovalDoor.answer for `.upload`), never into a payment
/// form, and never any other file:
/// only a document this turn was sent with (`AgentRun.documents`, in its own folder, which is
/// deleted when the run ends), and only the bytes it had when it was staged (its digest). The
/// file is set on the approved element itself in Serein's page-reader world (PageKit `upload`),
/// so no file panel opens and no other field can receive it.
extension BrowserModel {
  /// The upload card's only yes: nothing is remembered, whatever the level.
  nonisolated static let uploadButton = "Allow once"
  static let uploadNotAttached =
    "Only a document the user attached to this message can be uploaded. Name it exactly as listed under Documents the user attached."

  func upload(_ tab: BrowserTab, task id: String, arguments a: [String: Any]) async throws -> [String: Any] {
    guard let field = a["field"] as? String, let name = a["file"] as? String else {
      throw SereinError.invalid("upload needs tab, field (the file row's upload value) and file.")
    }
    // This turn's staged documents only (the chips it was sent with, each with the digest taken
    // at staging): an earlier turn's folder is gone, no path outside it resolves, and a file the
    // agent wrote into the folder is not on the list.
    func attached() -> (file: URL, digest: String, size: Int)? {
      guard let run = agentTabs.hub?.runs.first(where: { $0.taskID == id && $0.isActive }),
        let folder = run.attachments,
        let document = run.documents.first(where: { $0.name == name }), let digest = document.digest,
        let file = TurnAttachments.document(named: name, in: folder, root: ComposerContext.attachmentRoot),
        file.standardizedFileURL.path == URL(fileURLWithPath: document.path).standardizedFileURL.path
      else { return nil }
      return (file, digest, document.size)
    }
    // A table over the upload limit attaches for table_query (TurnAttachments.limit) but is never sent.
    if let run = agentTabs.hub?.runs.first(where: { $0.taskID == id && $0.isActive }),
      let document = run.documents.first(where: { $0.name == name }), document.size > TurnAttachments.documentLimit
    {
      let most: String = Bytes.file(Int64(TurnAttachments.documentLimit))
      throw SereinError.invalid("\(name) is over \(most). Serein uploads attached files up to \(most); the user can upload it themselves.")
    }
    guard let file = attached() else { throw SereinError.invalid(Self.uploadNotAttached) }
    let relay = relayTask(id, tasks[id])
    let standing = self.standing(task: id, else: RelayOrchestrator.standing(relay, present: !isUnattended(task: id)))
    if let check = await tab.verificationCheck() { throw check }
    let frame = try tab.uploadFrame(field)
    try await authorizeSite(tab.address, taskID: id)
    // A field in another site's frame sends the file to that site: it is named, and asked for too.
    let pageHost = (tab.web.url?.host ?? URL(string: tab.address)?.host ?? "").lowercased()
    let frameHost = frame.isMainFrame ? "" : frame.securityOrigin.host
    // A frame without a request URL is still checked by its origin.
    let origin = frame.isMainFrame || frame.securityOrigin.host.isEmpty
      ? nil : "\(frame.securityOrigin.protocol)://\(frame.securityOrigin.host)"
    if !frameHost.isEmpty, frameHost != pageHost, let address = frame.request.url?.absoluteString ?? origin {
      try await authorizeSite(address, taskID: id)
    }
    let host = frameHost.isEmpty ? pageHost : frameHost
    let frameAddress =
      frame.isMainFrame ? nil : [frame.request.url?.absoluteString ?? "", frame.securityOrigin.host].joined(separator: " ")
    guard let live = await tab.uploadReading(field, frame: frame) else {
      throw SereinError.invalid(ActionAdmission.pageChanged)
    }
    if ApprovalGate.paymentField(live, frameAddress: frameAddress) {
      throw SereinError.invalid("Serein does not upload files into a payment form.")
    }
    let gate = ApprovalGate.GateAction(
      kind: "upload", label: live.label, effect: .upload, elementID: live.bind, pageVersion: tab.pageVersion,
      site: host)
    let decision = try ApprovalDoor.answer(
      .init(.action(gate), standing, site: siteRule(tab.address, tool: "upload", arguments: a, task: id), taskID: id),
      facts: .init(
        secureField: false, botCheck: false, pays: .no, covered: false, path: nil, hostKeyChanged: nil,
        runsAnything: false, ref: "")
    ).decision()
    let intent = ApprovalGate.record(gate, effect: .upload, mint: { UUID().uuidString })
    if let pending = tasks[id]?.pendingApprovals {
      tasks[id]?.pendingApprovals = ApprovalGate.mergePending(pending, intent)
    }
    // A card has Allow once and Decline, nothing remembered; with nobody there it is deferred.
    guard let askRelay = relay ?? RelayOrchestrator.shared else { throw SereinError.invalid(ActionAdmission.needsPerson) }
    let fileName = file.file.lastPathComponent
    let place = host.isEmpty ? "this site" : host
    let fieldWords = live.label.isEmpty ? "a file field" : "the “\(String(live.label.prefix(60)))” field"
    // The size tells apart two files the person attached under one name ("cv.pdf", "cv 2.pdf").
    let size = Bytes.file(Int64(file.size))
    var detail = "Serein puts \(fileName) (\(size)) into \(fieldWords). \(ApprovalGate.askLine(.upload))"
    if !frameHost.isEmpty, frameHost != pageHost {
      detail += "\nThe field belongs to \(frameHost), inside a page of \(pageHost.isEmpty ? "another site" : pageHost)."
    }
    let answer: ApprovalGate.HumanAnswer = await decision == .auto ? .yes : askRelay.confirmAnswer(
      "Upload \(fileName) to \(place)?", detail, button: Self.uploadButton, thread: threadID(forTask: id), site: host)
    guard tasks[id]?.finished == false else { throw SereinError.invalid("The task ended while awaiting approval") }
    // A yes given before the site, or the frame's site, became Never does not upload (read again).
    try checkSiteRule(tab)
    if !frame.isMainFrame { try SiteRules.check(frame.request.url?.absoluteString) }
    try SiteRules.check(origin)
    // The same field, page version and effect as the yes, read again just before the files are set.
    let after = await tab.uploadReading(field, frame: frame)
    let liveEffect: ApprovalGate.Effect =
      after.map { ApprovalGate.paymentField($0, frameAddress: frameAddress) } == false ? .upload : .pay
    switch ApprovalGate.pressCheck(
      intent: intent, answer: answer, liveElement: after?.bind ?? "", liveVersion: tab.pageVersion, liveEffect: liveEffect)
    {
    case .proceed: break
    case .effectChanged: throw SereinError.invalid(ActionAdmission.effectChanged)
    case .refused:
      throw SereinError.invalid(ActionAdmission.blocked(answer: answer, decision: decision, effectChanged: false))
    }
    tab.noteApprovedElement(frame)
    // The turn may have ended while the card waited: its folder is gone, and so is the file. The
    // bytes are read once and checked against the staging digest; these exact bytes are sent, so
    // a file replaced or swapped for a link after the check above never reaches the page. The read
    // follows no link, never blocks on a pipe, and stops one byte past the limit, so an oversized
    // file is refused below rather than cut.
    guard let approved = attached(), approved.file == file.file,
      let data = SafeFileRead.regularFile(approved.file.path, limit: TurnAttachments.documentLimit + 1),
      data.count <= TurnAttachments.documentLimit
    else { throw SereinError.invalid(Self.uploadNotAttached) }
    guard TurnAttachments.digest(data) == approved.digest else {
      throw SereinError.invalid("The attached file changed after it was attached, so Serein did not upload it.")
    }
    guard !tab.sleeping, tasks[id]?.finished == false, tab.pageVersion == intent.pageVersion else {
      throw SereinError.invalid(ActionAdmission.pageChanged)
    }
    let type = UTType(filenameExtension: approved.file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    let raw: Any?
    do {
      raw = try await tab.web.callAsyncJavaScript(
        "return globalThis.__serein.upload(field, bind, name, type, data)",
        arguments: ["field": field, "bind": intent.elementID, "name": fileName, "type": type,
                    "data": data.base64EncodedString()],
        in: frame, contentWorld: BrowserTab.world)
    } catch {
      let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
      throw SereinError.invalid(message ?? error.localizedDescription)
    }
    let result = raw as? [String: Any] ?? [:]
    if result["reason"] as? String == "captcha" { throw VerificationCheck(host: tab.verificationHost) }
    if result["changed"] as? Bool == true { throw SereinError.invalid(ActionAdmission.pageChanged) }
    guard result["ok"] as? Bool == true else {
      throw SereinError.invalid(result["text"] as? String ?? "The page did not take the file.")
    }
    let label = result["field"] as? String ?? live.label
    agentTabs.relabelLast(
      task: id, tool: "upload",
      "Uploaded \(fileName) to " + (label.isEmpty ? "a file field" : "the “\(String(label.prefix(48)))” field"))
    return ["uploaded": fileName, "field": label, "site": place]
  }
}

extension BrowserTab {
  /// The frame of a file field from the latest read (`u<document>_…`, PageKit `read`).
  func uploadFrame(_ field: String) throws -> WKFrameInfo {
    guard field.hasPrefix("u"), let end = field.firstIndex(of: "_"),
      let frame = frames[String(field[field.index(after: field.startIndex)..<end])]
    else { throw SereinError.invalid("Stale file field. Read the tab again.") }
    return frame
  }
  /// The file field as it is now; nil when it is gone or no longer a file field.
  func uploadReading(_ field: String, frame: WKFrameInfo) async -> PageSnapshot? {
    guard let raw = try? await script("globalThis.__serein.describeUpload(\(jsonString(field)))", frame: frame)
      as? [String: Any], raw["connected"] as? Bool == true,
      raw["tag"] as? String == "input", raw["type"] as? String == "file"
    else { return nil }
    return PageReading.snapshot(raw)
  }
}
