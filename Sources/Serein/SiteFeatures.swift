import CoreLocation
import SereinCore
import SwiftUI
import UserNotifications
import WebKit

/// Per-site choices for location, notifications and autoplay, beside the older camera and
/// microphone key. Keyed `serein.site.<feature>.<origin>`, all in one map in GateSettings
/// (`SitePermissions.gateKey`): an allow is a person's consent. While that file cannot be read
/// no site has an allow, so each asks again. Camera and microphone (`serein.media.`, deny or ask,
/// never allow) stay in UserDefaults. Nothing about a private or agent tab is ever read from or
/// written to either.
@MainActor final class SitePermissionStore: ObservableObject {
  static let shared = SitePermissionStore()
  @Published private(set) var entries: [SitePermissionEntry] = []
  init() { reload() }
  /// The `serein.site.` choices, by key.
  private var siteChoices: [String: String] {
    (GateSettings.shared.dictionary(forKey: SitePermissions.gateKey) ?? [:]).compactMapValues { $0 as? String }
  }
  func reload() {
    let media = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix(SitePermissions.mediaDefaultsPrefix) }
    entries = SitePermissions.entries(in: media.merging(siteChoices as [String: Any]) { kept, _ in kept })
  }
  func value(_ feature: SiteFeature, origin: String) -> String? {
    let key = SitePermissions.key(feature, origin: origin)
    return feature == .media ? UserDefaults.standard.string(forKey: key) : siteChoices[key]
  }
  func set(_ feature: SiteFeature, origin: String, value: String) {
    store(SitePermissions.key(feature, origin: origin), value)
    reload()
  }
  func forget(_ entry: SitePermissionEntry) {
    store(entry.key, nil)
    reload()
  }
  func forgetAll() {
    for entry in entries { store(entry.key, nil) }
    reload()
  }
  private func store(_ key: String, _ value: String?) {
    guard !key.hasPrefix(SitePermissions.mediaDefaultsPrefix) else {
      UserDefaults.standard.set(value, forKey: key)
      return
    }
    var choices = siteChoices
    choices[key] = value
    GateSettings.shared.set(choices, forKey: SitePermissions.gateKey)
  }
}

/// The page-side half: geolocation, notifications and autoplay talk to Serein through one
/// message handler. Private and agent tabs get the same script in deny mode and no handler.
enum SiteFeatureScript {
  static func source(deny: Bool) -> String {
    """
    (()=>{try{
    const DENY=\(deny ? "true" : "false");
    const previous=window.__sereinSite;
    if(previous&&previous.deny===DENY)return;
    if(previous){previous.watchers.forEach(clearInterval);document.removeEventListener('play',previous.listener,true);HTMLMediaElement.prototype.play=previous.play;}
    const state={deny:DENY};
    Object.defineProperty(window,'__sereinSite',{value:state,configurable:true});
    const post=(kind,extra)=>{try{return webkit.messageHandlers.sereinSite.postMessage(Object.assign({kind},extra||{}))}catch(e){return Promise.reject(e)}};
    const failure=(code,message)=>({code,message,PERMISSION_DENIED:1,POSITION_UNAVAILABLE:2,TIMEOUT:3});
    const locate=(ok,bad)=>{(DENY?Promise.resolve({ok:false,code:1,message:'User denied Geolocation'}):post('geo')).then(r=>{
      if(r&&r.ok){ok&&ok({coords:{latitude:r.lat,longitude:r.lon,accuracy:r.acc,altitude:null,altitudeAccuracy:null,heading:null,speed:null},timestamp:r.ts})}
      else{bad&&bad(failure((r&&r.code)||2,(r&&r.message)||'Position unavailable'))}},()=>{bad&&bad(failure(2,'Position unavailable'))})};
    let watchId=0;const watchers=new Map();state.watchers=watchers;
    const geo={getCurrentPosition(ok,bad){locate(ok,bad)},
      watchPosition(ok,bad){const id=++watchId;const stop=e=>{if(e&&e.code===1){clearInterval(watchers.get(id));watchers.delete(id)}bad&&bad(e)};
        watchers.set(id,setInterval(()=>locate(ok,stop),15000));locate(ok,stop);return id},
      clearWatch(id){clearInterval(watchers.get(id));watchers.delete(id)}};
    try{Object.defineProperty(Navigator.prototype,'geolocation',{get(){return geo},configurable:true})}catch(_){}
    if(!DENY){
      let perm='default';post('notifState').then(v=>{perm=v}).catch(()=>{});
      class SereinNotification extends EventTarget{
        constructor(title,options){super();options=options||{};this.title=String(title);this.body=String(options.body||'');
          this.onclick=null;this.onshow=null;this.onclose=null;this.onerror=null;
          if(perm==='granted')post('notify',{title:this.title,body:this.body}).catch(()=>{})}
        close(){}
        static get permission(){return perm}
        static get maxActions(){return 0}
        static requestPermission(cb){const p=post('notifRequest').then(v=>(perm=v));if(typeof cb==='function')p.then(cb);return p}}
      try{Object.defineProperty(window,'Notification',{value:SereinNotification,configurable:true,writable:true})}catch(_){}
    }
    let policy=DENY?'block':'muted';
    if(!DENY)post('autoplay').then(v=>{policy=v}).catch(()=>{});
    const acted=()=>{try{return !!(navigator.userActivation&&navigator.userActivation.hasBeenActive)}catch(_){return false}};
    const blocked=el=>{if(acted()||policy==='allow')return false;if(policy==='block')return true;return !el.muted};
    const play=HTMLMediaElement.prototype.play;state.play=play;
    HTMLMediaElement.prototype.play=function(){if(blocked(this))return Promise.reject(new DOMException('Autoplay is blocked for this site.','NotAllowedError'));return play.apply(this,arguments)};
    state.listener=e=>{const t=e.target;if(t instanceof HTMLMediaElement&&blocked(t))t.pause()};document.addEventListener('play',state.listener,true);
    }catch(_){}})();
    """
  }
}

