import AppKit
import SereinCore

/// Watches Fn from any app. Carbon hot keys cannot register a lone modifier, and an event monitor
/// or tap would need Input Monitoring and sees every key typed in every app. These two calls need
/// no permission and carry no key contents: which modifiers are down, and how long since a key.
@MainActor final class FnKeyWatch {
  private var machine = FnCallMachine()
  private var timer: DispatchSourceTimer?
  private let claimed: () -> Bool
  private let report: (FnCallEvent) -> Void

  init(claimed: @escaping () -> Bool, report: @escaping (FnCallEvent) -> Void) {
    self.claimed = claimed
    self.report = report
    let source = DispatchSource.makeTimerSource(queue: .main)
    source.schedule(
      deadline: .now(), repeating: FnCallMachine.sampleInterval, leeway: .milliseconds(10))
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.tick() }
    }
    source.resume()
    timer = source
  }

  func stop() {
    timer?.cancel()
    timer = nil
  }

  private func tick() {
    let flags = CGEventSource.flagsState(.combinedSessionState)
    let fnDown = flags.contains(.maskSecondaryFn)
    let others: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
    let sample = FnCallSample(
      fnDown: fnDown,
      otherModifiers: !flags.intersection(others).isEmpty,
      // Asked only while Fn is down: this runs twenty times a second.
      claimed: fnDown && claimed(),
      secondsSinceKey: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown),
      time: ProcessInfo.processInfo.systemUptime)
    if let event = machine.step(sample) { report(event) }
  }
}
