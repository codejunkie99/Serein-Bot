import Foundation

/// Folders an agent CLI must never read, whatever the mode. The CLIs are child processes of
/// Serein, so they inherit any privacy access macOS gave Serein (for example Full Disk Access).
/// Claude Code uses scoped tool rules and a strict shell sandbox. Codex uses a named filesystem
/// profile; the older read-only sandbox is insufficient because it permits unrelated reads.
public enum AgentFileGuard {
  /// The native Claude fixture verifies the strict sandbox and environment scrub on this version.
  /// Older CLIs can silently ignore newer settings, so file tasks fail closed until updated.
  public static let minimumClaudeVersion = "2.1.296"
  /// Mail, messages, browser profiles and cookies, SSH keys and keychains, relative to home.
  public static let protectedHomePaths = [
    "Library/Mail",
    "Library/Containers/com.apple.mail",
    "Library/Messages",
    "Library/Safari",
    "Library/Containers/com.apple.Safari",
    "Library/Cookies",
    "Library/Keychains",
    "Library/Application Support/Google/Chrome",
    "Library/Application Support/Chromium",
    "Library/Application Support/Arc",
    "Library/Application Support/BraveSoftware",
    "Library/Application Support/Microsoft Edge",
    "Library/Application Support/Vivaldi",
    "Library/Application Support/com.operasoftware.Opera",
    "Library/Application Support/Perplexity",
    "Library/Application Support/Firefox",
    "Library/Application Support/zen",
    ".ssh",
    ".aws", ".azure", ".gnupg", ".kube", ".docker", ".config/gcloud",
    ".codex", ".claude", ".config/opencode",
    // Payment and wallet keys: the Stripe CLI's login, Solana and Foundry keystores, node wallets.
    ".config/stripe", ".config/solana", ".foundry/keystores", ".ethereum", ".bitcoin", ".electrum",
    // Sign-ins of agents Serein no longer runs, which may still be on the Mac.
    ".hermes", ".commandcode",
  ]
  /// System-wide folders denied the same way.
  public static let protectedSystemPaths = ["/Library/Keychains"]

