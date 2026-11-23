import Foundation

/// Where an assistant's computer runs (Settings › Serein's computer › Where it runs, one choice
/// per assistant): a container on this Mac through Docker, Serein's built-in computer (a virtual
/// machine Serein runs itself, the default without Docker, `defaultPlace`), E2B's or Daytona's
/// servers under the person's own account, or the person's own computer or VM over SSH
/// (OwnComputer.swift). Hosted and own computers are opt-in.
public enum ComputerPlace: String, Codable, Sendable, CaseIterable {
  case docker, builtIn, macOS, e2b, daytona, ownDesktop, ownMachine
  /// Persisted by earlier editions. Keep it readable until the person chooses another location.
  case unavailable = "sereinCloud"
  public static let unavailableReason = "This computer location is unavailable in Serein Free. Choose another location in Settings › Serein’s computer."
  public static let unavailableMove = "Choosing a new location clears this computer’s saved checkpoint and notes on this Mac. Its remote files stay where they are."

  public var label: String {
    switch self {
    case .docker: return "Docker on this Mac"
    case .builtIn: return "Serein's built-in computer"
    case .macOS: return "Virtual Mac"
    case .e2b: return "E2B"
    case .daytona: return "Daytona"
    case .ownDesktop: return "Your computer: a desktop for Serein"
    case .ownMachine: return "Your computer as it is"
    case .unavailable: return "Unavailable location"
    }
  }
  public var capabilities: ComputerCapabilities {
    switch self {
    case .docker: return .docker
    case .builtIn: return .builtIn
    case .macOS: return .macOS
    case .e2b: return .e2b
    case .daytona: return .daytona
    case .ownDesktop: return .ownDesktop
    case .ownMachine: return .ownMachine
    case .unavailable: return .unavailable
    }
  }
  /// The person's own machine, reached over SSH.
  public var isOwn: Bool { self == .ownDesktop || self == .ownMachine }
}

/// What a computer's backend can do. The settings page, the first-use card, the network decision
/// and the start-up read these; nothing about a provider is assumed beyond what its documentation
/// promises (E2B: https://docs.e2b.dev/network/internet-access, /sandbox/persistence; Daytona:
/// https://www.daytona.io/docs/en/network-limits.md, /linux-sandboxes.md).
public struct ComputerCapabilities: Equatable, Sendable {
  /// Pause keeps the apps inside running in memory, so they carry on where they were on resume.
  public var pauseKeepsMemory: Bool
  /// Open command streams outlive a pause (Docker freezes them; a hosted pause ends them, so
  /// Serein closes them first and opens new ones on resume).
  public var linksSurvivePause: Bool
  /// The computer's own internet can be switched off while commands and files keep working.
  public var ownInternetOff: Bool
  /// Serein's proxy can be carried over the command stream (the helper's shim), so the computer
  /// reaches the web only through this Mac.
  public var carriesProxy: Bool
  /// The provider holds the computer's own internet to a list of sites it enforces.
  public var enforcedAllowlist: Bool
  /// The person may give the computer the provider's own internet with no list Serein can have
  /// enforced; the first-use card says Serein can't limit it.
  public var openInternet: Bool
  /// A reset replaces the computer: the old one is deleted with everything in it, and the next
  /// start makes a new one and puts the checkpoint back into it.
  public var resetMakesNew: Bool
  /// Settings' memory and processor limits apply (a hosted computer's size comes from its template).
  public var memoryLimits: Bool
  /// Running it may cost money on the person's account: the first-use card and the schedule rule apply.
  public var paid: Bool
  /// Serein's own computer, holding nothing of the person's: steps inside need no card, and
  /// Throwaway, Reset and checkpoints apply. False for the person's own machine used as it is:
  /// every act asks (OwnMachinePolicy), and Serein never empties, resets or archives it.
  public var isolated: Bool

