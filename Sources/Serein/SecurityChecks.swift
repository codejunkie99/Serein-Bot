#if DEBUG
import AppKit
import Foundation
import SereinCore
import WebKit

/// Synthetic pages and in-memory stores only. No saved credential, account or personal tab
/// is read, and no model provider is called.
@MainActor func checkAgentContextPrivacy() async throws {
  guard let base = ProcessInfo.processInfo.environment["SEREIN_FIXTURE_URL"],
    let data = ProcessInfo.processInfo.environment["SEREIN_DATA_DIR"]
  else { throw SereinError.invalid("Security checks require an isolated test library and localhost fixture.") }
  let browser = try BrowserModel(root: URL(fileURLWithPath: data))
  defer { browser.shutdown() }
  let approvals = try FixtureApprovals(browser: browser)
  defer { approvals.close() }
  var checks = 0
  func check(_ condition: Bool, _ label: String) throws {
    guard condition else { throw SereinError.invalid("Security check failed: " + label) }
    checks += 1
  }
  let task = try browser.beginTask(isolated: true, allowActions: false, includeCurrent: false)
  func call(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
    try await browser.handle(["task": task.capability.task, "token": task.capability.token,
      "name": name, "arguments": args])
  }
  let secrets = ["SEREIN_QUERY_CANARY", "SEREIN_FRAGMENT_CANARY", "SEREIN_PASSWORD_CANARY",
    "sk-proj-SEREIN_TOKEN_CANARY_1234567890", "SEREIN_FIELD_TOKEN_CANARY"]
  let address = base + "security?unknown=" + secrets[0] + "#" + secrets[1]
  let opened = try await approvals.perform(expecting: [.site(url: address)]) {
    try await call("open_tab", ["url": address])
  }
  let id = opened["tab"] as! String
  guard let tab = browser.tasks[task.capability.task]?.tabs.first else { throw SereinError.invalid("No synthetic tab.") }
  await tab.settle(limit: 5)
  let read = try await call("read", ["tab": id])
  try check(read["sensitive"] as? Bool == true && read["text"] as? String == "Security fixture",
    "Password page sends its text without what is typed there")
  try check(!secrets.contains { jsonString(read).contains($0) }, "MCP reply excludes password and URL canaries")
  func pictureRefused() async -> Bool {
    do { _ = try await call("screenshot", ["tab": id]); return false } catch { return true }
  }
  /// The first field's opacity while the page is blanked for a picture.
  func blankedColour() async throws -> String {
    let colour = try await tab.script(
      "(()=>{globalThis.__serein.blank();const c=getComputedStyle(document.querySelector('input')).opacity;globalThis.__serein.unblank();return c})()") as? String
    return colour ?? ""
  }
  var pictured = !(await pictureRefused())
  var colour = try await blankedColour()
  try check(pictured && colour == "0", "Password page is pictured with the field blanked")
  _ = try await tab.script("const p=document.querySelector('input');p.type='text';p.name='';p.id='';p.removeAttribute('autocomplete');true")
  pictured = !(await pictureRefused())
  colour = try await blankedColour()
  try check(pictured && colour == "0", "Show password keeps the field blanked in pictures")
  let revealed = try await call("read", ["tab": id])
  try check(!jsonString(revealed).contains(secrets[2]) && revealed["sensitive"] as? Bool == true,
    "Revealed password remains excluded")
  _ = try await tab.script("document.body.textContent='SEREIN_PASSWORD_CANARY';true")
  let removed = try await call("read", ["tab": id])
  try check(removed["sensitive"] as? Bool == true && !jsonString(removed).contains(secrets[2]), "Removing a password field cannot expose its plaintext in the same document")
  try check(await pictureRefused(), "Removed password field cannot reopen pictures")

  try tab.navigate(base + "security-token")
  await tab.settle(limit: 5)
  let token = try await call("read", ["tab": id])
  try check((token["text"] as? String)?.contains("[hidden]") == true && !jsonString(token).contains(secrets[3]),
    "Visible API token is cut out of the text")
  try check(!(await pictureRefused()), "A page with a visible API token is pictured with it blanked")

  try tab.navigate(base + "security-token-field")
  await tab.settle(limit: 5)
  let tokenField = try await call("read", ["tab": id])
  try check(tokenField["sensitive"] as? Bool == true && !jsonString(tokenField).contains(secrets[4]), "Opaque token field is excluded by its metadata")
  try check(!(await pictureRefused()), "Opaque token field is pictured blanked")

  // A value a page script sets after load, and shows again elsewhere: cut from text, blanked.
  try tab.navigate(base + "security-script")
  await tab.settle(limit: 5)
  try await Task.sleep(nanoseconds: 400_000_000)
  let scripted = try await call("read", ["tab": id])
  try check((scripted["text"] as? String)?.contains("Saved: [hidden]") == true && !jsonString(scripted).contains("SCRIPT_SET_CANARY_77"),
    "A value a script sets and shows again is cut out of the text")
  try check(!(await pictureRefused()), "A page with a script-set value is pictured blanked")

  // The typed code is in no read result (its pixels are checked with the painted cases below).
  try tab.navigate(base + "security-pixels")
  await tab.settle(limit: 5)
  let codePage = try await call("read", ["tab": id])
  try check(!jsonString(codePage).contains("88888888"), "The typed code is in no read result")

  // What Serein cannot look inside, beside the user's fields, is hidden whole: a canvas, a closed
  // root on a custom element, on a div, and one the HTML parser built (unmarked).
  for (page, selector) in [("security-canvas", "canvas"), ("security-closed", "x-box"), ("security-closed-div", "#host"), ("security-dsd", "#dsd")] {
    try tab.navigate(base + page)
    await tab.settle(limit: 5)
    let opacity = try await tab.script(
      "(()=>{globalThis.__serein.blank();const o=getComputedStyle(document.querySelector('\(selector)')).opacity;globalThis.__serein.unblank();return o})()") as? String
    let pictured = !(await pictureRefused())
    try check(pictured && opacity == "0", "\(page): pictured with \(selector) hidden whole")
  }
  // A 2FA setup page: the seed is cut out of the text, and pictures hide the QR image, background
  // images, the seed and the stroked code.
  try tab.navigate(base + "security-2fa")
  await tab.settle(limit: 5)
  let twoStep = try await call("read", ["tab": id])
  try check((twoStep["text"] as? String)?.contains("Secret: [hidden]") == true && !jsonString(twoStep).contains("JBSW"),
    "A setup seed beside a code field is cut out of the text")
  let hidden = try await tab.script(
    "(()=>{globalThis.__serein.blank();const g=s=>getComputedStyle(document.querySelector(s));const r=[g('#qr').opacity,g('#badge').backgroundImage,g('#seed').opacity,g('#recovery').opacity,g('#code').opacity];globalThis.__serein.unblank();return r})()") as? [String]
  try check(!(await pictureRefused()) && hidden == ["0", "none", "0", "0", "0"],
    "A 2FA page is pictured with its QR image, background images, seed, recovery codes and stroked code hidden (\(hidden ?? []))")
  try check(!jsonString(twoStep).contains("7f3k-92ad"), "Recovery codes beside a code field are cut out of the text")

  // A value shown again outside its field, however it is painted: split over spans, SVG text, a
  // card's 3-digit code. Each shows in the picture with blanking off and not with it on.
  /// Pixels in the element's box that differ from a background sample: beside the box, or (`inside`)
  /// at its own top-left corner, for an element that paints its own background.
  func marks(_ selector: String, inside: Bool = false) async throws -> Int {
    let shot = try await call("screenshot", ["tab": id])
    // SEREIN_CHECK_PICTURES=<folder> keeps the pictures, to look at them after a failure.
    if let folder = ProcessInfo.processInfo.environment["SEREIN_CHECK_PICTURES"],
      let encoded = (shot["content"] as? [[String: Any]])?.first?["data"] as? String, let png = Data(base64Encoded: encoded)
    {
      try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(selector.dropFirst())-\(Date().timeIntervalSince1970).png"))
    }
    guard let encoded = (shot["content"] as? [[String: Any]])?.first?["data"] as? String,
      let png = Data(base64Encoded: encoded), let picture = NSBitmapImageRep(data: png),
      let box = try await tab.script(
        "(()=>{const b=document.querySelector('\(selector)').getBoundingClientRect();return [b.x,b.y,b.width,b.height,innerWidth]})()") as? [Double],
      box.count == 5, box[4] > 0
    else { return -1 }
    let scale = Double(picture.pixelsWide) / box[4]
    func brightness(_ x: Double, _ y: Double) -> Double {
      Double(picture.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0)
    }
    let page = inside ? brightness(box[0] + 3, box[1] + 3) : brightness(box[0] - 6, box[1] + box[3] / 2)
    var count = 0
    for y in stride(from: box[1], to: box[1] + box[3], by: 1) {
      for x in stride(from: box[0], to: box[0] + box[2], by: 1) where abs(brightness(x, y) - page) > 0.3 { count += 1 }
    }
    return count
  }
  for (page, selector, value) in [("security-pixels", "#code", "88888888"), ("security-split", "#preview", "4111"),
    ("security-svg", "#art", "4111"), ("security-cvc", "#back", "737"), ("security-dsd", "#dsd", "5555")] {
    try tab.navigate(base + page)
    await tab.settle(limit: 5)
    let readBack = try await call("read", ["tab": id])
    let hiddenMarks = try await marks(selector, inside: selector == "#art")
    _ = try await tab.script(
      "(()=>{const a={ok:true,frames:0,id:'off'};globalThis.__serein.blank=()=>a;globalThis.__serein.confirmBlank=()=>a;return true})()")
    let shownMarks = try await marks(selector, inside: selector == "#art")
    try check(hiddenMarks == 0 && shownMarks > 50,
      "\(page): the value is not in the picture (\(hiddenMarks) marked pixels; \(shownMarks) with blanking off)")
    let text = readBack["text"] as? String ?? ""
    try check(!text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == value }
      && !text.contains("4111") && !text.contains("88888888") && !text.contains("5555"),
      "\(page): the value is not in the text")
  }


  // A custom PIN box (role=textbox) counts as the user's field.
  try tab.navigate(base + "security-pin")
  await tab.settle(limit: 5)
  let pin = try await call("read", ["tab": id])
  // Everything the page could fill. A random document or tab id, or the fixture's port, holds four
  // digits like these by chance about once in a thousand reads.
  let pinContent = pin.filter { !["documentID", "tab", "url"].contains($0.key) }
  try check((pin["text"] as? String)?.contains("Enter the code we sent.") == true && !jsonString(pinContent).contains("4321"),
    "A custom PIN box is the user's field: its digits are cut out of the text")

  try tab.navigate(base + "plain?token=" + secrets[0] + "#" + secrets[1])
  await tab.settle(limit: 5)
  let ordinary = try await call("read", ["tab": id])
  try check((ordinary["text"] as? String)?.contains("Seat map") == true
    && !secrets.contains { jsonString(ordinary).contains($0) }, "Ordinary page stays useful without URL tokens")
  // Noise over the whole view makes a PNG far over the helper's limit; it still goes, as a JPEG.
  _ = try await tab.script(
    "(()=>{const c=document.createElement('canvas');c.width=innerWidth*2;c.height=innerHeight*2;c.style.cssText='position:fixed;inset:0;width:100vw;height:100vh';const x=c.getContext('2d'),d=x.createImageData(c.width,c.height);for(let i=0;i<d.data.length;i+=65536)crypto.getRandomValues(d.data.subarray(i,i+65536));for(let i=3;i<d.data.length;i+=4)d.data[i]=255;x.putImageData(d,0,0);document.body.append(c);return true})()")
  let noisy = (try await call("screenshot", ["tab": id])["content"] as? [[String: Any]])?.first
  try check(noisy?["mimeType"] as? String == "image/jpeg"
    && (noisy?["data"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap(NSBitmapImageRep.init(data:)) != nil,
    "A screenshot too big for the helper goes as a JPEG instead of failing")
  _ = try await tab.script("globalThis.__serein.read=()=>{throw Error('Password: SEREIN_PASSWORD_CANARY')};true")
  do {
    _ = try await call("read", ["tab": id])
    throw SereinError.invalid("Synthetic error was not raised.")
  } catch {
    try check(!error.localizedDescription.contains(secrets[2]), "Tool errors exclude credential canaries")
  }
  browser.endTask(task.capability.task)

  let personal = BrowserTab(store: .nonPersistent())
  defer { personal.discardPage() }
  try personal.navigate(address)
  await personal.settle(limit: 5)
  let captured = await ComposerContext.capture(personal)
  let context = PageContext.render(.init(page: captured))
  try check(captured.sensitive && !secrets.contains { context.contains($0) },
    "Composer context excludes password and URL canaries")
  do {
    try PasswordCapture.requireTrustedOrigin("https://other.invalid", in: personal)
    throw SereinError.invalid("Wrong-origin fill was accepted.")
  } catch {
    try check(error.localizedDescription.contains("Nothing was filled"), "Fill refuses origin changes before authentication")
  }
  let stale = try await personal.web.callAsyncJavaScript(
    "try { globalThis.__sereinPasswords.fill(origin, 'synthetic', 'SEREIN_FILL_CANARY', 'stale-document'); return false; } catch (_) { return true; }",
    arguments: ["origin": CredentialOrigin.normalize(address)!], in: nil, contentWorld: PasswordCapture.world) as? Bool
  try check(stale == true, "Fill refuses a replaced document before inserting a secret")
  guard let tls = ProcessInfo.processInfo.environment["SEREIN_TLS_FIXTURE_URL"] else {
    throw SereinError.invalid("Security checks also require the synthetic invalid-certificate fixture.")
  }
  let insecure = BrowserTab(privateMode: true, store: .nonPersistent())
  defer { insecure.discardPage() }
  try insecure.navigate(tls + "security")
  for _ in 0..<100 {
    if insecure.ext.rejectedCertificate != nil && insecure.ext.failedURL != nil && !insecure.web.isLoading { break }
    try await Task.sleep(nanoseconds: 50_000_000)
  }
  guard insecure.ext.rejectedCertificate != nil else { throw SereinError.invalid("Synthetic certificate was not rejected.") }
  insecure.continueAnyway()
  await insecure.settle(limit: 5)
  try check(PasswordCapture.certificateBypassed(insecure), "Native WebKit identifies a bypassed invalid certificate")
  do {
    try await PasswordCapture.fill(.init(id: "synthetic", username: "synthetic", credential: nil),
      origin: CredentialOrigin.normalize(tls)!, in: insecure)
    throw SereinError.invalid("Invalid-certificate fill was accepted.")
  } catch {
    try check(error.localizedDescription.contains("certificate problem"), "Shared password-fill path refuses invalid TLS before authentication or Keychain access")
  }
  FileHandle.standardOutput.write(Data("PASS: \(checks) synthetic browser privacy checks; no provider or Keychain access\n".utf8))
}
#endif
