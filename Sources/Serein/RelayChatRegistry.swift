import Foundation
import SereinCore

/// The hidden chat registry's shell (SereinCore/ChatRegistry.swift, TEAMS-V2 item 7). When a run
/// ends it indexes what each chat gained past its watermark, off the main actor, and rewrites
/// `REGISTRY.md` only when something changed. When a turn starts a cold session on a provider
/// that did not read the thread last, that turn gets a slice. The person does nothing and sees
/// no card; the files stay in the private relay store.
@MainActor final class RelayChatRegistry {
  static let shared = RelayChatRegistry()

  private var store: OffMain<ChatRegistryStore>?
  private var folder: URL?
  private var opening = false
  private var loaded = false
  private var passing = false
  private var again = false
  private weak var model: AgentModel?
  /// Each chat's stored row (its watermark), what the slice reads, and each thread's last reader.
  private var rows: [String: ChatRegistry.Row] = [:]
  private var digests: [ChatRegistry.Digest] = []
  private var readers: [String: String] = [:]

  /// Indexes the chats that changed since their watermark. One pass at a time; a call during a
  /// pass runs one more after it. Only the main actor's copy of the changed chats is made here.
  func refresh(_ model: AgentModel) {
    self.model = model
    guard let browser = model.browser else { return }
    open(browser.library.root)
    guard loaded, !passing, let store, let folder else {
      again = true
      return
    }
    let running = Set(model.hub.runs.filter(\.isActive).map(\.spec.threadID))
    var chats: [ChatRegistry.Chat] = []
    for conversation in model.conversations {
      var messages = conversation.messages
      // A running chat's last reply is still streaming: it is indexed when the run ends.
      if running.contains(conversation.id), messages.last?.role == "assistant" { messages.removeLast() }
      let mark = rows[conversation.id]?.mark
      if mark == nil ? messages.isEmpty : mark?.count == messages.count && mark?.lastID == messages.last?.id { continue }
      chats.append(ChatRegistry.Chat(
        id: conversation.id, title: conversation.title, provider: conversation.provider.rawValue,
        project: conversation.projectID.flatMap { id in browser.projects.first { $0.id == id }?.name },
        personal: conversation.readPersonal == true,
        messages: messages.map {
          ChatRegistry.Message(id: $0.id, role: $0.role, text: $0.text, at: $0.sentAt ?? conversation.updatedAt, tools: $0.activities ?? [])
        }))
    }
    // An empty list is a library not read yet, never "every chat was deleted".
    let keep: Set<String>? = model.conversations.isEmpty ? nil : Set(model.conversations.map(\.id))
    let gone = keep.map { !Set(rows.keys).subtracting($0).isEmpty } ?? false
    guard !chats.isEmpty || gone else { return }
    passing = true
    let stored = rows
    let relay = RelayOrchestrator.shared
    let memory = relay?.memory
    let reader = relay.map { $0.memoryReader($0.team.mainProfileID ?? RelayTeam.mainID) }
    Task { [weak self] in
      // The memory rules saved in each chat are its preferences too.
      var rules: [String: [String]] = [:]
      if let memory, let reader, let found = try? await memory.run({ try $0.rules(reader: reader) }) {
        for record in found { if let chat = record.chat { rules[chat, default: []].append(record.text) } }
      }
      let saved = rules
      let written = try? await store.run { store -> [ChatRegistry.Digest]? in
        let updates = chats.compactMap { chat -> ChatRegistry.Update? in
          var chat = chat
          chat.rules = saved[chat.id] ?? []
          return ChatRegistry.update(chat, row: stored[chat.id])
        }
        guard try store.apply(updates, keep: keep) else { return nil }
        let all = try store.digests()
        let file = folder.appendingPathComponent(ChatRegistry.markdownFile)
        try Data(ChatRegistry.markdown(all).utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return all
      }
      self?.finished(written ?? nil)
    }
  }

  /// The slice for a turn being built, or nil. It reads only what is in memory, so the turn never
  /// waits; the reader it records is written in the background.
  func handoff(_ model: AgentModel, thread: String, provider: String, project: String?, personal: Bool,
               query: String, cold: Bool) -> String? {
    guard loaded else {
      refresh(model)
      return nil
    }
    let last = readers[thread]
    let gives = ChatRegistry.hands(cold: cold, provider: provider, lastReader: last, seen: Set(readers.values))
    if last != provider {
      readers[thread] = provider
      store?.post { try $0.noteReader(thread: thread, provider: provider) }
    }
    guard gives else { return nil }
    refresh(model)
    return ChatRegistry.slice(for: thread, project: project, personal: personal, query: query, digests: digests)
  }

  private func open(_ root: URL) {
    guard store == nil, !opening else { return }
    opening = true
    let folder = root.appendingPathComponent(ChatRegistry.folder, isDirectory: true)
    let url = folder.appendingPathComponent(ChatRegistry.database)
    Task.detached { [weak self] in
      let opened = try? ChatRegistryStore(url: url)
      let state = try? opened.map { (try $0.digests(), try $0.readers()) }
      await self?.opened(opened, folder: folder, state: state ?? nil)
    }
  }

  private func opened(_ opened: ChatRegistryStore?, folder: URL, state: ([ChatRegistry.Digest], [String: String])?) {
    guard let opened, let state else { return }
    store = OffMain(opened, label: "serein.relay.registry")
    self.folder = folder
    adopt(state.0)
    readers = state.1
    loaded = true
    if again, let model { again = false; refresh(model) }
  }

  private func finished(_ written: [ChatRegistry.Digest]?) {
    passing = false
    if let written { adopt(written) }
    if again, let model { again = false; refresh(model) }
  }

  private func adopt(_ all: [ChatRegistry.Digest]) {
    digests = all
    rows = Dictionary(all.map { ($0.row.thread, $0.row) }, uniquingKeysWith: { _, last in last })
  }
}
