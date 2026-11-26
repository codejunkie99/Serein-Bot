import SereinCore
import SwiftUI

/// The New Serein dialog (`TeamSheets.Kind.newSerein`), opened by every New Serein: the sidebar's
/// + menu and its New Serein row, File › New Serein… (⌃⌘N) and a team's Add Assistant menu. It
/// shows where you are, so the sidebar never opens or moves for it. A face in the next free tint
/// with its eyes closed until the first letter, the field ("Name your new Serein"), the problem in
/// 12 `danger` (taken or too long), then Cancel and Make Serein (primary, off
/// while the field is empty or has a problem), which reads "Making…" while the assistant is made.
/// Return makes, Esc cancels. Made, its chat opens with the message box ready.
struct NewSereinSheet: View {
  var body: some View {
    if let relay = SereinSurface.controller?.relay {
      NewSereinForm(relay: relay)
    } else {
      SereinUnavailable().frame(width: 440, height: 200)
    }
  }
}

private struct NewSereinForm: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject private var board = AssistantSidebarState.shared
  @State private var name = ""
  @State private var problem: String?
  @State private var making = false
  @FocusState private var focused: Bool
  @Environment(\.palette) var p
  private var tint: String { AssistantColour.next(used: relay.team.profiles.map(\.colour)) }
  private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var off: Bool { trimmed.isEmpty || problem != nil || making }
  var body: some View {
    SheetFrame(title: "New Serein", subtitle: "It gets its own chat. Name it for its job, like Inbox or Travel.", back: nil, footer: {
      Spacer(minLength: 0)
      Button("Cancel") { TeamSheets.shared.dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
      Button(action: make) { makeLabel }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
        .disabled(off).opacity(off && !making ? 0.4 : 1)
        .accessibilityLabel(making ? "Making the new Serein" : "Make Serein")
    }) {
      field
      if let problem {
        Text(verbatim: problem).font(UIStyle.meta).foregroundStyle(p.danger).fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(width: 440)
    .background(p.raised)
    .onAppear { focused = true }
    .onChange(of: name) { _, _ in
      problem = AssistantRowRules.nameProblem(trimmed, roster: relay.team.profiles.map(\.name))
    }
  }
  private var field: some View {
    let ring = RoundedRectangle(cornerRadius: 10, style: .continuous)
    return HStack(spacing: 10) {
      AssistantFaceView(face: AssistantFace(id: "new-assistant").wearing(tint), size: 22, closedEyes: trimmed.isEmpty)
      TextField("Name your new Serein", text: $name)
        .textFieldStyle(.plain).font(AssistantType.name).foregroundStyle(p.ink)
        .focused($focused)
        .disabled(making)
        .onSubmit(make)
        .accessibilityLabel("New Serein's name")
    }
    .padding(.horizontal, 12).frame(height: 40)
    .overlay(ring.strokeBorder(problem == nil ? p.wash(0.15) : p.danger, lineWidth: 1))
  }
  private var makeLabel: some View {
    Group {
      if making { ShimmerText(text: "Making…", font: UIStyle.body, color: p.onSolid) } else { Text("Make Serein") }
    }
  }
  /// The person's own words name the make, so it is made at once (`makeAssistant(named:)`, which
  /// posts its first message in its chat with no model turn); the chat then switches to it. The
  /// button reads "Making…" first, for one frame at the least.
  private func make() {
    guard !making, !trimmed.isEmpty else { return }
    if let refusal = AssistantRowRules.nameProblem(trimmed, roster: relay.team.profiles.map(\.name)) {
      problem = refusal
      return
    }
    making = true
    let clean: String = RelayProfile.cleanName(trimmed)
    Task { @MainActor in
      await Task.yield()
      finish(clean)
    }
  }
  private func finish(_ clean: String) {
    let before: Set<String> = Set(relay.team.profiles.map(\.id))
    if let refusal = relay.makeAssistant(named: clean) {
      making = false
      problem = refusal
      return
    }
    making = false
    TeamSheets.shared.dismiss()
    guard let made = relay.team.profiles.first(where: { !before.contains($0.id) }) else { return }
    board.lastClicked = (nil, made.id)
    if relay.openAssistant(made.id) { board.switched() }
    NotificationCenter.default.post(name: SereinSurface.focus, object: nil)
  }
}