extension BrowserTab {
  /// Screen capture is always refused. Notifications are refused here only in tabs that never get the
  /// site-feature bridge (private and agent tabs); other tabs ask per site.
  static func baseShim(denyNotifications: Bool) -> String {
    let notification =
      denyNotifications
      ? "try{Object.defineProperty(window,'Notification',{value:class {static permission='denied';static requestPermission(){return Promise.resolve('denied')}},configurable:true})}catch(_){};"
      : ""
    // A closed shadow root hides its fields from PageKit; its host is marked so pictures of a page
    // with the user's own fields can refuse it (PageKit.js `unseen`).
    let closedRoots =
      "try{const a=Element.prototype.attachShadow;Element.prototype.attachShadow=function(o){const r=a.call(this,o);try{if(o&&o.mode==='closed')this.setAttribute('data-serein-closed','')}catch(_){}return r}}catch(_){};"
    return
      "(()=>{\(notification)\(closedRoots)try{if(navigator.mediaDevices)navigator.mediaDevices.getDisplayMedia=()=>Promise.reject(new DOMException('Screen capture unavailable','NotAllowedError'))}catch(_){}})();"
  }
  /// The address a person should see: a blank page has none.
  static func visibleAddress(_ url: URL?) -> String {
    guard let value = url?.absoluteString, value != "about:blank" else { return "" }
    return value
  }
}

@MainActor final class SiteFeatureBridge: NSObject, WKScriptMessageHandlerWithReply {
  weak var tab: BrowserTab?
  private var asking: [String: [CheckedContinuation<String, Never>]] = [:]
  /// "Not now" answers, by feature and site: not asked again until Serein quits.
  private static var notNow = Set<String>()
  private var recentNotifications: [String: [Date]] = [:]
  init(tab: BrowserTab) { self.tab = tab }

  static func install(on tab: BrowserTab, controller: WKUserContentController) {
    let deny = !SitePermissions.tabMayPrompt(isPrivate: tab.privateMode, isAgentTab: tab.owner != nil)
    controller.addUserScript(
      WKUserScript(
        source: SiteFeatureScript.source(deny: deny), injectionTime: .atDocumentStart,
        forMainFrameOnly: false))
    if !deny {
      controller.addScriptMessageHandler(
        SiteFeatureBridge(tab: tab), contentWorld: .page, name: "sereinSite")
    }
  }

