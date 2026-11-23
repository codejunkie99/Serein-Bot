import SereinCore
import SwiftUI
import WebKit

/// Certificates the person chose to open despite a problem, kept until quit and never saved.
/// Private tabs keep their own exceptions (on the tab), so nothing carries over to or from them.
@MainActor final class TrustStore {
  static let shared = TrustStore()
  var exceptions = TrustExceptions()
}

/// A pending HTTP Basic/Digest sign-in request. Completes exactly once.
final class AuthPrompt: Identifiable {
  let id = UUID()
  let host: String
  let realm: String?
  let retry: Bool
  let remember: Bool
  private var completion: ((URLCredential?) -> Void)?
  init(host: String, realm: String?, retry: Bool, remember: Bool, completion: @escaping (URLCredential?) -> Void) {
    self.host = host
    self.realm = realm
    self.retry = retry
    self.remember = remember
    self.completion = completion
  }
  func submit(user: String, password: String) {
    finish(URLCredential(user: user, password: password, persistence: remember ? .forSession : .none))
  }
  func cancel() { finish(nil) }
  private func finish(_ credential: URLCredential?) {
    let done = completion
    completion = nil
    done?(credential)
  }
}

/// Per-tab state for the browser basics. Held by BrowserTab so Browser.swift stays small.
@MainActor final class TabExtras: ObservableObject {
  @Published var canGoBack = false
  @Published var canGoForward = false
  @Published var crashed = false
  @Published var errorPage: ErrorPageCopy?
  @Published var failedURL: URL?
  @Published var auth: AuthPrompt?
  @Published var pinned = false
  @Published var findVisible = false
  @Published var findQuery = ""
  @Published var findCount = 0
  @Published var findIndex = 0
  @Published var findMatched = false
  /// The last certificate that failed evaluation, offered to "Visit anyway".
  var rejectedCertificate: (host: String, port: Int, fingerprint: String)?
  /// Exceptions for a private tab; they end with the tab.
  var privateExceptions = TrustExceptions()
  /// The chain and reason of the last failed certificate, for "Show certificate".
  var rejectedChain: [SecCertificate] = []
  var rejectedReason: String?
  @Published var findFocus = 0
  private var observations: [NSKeyValueObservation] = []
  private weak var boundWeb: WKWebView?

  func bind(_ web: WKWebView) {
    boundWeb = web
    web.isInspectable = UserDefaults.standard.bool(forKey: "serein.develop")
    observations = [
      web.observe(\.canGoBack, options: [.initial, .new]) { [weak self] w, _ in
        Task { @MainActor in self?.refreshHistory(from: w) }
      },
      web.observe(\.canGoForward, options: [.initial, .new]) { [weak self] w, _ in
        Task { @MainActor in self?.refreshHistory(from: w) }
      },
    ]
  }
  func refreshHistory(from web: WKWebView) {
    guard boundWeb === web else { return }
    if canGoBack != web.canGoBack { canGoBack = web.canGoBack }
    if canGoForward != web.canGoForward { canGoForward = web.canGoForward }
  }
  func showError(_ page: ErrorPageCopy, url: URL?) {
    errorPage = page
    failedURL = url
  }
  func clearError() {
    if errorPage != nil { errorPage = nil }
    if failedURL != nil { failedURL = nil }
  }
  func present(_ prompt: AuthPrompt) {
    auth?.cancel()
    auth = prompt
  }
  func finishAuth() { auth = nil }
}

