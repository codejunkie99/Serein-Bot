import SereinCore
import SwiftUI

/// What each tool call of this launch was given and what came back, by the step id the trail and
/// the step list carry. Memory only: the transcript keeps labels alone.
@MainActor final class ToolCallBook: ObservableObject {
  static let shared = ToolCallBook()
  @Published private(set) var calls: [String: ToolCall] = [:]
  /// UI previews only: fixture calls, nothing from a run.
  func preview(_ fixture: [ToolCall]) {
    for call in fixture { calls[call.id] = call }
  }
}

/// A finished turn's step as a Tool Call Card (affectUI Tool Call Card): one line with its mark,
/// what it did, the tool's name in mono, and how long it took or "Failed" in words. A click opens
/// what it was given and what came back. A failed call opens itself. A step with no recorded call
/// (an earlier launch, a page step) stays a plain line. Opens at once: the chat's layout never animates.
struct ToolCallRow: View {
  let id: String
  let label: String
  var failed = false
  /// Retry on a failed call: sends these words as the person's next message.
  var retry: ((String) -> Void)? = nil
  @ObservedObject private var book = ToolCallBook.shared
  @State private var open: Bool?
  @Environment(\.palette) private var p
  var body: some View {
    let call: ToolCall? = book.calls[id]
    let isOpen: Bool = call != nil && (open ?? failed)
    let again: (() -> Void)? = retry.map { send in { send(ToolCalls.retryWords(label)) } }
    VStack(alignment: .leading, spacing: 6) {
      if let call {
        Button { open = !isOpen } label: { line(call, open: isOpen) }
          .buttonStyle(AssistantPressStyle())
          .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
          .accessibilityHint(isOpen ? "Hides what it was given and what came back" : "Shows what it was given and what came back")
        if isOpen {
          ToolCallDetail(call: call, retry: again).padding(.leading, 26)
        }
      } else {
        line(nil, open: false)
      }
    }
  }
  private func line(_ call: ToolCall?, open: Bool) -> some View {
    HStack(spacing: 10) {
      Circle().fill(failed ? p.danger : p.faint).frame(width: 5, height: 5).frame(width: 16)
      Text(verbatim: label).font(AssistantType.body).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.middle)
      if let call {
        Text(verbatim: call.tool).font(UIStyle.microMono).foregroundStyle(p.faint).lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 8)
      if failed {
        // Said in words with a mark, never by colour alone.
        HStack(spacing: 4) {
          InterfaceIcon(systemName: "exclamationmark.circle", size: 11)
          Text("Failed")
        }.font(AssistantType.meta).foregroundStyle(p.danger).fixedSize()
      } else if let took = call.flatMap(ToolCalls.took) {
        Text(verbatim: took).font(AssistantType.figures).foregroundStyle(p.faint).fixedSize()
      }
      if call != nil {
        InterfaceIcon(systemName: "chevron.right", size: 9).foregroundStyle(p.faint)
          .rotationEffect(.degrees(open ? 90 : 0)).accessibilityHidden(true)
      }
    }.contentShape(Rectangle())
  }
}

/// The open part of a Tool Call Card: what the call was given and what came back, each in mono on
/// the `track` wash with Copy, a long one folded to its first lines behind "Show all N lines". A
/// call still running says it waits; a failed one offers Retry beside what went wrong.
struct ToolCallDetail: View {
  let call: ToolCall
  var retry: (() -> Void)? = nil
  @State private var allInput = false
  @State private var allOutput = false
  @Environment(\.palette) private var p
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !call.input.isEmpty { block("Given", call.input, all: $allInput) }
      if let output = call.output {
        block(call.failed ? "What went wrong" : "Came back", output.isEmpty ? "Nothing" : output, all: $allOutput)
      } else {
        Text("Waiting for the result…").font(AssistantType.meta).foregroundStyle(p.faint)
      }
      if call.failed, let retry {
        Button(action: retry) { Text("Retry").font(AssistantType.meta).foregroundStyle(p.accent).linkTarget() }
          .buttonStyle(AssistantPressStyle()).fixedSize()
          .help("Ask for this step again").accessibilityLabel("Retry this step")
      }
    }
  }
  private func block(_ title: String, _ text: String, all: Binding<Bool>) -> some View {
    let shown = ToolCalls.folded(text, open: all.wrappedValue)
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(title).font(AssistantType.meta).foregroundStyle(p.secondary)
        Spacer(minLength: 0)
        Button { MessageActions.copy(text) } label: {
          Text("Copy").font(AssistantType.meta).foregroundStyle(p.accent).linkTarget()
        }.buttonStyle(AssistantPressStyle()).fixedSize().accessibilityLabel("Copy \(title.lowercased())")
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: shown.text).font(UIStyle.microMono).foregroundStyle(p.ink)
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        if shown.hidden > 0 {
          Button { all.wrappedValue = true } label: {
            Text("Show all \(shown.hidden + ToolCalls.foldLines) lines").font(AssistantType.meta).foregroundStyle(p.accent).linkTarget()
          }.buttonStyle(AssistantPressStyle()).fixedSize()
        }
      }
      .padding(.horizontal, 10).padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(p.track, in: RoundedRectangle(cornerRadius: UIStyle.rowRadius, style: .continuous))
    }
  }
}
