import AppKit
import Combine
import SereinCore
import SwiftUI

/// The person's recipes (Show me once), one 0600 file each in the Library's private `recipes`
/// folder. Nothing here is an agent tool or in a prompt: Serein reads a recipe only when the
/// person asks it to run or update one (RelayToolHost `recipe_run`, `recipe_update`).
@MainActor final class RecipeBook: ObservableObject {
  static let shared = RecipeBook()
  static let folder = "recipes"
  @Published private(set) var recipes: [Recipe] = []
  private var library: Library?

  /// At launch.
  func attach(_ library: Library) {
    self.library = library
    reload()
  }

  private func reload() {
    guard let library else { return }
    let files = (try? FileManager.default.contentsOfDirectory(
      at: library.root.appendingPathComponent(Self.folder, isDirectory: true), includingPropertiesForKeys: nil)) ?? []
    // Only a file named by its recipe's id is kept, so Delete always removes the file it came from.
    recipes = files.filter { $0.pathExtension == "json" }
      .compactMap { url -> Recipe? in
        guard let recipe = library.load(Recipe.self, from: Self.folder + "/" + url.lastPathComponent),
          url.deletingPathExtension().lastPathComponent == recipe.id
        else { return nil }
        return recipe
      }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  /// The file is named by the recipe's id, which must be a UUID, so no name reaches a path.
  private func file(_ recipe: Recipe) throws -> String {
    guard UUID(uuidString: recipe.id) != nil else { throw SereinError.invalid("This recipe cannot be saved.") }
    return Self.folder + "/" + recipe.id + ".json"
  }

  func save(_ recipe: Recipe) throws {
    guard let library else { throw SereinError.invalid("Recipes are unavailable.") }
    let name = recipe.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw SereinError.invalid("Give the recipe a name.") }
    guard !recipes.contains(where: { $0.id != recipe.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
      throw SereinError.invalid("Another recipe already has that name.")
    }
    let path = try file(recipe)
    try FileManager.default.createDirectory(
      at: library.root.appendingPathComponent(Self.folder, isDirectory: true), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    var saved = recipe
    saved.name = String(name.prefix(Recipe.nameLimit))
    try library.save(saved, to: path)
    reload()
  }

  func rename(_ recipe: Recipe, to name: String) throws {
    var renamed = recipe
    renamed.name = name
    try save(renamed)
  }

  /// Removes the recipe's file.
  func delete(_ recipe: Recipe) throws {
    guard let library else { return }
    let url = library.root.appendingPathComponent(try file(recipe))
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    reload()
  }
}

/// Records the person's own steps in one tab they choose (⋯ › Show Serein How…). PageKit posts
/// each trusted click, typed value, choice and Enter from the top document; password, card, code
/// and file fields arrive as the person's own step with no value. Private, hidden and agent tabs
/// cannot record, and a step made while a task drives the tab is dropped.
@MainActor final class RecipeRecorder: ObservableObject {
  static let shared = RecipeRecorder()
  enum State { case idle, recording, review }
  @Published private(set) var state: State = .idle
  @Published private(set) var steps: [RecipeStep] = []
  /// The review sheet is open; closing it keeps the steps until Save or Discard.
  @Published var reviewing = false
  private(set) var start = ""
  private weak var tab: BrowserTab?
  private weak var browser: BrowserModel?
  private var loads: AnyCancellable?

  static func eligible(_ tab: BrowserTab?) -> Bool {
    guard let tab, PageViewportRecorder.eligible(tab), !tab.hiddenFromAgents else { return false }
    return ["http", "https"].contains(URL(string: tab.address)?.scheme?.lowercased() ?? "")
  }
  func belongs(to browser: BrowserModel) -> Bool { self.browser === browser }
  var host: String { URL(string: start)?.host ?? start }

  func begin(tab: BrowserTab, browser: BrowserModel) throws {
    guard state == .idle, Self.eligible(tab) else {
      throw SereinError.invalid("Open a regular webpage to show Serein how. Private, hidden and agent-owned tabs are excluded.")
    }
    let address = AgentPrivacy.url(tab.address)
    guard URL(string: address)?.host != nil else { throw SereinError.invalid("This page’s address cannot start a recipe.") }
    start = address
    steps = []
    self.tab = tab
    self.browser = browser
    tab.onUserStep = { [weak self, weak tab] json in
      // Eligible again at each step: the tab may since show a file, about: or data: page, or be private or hidden.
      guard let self, let tab, self.state == .recording, self.tab === tab, RecipeRecorder.eligible(tab), tab.inTask?() != true,
        self.steps.count < 200, let step = RecipeStep.recorded(json)
      else { return }
      self.steps.append(step)
    }
    state = .recording
    // Each new document starts with recording off; turn it on again whenever a load finishes.
    loads = tab.$loading.sink { [weak self] loading in
      guard !loading else { return }
      Task { @MainActor in self?.arm(true) }
    }
  }

  private func arm(_ on: Bool) {
    guard let tab, !tab.sleeping, !on || state == .recording else { return }
    Task { _ = try? await tab.script("globalThis.__serein&&globalThis.__serein.record(\(on))") }
  }

  /// Stop: the review sheet opens with the steps; with none, nothing is kept.
  func stop() {
    guard state == .recording else { return }
    arm(false)
    detach()
    if steps.isEmpty {
      browser?.notice = "Serein saw no steps to keep. Click, type or choose on the page while it watches."
      reset()
      return
    }
    state = .review
    reviewing = true
  }

  /// The review sheet's trash button: a stray step (a misclick, a cookie banner) is left out.
  func remove(_ id: String) {
    guard state == .review else { return }
    steps.removeAll { $0.id == id }
  }

  func discard() {
    if state == .recording { arm(false) }
    detach()
    reset()
  }

  /// Saves the steps as a recipe. `blanks` maps a typed or chosen step's id to the name its value
  /// is asked under each run; the recorded value of such a step is not kept.
  func save(name: String, blanks: [String: String]) throws {
    let kept = steps.map { step -> RecipeStep in
      guard step.kind == .type || step.kind == .select, let blank = blanks[step.id] else { return step }
      var asked = step
      let named = blank.trimmingCharacters(in: .whitespacesAndNewlines)
      asked.value = .blank(String((named.isEmpty ? (step.label.isEmpty ? "Value" : step.label) : named).prefix(40)))
      return asked
    }
    let recipe = Recipe(name: name, start: start, steps: kept)
    try RecipeBook.shared.save(recipe)
    browser?.notice = "Saved the recipe “\(recipe.name.trimmingCharacters(in: .whitespacesAndNewlines))”. Ask Serein to run it, or run it from Settings › Assistants › Recipes and shortcuts."
    reset()
  }

  private func detach() {
    loads = nil
    tab?.onUserStep = nil
  }

  private func reset() {
    state = .idle
    reviewing = false
    steps = []
    start = ""
    tab = nil
    browser = nil
  }
}

/// ⋯ › Show Serein How…: starts recording the person's steps in this tab; while it records the
/// row reads Stop Showing Serein. The bar under the page (`RecipeRecordBar`) has the same controls.
@MainActor enum RecipeRecordAction {
  static func title(_ recorder: RecipeRecorder = .shared) -> String {
    recorder.state == .recording ? "Stop Showing Serein" : "Show Serein How…"
  }
  static func enabled(_ browser: BrowserModel, _ recorder: RecipeRecorder = .shared) -> Bool {
    recorder.state == .recording
      || (recorder.state == .idle && browser.section == ShellSection.browser && RecipeRecorder.eligible(browser.active))
  }
  static func run(_ browser: BrowserModel, _ recorder: RecipeRecorder = .shared) {
    if recorder.state == .recording {
      recorder.stop()
    } else if let tab = browser.active {
      do { try recorder.begin(tab: tab, browser: browser) } catch { browser.notice = error.localizedDescription }
    }
  }
}

/// The thin bar under the page while Serein watches: a red dot, the step count, Stop and Discard.
struct RecipeRecordBar: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject private var recorder = RecipeRecorder.shared
  @Environment(\.palette) private var p
  var body: some View {
    if recorder.state != .idle && recorder.belongs(to: browser) {
      HStack(spacing: 8) {
        Circle().fill(p.danger).frame(width: 6, height: 6).accessibilityHidden(true)
        Text(status).font(UIStyle.meta)
        Spacer(minLength: 4)
        if recorder.state == .recording {
          Button("Stop") { recorder.stop() }.buttonStyle(QuietButton())
        } else {
          Button("Review…") { recorder.reviewing = true }.buttonStyle(QuietButton())
        }
        Button("Discard") { recorder.discard() }.buttonStyle(QuietButton())
      }.foregroundStyle(p.ink).padding(.horizontal, 12).padding(.vertical, 4)
        .background(p.card).accessibilityElement(children: .contain).accessibilityLabel("Showing Serein how")
        .accessibilityValue(status)
        .sheet(isPresented: $recorder.reviewing) {
          RecipeReviewSheet(recorder: recorder).environment(\.palette, p)
        }
    }
  }
  private var status: String {
    let count = "\(recorder.steps.count) step\(recorder.steps.count == 1 ? "" : "s")"
    return recorder.state == .recording ? "Showing Serein how · " + count : "Ready to save · " + count
  }
}

/// After Stop: the steps in plain words. Each typed or chosen value stays the same every time or
/// is asked each run; the person's own steps (passwords, cards, codes, files) hold no value.
struct RecipeReviewSheet: View {
  @ObservedObject var recorder: RecipeRecorder
  @State private var name = ""
  /// Step id -> the name its value is asked under (Ask each time).
  @State private var blanks: [String: String] = [:]
  @State private var error: String?
  @Environment(\.palette) var p
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Save what you showed Serein").role(.section)
      Text("Your steps on \(recorder.host). A typed value can be the same every time or asked each run. Serein keeps nothing for password, card, code or file fields: those steps stay yours.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(Array(recorder.steps.enumerated()), id: \.element.id) { index, step in
            row(index, step)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.frame(maxHeight: 340)
      TextField("Recipe name, such as Expense report", text: $name).textFieldStyle(.roundedBorder)
        .accessibilityLabel("Recipe name")
      if let error { Text(error).role(.meta).foregroundStyle(p.danger) }
      HStack {
        Button("Discard") { recorder.discard() }.buttonStyle(QuietButton())
        Spacer()
        Button("Not Now") { recorder.reviewing = false }.buttonStyle(QuietButton())
        Button("Save Recipe") {
          do { try recorder.save(name: name, blanks: blanks) } catch { self.error = error.localizedDescription }
        }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || recorder.steps.isEmpty)
      }
    }.padding(24).frame(width: UIStyle.wide(520)).background(p.panel)
  }

  private func row(_ index: Int, _ step: RecipeStep) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("\(index + 1).").font(UIStyle.monoMeta).foregroundStyle(p.secondary).accessibilityHidden(true)
        Text(step.words).role(.body).fixedSize(horizontal: false, vertical: true)
          .foregroundStyle(step.kind == .yours ? p.warning : p.ink)
          .accessibilityLabel("Step \(index + 1): \(step.words)")
        Spacer(minLength: 4)
        Button {
          blanks[step.id] = nil
          recorder.remove(step.id)
        } label: {
          InterfaceIcon(systemName: "trash", size: 13)
        }.buttonStyle(QuietButton()).help("Remove this step").accessibilityLabel("Remove step \(index + 1)")
      }
      if step.kind == .type || step.kind == .select {
        Picker("Value for step \(index + 1)", selection: Binding(
          get: { blanks[step.id] != nil },
          set: { blanks[step.id] = $0 ? String((step.label.isEmpty ? "Value \(index + 1)" : step.label).prefix(40)) : nil })
        ) {
          Text("Same every time").tag(false)
          Text("Ask each time").tag(true)
        }.pickerStyle(.segmented).labelsHidden().frame(width: UIStyle.wide(260))
        if let blank = blanks[step.id] {
          TextField("Name of this value", text: Binding(get: { blank }, set: { blanks[step.id] = $0 }))
            .textFieldStyle(.roundedBorder).frame(width: UIStyle.wide(260))
            .accessibilityLabel("Name of the value asked in step \(index + 1)")
        }
      }
    }
  }
}

