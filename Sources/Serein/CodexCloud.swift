import AppKit
import SereinCore
import SwiftUI

/// A Codex Cloud task in Serein (the Agents card): its status, its whole diff, and, once the
/// person confirms, that diff written into the task's project folder.
///
/// The diff comes from Codex itself (`codex cloud diff`). Serein writes it with plain `git apply`
/// after `git apply --check`, not with `codex cloud apply`, which runs `git apply --3way` (that
/// can leave conflict markers in files) and writes an `error.log` holding the ChatGPT account id
/// into the folder it runs in (both seen on this Mac). A diff that does not fit the folder as it
/// is writes nothing, and git's own words are shown. Every `codex cloud` command runs in a
/// private temporary folder, so that log never lands in a project.
@MainActor final class CloudTaskModel: ObservableObject {
  let task: CloudTask
  /// Codex's own one-line summary ("[READY] … · +3/-8 • 1 file").
  @Published private(set) var status: String?
  /// The whole diff; nil while it loads.
  @Published private(set) var diff: String?
  @Published private(set) var problem: String?
  @Published private(set) var applying = false
  @Published private(set) var applied: String?
  /// Where the diff goes: the project named like the task's environment, else the one chosen.
  @Published var folder: URL?
  /// Asks the person before anything is written (replaced in checks).
  var confirm: (URL, Int) -> Bool = CloudTaskModel.askToApply

  init(task: CloudTask, projects: [Project]) {
    self.task = task
    // A Codex Cloud environment is usually named after its repository.
    if let label = task.environment?.lowercased(), !label.isEmpty,
      let project = projects.first(where: {
        $0.name.lowercased() == label || URL(fileURLWithPath: $0.path).lastPathComponent.lowercased() == label
      })
    {
      folder = URL(fileURLWithPath: project.path)
    }
  }

  /// Files the diff changes (it starts at its first file).
  var files: Int { diff.map { $0.components(separatedBy: "diff --git ").count - 1 } ?? 0 }
  /// What the window shows; a diff too long to show in full is never applied from here.
  var shown: (text: String, truncated: Bool) { UnifiedDiff.cap(diff ?? "", maxLines: 20_000, maxBytes: 4 << 20) }

  func load() async {
    guard let codex = HarnessRegistry.shared.executable(.codex) else {
      problem = "Set up Codex in Settings › AI apps to see this task's changes."
      return
    }
    let env = HarnessRegistry.shared.environment(.codex, executable: codex)
    let scratch = Self.scratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    async let status = HarnessProbe.run(codex, ["cloud", "status", task.id], environment: env, timeout: 30, cwd: scratch)
    async let diff = HarnessProbe.run(codex, ["cloud", "diff", task.id], environment: env, timeout: 90, cwd: scratch)
    let (s, d) = await (status, diff)
    self.status = s.code == 0 ? s.output.split(separator: "\n").map(String.init).joined(separator: " · ") : nil
    // Warnings share the output; the diff starts at its first file.
    if d.code == 0, let start = d.output.range(of: "diff --git ") {
      self.diff = String(d.output[start.lowerBound...])
    } else if d.code == 0 {
      self.diff = ""
    } else {
      problem = "Codex could not read this task's changes." + Self.said(d.output)
    }
  }

  #if DEBUG
    func previewDiff(_ text: String) { diff = text }
  #endif

  func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Use this folder"
    panel.message = "Choose the project folder for “\(task.title)”."
    if panel.runModal() == .OK, let url = panel.url { folder = url }
  }

  /// Checks, asks, then writes the diff. Nothing is committed or staged.
  func apply() async {
    guard let diff, !diff.isEmpty, !shown.truncated, let folder, !applying, applied == nil else { return }
    problem = nil
    applying = true
    defer { applying = false }
    let probe = await Task.detached { GitTurns.probe(folder: folder) }.value
    guard case .repo(let repo) = probe else {
      problem = "\(folder.lastPathComponent) is not a git repository, so Serein cannot apply these changes there."
      return
    }
    guard confirm(repo.root, files) else { return }
    let patch = Self.scratch().appendingPathComponent("task.diff")
    defer { try? FileManager.default.removeItem(at: patch.deletingLastPathComponent()) }
    do { try diff.write(to: patch, atomically: true, encoding: .utf8) } catch {
      problem = "Serein could not prepare the changes. \(error.localizedDescription)"
      return
    }
    var env = ProcessInfo.processInfo.environment
    env["GIT_TERMINAL_PROMPT"] = "0"
    let check = await HarnessProbe.run(repo.git, ["apply", "--check", patch.path], environment: env, timeout: 60, cwd: repo.root)
    guard check.code == 0 else {
      problem = "These changes do not fit \(repo.root.lastPathComponent) as it is now, so nothing was written." + Self.said(check.output)
      return
    }
    let run = await HarnessProbe.run(repo.git, ["apply", patch.path], environment: env, timeout: 60, cwd: repo.root)
    if run.code == 0 {
      applied = "Applied to \(repo.root.lastPathComponent). Nothing is committed or staged; review it with git as usual."
    } else {
      problem = "Git could not apply the changes." + Self.said(run.output)
    }
  }

  static func askToApply(_ root: URL, _ files: Int) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Apply these changes to “\(root.lastPathComponent)”?"
    alert.informativeText =
      "Serein writes the diff shown (\(files) file\(files == 1 ? "" : "s")) into \(root.path) with git. Nothing is committed or staged. If any part does not fit the files as they are now, nothing is written."
    let apply = alert.addButton(withTitle: "Apply")
    let cancel = alert.addButton(withTitle: "Cancel")
    // Return cancels: a write to the person's files needs a deliberate click.
    apply.keyEquivalent = ""
    cancel.keyEquivalent = "\r"
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// A private temporary folder for a `codex cloud` command (it writes ./error.log there).
  static func scratch() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("serein-cloud-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  /// The CLI's last lines, as its own words.
  private static func said(_ output: String) -> String {
    let lines = output.split(separator: "\n").suffix(3).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    return lines.isEmpty ? "" : " " + String(lines.prefix(400))
  }
}

