#if DEBUG
import Foundation
import SereinCore
import SereinEngines

/// `Serein --verify-no-stall`: one scenario per blocker group in reviews/REFUSALS.md, each run
/// against the code that decides it (fake CLIs where a CLI answers), plus the safety invariants.
/// Each row also counts how many times the scenario reaches the person. Per reviews/PRINCIPLE.md
/// the target is one ask for a person-only step (the row's `rule`) and none for anything else.
/// A row not fixed yet prints BASELINE while it still ends, and asks, the way it did at 8921e891;
/// a fixed row (`strict`) must reach its target. Either way a change fails, so the table below
/// stays the record of where tasks stop. Returns whether every row held.
@MainActor func checkNoStall() async throws -> Bool {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("no-stall-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  var failed = false
  for row in NoStall.rows(root) {
    let (seen, asks) = await row.observe()
    let label = "\(row.id) \(row.scenario): now \(row.now.rawValue) asks \(row.asksNow),"
      + " target \(row.target.rawValue) asks \(row.asksTarget) (person step: \(row.rule?.rawValue ?? "none")),"
      + " seen \(seen.rawValue) asks \(asks)"
    let atTarget = seen == row.target && asks == row.asksTarget
    if row.strict {
      print((atTarget ? "PASS: " : "FAIL: ") + label)
      if !atTarget { failed = true }
    } else if seen == row.now && asks == row.asksNow {
      print("BASELINE: " + label)
    } else {
      // Reaching the target here means a fix landed: that fix marks its row strict.
      print("FAIL: " + label + (atTarget ? " (reached its target: mark the row strict)" : " (changed from the baseline)"))
      failed = true
    }
  }
  return !failed
}

enum NoStall {
  /// How a scenario ends, as the person would see the task.
  enum Seen: String {
    case refused, needsUser = "needs_user", handedBack = "handed back", parked, failed, cutShort = "cut short"
    case sends, recovers, continues = "continues with a card"
    /// An invariant: Serein does not do the step itself.
    case closed = "closed to Serein"
    case open = "OPEN TO SEREIN"

    /// Whether the task waits on the person: one ask.
    var asks: Int {
      switch self {
      case .refused, .needsUser, .handedBack, .parked, .failed, .cutShort, .continues: 1
      case .sends, .recovers, .closed, .open: 0
      }
    }
  }

  /// reviews/PRINCIPLE.md: the only steps that reach the person, each asked once.
  enum PersonRule: String {
    case captcha = "a CAPTCHA, in the takeover card"
    case passwordManager = "confirming a password manager login"
    case card = "submitting a payment or secret card"
    case changedHostKey = "a changed host key"
  }

  struct Row {
    let id: String
    let scenario: String
    let now: Seen
    let target: Seen
    /// The PRINCIPLE.md step still left to the person at the target; nil when Serein does it itself.
    let rule: PersonRule?
    let strict: Bool
    /// Times the scenario reaches the person at the baseline, when that is not one per stop.
    let asked: Int?
    let observe: () async -> (Seen, Int)

    var asksNow: Int { asked ?? now.asks }
    var asksTarget: Int { rule == nil ? 0 : 1 }

    init(
      id: String, scenario: String, now: Seen, target: Seen, rule: PersonRule? = nil, strict: Bool,
      observe: @escaping () async -> Seen
    ) {
      self.init(id: id, scenario: scenario, now: now, target: target, rule: rule, strict: strict, asked: nil) {
        let seen = await observe()
        return (seen, seen.asks)
      }
    }

    init(
      id: String, scenario: String, now: Seen, target: Seen, rule: PersonRule?, strict: Bool, asked: Int?,
      counting observe: @escaping () async -> (Seen, Int)
    ) {
      self.id = id
      self.scenario = scenario
      self.now = now
      self.target = target
      self.rule = rule
      self.strict = strict
      self.asked = asked
      self.observe = observe
    }
  }

  static func rows(_ root: URL) -> [Row] {
    let field = { (kind: String?) in
      SecureCard.Field(
        kind: kind, autocomplete: "", frameOrigin: "https://shop.example", topOrigin: "https://shop.example",
        formOrigin: "https://shop.example", trusted: true)
    }
    let projectFolder = root.appendingPathComponent("project").path
    let fullAccess = HarnessGrant(mode: "project", edits: true, permission: .fullAccess)
    let noFacts = ApprovalDoor.Facts(
      secureField: false, botCheck: false, pays: .no, covered: false, path: nil, hostKeyChanged: nil, runsAnything: false, ref: "")
    /// At Allow all, attended or not, the door runs `step` with nothing covering it.
    func doorRuns(_ step: ApprovalDoor.Step) -> Bool {
      [true, false].contains { ApprovalDoor.answer(.init(step, .proactiveTask(present: $0)), facts: noFacts).runs }
    }

    var rows: [Row] = [
      Row(id: "A4", scenario: "OpenCode in Project mode (HarnessPolicy.verdict)", now: .refused, target: .sends, strict: false) {
        HarnessPolicy.verdict(
          driver: .opencode, capabilities: .base(.opencode), mode: "project", edits: true, permission: .autoAcceptEdits
        ).allowed ? .sends : .refused
      },
      // The registry refuses every send while the probe says signed out (HarnessRegistry.verdict,
      // AgentModel.canThink: `signedIn == false`), so that is what the fake CLI's probe decides.
      Row(id: "B6", scenario: "Cursor signed in, `about` has a null email, `status` says Logged in", now: .refused, target: .sends, strict: true) {
        cursorProbe(root, status: "Logged in (unable to fetch user details)")
      },
      Row(id: "B6b", scenario: "Cursor probe that cannot tell (null email, unreadable status)", now: .refused, target: .sends, strict: true) {
        cursorProbe(root, status: "something new")
      },
      Row(id: "B7", scenario: "Cursor really signed out (`status` says Not logged in): fail over", now: .refused, target: .recovers, strict: false) {
        cursorProbe(root, status: "Not logged in")
      },
      Row(id: "D2", scenario: "CLI's own web fetch at Full access (HarnessApprovals.decide)", now: .refused, target: .sends, strict: false) {
        HarnessApprovals.decide(
          HarnessPermissionRequest(id: "f", kind: .fetch, title: "Fetch https://example.com"), grant: fullAccess,
          folder: projectFolder
        ).allow ? .sends : .refused
      },
      Row(id: "F2", scenario: "CAPTCHA on the page (SecureCard.admit)", now: .needsUser, target: .continues, rule: .captcha, strict: false) {
        guard case .refused(let line) = SecureCard.admit(field("captcha")) else { return .open }
        return line.contains("needs_user") ? .needsUser : .refused
      },
      Row(id: "F6", scenario: "Secure card outlasts its tool call (PersonStep.fields)", now: .parked, target: .continues, rule: .card, strict: false) {
        PersonStep.fields(.asked)["result"] == "asked" ? .continues : .parked
      },
      Row(id: "F7", scenario: "A tool reaches the person's step (HandBack.message)", now: .needsUser, target: .continues, rule: .card, strict: false) {
        HandBack.message.contains("outcome needs_user") ? .needsUser : .continues
      },
      Row(id: "H3", scenario: "ask_user in a run nobody watches (RelayAsk.unattended)", now: .handedBack, target: .recovers, strict: false) {
        (RelayAsk.unattended(true)?["note"] as? String)?.contains("end your reply with") == true ? .handedBack : .recovers
      },
      Row(id: "I1", scenario: "Edits in a project with no git (GitTurns.probe)", now: .refused, target: .recovers, strict: false) {
        if case .noGit = GitTurns.probe(folder: root, git: nil) { return .refused }
        return .recovers
      },
    ]

    // Group C: every way a turn ends other than done or the person's Stop (Turn.swift StopReason).
    let ends: [(String, StopReason, Seen)] = [
      ("refusal", .refusal, .refused), ("maxTokens", .maxTokens, .cutShort), ("loop", .loop(tool: "read"), .cutShort),
      ("stuck", .stuck(seconds: 90), .cutShort), ("stepLimit", .stepLimit(40), .cutShort),
      ("modeMismatch", .modeMismatch(name: "sandbox", expected: "workspace-write", reported: "danger-full-access"), .refused),
      ("signIn", .signIn("Not logged in"), .refused),
      ("usageLimit", .usageLimit("limit reached"), .failed), ("failed", .failed("boom"), .failed),
      ("keyFailure", .keyFailure("invalid api key"), .failed), ("modelRejected", .modelRejected("unknown model"), .failed),
      ("offline", .offline("no network"), .failed), ("resumeFailed", .resumeFailed("no session"), .failed),
    ]
    for (name, reason, now) in ends {
      rows.append(Row(id: "C-\(name)", scenario: "turn ends with StopReason.\(name)", now: now, target: .recovers, strict: false) {
        switch TurnEnd(reason).outcome {
        case .completed: return .recovers
        case .cutShort: return .cutShort
        case .failed: return .failed
        case .stopped: return .sends
        }
      })
    }

    // Invariants: these stay closed to Serein after every fix; the person's card is the way past.
    rows += [
      Row(id: "INV-captcha", scenario: "Serein never solves or submits a CAPTCHA itself", now: .closed, target: .closed, strict: true) {
        if case .card = SecureCard.admit(field("captcha")) { return .open }
        return WebTaskPrompt.text(isolated: false, actions: true).contains("Never solve CAPTCHAs") ? .closed : .open
      },
      Row(id: "INV-secret", scenario: "Serein never types into a secret field without the person's card", now: .closed, target: .closed, strict: true) {
        let secure = ApprovalGate.GateAction(kind: "type", role: "AXSecureTextField", text: "x", site: "shop.example")
        let labelled = ApprovalGate.GateAction(kind: "type", label: "Password", text: "x", site: "shop.example")
        return [secure, labelled].contains { doorRuns(.action($0)) } ? .open : .closed
      },
      Row(id: "INV-secret-card", scenario: "A password field is filled only through the person's secure card", now: .continues, target: .continues, rule: .card, strict: true) {
        SecureCard.admit(field("password")) == .card(.password) ? .continues : .refused
      },
      // PRINCIPLE.md: never asked again for the same site and item. Nothing remembers the
      // person's card yet, so the second login on shop.example shows the card again.
      Row(
        id: "F-once", scenario: "The same password field on the same site, twice (SecureCard.admit)", now: .continues,
        target: .continues, rule: .card, strict: false, asked: 2
      ) {
        let cards = (0..<2).filter { _ in SecureCard.admit(field("password")) == .card(.password) }.count
        return (cards > 0 ? .continues : .refused, cards)
      },
      Row(id: "INV-pay", scenario: "Serein never pays without the person's card", now: .closed, target: .closed, strict: true) {
        return doorRuns(.effect(.pay)) ? .open : .closed
      },
      Row(id: "INV-fence", scenario: "Serein never widens the file fence without the person's card", now: .closed, target: .closed, strict: true) {
        let outside = HarnessApprovals.decide(
          HarnessPermissionRequest(id: "e", kind: .edit, title: "Edit", paths: ["/etc/hosts"]), grant: fullAccess,
          folder: projectFolder)
        return outside.allow || outside.approval == nil ? .open : .closed
      },
    ]
    return rows
  }

  /// HarnessRegistry's real Cursor probe against a fake `cursor-agent` whose `about` prints the
  /// JSON this Mac's cursor-agent printed while signed in (userEmail and subscriptionTier null).
  nonisolated static func cursorProbe(_ root: URL, status: String) -> Seen {
    let dir = root.appendingPathComponent("cursor-\(UUID().uuidString)")
    let fake = dir.appendingPathComponent("cursor-agent")
    let script = """
      #!/bin/sh
      for a in "$@"; do
        case "$a" in
          about) echo '{"cliVersion":"2026.05.28-a70ca7c","subscriptionTier":null,"userEmail":null}'; exit 0 ;;
          status) echo '\(status)'; exit 0 ;;
        esac
      done
      exit 0
      """
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try script.write(to: fake, atomically: true, encoding: .utf8)
      chmod(fake.path, 0o755)
    } catch { return .failed }
    let probed = HarnessProbe.probeSync(
      .cursor, executable: fake.path, environment: ["PATH": "/usr/bin:/bin", "HOME": dir.path], session: false)
    return probed.auth.signedIn == false ? .refused : .sends
  }
}
#endif