  /// Replace the agent-only shims without reloading or losing form state.
  static func adopt(_ tab: BrowserTab) {
    guard !tab.privateMode, tab.owner == nil else { return }
    let controller = tab.web.configuration.userContentController
    let old = Set([SiteFeatureScript.source(deny: true), SiteFeatureScript.source(deny: false),
                   BrowserTab.baseShim(denyNotifications: true), BrowserTab.baseShim(denyNotifications: false)])
    let kept = controller.userScripts.filter { !old.contains($0.source) }
    controller.removeAllUserScripts()
    for script in kept { controller.addUserScript(script) }
    controller.addUserScript(WKUserScript(
      source: BrowserTab.baseShim(denyNotifications: false), injectionTime: .atDocumentStart,
      forMainFrameOnly: false))
    controller.removeScriptMessageHandler(forName: "sereinSite", contentWorld: .page)
    install(on: tab, controller: controller)
    Task {
      let source = SiteFeatureScript.source(deny: false)
      _ = try? await tab.web.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .page)
      for frame in tab.frames.values where !frame.isMainFrame {
        _ = try? await tab.web.callAsyncJavaScript(source, arguments: [:], in: frame, contentWorld: .page)
      }
    }
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) async -> (Any?, String?) {
    guard let tab, SitePermissions.tabMayPrompt(isPrivate: tab.privateMode, isAgentTab: tab.owner != nil),
      let body = message.body as? [String: Any], let kind = body["kind"] as? String
    else { return (nil, "Unavailable") }
    // The requesting site is the frame's own origin as WebKit reports it, never a page-supplied value.
    let frameOrigin = message.frameInfo.securityOrigin
    guard ["http", "https"].contains(frameOrigin.protocol), !frameOrigin.host.isEmpty else {
      return (nil, "Unavailable")
    }
    let requester = SitePermissions.origin(
      scheme: frameOrigin.protocol, host: frameOrigin.host, port: frameOrigin.port)
    let top = tab.web.url
    let topOrigin = SitePermissions.origin(
      scheme: top?.scheme ?? "", host: top?.host ?? "", port: top?.port ?? 0)
    // Embedded frames never get location or notifications; only the page the person sees asks.
    let granted = SitePermissions.grantKey(
      topOrigin: topOrigin, requester: requester, isMainFrame: message.frameInfo.isMainFrame)
    let store = SitePermissionStore.shared
    switch kind {
    case "geo":
      guard let origin = granted else {
        return (["ok": false, "code": 1, "message": "User denied Geolocation"], nil)
      }
      var choice = store.value(.geolocation, origin: origin) ?? "ask"
      if choice == "ask" {
        choice = await ask(
          .geolocation, origin: origin, frame: message.frameInfo,
          question: "wants to know your location",
          detail: "It will get your approximate position from this Mac, only while you use the page.")
      }
      guard choice == "allow" else {
        return (["ok": false, "code": 1, "message": "User denied Geolocation"], nil)
      }
      return (await LocationProvider.shared.current(), nil)
    case "notifState":
      guard let origin = granted else { return ("denied", nil) }
      switch store.value(.notifications, origin: origin) {
      case "allow": return ("granted", nil)
      case "block": return ("denied", nil)
      default: return ("default", nil)
      }
    case "notifRequest":
      guard let origin = granted else { return ("denied", nil) }
      var choice = store.value(.notifications, origin: origin) ?? "ask"
      if choice == "ask" {
        choice = await ask(
          .notifications, origin: origin, frame: message.frameInfo,
          question: "wants to send you notifications",
          detail: "They appear in Notification Center. You can turn this off in Settings, under Privacy.")
      }
      return (choice == "allow" ? "granted" : choice == "block" ? "denied" : "default", nil)
    case "notify":
      guard let origin = granted, store.value(.notifications, origin: origin) == "allow",
        SitePermissions.notificationAllowed(recent: recentNotifications[origin] ?? [])
      else { return (false, nil) }
      recentNotifications[origin, default: []].append(Date())
      recentNotifications[origin] = recentNotifications[origin]?.suffix(10).map { $0 }
      post(
        title: String((body["title"] as? String ?? "").prefix(100)),
        body: String((body["body"] as? String ?? "").prefix(300)), host: frameOrigin.host)
      return (true, nil)
    case "autoplay":
      // Autoplay follows the page the person is looking at, not an embedded frame.
      let top = tab.web.url
      let key = SitePermissions.origin(
        scheme: top?.scheme ?? "", host: top?.host ?? "", port: top?.port ?? 0)
      return (store.value(.autoplay, origin: key) ?? "muted", nil)
    default: return (nil, "Unknown request")
    }
  }

  /// Asks only right after the person interacted with the page (transient activation, read in
  /// Serein's own script world so the page cannot fake it), and not again for a site that got
  /// "Not now" this session. Otherwise the answer is "ask", which the page sees as a refusal.
  private func ask(
    _ feature: SiteFeature, origin: String, frame: WKFrameInfo, question: String, detail: String
  ) async -> String {
    let key = feature.rawValue + "|" + origin
    if Self.notNow.contains(key) { return "ask" }
    if asking[key] != nil {
      return await withCheckedContinuation { asking[key]?.append($0) }
    }
    guard let tab else { return "ask" }
    let active =
      (try? await tab.web.callAsyncJavaScript(
        "return !!(navigator.userActivation && navigator.userActivation.isActive);",
        arguments: [:], in: frame, contentWorld: .defaultClient)) as? Bool ?? false
    guard active else { return "ask" }
    return await prompt(feature, key: key, origin: origin, question: question, detail: detail)
  }

  /// Asks once per site and feature at a time; later asks for the same thing wait for the answer.
  /// The question is a sheet on the requesting tab's own window and names the tab. A tab that is
  /// not on screen waits until it is (two minutes at most); there is never an app-wide dialog.
  private func prompt(
    _ feature: SiteFeature, key: String, origin: String, question: String, detail: String
  ) async -> String {
    asking[key] = []
    var answer = "ask"
    var waited = 0
    while let tab, Self.window(showing: tab) == nil, waited < 240 {
      try? await Task.sleep(nanoseconds: 500_000_000)
      waited += 1
    }
    if let tab, let window = Self.window(showing: tab) {
      let alert = NSAlert()
      alert.messageText = "\(URL(string: origin)?.host ?? origin) \(question)"
      let name = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
      alert.informativeText =
        (name.isEmpty ? "" : "Asked by the tab \u{201C}\(String(name.prefix(80)))\u{201D}. ") + detail
      alert.addButton(withTitle: "Allow")
      alert.addButton(withTitle: "Block")
      alert.addButton(withTitle: "Not now")
      let response = await withCheckedContinuation { continuation in
        alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
      }
      answer =
        response == .alertFirstButtonReturn
        ? "allow" : response == .alertSecondButtonReturn ? "block" : "ask"
      if answer == "ask" { Self.notNow.insert(key) }
    }
    if answer != "ask" { SitePermissionStore.shared.set(feature, origin: origin, value: answer) }
    for waiter in asking.removeValue(forKey: key) ?? [] { waiter.resume(returning: answer) }
    return answer
  }

  /// The window where this tab's page is on screen now, if any.
  private static func window(showing tab: BrowserTab) -> NSWindow? {
    guard let window = tab.web.window, window.isVisible, !window.isMiniaturized,
      !tab.web.isHiddenOrHasHiddenAncestor, window.attachedSheet == nil
    else { return nil }
    return window
  }

  private func post(title: String, body: String, host: String) {

    guard TaskNotifications.shared.supported else { return }
    let content = UNMutableNotificationContent()
    content.title = title.isEmpty ? host : title
    content.subtitle = title.isEmpty ? "" : host
    content.body = body
    let request = UNNotificationRequest(
      identifier: "serein.web." + UUID().uuidString, content: content, trigger: nil)
    Task {
      let center = UNUserNotificationCenter.current()
      guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
      try? await center.add(request)
    }
  }
}

