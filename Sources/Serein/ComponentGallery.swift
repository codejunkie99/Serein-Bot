#if DEBUG
import AppKit
import SwiftUI

/// A window that shows Serein's shared building blocks on sample data, one tab each. Debug builds
/// open it with `--component-gallery`.
@MainActor enum ComponentGallery {
  private static var window: NSWindow?
  static func open() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Components"
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: GalleryView())
    window.center()
    window.makeKeyAndOrderFront(nil)
    self.window = window
  }
}

private struct GalleryView: View {
  enum Page: Hashable { case thinking, composer, fleet, steps }
  @State private var tab = Page.thinking
  @Environment(\.palette) private var p
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      GoalSegments(label: "Component", options: [
        (Page.thinking, "Thinking trail"), (Page.composer, "Composer"), (Page.fleet, "At work"), (Page.steps, "Steps"),
      ], selection: $tab)
      switch tab {
      case .thinking: ThinkingDemo()
      case .composer: ComposerDemo()
      case .fleet: FleetDemo()
      case .steps: StepsDemo()
      }
      Spacer(minLength: 0)
    }.padding(24).frame(minWidth: 720, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity, alignment: .topLeading)
      .background(p.background)
  }
}

private struct ThinkingDemo: View {
  @State private var steps: [ThinkingTrail.Step] = []
  @State private var started = Date()
  @State private var ended: Date?
  @State private var run = 0
  private static let script: [ThinkingTrail.Step] = [
    .init(id: "1", label: "Searched your apps", sources: [
      .init(app: "slack", name: "Slack · #team-offsite"), .init(app: "notion", name: "Notion · Offsite plan"),
      .init(app: "gmail", name: "Gmail · Venue quote"), .init(app: "googlecalendar", name: "Calendar · June"),
      .init(app: "github", name: "GitHub · offsite-site"), .init(app: "linear", name: "Linear · OFF-12"),
      .init(app: "figma", name: "Figma · Invite"),
    ]),
    .init(id: "2", label: "Comparing three venues on price and travel time"),
    .init(id: "3", label: "Checking who is away that week"),
    .init(id: "4", label: "Writing the shortlist"),
  ]
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      ThinkingTrail(steps: steps, startedAt: started, endedAt: ended).id(run)
      Button("Play again") { run += 1 }.buttonStyle(QuietButton(bordered: true))
    }.task(id: run) {
      steps = []
      ended = nil
      started = Date()
      for step in Self.script {
        try? await Task.sleep(for: .milliseconds(1500))
        if Task.isCancelled { return }
        steps.append(step)
      }
      try? await Task.sleep(for: .milliseconds(1500))
      if Task.isCancelled { return }
      ended = Date()
    }
  }
}

private struct ComposerDemo: View {
  @State private var text = ""
  @State private var asksFirst = false
  @State private var model = "Auto"
  @State private var sent = ""
  @Environment(\.palette) private var p
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ComposerCard(text: $text, asksFirst: $asksFirst, model: $model, models: ["Auto", "Claude Code", "Codex", "Gemini"],
        apps: [("slack", "Slack"), ("notion", "Notion"), ("gmail", "Gmail")],
        send: {
          sent = text
          text = ""
        })
      if !sent.isEmpty {
        Text("Sent to \(model)\(asksFirst ? ", asking first" : ""): \(sent)").font(AssistantType.meta).foregroundStyle(p.secondary)
      }
    }
  }
}

private struct FleetDemo: View {
  @State private var answered = ""
  @Environment(\.palette) private var p
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      AgentFleet(agents: [
        .init(id: "a", name: "Research", app: "Claude Code", task: "Compare offsite venues", state: .working, detail: "12m", helpers: [
          .init(id: "a1", name: "Prices", task: "Read three venue quotes", state: .working),
          .init(id: "a2", name: "Travel", task: "Train times from the office", state: .working),
          .init(id: "a3", name: "Dates", task: "Who is away in June", state: .done),
          .init(id: "a4", name: "Food", task: "Dietary needs from the form", state: .needsYou),
        ]),
        .init(id: "b", name: "Inbox", app: "Codex", task: "Draft replies to this morning's mail", state: .needsYou, detail: "4m"),
        .init(id: "c", name: "Site", app: "Claude Code", task: "Fix the sign-up form on the landing page", state: .working, detail: "31m", helpers: [
          .init(id: "c1", name: "Tests", task: "Run the form checks", state: .working),
          .init(id: "c2", name: "Copy", task: "Shorten the error messages", state: .done),
        ]),
        .init(id: "d", name: "Weekly notes", app: "Gemini", task: "Summarise the week for Friday", state: .done, detail: "6m"),
      ]) { answered = $0 }
      if !answered.isEmpty {
        Text("Answer asked for \(answered)").font(AssistantType.meta).foregroundStyle(p.secondary)
      }
    }
  }
}

private struct StepsDemo: View {
  @State private var done: Set<String> = ["1", "2"]
  @Environment(\.palette) private var p
  private static let titles = ["Create your account", "Connect an AI app", "Connect your calendar", "Add an assistant", "Send your first message"]
  var body: some View {
    StepTracker(title: "Getting started", steps: Self.titles.enumerated().map { index, title in
      StepTracker.Step(id: "\(index + 1)", title: title, done: done.contains("\(index + 1)"))
    }) { id in
      if done.contains(id) { done.remove(id) } else { done.insert(id) }
    }.padding(16).frame(width: 340).assistantCard(p)
  }
}
#endif
