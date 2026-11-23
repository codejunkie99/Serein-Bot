#if DEBUG
import Foundation
import SereinCore
@testable import SereinEngines

/// The ACP drivers' file guard through the real process host and the kernel's sandbox: every
/// driver carries it at every level, writes stay in the folder outside own setup, other tools'
/// MCP lists stay closed, each CLI writes only its own state in its home, and OpenCode's config folder
/// is Serein's alone.
extension AssistantCoreChecks {
  static func engineACPGuard(_ check: Check) throws {
    let fm = FileManager.default
    // Under /private/tmp, outside the per-user temp folder a guarded turn may write.
    let scratch = URL(fileURLWithPath: "/private/tmp/serein-acp-guard-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let project = scratch.appendingPathComponent("project", isDirectory: true)
    let outside = scratch.appendingPathComponent("outside", isDirectory: true)
    try fm.createDirectory(at: project, withIntermediateDirectories: true)
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: scratch) }
    try "{}".write(to: project.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
    try "PROJECT-FILE".write(to: project.appendingPathComponent("mine.txt"), atomically: true, encoding: .utf8)
    // Its parent holds the host's empty folder, which must sit outside the writable temp folder too.
    let records = RunRecords(root: scratch.appendingPathComponent("runs", isDirectory: true))
    try fm.createDirectory(at: records.directory, withIntermediateDirectories: true)
    defer { records.removeAll() }
    let host = SereinProcessHost(records: records)

    func request(_ cli: HarnessDriver, _ access: Access, executable: String = "/usr/bin/true") -> TurnRequest {
      TurnRequest(
        thread: ThreadKey("acp-guard"), cli: cli, executable: URL(fileURLWithPath: executable), access: access,
        prompt: TurnPrompt(stable: "s", volatile: "", message: "m", recovery: nil), model: nil, effort: nil, resume: nil,
        browser: nil, taskID: "acp-guard")
    }
    /// Runs `script` in /bin/sh under the profile `driver` gives `access`.
    func run(_ driver: any Driver, _ access: Access, _ script: String) throws -> String? {
      guard let profile = try? driver.contract(for: request(driver.cli, access), network: .open).sandboxProfile else { return nil }
      return try run(driver.cli, access, profile: profile, script)
    }
    func run(_ cli: HarnessDriver, _ access: Access, profile: String, _ script: String) throws -> String {
      var contract = LaunchContract(
        request(cli, access, executable: "/bin/sh"), arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"],
        expectedMode: .nothing(flagOnArgv: []), network: .open)
      contract.sandboxProfile = profile
      let hosted = try host.spawn(contract)
      hosted.closeInput()
      return try blocking {
        var text = Data()
        for await chunk in hosted.output { text.append(chunk) }
        _ = await hosted.exited()
        return String(decoding: text, as: UTF8.self)
      }
    }

    let drivers: [any Driver] = [GrokDriver(), OpenCodeDriver(), CursorDriver(), GeminiDriver(), PiDriver(cli: .pi)]
    let folderLevels: [Access] = [.project(folder: project, level: .review), .project(folder: project, level: .edits),
      .project(folder: project, level: .full), .task(folder: project)]
    let levels: [Access] = [.answer, .web, .ownSetup(folder: project)] + folderLevels
    for driver in drivers {
      let name = driver.cli.rawValue
      let guarded = levels.allSatisfy { access in
        (try? driver.contract(for: request(driver.cli, access), network: .open)).map { $0.sandboxProfile != nil } ?? true
      }
      try check(guarded, "\(name): every level it runs at carries the file guard")

      let write = "echo in > in.txt && echo IN-OK; echo out > \"\(outside.path)/\(name).txt\" 2>/dev/null && echo OUT-OK"
      let fenced = try folderLevels.allSatisfy { access in
        guard let output = try run(driver, access, write) else { return true }
        return output.contains("IN-OK") && !output.contains("OUT-OK")
      }
      try check(fenced, "\(name): at every project and task level, Full included, a shell writes its folder and nothing outside")
      if let own = try run(driver, .ownSetup(folder: project), write) {
        try check(own.contains("OUT-OK"), "\(name): own setup keeps writing where the person's setup does")
      }
      let noFolder = "ls . >/dev/null && echo LISTED; echo {} > .mcp.json 2>/dev/null && echo PLANTED; "
        + "echo out > \"\(outside.path)/\(name)-answer.txt\" 2>/dev/null && echo OUT-OK"
      if let answer = try run(driver, .answer, noFolder) {
        try check(answer.contains("LISTED") && !answer.contains("PLANTED") && !answer.contains("OUT-OK"),
          "\(name): a turn with no folder reads its shared empty folder and writes nothing there or outside")
      }
    }

    let claudeJSON = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json").path
    let lists = "head -c1 \"\(claudeJSON)\" >/dev/null 2>&1 && echo CLAUDE-READ; cat .mcp.json >/dev/null 2>&1 && echo MCP-READ; cat mine.txt"
    let task = try run(GrokDriver(), .task(folder: project), lists) ?? ""
    try check(!task.contains("CLAUDE-READ") && !task.contains("MCP-READ") && task.contains("PROJECT-FILE"),
      "Grok: outside own setup ~/.claude.json and the folder's .mcp.json stay closed, the rest of the folder reads")
    if fm.isReadableFile(atPath: claudeJSON) {
      try check((try run(GrokDriver(), .ownSetup(folder: project), lists) ?? "").contains("CLAUDE-READ"),
        "Grok: own setup still loads the person's MCP servers")
    }
    // A stand-in home per CLI. Each file is opened for append with nothing written; `shut` holds what
    // its next launch runs or loads, `state` what a turn writes.
    let fakeHome = scratch.appendingPathComponent("home", isDirectory: true)
    let homes: [(cli: HarnessDriver, home: String, shut: [String], state: [String], extra: String, saved: [String])] = [
      (.grok, ".grok",
       ["config.toml", "hooks/notify.json", "installed-plugins/registry.json", "skills/s/SKILL.md", "plugins/p/plugin.json",
        "agents/a.md", "lsp.json", "memory/MEMORY.md", "bin/grok", "models_cache.json"],
       ["sessions/s/chat_history.jsonl", "logs/unified.jsonl", "worktrees.db", "agent_id", "auth.json"],
       "echo x > .9.0.tmp && mv .9.0.tmp auth.json && echo SAVED; echo x > .9.1.tmp && mv .9.1.tmp config.toml 2>/dev/null && echo SWAPPED",
       ["SAVED"]),
      (.pi, ".pi/agent",
       ["settings.json", "extensions/e.ts", "skills/s/SKILL.md", "prompts/p.md", "themes/t.json", "AGENTS.md", "models.json",
        "mcp.json", "bin/rg"],
       ["sessions/s/1.jsonl", "auth.json"],
       "mkdir auth.json.lock 2>/dev/null && rmdir auth.json.lock && echo LOCKED", ["LOCKED"]),
      (.opencode, ".local",
       ["share/opencode/snapshot/p/config", "share/opencode/bin/rg", "state/opencode/kv.json",
        "cache/opencode/node_modules/p/index.js", "cache/opencode/package.json"],
       ["share/opencode/opencode.db", "share/opencode/opencode.db-wal", "share/opencode/log/1.log", "share/opencode/shell/1",
        "share/opencode/storage/s.json", "share/opencode/tool-output/t", "share/opencode/auth.json"],
       "", []),
      (.cursor, ".cursor",
       ["hooks.json", "mcp.json", "rules/r.mdc", "commands/c.md", "skills/s/SKILL.md", "agents/a.md", "plugins/p/plugin.json",
        "permissions.json", "sandbox.json", "acp-config.json", "projects/p/mcp-approvals.json", "projects/p/mcp-disabled.json"],
       ["chats/c/store.db", "acp-sessions/s.json", "projects/p/repo.json", "ai-tracking/ai-code-tracking.db", "cli-config.json"],
       "echo {} > cli-config.json.tmp && mv cli-config.json.tmp cli-config.json && echo SAVED", ["SAVED"]),
      // Never run here, so its whole home stays writable to a guarded turn.
      (.gemini, ".gemini", [], ["settings.json", "tmp/t/chats/c.json"], "", []),
      (.ohMyPi, ".omp", [], ["agent/settings.json"], "", []),
    ]
    for entry in homes {
      let root = fakeHome.appendingPathComponent(entry.home, isDirectory: true)
      for path in entry.shut + entry.state {
        let file = root.appendingPathComponent(path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: file, atomically: false, encoding: .utf8)
      }
      let probe = "cd \"\(root.path)\" || exit\n"
        + (entry.shut + entry.state).map { ": >> \($0) 2>/dev/null && echo \"OPEN \($0)\"" }.joined(separator: "\n")
        + "\n: > new-hook.json 2>/dev/null && echo NEW-FILE; mkdir new-skill-$$ 2>/dev/null && echo NEW-FOLDER\n" + entry.extra
      func shell(_ access: Access) throws -> String {
        try run(entry.cli, access, profile: LaunchContract.fileGuard(request(entry.cli, access), home: fakeHome), probe)
      }
      let name = entry.cli.rawValue
      let locked = try shell(.project(folder: project, level: .full))
      try check(entry.shut.allSatisfy { !locked.contains("OPEN \($0)") } && !locked.contains("SWAPPED")
        && (entry.shut.isEmpty || !locked.contains("NEW-")),
        "\(name): a guarded shell writes none of the code and config in its home that a later launch runs")
      try check(entry.state.allSatisfy { locked.contains("OPEN \($0)") } && entry.saved.allSatisfy(locked.contains),
        "\(name): its sessions, logs and sign-in stay writable to a guarded turn")
      let own = try shell(.ownSetup(folder: project))
      try check((entry.shut + entry.state).allSatisfy { own.contains("OPEN \($0)") } && own.contains("NEW-FOLDER"),
        "\(name): own setup still writes its whole home")
    }
    let closedToAll = AgentFileGuard.protectedPaths(home: fakeHome)
    try check([".claude", ".codex"].allSatisfy { closedToAll.contains(fakeHome.appendingPathComponent($0).path) },
      "Claude Code and Codex: their homes are in the protected folders their sandboxes deny writes to")

    let openCode = OpenCodeDriver()
    for level in [ProjectLevel.review, .edits, .full] {
      let contract = try openCode.contract(for: request(.opencode, .project(folder: project, level: level)), network: .open)
      let text = contract.environment["OPENCODE_CONFIG_CONTENT"] ?? ""
      let config = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
      let read = (config["permission"] as? [String: Any])?["read"] as? [String: String]
      try check(read == ["*": "allow", "*.env": "deny", "*.env.*": "deny", "*.env.example": "allow"]
        && text.contains("\"*.env.*\":\"deny\",\"*.env.example\":\"allow\""),
        "OpenCode \(level.rawValue): .env files stay unread, the example last so it reads")
    }
    let full = try openCode.contract(for: request(.opencode, .project(folder: project, level: .full)), network: .open)
    let configDir = URL(fileURLWithPath: full.environment["OPENCODE_CONFIG_DIR"] ?? "/")
    try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
    try "x".write(to: configDir.appendingPathComponent("planted.md"), atomically: true, encoding: .utf8)
    try openCode.prepare(full, request: request(.opencode, .project(folder: project, level: .full)))
    try check(!fm.fileExists(atPath: configDir.appendingPathComponent("planted.md").path),
      "OpenCode: its config folder is emptied before each launch")
    let plant = try run(openCode, .project(folder: project, level: .full),
      "ls \"\(configDir.path)\" >/dev/null && echo LISTED; mkdir -p \"\(configDir.path)/agents\" 2>/dev/null && echo PLANTED") ?? ""
    try check(plant.contains("LISTED") && !plant.contains("PLANTED"), "OpenCode: it reads its config folder and no shell can plant in it")
    let pi = try run(PiDriver(cli: .pi), .project(folder: project, level: .full), "mkdir -p \"\(configDir.path)/agents\" 2>/dev/null && echo PLANTED") ?? ""
    try check(!pi.contains("PLANTED"), "OpenCode's config folder is closed to another CLI's shell")
    let empty = ACPGrant.emptyFolder.path
    let planted = try run(GrokDriver(), .project(folder: project, level: .full), "echo {} > \"\(empty)/.mcp.json\" 2>/dev/null && echo PLANTED") ?? ""
    try? fm.removeItem(atPath: empty + "/.mcp.json")
    try check(!planted.contains("PLANTED"), "ACP's empty folder, a no-folder turn's cwd, is closed to a project turn's shell")

    let keychains = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains").path
    let cursor = try CursorDriver().contract(for: request(.cursor, .project(folder: project, level: .full)), network: .open)
    let keychainRules = (cursor.sandboxProfile ?? "").split(separator: "\n").filter { $0.contains(keychains) && $0.hasPrefix("(allow") }
    try check(!keychainRules.isEmpty && keychainRules.allSatisfy { !$0.contains("file-write") },
      "Cursor: the login keychain reopens to reads only")
    let keychainRead = try run(CursorDriver(), .project(folder: project, level: .full), """
      k="\(keychains)"
      { [ ! -e "$k/login.keychain-db" ] || head -c 1 "$k/login.keychain-db" > /dev/null; } && echo LOGIN
      ls "$k" > /dev/null 2>&1 && echo LISTED
      for f in "$k/metadata.keychain-db" "$k"/.fl*; do [ -e "$f" ] || continue; head -c 1 "$f" > /dev/null 2>&1 && echo OTHER; done
      """) ?? ""
    try check(keychainRead.contains("LOGIN") && !keychainRead.contains("LISTED") && !keychainRead.contains("OTHER"),
      "Cursor: only the login keychain file, where its sign-in lives, reopens; the rest of the Keychains folder stays closed")
  }
}
#endif
