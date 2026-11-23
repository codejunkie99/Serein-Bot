import AppKit
import SereinCore
import SwiftUI

/// The person's prompt shortcuts, in the Library's `shortcuts.json` (0600). Nothing here is an
/// agent tool or in a prompt: only the person saves one, from a sent message or in Settings.
/// Expanding one only fills a draft; sending it is an ordinary message, gated as usual.
@MainActor final class ShortcutBook: ObservableObject {
  static let shared = ShortcutBook()
  @Published private(set) var shortcuts: [PromptShortcut] = []
  private var library: Library?

  /// At launch.
  func attach(_ library: Library) {
    self.library = library
    let url = library.root.appendingPathComponent(PromptShortcuts.path)
    let loaded = library.load([PromptShortcut].self, from: PromptShortcuts.path)
    // An unreadable file (a hand-edit typo) is moved aside so the next save cannot overwrite it.
    if loaded == nil, FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.moveItem(at: url, to: library.root.appendingPathComponent("shortcuts.unreadable.json"))
    }
    shortcuts = PromptShortcuts.sanitized(loaded ?? [])
  }

  func named(_ name: String) -> PromptShortcut? { shortcuts.first { $0.name == name } }

  /// Saves a new shortcut, or a change to the one `replacing` names. New words that schedule,
  /// remind or watch ask on Serein's card first; anything but Allow saves nothing.
  @discardableResult
  func save(name: String, text: String, replacing id: String? = nil) async throws -> PromptShortcut {
    guard library != nil else { throw SereinError.invalid("Shortcuts are unavailable.") }
    let name = PromptShortcuts.normalized(name)
    if let problem = PromptShortcuts.problem(name: name, text: text, among: shortcuts, replacing: id) {
      throw SereinError.invalid(problem)
    }
    let old = id.flatMap { id in shortcuts.first { $0.id == id } }
    if id != nil && old == nil { throw SereinError.invalid("This shortcut was deleted.") }
    if old?.text != text, PromptShortcuts.startsStandingWork(text) { try await allow(name: name, text: text) }
    // The list may have changed while the card waited.
    guard let library, id == nil || shortcuts.contains(where: { $0.id == id }) else {
      throw SereinError.invalid("This shortcut was deleted.")
    }
    if let problem = PromptShortcuts.problem(name: name, text: text, among: shortcuts, replacing: id) {
      throw SereinError.invalid(problem)
    }
    let saved = PromptShortcut(id: old?.id ?? UUID().uuidString, name: name, text: text, created: old?.created ?? Date())
    let list = (shortcuts.filter { $0.id != saved.id } + [saved]).sorted { $0.name < $1.name }
    try library.save(list, to: PromptShortcuts.path)
    shortcuts = list
    return saved
  }

  func delete(_ shortcut: PromptShortcut) throws {
    guard let library else { return }
    let list = shortcuts.filter { $0.id != shortcut.id }
    try library.save(list, to: PromptShortcuts.path)
    shortcuts = list
  }

  /// The same gate as a settings change (ApprovalDoor.answer, `.setting`): a shortcut that sets up
  /// later or repeating work is `.change`, which always asks.
  private func allow(name: String, text: String) async throws {
    let relay = RelayOrchestrator.shared
    let decision = try ApprovalDoor.answer(
      .init(.setting(tool: "shortcut_save"), RelayOrchestrator.standing(relay, present: true)),
      facts: .init(
        secureField: false, botCheck: false, pays: .no, covered: false, path: nil, hostKeyChanged: nil,
        runsAnything: false, ref: "")
    ).decision()
    if decision == .auto { return }
    guard let relay else {
      throw SereinError.invalid("Not saved. Words that schedule or watch need Serein turned on to ask you first.")
    }
    let effect = ApprovalGate.settingsEffect(tool: "shortcut_save")
    let human = await relay.confirmAnswer(
      "Save the shortcut /\(name)?",
      ApprovalGate.askLine(effect) + " Its words ask Serein to schedule, remind or watch something. Saving starts nothing; it runs only when you send it.",
      button: "Save", thread: relay.threadID, more: text, moreName: "the shortcut")
    guard human == .yes else {
      throw SereinError.invalid(human == .no ? "Not saved. You declined the shortcut." : "Not saved. The card was not answered.")
    }
  }

  /// Save as Shortcut on a sent message: the person names it (its first words are offered).
  static func offer(_ text: String) {
    let field = NSTextField(string: PromptShortcuts.suggestedName(text))
    field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
    field.setAccessibilityLabel("Shortcut name")
    let alert = NSAlert()
    alert.messageText = "Save as a shortcut"
    alert.informativeText = "Type / and this name in a composer to put the message in your draft. Nothing is sent until you send it."
    alert.accessoryView = field
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let name = field.stringValue
    Task { @MainActor in
      do {
        let saved = try await shared.save(name: name, text: text)
        ToastCenter.shared.show("Saved the shortcut /\(saved.name)")
      } catch { ToastCenter.shared.show(error.localizedDescription) }
    }
  }
}

