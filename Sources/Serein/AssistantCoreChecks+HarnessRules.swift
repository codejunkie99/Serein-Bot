
#if DEBUG
import Foundation
import SereinCore

extension AssistantCoreChecks {
  static func harnessRules(_ check: Check) throws {
    try harnessClassify(check)
    try harnessReplay(check)
    try harnessIdle(check)
    try harnessStuck(check)
    try harnessLoopGuard(check)
  }

  private static func harnessClassify(_ check: Check) throws {
    typealias R = HarnessRetry
    func name(_ fault: R.Fault) -> String {
      switch fault {
      case .transient(let reason): return "transient \(reason.rawValue)"
      case .terminal(let reason): return "terminal \(reason.rawValue)"
      }
    }
    // Each text is read as stream error text and as a CLI's stderr unless the row says otherwise.
    let both: [(String, R.Fault)] = [
      ("HTTP 503: blocked by our safety systems", .terminal(.providerSafety)),
      ("429: safety monitoring paused this task", .terminal(.providerSafety)),
      ("xAI HTTP 429: Too Many Requests", .transient(.rateLimited)),
      ("rate limit exceeded, slow down", .transient(.rateLimited)),
      ("xAI HTTP 503: Service Unavailable", .transient(.serverError)),
      ("Internal Server Error", .transient(.serverError)),
      ("The API is temporarily overloaded", .transient(.overloaded)),
      ("upstream error (529 overloaded)", .transient(.overloaded)),
      ("unexpected status 429", .transient(.rateLimited)),
      ("unexpected status 500", .transient(.serverError)),
      ("unexpected status 502", .transient(.serverError)),
      ("unexpected status 503", .transient(.serverError)),
      ("unexpected status 504", .transient(.serverError)),
      ("stream error: workspace routing discovery failed: error sending request", .transient(.serverError)),
      ("workspace routing discovery timed out", .transient(.serverError)),
      ("Error: workspace routing discovery failed", .transient(.serverError)),
      ("fetch failed", .transient(.connectionReset)),
      ("read ECONNRESET", .transient(.connectionReset)),
      ("request timed out after 120000ms", .transient(.timeout)),
      ("Internal error: Internal service failure (session/new, ServiceUnavailableError)", .transient(.serverError)),
      ("ServiceUnavailableError: upstream unavailable", .transient(.serverError)),
      ("Internal error: fetchAvailableModels failed: [SSL: UNEXPECTED_EOF_WHILE_READING] EOF occurred in violation of protocol (_ssl.c:1082) (session/new)", .transient(.connectionReset)),
      ("ServiceUnavailableError: SSL: CERTIFICATE_VERIFY_FAILED", .terminal(.unknown)),
      ("Internal service failure: certificate verify failed", .terminal(.unknown)),
      ("UNEXPECTED_EOF_WHILE_READING: [SSL: CERTIFICATE_VERIFY_FAILED]", .terminal(.unknown)),
      ("HTTP 429: rate limit reached; retry after 1s", .transient(.rateLimited)),
      ("API Error: 429 Rate limit reached: weekly limit reached", .terminal(.quota)),
      ("You've hit your usage limit for this session. Try again at 7pm.", .terminal(.quota)),
      ("Usage limit reached for Claude Max", .terminal(.quota)),
      ("Rate limit reached: weekly limit reached", .terminal(.quota)),
      ("You are out of credits", .terminal(.quota)),
      ("You've hit your weekly limit \u{00b7} resets Oct 12 at 2:30pm (Asia/Calcutta)", .terminal(.quota)),
      ("You've hit your session limit \u{00b7} resets 3pm", .terminal(.quota)),
      ("You've hit your Opus limit", .terminal(.quota)),
      ("You've hit your org's monthly spend limit.", .terminal(.quota)),
      ("You've hit your team's shared budget. /model to switch models.", .terminal(.quota)),
      ("You're out of usage credits. Contact your admin to add more.", .terminal(.quota)),
      ("You're out of extra usage", .terminal(.quota)),
      ("error: 429 too many requests", .transient(.rateLimited)),
    ]
    for (text, fault) in both {
      try check(R.classify(.message(text)) == fault && R.classify(.exited(status: 1, stderr: text)) == fault,
        "classify \"\(text)\" as \(name(fault)), in a stream and on exit")
    }
    let messageOnly: [(String, R.Fault)] = [
      ("503: checking deployment safety", .transient(.serverError)),
      ("unexpected status 400", .terminal(.invalidRequest)),
      ("unexpected status 401", .terminal(.auth)),
      ("unexpected status 403", .terminal(.auth)),
      ("unexpected status 404", .terminal(.notFound)),
      ("unexpected status 422", .terminal(.invalidRequest)),
      ("workspace routing discovery unauthorized (401)", .terminal(.auth)),
      ("Internal service failure: 401 Unauthorized", .terminal(.auth)),
      ("ServiceUnavailableError: quota exceeded", .terminal(.quota)),
      ("UNEXPECTED_EOF_WHILE_READING: cancelled by user", .terminal(.interrupted)),
      ("Internal service failure: blocked by our safety systems", .terminal(.providerSafety)),
      ("SSL: CERTIFICATE_VERIFY_FAILED", .terminal(.unknown)),
      ("Internal error: OpenCode service failure", .terminal(.unknown)),
      ("unexpected status 401 Unauthorized: Missing bearer", .terminal(.auth)),
      ("invalid api key", .terminal(.auth)),
      ("quota exceeded for this plan", .terminal(.quota)),
      ("model not found: grok-99", .terminal(.unknownModel)),
      ("400 invalid request body", .terminal(.invalidRequest)),
      ("interrupted", .terminal(.interrupted)),
      ("turn cancelled by user", .terminal(.interrupted)),
      ("", .terminal(.unknown)),
      ("You've hit your rate limit, retry in 5s", .transient(.rateLimited)),
      ("You hit your API rate limit", .transient(.rateLimited)),
    ]
    for (text, fault) in messageOnly {
      try check(R.classify(.message(text)) == fault, "classify \"\(text)\" as \(name(fault))")
    }
    try check(R.classify(.exited(status: 3, stderr: "")) == .terminal(.terminalExit), "A bare nonzero exit is terminal")
    try check(R.classify(.signaled) == .terminal(.interrupted), "A signal kill is never retried")

    for (attempt, base) in R.backoffBase.enumerated() {
      try check(R.backoff(attempt: attempt, random: { 0.5 }) == base, "Backoff before retry \(attempt) is \(base) s at mid jitter")
    }
    try check(R.backoffBase == [1, 3, 8] && R.maxAttempts == 3, "Three attempts at 1, 3 and 8 s")
    for attempt in [0, 1, 2, 5] {
      let base = R.backoffBase[min(attempt, 2)]
      try check(R.backoff(attempt: attempt, random: { 0 }) == base * 0.75 && R.backoff(attempt: attempt, random: { 1 }) == base * 1.25,
        "Jitter for retry \(attempt) spans exactly +-25%")
    }
  }

