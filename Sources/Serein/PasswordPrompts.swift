import AppKit
import SereinCore
import SwiftUI
import WebKit

/// Popovers anchored to a tab's web view: save/update, autofill and the passkey notice.
/// They appear only while the tab is on screen.
@MainActor final class PasswordPrompts {
  private var save: NSPopover?
  private var autofill: NSPopover?
  private var passkey: NSPopover?

  func showSave(_ offer: SaveOffer, in tab: BrowserTab) {
    closeAutofill()
    let popover = makePopover(behavior: .semitransient)
    popover.contentViewController = NSHostingController(
      rootView: SavePasswordPrompt(
        offer: offer,
        finish: { [weak self, weak tab] choice in
          guard let self else { return }
          if let tab { self.apply(choice, offer: offer, in: tab) } else { self.close(\.save) }
        }
      ))
    present(popover, in: tab, at: topTrailing(tab.web), edge: .maxY, slot: \.save)
    // Keep typing in the page: a Return meant for the page must not answer the prompt.
    tab.web.window?.makeFirstResponder(tab.web)
  }

  func showAutofill(_ request: AutofillRequest, accounts: [AutofillAccount], in tab: BrowserTab) {
    guard tab.web.window != nil else { return }
    let generated =
      request.isNew
      ? PasswordGenerator.generate(
        rules: request.rules, fieldMinLength: request.minLength, fieldMaxLength: request.maxLength)
      : nil
    let popover = makePopover(behavior: .semitransient)
    popover.contentViewController = NSHostingController(
      rootView: AutofillPopover(
        host: CredentialOrigin.displayHost(request.origin), accounts: accounts,
        generated: generated, hasRules: !request.rules.isEmpty,
        choose: { [weak self, weak tab] account in
          guard let tab else { return }
          self?.closeAutofill()
          Task { @MainActor in
            do {
              try await PasswordCapture.fill(account, origin: request.origin, in: tab)
            } catch { Self.report(error, in: tab) }
          }
        },
        useGenerated: { [weak self, weak tab] in
          guard let tab, let generated else { return }
          self?.closeAutofill()
          Task { @MainActor in
            do {
              try await PasswordCapture.fillGenerated(generated, origin: request.origin, in: tab)
            } catch { Self.report(error, in: tab) }
          }
        },
        manage: { [weak self] in
          self?.closeAutofill()
          BrowserContext.browser?.showSettings = true
        }
      ))
    present(popover, in: tab, at: fieldRect(request.rect, in: tab.web), edge: below(tab.web), slot: \.autofill)
    // Keep typing in the page while the popover is open.
    tab.web.window?.makeFirstResponder(tab.web)
  }

  func showPasskey(host: String, in tab: BrowserTab) {
    let popover = makePopover(behavior: .semitransient)
    let address = tab.web.url
    popover.contentViewController = NSHostingController(
      rootView: PasskeyNotice(
        host: host.isEmpty ? "This site" : host,
        openElsewhere: address.map { url in { NSWorkspace.shared.open(url) } },
        dismiss: { [weak self] in self?.close(\.passkey) }
      ))
    present(popover, in: tab, at: topTrailing(tab.web), edge: .maxY, slot: \.passkey)
  }

  func closeAutofill() { close(\.autofill) }

  private func apply(_ choice: SaveChoice, offer: SaveOffer, in tab: BrowserTab) {
    close(\.save)
    switch choice {
    case .notNow: return
    case .never: PasswordNeverList.add(offer.origin)
    case .save:
      do {
        if offer.isPrivate {
          try MemoryCredentialStore.save(
            .init(origin: offer.origin, username: offer.username, password: offer.password),
            in: tab.web.configuration.websiteDataStore)
        } else {
          try PasswordVault.shared.save(
            origin: offer.origin, username: offer.username, password: offer.password)
        }
      } catch { Self.report(error, in: tab) }
    }
  }