extension BrowserTab {
  func webView(
    _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    let space = challenge.protectionSpace
    switch space.authenticationMethod {
    case NSURLAuthenticationMethodServerTrust:
      guard let trust = space.serverTrust else {
        completionHandler(.performDefaultHandling, nil)
        return
      }
      var trustError: CFError?
      if SecTrustEvaluateWithError(trust, &trustError) {
        completionHandler(.performDefaultHandling, nil)
      } else {
        let fingerprint = Self.leafFingerprint(trust)
        if owner == nil, let fingerprint,
          certificateAllowed(host: space.host, port: space.port, fingerprint: fingerprint)
        {
          completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
          ext.rejectedCertificate = fingerprint.map { (space.host, space.port, $0) }
          ext.rejectedChain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
          ext.rejectedReason = trustError.map { CFErrorCopyDescription($0) as String }
          // Default handling rejects the trust, so the load fails with the real certificate
          // error code (cancelling would report "cancelled" and show nothing).
          completionHandler(.performDefaultHandling, nil)
        }
      }
    case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest:
      guard owner == nil, space.proxyType == nil else {
        completionHandler(.rejectProtectionSpace, nil)
        return
      }
      let prompt = AuthPrompt(
        host: space.host, realm: space.realm, retry: challenge.previousFailureCount > 0,
        remember: !privateMode
      ) { [weak self] credential in
        Task { @MainActor in self?.ext.finishAuth() }
        completionHandler(credential == nil ? .cancelAuthenticationChallenge : .useCredential, credential)
      }
      ext.present(prompt)
    default:
      completionHandler(.performDefaultHandling, nil)
    }
  }
  static func leafFingerprint(_ trust: SecTrust) -> String? {
    guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first
    else { return nil }
    return TrustExceptions.fingerprint(SecCertificateCopyData(leaf) as Data)
  }
  func certificateAllowed(host: String, port: Int, fingerprint: String) -> Bool {
    let list = privateMode ? ext.privateExceptions : TrustStore.shared.exceptions
    return list.isAllowed(host: host, port: port, fingerprint: fingerprint)
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard web === webView else { return }
    loading = false
    ext.crashed = true
  }
  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    guard web === webView else { return }
    documentCommitted = true
    formResult = formPending
    formPending = false
    frameForms.removeAll()
    error = nil
    ext.clearError()
    ext.crashed = false
    // Every committed load starts a fresh console log, including back/forward, cached pages
    // and documents where the watcher script never runs (PDFs, images, plain text).
    ConsoleWatchStore.shared.reset(id)
    applyStoredZoom()
  }
  /// Opens the failed address after the person accepts a certificate problem for this host.
  func continueAnyway() {
    guard let url = ext.failedURL, let host = url.host, let rejected = ext.rejectedCertificate,
      rejected.host.lowercased() == host.lowercased(), rejected.port == (url.port ?? 443)
    else { return }
    if privateMode {
      ext.privateExceptions.allow(host: host, port: rejected.port, fingerprint: rejected.fingerprint)
    } else {
      TrustStore.shared.exceptions.allow(
        host: host, port: rejected.port, fingerprint: rejected.fingerprint)
    }
    error = nil
    ext.clearError()
    web.load(URLRequest(url: url))
  }
  func retryFailed() {
    if let url = ext.failedURL {
      error = nil
      ext.clearError()
      web.load(URLRequest(url: url))
    } else {
      web.reload()
    }
  }
  /// True for a page with the person's password, one-time-code or card fields, a source view, or a
  /// site set to Never. Page text is then not stored.
  func pageIsSensitive() async -> Bool {
    if hiddenFromAgents { return true }
    return await hasUserSteps()
  }
}

// MARK: - Overlays shown above the page

struct PageOverlays: View {
  @ObservedObject var tab: BrowserTab
  @ObservedObject var ext: TabExtras
  @Environment(\.palette) var p
  var body: some View {
    ZStack(alignment: .top) {
      if tab.error != nil, let page = ext.errorPage { ErrorPage(tab: tab, page: page) }
      if ext.crashed {
        HStack(spacing: 10) {
          InterfaceIcon(systemName: "exclamationmark.triangle", size: 14).foregroundStyle(p.warning)
          Text("This page stopped responding.")
          Spacer()
          Button("Reload") { tab.web.reload() }.buttonStyle(PrimaryButton())
        }.font(UIStyle.body).padding(.horizontal, 14).padding(.vertical, 8)
          .background(p.panel).overlay(alignment: .bottom) { Divider().overlay(p.line) }
          .accessibilityElement(children: .combine)
      }
      if ext.findVisible {
        HStack {
          Spacer()
          FindBar(tab: tab, ext: ext).padding(.top, ext.crashed ? 52 : 10).padding(.trailing, 12)
        }
      }
      if let prompt = ext.auth { AuthSheet(prompt: prompt, ext: ext) }
    }
  }
}

