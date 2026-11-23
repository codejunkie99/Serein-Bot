import AppKit
import SereinCore
import SwiftUI

/// What an app outside Serein is asking and its own answers, for the dock above Serein's composer
/// (`DecisionDock`). Choosing an answer presses it in that app (`WaitingAnswer`).
@MainActor final class WaitingCardModel: ObservableObject {
  enum State: String { case waiting, answering, done, changed, failed }
  @Published private(set) var prompt: WaitingPrompt?
  @Published private(set) var read: WaitingAnswer.Read = .unreadable
  @Published private(set) var state: State = .waiting
  @Published private(set) var chosen: String?
  @Published private(set) var note = ""
  private(set) var session: ExternalSession
  private var poll: Task<Void, Never>?

  init(session: ExternalSession) { self.session = session }

  func start() {
    poll?.cancel()
    poll = Task { [weak self] in
      while !Task.isCancelled {
        self?.refresh()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
      }
    }
  }
  func stop() { poll?.cancel(); poll = nil }

  /// Screenshots (`--ui-preview`): a preview session asks a fixed, synthetic question.
  static let previewPrompt = WaitingPrompt(
    kind: .terminal, question: "Do you want to proceed?", detail: "Bash command\ngit push origin main",
    choices: ["Yes", "Yes, and don't ask again for git push", "No, and tell Claude what to do differently (esc)"]
      .enumerated().map { WaitingPrompt.Choice(label: $0.element, index: $0.offset) },
    selected: 0)

  /// The question last answered here: a different one after it is new and shows again.
  private var answered: WaitingPrompt?

  private func refresh() {
    guard state != .answering else { return }
    if RunMode.previewing, session.id.hasPrefix("preview.") {
      // `--ui-dock-no-access`: the card while Serein has no Accessibility, with its drag tile.
      if CommandLine.arguments.contains("--ui-dock-no-access") {
        read = .needsAccessibility
        note = WaitingAnswer.accessibilityNote
        return
      }
      prompt = Self.previewPrompt
      read = .found(Self.previewPrompt)
      return
    }
    let (read, found) = WaitingAnswer.read(session)
    self.read = read
    // A window Serein can press beats the transcript; otherwise Claude Code's own transcript still
    // says what it asks (the desktop app's questions can't be read through Accessibility).
    let next = found?.prompt ?? transcriptPrompt()
    if let next, let prompt, !next.sameAsked(prompt), state == .waiting {
      note = "The question changed."
    }
    if state == .done || state == .changed {
      // After an answer the card keeps saying so, until the app asks something new.
      guard let next, answered.map({ !next.sameAsked($0) }) ?? true else { return }
      state = .waiting
      chosen = nil
      note = ""
    }
    prompt = next
    guard state == .waiting else { return }
    if next?.kind == .transcript {
      note = Self.transcriptNote(appName)
    } else if next == nil {
      note = read == .needsAccessibility ? WaitingAnswer.accessibilityNote : ""
    }
  }

  /// The question in a Claude Code session's transcript, when its window can't be read.
  private func transcriptPrompt() -> WaitingPrompt? {
    guard session.driver == .claude, let log = session.log else { return nil }
    return WaitingPromptReader.claudeTranscript(path: log)
  }

  static func transcriptNote(_ app: String) -> String { "Answer it in \(app). Serein can show this question but can't press its answers." }

  func choose(_ id: String) {
    // A failed answer can be tried again; the window is read again before anything is pressed.
    guard state == .waiting || state == .failed, let shown = prompt,
      let choice = shown.choices.first(where: { $0.id == id }) else { return }
    // Read from the transcript: nothing to press here, so the choice opens the app to answer.
    if shown.kind == .transcript { open(); return }
    state = .answering
    chosen = id
    note = "Answering in \(session.driver.displayName)…"
    Task {
      let outcome = await WaitingAnswer.answer(choice, shown: shown, session: session)
      switch outcome {
      case .answered:
        state = .done
        answered = shown
        note = "Answered “\(choice.label)” in \(appName)."
      case .unverified:
        state = .done
        answered = shown
        note = "Sent “\(choice.label)” to \(appName), but couldn't confirm it took. Open it to check."
      case .changed:
        state = .waiting
        chosen = nil
        note = "It asks something else now. Nothing was pressed."
        refresh()
      case .failed(let why):
        state = .failed
        chosen = nil
        note = why
      }
    }
  }

  var appName: String { WaitingAnswer.app(for: session)?.localizedName ?? session.driver.displayName }

  func open() { AgentsCard.reveal(session) }
}