  public static let docker = ComputerCapabilities(
    pauseKeepsMemory: true, linksSurvivePause: true, ownInternetOff: true, carriesProxy: true, enforcedAllowlist: false,
    openInternet: false, resetMakesNew: false, memoryLimits: true, paid: false, isolated: true)
  /// The built-in computer has no network card at all; Pause saves its memory to disk and stops it,
  /// which ends its links, and a reset puts its whole disk back (VirtualMachineComputer).
  public static let builtIn = ComputerCapabilities(
    pauseKeepsMemory: true, linksSurvivePause: false, ownInternetOff: true, carriesProxy: true, enforcedAllowlist: false,
    openInternet: false, resetMakesNew: false, memoryLimits: true, paid: false, isolated: true)
  /// A persistent native macOS guest. Networking stays off until the person explicitly allows
  /// Apple's NAT. No proxy, home-folder resets, shell streams or shared personal folders.
  public static let macOS = ComputerCapabilities(
    pauseKeepsMemory: true, linksSurvivePause: false, ownInternetOff: true, carriesProxy: false, enforcedAllowlist: false,
    openInternet: true, resetMakesNew: false, memoryLimits: false, paid: false, isolated: true)
  public static let e2b = ComputerCapabilities(
    pauseKeepsMemory: true, linksSurvivePause: false, ownInternetOff: true, carriesProxy: true, enforcedAllowlist: true,
    openInternet: false, resetMakesNew: true, memoryLimits: false, paid: true, isolated: true)
  /// A Linux VM sandbox (its own kernel; pause keeps memory). Daytona blocks a sandbox's own
  /// internet, or holds it to a list of sites (`domainAllowList`), only on its Tiers 3 and 4, so
  /// each computer's block or list is confirmed on Daytona's own record before use (the block also
  /// from inside), and refused where Daytona does not enforce it. Its own internet can also be left
  /// open on the person's Widening card, which Serein can't limit.
  public static let daytona = ComputerCapabilities(
    pauseKeepsMemory: true, linksSurvivePause: false, ownInternetOff: true, carriesProxy: true, enforcedAllowlist: true,
    openInternet: true, resetMakesNew: true, memoryLimits: false, paid: true, isolated: true)
  /// Serein's container on the person's machine over SSH: `docker pause` freezes it with its
  /// streams, it has no network of its own and the proxy is carried over its stream.
  public static let ownDesktop = ComputerCapabilities(
    pauseKeepsMemory: true, linksSurvivePause: true, ownInternetOff: true, carriesProxy: true, enforcedAllowlist: false,
    openInternet: false, resetMakesNew: false, memoryLimits: true, paid: false, isolated: true)
  /// The person's machine as it is: its own internet, which Serein cannot limit; Pause only ends
  /// Serein's link (the machine and its apps carry on).
  public static let ownMachine = ComputerCapabilities(
    pauseKeepsMemory: true, linksSurvivePause: false, ownInternetOff: false, carriesProxy: false, enforcedAllowlist: false,
    openInternet: false, resetMakesNew: false, memoryLimits: false, paid: false, isolated: false)
  fileprivate static let unavailable = ComputerCapabilities(
    pauseKeepsMemory: false, linksSurvivePause: false, ownInternetOff: false, carriesProxy: false, enforcedAllowlist: false,
    openInternet: false, resetMakesNew: false, memoryLimits: false, paid: false, isolated: false)
}

/// How a hosted computer reaches the web. "Through this Mac" (the default): the provider switches
/// the computer's own internet off, and its only way out is Serein's proxy over the command
/// stream, so the person's site rules, the assistant's Never sites, the private-range refusals and
/// the host log apply exactly as on Docker. "Provider internet" is the person's opt-in for one
/// computer: the provider's own internet, held to an allowlist the provider enforces (E2B; Daytona
/// on its Tiers 3 and 4), or, where the person turned the list off on a Widening card and the
/// provider allows it (Daytona), open; Serein cannot limit it beyond the list, or at all when
/// open, and the first-use card says so.
public enum HostedNetwork: Equatable, Sendable {
  case throughThisMac
  case provider(allow: [String])
  case providerOpen

  public enum Decision: Equatable, Sendable {
    case use(HostedNetwork)
    case refuse(String)
  }
  /// Sites an allowlist may hold.
  public static let maxAllow = 100

