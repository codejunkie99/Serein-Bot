import SereinCore
import SwiftUI

/// Session files: a task's own record (its chat, each turn's steps and the cards it put to the
/// person) read as one log (`SessionLog`), opened from the task's ⋯ menu, its actions bar and
/// History › Chats, and searched by History. Nothing here is stored twice and no agent reads it.
@MainActor enum SessionFiles {
  /// A task's record as its views show it, with condensed ranges put back: the open chat's
  /// messages, else its latest run's transcript, else the saved chat.
  static func record(_ id: String, agent: AgentModel) -> [AgentMessage] {
    ChatCondense.expanded(id == agent.conversationID ? agent.messages : SereinTaskHeader.messages(id, agent: agent))
  }

  static func log(_ messages: [AgentMessage]) -> SessionLog {
    SessionLog(messages.map {
      SessionLog.Message(id: $0.id, role: $0.role, text: $0.text, activities: $0.activities ?? [])
    })
  }

  /// History's search through the logs, off the main thread; it holds only the tasks handed in
  /// with the latest search, so a deleted chat's log leaves it with the next one.
  static let index = SessionSearchIndex()

  /// Every saved task (not Serein's own chats) as the index takes it, with a version that moves
  /// whenever the chat's end or its last turn's steps change, so an unchanged log is not rebuilt.
  static func searchSources(_ agent: AgentModel) -> [SessionSearchIndex.Source] {
    agent.conversations.filter { !$0.messages.isEmpty && !agent.isSereinChat($0) }.map { thread in
      var version = Hasher()
      version.combine(thread.tail.count)
      version.combine(thread.tail.last)
      version.combine(thread.messages.last?.activities?.count ?? 0)
      return SessionSearchIndex.Source(
        id: thread.id, version: version.finalize(),
        messages: ChatCondense.expanded(thread.messages).map {
          SessionLog.Message(id: $0.id, role: $0.role, text: $0.text, activities: $0.activities ?? [])
        })
    }
  }
}

/// A task's session log, read only: every request, step, card with its answer and output in
/// order, numbered. Find narrows the lines. Each line offers Continue from here (a fresh task that
/// starts from the log up to that line) and Fork from here (a copy of the record up to it).
struct SessionLogSheet: View {
  let id: String
  @ObservedObject var agent: AgentModel
  let close: () -> Void
  @State private var query = ""
  @Environment(\.palette) private var p
  var body: some View {
    let log = SessionFiles.log(SessionFiles.record(id, agent: agent))
    let shown = log.matching(query)
    let title = agent.hub.latest(for: id)?.spec.title ?? agent.openThreadItem(id)?.title ?? "Task"
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Session log").role(.section).accessibilityAddTraits(.isHeader)
        Text(verbatim: title.isEmpty ? "Task" : title).role(.meta).lineLimit(1)
      }
      Text("Each request, step, card and output of this task, in order. Recognised keys, tokens and passwords are replaced, typed values are left out, and long requests and outputs are cut.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      ChatSearchField(query: $query, prompt: "Find in this log")
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          if log.entries.isEmpty {
            Text("Nothing in this task's log yet.").role(.meta).padding(.vertical, 12)
          } else if shown.isEmpty {
            Text("Nothing in this log matches “\(query)”.").role(.meta).padding(.vertical, 12)
          }
          ForEach(shown) { entry in row(entry) }
        }.padding(.vertical, 4)
      }.frame(height: 420)
      HStack {
        Text("\(log.entries.count) line\(log.entries.count == 1 ? "" : "s") · This log follows the chat. Try Again and Edit change it the same way.")
          .role(.micro).fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button("Done") { close() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
      }
    }.padding(24).frame(width: UIStyle.wide(560)).background(p.panel)
      .accessibilityElement(children: .contain).accessibilityLabel("Session log, read only")
  }

  private func row(_ entry: SessionLog.Entry) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("\(entry.number)").font(UIStyle.microMono).foregroundStyle(p.faint)
        .frame(minWidth: 26, alignment: .trailing).accessibilityHidden(true)
      InterfaceIcon(systemName: Self.symbol(entry.kind), size: 11)
        .foregroundStyle(entry.failed ? p.danger : p.secondary).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(SessionLog.kindName(entry.kind) + (entry.failed ? (entry.kind == .card ? " · not allowed" : " · not done") : ""))
          .font(UIStyle.micro).foregroundStyle(entry.failed ? p.danger : p.faint)
        Text(verbatim: entry.text).font(UIStyle.meta).foregroundStyle(p.ink).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }.frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SessionLog.line(entry))
      Menu {
        actions(entry)
      } label: {
        InterfaceIcon(systemName: "arrow.triangle.branch", size: 12).foregroundStyle(p.secondary)
          .frame(width: 24, height: 22).contentShape(Rectangle())
      }.composerMenu().fixedSize()
        .help("Continue from here or fork from here")
        .accessibilityLabel("Continue or fork from line \(entry.number)")
    }.contextMenu { actions(entry) }
  }

  @ViewBuilder private func actions(_ entry: SessionLog.Entry) -> some View {
    Button("Continue from here") {
      close()
      agent.flow.continueFromLog(id, through: entry.id, fork: false)
    }.help("Start a fresh task from this log up to here. This task stays as it is.")
    Button("Fork from here") {
      close()
      agent.flow.continueFromLog(id, through: entry.id, fork: true)
    }.help("Start a new task with a copy of this task up to here. This task stays as it is.")
  }

  static func symbol(_ kind: SessionLog.Entry.Kind) -> String {
    switch kind {
    case .request: return "person"
    case .step: return "list.bullet"
    case .card: return "hand.raised"
    case .output: return "text.alignleft"
    }
  }
}