/// One position fix from the system, for a site the person has allowed.
@MainActor final class LocationProvider: NSObject, CLLocationManagerDelegate {
  static let shared = LocationProvider()
  private var manager: CLLocationManager?
  private var waiters: [CheckedContinuation<[String: Any], Never>] = []
  private var timeout: Task<Void, Never>?
  private func fail(_ code: Int, _ message: String) -> [String: Any] {
    ["ok": false, "code": code, "message": message]
  }
  func current() async -> [String: Any] {
    // Location needs a bundled app with the usage string in its Info.plist.
    guard TaskNotifications.shared.supported else {
      return fail(2, "Location is only available in the packaged app.")
    }
    return await withCheckedContinuation { continuation in
      waiters.append(continuation)
      guard waiters.count == 1 else { return }
      let manager = CLLocationManager()
      manager.delegate = self
      manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
      self.manager = manager
      timeout = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        if !Task.isCancelled { self?.finish(self?.fail(3, "Location took too long.") ?? [:]) }
      }
      begin(manager)
    }
  }
  private func begin(_ manager: CLLocationManager) {
    switch manager.authorizationStatus {
    case .notDetermined: manager.requestWhenInUseAuthorization()
    case .authorized, .authorizedAlways: manager.requestLocation()
    default:
      finish(fail(1, "Location is off for Serein. Turn it on in System Settings, under Privacy."))
    }
  }
  private func finish(_ result: [String: Any]) {
    timeout?.cancel()
    let list = waiters
    waiters = []
    manager?.delegate = nil
    manager = nil
    for waiter in list { waiter.resume(returning: result) }
  }
  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    Task { @MainActor in
      guard self.manager === manager, manager.authorizationStatus != .notDetermined else { return }
      self.begin(manager)
    }
  }
  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let place = locations.last else { return }
    Task { @MainActor in
      self.finish([
        "ok": true, "lat": place.coordinate.latitude, "lon": place.coordinate.longitude,
        "acc": max(place.horizontalAccuracy, 0), "ts": place.timestamp.timeIntervalSince1970 * 1000,
      ])
    }
  }
  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    Task { @MainActor in self.finish(self.fail(2, "Position unavailable.")) }
  }
}
