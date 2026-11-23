import AppKit
import SereinCore
import SwiftUI

/// The pieces of Settings' list pages (Connections, Plugins, Serein's computer): a caption with an
/// optional info popover, a row with a logo, a status line, one action and its own settings folded
/// under a chevron, coloured company logos, and the Mac's own app icons.

/// A section caption like SettingsGroup's, with an optional info popover for the long explanation.
struct SettingsCaption: View {
  let title: String
  var info: String?
  @Environment(\.palette) var p
  init(_ title: String, info: String? = nil) {
    self.title = title
    self.info = info
  }
  var body: some View {
    HStack(spacing: 4) {
      Text(title).font(AssistantType.meta).foregroundStyle(p.secondary)
        .accessibilityLabel(title).accessibilityAddTraits(.isHeader)
      if let info { InfoPopoverButton(text: info, label: "About \(title.lowercased())") }
    }.padding(.leading, 2).id(title)
  }
}

/// The chevron that folds a row's own settings in and out.
struct DisclosureChevron: View {
  @Binding var open: Bool
  let name: String
  @Environment(\.palette) var p
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    Button {
      if reduceMotion { open.toggle() } else { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } }
    } label: {
      InterfaceIcon(systemName: "chevron.right", size: 11).foregroundStyle(p.faint)
        .rotationEffect(.degrees(open ? 90 : 0))
        .frame(width: 24, height: 24).contentShape(Rectangle())
    }.buttonStyle(.pressable)
      .help(open ? "Hide \(name) settings" : "Show \(name) settings")
      .accessibilityLabel(open ? "Hide \(name) settings" : "Show \(name) settings")
  }
}

/// One row of a settings list: its logo, name (and a small badge), status line and one action,
/// with its own settings folded under a chevron when `expandable`. `live` (progress, a setup form)
/// shows even while folded. Rows sit in one card; each but the first draws a hairline above it.
struct SettingsListRow<Mark: View, Trailing: View, Live: View, Details: View>: View {
  let name: String
  var badge: String?
  let status: String
  var statusTint: Color?
  var divider = true
  var expandable = true
  @ViewBuilder var mark: () -> Mark
  @ViewBuilder var trailing: () -> Trailing
  @ViewBuilder var live: () -> Live
  @ViewBuilder var details: () -> Details
  @State private var open = false
  @Environment(\.palette) var p

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        mark().frame(width: 30, height: 30).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(name).font(UIStyle.font(13)).lineLimit(1).truncationMode(.middle)
            if let badge {
              Text(badge).font(UIStyle.font(11)).tracking(0.1).foregroundStyle(p.faint).lineLimit(1)
                .padding(.horizontal, 7).frame(height: 18).background(p.track, in: Capsule())
            }
          }
          Text(status).font(UIStyle.meta).tracking(0.12).foregroundStyle(statusTint ?? p.faint)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        trailing()
        if expandable { DisclosureChevron(open: $open, name: name) }
      }
      live()
      if open && expandable {
        VStack(alignment: .leading, spacing: 16, content: details).padding(.leading, 42)
      }
    }
    // Grok's `.cfg-row`: at least 52 high, 8 by 10 in, a 0.5 hairline above all but the first.
    .padding(.horizontal, 10).padding(.vertical, 8).frame(minHeight: 52)
    .overlay(alignment: .top) { if divider { Rectangle().fill(p.hairline).frame(height: 0.5) } }
    .accessibilityElement(children: .contain)
  }
}

/// Help under a control inside a row, with the full explanation in a popover.
struct SettingsHelp: View {
  let text: String
  var more: String?
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      Text(text).role(.meta).fixedSize(horizontal: false, vertical: true)
      if let more { InfoPopoverButton(text: more, label: "More about this") }
    }
  }
}

/// A glyph on a small plate, for a row with no logo of its own (an MCP server, a plugin).
struct SettingsGlyphTile: View {
  let systemName: String
  @Environment(\.palette) var p
  var body: some View {
    InterfaceIcon(systemName: systemName, size: 16).foregroundStyle(p.secondary)
      .frame(width: 30, height: 30)
      .background(p.track, in: RoundedRectangle(cornerRadius: 7))
  }
}

/// The switch at the end of a row, labelled for VoiceOver ("Use Mail").
struct SettingsRowSwitch: View {
  let label: String
  @Binding var isOn: Bool
  var body: some View {
    Toggle(label, isOn: $isOn).toggleStyle(SereinSwitchStyle(labeled: false))
      .accessibilityLabel(label)
  }
}

/// Displays the company logo in both appearance modes.
enum Brand: String, CaseIterable {
  case gmail, googleCalendar, slack, notion, github, composio, docker, e2b, daytona, claude, codex, gemini, cursor
  // One-click apps (ConnectorCatalog).
  case adobe, agentmail, algolia, amplitude, apify, apollo, asana, attio, beehiiv, bitly, brex, calendly, canva
  case clickup, cloudflare, contentful, context7, deel, descript, dropbox, fathom, figma, gocardless, granola
  case gusto, heygen, highlevel, hubspot, ifttt, intercom, jotform, kit, klaviyo, lemlist, linear, lovable, lucid
  case mercury, metricool, mixpanel, monday, motion, neon, newrelic, outreach, paypal, pipedrive, posthog, postman
  case prisma, remote, sanity, semrush, sentry, similarweb, sourcegraph, square, stripe, supabase, tally, vercel
  case webflow, wix, wordpress, workos, zapier, zoominfo