  private static func report(_ error: Error, in tab: BrowserTab) {
    // Cancelled device authentication needs no message.
    if (error as NSError).domain == "com.apple.LocalAuthentication" { return }
    if let browser = BrowserContext.browser, browser.tabs.contains(where: { $0 === tab }) {
      browser.notice = error.localizedDescription
    } else {
      NSSound.beep()
    }
  }

  // MARK: Popover plumbing

  private func makePopover(behavior: NSPopover.Behavior) -> NSPopover {
    let popover = NSPopover()
    popover.behavior = behavior
    popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    return popover
  }

  private func present(
    _ popover: NSPopover, in tab: BrowserTab, at rect: CGRect, edge: NSRectEdge,
    slot: ReferenceWritableKeyPath<PasswordPrompts, NSPopover?>
  ) {
    close(slot)
    guard tab.web.window != nil, !tab.web.isHiddenOrHasHiddenAncestor else { return }
    self[keyPath: slot] = popover
    popover.show(relativeTo: rect, of: tab.web, preferredEdge: edge)
  }

  private func close(_ slot: ReferenceWritableKeyPath<PasswordPrompts, NSPopover?>) {
    self[keyPath: slot]?.performClose(nil)
    self[keyPath: slot] = nil
  }

  private func topTrailing(_ web: WKWebView) -> CGRect {
    let b = web.bounds
    let y = web.isFlipped ? b.minY + 4 : b.maxY - 8
    return CGRect(x: b.maxX - 200, y: y, width: 4, height: 4)
  }

  private func below(_ web: WKWebView) -> NSRectEdge { web.isFlipped ? .maxY : .minY }

  /// Converts a CSS-pixel viewport rectangle into the web view's coordinates.
  private func fieldRect(_ css: CGRect, in web: WKWebView) -> CGRect {
    let scale = web.pageZoom * web.magnification
    var r = CGRect(
      x: css.minX * scale, y: css.minY * scale, width: max(css.width * scale, 4),
      height: max(css.height * scale, 4))
    if !web.isFlipped { r.origin.y = web.bounds.height - r.maxY }
    return r.intersection(web.bounds.insetBy(dx: 1, dy: 1)).isNull
      ? CGRect(x: web.bounds.midX, y: web.bounds.midY, width: 4, height: 4)
      : r.intersection(web.bounds.insetBy(dx: 1, dy: 1))
  }
}

enum SaveChoice { case save, notNow, never }

// MARK: Views

private struct PromptCard<Content: View>: View {
  @ViewBuilder var content: Content
  @Environment(\.palette) var p
  var body: some View {
    VStack(alignment: .leading, spacing: 12) { content }
      .padding(16).frame(width: UIStyle.wide(320), alignment: .leading)
      .font(UIStyle.font(13)).foregroundStyle(p.ink).background(p.overlay)
  }
}

struct SavePasswordPrompt: View {
  let offer: SaveOffer
  let finish: (SaveChoice) -> Void
  @Environment(\.palette) var p
  var host: String { CredentialOrigin.displayHost(offer.origin) }
  var body: some View {
    PromptCard {
      HStack(spacing: 10) {
        Image(systemName: "key.fill").foregroundStyle(p.accent).accessibilityHidden(true)
        Text(offer.isUpdate ? "Update the password for \(host)?" : "Save a password for \(host)?")
          .font(UIStyle.section)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(offer.username.isEmpty ? "No username" : offer.username).font(UIStyle.mono(12))
        Text(String(repeating: "•", count: min(offer.password.count, 16)))
          .font(UIStyle.mono(12)).foregroundStyle(p.secondary)
          .accessibilityLabel("Password hidden")
      }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
      Text(
        offer.isPrivate
          ? "Kept only while this private window is open. Nothing goes to your Keychain."
          : "Stored in this Mac’s Keychain. Filling it asks for Touch ID or your password."
      ).font(UIStyle.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        if !offer.isUpdate {
          Button("Never for this site") { finish(.never) }.buttonStyle(QuietButton())
        }
        Spacer()
        Button("Not now") { finish(.notNow) }.buttonStyle(QuietButton())
          .keyboardShortcut(.cancelAction)
        if offer.isUpdate {
          // Overwriting a saved password needs a deliberate click, never a stray Return.
          Button("Update") { finish(.save) }.buttonStyle(PrimaryButton())
        } else {
          Button("Save") { finish(.save) }.buttonStyle(PrimaryButton())
            .keyboardShortcut(.defaultAction)
        }
      }
    }
  }
}

