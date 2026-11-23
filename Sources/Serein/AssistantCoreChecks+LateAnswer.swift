#if DEBUG
import Foundation
import SereinCore

/// A card raised inside a socket call closes before the caller stops waiting, so a card for a
/// call that has returned can no longer run its action (CallWindow, SocketCall).
extension AssistantCoreChecks {
  static func lateAnswer(_ check: Check) throws {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let window = CallWindow(start: start)
    let returned = start.addingTimeInterval(SocketServer.answerWait)
    try check(
      SocketServer.answerWait < 120 && window.answerBy < returned
        && window.answerBy == start.addingTimeInterval(SocketServer.answerWait - CallWindow.margin),
      "A socket call answers before the agent's 120 s tool limit, and its cards stop taking answers before that answer")
    try check(
      window.cardLife(RelayAsk.timeout, now: start) == SocketServer.answerWait - CallWindow.margin
        && window.cardLife(RelayAsk.timeout, now: start.addingTimeInterval(100)) == SocketServer.answerWait - CallWindow.margin - 100
        && window.cardLife(5, now: start) == 5,
      "A card in a call waits its own life or what the call has left, whichever is shorter")
    try check(
      window.cardLife(RelayAsk.timeout, now: window.answerBy) == nil
        && window.cardLife(RelayAsk.timeout, now: returned) == nil,
      "Once the call has nothing left, no card shows")
    let lastCard = stride(from: 0.0, to: SocketServer.answerWait + 30, by: 0.5).allSatisfy { asked in
      let at = start.addingTimeInterval(asked)
      guard let life = window.cardLife(RelayAsk.timeout, now: at) else { return true }
      return at.addingTimeInterval(life) <= window.answerBy
    }
    try check(lastCard, "Every card a call raises, early or late in it, closes before the call stops taking answers")
    try check(
      window.settle(.yes, at: start.addingTimeInterval(60)) == .yes
        && window.settle(.yes, at: window.answerBy) == .timeout
        && window.settle(.yes, at: returned) == .timeout
        && window.settle(.yes, at: returned.addingTimeInterval(180)) == .timeout,
      "A yes inside the window runs; an Allow pressed after the call returned runs nothing")
    try check(
      window.settle(.no, at: returned) == .no && window.settle(.timeout, at: start) == .timeout,
      "A no stays a no, and a timeout is never turned into a yes")
    let error = CallWindow.reply(["error": ActionAdmission.needsPerson], unanswered: true)
    let quiet = CallWindow.reply(["done": false], unanswered: true)
    let answered = CallWindow.reply(["error": ActionAdmission.declined], unanswered: false)
    try check(
      error["error"] as? String == CallWindow.unansweredResult
        && quiet["unanswered"] as? String == CallWindow.unansweredResult && quiet["done"] as? Bool == false
        && answered["error"] as? String == ActionAdmission.declined,
      "A call whose card went unanswered tells the caller so; any other call's reply is untouched")
    try check(
      CallWindow.unansweredResult.contains("did not answer in time") && CallWindow.unansweredResult.contains("nothing was done")
        && CallWindow.unansweredResult.contains("Ask again"),
      "The tool result says the person did not answer in time, nothing was done, and to ask again if still needed")
    let line = ApprovalLife.line(.unanswered)
    try check(
      line.word == "Declined" && line.why == "No answer in time. Nothing was done.",
      "The closed card reads Declined, with “No answer in time. Nothing was done.”")
    try check(
      ToolGate.limit < SocketServer.answerWait - CallWindow.margin,
      "A call waiting its turn in the task's line gives up well inside the socket's wait")
  }
}
#endif
