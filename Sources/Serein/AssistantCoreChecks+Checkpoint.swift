#if DEBUG
import Foundation
import SereinCore

extension AssistantCoreChecks {
  static func checkpointCompletion(_ check: Check) throws {
    func reply(_ status: Int, _ body: String) -> DockerResponse {
      DockerResponse(status: status, headers: [:], body: Data(body.utf8))
    }
    var inspections = [
      reply(200, #"{"Running":true,"ExitCode":null}"#),
      reply(200, #"{"Running":true,"ExitCode":0}"#),
      reply(503, #"{"Running":false,"ExitCode":0}"#),
      reply(200, #"{"Running":false,"ExitCode":null}"#),
      reply(200, #"{"Running":false,"ExitCode":17}"#),
    ]
    let confirmed = try DockerExecExit.wait(inspect: { inspections.removeFirst() }, between: {})
    try check(confirmed == 17 && inspections.isEmpty,
      "A running Docker exec with null or zero exit code and an HTTP error never settles a restore")
    var inspected = 0
    let afterDisconnect = try DockerExecExit.wait(inspect: {
      inspected += 1
      if inspected == 1 { throw DockerError(text: "connection lost") }
      return reply(200, #"{"Running":false,"ExitCode":0}"#)
    }, between: {})
    try check(afterDisconnect == 0 && inspected == 2, "A transient Docker inspection failure retries until exit is confirmed")
    inspected = 0
    var waits = 0
    let unresolved = Result {
      try DockerExecExit.wait(inspect: {
        inspected += 1
        return reply(200, #"{"Running":true,"ExitCode":null}"#)
      }, between: { waits += 1 })
    }
    guard case .failure = unresolved else { throw SereinError.invalid("Docker reported an unconfirmed exit") }
    try check(inspected == 8 && waits == 7, "A worker that never reports an exit stops polling with an indeterminate outcome")
    var attempts = 0
    let retried = DockerCheckpointCompletion.finish(.success(0), unpause: {
      attempts += 1
      return attempts == 2
    }, state: { "paused" })
    try check(try retried.result.get() == 0 && retried.desktopRunning && attempts == 2,
      "A committed restore stays successful when the first resume fails and the retry succeeds")

    let lost = DockerCheckpointCompletion.finish(.success(0), unpause: { false }, state: { "running" })
    try check(try lost.result.get() == 0 && lost.desktopRunning,
      "An inspection confirms Docker resumed even if the unpause response was lost")

    let pending = DockerCheckpointCompletion.finish(.success(0), unpause: { false }, state: { nil })
    try check(try pending.result.get() == 0 && !pending.desktopRunning,
      "An unavailable Docker daemon leaves a desktop resume owed while the restore stays committed")

    let failed = DockerCheckpointCompletion.finish(.failure(SereinError.invalid("archive failure")),
      unpause: { false }, state: { "paused" })
    guard case .failure(let error) = failed.result else { throw SereinError.invalid("Lost archive failure") }
    try check(error.localizedDescription.contains("archive failure") && !failed.desktopRunning,
      "A failed resume preserves the original archive error")
  }
}
#endif
