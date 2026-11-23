import AppKit
import SereinCore
import SwiftUI

/// UI previews only: the Tool Call Card, Run Controls and Message Actions with fixture data, on a
/// sheet over the preview screen (`--ui-affect-tool-call`, `--ui-affect-run-controls`, optionally
/// followed by `stopped`, and `--ui-affect-message-actions`). Nothing here runs a task.
enum AffectLaneOnePreview {
  enum Item { case toolCall, runControls(stopped: Bool), messageActions }

  static func item(_ arguments: [String]) -> Item? {
    if arguments.contains("--ui-affect-tool-call") { return .toolCall }
    if let index = arguments.firstIndex(of: "--ui-affect-run-controls") {
      return .runControls(stopped: arguments.indices.contains(index + 1) && arguments[index + 1] == "stopped")
    }
    if arguments.contains("--ui-affect-message-actions") { return .messageActions }
    return nil
  }

  @MainActor static func present(_ item: Item, on window: NSWindow, browser: BrowserModel, agent: AgentModel) {
    let start = Date().addingTimeInterval(-90)
    switch item {
    case .toolCall:
      ToolCallBook.shared.preview(calls(start))
    case .runControls(let stopped):
      agent.draft = stopped ? "" : "Use the March figures instead"
    case .messageActions:
      ReplyVersionBook.shared.preview(chat: "preview-versions", asked: "Plan my week",
                                      earlier: ["Monday is clear, so the review fits there. Tuesday has two calls."])
    }
    let view = Sheet(item: item, start: start, browser: browser, agent: agent)
      .environment(\.palette, Palette.current)
    let sheet = NSWindow(contentViewController: NSHostingController(rootView: view))
    sheet.setContentSize(NSSize(width: 560, height: 520))
    window.beginSheet(sheet)
  }

  static func calls(_ start: Date) -> [ToolCall] {
    let results = (1...14).map { "Result \($0): Sources/Upload.swift:\($0 * 12)" }.joined(separator: "\n")
    return [
      ToolCall(id: "preview-read", tool: "Read", input: "{\n  \"file_path\" : \"Sources/Upload.swift\"\n}",
               output: "import Foundation\n\nstruct Upload {\n  var url: URL\n}", startedAt: start,
               endedAt: start.addingTimeInterval(0.4)),
      ToolCall(id: "preview-search", tool: "Grep", input: "{\n  \"pattern\" : \"Upload\"\n}", output: results,
               startedAt: start.addingTimeInterval(1), endedAt: start.addingTimeInterval(3)),
      ToolCall(id: "preview-test", tool: "Bash", input: "{\n  \"command\" : \"swift test --filter Upload\"\n}",
               output: "error: no such module 'XCTest'", failed: true,
               startedAt: start.addingTimeInterval(4), endedAt: start.addingTimeInterval(16)),
    ]
  }

  private struct Sheet: View {
    let item: Item
    let start: Date
    @ObservedObject var browser: BrowserModel
    @ObservedObject var agent: AgentModel
    @State private var askSignIns = false
    @Environment(\.palette) private var p
    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        switch item {
        case .toolCall:
          VStack(alignment: .leading, spacing: 6) {
            ToolCallRow(id: "preview-read", label: "Read Sources/Upload.swift", retry: { _ in })
            ToolCallRow(id: "preview-search", label: "Searched the code for Upload", retry: { _ in })
            ToolCallRow(id: "preview-test", label: "Ran the upload tests", failed: true, retry: { _ in })
          }
          Divider()
          StepTimeline(steps: steps, startedAt: start, cap: 220, retry: { _ in })
        case .runControls(let stopped):
          ComposerControls(browser: browser, agent: agent, owner: "preview-affect", expanded: true,
                           running: !stopped, stopped: stopped, askSignIns: $askSignIns, send: {})
        case .messageActions:
          HStack(alignment: .bottom, spacing: 8) {
            SereinReplyBubble(text: shownReply) {
              Text(verbatim: shownReply).font(AssistantType.bubble).foregroundStyle(p.ink)
            } accessory: {
              MessageActions(text: newestReply, retry: {}, speak: { _ in })
            }
          }
          // The actions hang past the bubble, as in the chat's side margin; the sheet has no margin.
          .padding(.trailing, 100)
        }
        Spacer(minLength: 0)
      }
      .padding(16)
      .frame(width: 560, height: 520, alignment: .topLeading)
      .background(p.card)
    }
    private var steps: [AgentStep] {
      var read = AgentStep(time: start, tool: "Read", label: "Read Sources/Upload.swift")
      read.id = "preview-read"
      var test = AgentStep(time: start.addingTimeInterval(4), tool: "Bash", label: "Ran the upload tests")
      test.id = "preview-test"
      test.failed = "error: no such module 'XCTest'"
      return [read, test]
    }
    private let newestReply = "Monday is clear, so the review fits there. Tuesday is taken by two calls, so I left it alone."
    @ObservedObject private var versions = ReplyVersionBook.shared
    private var shownReply: String { versions.text(current: newestReply) }
  }
}
