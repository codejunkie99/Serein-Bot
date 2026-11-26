import SereinCore
import SwiftUI

/// What a condensed range keeps, on the summary message that took its place
/// (`AgentMessage.condensed`), so it saves and loads with the thread's own transcript.
struct CondensedRange: Codable, Equatable {
  /// The slice of the transcript exactly as it was, in order: what Show reads and Edit puts back.
  var originals: [AgentMessage]
  /// The ids of that slice's messages still shown, just before the summary: every message of the
  /// user, every reply with a declined or failed step or an edit review, and replies from the
  /// other side of the own-setup line.
  var kept: [String]
  /// The native session the thread left so its next turn starts from the summary. Kept in saved
  /// chats; nothing resumes it since the divider lost Undo.
  var session: String?
  /// The session scope of the turn that folded (`RunSpec.scope`).
  var scope: String
  /// The messages the summary stands for, as the divider counts and shows them.
  var folded: [AgentMessage] { originals.filter { !kept.contains($0.id) } }
}

/// Long chats fold their older replies into one summary to save context, visibly and reversibly.
/// Only the agent's replies and tool steps fold; the user's words and every decision stay as they
/// were. The summary is extractive, with no model call: the first line of each folded reply and
/// its step labels.
@MainActor enum ChatCondense {
  /// A finished turn whose request carried this much (as the CLI reported it, else estimated from
  /// the transcript) folds the thread. It sits under where the CLIs compact a 200k window on their
  /// own, so the fold happens here, where it shows and can be undone. Harnesses that report no size
  /// are judged by the visible text only, which undercounts the session by far, so they fold
  /// rarely. A 1M-window session folds early; Undo before the next turn resumes it.
  static let threshold = 150_000
  /// The latest turns stay whole: from the second-to-last message of the user on.
  static let recentTurns = 2
  /// Fewer folded messages would save nothing worth a divider.
  static let minimum = 4
  /// Under RunContext's 6,000-character clip of each replayed message, newest lines first.
  static let budget = 5_500

  /// Four characters a token, for harnesses that report no context size.
  static func estimate(_ messages: [AgentMessage]) -> Int {
    messages.reduce(0) { $0 + $1.text.utf8.count } / 4
  }

  /// Stays verbatim: anything but an assistant reply, a reply with a declined or failed step (a
  /// refusal or the user's no), one with an edit review (its approval card and changes hang on
  /// it), and a reply from the other side of the own-setup line, which a summary on this side
  /// must not carry.
  static func keeps(_ message: AgentMessage, own: Bool) -> Bool {
    message.role != "assistant" || (message.own ?? false) != own
      || message.activities?.contains(where: { $0.failed }) == true
      || EditReview.shared.review(for: message.id) != nil
  }

  /// The transcript with the older replies folded into one summary after the messages kept, or nil
  /// when too little would fold. A range already condensed is never folded again. `own` is the
  /// turn's side of the own-setup line; `scope` its session scope.
  static func condense(_ messages: [AgentMessage], own: Bool, session: String?, scope: String) -> [AgentMessage]? {
    let start = messages.lastIndex(where: { $0.condensed != nil }).map { $0 + 1 } ?? 0
    let asked = messages.indices.filter { $0 >= start && messages[$0].role == "you" }
    guard asked.count > recentTurns else { return nil }
    let end = asked[asked.count - recentTurns]
    let slice = Array(messages[start..<end])
    let kept = slice.filter { keeps($0, own: own) }
    guard slice.count - kept.count >= minimum else { return nil }
    let range = CondensedRange(originals: slice, kept: kept.map(\.id), session: session, scope: scope)
    let summary = AgentMessage(role: "assistant", text: text(range), own: own ? true : nil, condensed: range)
    return Array(messages[..<start]) + kept + [summary] + Array(messages[end...])
  }

  /// The transcript with the range of `summaryID` put back exactly as it was, or nil when that
  /// summary is not in it (Edit and Export).
  static func undo(_ messages: [AgentMessage], summaryID: String) -> [AgentMessage]? {
    guard let at = messages.firstIndex(where: { $0.id == summaryID }), let range = messages[at].condensed
    else { return nil }
    let kept = Set(range.kept)
    var start = at
    while start > 0, kept.contains(messages[start - 1].id) { start -= 1 }
    return Array(messages[..<start]) + range.originals + Array(messages[(at + 1)...])
  }

  /// The transcript before `messageID`, for Edit and rerun, or nil when the message is not in it.
  /// A summary after the message goes with the turns it stands for. The one whose range holds
  /// the message (the user's words stay in place ahead of their summary) is undone first, so the
  /// replies folded from before the message stay. A divider before the message stays,
  /// and no summary left may resume a session that held the replaced turns.
  static func before(_ messages: [AgentMessage], _ messageID: String) -> [AgentMessage]? {
    var list = messages
    if let holder = list.first(where: { $0.condensed?.originals.contains(where: { $0.id == messageID }) == true }),
      let back = undo(list, summaryID: holder.id)
    {
      list = back
    }
    return list.firstIndex(where: { $0.id == messageID }).map { Array(list[..<$0]).map { m in var m = m; m.condensed?.session = nil; return m } }
  }