  /// The protected folders plus every harness's own home (`harnessHomes`), which holds its
  /// sign-in, except `driver`'s: a harness under `ownSetupProfile` keeps its own home open, and
  /// Claude Code and Codex (no entry there) never read another harness's sign-in.
  public static func protectedPaths(home: URL, except driver: HarnessDriver? = nil) -> [String] {
    (protectedHomePaths + harnessHomes.filter { $0.key != driver }.sorted { $0.key.rawValue < $1.key.rawValue }.flatMap(\.value))
      .map { home.appendingPathComponent($0).standardizedFileURL.path } + protectedSystemPaths
  }
  /// Each harness's own home, which holds its sign-in. A harness under `ownSetupProfile` keeps
  /// only its own open. ponytail: the default spellings; a home moved by GROK_HOME or
  /// PI_CODING_AGENT_DIR is not closed.
  static let harnessHomes: [HarnessDriver: [String]] = [
    .pi: [".pi"], .ohMyPi: [".omp"], .grok: [".grok"], .gemini: [".gemini"], .cursor: [".cursor"],
    .opencode: [".local/share/opencode"],
  ]
  /// The only part of its home a guarded turn writes: the state each harness was measured to write.
  /// The rest holds what its next launch runs or loads, guarded or not, so it stays read-only. A
  /// harness with no entry keeps its whole home writable: Oh My Pi and Gemini CLI were never run
  /// here.
  static let harnessState: [HarnessDriver: [String]] = [
    .pi: piState, .opencode: openCodeState, .cursor: cursorState, .grok: grokState,
  ]
  /// Pi 0.55.3 writes its sessions and its auth.json lock folder (measured) and saves auth.json in
  /// place (from its source). Closed: settings.json (its shell, packages and extension lists),
  /// extensions, skills, prompts, themes, AGENTS.md, models.json, mcp.json and the fd and rg it
  /// runs from bin.
  static let piState = ["sessions", "auth.json", "auth.json.lock"].map { ".pi/agent/" + $0 }
  /// OpenCode 2.2.4 writes its database (sign-ins included), log and shell output; tool-output,
  /// storage and the legacy auth.json are assumed from its source. Closed: its snapshot git folders
  /// (a planted config or hook runs at the next snapshot), and all of ~/.local/state/opencode and
  /// ~/.cache/opencode (plugin records, provider packages, downloaded tools); a turn ends without them.
  static let openCodeState = [
    "opencode.db", "opencode.db-wal", "opencode.db-shm", "opencode.db-journal", "log", "shell", "tool-output",
    "storage", "auth.json",
  ].map { ".local/share/opencode/" + $0 }
  /// Cursor 2026.05.28 is signed out here, so this is from its source and the start of a turn
  /// (measured: it creates projects/<folder>). Its chats, ACP sessions, project folders (MCP
  /// sign-ins included) and tracking database; cli-config.json, which it saves through a `.tmp` at
  /// start, on a model change and on sign-in and whose failure it does not catch. Closed: hooks.json,
  /// mcp.json, rules, commands, skills, agents, plugins, extensions, permissions.json,
  /// sandbox.json, acp-config.json and each project's MCP approvals (`stateRules`).
  static let cursorState = [
    "chats", "acp-sessions", "projects", "ai-tracking", "cli-config.json", "cli-config.json.tmp", "cli-config.json.bad",
  ].map { ".cursor/" + $0 }
  /// The only part of ~/.grok a guarded Grok turn writes. The rest holds what its next launch
  /// runs or loads, guarded or not: config.toml, hooks, plugins and their registry, skills, agents,
  /// lsp.json, memory, completions and its own binary. Its model, settings and experiment caches
  /// stay read-only too; it fetches them again.
  static let grokState = [
    "sessions", "logs", "memtrace", "process-records", "agent_id", "auth.json", "auth.json.lock", "auth.json.commit.lock",
    "worktrees.db", "worktrees.db-wal", "worktrees.db-shm", "worktrees.db-journal",
    "managed_config.lock", "models_cache.json.lock", "installed-plugins/registry.lock",
  ].map { ".grok/" + $0 }
  /// Grok's lock slots and per-session folders, outside the per-user temp folder.
  static let grokSharedTemp = ["/private/tmp/grok-file-lock-\(getuid())", "/private/tmp/sessions"]
  /// What a guarded turn writes outside its folder: the per-user temp folder, /dev, and the
  /// harness's own state (its whole home when it has none listed). Everything else stays
  /// read-only to it and to its shell.
  public static func writableRoots(home: URL, driver: HarnessDriver, folder: URL?) -> [String] {
    [folder?.path, FileManager.default.temporaryDirectory.path, "/dev"].compactMap { $0 }
      + (harnessState[driver] ?? harnessHomes[driver] ?? []).map { home.appendingPathComponent($0).path }
      + (driver == .grok ? grokSharedTemp : [])
  }
  /// Writes a `writable` profile allows past its roots, or closes inside them. Grok saves through
  /// `.<pid>.<n>.tmp` files and renames them over its state in ~/.grok (measured; the auth.json
  /// spelling assumed): its refresh token rotates, so a lost auth.json save signs the person out.
  /// Cursor's projects keep which MCP servers start without asking; those stay closed.
  static func stateRules(home: URL, driver: HarnessDriver) -> String {
    switch driver {
    case .grok: "(allow file-write* " + homeRegex(home, ".grok/", #"(\.[0-9]+\.[0-9]+\.tmp|auth\.json\.tmp\.[0-9]+\.[0-9]+)$"#) + ")\n"
    case .cursor: "(deny file-write* " + homeRegex(home, ".cursor/projects/", #"[^/]+/mcp-(approvals|disabled)\.json$"#) + ")\n"
    default: ""
    }
  }
  /// A sandbox regex for `rest` under `folder` of the home, in both of its spellings.
  private static func homeRegex(_ home: URL, _ folder: String, _ rest: String) -> String {
    Set([home.path, physicalPath(home.path)]).sorted()
      .map { "(regex #\"^" + NSRegularExpression.escapedPattern(for: $0 + "/" + folder) + rest + "\")" }
      .joined(separator: " ")
  }
  /// The MCP server lists a harness loads besides its own config, closed outside own setup so only
  /// Serein's servers start: Claude Code's `~/.claude.json` (Grok, and any CLI reading it), and for
  /// Grok the folder's `.mcp.json` and `.grok/config.toml`, which it loads untrusted.
  public static func foreignToolLists(home: URL, driver: HarnessDriver, folder: URL?) -> [String] {
    let folderLists = driver == .grok ? [".mcp.json", ".grok/config.toml"].compactMap { folder?.appendingPathComponent($0).path } : []
    return [home.appendingPathComponent(".claude.json").path] + folderLists
  }
  /// Closed only under `ownSetupProfile`, not for Claude Code and Codex, whose project tasks may
  /// need git and gh: every WebKit app's website data and cookies (Serein's included), Serein's
  /// own folder, plain token files, and desktop agents' sign-ins.
  static let ownSetupHomePaths = [
    "Library/HTTPStorages", "Library/WebKit", "Library/Application Support/Serein",
    "Library/Preferences/local.serein.browser.plist",
    ".config/gh", ".git-credentials", ".netrc",
    "Library/Application Support/Cursor", "Library/Application Support/Claude",
  ]
  /// Serein's own data, which no agent reads or writes outside Library mode's copies, whatever
  /// folder it works in: the `library` (recordings, downloads, checkpoints, sessions, pairings,
  /// step pictures; it can live anywhere with SEREIN_DATA_DIR), Serein's support and cache
  /// folders, the website data and caches macOS keeps under its bundle id, and two files: its
  /// cookie jar beside HTTPStorages and its settings (which hold consents).
  public static func sereinPrivateRoots(home: URL, library: URL?) -> [URL] {
    let names: [String] = [
      "Library/Application Support/Serein", "Library/Caches/Serein", "Library/Caches/local.serein.browser",
      "Library/WebKit/local.serein.browser", "Library/HTTPStorages/local.serein.browser",
      "Library/HTTPStorages/local.serein.browser.binarycookies", "Library/Preferences/local.serein.browser.plist"]
    var roots: [URL] = []
    if let library { roots.append(library) }
    if let storage = GateSettings.shared.string(forKey: MacComputerPolicy.storageKey) {
      roots.append(URL(fileURLWithPath: storage, isDirectory: true))
    }
    for name in names { roots.append(home.appendingPathComponent(name)) }
    return roots
  }
  /// Serein's own run files: the browser socket with every task's capability, and the helpers'
  /// folder and files. In Serein's caches, a private root every guard closes; a guarded CLI gets
  /// back only its own task's files.
  public static var runRoot: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Serein/run", isDirectory: true)
  }
  /// The private roots a Codex profile denies around `workRoot`, in the spelling `codexProfile`
  /// gives the work root: every one, except one that holds the work root, whose rest the
  /// profile's `:root` deny keeps closed (a denied root would win over the work root's read). The
  /// only such work root is Anywhere in the library: AgentModel.send refuses a project inside
  /// Serein's own data and gives other modes Anywhere in its place.
  public static func privateDenies(_ roots: [URL], workRoot: URL) -> [String] {
    let work = workRoot.resolvingSymlinksInPath().standardizedFileURL.path
    return roots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
      .filter { !within(work, $0) }
  }
  /// Where an absolute `path` leads when it is opened. The longest part of it that exists, as
  /// written, is resolved by the system, so `link/..` climbs from the link's target as the kernel
  /// does, not from the link (a lexical clean-up would say it never left the folder). The rest,
  /// which does not exist yet, follows with `.` and `..` applied; a link whose target does not
  /// exist is followed as a write would follow it, up to the system's 32 links.
  public static func physicalPath(_ path: String) -> String { resolve(path, hops: 0) }
  private static func resolve(_ path: String, hops: Int) -> String {
    var parts = path.split(separator: "/").map(String.init)
    var tail: [String] = []
    while true {
      let prefix = "/" + parts.joined(separator: "/")
      if let resolved = realpath(prefix, nil) {
        var out = String(cString: resolved).split(separator: "/").map(String.init)
        free(resolved)
        for part in tail where part != "." {
          if part == ".." { _ = out.popLast() } else { out.append(part) }
        }
        return "/" + out.joined(separator: "/")
      }
      if hops < 32, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: prefix) {
        let base = target.hasPrefix("/") ? target : "/" + parts.dropLast().joined(separator: "/") + "/" + target
        return resolve(([base] + tail).joined(separator: "/"), hops: hops + 1)
      }
      guard let last = parts.popLast() else { return URL(fileURLWithPath: path).standardizedFileURL.path }
      tail.insert(last, at: 0)
    }
  }
  /// True when the absolute `path` leads into one of `roots`, both resolved as they are opened.
  public static func leadsInto(_ path: String, roots: [URL]) -> Bool {
    let real = physicalPath(path)
    return roots.contains { within(real, physicalPath($0.path)) }
  }
  /// A project folder that would hold Serein's own data: the home folder, ~/Library, or a folder
  /// that is or holds one of `sereinPrivateRoots`. Adding one is allowed; the person is told.
  public static func holdsSereinData(_ folder: String, home: URL, library: URL) -> Bool {
    let real = physicalPath(folder)
    let homePath = physicalPath(home.path)
    return real == homePath || real == physicalPath(homePath + "/Library")
      || sereinPrivateRoots(home: home, library: library).contains { within(physicalPath($0.path), real) }
  }
  /// `path` is `folder` or inside it.
  static func within(_ path: String, _ folder: String) -> Bool {
    path == folder || folder == "/" || path.hasPrefix(folder + "/")
  }

