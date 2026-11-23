#if DEBUG
import Foundation
import SereinCore
import WebKit

/// Only synthetic markup in a nonpersistent store. No personal tab, credential store or
/// provider is used. Exercise the synchronous drain as well as observer delivery.
@MainActor func checkPageKitPerformanceContracts() async throws {
  let tab = BrowserTab(privateMode: true, owner: "synthetic-pagekit-check", store: .nonPersistent())
  defer { tab.discardPage() }
  var checks = 0
  func check(_ condition: Bool, _ label: String) throws {
    guard condition else { throw SereinError.invalid("PageKit check failed: " + label) }
    checks += 1
  }
  func load(_ body: String) async throws {
    let marker = UUID().uuidString
    tab.web.loadHTMLString("<!doctype html><title>\(marker)</title>" + body,
      baseURL: URL(string: "http://127.0.0.1/serein-synthetic-pagekit"))
    for _ in 0..<100 {
      if !tab.web.isLoading,
        (try? await tab.script("document.title")) as? String == marker,
        (try? await tab.script("typeof globalThis.__serein.readContext")) as? String == "function"
      { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw SereinError.invalid("Synthetic PageKit document did not load.")
  }
  func result(_ source: String) async throws -> [String: Any] {
    guard let value = try await tab.script(source) as? [String: Any] else {
      throw SereinError.invalid("Missing synthetic PageKit result.")
    }
    return value
  }
  try await load("<form id='signin'><input type='password'></form><button form='signin'>Enter account</button><form id='news'><button>Subscribe</button></form>")
  let forms = try await result("""
    (() => {
      const kit = globalThis.__serein;
      const read = kit.read().elements;
      const readForm = label => {
        const button = read.find(row => row.label === label);
        return button ? kit.describe(button.ref, 'click', {}).passwordForm : null;
      };
      const first = readForm('Enter account'), again = readForm('Enter account'), other = readForm('Subscribe');
      document.querySelector('#signin').replaceWith(document.querySelector('#signin').cloneNode(true));
      return { first, again, other, replacement:readForm('Enter account') };
    })()
    """)
  let loginForm = forms["first"] as? String
  try check(loginForm?.isEmpty == false && forms["again"] as? String == loginForm
    && forms["other"] as? String == "" && (forms["replacement"] as? String)?.isEmpty == false
    && forms["replacement"] as? String != loginForm,
    "Password submission binds the button to its own live form and expires when that form is replaced")
  try await load("<main id='feed'></main><script>for(let i=0;i<1500;i++){const p=document.createElement('p');p.innerHTML='Synthetic post '+i+' <a href=\"#'+i+'\">Reply</a><button>Like</button>';document.getElementById('feed').append(p)}</script>")
  let outline = try await result("globalThis.__serein.read()")
  let context = try await result("globalThis.__serein.readContext()")
  try check(outline["text"] as? String == context["text"] as? String,
    "Text-only context preserves the first page of text")
  try check((outline["elements"] as? [[String: Any]])?.count == 300
    && (context["elements"] as? [[String: Any]])?.isEmpty == true,
    "Agent reads retain 300 element references; context measures none")
  try check(outline["documentID"] as? String == context["documentID"] as? String
    && outline["revision"] as? Int == context["revision"] as? Int,
    "Both reads preserve document and revision integrity")
  let ref = (outline["elements"] as? [[String: Any]])?.first?["ref"] as? String ?? ""
  let stale = try await tab.script("try{globalThis.__serein.act('click',{ref:\(jsonString(ref))});false}catch(_){true}") as? Bool
  try check(stale == true, "Context reads continue to invalidate old action references")
  let revision = try await result("(() => { const k=globalThis.__serein,p=document.getElementById('feed');const a=k.probe().revision;p.className='changed';const b=k.probe().revision;p.style.opacity='.9';const c=k.probe().revision;p.firstChild.firstChild.textContent='Updated synthetic post';const d=k.probe().revision;p.append(document.createElement('p'));const e=k.probe().revision;return {ok:a<b&&b<c&&c<d&&d<e};})()")
  try check(revision["ok"] as? Bool == true,
    "Class, style, text and child mutations still advance revision before callback delivery")
  let lateSecret = try await result("(() => { const code=document.createElement('code');code.textContent='api_key = sk-proj-SEREIN_SYNTHETIC_LATE_TOKEN_1234567890';document.body.append(code);return globalThis.__serein.readContext();})()")
  try check(lateSecret["sensitive"] as? Bool == true
    && (lateSecret["text"] as? String)?.isEmpty == false
    && !jsonString(lateSecret).contains("SEREIN_SYNTHETIC_LATE_TOKEN"),
    "Security scans still inspect secrets beyond the shortened text-context budget; the secret is in no text")

  try await load("<input id='field' type='password' value='SEREIN_SYNTHETIC_PASSWORD'>")
  let toggled = try await result("(() => { const f=document.getElementById('field');f.type='text';f.id='';f.name='';return globalThis.__serein.readContext();})()")
  try check(toggled["sensitive"] as? Bool == true && toggled["text"] as? String == "",
    "Password-to-text is remembered before observer delivery")
  _ = try await tab.script("document.body.textContent='SEREIN_SYNTHETIC_PASSWORD';true")
  try await Task.sleep(nanoseconds: 20_000_000)
  let removed = try await result("globalThis.__serein.readContext()")
  try check(removed["sensitive"] as? Bool == true && removed["text"] as? String == "",
    "Removing a revealed password does not clear sensitive document history")

  try await load("<input id='field'>")
  let transient = try await result("(() => { const f=document.getElementById('field');f.type='password';f.type='text';return globalThis.__serein.probe();})()")
  try check(transient["steps"] as? Bool == true,
    "Transient password types are remembered even within one JavaScript turn")
  try await load("<input id='field'><p>Ordinary synthetic text.</p>")
  let ordinary = try await result("globalThis.__serein.readContext()")
  try check(ordinary["sensitive"] as? Bool == false, "New documents reset sensitive history")
  let valueOnly = try await result("(() => { document.getElementById('field').value='sk-proj-SEREIN_SYNTHETIC_TOKEN_1234567890';return globalThis.__serein.readContext();})()")
  try check(valueOnly["sensitive"] as? Bool == true && valueOnly["text"] as? String == "",
    "Secret field values are rescanned without an attribute mutation")

  try await load("<div id='host'></div><script>document.getElementById('host').attachShadow({mode:'open'}).innerHTML='<input name=\"access_token\" value=\"synthetic\">'</script>")
  let shadow = try await result("globalThis.__serein.probe()")
  try check(shadow["steps"] as? Bool == true, "Open shadow roots remain part of security scans")
  try await load("<div contenteditable='true' aria-label='Access token'>SEREIN_SYNTHETIC_EDITABLE_SECRET</div>")
  let editable = try await result("globalThis.__serein.readContext()")
  try check(editable["sensitive"] as? Bool == true && editable["text"] as? String == "",
    "Text-only reads preserve sensitive rich-text fields without enumerating action geometry")
  try await load("<input class='g-recaptcha'>")
  let captcha = try await result("globalThis.__serein.readContext()")
  try check((captcha["user_steps"] as? [String])?.contains("captcha") == true,
    "CAPTCHA classes on form controls retain their user-step kind")
  for illustration in [
    "<label>What is 3 + 4?<input></label><span hidden>CAPTCHA</span>",
    "<div style='opacity:0'><img width='80' height='40' alt='CAPTCHA'></div>",
    "<img hidden alt='CAPTCHA'>",
    "<img style='visibility:hidden' alt='CAPTCHA'>",
    "<article><figure><img width='80' height='40' alt='CAPTCHA example'></figure></article>"
  ] {
    try await load(illustration + "<form><label>Feedback<input></label><button>Send feedback</button></form>")
    let probe = try await result("(() => {const k=globalThis.__serein;return {challenge:k.challenge('')!==null,steps:k.readContext().user_steps};})()")
    try check(probe["challenge"] as? Bool == false && !(probe["steps"] as? [String] ?? []).contains("captcha"),
              "An illustration or hidden CAPTCHA image leaves the feedback form available")
  }
  try await load("<form><img width='100' height='40' alt='CAPTCHA'><label>Answer<input></label><button type='button'>New image</button><button>Verify</button></form>")
  let imageChallenge = try await result("""
    (() => {const k=globalThis.__serein, rows=k.read().elements;
      const blocks=label=>{const row=rows.find(x=>x.label===label);return !!row && k.challenge(row.ref)?.blocks===true;};
      return {field:blocks('Answer'),button:blocks('New image'),verify:blocks('Verify')};})()
    """)
  try check(imageChallenge["field"] as? Bool == true && imageChallenge["button"] as? Bool == true && imageChallenge["verify"] as? Bool == true,
            "A visible CAPTCHA hands its answer field and new-image button to the person")
  try await load("<form><img width='80' height='40' alt='CAPTCHA'></form><form><label>Answer<input></label><button>Verify</button></form>")
  let adjacentForms = try await result("""
    (() => {const k=globalThis.__serein, rows=k.read().elements;
      return {available:['Answer','Verify'].every(label=>{const row=rows.find(x=>x.label===label);
        return !!row && !k.challenge(row.ref)?.blocks;})};})()
    """)
  try check(adjacentForms["available"] as? Bool == true, "An inline challenge leaves the adjacent form's controls available")
  // X's composer keeps a hidden file input. The page is read and pictured; file inputs get no reference.
  try await load("<p>Synthetic draft post.</p><input type='file' data-testid='fileInput' style='display:none'><label>Photo <input type='file'></label><button>Post</button>")
  let upload = try await result("globalThis.__serein.read()")
  let uploadProbe = try await result("globalThis.__serein.probe()")
  let uploadRows = upload["elements"] as? [[String: Any]] ?? []
  try check((upload["text"] as? String)?.contains("Synthetic draft post.") == true
    && upload["sensitive"] as? Bool == false && uploadProbe["steps"] as? Bool == false
    && uploadRows.filter { $0["ref"] != nil }.map { $0["role"] as? String } == ["button"]
    && uploadRows.allSatisfy { $0["role"] as? String != "file" || ($0["ref"] == nil && ($0["acts"] as? [String] ?? []).isEmpty) },
    "A page with upload fields is read and pictured, and its file inputs get no reference")
  // The user's upload button opens a file panel; WebKit calls this only when the signature matches.
  try check(tab.responds(to: #selector(WKUIDelegate.webView(_:runOpenPanelWith:initiatedByFrame:completionHandler:))),
    "A page's upload button asks the tab for files")
  try await load("<iframe srcdoc=\"<input type='password'>\"></iframe>")
  try await Task.sleep(nanoseconds: 50_000_000)
  let inline = try await result("globalThis.__serein.probe()")
  try check(inline["steps"] as? Bool == true && inline["frames"] as? Int == 0,
    "Readable inline frames are checked directly and remain sensitive")
  try await load("<iframe sandbox srcdoc=\"<p>Unreadable synthetic frame.</p>\"></iframe>")
  try await Task.sleep(nanoseconds: 50_000_000)
  let frameCount = try await result("globalThis.__serein.probe()")
  try check(frameCount["frames"] as? Int == 1,
    "Unreadable sandboxed inline frames still count for the native fail-closed registry")

  // Covered controls: a person presses what the page draws, so the agent does too.
  func press(_ label: String, _ verb: String = "click", text: String = "") async throws -> [String: Any] {
    try await result("""
      (() => { const k=globalThis.__serein,row=k.read().elements.find(x=>x.label.includes(\(jsonString(label))));
        if(!row)return {error:'no row'};
        try{return k.act(\(jsonString(verb)),{ref:row.ref,text:\(jsonString(text))});}catch(err){return {error:String(err.message)};} })()
      """)
  }
  try await load("<style>.opt{position:relative;display:block;width:240px;height:80px;margin:8px}"
    + ".opt input{position:absolute;inset:0;opacity:0;margin:0}.opt span{position:absolute;inset:0;background:#eee}</style>"
    + "<label class='opt'><input type='radio' name='size' value='1tb'><span>1TB Buy from $1799</span></label>"
    + "<label class='opt'><input type='radio' name='size' value='2tb'><span>2TB Buy from $2399</span></label>")
  let card = try await press("2TB")
  let cardChecked = try await tab.script("document.querySelector('input[value=\"2tb\"]').checked") as? Bool
  try check(card["error"] == nil && cardChecked == true, "A radio under its own card is chosen (Apple's storage cards)")
  try await load("<input type='radio' id='silver' name='c' style='position:absolute;width:1px;height:1px;clip:rect(0 0 0 0);overflow:hidden'>"
    + "<p>Colour</p><label for='silver' style='display:block;width:40px;height:40px;border-radius:20px;background:#ccc'>Silver</label>")
  let swatch = try await press("Silver")
  let swatchChecked = try await tab.script("document.getElementById('silver').checked") as? Bool
  try check(swatch["via"] as? String == "label" && swatchChecked == true,
    "A clipped radio is chosen through its visible label (Apple's colour circles)")
  try await load("<div style='position:relative;width:260px'><input id='email' style='width:260px;height:44px'>"
    + "<label for='email' style='position:absolute;left:8px;top:12px;width:240px;height:20px'>Email</label></div>")
  let floating = try await press("Email", "type", text: "a@example.com")
  let typed = try await tab.script("document.getElementById('email').value") as? String
  try check(floating["error"] == nil && typed == "a@example.com", "A field under its floating label takes text")
  try await load("<div style='position:relative;width:300px'><button style='width:300px;height:44px'"
    + " onclick=\"document.body.dataset.pressed='yes'\">Wide button</button>"
    + "<span style='position:absolute;left:140px;top:0;width:24px;height:44px;background:red'></span></div>")
  let badge = try await press("Wide button")
  let pressed = try await tab.script("document.body.dataset.pressed ?? ''") as? String
  try check(badge["error"] == nil && pressed == "yes", "A button with a badge over its centre is pressed beside it")
  try await load("<a href='#product' aria-label='Product page' style='display:block;padding:20px'"
    + " onclick=\"document.body.dataset.link='yes';return false\"><button style='pointer-events:none'"
    + " onclick=\"document.body.dataset.cart='yes'\">Add to cart</button></a>")
  let wrapped = try await press("Add to cart")
  let cart = try await tab.script("document.body.dataset.cart ?? ''") as? String
  try check(wrapped["error"] == nil && cart == "yes", "A button inside a card link is pressed, not the link around it")
  try await load("<button onclick=\"document.body.dataset.pressed='yes'\">Continue</button>"
    + "<div role='dialog' aria-modal='true' style='position:fixed;inset:0;background:rgba(0,0,0,.4)'><p>Accept cookies</p></div>")
  let blocked = try await press("Continue")
  let notPressed = try await tab.script("document.body.dataset.pressed ?? ''") as? String
  try check((blocked["error"] as? String)?.contains("covered by \"Accept cookies\"") == true && notPressed == "",
    "A real cover is named and nothing under it is pressed")

  // Consequential-action readback must survive invalidation without reviving a stale ref.
  // This exercises FrameBridge with the exact synthetic intent; browser integration checks
  // separately obtain that intent by answering the real approval card.
  try await load("<label>Gift note<input id='note' aria-label='Gift note'></label><input autocomplete='cc-number'>")
  let notePage = try await result("globalThis.__serein.read()")
  let noteRef = (notePage["elements"] as? [[String: Any]])?.first { $0["label"] as? String == "Gift note" }?["ref"] as? String ?? ""
  let noteArgs: [String: Any] = ["ref": noteRef, "text": "Synthetic gift"]
  let noteLive = await tab.elementFacts(name: "type", arguments: noteArgs)
  let noteGate = ActionAdmission.action(name: "type", arguments: noteArgs, site: "127.0.0.1",
    pageVersion: tab.pageVersion, live: noteLive)
  let noteIntent = ApprovalGate.record(noteGate, effect: noteGate.effect ?? .unknown, mint: { UUID().uuidString })
  let noteAction = try await tab.frameAction(name: "type", arguments: noteArgs, binding: noteIntent) as? [String: Any]
  let noteValue = try await tab.script("document.getElementById('note').value") as? String
  let staleNote = await tab.elementFacts(name: "type", arguments: noteArgs)
  try check(noteIntent.effect == .pay && noteAction?["performed"] as? String == "type"
    && noteValue == "Synthetic gift" && !staleNote.connected,
    "Payment readback uses the acted-on element while the old action reference stays invalid")

  // A verification page can appear after the control was read. The private consequential
  // action must return the hand-off without typing or inventing a successful readback.
  try await load("<h1 id='verification' hidden>Verify you are human</h1>"
    + "<label>Gift note<input id='note' aria-label='Gift note' value='Original'"
    + " oninput=\"document.body.dataset.inputs=String(Number(document.body.dataset.inputs||0)+1)\"></label>"
    + "<input autocomplete='cc-number'>")
  let captchaPacket = try await tab.web.callAsyncJavaScript("""
    const k = globalThis.__serein;
    const clearBefore = k.challenge('') === null;
    const row = k.read().elements.find(x => x.label === 'Gift note');
    if (!row) throw Error('Synthetic gift-note control was not read');
    document.getElementById('verification').hidden = false;
    const packet = await k.actAndDescribe('type', {ref: row.ref, text: 'Must not be typed'});
    return {clearBefore, packet, value: document.getElementById('note').value,
      inputs: Number(document.body.dataset.inputs || 0)};
    """, arguments: [:], in: nil, contentWorld: BrowserTab.world) as? [String: Any] ?? [:]
  let refusedPacket = captchaPacket["packet"] as? [String: Any] ?? [:]
  let refusedAction = refusedPacket["result"] as? [String: Any] ?? [:]
  try check(captchaPacket["clearBefore"] as? Bool == true
    && refusedAction["needs_user"] as? Bool == true && refusedAction["reason"] as? String == "captcha"
    && refusedAction["performed"] == nil && refusedPacket["reading"] == nil
    && captchaPacket["value"] as? String == "Original" && captchaPacket["inputs"] as? Int == 0,
    "A newly blocking CAPTCHA prevents consequential input and returns no success readback")

  // The native bridge must recognize that refusal-only packet before requiring its absent
  // reading; callers need VerificationCheck, not a generic failed-readback error.
  let blockedPage = try await result("globalThis.__serein.read()")
  let blockedRef = (blockedPage["elements"] as? [[String: Any]])?.first { $0["label"] as? String == "Gift note" }?["ref"] as? String ?? ""
  let blockedArgs: [String: Any] = ["ref": blockedRef, "text": "Must still not be typed"]
  let blockedLive = await tab.elementFacts(name: "type", arguments: blockedArgs)
  let blockedGate = ActionAdmission.action(name: "type", arguments: blockedArgs, site: "127.0.0.1",
    pageVersion: tab.pageVersion, live: blockedLive)
  let blockedIntent = ApprovalGate.record(blockedGate, effect: blockedGate.effect ?? .unknown, mint: { UUID().uuidString })
  var verificationHost: String?
  var verificationError = ""
  do { _ = try await tab.frameAction(name: "type", arguments: blockedArgs, binding: blockedIntent) }
  catch {
    verificationHost = (error as? VerificationCheck)?.host
    verificationError = error.localizedDescription
  }
  let blockedValue = try await tab.script("document.getElementById('note').value") as? String
  let blockedInputs = try await tab.script("Number(document.body.dataset.inputs || 0)") as? Int
  try check(blockedIntent.effect == .pay && verificationHost == "127.0.0.1"
    && blockedValue == "Original" && blockedInputs == 0,
    "The consequential native readback path preserves the CAPTCHA hand-off without typing"
      + (verificationHost == nil ? " [\(verificationError)]" : ""))

  // A replacement can copy both the label and data-serein-bind; it is still another node.
  // Nested handler microtasks must finish before the private readback releases its handle.
  for (timing, handler) in [
    ("synchronous", "this.replaceWith(this.cloneNode(true))"),
    ("microtask", "queueMicrotask(()=>this.replaceWith(this.cloneNode(true)))"),
    ("nested microtask", "queueMicrotask(()=>queueMicrotask(()=>this.replaceWith(this.cloneNode(true))))"),
  ] {
    try await load("<button id='pay' onclick=\"\(handler)\">Pay $5</button>")
    let payPage = try await result("globalThis.__serein.read()")
    let payRef = (payPage["elements"] as? [[String: Any]])?.first?["ref"] as? String ?? ""
    let payArgs: [String: Any] = ["ref": payRef]
    let payLive = await tab.elementFacts(name: "click", arguments: payArgs)
    let payGate = ActionAdmission.action(name: "click", arguments: payArgs, site: "127.0.0.1",
      pageVersion: tab.pageVersion, live: payLive)
    let payIntent = ApprovalGate.record(payGate, effect: payGate.effect ?? .unknown, mint: { UUID().uuidString })
    var replacedFailure = ""
    do { _ = try await tab.frameAction(name: "click", arguments: payArgs, binding: payIntent) }
    catch { replacedFailure = error.localizedDescription }
    let replacementBind = try await tab.script("document.getElementById('pay').dataset.sereinBind") as? String
    try check(payIntent.effect == .pay && replacementBind == payIntent.elementID
      && replacedFailure == "Serein could not read back what that did, so it is not reporting it as done.",
      "Payment readback refuses a \(timing) replacement even when its label and binding match")
  }

  // Load-time reading: choice groups in one line, quiet despite animation, root-handled controls.
  try await load("<fieldset><legend>Finish</legend>"
    + "<label><input type='radio' name='finish' style='opacity:0'><span>Burgundy</span></label>"
    + "<label><input type='radio' name='finish' checked style='opacity:0'><span>Silver<span style='position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)'>Footnote</span></span></label>"
    + "<label><input type='radio' name='finish' disabled style='opacity:0'><span>Black</span></label></fieldset>")
  let summary = try await result("globalThis.__serein.read()")
  try check((summary["choices"] as? [String]) == ["Finish: Burgundy | [Silver] | Black (locked)"],
    "Choice groups read as one line with the pick and the locked options")
  try await load("<div id='spin' style='width:20px;height:20px'></div>"
    + "<script>let a=0;setInterval(()=>{document.getElementById('spin').style.transform='rotate('+(a+=7)+'deg)'},30)</script>")
  let quiet = try await tab.web.callAsyncJavaScript(
    "return await globalThis.__serein.settle(150, 3000);", arguments: [:], in: nil,
    contentWorld: BrowserTab.world) as? [String: Any] ?? [:]
  try check(quiet["settled"] as? Bool == true && ((quiet["waited_ms"] as? NSNumber)?.intValue ?? 9999) < 1000,
    "An animating page still counts as quiet")
  try await load("<div id='root'><div style='cursor:pointer'><span>Open menu</span></div><p>Plain text</p></div>"
    + "<script>document.getElementById('root').addEventListener('click',e=>{if(e.target.closest('[style]'))document.body.dataset.pressed='yes'})</script>")
  let rooted = try await result("(() => { const r=globalThis.__serein.read().elements; return {rows:r.map(x=>x.role+':'+x.label)}; })()")
  let rootedPress = try await press("Open menu")
  let rootedPressed = try await tab.script("document.body.dataset.pressed ?? ''") as? String
  try check((rooted["rows"] as? [String]) == ["clickable:Open menu"] && rootedPress["error"] == nil && rootedPressed == "yes",
    "A control handled on the page root is listed by its pointer and pressed")
  // A file field is the user's step for that field only; the rest of the form stays readable.
  try await load("<label>Name <input id='name'></label><label>Picture <input type='file'></label><p>Form text</p>")
  let form = try await result("(() => { const r=globalThis.__serein.read(); return {sensitive:r.sensitive,text:r.text,file:r.elements.filter(x=>x.role==='file').map(x=>String(!!x.ref)+':'+x.acts.length)}; })()")
  try check(form["sensitive"] as? Bool == false && (form["text"] as? String)?.contains("Form text") == true
    && (form["file"] as? [String]) == ["false:0"], "A file field is listed without a ref and does not hide the page")
  // The read counts the controls it looked at and the user's own it left out (synthetic fields only).
  try await load("<label>Email <input id='mail'></label><label>Password <input type='password'></label><button>Sign in</button>")
  let counted = try await result("(() => { const r=globalThis.__serein.read(); return {redaction:r.redaction,rows:r.elements.filter(x=>x.label==='Password')}; })()")
  let redaction = counted["redaction"] as? [String: Any]
  let passwordRows = counted["rows"] as? [[String: Any]] ?? []
  try check((redaction?["withheld"] as? Int ?? 0) >= 1 && (redaction?["inspected"] as? Int ?? 0) >= 3
    && passwordRows.count == 1 && passwordRows[0]["secure"] as? String == "password"
    && passwordRows[0]["acts"] as? [String] == ["secure_card"] && passwordRows[0]["value"] == nil,
    "A read counts the password field and lists only its secure-card action without a value")
  // Arrow keys step a number field, as a person's keys do.
  try await load("<label>Amount <input id='n' type='number' value='42'></label>")
  _ = try await result("(() => { const k=globalThis.__serein,row=k.read().elements[0];return k.act('key',{ref:row.ref,key:'ArrowUp'}); })()")
  let stepped = try await tab.script("document.getElementById('n').value") as? String
  try check(stepped == "43", "ArrowUp steps a number field")
  // Fields no one types into are no code step, whatever their names say (GitHub, Wikipedia).
  try await load("<form><input type='hidden' name='authenticity_token' value='OYxTT_os8zF2yc6g8bY-QgZsjdrLHf'>"
    + "<label><input type='radio' name='freq'>One time</label><label><input type='radio' name='freq'>Monthly</label></form><p>Releases</p>")
  let tokens = try await result("globalThis.__serein.read()")
  try check(tokens["sensitive"] as? Bool == false && (tokens["text"] as? String)?.contains("Releases") == true,
    "A hidden form token and a 'One time' radio do not make the page a code step")
  // A table header that sorts on click (a pointer th) is listed.
  try await load("<table><thead><tr><th style='cursor:pointer' onclick='1'><span>Due</span></th></tr></thead><tbody><tr><td>1</td></tr></tbody></table>")
  let header = try await result("(() => ({rows:globalThis.__serein.read().elements.map(x=>x.role+':'+x.label)}))()")
  try check((header["rows"] as? [String]) == ["clickable:Due"], "A sortable table header is listed")
  // The accessibility tree holds only roles PageAX knows: a date field, a slider and a list box
  // stay in the merged read; a link the tree does not have (aria-hidden) goes.
  let tree = PageAX.Tree(controls: [PageAX.Control(ref: "x1_1", role: "button", label: "Go", checked: nil,
    enabled: true, typed: false, center: CGPoint(x: 10, y: 10))], complete: true)
  let merged = PageAX.merge([
    ["ref": "a", "role": "button", "label": "Go", "acts": ["click"], "x": 10, "y": 10],
    ["ref": "b", "role": "input", "label": "Date", "acts": ["type"], "x": 50, "y": 50],
    ["ref": "c", "role": "input", "label": "Volume", "acts": ["click"], "x": 90, "y": 90],
    ["ref": "d", "role": "select", "label": "Size", "acts": ["select"], "x": 130, "y": 130],
    ["ref": "e", "role": "a", "label": "Hidden link", "acts": ["click"], "x": 170, "y": 170],
  ], tree)
  try check(merged.compactMap { $0["ref"] as? String } == ["a", "b", "c", "d"],
    "The accessibility read keeps form fields the tree has no role for")
  print("PASS: \(checks) synthetic PageKit context, mutation, sensitive-field and frame checks")
}

/// `--probe-page <url> [label ...]`: how reading and acting hold up on a real (heavy) page. Opens it
/// in an isolated agent tab and prints the time of each part: open with the ready wait, PageKit's
/// read, the accessibility read (SEREIN_AX=1), the merged read, each press of a named option (label
/// prefix; nothing else is pressed) with its ready wait and page after, and an idle ready wait.
@MainActor func probePage(_ url: String, labels: [String]) async throws {
  let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SEREIN_DATA_DIR"] ?? NSTemporaryDirectory())
  let browser = try BrowserModel(root: root)
  defer { browser.shutdown() }
  let task = try browser.beginTask(isolated: true, allowActions: true, includeCurrent: false)
  func call(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
    try await browser.handle(["task": task.capability.task, "token": task.capability.token, "name": name, "arguments": args])
  }
  func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
  var t = Date()
  let id = try await call("open_tab", ["url": url])["tab"] as? String ?? ""
  print("open + ready: \(ms(t)) ms")
  guard let tab = browser.tasks[task.capability.task]?.tabs.first(where: { $0.id == id }) else {
    throw SereinError.invalid("The tab did not open.")
  }
  for pass in 1...2 {
    t = Date()
    let kit = try await tab.frameOutline(start: 0, frameID: nil)
    let kitMs = ms(t)
    t = Date()
    let tree = await PageAX.controls(tab)
    let treeMs = ms(t)
    t = Date()
    let page = try await call("read", ["tab": id])
    let rows = page["elements"] as? [[String: Any]] ?? []
    print("read \(pass): PageKit \((kit["elements"] as? [Any])?.count ?? 0) rows in \(kitMs) ms; tree \(tree.map { "\($0.controls.count) controls\($0.complete ? "" : " (partial)")" } ?? "off") in \(treeMs) ms; merged \(rows.count) rows (\(rows.filter { ($0["ref"] as? String)?.hasPrefix("x") == true }.count) from the tree, \(rows.filter { $0["role"] as? String == "clickable" }.count) clickable) in \(ms(t)) ms; text \((page["text"] as? String)?.count ?? 0) chars")
    for line in page["choices"] as? [String] ?? [] { print("  choice  \(line)") }
    try await Task.sleep(nanoseconds: 300_000_000)
  }
  for label in labels {
    let rows = (try await call("read", ["tab": id]))["elements"] as? [[String: Any]] ?? []
    // Pages put no-break spaces in names ("iPhone\u{a0}18"); compare words only.
    func words(_ s: String) -> String { s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
    guard let row = rows.first(where: { words($0["label"] as? String ?? "").hasPrefix(words(label)) }),
      let ref = row["ref"] as? String
    else { print("press \"\(label)\": not listed"); continue }
    t = Date()
    do {
      let r = try await call("click", ["tab": id, "ref": ref])
      print("press \"\(label)\" (\(row["role"] ?? "")): \(ms(t)) ms with ready wait and page after, via \((r["result"] as? [String: Any])?["via"] ?? "pagekit")")
      for line in (r["page"] as? [String: Any])?["choices"] as? [String] ?? [] { print("  choice  \(line)") }
    } catch { print("press \"\(label)\": \(error.localizedDescription) after \(ms(t)) ms") }
  }
  // A ready wait with nothing happening: what constant requests and animation cost on this page.
  t = Date()
  await tab.settle(limit: 3)
  print("idle ready wait: \(ms(t)) ms")
  // SEREIN_PROBE_FIRST=<second url>: how long until the tree answers for a new page in this tab
  // and for a new tab, reading every 50 ms.
  if let second = ProcessInfo.processInfo.environment["SEREIN_PROBE_FIRST"] {
    func firstTree(_ what: String, _ tab: BrowserTab, since: Date) async {
      for _ in 0..<100 {
        if let tree = await PageAX.controls(tab), !tree.controls.isEmpty {
          print("first tree, \(what): \(ms(since)) ms after the page was ready (\(tree.controls.count) controls)")
          return
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
      }
      print("first tree, \(what): none within 5 s")
    }
    t = Date()
    _ = try await call("navigate", ["tab": id, "url": second])
    print("navigate + ready: \(ms(t)) ms")
    await firstTree("same tab, new page", tab, since: Date())
    t = Date()
    let other = try await call("open_tab", ["url": second])["tab"] as? String ?? ""
    print("new tab open + ready: \(ms(t)) ms")
    if let newTab = browser.tasks[task.capability.task]?.tabs.first(where: { $0.id == other }) {
      await firstTree("new tab", newTab, since: Date())
    }
  }
}
#endif