  /// The transcript with every condensed range put back, as it was before any fold (Export).
  static func expanded(_ messages: [AgentMessage]) -> [AgentMessage] {
    messages.filter { $0.condensed != nil }.reduce(messages) { undo($0, summaryID: $1.id) ?? $0 }
  }

  /// What the agent reads in place of the folded replies: one line each, with the request it
  /// answered, its first line and its steps (labels are already redacted and bounded).
  static func text(_ range: CondensedRange) -> String {
    let kept = Set(range.kept)
    var request = ""
    var lines: [String] = []
    var automatic = false
    for message in range.originals {
      if message.role == "you" {
        automatic = RelayAutomatic.kind(of: message.text) != nil
        request = RelayAutomatic.label(message.text) ?? RunNow.clip(message.text, 80)
        continue
      }
      guard !kept.contains(message.id),
        !RelayProactive.isNothing(message.text), !(automatic && RelayAutomatic.isQuiet(reply: message.text))
      else { continue }
      let first = message.text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
      let actions = message.activities ?? []
      let steps = actions.prefix(3).map(\.label).joined(separator: "; ")
        + (actions.count > 3 ? " and \(actions.count - 3) more steps" : "")
      guard !first.isEmpty || !steps.isEmpty else { continue }
      lines.append("- " + (request.isEmpty ? "" : "To \u{201C}\(request)\u{201D}: ") + RunNow.clip(first, 200)
        + (steps.isEmpty ? "" : (first.isEmpty ? "" : " ") + "[\(steps)]"))
    }
    let head = "Summary of \(range.folded.count) earlier replies and tool steps, condensed to save context:"
    var shown: [String] = []
    var used = head.count + 40
    for line in lines.reversed() {
      guard used + line.count + 1 <= budget else { break }
      shown.insert(line, at: 0)
      used += line.count + 1
    }
    let left = lines.count - shown.count
    return ([head] + (left > 0 ? ["- \(left) earlier replies left out"] : []) + shown).joined(separator: "\n")
  }
}

extension AgentModel {
  /// After a turn ends (AgentHub's onEnd): once its request reached the threshold, the thread's
  /// older replies fold. Never while anything waits on the user (a turn that ended needing them,
  /// a card of this thread, an intent its browser task still holds; those lists are only read),
  /// and never on a linked chat, which the other app's next read replaces. True when it folded.
  /// `force`: the person pressed Compact, so the size threshold does not apply; the rest does.
  func condenseIfDue(_ run: AgentRun, force: Bool = false) -> Bool {
    let id = run.spec.threadID
    let selected = id == conversationID
    let stored = conversations.first(where: { $0.id == id })
    let followed = selected ? link : stored?.link
    let session = run.remoteID ?? (selected ? nativeSessionID : stored?.remoteID)
    guard run.record.outcome == .done, run.approvals.isEmpty, followed == nil,
      browser?.tasks[run.taskID]?.pendingApprovals.isEmpty != false,
      RelayOrchestrator.shared?.approvals.contains(where: { $0.threadID == id }) != true,
      force || (run.contextTokens ?? ChatCondense.estimate(run.transcript)) >= ChatCondense.threshold,
      let folded = ChatCondense.condense(run.transcript, own: run.initialSpec.grants.ownSetup, session: session,
        scope: run.spec.scope)
    else { return false }
    run.folded = true
    run.transcript = folded
    return true
  }
}

/// Where older replies were folded: “Condensed N messages” and Show to read the originals in place
/// (read only). No Undo: folding is how the chat keeps its context, not something to take back (the
/// owner's call, 2026-11-25). Its help shows the summary the agent reads instead.
struct CondensedDivider: View {
  let summary: AgentMessage
  let range: CondensedRange
  var userWidth: CGFloat = 360
  @State private var shown = false
  @Environment(\.palette) private var p
  var body: some View {
    let folded = range.folded
    let count = "Condensed \(folded.count) message\(folded.count == 1 ? "" : "s")"
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Rectangle().fill(p.line).frame(height: 1)
        Text(count).font(UIStyle.meta).foregroundStyle(p.secondary).fixedSize()
          .help(summary.text).accessibilityLabel(count)
        Button(shown ? "Hide" : "Show") { shown.toggle() }.buttonStyle(QuietButton())
          .accessibilityLabel(shown ? "Hide the condensed messages" : "Show the condensed messages")
          .accessibilityValue(shown ? "Expanded" : "Collapsed")
        Rectangle().fill(p.line).frame(height: 1)
      }.accessibilityElement(children: .contain).accessibilityLabel(count)
      if shown {
        VStack(alignment: .leading, spacing: 16) {
          ForEach(folded) { message in
            ThreadMessageContent(message: message, placeholder: "", userWidth: userWidth, showsCopy: false, palette: p)
          }
        }.padding(.leading, 12)
          .overlay(alignment: .leading) { Rectangle().fill(p.line).frame(width: 2) }
          .accessibilityElement(children: .contain).accessibilityLabel("Condensed messages, read only")
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