  /// The mode a hosted computer starts with, or why it does not start. Through this Mac is used
  /// only when the provider can switch the computer's own internet off and carry Serein's proxy;
  /// nothing weaker stands in for it. Provider internet needs the person's switch, and either an
  /// allowlist the provider enforces with at least one site on it, or (`listOnly` off, which only
  /// a Widening card turns off) a provider that offers its internet open.
  public static func decide(
    _ capabilities: ComputerCapabilities, providerInternet: Bool, allowlist: [String], listOnly: Bool = true
  ) -> Decision {
    if providerInternet {
      if !listOnly {
        guard capabilities.openInternet else {
          return .refuse("This provider's own internet is used here only held to a list of sites. The user turns Only these sites on in Settings › Serein's computer.")
        }
        return .use(.providerOpen)
      }
      guard capabilities.enforcedAllowlist else {
        return .refuse("This provider cannot hold a computer's internet to a list of sites, so Serein does not use its internet. Turn that off in Settings › Serein's computer.")
      }
      let allow = clean(allowlist)
      guard !allow.isEmpty else {
        return .refuse(
          "This computer is set to use its provider's own internet held to a list of sites, but no site is on the list. The user adds a site in Settings › Serein's computer, or turns the provider's internet off so it goes through this Mac."
            + (capabilities.openInternet ? " On this provider the user can also turn off Only these sites, which Serein can't limit." : ""))
      }
      return .use(.provider(allow: allow))
    }
    guard capabilities.ownInternetOff, capabilities.carriesProxy else {
      return .refuse("This provider cannot switch off the computer's own internet and carry Serein's proxy, so the computer does not start: its internet would not go through this Mac.")
    }
    return .use(.throughThisMac)
  }

  /// The browser and every command inside reach the web through Serein's proxy shim.
  public var usesProxy: Bool { self == .throughThisMac }

  /// Hosts a new computer held to a list tries from inside: the address and the services
  /// Daytona's Tiers 1 and 2 leave open whatever a sandbox asks. One that answers means the list
  /// is not held.
  public static let listCanaries = ["1.1.1.1", "github.com", "registry.npmjs.org", "pypi.org"]
  /// The canaries off the person's list (a listed one proves nothing). Never empty: an address
  /// is never on a list.
  public static func canaries(off allow: [String]) -> [String] {
    listCanaries.filter { host in !allow.contains { ComputerAllowlist.matches(host: host, entry: $0) } }
  }

  /// One allowlist site as the provider takes it: a name (`example.com`) or every name under one
  /// (`*.example.com`), lower case. Never an address or a range: an allowed address opens every
  /// port on it, and the person's list is meant to name sites. nil for anything else.
  public static func allowEntry(_ raw: String) -> String? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if text.hasSuffix(".") { text.removeLast() }
    let wildcard = text.hasPrefix("*.")
    let name = wildcard ? String(text.dropFirst(2)) : text
    let labels = name.split(separator: ".", omittingEmptySubsequences: false)
    guard !name.isEmpty, name.count <= 253, !name.contains(":"), ComputerNetworkPolicy.plainHost(name),
      labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }),
      ComputerNetworkPolicy.ipv4(name) == nil, labels.last?.contains(where: \.isLetter) == true
    else { return nil }
    return wildcard ? "*." + name : name
  }
  /// The valid sites of a list, each once, in order, at most `limit`.
  public static func clean(_ entries: [String], limit: Int = maxAllow) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for entry in entries {
      guard out.count < limit else { break }
      guard let site = allowEntry(entry), seen.insert(site).inserted else { continue }
      out.append(site)
    }
    return out
  }
}

/// Spending on a hosted computer, enforced by Serein rather than left to the provider.
public enum HostedSpending {
  /// Why a paid computer may not start for this run, or nil. A run nobody started by hand (a
  /// schedule, a watch or a webhook) never creates or wakes one unless the person turned that on
  /// for this assistant (off by default); one already running costs nothing new to use.
  public static func startRefusal(
    paid: Bool, running: Bool, unattended: Bool, allowedUnattended: Bool, provider: String, assistant: String
  ) -> String? {
    guard paid, !running, unattended, !allowedUnattended else { return nil }
    return "\(assistant)'s computer runs on \(provider) and may cost the user money, so a scheduled run, an alert or a webhook does not start it. The user can turn that on for \(assistant) in Settings › Serein's computer, or start the computer while they are here."
  }
}