/// Next to Copy on a message you sent. Holds no closure, so the message row stays Equatable.
struct MessageShortcutButton: View {
  let text: String
  var isVisible = true
  var body: some View {
    Button { ShortcutBook.offer(text) } label: {
      InterfaceIcon(systemName: "plus", size: 14).frame(width: 18, height: 18)
    }.buttonStyle(QuietButton())
      .help("Save as shortcut")
      .accessibilityLabel("Save message as shortcut")
      .opacity(isVisible ? 1 : 0)
      .allowsHitTesting(isVisible)
      .accessibilityHidden(!isVisible)
  }
}

/// Settings › Assistants › Recipes and shortcuts: rename, change the words, delete.
struct ShortcutSettings: View {
  @ObservedObject private var book = ShortcutBook.shared
  @State private var names: [String: String] = [:]
  @State private var texts: [String: String] = [:]
  @State private var saving: Set<String> = []
  @State private var error: String?
  @Environment(\.palette) var p
  var body: some View {
    SettingsGroup("Prompt shortcuts") {
      if book.shortcuts.isEmpty {
        Text("No shortcuts yet. Point at a message you sent and choose Save as shortcut.").role(.meta)
      } else {
        ForEach(book.shortcuts) { shortcut in row(shortcut) }
      }
      if let error { Text(error).role(.meta).foregroundStyle(p.danger) }
      SettingsNote("Type / and a shortcut’s name to put its words in your draft. Nothing is sent until you send it. Saving words that schedule, remind or watch asks you first.")
    }
  }

  private func row(_ shortcut: PromptShortcut) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        TextField("Shortcut name", text: Binding(get: { names[shortcut.id] ?? shortcut.name }, set: { names[shortcut.id] = $0 }))
          .textFieldStyle(.serein).frame(width: UIStyle.wide(200))
          .accessibilityLabel("Name of the shortcut /\(shortcut.name)")
          .onSubmit { save(shortcut) }
        Spacer()
        Button("Revert") { names[shortcut.id] = nil; texts[shortcut.id] = nil }.controlSize(.small)
          .disabled(!changed(shortcut))
          .accessibilityLabel("Revert /\(shortcut.name) to its saved name and words")
        Button("Save") { save(shortcut) }.controlSize(.small)
          .disabled(!changed(shortcut) || saving.contains(shortcut.id))
          .accessibilityLabel("Save changes to /\(shortcut.name)")
        Button("Delete") { delete(shortcut) }.controlSize(.small)
          .accessibilityLabel("Delete /\(shortcut.name)")
      }
      TextField("Words", text: Binding(get: { texts[shortcut.id] ?? shortcut.text }, set: { texts[shortcut.id] = $0 }), axis: .vertical)
        .textFieldStyle(.serein).lineLimit(2...6)
        .accessibilityLabel("Words of the shortcut /\(shortcut.name)")
    }
  }

  private func changed(_ shortcut: PromptShortcut) -> Bool {
    (names[shortcut.id].map { $0 != shortcut.name } ?? false) || (texts[shortcut.id].map { $0 != shortcut.text } ?? false)
  }

  @MainActor private func save(_ shortcut: PromptShortcut) {
    guard changed(shortcut), !saving.contains(shortcut.id) else { return }
    let name = names[shortcut.id] ?? shortcut.name, text = texts[shortcut.id] ?? shortcut.text
    saving.insert(shortcut.id)
    Task { @MainActor in
      defer { saving.remove(shortcut.id) }
      do {
        try await book.save(name: name, text: text, replacing: shortcut.id)
        names[shortcut.id] = nil
        texts[shortcut.id] = nil
        error = nil
      } catch { self.error = error.localizedDescription }
    }
  }

  @MainActor private func delete(_ shortcut: PromptShortcut) {
    let alert = NSAlert()
    alert.messageText = "Delete the shortcut /\(shortcut.name)?"
    alert.informativeText = "Its words are removed from this Mac."
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.cancelByDefault()
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
      try book.delete(shortcut)
      names[shortcut.id] = nil
      texts[shortcut.id] = nil
    } catch { self.error = error.localizedDescription }
  }
}
