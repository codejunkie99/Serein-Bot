#if DEBUG
import AppKit
import Foundation
import SereinCore
import SwiftUI

/// Keys and cards the model asks for with `secret_ask` and uses by placeholder with
/// `service_request`: the value goes only to its own hosts over https, never comes back to the
/// model, the tool-call record or the library, and a key pasted into the message box is caught.
extension AssistantCoreChecks {
  static let fakeKey = "sk_test_SEREINFAKE0000000000000000abcd"

  static func secureField(_ check: Check) throws {
    let saved = Date(timeIntervalSince1970: 1_800_000_000)
    let stripe = SecretRecord(id: "stripe-key", name: "Stripe key", hosts: ["api.stripe.com"], kind: .key, savedAt: saved)
    let github = SecretRecord(id: "github-token", name: "GitHub token", hosts: ["api.github.com"], kind: .key, savedAt: saved)
    let records = [stripe, github]
    let values = [stripe.id: fakeKey, github.id: "ghp_SEREINFAKE000000000000000000000000"]

    // Every pairing: a value goes in only on its own host or a subdomain of it, over https.
    let destinations: [(String, String?)] = [
      ("https://api.stripe.com/v1/customers", stripe.id),
      ("https://files.api.stripe.com/v1/files", stripe.id),
      ("https://API.Stripe.com/v1/customers", stripe.id),
      ("https://api.stripe.com:443/v1/customers", stripe.id),
      ("https://api.github.com/user", github.id),
      ("https://api.stripe.com.evil.io/v1/customers", nil),
      ("https://evilstripe.com/v1/customers", nil),
      ("https://evilapi.stripe.com/v1/customers", nil),
      ("https://stripe.com/v1/customers", nil),
      ("https://evil.io/?next=https://api.stripe.com", nil),
      ("http://api.stripe.com/v1/customers", nil),
      ("https://1.2.3.4/v1/customers", nil),
      ("https://[::1]/v1/customers", nil),
      ("https://api.stripe.com:8443/v1/customers", nil),
      ("https://user@api.stripe.com/v1/customers", nil),
      ("https://api.stripe.com@evil.io/v1/customers", nil),
      ("https://api.stripe.com./v1/customers", nil),
      ("https://api.stripe.com%2eevil.io/v1/customers", nil),
      ("ftp://api.stripe.com/v1/customers", nil),
    ]
    var wrong: [String] = []
    for record in records {
      for (url, owner) in destinations {
        let request = ["method": "GET", "url": url, "headers": ["Authorization": "Bearer {{secret:\(record.id)}}"]] as [String: Any]
        let filled: URLRequest? = SecretVault.plan(request, records: records).flatMap { SecretVault.fill($0, values: values) }.value
        if (filled != nil) != (owner == record.id) { wrong.append("\(record.id) to \(url)") }
      }
    }
    try check(wrong.isEmpty, "A key goes only to its own host or a subdomain over https, for every pair (wrong: \(wrong))")
    let inHost = ["method": "GET", "url": "https://{{secret:stripe-key}}.api.stripe.com/v1"] as [String: Any]
    let inQuery = ["method": "GET", "url": "https://api.stripe.com/v1/x?key={{secret:stripe-key}}"] as [String: Any]
    try check(
      SecretVault.plan(inHost, records: records).value == nil && SecretVault.plan(inQuery, records: records).value != nil,
      "A placeholder may sit in the path or query, never in the host")
    let none = ["method": "GET", "url": "https://api.stripe.com/v1/customers"] as [String: Any]
    try check(
      SecretVault.plan(none, records: records).error == SecretVault.Refusal(SecretVault.noPlaceholder),
      "service_request without a placeholder is refused: it is not a general web tool")

    // No leaks: a stand-in service echoes the request back in every form it might.
    let request = [
      "method": "POST", "url": "https://api.stripe.com/v1/customers?k={{secret:stripe-key}}",
      "headers": ["Authorization": "Bearer {{secret:stripe-key}}"], "body": #"{"key":"{{secret:stripe-key}}"}"#,
    ] as [String: Any]
    guard case .success(let plan) = SecretVault.plan(request, records: records),
      case .success(let sent) = SecretVault.fill(plan, values: values)
    else { throw SereinError.invalid("FAIL: The round trip's request could not be built") }
    try check(
      sent.value(forHTTPHeaderField: "Authorization") == "Bearer " + fakeKey && plan.shown.contains("{{secret:stripe-key}}")
        && !plan.shown.contains(fakeKey),
      "The request carries the key, and the approval card shows only the placeholder")
    let echo = Data(standInEcho(sent).utf8)
    let answer = SecretVault.answer(status: 200, contentType: "application/json", body: echo, values: values)
    let modelText = String(decoding: try JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys]), as: UTF8.self)
    var calls: [String: ToolCall] = [:]
    let use: [String: Any] = ["type": "tool_use", "id": "c1", "name": "service_request", "input": request]
    let result: [String: Any] = ["type": "tool_result", "tool_use_id": "c1", "content": modelText]
    ToolCalls.apply(["type": "assistant", "message": ["content": [use]]], to: &calls, at: saved)
    ToolCalls.apply(["type": "user", "message": ["content": [result]]], to: &calls, at: saved)
    let recordText = (calls["c1"]?.input ?? "") + (calls["c1"]?.output ?? "")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("serein-secure-field-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let library = try Library(root: folder)
    try library.save(records, to: "secrets.json")
    try library.saveText(modelText, to: "answer.json")
    try library.saveText(recordText, to: "tool-call.txt")
    try library.saveText(AgentStep.label(tool: "service_request", arguments: request), to: "step.txt")
    let disk = try FileManager.default.subpathsOfDirectory(atPath: folder.path).compactMap { path in
      FileManager.default.contents(atPath: folder.appendingPathComponent(path).path).map { String(decoding: $0, as: UTF8.self) }
    }.joined(separator: "\n")
    let forms = leakForms(fakeKey)
    try check(standInEcho(sent).contains(forms[1]) && standInEcho(sent).contains(forms[2]),
              "The stand-in echoes the key in base64, hex and URL-encoded forms")
    try check(!forms.contains { modelText.contains($0) } && modelText.contains("[secret:stripe-key]"),
              "The model's answer holds no form of the key, only its marker")
    try check(!calls.isEmpty && !forms.contains { recordText.contains($0) }, "The tool-call record holds no form of the key")
    try check(!disk.isEmpty && !forms.contains { disk.contains($0) }, "Nothing written to the library holds any form of the key")
    let failed = SecretVault.scrub("The request did not go through: \(sent.url?.absoluteString ?? "")", values: values)
    try check(!forms.contains { failed.contains($0) }, "A failed request's words hold no form of the key")

    // Asking: only a turn the person started, only plain hosts, a saved key answers at once.
    let ask = ["name": "Stripe key", "hosts": ["api.stripe.com"], "kind": "key"] as [String: Any]
    try check(SecretVault.ask(ask, personStarted: false, records: []) == .refused(SecretVault.notHere),
              "secret_ask in a turn the person did not start is refused")
    guard case .show(let shown) = SecretVault.ask(ask, personStarted: true, records: []) else {
      throw SereinError.invalid("FAIL: secret_ask in the person's turn shows the card")
    }
    try check(shown.id == "stripe-key" && shown.savedAt == nil && ConnectLink(app: shown.id, name: shown.name, kind: .secret) != nil,
              "secret_ask in the person's turn shows the card for a new record")
    let badHosts: [[String]] = [["https://api.stripe.com"], ["1.2.3.4"], ["localhost"], ["api.stripe.com/v1"], ["api.stripe.com:443"], []]
    try check(badHosts.allSatisfy { SecretVault.ask(["name": "Stripe key", "hosts": $0], personStarted: true, records: []) == .refused(SecretVault.badHosts) },
              "secret_ask refuses hosts that are not plain domain names")
    let ready = SecretVault.ask(ask, personStarted: true, records: records)
    try check(ready == .saved(stripe) && (SecretVault.answer(stripe, saved: true)["placeholder"] as? String) == "{{secret:stripe-key}}",
              "A saved key answers at once with its placeholder")

    // Pasting: a key in the draft is caught and taken out; plain words go.
    let draft = "use my key \(fakeKey) for the invoices"
    try check(
      MessagePlan.of(draft, hasAttachments: false, shortcuts: [], mentionRefusal: nil, questionWaits: false) == .refuse(ComposerGuard.keyRefusal)
        && ComposerGuard.firstKey(in: draft) == fakeKey && ComposerGuard.withoutKeys(draft) == "use my key for the invoices",
      "A pasted key is caught, goes to the secure field and leaves the draft")
    try check(ComposerGuard.withoutKeys("try Bearer \(fakeKey) now") == "try now", "A key two shapes match leaves the draft whole")
    try check(ComposerGuard.firstKey(in: "Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345") == "abcdefghijklmnopqrstuvwxyz012345",
              "A bearer token goes to the secure field without its word")
    try check(!ComposerGuard.looksLikeKey("Ask Stripe why the sk_test key stopped working on api.stripe.com"),
              "A plain sentence about a key is not caught")

    // Door: a change follows the level, the person there or not; a payment meets the pay floor.
    let post = ["method": "POST", "url": "https://api.github.com/repos/a/b/issues", "headers": ["Authorization": "Bearer {{secret:github-token}}"]] as [String: Any]
    let charge = ["method": "POST", "url": "https://api.stripe.com/v1/charges", "headers": ["Authorization": "Bearer {{secret:stripe-key}}"]] as [String: Any]
    let read = ["method": "GET", "url": "https://api.github.com/user", "headers": ["Authorization": "Bearer {{secret:github-token}}"]] as [String: Any]
    let postEffect = SecretVault.plan(post, records: records).value?.effect
    let chargeEffect = SecretVault.plan(charge, records: records).value?.effect
    let there = ApprovalDoor.Standing.person(.riskyOnly)
    let away = ApprovalDoor.Standing(level: .riskyOnly, levelStands: true, present: false)
    let pay = ApprovalDoor.Answer.blocked(.pay(ref: ""))
    try check(postEffect == .change && SecretVault.decision(.change, .person(.everyStep)) == .card(.hold(cap: ApprovalDoor.holdCap))
              && SecretVault.decision(.change, there) == .run,
              "A request that is not GET shows a card at Every step and runs at Only risky steps")
    try check(chargeEffect == .pay && SecretVault.decision(.pay, there) == pay
              && ApprovalGate.requestEffect(method: "POST", host: "api.example.com", path: "/v1/payment_intents") == .pay,
              "A charge to a payment endpoint rates as paying and meets the pay floor")
    try check(SecretVault.decision(.change, away) == .run
              && SecretVault.plan(read, records: records).value?.effect == .read
              && SecretVault.decision(.read, .person(.everyStep)) == .run
              && SecretVault.decision(.change, ApprovalDoor.Standing(level: .everyStep, levelStands: true, present: false)) == .card(.deferred),
              "A change follows the level with nobody there, its card left open at Every step; a read runs")
    try check(
      SecretVault.decision(.pay, .proactiveTask(present: true)) == pay && SecretVault.decision(.pay, .proactiveTask(present: false)) == pay
        && SecretVault.decision(.change, .proactiveTask(present: false)) == .run,
      "At Allow all a payment through the secure field is the person's card, and a change runs")
    // The vault asks the door, as every other caller does, for every effect, level and turn.
    let moved = ApprovalGate.Effect.allCases.flatMap { effect in
      DoorTable.standings.compactMap { standing -> String? in
        let door = ApprovalDoor.answer(.init(.effect(effect), standing), facts: DoorTable.facts())
        return SecretVault.decision(effect, standing) == door ? nil : "\(effect) \(standing.level) present:\(standing.present)"
      }
    }
    try check(moved.isEmpty, "A request's answer is the door's, for every effect, level and turn"
              + (moved.isEmpty ? "" : ": \(moved)"))

    // Cards: the model learns only that a card is saved.
    var typed = SecretEntry()
    typed.number = "4242 4242 4242 4242"
    typed.expiry = "4/31"
    typed.cvc = "123"
    typed.holder = "Test Person"
    let card = SecretRecord(id: "visa", name: "Visa", hosts: ["shop.example.com"], kind: .card, savedAt: saved)
    let cardAnswer = String(describing: SecretVault.answer(card, saved: true))
      + String(describing: SecretVault.answer(card, saved: false))
      + String(decoding: try JSONEncoder().encode(SecretRecord(id: card.id, name: card.name, hosts: card.hosts, kind: .card)), as: UTF8.self)
    try check(SecretVault.value(.card, typed) != nil && !cardAnswer.contains(where: \.isNumber),
              "Card digits never reach the model's text or the saved record")
    var typo = typed
    typo.number = "4242 4242 4242 4241"
    try check(SecretVault.value(.card, typo) == nil, "A card number that fails its check digit is not saved")
    let cardInRequest = ["method": "GET", "url": "https://shop.example.com/x?c={{secret:visa}}"] as [String: Any]
    try check(SecretVault.plan(cardInRequest, records: records + [card]).value == nil, "A card never goes into a request")

    // Offscreen, no window.
    if let folder = ProcessInfo.processInfo.environment["SEREIN_SECRET_CARD_PREVIEW"] {
      try MainActor.assumeIsolated { try drawSecretCards(into: URL(fileURLWithPath: folder), key: stripe, card: card) }
    }
  }

  static func standInEcho(_ request: URLRequest) -> String {
    let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
    let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
    let token = auth.replacingOccurrences(of: "Bearer ", with: "")
    let data = Data(token.utf8)
    let echo: [String: Any] = [
      "url": request.url?.absoluteString ?? "", "authorization": auth, "body": body,
      "base64": data.base64EncodedString(), "hex": data.map { String(format: "%02x", $0) }.joined(),
      "encoded": token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "",
    ]
    return String(decoding: (try? JSONSerialization.data(withJSONObject: echo, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
  }

  static func leakForms(_ value: String) -> [String] {
    let data = Data(value.utf8)
    return [value, data.base64EncodedString(), data.map { String(format: "%02x", $0) }.joined(),
            value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value]
  }

  private final class PreviewKeeper: ObservableObject {}

  @MainActor private static func drawSecretCards(into folder: URL, key: SecretRecord, card: SecretRecord) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let keeper = PreviewKeeper()
    for palette in [Palette.light, .dusk] {
      let content = VStack(alignment: .leading, spacing: 12) {
        SecretCard(keeper: keeper, ask: .record(key), isSaved: { _ in false }, save: { _, _ in nil }) {}
        SecretCard(keeper: keeper, ask: .record(card), isSaved: { _ in false }, save: { _, _ in nil }) {}
        SecretCard(keeper: keeper, ask: .record(key), isSaved: { _ in true }, save: { _, _ in nil }) {}
        KeyCaughtNote(remove: {}, secure: {})
        SecretCard(keeper: keeper, ask: .pasted, prefilled: fakeKey, isSaved: { _ in false }, save: { _, _ in nil }) {}
      }
      .frame(width: 560, alignment: .leading).padding(20)
      .environment(\.palette, palette).environment(\.colorScheme, palette.isDark ? .dark : .light)
      .environment(\.sereinReducedEffects, true).background(palette.background)
      // ImageRenderer leaves AppKit text fields blank, so the cards are drawn in a hosting view.
      let host = NSHostingView(rootView: content)
      host.frame = NSRect(origin: .zero, size: host.fittingSize)
      let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
      window.contentView = host
      defer { window.close() }
      host.layoutSubtreeIfNeeded()
      host.displayIfNeeded()
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw SereinError.invalid("The secret cards could not be drawn.")
      }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw SereinError.invalid("The secret cards could not be drawn.")
      }
      try data.write(to: folder.appendingPathComponent("secret-cards-\(palette.isDark ? "dark" : "light").png"))
    }
  }
}

private extension Result {
  var value: Success? { try? get() }
  var error: Failure? {
    if case .failure(let failure) = self { return failure }
    return nil
  }
}
#endif
