import AppKit
import SereinCore
import SwiftUI

/// What one secret card asks for and how it reads once done.
struct SecretAsk {
  enum Form { case key, card, pasted, password, code }
  let form: Form
  let title: String
  /// At most one line under the title.
  var lead: String?
  /// The one line beside the buttons: where it goes and that the AI never sees it.
  let line: String
  let brand: Brand?
  let name: String
  let saved: String
  let declined: String
  /// The card fields the page has; nil shows them all.
  var parts: [SecureCard.Part]? = nil
  var button = "Save"

  /// A cloud computer's key (`ConnectLink.Kind.key`).
  static func place(_ link: ConnectLink, assistant: String) -> SecretAsk {
    SecretAsk(
      form: .key, title: "Add your \(link.name) key", lead: "\(assistant) needs it to run its computer on \(link.name).",
      line: "\(ConnectFlow.keyNote) \(assistant) never sees it.", brand: Brand(rawValue: link.app), name: link.name,
      saved: "\(link.name) key saved", declined: "No \(link.name) key added")
  }
  /// A key or card asked for with `secret_ask`.
  static func record(_ record: SecretRecord) -> SecretAsk {
    let card = record.kind == .card
    return SecretAsk(
      form: card ? .card : .key, title: "Add your \(record.name)", line: SecretVault.line(record),
      brand: Brand(rawValue: String(record.id.prefix { $0 != "-" })), name: record.name,
      saved: "\(record.name) saved", declined: card ? "No card added" : "No \(record.name) added")
  }
  /// A password, code or card a task's page needs (SecureCards): Serein fills it on the page.
  static func secure(_ card: SecureCards.Card) -> SecretAsk {
    let form: Form = switch card.kind {
    case .password: .password
    case .code: .code
    case .card: .card
    case .key: .key
    }
    return SecretAsk(
      form: form, title: card.title, line: card.mac == nil ? SecureCard.line : SecureCard.macLine, brand: nil, name: card.host, saved: "Sent to \(card.host)",
      declined: "Not filled", parts: card.kind == .card ? card.parts : nil, button: "Fill")
  }
  /// A key caught in the message box, before the person names its service.
  static let pasted = SecretAsk(
    form: .pasted, title: "Save this key", line: "Only sent to the address you type. Serein's AI never sees it.",
    brand: nil, name: "Key", saved: "Key saved", declined: "Key not saved")
}

extension HostedAccount {
  /// The account whose Keychain item a cloud computer's key link fills.
  static func forKey(_ link: ConnectLink) -> HostedAccount? {
    guard link.kind == .key else { return nil }
    switch ComputerPlace(rawValue: link.app) {
    case .e2b: return E2BAccount.shared
    case .daytona: return DaytonaAccount.shared
    default: return nil
    }
  }
}

/// A key or a card asked for in the chat: masked fields that save straight to Keychain through the
/// keeper, so the value never enters the chat, the prompt or a tool answer. Once saved it settles
/// to one line and the person's words go on once; Not now settles it without one.
struct SecretCard<Keeper: ObservableObject>: View {
  @ObservedObject var keeper: Keeper
  let ask: SecretAsk
  let isSaved: (Keeper) -> Bool
  let save: (Keeper, SecretEntry) -> String?
  let carryOn: () -> Void
  /// Not now and Escape tell the asker too.
  let decline: (() -> Void)?
  /// The value, only here, only until Save.
  @State private var entry: SecretEntry
  @State private var refused: String?
  @State private var declined = false
  /// Saved from this card, for a pasted key whose record did not exist before.
  @State private var savedHere = false
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects

  init(
    keeper: Keeper, ask: SecretAsk, prefilled: String = "", isSaved: @escaping (Keeper) -> Bool,
    save: @escaping (Keeper, SecretEntry) -> String?, carryOn: @escaping () -> Void, decline: (() -> Void)? = nil
  ) {
    _keeper = ObservedObject(wrappedValue: keeper)
    self.ask = ask
    self.isSaved = isSaved
    self.save = save
    self.carryOn = carryOn
    self.decline = decline
    _entry = State(initialValue: SecretEntry(key: prefilled))
  }

  private var reduce: Bool { systemReduceMotion || previewReducedEffects }
  private var done: Bool { savedHere || isSaved(keeper) }
  private var blank: Bool {
    switch ask.form {
    case .key: return entry.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .card:
      return shows(.number) && entry.number.isEmpty || shows(.expiry) && entry.expiry.isEmpty
        || shows(.cvc) && entry.cvc.isEmpty || ask.parts?.contains(.holder) == true && entry.holder.isEmpty
    case .pasted: return entry.key.isEmpty || entry.service.isEmpty || entry.address.isEmpty
    case .password, .code: return entry.key.isEmpty
    }
  }

