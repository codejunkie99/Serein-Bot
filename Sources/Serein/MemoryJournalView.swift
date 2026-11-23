import AppKit
import SereinCore
import SwiftUI

/// What the journal reads from the store beside the entries themselves: how full the assistant's
/// notes are, and the record behind each note the journal names (for its source chip, and to
/// tell whether an Undo is still safe).
struct MemoryJournalState: Equatable, Sendable {
  var usage = MemoryFill.Usage()
  var records: [String: MemoryRecord] = [:]
}

extension RelayOrchestrator {
  /// The journal's state for the assistant you talk to, read off the main thread. The person's
  /// own view: no model reads it, so no chat is marked.
  func memoryJournalState() async -> MemoryJournalState {
    guard let memory = await memoryStore() else { return MemoryJournalState() }
    let owner: String = team.activeID
    let ids: [String] = Array(Set(journal.map(\.noteID)))
    let read: MemoryJournalState? = try? await memory.run { (store: MemoryStore) -> MemoryJournalState in
      var state = MemoryJournalState(usage: MemoryFill.usage(try store.notes(owner: owner)))
      for id in ids {
        if let record = try store.record(id: id) { state.records[id] = record }
      }
      return state
    }
    return read ?? MemoryJournalState()
  }
}

/// The memory journal of the assistant you talk to: a gauge of how full its notes are, then
/// every change to them as one plain sentence, newest first, each with its source, a fold that
/// shows the words before and after, and Undo. Past `MemoryJournal.searchAbove` changes a search
/// field narrows the list. Where an Undo is no longer safe the row says why in a few words and
/// offers no button. It sits in the assistant's Memory settings and in its own window, which
/// the chat opens (`MemoryJournalWindow`). Nothing here animates layout: a fold appears at once.
struct MemoryJournalView: View {
  @ObservedObject var relay: RelayOrchestrator
  /// The assistant's name, for the sentences.
  let name: String
  @Environment(\.palette) var p
  @State private var query = ""
  @State private var open: Set<UUID> = []
  @State private var state = MemoryJournalState()
  /// A fold never grows taller than this; longer words scroll inside it.
  static let foldHeight: CGFloat = 240

  private var entries: [RelayJournalEntry] {
    relay.journal.filter { !$0.isInstruction && !$0.isTeam }.reversed()
  }
  /// Changes when the journal or a listed note does, so the state is read again.
  private var stamp: Int {
    var hasher = Hasher()
    hasher.combine(relay.journal.last?.id)
    for note in relay.notes {
      hasher.combine(note.id)
      hasher.combine(note.text)
    }
    return hasher.finalize()
  }