/// What a hosted computer has cost. Daytona reports a price per sandbox through its usage API
/// (https://www.daytona.io/docs/analytics-openapi.json), shown as its report. E2B has no cost
/// endpoint, and Daytona's report can be missing (a key without billing access) or late, so
/// otherwise this is Serein's estimate from the computer's size and running time at the published
/// per-second prices, always labelled as such.
public enum HostedUsage {
  public static let label = "Serein's estimate"
  /// The published rates per second, per vCPU and per GiB of memory; E2B and Daytona publish the
  /// same two (https://docs.e2b.dev/faq/calculate-sandbox-price, https://www.daytona.io/pricing;
  /// Daytona's disk past 5 GiB is left out). Paused and deleted computers are not billed for these.
  public static let cpuSecond = 0.000014
  public static let gibSecond = 0.0000045

  public static func dollars(cpuCount: Int, memoryMB: Int, seconds: Double) -> Double {
    let cpus: Double = Double(max(0, cpuCount))
    let gibibytes: Double = Double(max(0, memoryMB)) / 1024
    let perSecond: Double = cpus * cpuSecond + gibibytes * gibSecond
    return max(0, seconds) * perSecond
  }
  static func money(_ dollars: Double) -> String {
    dollars < 0.01 ? "under $0.01" : String(format: "about $%.2f", dollars)
  }
  public static func line(dollars: Double, seconds: Double) -> String {
    let minutes = Int((max(0, seconds) / 60).rounded())
    return "\(label): \(money(dollars)) for \(minutes) minute\(minutes == 1 ? "" : "s") running"
  }

  /// Running time Serein has seen, with the size the provider reported for the computer, and the
  /// price the provider itself reported, when it does.
  public struct Spent: Codable, Equatable, Sendable {
    public var seconds: Double
    public var cpuCount: Int?
    public var memoryMB: Int?
    public var reported: Double?
    public init(seconds: Double = 0, cpuCount: Int? = nil, memoryMB: Int? = nil, reported: Double? = nil) {
      self.seconds = seconds
      self.cpuCount = cpuCount
      self.memoryMB = memoryMB
      self.reported = reported
    }
    /// The provider's report when there is one, otherwise the estimate once the size is known.
    public func line(provider: String) -> String? {
      if let reported { return "\(provider)'s report: \(HostedUsage.money(reported)) so far" }
      guard let cpuCount, let memoryMB else { return nil }
      return HostedUsage.line(dollars: HostedUsage.dollars(cpuCount: cpuCount, memoryMB: memoryMB, seconds: seconds), seconds: seconds)
    }
  }
}

/// One assistant's hosted-computer settings and record, kept in the Library with the computer's
/// mode (`computers/state.json`). Nothing here is a secret: the key lives in Keychain only.
public struct HostedSettings: Codable, Equatable, Sendable {
  /// The provider's id for the computer, so it is resumed after a relaunch instead of made again.
  public var sandboxID: String?
  /// Paused E2B sandbox kept until its checkpoint replacement is usable.
  public var checkpointSourceID: String?
  /// Written before a billable create, retained with its ID until startup and restore succeed.
  public var e2bCreateAttempt: String?
  /// The person's opt-in to the provider's own internet for this computer, and its allowlist.
  public var providerInternet: Bool
  public var allowlist: [String]
  /// The provider's own internet is held to `allowlist` (on unless a Widening card turned it off;
  /// only a provider that offers its internet open can start with it off).
  public var listOnly: Bool
  /// The person's switch that lets a schedule, a watch or a webhook start this paid computer.
  public var fromSchedules: Bool
  /// The first-use card the person accepted; a card with other words (a new internet setting)
  /// asks again.
  public var acceptedCard: String?
  public var spent: HostedUsage.Spent