  /// The macOS sandbox profile for harnesses that read files without asking Serein (Grok and
  /// Gemini CLI, HarnessPolicy.ownSetupDrivers; Pi and Oh My Pi): everything as usual, except
  /// no read or write under the protected folders (with the other harnesses' homes), the paths
  /// above and Serein's own data (`sereinPrivateRoots`, with `library`), in their own and their
  /// resolved spelling. `workspace`, the task's own folder, stays open only when it is the
  /// library's Anywhere folder. `extra` is closed, inside that folder too. `writable`, when set, is the only place
  /// writes go (`writableRoots`); the closed folders stay closed inside it.
  /// `openHome` (Allow all) adds home to `writable`; the harness's own home keeps only its state
  /// writable, as what its next launch loads lives there.
  public static func ownSetupProfile(
    home: URL, driver: HarnessDriver, library: URL? = nil, workspace: URL? = nil, extra: [String] = [],
    writable: [String]? = nil, openHome: Bool = false
  ) -> String {
    let closed = closedPaths(home: home, driver: driver, library: library)
    let anywhere = library?.appendingPathComponent("Anywhere").standardizedFileURL.path
    let open = [workspace?.standardizedFileURL.path].compactMap { $0 }.filter { $0 == anywhere }
    // The last matching rule wins, so the open folder comes after the closed ones. Serein's own
    // settings go through cfprefsd (`defaults`), which writes them outside the sandbox, past any
    // file rule and past a preference-domain rule (both tried): the harness gets no cfprefsd, so
    // its shell cannot read Serein's settings. The gate switches and consents are not there at all
    // but in the Library (GateSettings), which this profile closes with the rest.
    let ownHome = openHome ? (harnessHomes[driver] ?? []).map { home.appendingPathComponent($0).path } : []
    let fence = writable.map { roots in
      let state = roots.filter { root in ownHome.contains { within(root, $0) } }
      return "(deny file-write* (subpath \"/\"))\n(allow file-write* " + subpaths(roots + (openHome ? [home.path] : [])) + ")\n"
        + (ownHome.isEmpty ? "" : "(deny file-write* " + subpaths(ownHome) + ")\n")
        + (ownHome.isEmpty || state.isEmpty ? "" : "(allow file-write* " + subpaths(state) + ")\n")
        + stateRules(home: home, driver: driver)
    } ?? ""
    return "(version 1)\n(allow default)\n" + fence + "(deny file-read* file-write* file-link " + subpaths(closed) + ")\n"
      + (open.isEmpty ? "" : "(allow file-read* file-write* " + subpaths(open) + ")\n")
      + (extra.isEmpty ? "" : "(deny file-read* file-write* file-link " + subpaths(extra) + ")\n")
      + noPreferences
  }

