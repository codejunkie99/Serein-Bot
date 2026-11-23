import Foundation
import SereinCore
import SwiftUI

/// A new key for an OpenCode model's provider, handed to OpenCode itself so its later turns use
/// it. A private `opencode serve` on 127.0.0.1, locked with a one-time password and stopped right
/// after, takes the key in the body of OpenCode's own connect-key request: never on a command
/// line, in a log line or in Serein's library. OpenCode 2 only.
@MainActor enum OpenCodeKey {
  static let refusal = "OpenCode did not take the key. Check it and try again."

  /// The key failure a failed OpenCode 2 turn on a named model met; nil for anything else. A
  /// signed-out turn keeps its own sign-in card.
  static func failure(_ run: AgentRun) -> KeyFailure? {
    guard run.spec.provider.driver == .opencode, run.record.outcome == .stuck, !run.signedOut,
      run.spec.model.contains("/"),
      OpenCodeAPI(version: HarnessRegistry.shared.snapshot(run.spec.provider)?.version) == .v2
    else { return nil }
    return KeyFailure.of(run.error)
  }

  /// nil when OpenCode stored the key for `model`'s provider, else `refusal`.
  static func hand(_ key: String, model: String) async -> String? {
    let provider = Provider(.opencode)
    let registry = HarnessRegistry.shared
    guard let executable = registry.executable(provider) else { return refusal }
    let environment = AgentFileGuard.environment(
      registry.environment(provider, executable: executable), driver: .opencode, ownKey: registry.keyVariable(provider))
    return await hand(key, model: model, executable: executable, environment: environment) ? nil : refusal
  }