/// Settings › Assistants › Recipes and shortcuts: rename, view steps, run and delete.
struct RecipeSettings: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject private var book = RecipeBook.shared
  @State private var open: Set<String> = []
  @State private var names: [String: String] = [:]
  @State private var error: String?
  @Environment(\.palette) var p
  var body: some View {
    SettingsGroup("Recipes") {
      if book.recipes.isEmpty {
        Text("No recipes yet. On a page, choose ⋯ › Show Serein How…, do the task once, then save it.").role(.meta)
      } else {
        ForEach(book.recipes) { recipe in row(recipe) }
      }
      if let error { Text(error).role(.meta).foregroundStyle(p.danger) }
      SettingsNote("Recipes stay on this Mac. Serein runs one only when you ask, in its own tabs, after you say yes, and asks before every send, submit, payment or deletion on every run.")
    }
  }

  private func row(_ recipe: Recipe) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        TextField("Recipe name", text: Binding(get: { names[recipe.id] ?? recipe.name }, set: { names[recipe.id] = $0 }))
          .textFieldStyle(.roundedBorder).frame(width: UIStyle.wide(200))
          .accessibilityLabel("Name of the recipe \(recipe.name)")
          .onSubmit { rename(recipe) }
        Text("\(recipe.steps.count) step\(recipe.steps.count == 1 ? "" : "s") · \(recipe.host)").role(.meta).lineLimit(1)
        Spacer()
        Button(open.contains(recipe.id) ? "Hide Steps" : "Steps") {
          if open.contains(recipe.id) { open.remove(recipe.id) } else { open.insert(recipe.id) }
        }.controlSize(.small).accessibilityLabel((open.contains(recipe.id) ? "Hide steps of " : "Show steps of ") + recipe.name)
        Button("Run") { run(recipe) }.controlSize(.small).accessibilityLabel("Run " + recipe.name)
        Button("Delete") { delete(recipe) }.controlSize(.small).accessibilityLabel("Delete " + recipe.name)
      }
      if open.contains(recipe.id) {
        ForEach(Array(recipe.steps.enumerated()), id: \.element.id) { index, step in
          Text("\(index + 1). \(step.words)").role(.meta).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  @MainActor private func rename(_ recipe: Recipe) {
    guard let name = names[recipe.id], name != recipe.name else { return }
    do {
      try book.rename(recipe, to: name)
      names[recipe.id] = nil
      error = nil
    } catch { self.error = error.localizedDescription }
  }

  /// The same run as asking Serein for it: blanks in the panel's form, then the start card.
  @MainActor private func run(_ recipe: Recipe) {
    error = nil
    SereinRouter.show()
    Task { @MainActor in
      do { _ = try await relay.tools.runRecipe(recipe, values: [:]) } catch { self.error = error.localizedDescription }
    }
  }

  @MainActor private func delete(_ recipe: Recipe) {
    let alert = NSAlert()
    alert.messageText = "Delete the recipe “\(recipe.name)”?"
    alert.informativeText = "Its file is removed from this Mac."
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.cancelByDefault()
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do { try book.delete(recipe) } catch { self.error = error.localizedDescription }
  }
}