  /// Other CLIs' sign-ins, the protected folders and Serein's own data: closed to `driver`.
  static func closedPaths(home: URL, driver: HarnessDriver, library: URL?) -> [String] {
    protectedPaths(home: home, except: driver)
      + ownSetupHomePaths.map { home.appendingPathComponent($0).standardizedFileURL.path }
      + sereinPrivateRoots(home: home, library: library).map(\.standardizedFileURL.path)
  }
  /// The sandbox for a command on the person's own Mac (`mac_run`, LocalExecution): everything as
  /// usual except the protected folders with every harness's home, the token and sign-in files of
  /// `ownSetupProfile`, and Serein's own data and settings service.
  public static func shellProfile(home: URL, library: URL?) -> String {
    let closed = protectedPaths(home: home)
      + ownSetupHomePaths.map { home.appendingPathComponent($0).standardizedFileURL.path }
      + sereinPrivateRoots(home: home, library: library).map(\.standardizedFileURL.path)
    return "(version 1)\n(allow default)\n(deny file-read* file-write* file-link " + subpaths(closed) + ")\n" + noPreferences
  }
  /// Each path as a sandbox `subpath`, in its own and its resolved spelling (a subpath also
  /// matches a file at that path).
  private static func subpaths(_ paths: [String]) -> String {
    var seen = Set<String>()
    return paths.flatMap { [$0, physicalPath($0)] }
      .filter { seen.insert($0).inserted }
      .map { "(subpath " + jsonString($0) + ")" }.joined(separator: " ")
  }
  /// No cfprefsd: `defaults` writes through it, outside any file rule.
  private static let noPreferences =
    "(deny mach-lookup (global-name \"com.apple.cfprefsd.daemon\") (global-name \"com.apple.cfprefsd.agent\"))\n"
  /// For a CLI that keeps its own settings and its own home (a linked chat's reply): everything
  /// as usual except Serein's own data and its settings service, so a page in the reply's context
  /// cannot have it read the library or change a consent.
  public static func sereinDataProfile(home: URL, library: URL?) -> String {
    "(version 1)\n(allow default)\n(deny file-read* file-write* file-link "
      + subpaths(sereinPrivateRoots(home: home, library: library).map(\.standardizedFileURL.path)) + ")\n" + noPreferences
  }

  /// Files that only an app with Full Disk Access can open. Reading one of them means every
  /// agent Serein starts can read the user's mail and messages too. None of them is in another
  /// app's container, so probing never makes macOS show a prompt.
  public static func fullDiskAccessProbes(home: URL) -> [URL] {
    [
      home.appendingPathComponent("Library/Messages/chat.db"),
      home.appendingPathComponent("Library/Mail"),
      home.appendingPathComponent("Library/Safari/Bookmarks.plist"),
    ]
  }
  /// True when any probe can be opened. `canOpen` does the real open; it is injected for tests.
  public static func holdsFullDiskAccess(home: URL, canOpen: (URL) -> Bool) -> Bool {
    fullDiskAccessProbes(home: home).contains(where: canOpen)
  }

  /// A Claude Code `Read` deny rule for everything under `path`. `//` marks an absolute path.
  /// Rule lists are split on spaces and commas, so each space becomes `*` (any characters
  /// except `/`), which still matches the real folder name.
  public static func readRule(_ path: String) -> String {
    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    let absolute = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    let safe = absolute.replacingOccurrences(of: " ", with: "*")
      .replacingOccurrences(of: ",", with: "*")
    return "Read(/\(safe)/**)"
  }
  /// The same rule for the file or folder at `path` itself (a settings or cookie file).
  public static func exactReadRule(_ path: String) -> String { String(readRule(path).dropLast(4)) + ")" }

  /// Adds deny rules for `paths` to Claude Code arguments. Every existing `--disallowedTools`
  /// flag is folded into one, so no rule is lost to a later flag.
  public static func denyReads(_ args: [String], paths: [String]) -> [String] {
    var out: [String] = []
    var rules: [String] = []
    var i = 0
    while i < args.count {
      let arg = args[i]
      if arg.hasPrefix("--disallowedTools=") {
        rules += split(String(arg.dropFirst("--disallowedTools=".count)))
      } else if arg == "--disallowedTools" || arg == "--disallowed-tools" {
        if i + 1 < args.count { rules += split(args[i + 1]) }
        i += 1
      } else if arg.hasPrefix("--disallowed-tools=") {
        rules += split(String(arg.dropFirst("--disallowed-tools=".count)))
      } else {
        out.append(arg)
      }
      i += 1
    }
    for rule in paths.flatMap({ [readRule($0), exactReadRule($0)] }) where !rules.contains(rule) { rules.append(rule) }
    guard !rules.isEmpty else { return out }
    return out + ["--disallowedTools=" + rules.joined(separator: ",")]
  }

  /// The deny rules currently in `args`.
  public static func deniedRules(_ args: [String]) -> [String] {
    args.filter { $0.hasPrefix("--disallowedTools=") }
      .flatMap { split(String($0.dropFirst("--disallowedTools=".count))) }
  }