  /// Starts the server on Serein's own empty config folder, never the person's ~/.config/opencode,
  /// posts the key and stops it. OpenCode keeps keys in its data folder, which engine turns read.
  /// A server Serein quits under is ended at the next launch (ProcessGroup.endLeftovers).
  nonisolated static func hand(
    _ key: String, model: String, executable: String, environment: [String: String]
  ) async -> Bool {
    guard let route = OpenCodeAPI.keyRoute(model: model) else { return false }
    let password = UUID().uuidString + UUID().uuidString
    var env = environment
    env["OPENCODE_CONFIG_DIR"] = HelperFolder.openCodeConfig
    env["OPENCODE_DISABLE_PROJECT_CONFIG"] = "1"
    env["OPENCODE_DISABLE_CLAUDE_CODE"] = "1"
    env["OPENCODE_DISABLE_EXTERNAL_SKILLS"] = "1"
    env["OPENCODE_PURE"] = "1"
    env["OPENCODE_SERVER_PASSWORD"] = password
    env["OPENCODE_SERVER_USERNAME"] = "opencode"
    let child = Process()
    let stdout = Pipe()
    child.executableURL = URL(fileURLWithPath: executable)
    child.arguments = HarnessDriver.opencode.quietArguments + OpenCodeAPI.v2.serveArguments
    child.currentDirectoryURL = HelperFolder.url
    child.environment = env
    child.standardOutput = stdout
    child.standardError = FileHandle.nullDevice
    child.standardInput = FileHandle.nullDevice
    guard (try? ProcessGroup.configure(child)) != nil, (try? child.run()) != nil else { return false }
    defer { ProcessGroup.terminate(child) }
    guard let base = await listening(stdout),
      var parts = URLComponents(url: base.appendingPathComponent(route), resolvingAgainstBaseURL: false)
    else { return false }
    parts.queryItems = [URLQueryItem(name: "directory", value: HelperFolder.url.path)]
    guard let url = parts.url else { return false }
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.httpMethod = "POST"
    request.setValue("Basic " + Data("opencode:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["key": key])
    // Straight to the key route: a provider lookup this soon after start often answers 404.
    guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
    return (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
  }

  /// The address in "opencode server listening on http://127.0.0.1:<port>", or nil once the
  /// server exits or 30 s pass. The pipe is drained after, so the server never blocks on it.
  nonisolated private static func listening(_ stdout: Pipe) async -> URL? {
    let found = ResumeOnce<URL?>()
    DispatchQueue.global(qos: .userInitiated).async {
      var seen = ""
      while case let data = stdout.fileHandleForReading.availableData, !data.isEmpty {
        seen += String(decoding: data, as: UTF8.self)
        // The port must be followed by something, so a half-written one never matches.
        if let hit = seen.range(of: #"http://127\.0\.0\.1:\d{2,5}(?=\D)"#, options: .regularExpression) {
          found.resume(URL(string: String(seen[hit])))
          while !stdout.fileHandleForReading.availableData.isEmpty {}
          return
        }
        if seen.count > 100_000 { seen = String(seen.suffix(2000)) }
      }
      found.resume(nil)
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 30) { found.resume(nil) }
    return await withCheckedContinuation { found.set($0) }
  }
}

/// OpenCode's key failed (`KeyFailure`): one masked field under the failure line, shaped as
/// `SecretCard`. Save hands the key to OpenCode (`OpenCodeKey.hand`) and the person's same message
/// goes again once; Not now or Escape settles it without a key.
struct OpenCodeKeyCard: View {
  let failure: KeyFailure
  let model: String
  let assistant: String
  let carryOn: () -> Void
  /// The key, only here, only until Save.
  @State private var key = ""
  @State private var ask = KeyFailure.Ask()
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects

  static func heading(_ failure: KeyFailure) -> String {
    failure == .expired ? "Your OpenCode key has expired" : "OpenCode did not accept your key"
  }
  static let whereToMake = "Make a new key in OpenCode Console, then paste it here."
  static func note(_ assistant: String) -> String { "\(assistant) hands it to OpenCode and keeps no copy." }
  static let saved = "New OpenCode key saved"
  static let declined = "No new OpenCode key added"

  private var reduce: Bool { systemReduceMotion || previewReducedEffects }
  private var blank: Bool { key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  var body: some View {
    Group {
      switch ask.step {
      case .saved: settled(Self.saved, check: true)
      case .declined: settled(Self.declined, check: false)
      case .asking, .handing: card
      }
    }
    .animation(Motion.swapping(reduce), value: ask.step)
    .onExitCommand { ask.decline() }
  }

  private var card: some View {
    let ring = RoundedRectangle(cornerRadius: 12, style: .continuous)
    let busy: Bool = ask.step == .handing
    return VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        BrandLogo(nil, size: 32, name: "OpenCode", round: true)
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: Self.heading(failure)).font(AssistantType.name).foregroundStyle(p.ink)
          Text(verbatim: Self.whereToMake)
            .font(AssistantType.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      HStack(spacing: 10) {
        InterfaceIcon(systemName: "lock", size: 15).foregroundStyle(p.secondary).frame(width: 20).accessibilityHidden(true)
        SecureField("Paste your new key", text: $key)
          .textFieldStyle(.plain).font(AssistantType.body)
          .onSubmit(save)
          .disabled(busy)
          .accessibilityLabel("OpenCode key")
          .accessibilityHint(Self.note(assistant))
      }
      .padding(.horizontal, 14).frame(height: AssistantMetrics.barHeight)
      .overlay(ring.strokeBorder(ask.refusal == nil ? p.wash(0.15) : p.danger.opacity(0.6), lineWidth: 1))
      if let refusal = ask.refusal {
        Text(verbatim: refusal).font(AssistantType.meta).foregroundStyle(p.danger)
          .onAppear { AccessibilityNotification.Announcement(refusal).post() }
      }
      HStack(spacing: 10) {
        Text(verbatim: Self.note(assistant))
          .font(AssistantType.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button { ask.decline() } label: {
          Text("Not now").font(AssistantType.meta).foregroundStyle(p.secondary).linkTarget()
        }.buttonStyle(.pressable).disabled(busy)
        ChatCardSolidButton(title: busy ? "Saving…" : "Save", action: save).disabled(blank || busy).opacity(blank || busy ? 0.5 : 1)
      }
    }
    .padding(14)
    .frame(maxWidth: AssistantMetrics.cardWide)
    .assistantCard(p, radius: AssistantMetrics.signInRadius)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Self.heading(failure))
  }

  /// The field clears at once, whatever the answer.
  private func save() {
    let pasted: String = key
    key = ""
    guard ask.begin(pasted) else { return }
    let model: String = model
    Task { @MainActor in
      let refused: String? = await OpenCodeKey.hand(pasted, model: model)
      if ask.handed(refused) { carryOn() }
    }
  }

  /// A centred line once the card is done, with a check that pops on saved.
  private func settled(_ words: String, check: Bool) -> some View {
    HStack(spacing: 6) {
      if check {
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