struct ErrorPage: View {
  @ObservedObject var tab: BrowserTab
  let page: ErrorPageCopy
  @State private var showCertificate = false
  @Environment(\.palette) var p
  var certificate: CertificateSummary? {
    guard page.kind == .certificate, let host = tab.ext.failedURL?.host,
      tab.ext.rejectedCertificate?.host.lowercased() == host.lowercased()
    else { return nil }
    return CertificateSummary(chain: tab.ext.rejectedChain, host: host, reason: tab.ext.rejectedReason)
  }
  var body: some View {
    VStack(spacing: 14) {
      let tint = page.kind == .certificate ? p.warning : p.accent
      Image(systemName: page.symbol).resizable().scaledToFit().frame(width: 28, height: 28)
        .foregroundStyle(tint).frame(width: 56, height: 56).background(tint.opacity(0.12), in: Circle())
        .accessibilityHidden(true)
      Text(page.title).role(.title).multilineTextAlignment(.center)
      Text(page.detail).role(.reading).foregroundStyle(p.secondary).multilineTextAlignment(.center).frame(
        maxWidth: 460)
      HStack(spacing: 10) {
        if page.kind == .certificate, page.canContinue {
          if tab.ext.canGoBack { Button("Go back") { tab.web.goBack() }.buttonStyle(PrimaryButton()) }
          Button("Visit anyway") { tab.continueAnyway() }.buttonStyle(QuietButton())
          if certificate != nil {
            Button("Show certificate") { showCertificate = true }.buttonStyle(QuietButton())
          }
        } else {
          Button("Try again") { tab.retryFailed() }.buttonStyle(PrimaryButton())
        }
      }
      if page.canContinue, let host = tab.ext.failedURL?.host {
        Text(
          "Visiting anyway trusts this one certificate for \(host) \(tab.privateMode ? "until you close this tab" : "until you quit Serein"). Avoid entering passwords there."
        )
          .role(.meta).frame(maxWidth: 420)
          .multilineTextAlignment(.center)
      }
    }.padding(32).frame(maxWidth: 520)
      .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
      .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(p.background)
      .sheet(isPresented: $showCertificate) {
        if let summary = certificate {
          CertificateSheet(summary: summary) { showCertificate = false }.environment(\.palette, p)
        }
      }
  }
}

struct AuthSheet: View {
  let prompt: AuthPrompt
  @ObservedObject var ext: TabExtras
  @State private var user = ""
  @State private var password = ""
  @Environment(\.palette) var p
  var body: some View {
    ZStack {
      p.scrim
      VStack(alignment: .leading, spacing: 12) {
        Text("Sign in to \(prompt.host)").role(.section)
        Text(
          (prompt.realm.map { "“\($0)” asks for a name and password." }
            ?? "This site asks for a name and password.")
            + (prompt.retry ? " The last attempt was not accepted." : "")
        ).role(.meta).fixedSize(horizontal: false, vertical: true)
        TextField("Name", text: $user).textFieldStyle(.serein)
        SecureField("Password", text: $password).textFieldStyle(.serein).onSubmit(submit)
        HStack {
          Spacer()
          Button("Cancel") { prompt.cancel() }.buttonStyle(QuietButton()).keyboardShortcut(
            .cancelAction)
          Button("Sign in", action: submit).buttonStyle(PrimaryButton()).keyboardShortcut(
            .defaultAction
          ).disabled(user.isEmpty)
        }
      }.padding(24).frame(width: UIStyle.wide(360)).background(
        p.overlay, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius)
      ).overlay(RoundedRectangle(cornerRadius: UIStyle.panelRadius).stroke(p.borderStrong))
    }.id(prompt.id)
  }
  func submit() {
    guard !user.isEmpty else { return }
    prompt.submit(user: user, password: password)
  }
}