  /// Matching files are unavailable even inside an explicitly granted project.
  public static let secretGlobs = [
    "**/.env*", "**/.env", "**/.env.*", "**/*.env", "**/*.pem", "**/*.key", "**/*.p12", "**/*.pfx",
    "**/id_rsa", "**/id_ed25519", "**/credentials", "**/credentials.json", "**/auth.json",
    "**/secrets.json", "**/secrets.yaml", "**/secrets.yml", "**/*passwords*.csv",
    "**/.npmrc", "**/.netrc", "**/.git-credentials", "**/.ssh/**", "**/.aws/**",
    "**/.codex/**", "**/.claude/**", "**/.cursor/**",
  ]

  /// The secret files a wrapped CLI's shell cannot open (`LaunchContract.fileGuard`): `.env`
  /// files anywhere (not `.envrc`, the `.env.example`/`.sample`/`.template` kind, or a `.env`
  /// folder such as a venv), and the rest of `secretGlobs` inside `folder`, except under
  /// node_modules and site-packages (packages ship test keys). Those packages stay closed inside
  /// the closed folders (`closedPaths`, PAYGUARD-REVIEW H2). The driver's own home and state stay
  /// as they were, so a task in the home folder keeps the CLI's own sign-in.
  public static func secretRule(home: URL, driver: HarnessDriver, folder: URL?, library: URL? = nil, fenced: Bool = true) -> String {
    let env = "(require-all (regex " + jsonString(#"/\.env[^/]*$"#) + ") (require-not (regex "
      + jsonString(#"/\.env(rc|\.example|\.sample|\.template)$"#) + ")) (vnode-type REGULAR-FILE))"
    var rule = "(deny file-read* file-write* file-link " + env + ")\n"
    if let folder {
      let roots = Set([folder.standardizedFileURL.path, physicalPath(folder.standardizedFileURL.path)]).sorted()
      let globs = secretGlobs.filter { !$0.hasPrefix("**/.env") }
      let denied = roots.flatMap { root in globs.map { "(regex " + jsonString(regex(fromGlob: $0, under: root)) + ")" } }
      let packages = roots.map { "(regex " + jsonString("^" + escaped($0) + "/(.*/)?(node_modules|site-packages)/") + ")" }
      rule += "(deny file-read* file-write* file-link " + denied.joined(separator: " ") + ")\n"
      rule += "(allow file-read* file-write* " + packages.joined(separator: " ") + ")\n"
      // The last matching rule wins: a closed folder inside this one keeps its packages closed.
      let closed = closedPaths(home: home, driver: driver, library: library).flatMap { [$0, physicalPath($0)] }
        .filter { path in roots.contains { root in path != root && within(path, root) } }
      let closedPackages = Set(closed).sorted().map { "(regex " + jsonString("^" + escaped($0) + "/(.*/)?(node_modules|site-packages)/") + ")" }
      if !closedPackages.isEmpty { rule += "(deny file-read* file-write* file-link " + closedPackages.joined(separator: " ") + ")\n" }
    }
    let own = ((harnessHomes[driver] ?? []) + (harnessState[driver] ?? [])).map { home.appendingPathComponent($0).path }
    let ownWrites = writableRoots(home: home, driver: driver, folder: nil).filter { path in own.contains { within(path, $0) } }
    if !own.isEmpty { rule += "(allow file-read* " + subpaths(own) + ")\n" }
    if !ownWrites.isEmpty { rule += "(allow file-write* " + subpaths(ownWrites) + ")\n" }
    // Outside own setup the state's own closures (Cursor's MCP approvals) come again after the reopen, so they win.
    if fenced, !ownWrites.isEmpty { rule += stateRules(home: home, driver: driver) }
    return rule
  }

  /// A `secretGlobs` pattern as a sandbox regex for paths under `root`: `**/` is any folders,
  /// a closing `/**` the folder and everything in it, `*` one name's characters.
  public static func regex(fromGlob glob: String, under root: String) -> String {
    var body = glob
    var tail = ""
    if body.hasSuffix("/**") {
      body.removeLast(3)
      tail = "(/.*)?"
    }
    let parts = body.components(separatedBy: "**/").map { $0.split(separator: "*", omittingEmptySubsequences: false).map { escaped(String($0)) }.joined(separator: "[^/]*") }
    return "^" + escaped(root) + "/" + parts.joined(separator: "(.*/)?") + tail + "$"
  }

  private static func escaped(_ literal: String) -> String {
    literal.reduce(into: "") { out, character in
      if #"\.^$|()[]{}*+?"#.contains(character) { out.append("\\") }
      out.append(character)
    }
  }

  /// Full access changes prompting, never the credential boundary. CLI runtime credentials
  /// stay available to the trusted CLI itself; model-generated commands cannot read them.
  /// `privateRoots` (Serein's own data, `sereinPrivateRoots`, outside Library mode) are denied
  /// as `privateDenies` says, so a project that holds them (the home folder) cannot open them.
  /// `openHome` (Allow all, `HarnessGrant.opensHome`) writes all of home past those denies.
  /// `widened` (PathGrants.roots) opens those folders like the work root, past the same denies.
  public static func codexProfile(
    folder: URL, writable: Bool, attachments: [URL] = [], executable: String? = nil, privateRoots: [URL] = [],
    openHome: Bool = false, widened: [URL] = []
  ) -> [String: Any] {
    let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
    var scoped: [String: String] = [".": writable ? "write" : "read", ".git": "read"]
    for pattern in secretGlobs { scoped[pattern] = "deny" }
    var files: [String: Any] = [":root": "deny", ":minimal": "read", root: scoped]
    if openHome {
      var home = scoped
      home["."] = "write"
      home.removeValue(forKey: ".git")
      let homePath = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
      if files[homePath] == nil { files[homePath] = home }
    }
    for folder in attachments {
      let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
      if path != root { files[path] = "read" }
    }
    for folder in widened {
      let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
      if path != root { files[path] = writable ? "write" : "read" }
    }
    // Codex 0.162 starts itself again inside this sandbox to read AGENTS.md; without its install
    // paths that fails with "execvp() of '/opt/homebrew/bin/codex' failed: Operation not permitted".
    for path in executable.map(installPaths) ?? [] where files[path] == nil { files[path] = "read" }
    // git reads the person's identity and aliases. mktemp, xcrun and compilers write the per-user
    // temp folder whatever TMPDIR says, so it stays writable; Serein's run files live in `runRoot`.
    let home = FileManager.default.homeDirectoryForCurrentUser
    for path in [".gitconfig", ".config/git"] { files[home.appendingPathComponent(path).path] = "read" }
    files[URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().standardizedFileURL.path] = "write"
    // Denies take precedence even if the project is accidentally chosen inside a private store.
    for path in protectedPaths(home: FileManager.default.homeDirectoryForCurrentUser) {
      files[path] = "deny"
    }
    for path in privateDenies(privateRoots, workRoot: folder) { files[path] = "deny" }
    return ["filesystem": files, "network": ["enabled": false]]
  }

  /// An inline TOML value, never shell text. JSON strings use compatible escaping for TOML keys.
  public static func toml(_ value: Any) -> String {
    if let dict = value as? [String: Any] {
      return "{ " + dict.keys.sorted().map { jsonString($0) + " = " + toml(dict[$0]!) }.joined(separator: ", ") + " }"
    }
    return jsonString(value)
  }
  /// What Codex needs to start itself again inside its profile: the folder of the file it runs,
  /// one up from a `bin` folder (Homebrew's Caskroom or Cellar version folder), and the folder of
  /// the link it was given (Homebrew's bin). The profile resolves links, so a link file alone is
  /// not enough (checked with `codex sandbox`). Never all of /opt/homebrew, whose `etc` and `var`
  /// hold other tools' settings and data; another tool's link in bin stays closed, as its target
  /// is not readable. A top-level folder, the home folder or one that holds it (a plain
  /// ~/bin/codex) would open the user's files to the model's shell commands: then the file alone.
  public static func installPaths(_ executable: String) -> [String] {
    let given = URL(fileURLWithPath: executable)
    let linkFolder = given.deletingLastPathComponent().resolvingSymlinksInPath()
    let real = given.resolvingSymlinksInPath()
    var version = real.deletingLastPathComponent()
    if version.lastPathComponent == "bin" { version.deleteLastPathComponent() }
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    func safe(_ folder: URL) -> Bool {
      folder.pathComponents.count >= 4 && folder.path != home && !home.hasPrefix(folder.path + "/")
    }
    let target = safe(version) ? version.path : real.path
    let isLink = linkFolder.appendingPathComponent(given.lastPathComponent).path != real.path
    let linkOutside = !(linkFolder.path + "/").hasPrefix(target + "/")
    return isLink && linkOutside && safe(linkFolder) ? [linkFolder.path, target] : [target]
  }
  public static func codexArguments(
    folder: URL, writable: Bool, attachments: [URL] = [], executable: String? = nil, privateRoots: [URL] = []
  ) -> [String] {
    ["--strict-config", "-c", "default_permissions=\"serein_task\"", "-c",
      "permissions.serein_task="
        + toml(codexProfile(
          folder: folder, writable: writable, attachments: attachments, executable: executable,
          privateRoots: privateRoots)),
      "-c", "shell_environment_policy.inherit=\"none\"", "-c", "shell_environment_policy.set={}",
      "-c", "shell_environment_policy.ignore_default_excludes=false"]
  }

  /// A run's own short, atomically created 0700 folder in /private/tmp, in its physical spelling.
  /// The run removes it when it ends.
  public static func makeRuntimeDirectory() throws -> URL {
    var template = Array("/private/tmp/serein-cli-XXXXXX".utf8CString)
    let path = template.withUnsafeMutableBufferPointer { buffer -> String? in
      guard let result = mkdtemp(buffer.baseAddress!) else { return nil }
      return String(cString: result)
    }
    guard let path else { throw SereinError.invalid("Could not create the agent's private temporary directory.") }
    // Claude withholds symlink-spelled grants beneath a read-denied region. Foundation's
    // standardizedFileURL collapses /private/tmp back to /tmp, so preserve the physical path.
    return URL(fileURLWithPath: path)
  }

  /// Puts the shell helper and its sandbox profile into `directory`, an empty 0700 folder the
  /// caller made, spelled physically.
  public static func fillClaudeRuntimeDirectory(_ directory: URL) throws {
    let path = directory.path
    do {
      let fm = FileManager.default
      let shell = directory.appendingPathComponent("shell")
      try fm.createDirectory(at: shell, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let helper = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .deletingLastPathComponent().appendingPathComponent("serein-process-host")
      guard fm.isExecutableFile(atPath: helper.path) else {
        throw SereinError.invalid("Process host missing. Rebuild Serein with its helper.")
      }
      try fm.copyItem(at: helper, to: shell.appendingPathComponent("zsh"))
      try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: shell.appendingPathComponent("zsh").path)
      let readable = [path] + claudeSystemReadPaths
      let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        .map { URL(fileURLWithPath: $0) } ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
      let snapshots = claudePhysicalPath(config) + "/shell-snapshots"
      // Built in typed steps: as one chained expression the type checker gives up.
      let readSubpaths: String = readable.map { "(subpath \(jsonString($0)))" }.joined(separator: " ")
      let writable: [String] = [path, snapshots, "/dev/fd"]
      let writeSubpaths: String = writable.map { "(subpath \(jsonString($0)))" }.joined(separator: " ")
      let shellSubpath: String = jsonString(path + "/shell")
      let profile: String = "(version 1)\n(allow default)\n(deny file-read* (subpath \"/\"))\n(allow file-read* (literal \"/\") "
        + readSubpaths + ")\n"
        + "(allow file-read-metadata (vnode-type DIRECTORY))\n"
        + "(deny file-write* (subpath \"/\"))\n(allow file-write* "
        + writeSubpaths
        + " (literal \"/dev/null\"))\n(deny file-write* (subpath " + shellSubpath + "))\n(deny network*)\n" + noPreferences
      try Data(profile.utf8).write(to: shell.appendingPathComponent("startup.sb"))
      try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: shell.appendingPathComponent("startup.sb").path)
    }
  }

  /// Keep libc's physical spelling: Foundation normalizes macOS /private aliases back to
  /// symlinks, which Claude correctly refuses to carve out of a broad read-deny boundary.
  public static func claudePhysicalPath(_ url: URL) -> String { physicalPath(url.path) }

  private static let claudeSystemReadPaths = ["/System/Library", "/System/Applications", "/System/iOSSupport",
    "/usr", "/bin", "/sbin", "/opt/homebrew", "/Applications", "/Library/Developer", "/private/etc", "/dev", "/private/var/select"]

  public static func claudeCommandEnvironment(runtimeDirectory: URL) -> [String: String] {
    let runtime = claudePhysicalPath(runtimeDirectory)
    return ["CLAUDE_CODE_TMPDIR": runtime, "CLAUDE_CODE_SHELL": runtime + "/shell/zsh", "ZDOTDIR": runtime + "/shell"]
  }

  /// Scoped tools, plus secret exclusions, in every mode (including Full access and pictures).
  /// `privateRoots` (Serein's own data outside Library mode) are closed like the protected folders:
  /// Read and Edit denies in both spellings, and the shell's denyRead and denyWrite.
  public static func claudeArguments(
    _ args: [String], folders: [URL], commands: Bool, runtimeDirectory: URL? = nil, privateRoots: [URL] = []
  ) -> [String] {
    let roots = folders.map(claudePhysicalPath)
    // Native file permissions match the tool's spelling; the shell sandbox resolves paths.
    // Allow both spellings of the same scoped roots, with identical credential exclusions.
    let fileRoots = Array(Set(roots + folders.map { $0.standardizedFileURL.path })).sorted()
    var out = args
    var settings: [String: Any] = [:]
    let settingsIndex = out.firstIndex(of: "--settings").flatMap { $0 + 1 < out.count ? $0 + 1 : nil }
    if let i = settingsIndex {
      settings = (try? JSONSerialization.jsonObject(with: Data(out[i].utf8))) as? [String: Any] ?? [:]
    }
    if let i = out.firstIndex(of: "--allowedTools"), i + 1 < out.count {
      let tools = split(out[i + 1])
      let fileTools = ["Read", "Glob", "Grep", "Edit", "Write"]
      func fileTool(_ tool: String) -> Bool { fileTools.contains { tool == $0 || tool.hasPrefix($0 + "(") } }
      // Settings arrays preserve spaces/commas in exact paths; CLI tool lists split them.
      out[i + 1] = tools.filter { !fileTool($0) }.joined(separator: ",")
      let requested = fileTools.filter { name in tools.contains { $0 == name || $0.hasPrefix(name + "(") } }
      // Claude uses Read(path) for Read/Grep/Glob, and Edit(path) for Edit/Write.
      let scoped = ["Read", "Edit"].filter { name in
        name == "Read" ? requested.contains { ["Read", "Grep", "Glob"].contains($0) }
          : requested.contains { ["Edit", "Write"].contains($0) }
      }
      var allow: [String] = []
      for tool in scoped {
        for root in fileRoots { allow.append("\(tool)(/\(root)/**)") }
      }
      if commands { allow.append("Bash") }
      settings["permissions"] = ["allow": allow]
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    var seen = Set<String>()
    // Built in typed steps: as one chained expression the type checker gives up.
    var candidates: [String] = protectedPaths(home: home)
    for root in privateRoots {
      candidates.append(claudePhysicalPath(root))
      candidates.append(root.standardizedFileURL.path)
    }
    let closed: [String] = candidates.filter { seen.insert($0).inserted }
    var denies: [String] = closed
    for root in roots {
      for glob in secretGlobs { denies.append("\(root)/\(glob)") }
    }
    var secretRules: [String] = []
    for root in fileRoots {
      for glob in secretGlobs {
        for tool in ["Read", "Edit"] { secretRules.append("\(tool)(/\(root)/\(glob))") }
      }
    }
    var permissions = settings["permissions"] as? [String: Any] ?? [:]
    // A folder's rule and the exact path's, which a file there (cookies, settings) needs.
    var denyRules: [String] = []
    for path in closed {
      for tool in ["Read", "Edit"] {
        denyRules.append("\(tool)(/\(path)/**)")
        denyRules.append("\(tool)(/\(path))")
      }
    }
    permissions["deny"] = denyRules + secretRules
    settings["permissions"] = permissions
    // Native file tools obey the Read rules too. Shells need a separate, mandatory OS boundary.
    if commands {
      let runtime = claudePhysicalPath(runtimeDirectory ?? URL(fileURLWithPath: "/private/tmp/serein-cli-" + UUID().uuidString))
      // Scoped file-tool allows and --restricted exclude CLI internals. Do not add a Read
      // deny here: Claude also applies those denies to the shell, blocking its own stdout.
      settings["env"] = claudeCommandEnvironment(runtimeDirectory: URL(fileURLWithPath: runtime))
      settings["sandbox"] = [
        "enabled": true, "failIfUnavailable": true, "allowUnsandboxedCommands": false,
        "autoAllowBashIfSandboxed": true,
        "excludedCommands": [String](),
        "filesystem": ["disabled": false, "denyRead": ["/"] + denies,
          "allowRead": roots + [runtime] + claudeSystemReadPaths,
          "allowWrite": roots + [runtime, "/dev/fd", "/dev/null"], "denyWrite": denies + [runtime + "/shell"]],
        "network": ["allowedDomains": [String](), "allowAllUnixSockets": false],
      ] as [String: Any]
    }
    if let i = settingsIndex { out[i] = jsonString(settings) }
    else { out += ["--settings", jsonString(settings)] }
    return denyReads(out, paths: closed)
  }

  /// Keep provider authentication in the trusted CLI, while dropping unrelated inherited
  /// credentials. Codex shells inherit no environment; Claude additionally scrubs children.
  /// `ownKey`: the variable the person's own Keychain key for this harness is given as; only that
  /// name, only to this harness's child.
  public static func environment(_ original: [String: String], driver: HarnessDriver?, ownKey: String? = nil) -> [String: String] {
    let providerKeys: Set<String>
    switch driver {
    case .claude: providerKeys = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"]
    case .codex: providerKeys = ["OPENAI_API_KEY", "CODEX_API_KEY"]
    case .cursor: providerKeys = ["CURSOR_API_KEY"]
    case .gemini: providerKeys = ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
    case .grok: providerKeys = ["XAI_API_KEY"]
    case .opencode: providerKeys = ["OPENCODE_API_KEY"]
    default: providerKeys = []
    }
    var env = original.filter { key, value in
      let name = key.lowercased()
      let secret = name.contains("token") || name.contains("secret") || name.contains("password")
        || name.contains("credential") || name.contains("api_key") || name.contains("private_key")
        || name == "aws_access_key_id" || AgentPrivacy.redact(value) != value
      return !secret || providerKeys.contains(key) || key == ownKey
    }
    if driver == .claude {
      for key in ["ENV", "BASH_ENV", "ZDOTDIR", "CLAUDE_CODE_SHELL", "CLAUDE_CODE_SHELL_PREFIX", "CLAUDE_BG_AUTH_SNAPSHOT_PATH"] {
        env.removeValue(forKey: key)
      }
      env["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] = "1"
      if let config = env["CLAUDE_CONFIG_DIR"] {
        env["CLAUDE_CONFIG_DIR"] = claudePhysicalPath(URL(fileURLWithPath: config))
      }
    }
    return env
  }

  /// Check host-handled reads against a canonical root; a symlink cannot widen the grant. A path
  /// that leads into Serein's own data (`privateRoots`) is refused even inside the folder.
  public static func allowsRead(
    _ paths: [String], folder: String?,
    privateRoots: [URL] = sereinPrivateRoots(home: FileManager.default.homeDirectoryForCurrentUser, library: AgentAccess.defaultRoot)
  ) -> Bool {
    guard let folder, !paths.isEmpty else { return false }
    let root = HarnessApprovals.resolved(folder, folder: nil)
    return paths.allSatisfy { raw in
      let path = HarnessApprovals.resolved(raw, folder: root)
      guard path == root || path.hasPrefix(root + "/"), !leadsInto(path, roots: privateRoots) else { return false }
      let parts = path.split(separator: "/").map { $0.lowercased() }
      return !parts.contains { part in
        part.hasPrefix(".env") || part.hasSuffix(".env")
          || [".ssh", ".aws", ".codex", ".claude", ".cursor", ".gemini", ".grok", ".hermes", "credentials", "credentials.json", "auth.json", "secrets.json", "secrets.yaml", "secrets.yml", ".npmrc", ".netrc", ".git-credentials", "id_rsa", "id_ed25519"].contains(part)
          || [".pem", ".key", ".p12", ".pfx"].contains { part.hasSuffix($0) }
          || (part.contains("passwords") && part.hasSuffix(".csv"))
      }
    }
  }

  /// Allow all's reach (`HarnessGrant.opensHome`): every path inside home, past the protected
  /// folders, Serein's own data and the secret files `allowsRead` refuses.
  public static func allowsHome(_ paths: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
    let protected = protectedPaths(home: home).map { URL(fileURLWithPath: $0) }
    return allowsRead(paths, folder: home.path)
      && !paths.contains { leadsInto(HarnessApprovals.resolved($0, folder: home.path), roots: protected) }
  }

  private static func split(_ list: String) -> [String] {
    // Commas inside a rule's parentheses belong to the rule.
    var parts: [String] = []
    var current = ""
    var depth = 0
    for ch in list {
      if ch == "(" { depth += 1 }
      if ch == ")" { depth = max(0, depth - 1) }
      if ch == "," && depth == 0 {
        if !current.isEmpty { parts.append(current) }
        current = ""
      } else {
        current.append(ch)
      }
    }
    if !current.isEmpty { parts.append(current) }
    return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }
}