  private static func harnessReplay(_ check: Check) throws {
    typealias R = HarnessRetry
    let transient = R.Failure.exited(status: 5, stderr: "API Error: 529 overloaded")
    let auth = R.Failure.exited(status: 1, stderr: "not logged in")
    let crash = R.Failure.exited(status: 1, stderr: "unknown option '--autocompact'")
    let cases: [(String, R.Failure, R.Stage, Int, ShellRisk?, R.Verdict)] = [
      ("A transient failure before acceptance is sent again after 1 s", transient, .sent, 0, nil, .replay(attempt: 1, after: 1)),
      ("The second retry waits 3 s", transient, .sent, 1, nil, .replay(attempt: 2, after: 3)),
      ("No retry past three attempts", transient, .sent, 2, nil, .hold(.attemptsUsed)),
      ("A turn the CLI accepted never re-sends", transient, .accepted, 0, nil, .hold(.accepted)),
      ("A clean exit is not retried", .exited(status: 0, stderr: ""), .sent, 0, nil, .hold(.cleanExit)),
      ("A terminal failure is not retried", auth, .sent, 0, nil, .hold(.terminal(.auth))),
      ("A launch that never took the prompt relaunches at once", crash, .launching, 0, nil, .replay(attempt: 1, after: 0)),
      ("A launch that keeps dying stops at the cap", crash, .launching, 2, nil, .hold(.attemptsUsed)),
      ("A launch refused by sign-in is not relaunched", auth, .launching, 0, nil, .hold(.terminal(.auth))),
      ("A stop during launch is not relaunched", .signaled, .launching, 0, nil, .hold(.terminal(.interrupted))),
      ("A turn whose shell looked like a push never replays", transient, .sent, 0, .push, .hold(.shellRisk(.push))),
      ("A launch with a payment step never replays", crash, .launching, 0, .pay, .hold(.shellRisk(.pay))),
      ("Shell risk is named over acceptance", transient, .accepted, 0, .publish, .hold(.shellRisk(.publish))),
    ]
    for (label, failure, stage, retries, risk, verdict) in cases {
      try check(R.decide(failure, stage: stage, retries: retries, shellRisk: risk, random: { 0.5 }) == verdict, label)
    }

    let risks: [(String, ShellRisk?)] = [
      ("git push origin main", .push),
      ("cd repo && git -C . push --force-with-lease", .push),
      ("git status", nil),
      ("git log --grep push", nil),
      ("git --no-pager push", .push),
      ("npm publish --access public", .publish),
      ("pnpm   publish", .publish),
      ("cargo publish", .publish),
      ("gh release create v1.2.0", .publish),
      ("docker push ghcr.io/me/app", .publish),
      ("npm install", nil),
      ("curl -X POST https://api.stripe.com/v1/charges", .pay),
      ("stripe payment_intents create --amount 500", .pay),
      ("swift build", nil),
    ]
    for (command, risk) in risks {
      try check(ShellRisk.of(command) == risk, "Shell risk of \"\(command)\" is \(risk.map(\.rawValue) ?? "none")")
    }
  }