/// The task in its own window, beside the browser (a sheet would cover it).
@MainActor final class CloudTaskWindow: NSObject, NSWindowDelegate {
  private static var open: [String: CloudTaskWindow] = [:]
  private let window: NSWindow
  private let id: String

  static func show(_ task: CloudTask, browser: BrowserModel) {
    if let current = open[task.id] {
      current.window.makeKeyAndOrderFront(nil)
      return
    }
    let model = CloudTaskModel(task: task, projects: browser.projects)
    let controller = CloudTaskWindow(task: task, root: CloudTaskView(model: model, browser: browser))
    open[task.id] = controller
    controller.window.center()
    controller.window.makeKeyAndOrderFront(nil)
    Task { await model.load() }
  }

  private init(task: CloudTask, root: CloudTaskView) {
    id = task.id
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    super.init()
    window.title = task.title
    window.isReleasedWhenClosed = false
    window.backgroundColor = Palette.dynamic(\.background)
    window.minSize = NSSize(width: 520, height: 360)
    window.delegate = self
    window.contentView = NSHostingView(rootView: root)
  }

  func windowWillClose(_ notification: Notification) { Self.open[id] = nil }
}

struct CloudTaskView: View {
  @ObservedObject var model: CloudTaskModel
  @ObservedObject var browser: BrowserModel
  @ObservedObject private var appearance = AppearanceController.shared
  var body: some View { CloudTaskContent(model: model, browser: browser).environment(\.palette, appearance.palette) }
}

private struct CloudTaskContent: View {
  @ObservedObject var model: CloudTaskModel
  @ObservedObject var browser: BrowserModel
  @Environment(\.palette) private var p
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text(verbatim: model.task.title).font(UIStyle.bodyStrong).foregroundStyle(p.ink).lineLimit(2)
        Text(verbatim: model.status ?? ([model.task.status.capitalized] + [model.task.environment].compactMap { $0 }).joined(separator: " · "))
          .role(.meta).lineLimit(2)
      }
      HStack(spacing: 8) {
        if let url = model.task.url {
          Button("Open in browser") {
            browser.openInDefaultBrowser(url)
          }.buttonStyle(QuietButton())
        }
        Spacer(minLength: 8)
        Text(verbatim: model.folder.map { "Apply to \($0.lastPathComponent)" } ?? "No project folder yet").role(.meta)
          .help(model.folder?.path ?? "Choose the folder of this task's repository")
        Button(model.folder == nil ? "Choose folder…" : "Change…") { model.chooseFolder() }.buttonStyle(QuietButton())
          .disabled(model.applying)
        Button(model.applying ? "Applying…" : "Apply…") { Task { await model.apply() } }
          .disabled(model.diff?.isEmpty != false || model.shown.truncated || model.folder == nil || model.applying
            || model.applied != nil)
          .help("Shows the folder and asks before anything is written")
      }
      if let problem = model.problem {
        Text(verbatim: problem).role(.meta).foregroundStyle(p.warning).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let applied = model.applied {
        Text(verbatim: applied).role(.meta).foregroundStyle(p.success)
      }
      diff
    }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(p.background)
  }
  @ViewBuilder var diff: some View {
    if model.diff == nil && model.problem == nil {
      ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.diff?.isEmpty == true {
      Text("This task changed no files.").role(.meta).frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.diff != nil {
      let shown = model.shown
      ScrollView([.vertical, .horizontal]) {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(Array(shown.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
            Text(verbatim: String(line)).font(UIStyle.monoMeta).foregroundStyle(color(line))
              .fixedSize(horizontal: true, vertical: false)
          }
          if shown.truncated {
            Text("This diff is too long to show in full, so Serein does not apply it. Open the task in the browser to read and apply all of it.").role(.meta)
              .padding(.top, 8)
          }
        }.padding(12).textSelection(.enabled)
      }.background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
    }
  }
  private func color(_ line: Substring) -> Color {
    if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") { return p.faint }
    if line.hasPrefix("+") { return p.success }
    if line.hasPrefix("-") { return p.danger }
    if line.hasPrefix("@@") { return p.accent }
    return p.secondary
  }
}