  var body: some View {
    Group {
      if done {
        settled(ask.saved, check: true)
      } else if declined {
        settled(ask.declined, check: false)
      } else {
        form
      }
    }
    .animation(Motion.swapping(reduce), value: done)
    .animation(Motion.swapping(reduce), value: declined)
    .onExitCommand { if !done { notNow() } }
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        BrandLogo(ask.brand, size: 32, name: ask.name, round: true)
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: ask.title).font(AssistantType.name).foregroundStyle(p.ink)
          if let lead = ask.lead {
            Text(verbatim: lead).font(AssistantType.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      fields
      if let refused {
        Text(verbatim: refused).font(AssistantType.meta).foregroundStyle(p.danger)
          .onAppear { AccessibilityNotification.Announcement(refused).post() }
      }
      HStack(spacing: 12) {
        Text(verbatim: ask.line)
          .font(AssistantType.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button(action: notNow) {
          Text("Not now").font(AssistantType.meta).foregroundStyle(p.secondary).linkTarget()
        }.buttonStyle(.pressable)
        ChatCardSolidButton(title: ask.button, action: submit).disabled(blank).opacity(blank ? 0.5 : 1)
      }
    }
    .padding(16)
    .frame(maxWidth: AssistantMetrics.cardWide)
    .assistantCard(p, radius: AssistantMetrics.signInRadius)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(ask.title)
  }

  @ViewBuilder private var fields: some View {
    switch ask.form {
    case .key:
      field("lock", hidden: true, "Paste your key", text: $entry.key, label: ask.name)
    case .card:
      if shows(.number) { field("creditcard", hidden: true, "Card number", text: $entry.number, label: "Card number") }
      HStack(spacing: 12) {
        if shows(.expiry) { field("calendar", hidden: false, "MM/YY", text: $entry.expiry, label: "Expiry") }
        if shows(.cvc) { field("lock", hidden: true, "Security code", text: $entry.cvc, label: "Security code") }
      }
      if shows(.holder) { field("person", hidden: false, "Name on card", text: $entry.holder, label: "Name on card") }
    case .password:
      field("lock", hidden: true, "Password", text: $entry.key, label: "Password")
    case .code:
      field("number", hidden: true, "Code", text: $entry.key, label: "Code")
    case .pasted:
      field("lock", hidden: true, "Key", text: $entry.key, label: "Key")
      field("building.2", hidden: false, "Service, such as Stripe", text: $entry.service, label: "Service")
      field("globe", hidden: false, "Address, such as api.stripe.com", text: $entry.address, label: "Address")
    }
  }

  private func shows(_ part: SecureCard.Part) -> Bool { ask.parts?.contains(part) ?? true }
  private func notNow() {
    declined = true
    decline?()
  }

  /// One masked or plain field in the card's ring. Save empties the hidden ones itself, so only
  /// new typing clears the error.
  private func field(_ icon: String, hidden: Bool, _ prompt: String, text: Binding<String>, label: String) -> some View {
    let ring = RoundedRectangle(cornerRadius: 12, style: .continuous)
    return HStack(spacing: 12) {
      InterfaceIcon(systemName: icon, size: 15).foregroundStyle(p.secondary).frame(width: 20).accessibilityHidden(true)
      Group {
        if hidden {
          SecureField(prompt, text: text)
        } else {
          TextField(prompt, text: text)
        }
      }
      .textFieldStyle(.plain).font(AssistantType.body)
      .onSubmit(submit)
      .onChange(of: text.wrappedValue) { _, now in if !now.isEmpty { refused = nil } }
      .accessibilityLabel(label)
      .accessibilityHint(ConnectFlow.keyNote)
    }
    .padding(.horizontal, 14).frame(height: AssistantMetrics.barHeight)
    .overlay(ring.strokeBorder(refused == nil ? p.wash(0.15) : p.danger.opacity(0.6), lineWidth: 1))
  }

  /// The card's own fields clear at once, whatever the answer.
  private func submit() {
    guard !blank else { return }
    let typed: SecretEntry = entry
    for part in [\SecretEntry.key, \.number, \.cvc, \.expiry, \.holder] { entry[keyPath: part] = "" }
    if let why = save(keeper, typed) {
      refused = why
    } else {
      refused = nil
      savedHere = true
      carryOn()
    }
  }

  /// A centred line once the card is done, with a check that pops on saved.
  private func settled(_ words: String, check: Bool) -> some View {
    HStack(spacing: 6) {
      if check {
        BrandLogo(ask.brand, size: 12, name: ask.name, round: true)
        InterfaceIcon(systemName: "checkmark", size: 10).foregroundStyle(p.success)
          .transition(reduce ? AnyTransition.opacity : AnyTransition.scale.animation(Motion.pop))
      }
      Text(verbatim: words)
    }
    .font(AssistantType.meta).foregroundStyle(p.secondary)
    .padding(.vertical, 6).padding(.horizontal, 12)
    .background(p.track, in: Capsule())
    .frame(maxWidth: .infinity)
    .onAppear { AccessibilityNotification.Announcement(words).post() }
  }
}

/// Under the message box when a key was caught (`ComposerGuard`): a secure field for it, or take
/// it out. There is no way to send it.
struct KeyCaughtNote: View {
  let remove: () -> Void
  let secure: () -> Void
  @Environment(\.palette) private var p

  var body: some View {
    HStack(spacing: 12) {
      InterfaceIcon(systemName: "lock", size: 11).foregroundStyle(p.secondary).accessibilityHidden(true)
      Text(verbatim: ComposerGuard.keyNote).font(AssistantType.meta).foregroundStyle(p.secondary)
        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
      Button(action: remove) {
        Text("Remove it").font(AssistantType.meta).foregroundStyle(p.secondary).linkTarget()
      }.buttonStyle(.pressable)
      ChatCardSolidButton(title: "Use a secure field", action: secure)
    }
    .accessibilityElement(children: .contain)
    .onAppear { AccessibilityNotification.Announcement(ComposerGuard.keyNote).post() }
  }
}

/// The secure cards waiting on the person (SecureCards), at the foot of Serein's chat with its other asks.
struct SecureCardStack: View {
  @ObservedObject var cards: SecureCards

  var body: some View {
    ForEach(cards.open) { card in
      SecretCard(
        keeper: cards, ask: .secure(card), isSaved: { _ in false }, save: { cards, entry in cards.submit(card.id, entry) },
        carryOn: {}, decline: { cards.decline(card.id) }
      ).id(card.id)
    }
  }
}