  private static func harnessIdle(_ check: Check) throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let cases: [(String, Date?, TimeInterval?, TimeInterval)] = [
      ("A thread the person has open keeps its CLI ten minutes", now.addingTimeInterval(-5 * 60), nil, 600),
      ("Seen exactly 30 minutes ago still counts as watched", now.addingTimeInterval(-30 * 60), nil, 600),
      ("A thread unseen for 31 minutes closes after 30 s", now.addingTimeInterval(-31 * 60), nil, 30),
      ("A thread never seen closes after 30 s", nil, nil, 30),
      ("Low memory shortens a watched thread's idle", now, 150, 150),
      ("Low memory never lengthens it", now, 3600, 600),
      ("Low memory below 30 s cuts an unseen thread too", nil, 15, 15),
      ("Never below the ten-second floor", now, 2, 10),
    ]
    for (label, seen, low, expected) in cases {
      try check(HarnessIdle.closeAfter(lastSeen: seen, now: now, lowMemory: low) == expected, label)
    }
  }

  private static func harnessStuck(_ check: Check) throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: TimeInterval) -> Date { start.addingTimeInterval(s) }
    let idle = HarnessStuck.Evidence(cpuPerMinute: 0.2, openTCP: 0, logGrew: false)
    let open = HarnessStuck.Evidence(cpuPerMinute: 0.2, openTCP: 1, logGrew: false)
    let busy = HarnessStuck.Evidence(cpuPerMinute: 4, openTCP: 0, logGrew: false)
    let blind = HarnessStuck.Evidence(cpuPerMinute: nil, openTCP: nil, logGrew: false)
    let logging = HarnessStuck.Evidence(cpuPerMinute: 0.2, openTCP: 0, logGrew: true)
    // Each run is a sequence of ticks on one watch; a nil evidence row is "the CLI sent output".
    let runs: [(String, [(TimeInterval, HarnessStuck.Evidence?, HarnessStuck.Verdict?)])] = [
      ("Quiet under a minute is still talking", [(59, idle, .talking)]),
      ("A minute of silence with no signs reads as between requests", [(60, idle, .quiet(.betweenRequests))]),
      ("No signs for 180 s is stuck, and 5 min stops the turn", [
        (60, idle, .quiet(.betweenRequests)), (239, idle, .quiet(.betweenRequests)),
        (240, idle, .quiet(.stuck)), (359, idle, .quiet(.stuck)), (360, idle, .stop(.noSigns)),
      ]),
      ("An open connection extends the clock", [
        (60, idle, .quiet(.betweenRequests)), (240, open, .quiet(.waitingModel)),
        (300, idle, .quiet(.betweenRequests)), (480, idle, .quiet(.stuck)),
      ]),
      ("CPU over 3 s a minute extends the clock", [
        (60, idle, .quiet(.betweenRequests)), (240, busy, .quiet(.busy)), (300, idle, .quiet(.betweenRequests)),
      ]),
      ("A growing log counts as the CLI talking", [
        (60, idle, .quiet(.betweenRequests)), (300, logging, .talking), (359, idle, .talking), (360, idle, .quiet(.betweenRequests)),
      ]),
      ("An unreadable process is never taken as idle", [(60, blind, .quiet(.unknown)), (600, blind, .quiet(.unknown))]),
      ("Fifteen minutes of silence stops the turn whatever the evidence", [
        (60, open, .quiet(.waitingModel)), (899, busy, .quiet(.busy)), (900, open, .stop(.silence)),
      ]),
      ("Output resets every clock", [
        (60, idle, .quiet(.betweenRequests)), (240, idle, .quiet(.stuck)), (241, nil, nil),
        (300, idle, .talking), (301, idle, .quiet(.betweenRequests)), (1141, busy, .stop(.silence)),
      ]),
    ]
    for (label, ticks) in runs {
      var watch = HarnessStuck(promptSent: start)
      var ok = true
      for (second, evidence, expected) in ticks {
        guard let evidence else { watch.heard(at: at(second)); continue }
        ok = ok && watch.tick(now: at(second), evidence: evidence) == expected
      }
      try check(ok, label)
    }
  }

  private static func harnessLoopGuard(_ check: Check) throws {
    let runs: [(String, [(String, String)], [Bool])] = [
      ("The same call four times in a row trips", Array(repeating: ("read", #"{"path":"a"}"#), count: 5), [false, false, false, true, true]),
      ("Different arguments reset the count", [("read", "a"), ("read", "a"), ("read", "a"), ("read", "b"), ("read", "a")], [false, false, false, false, false]),
      ("A different tool with the same arguments resets it", [("read", "a"), ("read", "a"), ("read", "a"), ("grep", "a"), ("grep", "a")], [false, false, false, false, false]),
      ("A run of 60 varied steps never trips", (0..<60).map { ("edit", "step \($0)") }, Array(repeating: false, count: 60)),
    ]
    for (label, calls, expected) in runs {
      var guardrail = HarnessLoopGuard()
      try check(calls.map { guardrail.record(tool: $0.0, arguments: $0.1) } == expected, label)
    }
  }
}
#endif
