import Foundation

/// Apps Serein connects in one click: each runs its own MCP server, and its sign-in lets an app
/// register itself (OAuth 2.1 dynamic client registration with PKCE, `PluginOAuth`), so the person
/// only signs in to the app in their browser. The first 18 addresses were checked to publish that
/// sign-in on 7 Nov 2026 and pass Serein's own sign-in checks (`--verify-connectors-live`). The
/// rest were found in other assistants' catalogs and passed the same discovery rules on 9 Nov 2026,
/// read from a Linux machine (no registration made); run `--verify-connectors-live` on a Mac before
/// a release and take out any that fail. Three apps sign in another way (`SignIn`): GitHub and
/// Slack take a token the person makes, because their servers offer no sign-in an app can
/// register with; HubSpot's server takes only its own OAuth apps, so it connects through
/// Composio. Jira and
/// Confluence, Airtable, Todoist, Miro and Netlify publish theirs in a shape those checks refuse,
/// so they are not here yet. Apps whose sign-in needs a client Serein has registered with them
/// first (Google, Box) are not here; Gmail and Google Calendar reach the person through the Mac's
/// Mail and Calendar (`macFallback`) until Serein has its own Google client.
public enum ConnectorCatalog {
  /// The groups the Connect Apps window shows, in order.
  public enum Category: String, CaseIterable, Sendable {
    case productivity, communication, design, code, finance, sales, marketing, analytics
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
  }
  /// How a one-click app signs in.
  public enum SignIn: Sendable, Equatable {
    /// The browser sign-in its server publishes, with app registration (`PluginOAuth`).
    case browser
    /// A token the person makes in the app, kept in the Keychain and sent as the bearer token.
    case key(KeySignIn)
    /// Composio's hosted sign-in for this Composio toolkit (`ComposioApps`).
    case composio(String)
    public var key: KeySignIn? {
      if case .key(let key) = self { return key }
      return nil
    }
    public var composioApp: String? {
      if case .composio(let app) = self { return app }
      return nil
    }
  }