  var body: some View {
    let all: [RelayJournalEntry] = entries
    let shown: [RelayJournalEntry] = all.filter { MemoryJournal.matches($0, query: query) }
    VStack(alignment: .leading, spacing: 12) {
      gauge
      if all.count > MemoryJournal.searchAbove { ChatSearchField(query: $query, prompt: "Find a change") }
      if all.isEmpty {
        Text("No changes yet. What \(name) remembers shows here, with Undo.").role(.meta)
      } else if shown.isEmpty {
        Text("No change matches.").role(.meta)
      } else {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(shown, id: \.id) { entry in row(entry) }
        }
      }
    }
    .task(id: stamp) { state = await relay.memoryJournalState() }
  }

  /// One short line, a thin bar and the detail behind the info button. It turns to the warning
  /// colour from `MemoryFill.warnAt`.
  private var gauge: some View {
    let usage: MemoryFill.Usage = state.usage
    let tone: Color = usage.warns ? p.warning : p.secondary
    return HStack(spacing: 8) {
      Text(MemoryJournal.gauge(usage)).role(.meta).foregroundStyle(tone)
      Capsule().fill(p.track).frame(width: 72, height: 4)
        .overlay(alignment: .leading) {
          Capsule().fill(tone).frame(width: 72 * min(1, max(0, usage.fraction)), height: 4)
        }
        .accessibilityHidden(true)
      InfoPopoverButton(text: MemoryJournal.gaugeInfo, label: "About how full the notes are")
      Spacer(minLength: 0)
    }
  }

  /// The words the note holds now, as Undo would find them. A removed note counts as back when
  /// the store holds it live, listed or not; any other change must find the note in the list
  /// (`RelayJournal.undo` works on the list).
  private func live(_ entry: RelayJournalEntry) -> String? {
    if let listed = relay.notes.first(where: { $0.id == entry.noteID }) { return listed.text }
    guard entry.action == .removed, let record = state.records[entry.noteID], record.archived == nil,
      record.review != .unreviewed
    else { return nil }
    return record.text
  }

  private func row(_ entry: RelayJournalEntry) -> some View {
    let sentence: String = MemoryJournal.sentence(entry, name: name)
    let blocked: String? = MemoryJournal.undoBlock(entry, live: live(entry))
    let unfolded: Bool = open.contains(entry.id)
    return HStack(alignment: .top, spacing: 8) {
      Button {
        if unfolded { open.remove(entry.id) } else { open.insert(entry.id) }
      } label: {
        InterfaceIcon(systemName: "chevron.right", size: 11).foregroundStyle(p.faint)
          .rotationEffect(.degrees(unfolded ? 90 : 0))
          .frame(width: 20, height: 20).contentShape(Rectangle())
      }.buttonStyle(.pressable)
        .help(unfolded ? "Hide the change" : "Show the change")
        .accessibilityLabel(unfolded ? "Hide the change" : "Show the change")
      VStack(alignment: .leading, spacing: 4) {
        Text(sentence).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          Text(entry.at.formatted(.relative(presentation: .named))).role(.meta)
          if let record = state.records[entry.noteID] { chip(record) }
        }
        if unfolded { fold(entry) }
      }
      Spacer(minLength: 8)
      if let blocked {
        Text(blocked).role(.meta).accessibilityLabel("Undo is off: \(blocked)")
      } else {
        Button("Undo") { relay.undo(entry) }.controlSize(.small)
          .accessibilityLabel("Undo: \(sentence)")
      }
    }
  }

  /// Where the note came from. With a chat, a click opens that chat.
  @ViewBuilder private func chip(_ record: MemoryRecord) -> some View {
    let label: String = MemoryJournal.source(record)
    let face = Text(label).font(UIStyle.font(11)).foregroundStyle(p.secondary)
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(Capsule().fill(p.track))
    if let chat = record.chat {
      Button { SereinRouter.open(threadID: chat) } label: { face }
        .buttonStyle(.pressable).help("Open the chat this came from")
        .accessibilityLabel("\(label). Open the chat this came from")
    } else {
      face
    }
  }

  /// Past this many characters the fold's words could pass `foldHeight` at the journal's width,
  /// so they scroll in a fold of that height instead.
  static let foldScrollsAbove = 700

  /// The change itself: the words before struck through, then the words after, and what the
  /// person said. Short words take their own height; long ones scroll within `foldHeight`.
  @ViewBuilder private func fold(_ entry: RelayJournalEntry) -> some View {
    let words = VStack(alignment: .leading, spacing: 4) {
      if let prior = entry.priorText, !prior.isEmpty {
        Text(prior).strikethrough().foregroundStyle(p.faint)
          .accessibilityLabel("Before: \(prior)")
      }
      if !entry.text.isEmpty { Text(entry.text).accessibilityLabel("Now: \(entry.text)") }
      if let quote = entry.quote ?? entry.priorQuote, !quote.isEmpty {
        Text("You said “\(quote)”").role(.meta)
      }
    }
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
    let length: Int = (entry.priorText?.count ?? 0) + entry.text.count + ((entry.quote ?? entry.priorQuote)?.count ?? 0)
    // shortcut: a character count stands in for the measured height; measure if a fold clips.
    if length > Self.foldScrollsAbove {
      ScrollView { words.fixedSize(horizontal: false, vertical: true) }
        .frame(height: Self.foldHeight).foldCard(p)
    } else {
      words.fixedSize(horizontal: false, vertical: true).foldCard(p)
    }
  }
}

extension View {
  /// The fold's quiet card under a journal row.
  fileprivate func foldCard(_ p: Palette) -> some View {
    padding(8).background(RoundedRectangle(cornerRadius: UIStyle.controlRadius).fill(p.track)).padding(.top, 4)
  }
}

/// The journal in its own window, so the chat can show it without a trip through Settings: the
/// person asks to see what is remembered (`MemoryTools.asksToSeeMemory`, `prepareMemory`), and
/// any other surface may call `show`. One window; a second call brings it forward.
@MainActor enum MemoryJournalWindow {
  private static var window: NSWindow?
  private static var closeObserver: NSObjectProtocol?

  /// Opens the journal of the assistant you talk to. Checks and previews open no window.
  static func show(_ relay: RelayOrchestrator) {
    guard !RunMode.automated else { return }
    if let window {
      window.makeKeyAndOrderFront(nil)
      return
    }
    let w = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 620), styleMask: [.titled, .closable, .resizable],
      backing: .buffered, defer: false)
    w.title = "Memory"
    w.isReleasedWhenClosed = false
    w.contentMinSize = NSSize(width: 380, height: 320)
    w.contentViewController = NSHostingController(rootView: MemoryJournalPanel(relay: relay))
    w.center()
    window = w
    closeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: w, queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        window = nil
        if let token = closeObserver { NotificationCenter.default.removeObserver(token) }
        closeObserver = nil
      }
    }
    w.makeKeyAndOrderFront(nil)
  }
}

/// The window's content: the journal on the panel colour, scrolling as a whole.
private struct MemoryJournalPanel: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject private var appearance = AppearanceController.shared
  var body: some View {
    let p: Palette = appearance.palette
    ScrollView {
      MemoryJournalView(relay: relay, name: relay.team.active?.name ?? "Serein")
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 380, minHeight: 320)
    .font(UIStyle.body).foregroundStyle(p.ink).background(p.panel)
    .environment(\.palette, p)
  }
}
