import CryptoKit
import SereinCore
import SwiftUI
import WebKit

@MainActor final class ContentBlocking: ObservableObject {
  static let shared = ContentBlocking()
  @Published var enabled = UserDefaults.standard.object(forKey: "serein.blocking") as? Bool ?? true
  @Published var status = "Loading filter rules…"
  @Published var updating = false
  @Published var allowed = UserDefaults.standard.string(forKey: "serein.adAllowed") ?? ""
  private var rules: [WKContentRuleList] = []
  private var compilationRevision = 0
  @Published var custom = UserDefaults.standard.string(forKey: "serein.customFilters") ?? ""
  private var views = NSHashTable<WKWebView>.weakObjects()
  private var source = ""
  private let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Serein/filters.txt")
  init() {
    source =
      (try? String(contentsOf: cache))
      ?? "||doubleclick.net^\n||googlesyndication.com^\n||google-analytics.com^\n||facebook.net^$third-party\n||scorecardresearch.com^\n||hotjar.com^"
    Task { await compile() }
  }
  func attach(_ web: WKWebView) {
    views.add(web)
    if enabled { for rule in rules { web.configuration.userContentController.add(rule) } }
  }
  func apply() {
    UserDefaults.standard.set(enabled, forKey: "serein.blocking")
    for web in views.allObjects {
      web.configuration.userContentController.removeAllContentRuleLists()
      if enabled { for rule in rules { web.configuration.userContentController.add(rule) } }
    }
  }
  func update() {
    guard !updating else { return }
    updating = true
    status = "Downloading EasyList and EasyPrivacy…"
    Task {
      do {
        var text = ""
        for name in ["easylist", "easyprivacy"] {
          var request = URLRequest(url: URL(string: "https://easylist.to/easylist/\(name).txt")!)
          request.timeoutInterval = 30
          let (data, response) = try await URLSession.shared.data(for: request)
          guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 15_000_000,
            let content = String(data: data, encoding: .utf8), content.contains("[Adblock")
          else { throw SereinError.invalid("Invalid filter-list download") }
          text += content + "\n"
        }
        await compile(newSource: text)
      } catch { status = error.localizedDescription }
      updating = false
    }
  }
  func saveExceptions() {
    Task { await compile() }
  }
  /// Removes compiled lists from WebKit's store, except the ones in use.
  private func discard(_ lists: [WKContentRuleList]) {
    let inUse = Set(rules.map(\.identifier))
    for list in lists where !inUse.contains(list.identifier) {
      WKContentRuleListStore.default().removeContentRuleList(forIdentifier: list.identifier) { _ in
      }
    }
  }
  static let identifierPrefix = "SereinFilters-"
  /// A chunk is named by its rules, so a launch with the same lists finds WebKit's compiled copy
  /// (`lookUpContentRuleList`) instead of compiling tens of thousands of rules again.
  static func identifier(for json: String) -> String {
    identifierPrefix + SHA256.hash(data: Data(json.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
  }
  private static func compiled(_ identifier: String) async -> WKContentRuleList? {
    await withCheckedContinuation { c in
      WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: identifier) { list, _ in
        c.resume(returning: list)
      }
    }
  }
  /// Lists an earlier launch or rule set left in the store (each launch used to compile under a
  /// new name). Only Serein's own filter lists are touched.
  private func sweep() {
    let inUse = Set(rules.map(\.identifier))
    let prefix = Self.identifierPrefix
    WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { identifiers in
      for identifier in identifiers ?? [] where identifier.hasPrefix(prefix) && !inUse.contains(identifier) {
        WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in }
      }
    }
  }
  func compile(newSource: String? = nil) async {
    compilationRevision += 1
    let revision = compilationRevision
    let candidate = newSource ?? source
    let candidateCustom = custom
    let candidateAllowed = allowed
    let text = candidate + "\n" + candidateCustom
    let sites = candidateAllowed.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }.filter { $0.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil }
    let result = await Task.detached { FilterRules.convert(text, allowedSites: sites) }.value
    var compiledRules: [WKContentRuleList] = []
    var committed = false
    defer { if !committed { discard(compiledRules) } }
    do {
      let chunks = FilterRules.chunks(result.rules)
      for chunk in chunks {
        guard revision == compilationRevision else { return }
        let json = jsonString(chunk)
        let identifier = Self.identifier(for: json)
        if let cached = await Self.compiled(identifier) {
          compiledRules.append(cached)
          continue
        }
        guard revision == compilationRevision else { return }
        let compiled: WKContentRuleList = try await withCheckedThrowingContinuation { c in
          WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier, encodedContentRuleList: json
          ) { rule, error in
            if let rule {
              c.resume(returning: rule)
            } else {
              c.resume(throwing: error ?? SereinError.invalid("Filter compilation failed"))
            }
          }
        }
        compiledRules.append(compiled)
      }
      guard revision == compilationRevision else { return }
      if newSource != nil {
        try FileManager.default.createDirectory(
          at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try candidate.write(to: cache, atomically: true, encoding: .utf8)
      }
      source = candidate
      UserDefaults.standard.set(candidateAllowed, forKey: "serein.adAllowed")
      UserDefaults.standard.set(candidateCustom, forKey: "serein.customFilters")
      let previous = rules
      rules = compiledRules
      committed = true
      apply()
      discard(previous)
      sweep()
      status =
        "\(result.rules.count) WebKit rules active; \(result.skipped) unsupported rules skipped."
    } catch {
      if revision == compilationRevision {
        status = "Kept previous rules. " + error.localizedDescription
      }
    }
  }
  func saveCustom() {
    Task { await compile() }
  }
  private var iconBlockCache: (key: Int, domains: Set<String>)?
  /// Site icon requests go outside WebKit, so they ask here: true when blocking is on and a
  /// `||host^` rule blocks the host (or a parent domain).
  func blocksIcons(host: String) -> Bool {
    guard enabled, !host.isEmpty else { return false }
    let key = source.hashValue ^ custom.hashValue ^ allowed.hashValue
    if iconBlockCache?.key != key {
      let sites = allowed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
      iconBlockCache = (key, SiteIconPlan.blockedDomains(from: source + "\n" + custom, allowedSites: sites))
    }
    return SiteIconPlan.isBlocked(host: host, domains: iconBlockCache?.domains ?? [])
  }
}
struct BlockingSettings: View {
  @StateObject private var blocking = ContentBlocking.shared
  @Environment(\.palette) var p
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle("Block ads and trackers", isOn: $blocking.enabled).onChange(of: blocking.enabled) {
        _, _ in blocking.apply()
      }
      Text(blocking.status).font(UIStyle.font(12)).foregroundStyle(p.secondary)
      Button("Update EasyList + EasyPrivacy") { blocking.update() }.disabled(blocking.updating)
      TextField("Allowed sites, separated by commas", text: $blocking.allowed)
        .textFieldStyle(.plain).textInputCursor().padding(8)
        .background(p.background, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: UIStyle.controlRadius).stroke(p.borderStrong))
        .onSubmit { blocking.saveExceptions() }
      Button("Save site exceptions") { blocking.saveExceptions() }
      Text("Custom filter rules").font(UIStyle.font(13))
      TextEditor(text: $blocking.custom).font(UIStyle.mono(12)).scrollContentBackground(.hidden)
        .frame(height: 112).padding(8)
        .background(p.background, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: UIStyle.controlRadius).stroke(p.borderStrong))
      Button("Apply custom rules") { blocking.saveCustom() }
      Text(
        "A small starter list ships in code. Update downloads the public lists. Network and cosmetic rules, domain exceptions, type exclusions and supported regular expressions are converted. Scriptlets and unrepresentable syntax are counted as unsupported. Previous active rules stay in place if compilation fails. Lists: EasyList authors, GPLv3 or CC BY-SA 3.0."
      ).font(UIStyle.font(12)).foregroundStyle(p.secondary)
    }.font(UIStyle.font(13)).foregroundStyle(p.ink).buttonStyle(QuietButton())
      .controlSize(.small).tint(p.solid)
  }
}