  /// A token the person makes and pastes: what it is called, where it is made, and the shape
  /// Serein checks before it sends it anywhere. Only the shape is checked here; the server
  /// decides whether the token works.
  public struct KeySignIn: Sendable, Equatable {
    /// "personal access token".
    public let name: String
    /// The beginnings a token of this kind has (`github_pat_`, `ghp_`).
    public let prefixes: [String]
    /// The https page where the person makes one.
    public let page: String
    /// What to do there, in order.
    public let steps: [String]
    /// A token's beginning with what to say instead, for tokens of the wrong kind.
    public let wrongKinds: [String: String]
    public init(name: String, prefixes: [String], page: String, steps: [String], wrongKinds: [String: String] = [:]) {
      self.name = name
      self.prefixes = prefixes
      self.page = page
      self.steps = steps
      self.wrongKinds = wrongKinds
    }
    public static let lengthLimit = 512
    /// What the secure field shows before anything is typed: the first beginning, then "…".
    public var placeholder: String { (prefixes.first ?? "") + "…" }
    /// Why `raw` cannot be this kind of token, in the person's words; nil when its shape fits.
    public func problem(_ raw: String) -> String? {
      let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !token.isEmpty else { return "Paste the \(name)." }
      guard !token.contains(where: { $0.isWhitespace || $0.isNewline }) else { return "Paste the whole \(name), without spaces." }
      if let wrong = wrongKinds.keys.sorted().first(where: { token.hasPrefix($0) }) { return wrongKinds[wrong] }
      guard prefixes.contains(where: { token.hasPrefix($0) }) else {
        return "A \(name) starts with " + prefixes.joined(separator: " or ") + ". Check that you copied the right one."
      }
      guard token.count >= 20, token.count <= Self.lengthLimit, token.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value < 127 })
      else { return "That does not look like a whole \(name). Copy it again." }
      return nil
    }
  }

  public struct Connector: Sendable, Equatable, Identifiable {
    /// A short id (`notion`): the link's app id in a chat card.
    public let id: String
    public let category: Category
    public let name: String
    /// Its MCP server's address.
    public let url: String
    /// Other words a person or a model may use for it.
    public let words: [String]
    /// What it gives the assistant, for its row.
    public let does: String
    /// How it signs in: the browser for most.
    public let signIn: SignIn
    public init(
      id: String, category: Category, name: String, url: String, words: [String] = [], does: String,
      signIn: SignIn = .browser
    ) {
      self.id = id
      self.category = category
      self.name = name
      self.url = url
      self.words = words
      self.does = does
      self.signIn = signIn
    }
  }

  public static let all: [Connector] = [
    Connector(id: "notion", category: .productivity, name: "Notion", url: "https://mcp.notion.com/mcp", words: [], does: "Pages, docs and databases"),
    Connector(id: "linear", category: .code, name: "Linear", url: "https://mcp.linear.app/mcp", words: [], does: "Issues, projects and cycles"),
    Connector(id: "vercel", category: .code, name: "Vercel", url: "https://mcp.vercel.com", words: [], does: "Deployments, logs and projects"),
    Connector(id: "asana", category: .productivity, name: "Asana", url: "https://mcp.asana.com/sse", words: [], does: "Tasks and projects"),
    Connector(id: "monday", category: .productivity, name: "Monday", url: "https://mcp.monday.com/mcp", words: ["monday.com"], does: "Boards and items"),
    Connector(id: "dropbox", category: .productivity, name: "Dropbox", url: "https://mcp.dropbox.com/mcp", words: [], does: "Files and folders"),
    Connector(id: "granola", category: .productivity, name: "Granola", url: "https://mcp.granola.ai/mcp", words: [], does: "Meeting notes"),
    Connector(id: "figma", category: .design, name: "Figma", url: "https://mcp.figma.com/mcp", words: [], does: "Designs and comments"),
    Connector(id: "canva", category: .design, name: "Canva", url: "https://mcp.canva.com/mcp", words: [], does: "Designs"),
    Connector(id: "webflow", category: .design, name: "Webflow", url: "https://mcp.webflow.com/mcp", words: [], does: "Sites and content"),
    Connector(id: "sentry", category: .code, name: "Sentry", url: "https://mcp.sentry.dev/mcp", words: [], does: "Errors and issues"),
    Connector(id: "supabase", category: .code, name: "Supabase", url: "https://mcp.supabase.com/mcp", words: [], does: "Databases and projects"),
    Connector(id: "cloudflare", category: .code, name: "Cloudflare", url: "https://bindings.mcp.cloudflare.com/mcp", words: [], does: "Workers, storage and DNS"),
    Connector(id: "stripe", category: .finance, name: "Stripe", url: "https://mcp.stripe.com", words: [], does: "Payments and customers"),
    Connector(id: "paypal", category: .finance, name: "PayPal", url: "https://mcp.paypal.com/mcp", words: [], does: "Payments and invoices"),
    Connector(id: "square", category: .finance, name: "Square", url: "https://mcp.squareup.com/sse", words: [], does: "Sales and catalog"),
    Connector(id: "intercom", category: .communication, name: "Intercom", url: "https://mcp.intercom.com/mcp", words: [], does: "Conversations and contacts"),
    Connector(id: "zapier", category: .productivity, name: "Zapier", url: "https://mcp.zapier.com/api/mcp/mcp", words: [], does: "Actions in your Zaps' apps"),
    Connector(id: "clickup", category: .productivity, name: "ClickUp", url: "https://mcp.clickup.com/mcp", words: [], does: "Tasks, docs and goals"),
    Connector(id: "calendly", category: .productivity, name: "Calendly", url: "https://mcp.calendly.com", words: [], does: "Event types and bookings"),
    Connector(id: "jotform", category: .productivity, name: "Jotform", url: "https://mcp.jotform.com", words: [], does: "Forms and submissions"),
    Connector(id: "tally", category: .productivity, name: "Tally", url: "https://api.tally.so/mcp", words: [], does: "Forms and responses"),
    Connector(id: "lucid", category: .design, name: "Lucid", url: "https://mcp.lucid.app/mcp", words: ["lucidchart", "lucidspark"], does: "Diagrams and boards"),
    Connector(id: "motion", category: .productivity, name: "Motion", url: "https://mcp.motion.so/mcp", words: ["usemotion"], does: "Tasks and calendar plans"),
    Connector(id: "fathom", category: .productivity, name: "Fathom", url: "https://api.fathom.ai/mcp", words: [], does: "Meeting recordings and notes"),
    Connector(id: "ifttt", category: .productivity, name: "IFTTT", url: "https://ifttt.com/mcp", words: [], does: "Applets across your apps"),
    Connector(id: "wordpress", category: .design, name: "WordPress.com", url: "https://public-api.wordpress.com/wpcom/v2/mcp/v1", words: ["wordpress"], does: "Sites, posts and pages"),
    Connector(id: "wix", category: .design, name: "Wix", url: "https://mcp.wix.com/mcp", words: [], does: "Sites, stores and bookings"),
    Connector(id: "contentful", category: .design, name: "Contentful", url: "https://mcp.contentful.com/mcp", words: [], does: "Content models and entries"),
    Connector(id: "sanity", category: .design, name: "Sanity", url: "https://mcp.sanity.io", words: [], does: "Content and datasets"),
    Connector(id: "adobe", category: .design, name: "Adobe", url: "https://adobe-creativity.adobe.io/mcp", words: ["adobe express"], does: "Creative edits and assets"),
    Connector(id: "descript", category: .design, name: "Descript", url: "https://api.descript.com/v2/mcp", words: [], does: "Video and audio projects"),
    Connector(id: "heygen", category: .design, name: "HeyGen", url: "https://mcp.heygen.com/mcp/v1/", words: [], does: "AI videos and avatars"),
    Connector(id: "neon", category: .code, name: "Neon", url: "https://mcp.neon.tech/mcp", words: [], does: "Postgres projects and branches"),
    Connector(id: "prisma", category: .code, name: "Prisma", url: "https://mcp.prisma.io/mcp", words: ["prisma postgres"], does: "Databases and migrations"),
    Connector(id: "postman", category: .code, name: "Postman", url: "https://mcp.postman.com/minimal", words: [], does: "APIs, collections and tests"),
    Connector(id: "sourcegraph", category: .code, name: "Sourcegraph", url: "https://sourcegraph.com/.api/mcp", words: [], does: "Code search"),
    Connector(id: "lovable", category: .code, name: "Lovable", url: "https://mcp.lovable.dev", words: [], does: "Apps and projects"),
    Connector(id: "algolia", category: .code, name: "Algolia", url: "https://mcp.algolia.com/mcp", words: [], does: "Search indexes"),
    Connector(id: "newrelic", category: .code, name: "New Relic", url: "https://mcp.newrelic.com/mcp/", words: ["newrelic"], does: "Observability data"),
    Connector(id: "workos", category: .code, name: "WorkOS", url: "https://mcp.workos.com/mcp", words: [], does: "Users, organizations and SSO"),
    Connector(id: "apify", category: .code, name: "Apify", url: "https://mcp.apify.com", words: [], does: "Web scrapers and actors"),
    Connector(id: "context7", category: .code, name: "Context7", url: "https://mcp.context7.com/mcp/oauth", words: [], does: "Up-to-date library docs"),
    Connector(id: "mercury", category: .finance, name: "Mercury", url: "https://mcp.mercury.com/mcp", words: [], does: "Bank accounts and transactions"),
    Connector(id: "brex", category: .finance, name: "Brex", url: "https://api.brex.com/mcp", words: [], does: "Cards, expenses and budgets"),
    Connector(id: "gocardless", category: .finance, name: "GoCardless", url: "https://mcp.gocardless.com", words: [], does: "Direct debit payments"),
    Connector(id: "gusto", category: .finance, name: "Gusto", url: "https://mcp.api.gusto.com", words: [], does: "Payroll and people"),
    Connector(id: "deel", category: .finance, name: "Deel", url: "https://api.letsdeel.com/mcp", words: [], does: "Contracts, payroll and people"),
    Connector(id: "remote", category: .finance, name: "Remote", url: "https://mcp.remote.com/mcp", words: ["remote.com"], does: "Global payroll and hiring"),
    Connector(id: "attio", category: .sales, name: "Attio", url: "https://mcp.attio.com/mcp", words: [], does: "CRM records and lists"),
    Connector(id: "pipedrive", category: .sales, name: "Pipedrive", url: "https://mcp.pipedrive.ai/mcp", words: [], does: "Deals, contacts and activities"),
    Connector(id: "apollo", category: .sales, name: "Apollo", url: "https://mcp.apollo.io/mcp", words: ["apollo.io"], does: "Prospects and sequences"),
    Connector(id: "zoominfo", category: .sales, name: "ZoomInfo", url: "https://mcp.zoominfo.com/mcp", words: [], does: "Company and contact data"),
    Connector(id: "outreach", category: .sales, name: "Outreach", url: "https://api.outreach.io/mcp/", words: [], does: "Sequences and prospects"),
    Connector(id: "highlevel", category: .sales, name: "HighLevel", url: "https://services.leadconnectorhq.com/mcp/", words: ["gohighlevel", "go high level"], does: "Contacts, pipelines and campaigns"),
    Connector(id: "lemlist", category: .sales, name: "lemlist", url: "https://app.lemlist.com/mcp", words: [], does: "Outreach campaigns"),
    Connector(id: "klaviyo", category: .marketing, name: "Klaviyo", url: "https://mcp.klaviyo.com/mcp", words: [], does: "Email and SMS marketing"),
    Connector(id: "kit", category: .marketing, name: "Kit", url: "https://app.kit.com/mcp", words: ["convertkit"], does: "Email subscribers and broadcasts"),
    Connector(id: "beehiiv", category: .marketing, name: "beehiiv", url: "https://mcp.beehiiv.com/mcp", words: [], does: "Newsletters and subscribers"),
    Connector(id: "bitly", category: .marketing, name: "Bitly", url: "https://api-ssl.bitly.com/v4/mcp", words: [], does: "Short links and clicks"),
    Connector(id: "metricool", category: .marketing, name: "Metricool", url: "https://ai.metricool.com/mcp", words: [], does: "Social posts and analytics"),
    Connector(id: "semrush", category: .marketing, name: "Semrush", url: "https://mcp.semrush.com/v2/mcp", words: [], does: "SEO and keyword data"),
    Connector(id: "amplitude", category: .analytics, name: "Amplitude", url: "https://mcp.amplitude.com/mcp", words: [], does: "Product analytics"),
    Connector(id: "mixpanel", category: .analytics, name: "Mixpanel", url: "https://mcp.mixpanel.com/mcp", words: [], does: "Events, funnels and reports"),
    Connector(id: "posthog", category: .analytics, name: "PostHog", url: "https://mcp.posthog.com/mcp", words: [], does: "Product analytics and flags"),
    // An inbox of an assistant's own (issue #1's "New email"): with "Connected apps it can use",
    // one assistant alone can hold it.
    Connector(id: "agentmail", category: .communication, name: "AgentMail", url: "https://mcp.agentmail.to/mcp", words: ["agent mail"], does: "An email inbox of an assistant's own"),
    Connector(
      id: "github", category: .code, name: "GitHub", url: "https://api.githubcopilot.com/mcp/", words: ["git hub"],
      does: "Repositories, issues and pull requests",
      signIn: .key(KeySignIn(
        name: "personal access token", prefixes: ["github_pat_", "ghp_"],
        page: "https://github.com/settings/personal-access-tokens/new",
        steps: [
          "On GitHub, open Settings › Developer settings › Personal access tokens › Fine-grained tokens, and choose Generate new token.",
          "Choose the repositories Serein may use, and only the permissions it needs, such as Issues and Pull requests.",
          "Generate the token and copy it. GitHub shows it once.",
        ],
        wrongKinds: ["gho_": "That is a token GitHub gave another app. Make a personal access token instead."]))),
    Connector(
      id: "slack", category: .communication, name: "Slack", url: "https://mcp.slack.com/mcp", words: [],
      does: "Channels, messages and search",
      signIn: .key(KeySignIn(
        name: "user token", prefixes: ["xoxp-"], page: "https://api.slack.com/apps",
        steps: [
          "At api.slack.com/apps, choose Create New App, then From scratch, and pick your workspace.",
          "Under Agents, turn on Slack Model Context Protocol (MCP) Server.",
          "Under OAuth & Permissions, add the user token scopes Serein may use, such as search:read.public, channels:history and chat:write.",
          "Install the app to your workspace, then copy the User OAuth Token.",
        ],
        wrongKinds: [
          "xoxb-": "That is a bot token. Copy the User OAuth Token, which starts with xoxp-.",
          "xapp-": "That is an app-level token. Copy the User OAuth Token, which starts with xoxp-.",
        ]))),
    Connector(
      id: "hubspot", category: .sales, name: "HubSpot", url: "https://mcp.hubspot.com/", words: ["hub spot"],
      does: "Contacts, companies and deals", signIn: .composio("hubspot")),
    Connector(id: "similarweb", category: .analytics, name: "Similarweb", url: "https://mcp.similarweb.com", words: [], does: "Website traffic data"),
  ]

  /// Apps the Mac already reaches: Gmail through Mail (an account in Internet Accounts) and Google
  /// Calendar through Calendar. The value is the Mac app's connection id (`ConnectCatalog.macApps`).
  public static let macFallback: [String: String] = [
    "gmail": "mail", "google mail": "mail", "google calendar": "calendar", "gcal": "calendar",
  ]

  public static func byID(_ id: String) -> Connector? { all.first { $0.id == id } }

  /// The connector a person's or a model's words name: its name, id or another word for it,
  /// ignoring case, spaces and a trailing "app".
  public static func find(_ raw: String) -> Connector? {
    let key = normalized(raw)
    guard !key.isEmpty else { return nil }
    return all.first { connector in
      ([connector.name, connector.id] + connector.words).map(normalized).contains(key)
    }
  }

  public static func normalized(_ raw: String) -> String {
    var words = raw.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    if words.count > 1, words.last == "app" { words.removeLast() }
    return words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