/// A result line's meter (ContextMeter): “about 42% of context”, “(estimate)” when Serein guessed.
/// Past 80% it is in the warning colour, with one line suggesting a fresh task, in words as well
/// as colour. With `fill` the line opens in place to what fills the window (`ContextWindowView`);
/// with `compact` as well, the nearly-full line offers Compact right there.
struct ContextMeterLine: View {
  let meter: ContextMeter
  /// False once the turn's end condensed the chat: the next turn already starts from a summary.
  var advise = true
  /// What fills the window (`AgentRun.contextFill`); nil for a record read later.
  var fill: ContextFill? = nil
  /// Folds the chat's older replies now (`ChatCondense`); nil where nothing can fold.
  var compact: (() -> Void)? = nil
  @State private var open = false
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  var body: some View {
    let reduce: Bool = systemReduceMotion || previewReducedEffects
    let compactHere: (() -> Void)? = advise ? compact : nil
    VStack(alignment: .leading, spacing: 2) {
      if fill != nil {
        Button {
          withAnimation(reduce ? nil : Motion.enter) { open.toggle() }
        } label: {
          HStack(spacing: 4) {
            label
            InterfaceIcon(systemName: "chevron.right", size: 9).foregroundStyle(p.faint)
              .rotationEffect(.degrees(open ? 90 : 0))
          }.contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .help(open ? "Hide what fills the context" : "Show what fills the context")
        .accessibilityLabel(meter.label)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
      } else {
        label
      }
      if meter.warns && advise {
        if let compactHere {
          HStack(spacing: 8) {
            Text("Context is nearly full.").font(UIStyle.micro).foregroundStyle(p.warning)
            Button("Compact now", action: compactHere).buttonStyle(.pressable)
              .font(UIStyle.micro).foregroundStyle(p.ink)
              .help(ContextFill.compactNote)
          }
        } else {
          Text(ContextMeter.advice).font(UIStyle.micro).foregroundStyle(p.warning)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if open, let fill {
        ContextWindowView(meter: meter, fill: fill, compact: compactHere)
          .padding(.top, 6).transition(Motion.arrival(reduce))
      }
    }.accessibilityElement(children: .contain)
  }
  private var label: some View {
    Text(meter.label).font(UIStyle.micro).foregroundStyle(meter.warns ? p.warning : p.faint)
  }
}

/// What fills the context window (affectUI Context Window, Context Map folded in): a field of 50
/// cells, two rows of 25, each 2% of the window, filled in the parts' order; under it one row per
/// part with its share and tokens, then what is left and Compact. Pointing at a row lights its
/// cells and dims the rest (opacity only). The field is drawn for the eye; every figure is in the
/// rows too, so VoiceOver reads the rows and skips the field.
struct ContextWindowView: View {
  let meter: ContextMeter
  let fill: ContextFill
  var compact: (() -> Void)? = nil
  @State private var lit: ContextFill.Kind? = nil
  @Environment(\.palette) private var p
  var body: some View {
    let cells: [ContextFill.Kind?] = fill.cells
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Context window").font(AssistantType.name).foregroundStyle(p.ink)
        Spacer(minLength: 8)
        Text(verbatim: "\(meter.percent)% of \(ContextFill.tokens(fill.window))")
          .font(AssistantType.figures).foregroundStyle(meter.warns ? p.warning : p.secondary)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Context window, about \(meter.percent)% of \(ContextFill.tokens(fill.window)) tokens used")
      VStack(alignment: .leading, spacing: 2) {
        ForEach(0..<(ContextFill.cellCount / ContextFill.cellsPerRow), id: \.self) { line in
          HStack(spacing: 2) {
            ForEach(0..<ContextFill.cellsPerRow, id: \.self) { column in
              let kind: ContextFill.Kind? = cells[line * ContextFill.cellsPerRow + column]
              RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(kind.map(tone) ?? p.track)
                .frame(width: 9, height: 9)
                .opacity(lit == nil || kind == lit ? 1 : 0.35)
            }
          }
        }
      }
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 0) {
        ForEach(fill.parts, id: \.kind) { part in
          HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(tone(part.kind)).frame(width: 9, height: 9)
            Text(verbatim: fill.words(part.kind)).font(AssistantType.meta).foregroundStyle(p.ink).lineLimit(1)
            Spacer(minLength: 8)
            Text(verbatim: "\(fill.percent(part))% · \(ContextFill.tokens(part.tokens))")
              .font(AssistantType.figures).foregroundStyle(p.secondary)
          }
          .frame(minHeight: 24)
          .contentShape(Rectangle())
          .onHover { lit = $0 ? part.kind : (lit == part.kind ? nil : lit) }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(fill.line(part))
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: fill.leftLine).font(AssistantType.meta).foregroundStyle(meter.warns ? p.warning : p.secondary)
        if fill.estimated {
          Text(ContextFill.estimateNote).font(UIStyle.micro).foregroundStyle(p.faint)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if let compact {
        HStack(alignment: .top, spacing: 12) {
          Text(ContextFill.compactNote).font(UIStyle.micro).foregroundStyle(p.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          ChatCardSolidButton(title: "Compact", action: compact)
        }
      }
    }
    .padding(16)
    .frame(maxWidth: AssistantMetrics.cardNarrow, alignment: .leading)
    .assistantCard(p)
    .accessibilityElement(children: .contain)
  }
  /// One neutral step per part and the accent for the chat, the part Compact can shrink.
  private func tone(_ kind: ContextFill.Kind) -> Color {
    switch kind {
    case .instructions: return p.faint
    case .memory: return p.secondary
    case .files: return p.ink.opacity(0.55)
    case .chat: return p.accent
    }
  }
}

extension AgentRun {
  /// What fills the task's window, for its meter (`ContextFill`): the chat and this turn's
  /// documents by Serein's own count, the rest of what the harness reported as instructions and
  /// tools. Memory has no count of its own here, so it stays inside the instructions.
  var contextFill: ContextFill? {
    ContextFill.measure(
      window: contextWindow ?? ContextMeter.knownWindow(spec.provider.driver, model: spec.model),
      reported: contextTokens, chat: ChatCondense.estimate(transcript),
      files: documents.reduce(0) { $0 + $1.text.utf8.count } / 4, memory: nil)
  }
}
