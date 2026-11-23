#if DEBUG
import Foundation
import SereinCore
@testable import SereinEngines

/// Secret files under the wrapped file guard: `.env*` anywhere and the other secret patterns in
/// the folder are closed to a real shell, package folders and the CLI's own sign-in stay open,
/// and payment keystores in the home folder are closed like other sign-ins.
extension AssistantCoreChecks {
  static func engineSecrets(_ check: Check) throws {
    let root = "/w/p"
    let samples: [String: (yes: [String], no: [String])] = [
      "**/*.pem": (["/w/p/a.pem", "/w/p/x/y/a.pem"], ["/w/p/a.pem.bak", "/w/q/a.pem", "/w/pa.pem"]),
      "**/credentials": (["/w/p/credentials", "/w/p/.aws/credentials"], ["/w/p/credentials.txt"]),
      "**/.ssh/**": (["/w/p/.ssh", "/w/p/a/.ssh/id_ed25519"], ["/w/p/.sshx/id"]),
      "**/*passwords*.csv": (["/w/p/my-passwords-2026.csv"], ["/w/p/passwords.csv.gz"]),
    ]
    for glob in AgentFileGuard.secretGlobs {
      let pattern = AgentFileGuard.regex(fromGlob: glob, under: root)
      guard let regex = try? NSRegularExpression(pattern: pattern) else {
        try check(false, "\(glob) converts to a valid regex (\(pattern))")
        continue
      }
      func matches(_ path: String) -> Bool { regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil }
      if let sample = samples[glob] {
        try check(sample.yes.allSatisfy(matches) && !sample.no.contains(where: matches), "\(glob) matches what it names and nothing else")
      }
    }
    try check(["config.env", "x/server.key", "a/id_rsa"].allSatisfy { path in
      AgentFileGuard.secretGlobs.contains { glob in
        (try? NSRegularExpression(pattern: AgentFileGuard.regex(fromGlob: glob, under: root)))?
          .firstMatch(in: root + "/" + path, range: NSRange((root + "/" + path).startIndex..., in: root + "/" + path)) != nil
      }
    }, "config.env, server.key and id_rsa in a project match a secret pattern")
    try check([".config/stripe", ".config/solana", ".foundry/keystores", ".ethereum", ".bitcoin", ".electrum"]
      .allSatisfy(AgentFileGuard.protectedHomePaths.contains), "Payment and wallet keystores are closed like other sign-ins")

    let fm = FileManager.default
    let base = URL(fileURLWithPath: AgentFileGuard.physicalPath(fm.temporaryDirectory.path))
      .appendingPathComponent("pay-secrets-\(UUID().uuidString.prefix(8))")
    let home = base.appendingPathComponent("home")
    let project = home.appendingPathComponent("project")
    defer { try? fm.removeItem(at: base) }
    let files = [
      "project/.env": "ENV-SECRET", "project/sub/.env.local": "ENV-LOCAL", "project/config.env": "CONFIG-ENV",
      "project/server.pem": "PEM", "project/node_modules/pkg/test.key": "PKG-KEY", "project/README.md": "README",
      ".local/share/opencode/auth.json": "OWN-AUTH", ".pi/agent/auth.json": "PI-AUTH", ".config/stripe/config.toml": "STRIPE-LOGIN",
    ]
    for (path, text) in files {
      let url = home.appendingPathComponent(path)
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: url, atomically: true, encoding: .utf8)
    }
    let records = RunRecords(root: base.appendingPathComponent(".runs"))
    try fm.createDirectory(at: records.directory, withIntermediateDirectories: true)
    let host = SereinProcessHost(records: records)
    func contract(_ cli: HarnessDriver, folder: URL, _ paths: [String], open: Bool = false) -> LaunchContract {
      var request = TurnRequest(
        thread: ThreadKey("secrets"), cli: cli, executable: URL(fileURLWithPath: "/bin/sh"), access: .task(folder: folder),
        prompt: TurnPrompt(stable: "s", volatile: "", message: "m", recovery: nil), model: nil, effort: nil, resume: nil,
        browser: nil, taskID: "secrets")
      request.secretsOpen = open
      let script = paths.map { "cat \"\(home.appendingPathComponent($0).path)\" 2>/dev/null; echo" }.joined(separator: "; ")
      var contract = LaunchContract(
        request, arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"], expectedMode: .nothing(flagOnArgv: []),
        network: .open)
      contract.sandboxProfile = LaunchContract.fileGuard(request, home: home)
      return contract
    }
    func read(_ cli: HarnessDriver, folder: URL, _ paths: [String], open: Bool = false) throws -> String {
      let hosted = try host.spawn(contract(cli, folder: folder, paths, open: open))
      hosted.closeInput()
      return try blocking {
        var text = Data()
        for await chunk in hosted.output { text.append(chunk) }
        _ = await hosted.exited()
        return String(decoding: text, as: UTF8.self)
      }
    }
    for cli in [HarnessDriver.grok, .opencode, .pi, .gemini, .cursor] {
      let seen = try read(cli, folder: project, Array(files.keys.filter { $0.hasPrefix("project/") }))
      try check(seen.contains("README") && seen.contains("PKG-KEY"), "\(cli.rawValue): the project and its packages stay readable")
      try check(!["ENV-SECRET", "ENV-LOCAL", "CONFIG-ENV", "PEM"].contains(where: seen.contains),
        "\(cli.rawValue): the project's .env files and keys are not (\(seen.split(separator: "\n").joined(separator: ",")))")
    }
    let fromHome = try read(.opencode, folder: home, [".local/share/opencode/auth.json", ".pi/agent/auth.json", ".config/stripe/config.toml", "project/.env"])
    try check(fromHome.contains("OWN-AUTH"), "A task in the home folder keeps OpenCode's own sign-in readable")
    try check(!fromHome.contains("PI-AUTH") && !fromHome.contains("STRIPE-LOGIN") && !fromHome.contains("ENV-SECRET"),
      "Another CLI's sign-in, the Stripe CLI's login and .env stay closed from the home folder")

    // Allow all (owner, 2026-11-18): the shell reads secret files; a level change relaunches.
    let secrets = ["project/.env", "project/server.pem", ".pi/agent/auth.json"]
    let opened = try read(.grok, folder: project, secrets, open: true)
    try check(opened.contains("ENV-SECRET") && opened.contains("PEM") && !opened.contains("PI-AUTH"),
      "At Allow all a wrapped CLI's shell reads the project's .env and keys, never another CLI's sign-in (\(opened.split(separator: "\n").joined(separator: ",")))")
    try check(contract(.grok, folder: project, secrets, open: true).warmKey.changed(from: contract(.grok, folder: project, secrets).warmKey) == ["sandbox"],
      "Allow all changes the launch's sandbox, so a warm CLI is replaced when the level changes")
  }
}
#endif