  var name: String {
    switch self {
    case .gmail: return "Gmail"
    case .googleCalendar: return "Google Calendar"
    case .slack: return "Slack"
    case .notion: return "Notion"
    case .github: return "GitHub"
    case .composio: return "Composio"
    case .docker: return "Docker"
    case .e2b: return "E2B"
    case .daytona: return "Daytona"
    case .claude: return "Claude"
    case .codex: return "Codex"
    case .gemini: return "Gemini"
    case .cursor: return "Cursor"
    default: return ConnectorCatalog.byID(rawValue)?.name ?? rawValue.capitalized
    }
  }
  fileprivate var file: String {
    switch self {
    case .googleCalendar: return "logo-googlecalendar"
    case .daytona: return "place-daytona"
    case .cursor: return "harness-cursor"
    default: return "logo-" + rawValue
    }
  }
  fileprivate var ink: Bool {
    [
      .github, .daytona, .cursor, .agentmail, .amplitude, .attio, .beehiiv, .brex, .granola, .ifttt, .intercom,
      .linear, .lucid, .mercury, .metricool, .prisma, .sanity, .sentry, .square, .tally, .vercel, .wix,
    ].contains(self)
  }

  /// A Composio app by its slug ("gmail", "googlecalendar").
  static func app(_ slug: String) -> Brand? {
    switch slug.lowercased() {
    case "gmail": return .gmail
    case "googlecalendar": return .googleCalendar
    case "slack": return .slack
    case "notion": return .notion
    case "github": return .github
    default: return Brand(rawValue: slug.lowercased())
    }
  }
  /// One of the person's AI apps by the name Serein shows for it ("Claude Code", "Codex").
  static func aiApp(_ name: String) -> Brand? {
    let lower = name.lowercased()
    if lower.contains("claude") { return .claude }
    if lower.contains("codex") { return .codex }
    if lower.contains("gemini") { return .gemini }
    if lower.contains("cursor") { return .cursor }
    return nil
  }
}

/// A company's logo in its own colours; a name with no logo shows its first letter on a plate.
struct BrandLogo: View {
  let brand: Brand?
  var size: CGFloat = 22
  /// The name whose first letter stands in when there is no logo.
  var name = ""
  /// The personal-assistant screens' monogram (SPEC.md 2.8): the letter on a `track` circle, in
  /// 13 medium at 28 points or more, else 12 regular. Settings keeps its square plate.
  var round = false
  @Environment(\.palette) var p

  init(_ brand: Brand?, size: CGFloat = 22, name: String = "", round: Bool = false) {
    self.brand = brand
    self.size = size
    self.name = name
    self.round = round
  }

  private static let images: [Brand: NSImage] = Dictionary(uniqueKeysWithValues:
    Brand.allCases.compactMap { brand -> (Brand, NSImage)? in
      guard let url = Bundle.assets.url(forResource: brand.file, withExtension: "svg", subdirectory: "Icons"),
        let image = NSImage(contentsOf: url) else { return nil }
      image.isTemplate = brand.ink
      return (brand, image)
    })

  #if DEBUG
    /// Whether an app has a bundled logo that loads: what the one-click apps' check asks.
    static func loads(_ slug: String) -> Bool { Brand.app(slug).flatMap { images[$0] } != nil }
  #endif

  var body: some View {
    if let brand, let image = Self.images[brand] {
      if brand.ink {
        Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
          .foregroundStyle(p.ink).frame(width: size, height: size)
      } else {
        Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(width: size, height: size)
      }
    } else if round {
      Text(String((brand?.name ?? name).prefix(1)).uppercased())
        .font(size >= 28 ? AssistantType.name : AssistantType.meta).foregroundStyle(p.secondary)
        .frame(width: size, height: size)
        .background(p.track, in: Circle())
        .accessibilityHidden(true)
    } else {
      Text(String((brand?.name ?? name).prefix(1)).uppercased())
        .font(UIStyle.font(size * 0.5, weight: .semibold)).foregroundStyle(p.secondary)
        .frame(width: size, height: size)
        .background(p.track, in: RoundedRectangle(cornerRadius: size * 0.24))
    }
  }
}

/// A Mac app's own icon (Mail, Calendar…), read from the installed app; a glyph while the app is
/// not found.
struct MacAppIcon: View {
  let bundleID: String
  var size: CGFloat = 30
  var fallback = "square.grid.2x2"
  @Environment(\.palette) var p
  private static var cache: [String: NSImage] = [:]

  private static func icon(_ id: String) -> NSImage? {
    if let hit = cache[id] { return hit }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
    let image: NSImage = NSWorkspace.shared.icon(forFile: url.path)
    cache[id] = image
    return image
  }

  var body: some View {
    if let image = Self.icon(bundleID) {
      Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
    } else {
      SettingsGlyphTile(systemName: fallback)
    }
  }
}
