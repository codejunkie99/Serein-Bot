import Foundation
import SereinCore

/// One SQLite store used only off the main thread: every call runs on the store's own serial
/// queue, in the order Serein asked, and the answer comes back to the caller. The memory store
/// and the work ledger are each opened once and kept in one of these.
final class OffMain<Store: Sendable>: @unchecked Sendable {
  let store: Store
  private let queue: DispatchQueue

  init(_ store: Store, label: String) {
    self.store = store
    queue = DispatchQueue(label: label, qos: .utility)
  }

  /// Runs `body` on the store's queue and returns what it returns.
  func run<T>(_ body: @escaping @Sendable (Store) throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
      queue.async {
        do {
          continuation.resume(returning: try body(self.store))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// Runs `body` on the store's queue when nothing waits for the answer; the order still holds.
  func post(_ body: @escaping @Sendable (Store) throws -> Void) {
    queue.async { try? body(self.store) }
  }
}

/// What the memory shell keeps between launches (relay/memory/shell.json, 0600): the move of the
/// old notes and whether the person was told, the old files and when they moved, and each chat's
/// last capture. Every field is optional, so a file from an older build decodes.
struct MemoryShellState: Codable, Equatable {
  /// How many old notes moved into the store, and whether the person was told (once).
  var moved: Int?
  var told: Bool?
  /// Each notes.v1.json the move left, with when it moved: deleted after `keepOld`.
  var oldFiles: [String: Date]?
  /// Each chat's last message a capture read (`RelayLearning.isDue`).
  var distilled: [String: String]?
  /// When the recent captures started (`RelayLearning.mayCapture`).
  var captures: [Date]?

  static let path = "relay/memory/shell.json"
  /// The old notes file stays this long after the move (SYNTHESIS Q5).
  static let keepOld: TimeInterval = 60 * 86_400
}

/// Serein's shared memory in the app (memory unit 11 and the shell part of 6b): one store,
/// opened once off the main thread; the old notes moved in; the memory tools; the per-turn memory
/// block; learned proposals; the notes list Settings shows; receipts and their Undo.
extension RelayOrchestrator {
  static let memoryClosed = "My memory is not open, so I keep nothing new now."
  static let outsideStays =
    "That came from outside content, so it stays with this assistant. Say it in your own words in a new message to share it."
  /// `UndoToken.entry` for memory: this, then the store's log entries, joined by ",".
  static let memoryUndoPrefix = "memory:"
  /// `UndoToken.entry` for a schedule: this, then the `RelayScheduleChange` id.
  static let scheduleUndoPrefix = "schedule:"
  /// Tools that bring no outside text into a turn: memory, its own reminders, notify, the look and
  /// the person's own answers. A turn that used only these, with no page or file on the person's
  /// message, is clean (`MemoryTurn.isClean`), so a typed remember is shared with every assistant.
  static let cleanTools: Set<String> = [
    "remember", "recall", "forget", "memory_share", "reminder_create", "reminder_cancel", "notify",
    "look_get", "look_set", "look_undo", "look_show", "ask_user",
  ]

  // MARK: opening and the move of the old notes

  /// Opens the store once, off the main thread, then moves the old notes in and reads the notes
  /// Settings lists. UI previews open no store.
  func openMemory() {
    guard !RunMode.previewing else { return }
    let url = browser.library.root.appendingPathComponent(MemoryStore.relativePath)
    memoryOpening = Task { [weak self] in
      let opened: MemoryStore? = await Task.detached(priority: .utility) { () -> MemoryStore? in
        try? MemoryStore(url: url)
      }.value
      guard let self else { return }
      guard let opened else {
        self.note("I could not open my memory, so I keep nothing new until I can.", .auto)
        return
      }
      self.memory = OffMain(opened, label: "serein.relay.memory")
      // Checks and previews never move a library's files.
      if Self.persists { await self.moveOldNotes() }
      await self.refreshNotes()
    }
  }

  /// The store, once open: a call while it opens waits for it. nil when it could not open.
  func memoryStore() async -> OffMain<MemoryStore>? {
    if let memory { return memory }
    await memoryOpening?.value
    return memory
  }

  /// The reader for `profileID`: the teams it is in; Serein, the main assistant, reads every team.
  func memoryReader(_ profileID: String) -> MemoryReader {
    let teams = Set(team.groups(of: profileID).map(\.id))
    // No record this build writes names an app (`MemoryProvenance.app`); the unit that does
    // passes the apps the assistant holds now, so a removed app silences its records.
    return MemoryReader(assistant: profileID, teams: teams, apps: [], isMain: profileID == team.mainProfileID)
  }

  /// Each assistant's name by id, for record labels.
  var memoryNames: [String: String] {
    Dictionary(team.profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
  }

  /// Moves each assistant's notes.json into the store (`MemoryMigration`), once: a repeat adds
  /// nothing. A file moves to notes.v1.json only after every planned row is in the store, and it
  /// is deleted 60 days later. A file that does not decode is left alone (`readState` says so
  /// once). The person is told once how many notes moved (`tellMemoryMoved`).
  func moveOldNotes() async {
    guard let memory else { return }
    var byProfile: [String: [RelayNote]] = [:]
    var files: [String: String] = [:]
    for profile in team.profiles {
      let path = team.folder(profile.id) + "/notes.json"
      guard let list = readState([RelayNote].self, path) else { continue }
      byProfile[profile.id] = list
      files[profile.id] = path
    }
    guard !files.isEmpty else {
      sweepOldNotes()
      return
    }
    let planned = MemoryMigration.plan(byProfile)
    let ids = planned.map(\.id)
    let present: Set<String>? = try? await memory.run { (store: MemoryStore) -> Set<String> in
      _ = try store.migrate(planned)
      return try store.present(ids: ids)
    }
    guard let present else { return }
    var shell = memoryShell
    var old = shell.oldFiles ?? [:]
    var moved = 0
    for (profile, path) in files {
      let mine = planned.filter { $0.owner == profile }
      guard MemoryMigration.isComplete(mine, present: present), let kept = keepOldNotes(path) else { continue }
      old[kept] = Date()
      moved += mine.count
    }
    shell.oldFiles = old
    if moved > 0 {
      shell.moved = (shell.moved ?? 0) + moved
      shell.told = false
    }
    memoryShell = shell
    persist(shell, MemoryShellState.path)
    sweepOldNotes()
    tellMemoryMoved()
  }

  /// Renames `…/notes.json` to `…/notes.v1.json` (a free name when that one is taken). The new
  /// path, or nil when it could not move.
  private func keepOldNotes(_ path: String) -> String? {
    let files = FileManager.default
    let root = browser.library.root
    let folder = String(path.dropLast("notes.json".count))
    var target = folder + "notes.v1.json"
    if files.fileExists(atPath: root.appendingPathComponent(target).path) {
      target = folder + "notes.v1-\(Int(Date().timeIntervalSince1970)).json"
    }
    do {
      try files.moveItem(at: root.appendingPathComponent(path), to: root.appendingPathComponent(target))
    } catch {
      return nil
    }
    return target
  }

  /// Deletes each old notes file whose 60 days are over.
  private func sweepOldNotes(now: Date = Date()) {
    guard let old = memoryShell.oldFiles, !old.isEmpty else { return }
    let due = old.filter { now.timeIntervalSince($0.value) >= MemoryShellState.keepOld }
    guard !due.isEmpty else { return }
    for path in due.keys { try? FileManager.default.removeItem(at: browser.library.root.appendingPathComponent(path)) }
    var shell = memoryShell
    shell.oldFiles = old.filter { due[$0.key] == nil }
    memoryShell = shell
    persist(shell, MemoryShellState.path)
  }

  /// Says once, in the chat on screen, how many notes moved and that they stay private. The
  /// clock tries again while the chat works or has no saved messages yet.
  func tellMemoryMoved() {
    guard memoryShell.told == false, let moved = memoryShell.moved, moved > 0 else { return }
    let words = moved == 1
      ? "I moved 1 note into my memory. It stays private. Say “share my notes with everyone” to open it."
      : "I moved \(moved) notes into my memory. They stay private. Say “share my notes with everyone” to open them."
    guard agent.postNotice(words, into: threadID) == true else { return }
    var shell = memoryShell
    shell.told = true
    memoryShell = shell
    persist(shell, MemoryShellState.path)
  }

  // MARK: the notes Settings lists

  /// The active assistant's notes as Settings lists them (newest last) and its learned proposals
  /// beside the tidy ones, read again from the store, and each assistant's count of its own notes
  /// (`noteCount`). `actor`: who made the change that called this, so the journal records what
  /// changed in the list. Before the lists are read, each assistant's notes past an end date or
  /// over a cap leave for the archive (`MemoryStore.archive`), and its journal says so.
  func refreshNotes(journal actor: String? = nil) async {
    guard let memory = await memoryStore() else { return }
    let profileID = team.activeID
    let reader = memoryReader(profileID)
    let readers: [MemoryReader] = team.profiles.map { memoryReader($0.id) }
    let read = try? await memory.run {
      (store: MemoryStore) -> (
        records: [MemoryRecord], waiting: [MemoryRecord], counts: [String: Int], moved: [String: [MemoryFill.Move]]
      ) in
      var moved: [String: [MemoryFill.Move]] = [:]
      for one in readers {
        let moves = try store.archive(owner: one.assistant)
        if !moves.isEmpty { moved[one.assistant] = moves }
      }
      // The person's own list in Settings and a count: no model reads them, so no chat needs a mark.
      let records = try store.search("", reader: reader, limit: MemoryStore.recallLimit).reveal { true }
      let waiting = try store.proposals(owner: profileID)
      var counts: [String: Int] = [:]
      for one in readers {
        let own = try store.search("", reader: one, limit: MemoryStore.recallLimit).reveal { true }
        counts[one.assistant] = own.filter { $0.owner == one.assistant }.count
      }
      return (records: records, waiting: waiting, counts: counts, moved: moved)
    }
    guard let read else { return }
    memoryCounts = read.counts
    for (owner, moves) in read.moved { journalArchived(moves, owner: owner) }
    guard team.activeID == profileID else { return }
    for record in read.records + read.waiting { noteMarks[record.id] = record.personal }
    // What left for the archive has its own journal line above: it is not `actor`'s change.
    let archived: Set<String> = Set(read.moved.values.flatMap { $0.map(\.record.id) })
    let before = notes.filter { !archived.contains($0.id) }
    let next: [RelayNote] = read.records.reversed().map { Self.relayNote($0) }
    notes = next
    proposals = read.waiting.reversed().map { Self.relayNote($0) } + tidyProposals
    guard let actor else { return }
    let entries = RelayJournal.entries(actor: actor, before: before, after: next)
    guard !entries.isEmpty else { return }
    journal = RelayJournal.trimmed(journal + entries)
    persist(journal, dir + "/journal.json")
  }

  /// Records the notes of `owner` that left for the archive in that assistant's own journal, each
  /// with its words, so Undo on the line brings the note back (`applyToMemory`). Another
  /// assistant's journal is on disk only; it is read, added to and saved.
  private func journalArchived(_ moves: [MemoryFill.Move], owner: String) {
    let entries: [RelayJournalEntry] = moves.map { move in
      RelayJournalEntry(
        actor: move.reason == .ended ? MemoryJournal.endedActor : MemoryJournal.fullActor, action: .removed,
        noteID: move.record.id, text: "", priorText: move.record.text, priorQuote: move.record.quote)
    }
    if owner == team.activeID {
      journal = RelayJournal.trimmed(journal + entries)
      persist(journal, dir + "/journal.json")
      return
    }
    let path = team.folder(owner) + "/journal.json"
    let kept: [RelayJournalEntry] = readState([RelayJournalEntry].self, path) ?? []
    persist(RelayJournal.trimmed(kept + entries), path)
  }

  static func relayNote(_ record: MemoryRecord) -> RelayNote {
    RelayNote(id: record.id, text: record.text, quote: record.quote, createdAt: record.createdAt, expires: record.expires)
  }

  /// What a change to the Settings list (`updateNotes`) does in the store, off the main thread,
  /// then the list is read again: a note that left is forgotten (its digest stays, so learning
  /// never proposes it again), a note with new words is edited, and a new note (one Undo puts
  /// back, or a kept tidy merge) is the person's own, private to the active assistant. A new note
  /// keeps the personal-read mark of the note it was; when that is not known, it is marked.
  func applyToMemory(before: [RelayNote], after: [RelayNote]) {
    let owner = team.activeID
    let old = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let new = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let gone: [String] = before.map(\.id).filter { new[$0] == nil }
    var edits: [(id: String, text: String)] = []
    var added: [MemoryRecord] = []
    for note in after {
      if let was = old[note.id] {
        if was.text != note.text { edits.append((id: note.id, text: note.text)) }
        continue
      }
      let record = MemoryRecord(
        id: note.id, kind: .note, text: note.text, quote: note.quote, owner: owner, scope: .assistant(owner),
        provenance: MemoryProvenance(source: .person), createdAt: note.createdAt, expires: note.expires,
        review: .confirmed, personal: noteMarks[note.id] ?? true)
      added.append(record)
    }
    guard !gone.isEmpty || !edits.isEmpty || !added.isEmpty else { return }
    let forgets = gone
    let changes = edits
    let inserts = added
    Task { [weak self] in
      guard let memory = await self?.memoryStore() else { return }
      _ = try? await memory.run { (store: MemoryStore) -> Void in
        for id in forgets { _ = try store.forget(id: id) }
        for change in changes {
          guard let current = try store.record(id: change.id) else { continue }
          _ = try store.update(id: change.id, expected: current.updatedAt, edit: MemoryEdit(text: change.text))
        }
        for record in inserts {
          // Undo of a note that left for the archive: its id is still taken there, so the same
          // record comes back out instead of a copy going in.
          if case .conflict = try store.insert(record) { _ = try store.unarchive(id: record.id) }
        }
      }
      await self?.refreshNotes()
    }
  }

  // MARK: learning

  /// What `owner` keeps and waits on, for one capture: every text (to leave out repeats), the
  /// texts without the personal-read mark (the only ones the request may quote), and how many
  /// proposals wait.
  func memoryTexts(owner: String) async -> (all: [String], unmarked: [String], waiting: Int) {
    guard let memory = await memoryStore() else { return (all: [], unmarked: [], waiting: 0) }
    let reader = memoryReader(owner)
    let read = try? await memory.run { (store: MemoryStore) -> (notes: [MemoryRecord], waiting: [MemoryRecord]) in
      // Only texts for the host's own repeat check and the request below; personal ones are
      // filtered out before the request.
      let notes = try store.search("", reader: reader, limit: MemoryStore.recallLimit).reveal { true }
      let waiting = try store.proposals(owner: owner)
      return (notes: notes, waiting: waiting)
    }
    guard let read else { return (all: [], unmarked: [], waiting: 0) }
    let every = read.notes + read.waiting
    return (all: every.map(\.text), unmarked: every.filter { !$0.personal }.map(\.text), waiting: read.waiting.count)
  }

  /// Saves learned proposals; one that matches a tombstone is refused there. Returns how many
  /// were saved.
  func addProposals(_ records: [MemoryRecord]) async -> Int {
    guard let memory = await memoryStore() else { return 0 }
    let fresh = records
    let added: Int? = try? await memory.run { (store: MemoryStore) -> Int in
      var count = 0
      for record in fresh {
        if case .done = try store.insert(record) { count += 1 }
      }
      return count
    }
    await refreshNotes()
    return added ?? 0
  }

  /// The person kept (`keep`) or declined a learned proposal. A kept one is confirmed and stays
  /// private to its assistant; a declined one leaves a digest, so it is never proposed again.
  @discardableResult
  func reviewProposal(_ id: String, keep: Bool) async -> Bool {
    guard let memory = await memoryStore() else { return false }
    let write: MemoryWrite? = try? await memory.run { (store: MemoryStore) -> MemoryWrite in
      guard let record = try store.record(id: id), record.review == .unreviewed else { return .missing }
      if keep { return try store.update(id: id, expected: record.updatedAt, edit: MemoryEdit(review: .confirmed)) }
      return try store.forget(id: id, reason: .declined)
    }
    await refreshNotes(journal: keep ? "learning" : nil)
    guard let write, case .done = write else { return false }
    return true
  }

  /// A deleted chat: every learned record made in it is forgotten, with a `sourceDeleted` digest
  /// (SPEC 4.9). What the person said stays.
  func forgetChatMemory(_ chat: String) {
    Task { [weak self] in
      guard let memory = await self?.memoryStore() else { return }
      let gone: Int? = try? await memory.run { (store: MemoryStore) -> Int in try store.forgetLearned(chat: chat) }
      guard let gone, gone > 0 else { return }
      await self?.refreshNotes()
    }
  }

  // MARK: the turn

  /// What the turn is told when the person's message opened the journal, so the reply points at
  /// it instead of reciting the notes.
  static let journalShown =
    "The person asked to see what you remember. Their memory journal is open in its own window now, with every change and Undo. Mention that in one short sentence, then answer as usual."

  /// The memory block of one turn, for `RelayPrompt.volatile` (`turnMemory`). A message of the
  /// person's that asks to see what is remembered (`MemoryTools.asksToSeeMemory`) opens the
  /// journal first: the chat's way in, with no trip through Settings.
  func prepareMemory(request: String, thread: String, profileID: String) async {
    turnMemory = nil
    let shown: Bool = !RunMode.automated && profileID == team.activeID && MemoryTools.asksToSeeMemory(typedWords)
    if shown { MemoryJournalWindow.show(self) }
    guard let block = await memoryBlock(request: request, thread: thread, profileID: profileID) else {
      if shown { turnMemory = Self.journalShown }
      return
    }
    // A note from outside content makes this turn outside too, as `recall` does, so a note the
    // person saves from it stays private (`MemoryTools.carriesOutside`).
    if block.outside { turnReadOutside = true }
    turnMemory = shown ? block.text + "\n" + Self.journalShown : block.text
  }

  /// One memory block, by SPEC 4.7: what `profileID` may recall for `request`, then, with few
  /// matches, its newest shared notes; at most `MemoryPrompt.maxRecords`, each fenced as data
  /// (`MemoryPrompt.renderKept`). Records with the personal-read mark go in only when `thread` is
  /// marked already; otherwise one line counts them, and `recall` reads them after marking the
  /// chat. The host counts each record it put in (`markRendered`). A light ask's prompt uses it
  /// too (RelayAsks.swift).
  func renderedMemory(request: String, thread: String, profileID: String) async -> String? {
    await memoryBlock(request: request, thread: thread, profileID: profileID)?.text
  }
  /// The memory block's text, and whether a record that went into it came from outside content.
  private func memoryBlock(request: String, thread: String, profileID: String) async -> (text: String, outside: Bool)? {
    guard let memory = await memoryStore() else { return nil }
    let reader = memoryReader(profileID)
    let found = try? await memory.run { (store: MemoryStore) -> (topical: [MemoryRecord], newest: [MemoryRecord]) in
      // The lists whole; `MemoryHits` below decides what the prompt may hold.
      let topical = try store.search(request, reader: reader, limit: MemoryPrompt.maxRecords).reveal { true }
      let newest = try store.search("", reader: reader, limit: MemoryStore.recallLimit).reveal { true }
      return (topical: topical, newest: newest)
    }
    guard let found else { return nil }
    let hits = MemoryHits(MemoryTools.forTurn(topical: found.topical, newest: found.newest))
    let marked = agent.readsPersonal(thread: thread)
    let shown: [MemoryRecord] = marked ? hits.reveal { true } : hits.unmarked
    let sealed = marked ? 0 : hits.sealedCount
    guard let block = MemoryPrompt.renderKept(shown, names: memoryNames, sealed: sealed) else { return nil }
    let ids = block.ids
    memory.post { store in try store.markRendered(ids) }
    let went: Set<String> = Set(ids)
    let rendered: [MemoryRecord] = shown.filter { went.contains($0.id) }
    return (text: block.text, outside: MemoryTools.carriesOutside(rendered))
  }

  /// Shows `receipt` under the reply of the turn now running, with its Undo kept for the chat
  /// (`deliver`, RelayAssistantTools.swift: it lands on the reply when the turn ends).
  func noteReceipt(_ receipt: Receipt) {
    deliver(receipt: receipt, into: turnThread)
  }

  /// Serein's own turn called `name` (BrowserModel.perform): anything but `cleanTools` may bring
  /// outside text into the turn.
  func noteTurnTool(_ name: String) {
    if !Self.cleanTools.contains(name) { turnReadOutside = true }
    #if DEBUG
      toolsCalledForChecks.append(name)
    #endif
  }

  /// What the turn now running on `thread` has read, for a new record's defaults (`MemoryDefaults`):
  /// outside text (a tool beyond `cleanTools`, a step of the AI app's own, a page or a file on the
  /// message), and personal data (the chat's mark).
  func memoryTurn(thread: String) -> MemoryTurn {
    let steps = agent.hub.run(for: thread)?.steps.isEmpty == false
    return MemoryTurn(readOutside: turnReadOutside || steps, readPersonal: agent.readsPersonal(thread: thread))
  }

  /// Whether the chat behind a task chat read the person's data: the chat on screen (as before),
  /// or the chat that started it, which for a routine's task is its owner's chat.
  func parentChatMarked(_ thread: String) -> Bool {
    if agent.readsPersonal(thread: threadID) { return true }
    guard let chat = child(thread)?.chatID, chat != threadID else { return false }
    return agent.readsPersonal(thread: chat)
  }

  // MARK: the memory tools (RelayToolHost asks Admission first)

  /// What `remember` saves (SPEC 4.3). When the person's own words ask to keep it, a confirmed
  /// note (`MemoryDefaults.remembered`): every assistant's in a clean turn, else this one's, or the
  /// scope `wanted` names; with a receipt. Otherwise it is this assistant's own idea
  /// (`MemoryDefaults.learned`): private and unreviewed until the person keeps it, with no receipt.
  /// An equal note that is there already is not saved twice.
  func rememberFact(_ text: String, quote: String?, scope wanted: MemoryScope?, expires: Date?) async throws
    -> (record: MemoryRecord, receipt: Receipt?)
  {
    guard let memory = await memoryStore() else { throw SereinError.invalid(Self.memoryClosed) }
    if let why = SavedText.problem(text) { throw SereinError.invalid(why) }
    let owner = turnProfileID
    let chat = turnThread
    let facts = memoryTurn(thread: chat)
    let asked = MemoryTools.asksToRemember(typedWords)
    var record: MemoryRecord
    if asked {
      // What the person asked to keep carries their own words: the quote when they typed it,
      // else their message (`MemoryTools.verbatim`), never words the model made up.
      let said: String? = MemoryTools.verbatim(quote, said: typedWords)
      record = try MemoryDefaults.remembered(text, quote: said, by: owner, chat: chat, turn: facts, expires: expires)
      if let wanted, wanted != record.scope {
        if record.outside, wanted != .assistant(owner) { throw SereinError.invalid(Self.outsideStays) }
        record = try record.edited(MemoryEdit(scope: wanted))
      }
    } else {
      record = try MemoryDefaults.learned(
        text, quote: quote, by: owner, from: .assistant, reference: chat, personal: facts.readPersonal, expires: expires,
        chat: chat, outside: facts.readOutside)
    }
    let ready = record
    let reader = memoryReader(owner)
    let outcome = try await memory.run { (store: MemoryStore) -> (write: MemoryWrite, same: MemoryRecord?) in
      let key = MemoryTombstone.normalized(ready.text)
      let kept = try store.search(ready.text, reader: reader, limit: 10).reveal { true }
      let waiting = try store.proposals(owner: ready.owner)
      let same = (kept + waiting).first { MemoryTombstone.normalized($0.text) == key && $0.scope == ready.scope }
      if let same { return (write: MemoryWrite.missing, same: same) }
      let write = try store.insert(ready)
      return (write: write, same: nil)
    }
    if let same = outcome.same {
      guard asked else { return (record: same, receipt: nil) }
      var receipt = ReceiptCopy.remembered(same.text, sharedWithAll: same.scope == .person, entry: "")
      receipt.undo = nil
      noteReceipt(receipt)
      return (record: same, receipt: receipt)
    }
    guard case .done(let entry) = outcome.write else {
      throw SereinError.invalid(outcome.write.words ?? "I could not save that note.")
    }
    await refreshNotes(journal: "relay")
    guard asked else { return (record: ready, receipt: nil) }
    let receipt = ReceiptCopy.remembered(ready.text, sharedWithAll: ready.scope == .person, entry: Self.memoryUndoPrefix + entry)
    noteReceipt(receipt)
    return (record: ready, receipt: receipt)
  }

  /// What `recall` answers: the records the turn's assistant may read for `query`, best first, at
  /// most `limit` (SPEC 4.7). Records with the personal-read mark come back only after the chat is
  /// marked; when the mark cannot be saved they are withheld. In the person's turn it also names
  /// who else knows something (never the text) and, as a separate list, at most three of its
  /// proposals the person could keep (SPEC 4.6). Text from a learned record is marked untrusted.
  func recallFacts(_ query: String?, limit: Int) async throws -> [String: Any] {
    guard let memory = await memoryStore() else { throw SereinError.invalid(Self.memoryClosed) }
    let owner = turnProfileID
    let reader = memoryReader(owner)
    let words = query ?? ""
    let cap = min(max(limit, 1), MemoryStore.recallLimit)
    let person = startedByPerson
    let read = try await memory.run {
      (store: MemoryStore) -> (hits: MemoryHits, who: [String: Int], ideas: [MemoryRecord]) in
      let hits = try store.search(words, reader: reader, limit: cap)
      var who: [String: Int] = [:]
      var ideas: [MemoryRecord] = []
      if person {
        who = try store.whoKnows(words, reader: reader)
        ideas = try store.proposals(owner: owner, limit: 3)
      }
      return (hits: hits, who: who, ideas: ideas)
    }
    let chat = turnThread
    let records = read.hits.reveal { self.agent.markPersonalRead(thread: chat) }
    if MemoryTools.carriesOutside(records) { turnReadOutside = true }
    let names = memoryNames
    var out: [String: Any] = ["notes": records.map { Self.row($0, names: names, team: team) }, "total": records.count]
    if records.isEmpty, read.hits.needsMark { out["withheld"] = BrowserModel.personalMarkWithheld }
    if person {
      let who = MemoryTools.whoKnows(read.who, in: team)
      if !who.isEmpty { out["who"] = who.map { item -> [String: Any] in ["assistant": item.name, "notes": item.count] } }
      let marked = agent.readsPersonal(thread: chat)
      let ideas = read.ideas.filter { !$0.personal || marked }
      if !ideas.isEmpty {
        out["ideas"] = [
          "about": "Notes you could ask the person to keep. They are not used until the person says yes; then keep one with remember and keep set to its id.",
          "notes": ideas.map { ["id": $0.id, "text_untrusted": $0.text, "quote": $0.quote ?? ""] },
        ] as [String: Any]
      }
    }
    let shown = records.map(\.id)
    memory.post { store in try store.markRendered(shown) }
    return out
  }

  /// One recall row: its words (untrusted when an assistant learned it), the person's words, when
  /// it was saved, where it came from and who may read it.
  static func row(_ record: MemoryRecord, names: [String: String], team: RelayTeam) -> [String: Any] {
    var out: [String: Any] = [
      "id": record.id, "quote": record.quote ?? "", "saved": RelayToolHost.stamp(record.createdAt),
      "from": MemoryPrompt.label(record, names: names), "shared": MemoryTools.whom(record.scope, in: team),
    ]
    out[record.provenance.source.isLearned ? "text_untrusted" : "text"] = record.text
    return out
  }

  /// One record by id that the turn's assistant may change: one it may recall, or its own
  /// proposal. Throws "No note has that id" otherwise.
  func memoryRecord(_ id: String) async throws -> MemoryRecord {
    guard let memory = await memoryStore() else { throw SereinError.invalid(Self.memoryClosed) }
    let found: MemoryRecord? = try await memory.run { (store: MemoryStore) -> MemoryRecord? in try store.record(id: id) }
    let reader = memoryReader(turnProfileID)
    guard let found,
      MemoryRecall.eligible(found, for: reader) || (found.review == .unreviewed && found.owner == reader.assistant)
    else { throw SereinError.invalid("No note has that id. Use recall to find it.") }
    return found
  }

  /// Forgets `records` (at most three, SPEC 4.3): each leaves a digest (`declined` for a
  /// proposal), and the receipt's Undo brings them back for 10 seconds.
  func forgetFacts(_ records: [MemoryRecord]) async throws -> Receipt {
    guard let memory = await memoryStore() else { throw SereinError.invalid(Self.memoryClosed) }
    let targets: [(id: String, idea: Bool)] = records.map { (id: $0.id, idea: $0.review == .unreviewed) }
    let entries: [String] = try await memory.run { (store: MemoryStore) -> [String] in
      var out: [String] = []
      for target in targets {
        let write = try store.forget(id: target.id, reason: target.idea ? .declined : .forgotten)
        if case .done(let entry) = write { out.append(entry) }
      }
      return out
    }
    guard !entries.isEmpty else { throw SereinError.invalid("I cannot find that note.") }
    await refreshNotes(journal: "relay")
    let receipt = ReceiptCopy.forgot(entry: Self.memoryUndoPrefix + entries.joined(separator: ","))
    noteReceipt(receipt)
    return receipt
  }

  /// Moves `record` to `scope` (SPEC 4.3): wider for a share, or back to its assistant ("keep
  /// that to yourself"). A learned record never goes wider (`MemoryRecord.edited`), nor one from
  /// outside content.
  func shareFact(_ record: MemoryRecord, with scope: MemoryScope) async throws -> Receipt {
    guard let memory = await memoryStore() else { throw SereinError.invalid(Self.memoryClosed) }
    let own = MemoryScope.assistant(record.owner)
    if record.outside, scope != own { throw SereinError.invalid(Self.outsideStays) }
    let id = record.id
    let expected = record.updatedAt
    let write = try await memory.run { (store: MemoryStore) -> MemoryWrite in
      try store.update(id: id, expected: expected, edit: MemoryEdit(scope: scope))
    }
    guard case .done(let entry) = write else { throw SereinError.invalid(write.words ?? "That note changed. Try again.") }
    await refreshNotes(journal: "relay")
    let token = Self.memoryUndoPrefix + entry
    let receipt: Receipt
    if scope == own {
      let name = memoryNames[record.owner] ?? "This assistant"
      receipt = Receipt(
        kind: .memoryShared, line: "Done. Only \(name) uses it now.", undo: UndoToken(entry: token, kind: .memoryShared))
    } else {
      receipt = ReceiptCopy.shared(with: MemoryTools.whom(scope, in: team), entry: token)
    }
    noteReceipt(receipt)
    return receipt
  }

  /// The person said yes to keeping a proposal (`remember` with `keep`): it is confirmed and stays
  /// private to its assistant.
  func keepIdea(_ record: MemoryRecord) async throws -> Receipt {
    guard let memory = await memoryStore() else { throw SereinError.invalid(Self.memoryClosed) }
    guard record.review == .unreviewed else { throw SereinError.invalid("That note is kept already.") }
    let id = record.id
    let expected = record.updatedAt
    let write = try await memory.run { (store: MemoryStore) -> MemoryWrite in
      try store.update(id: id, expected: expected, edit: MemoryEdit(review: .confirmed))
    }
    guard case .done(let entry) = write else { throw SereinError.invalid(write.words ?? "That note changed. Try again.") }
    await refreshNotes(journal: "learning")
    let receipt = ReceiptCopy.remembered(record.text, sharedWithAll: false, entry: Self.memoryUndoPrefix + entry)
    noteReceipt(receipt)
    return receipt
  }

  // MARK: receipts and their Undo

  /// The receipt for a schedule Serein just saved (`ScheduleRequest.receipt`), with Undo through
  /// its schedule change, shown under the turn's reply.
  @discardableResult
  func scheduleReceipt(
    for reminder: RelayReminder, owner: String?, connect: [ConnectLink] = [], into chat: String? = nil
  ) -> Receipt {
    var receipt = ScheduleRequest.receipt(for: reminder, owner: owner)
    // An app it needs is not connected yet: the line says so, and the pill rides under it.
    if let first = connect.first { receipt.line = ScheduleRequest.connectFirst(receipt.line, app: first.name) }
    if let change = scheduleChanges.last(where: { $0.itemID == reminder.id }) {
      receipt.undo = UndoToken(entry: Self.scheduleUndoPrefix + change.id.uuidString, kind: receipt.kind)
    }
    deliver(receipt: receipt, connect: connect, into: chat ?? turnThread)
    return receipt
  }

  /// Undo for a memory receipt (an entry "memory:…"), off the main thread: the store reverses its
  /// log entries (a forget's copy lasts `UndoToken.removalWindow`). The receipt that says so, or
  /// the words that say why not. The receipt's Undo (`undoReceipt`) and the `undo` tool call this;
  /// a schedule's Undo goes through `revert`.
  func revertMemory(_ token: UndoToken) async -> Result<Receipt, ChangeRefusal> {
    let gone: ChangeRefusal = "That note can no longer change back."
    guard token.isLive(), token.entry.hasPrefix(Self.memoryUndoPrefix) else { return .failure(gone) }
    let entries = token.entry.dropFirst(Self.memoryUndoPrefix.count).split(separator: ",").map(String.init)
    guard !entries.isEmpty, let memory = await memoryStore() else { return .failure(gone) }
    let undone: Int? = try? await memory.run { (store: MemoryStore) -> Int in
      var count = 0
      for entry in entries {
        if case .done = try store.undo(entry: entry) { count += 1 }
      }
      return count
    }
    guard let undone, undone > 0 else { return .failure(gone) }
    desk.undo.remove(token.entry)
    await refreshNotes(journal: "user")
    return .success(ReceiptCopy.undone())
  }

  #if DEBUG
  /// Checks only: puts `records` straight into the store and reads the notes again.
  func seedMemoryForChecks(_ records: [MemoryRecord]) async {
    guard let memory = await memoryStore() else { return }
    let seeds = records
    _ = try? await memory.run { (store: MemoryStore) -> Void in
      for record in seeds { _ = try store.insert(record) }
    }
    await refreshNotes()
  }
  #endif
}