  enum CodingKeys: String, CodingKey {
    case sandboxID, checkpointSourceID, e2bCreateAttempt, providerInternet, allowlist, listOnly, fromSchedules, acceptedCard, spent
  }
  public init() {
    sandboxID = nil
    providerInternet = false
    allowlist = []
    listOnly = true
    fromSchedules = false
    acceptedCard = nil
    spent = HostedUsage.Spent()
  }
  /// Every field is optional on disk, so a record from an older Serein reads with the defaults.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    sandboxID = try c.decodeIfPresent(String.self, forKey: .sandboxID)
    e2bCreateAttempt = try c.decodeIfPresent(String.self, forKey: .e2bCreateAttempt)
    checkpointSourceID = try c.decodeIfPresent(String.self, forKey: .checkpointSourceID)
    providerInternet = try c.decodeIfPresent(Bool.self, forKey: .providerInternet) ?? false
    allowlist = HostedNetwork.clean(try c.decodeIfPresent([String].self, forKey: .allowlist) ?? [])
    // A record from before the list could be turned off holds its sites to the list.
    listOnly = try c.decodeIfPresent(Bool.self, forKey: .listOnly) ?? true
    fromSchedules = try c.decodeIfPresent(Bool.self, forKey: .fromSchedules) ?? false
    acceptedCard = try c.decodeIfPresent(String.self, forKey: .acceptedCard)
    spent = try c.decodeIfPresent(HostedUsage.Spent.self, forKey: .spent) ?? HostedUsage.Spent()
  }
  /// The provider-internet list in the shape the Widening rules judge (ComputerAllowlist).
  public var providerList: ComputerAllowlist {
    get { ComputerAllowlist(only: listOnly, sites: allowlist) }
    set {
      listOnly = newValue.only
      allowlist = HostedNetwork.clean(newValue.sites)
    }
  }
}

/// The words of a hosted computer's first-use card (ApprovalGate `hostedStart`) and its refusals.
public enum HostedCard {
  public static func title(assistant: String, provider: String) -> String {
    "Start \(assistant)'s computer on \(provider)?"
  }
  /// Where the computer runs, what Serein sends there, how its internet goes, and that it may
  /// cost money, in plain words.
  public static func detail(place: ComputerPlace, network: HostedNetwork) -> String {
    let provider = place.label
    let internet: String
    switch network {
    case .throughThisMac:
      internet = "Its internet goes through this Mac. Its web traffic leaves from your own connection."
    case .provider(let allow):
      let sites = allow.count == 1 ? allow[0] : "\(allow.count) sites you allowed"
      // E2B opens its DNS server to every computer with a list (https://docs.e2b.dev/network/internet-access).
      let dns = place == .e2b ? " and E2B's DNS server" : ""
      internet = "Its internet is \(provider)'s own, open to \(sites)\(dns). Serein cannot limit it beyond that list or apply your site rules there."
    case .providerOpen:
      internet = "Its internet is \(provider)'s own. \(openLine) Your site rules don't apply there, and it can reach sites they would block, including code hosts and AI services."
    }
    return "This computer runs on \(provider)'s servers. Serein sends it the commands, files and screen input for this task. \(internet) Your \(provider) key never goes into the computer. A paused computer stays on your \(provider) account until you delete it. \(provider) may charge your account for the time it runs."
  }
  /// The line every card and setting shows where the provider's own internet is open.
  public static let openLine = "Serein can't limit this computer's internet."
  public static func noKey(_ provider: String) -> String {
    "This assistant's computer runs on \(provider), and no \(provider) key is saved. The user adds one in Settings › Serein's computer."
  }
  public static func notConfirmed(_ provider: String) -> String {
    "\(provider) did not confirm the internet setting Serein asked for, so Serein did not use that computer."
  }
  public static func notSealed(_ provider: String) -> String {
    "\(provider) says this computer's own internet is off, but it reached the internet without Serein, so Serein did not use it."
  }
  public static func notHeld(_ provider: String) -> String {
    "\(provider) says this computer's internet is held to your list of sites, but it reached a site that is not on it, so Serein did not use it. On \(provider)'s Tiers 1 and 2 the list is not enforced: turn off Only these sites (Serein can't limit it then), or turn \(provider)'s internet off."
  }
  /// A template or snapshot from before the inside check: its helper cannot run it.
  public static func oldHelper(_ provider: String) -> String {
    "Serein could not check from inside that this computer's own internet is off, because its helper is older than this Serein, so Serein did not use it. "
      + rebuild(provider)
  }
  public static func rebuild(_ provider: String) -> String {
    "Rebuild the \(provider) \(provider == "E2B" ? "template" : "snapshot") from the folder Show Recipe opens, then Reset this computer in Settings › Serein's computer."
  }
  public static func declined(_ provider: String) -> String { "The user did not start the computer on \(provider)." }
  public static func needsPerson(_ provider: String) -> String {
    "Starting this computer on \(provider) needs the user's answer on a card the first time, and nobody is here to give it."
  }
}