struct AutofillPopover: View {
  let host: String
  let accounts: [AutofillAccount]
  let generated: String?
  let hasRules: Bool
  let choose: (AutofillAccount) -> Void
  let useGenerated: () -> Void
  let manage: () -> Void
  @Environment(\.palette) var p
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if !accounts.isEmpty {
        Text("Saved for \(host)").font(UIStyle.micro).foregroundStyle(p.secondary)
          .padding(.horizontal, 8).padding(.top, 4)
        ForEach(accounts) { account in
          row(icon: "person.crop.circle", title: account.username.isEmpty ? "No username" : account.username,
            detail: nil) { choose(account) }
        }
      }
      if let generated {
        row(
          icon: "wand.and.stars", title: "Use a strong password",
          detail: generated + (hasRules ? "\nFollows this site’s password rules." : ""),
          action: useGenerated)
      }
      Divider().overlay(p.line).padding(.vertical, 2)
      row(icon: "key", title: "Manage passwords…", detail: nil, action: manage)
    }.padding(6).frame(width: UIStyle.wide(280), alignment: .leading)
      .font(UIStyle.font(13)).foregroundStyle(p.ink).background(p.overlay)
  }
  private func row(icon: String, title: String, detail: String?, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: icon).frame(width: 16).foregroundStyle(p.secondary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
          if let detail {
            Text(detail).font(UIStyle.mono(12)).foregroundStyle(p.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 0)
      }.padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
    }.buttonStyle(QuietButton())
  }
}

struct PasskeyNotice: View {
  let host: String
  let openElsewhere: (() -> Void)?
  let dismiss: () -> Void
  @Environment(\.palette) var p
  var body: some View {
    PromptCard {
      HStack(spacing: 10) {
        Image(systemName: "person.badge.key").foregroundStyle(p.accent).accessibilityHidden(true)
        Text("\(host) asked for a passkey").font(UIStyle.section)
      }
      Text(
        "Serein can’t use passkeys yet, so this request won’t open a prompt. Pick another way to sign in on the page, such as a password or an emailed code. Or open the page in your default browser to use your passkey there."
      ).font(UIStyle.meta).foregroundStyle(p.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Spacer()
        if let openElsewhere {
          Button("Open in default browser") {
            openElsewhere()
            dismiss()
          }.buttonStyle(QuietButton())
        }
        Button("OK", action: dismiss).buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
      }
    }
  }
}

/// Settings > Passwords: the save offer switch and the "Never for this site" list.
struct PasswordCaptureSettings: View {
  @State private var offer = PasswordCapture.offerToSave
  @State private var never = PasswordNeverList.all
  @Environment(\.palette) var p
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle("Offer to save passwords when you sign in", isOn: $offer)
        .onChange(of: offer) { _, value in PasswordCapture.offerToSave = value }
      Text(
        "Serein asks after you submit a sign-in form on a page a task handed you. Agent tabs never offer."
      ).font(UIStyle.meta).foregroundStyle(p.secondary)
      if !never.isEmpty {
        Text("Never saved for").font(UIStyle.font(13, weight: .medium)).padding(.top, 4)
        ForEach(never, id: \.self) { origin in
          HStack {
            Text(origin).font(UIStyle.mono(12))
            Spacer()
            Button("Offer again") {
              PasswordNeverList.remove(origin)
              never = PasswordNeverList.all
            }
          }
        }
      }
    }
  }
}
