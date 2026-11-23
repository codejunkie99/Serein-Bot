import SereinCore
import SwiftUI

// Serein's own questions (ask_user), inside its reply: one card that asks one question at a
// time, then folds into small answer chips where the turn began. Approvals and other apps'
// questions keep the dock above the composer (`DecisionDock`).

/// A form Serein asked for mid-turn, at the foot of its reply. "Needs you" and the form's title,
/// dots for where it is when there are several questions, the question, its choices as numbered
/// rows, and a last row for the person's own words. A row answers by click, by its number key, or
/// by the arrows and Return; Back and Skip sit at the foot. After the last question the card goes
/// and the answers show as chips (`AnsweredQuestionChips`).
struct QuestionFormCard: View {
  let form: RelayOrchestrator.QuestionForm
  let relay: RelayOrchestrator
  let p: Palette
  @State private var answers: [String: String] = [:]
  @State private var step = 0
  @State private var forward = true
  @State private var selected = 0
  @State private var typed = ""
  @FocusState private var keys: Bool
  @FocusState private var fieldFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  private var reduceMotion: Bool { systemReduceMotion || previewReducedEffects }

  private var current: RelayQuestion { form.questions[min(step, form.questions.count - 1)] }
  private var lastStep: Bool { step + 1 >= form.questions.count }
  private var rows: [DecisionRow] {
    let hint = lastStep ? "Answers \(current.label)" : "Answers and goes to the next question"
    return current.choices.map { choice in
      let parts = RelayAsk.split(choice)
      return DecisionRow(id: choice, title: parts.title, summary: parts.detail, chosen: answers[current.id] == choice,
                         hint: hint) { choose(choice) }
    }
  }

  var body: some View {
    let rows = rows
    VStack(alignment: .leading, spacing: 0) {
      header.padding(.horizontal, 16).padding(.top, 14)
      VStack(alignment: .leading, spacing: 10) {
        Text(current.label).font(UIStyle.font(15, weight: .semibold)).foregroundStyle(p.ink)
          .fixedSize(horizontal: false, vertical: true)
        if current.columns != nil {
          columns
        } else {
          VStack(spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { number, row in
              DecisionRowView(row: row, number: number + 1, selected: keys && number == selected, enabled: true) {
                selected = number
                row.pick()
              }
            }
            field(number: rows.count + 1)
          }.padding(.horizontal, -8)
        }
      }
      .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
      .id(step)
      .transition(stepTransition)
      footer(rowCount: rows.count)
    }
    .frame(maxWidth: 560, alignment: .leading)
    .background(p.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.borderStrong, lineWidth: UIStyle.hairline))
    .shadow(color: p.cardShadow, radius: 10, y: 4)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .focusable().focusEffectDisabled().focused($keys)
    .onKeyPress(characters: .decimalDigits, phases: .down) { press in
      guard !fieldFocused, let number = Int(press.characters), number >= 1 else { return .ignored }
      if number <= min(rows.count, 9) {
        selected = number - 1
        rows[number - 1].pick()
        return .handled
      }
      if number == rows.count + 1, current.columns == nil {
        fieldFocused = true
        return .handled
      }
      return .ignored
    }
    .onKeyPress(.upArrow) {
      guard !fieldFocused, !rows.isEmpty else { return .ignored }
      selected = max(selected - 1, 0)
      return .handled
    }
    .onKeyPress(.downArrow) {
      guard !fieldFocused, !rows.isEmpty else { return .ignored }
      if selected + 1 < rows.count { selected += 1 } else { fieldFocused = true }
      return .handled
    }
    .onKeyPress(.return) {
      guard !fieldFocused, rows.indices.contains(selected) else { return .ignored }
      rows[selected].pick()
      return .handled
    }
    .onExitCommand { keys = false }
    .onAppear { takeKeys() }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Serein needs an answer: \(form.title)")
  }

  // MARK: parts

  private var header: some View {
    HStack(spacing: 8) {
      Text("Needs you").font(UIStyle.font(11, weight: .medium)).foregroundStyle(p.warning)
        .padding(.horizontal, 7).frame(height: 20)
        .background(p.warning.opacity(0.12), in: Capsule())
      Text(form.title).font(UIStyle.font(12.5)).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.tail)
      Spacer(minLength: 8)
      if form.questions.count > 1 {
        HStack(spacing: 4) {
          ForEach(form.questions.indices, id: \.self) { index in
            Capsule().fill(index <= step ? p.ink : p.borderStrong).frame(width: 16, height: 3)
          }
        }
        .animation(MessageMotion.controls, value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Question \(step + 1) of \(form.questions.count)")
      }
    }
  }

  /// The person's own words, as the last numbered row: Return or the arrow sends them.
  private func field(number: Int) -> some View {
    let empty = typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return HStack(spacing: 10) {
      Group {
        if current.choices.isEmpty {
          InterfaceIcon(systemName: "pencil", size: 11)
        } else {
          Text("\(number)").font(UIStyle.font(12, weight: .medium))
        }
      }
      .foregroundStyle(p.secondary).frame(width: 24, height: 24)
      .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(p.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [2.5, 2])))
      .accessibilityHidden(true)
      TextField(current.choices.isEmpty ? "Type your answer" : "Something else\u{2026}", text: $typed)
        .textFieldStyle(.plain).font(UIStyle.font(14)).focused($fieldFocused)
        .onSubmit(submitTyped)
        .onExitCommand { fieldFocused = false; keys = true }
        .accessibilityLabel(current.label)
      if !empty || current.choices.isEmpty {
        Button(action: submitTyped) {
          InterfaceIcon(systemName: "arrow.up", size: 12).foregroundStyle(empty ? p.faint : p.onSolid)
            .frame(width: 24, height: 24).background(empty ? p.track : p.solid, in: Circle())
        }.buttonStyle(AssistantPressStyle()).disabled(empty)
          .accessibilityLabel(lastStep ? "Send answer" : "Next question")
      }
    }
    .padding(8)
    .background(fieldFocused ? p.hover : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private var columns: some View {
    VStack(alignment: .leading, spacing: 8) {
      ColumnsEditor(proposed: current.columns ?? []) { answers[current.id] = $0 }
      HStack {
        Spacer()
        Button(lastStep ? "Collect" : "Next") { advance() }.buttonStyle(PillButton(kind: .solid, small: true))
          .disabled((answers[current.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
  }

  private func footer(rowCount: Int) -> some View {
    HStack(spacing: 4) {
      if rowCount > 0 {
        Text(rowCount == 1 ? "1 to pick" : "1\u{2013}\(min(rowCount, 9)) to pick")
          .font(UIStyle.micro).monospacedDigit().foregroundStyle(p.faint)
          .accessibilityHidden(true)
      }
      Spacer(minLength: 8)
      if step > 0 {
        Button("Back") { move(to: step - 1) }.buttonStyle(PillButton(kind: .quiet, small: true))
      }
      Button("Skip") {
        answers[current.id] = nil
        advance()
      }.buttonStyle(PillButton(kind: .quiet, small: true))
        .accessibilityLabel(lastStep ? "Skip and send the answers" : "Skip this question")
    }
    .padding(.horizontal, 12).padding(.vertical, 6)
    .overlay(alignment: .top) { Rectangle().fill(p.line).frame(height: UIStyle.hairline) }
  }

  private var stepTransition: AnyTransition {
    guard !reduceMotion else { return .opacity }
    return .asymmetric(
      insertion: .opacity.combined(with: .offset(x: forward ? 14 : -14)),
      removal: .opacity)
  }

  // MARK: answering

  private func takeKeys() {
    if current.choices.isEmpty, current.columns == nil { fieldFocused = true } else { keys = true }
  }
  private func submitTyped() {
    let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !words.isEmpty else { return }
    choose(words)
  }
  private func choose(_ value: String) {
    answers[current.id] = value
    advance()
  }
  /// The next question, or the answers to Serein after the last.
  private func advance() {
    if lastStep {
      withAnimation(MessageMotion.reply) { relay.answer(form, answers) }
    } else {
      move(to: step + 1)
    }
  }
  private func move(to index: Int) {
    forward = index > step
    withAnimation(MessageMotion.time) { step = index }
    typed = answers[form.questions[index].id].flatMap { form.questions[index].choices.contains($0) ? nil : $0 } ?? ""
    selected = 0
    fieldFocused = false
    takeKeys()
  }
}

/// A form Serein asked and the person answered, where its turn began: one small chip per
/// question with the answer (the question on hover). Clicking a chip opens its choices again; a
/// new answer goes to Serein as the person's next message.
struct AnsweredQuestionChips: View {
  let answered: RelayOrchestrator.AnsweredQuestion
  let p: Palette
  var body: some View {
    FlowLayout(spacing: 6) {
      ForEach(Array(answered.items.enumerated()), id: \.offset) { index, item in
        AnswerChip(item: item, p: p) { value in
          RelayOrchestrator.shared?.changeAnswer(answered, at: index, to: value)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("You answered: \(answered.summary)")
  }
}

private struct AnswerChip: View {
  let item: RelayOrchestrator.AnsweredQuestion.Item
  let p: Palette
  let change: (String) -> Void
  @State private var hovered = false
  @State private var open = false

  var body: some View {
    Button { open = true } label: {
      HStack(spacing: 5) {
        InterfaceIcon(systemName: item.answer == nil ? "minus" : "checkmark", size: 10)
          .foregroundStyle(item.answer == nil ? p.faint : p.success)
        Text(item.answer ?? "Skipped").font(UIStyle.font(12.5, weight: .medium))
          .foregroundStyle(item.answer == nil ? p.secondary : p.ink)
          .lineLimit(1).truncationMode(.tail)
      }
      .padding(.leading, 8).padding(.trailing, 10).frame(height: 26)
      .background(hovered || open ? p.hover : p.track, in: Capsule())
      .contentShape(Capsule())
    }
    .buttonStyle(AssistantPressStyle())
    .onHover { hovered = $0 }
    .animation(MessageMotion.controls, value: hovered)
    .help("\(item.question) \u{00B7} Click to change")
    .accessibilityLabel("\(item.question): \(item.answer ?? "Skipped")")
    .accessibilityHint("Changes this answer")
    .popover(isPresented: $open, arrowEdge: .bottom) {
      ChangeAnswer(item: item, p: p) { value in
        open = false
        change(value)
      }
      .environment(\.palette, p)
    }
  }
}

/// A chip's question again, in a popover: its choices as numbered rows with the current one
/// marked, and a field for other words.
private struct ChangeAnswer: View {
  let item: RelayOrchestrator.AnsweredQuestion.Item
  let p: Palette
  let pick: (String) -> Void
  @State private var typed = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(item.question).font(UIStyle.font(14, weight: .semibold)).foregroundStyle(p.ink)
        .fixedSize(horizontal: false, vertical: true)
      if !item.choices.isEmpty {
        VStack(spacing: 2) {
          ForEach(Array(item.choices.enumerated()), id: \.offset) { number, choice in
            let parts = RelayAsk.split(choice)
            DecisionRowView(
              row: DecisionRow(id: choice, title: parts.title, summary: parts.detail, chosen: parts.title == item.answer,
                               hint: "Sends this as your new answer") { pick(choice) },
              number: number + 1, selected: false, enabled: true) { pick(choice) }
          }
        }.padding(.horizontal, -8)
      }
      HStack(spacing: 8) {
        TextField(item.choices.isEmpty ? "Your new answer" : "Something else\u{2026}", text: $typed)
          .textFieldStyle(.plain).font(UIStyle.font(14))
          .onSubmit { send() }
        Button("Send") { send() }.buttonStyle(PillButton(kind: .solid, small: true))
          .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding(.leading, 12).padding(.trailing, 4).frame(height: 34)
      .background(p.track, in: Capsule())
      Text("Serein has already moved on, so this goes as your next message.")
        .font(UIStyle.micro).foregroundStyle(p.faint).fixedSize(horizontal: false, vertical: true)
    }
    .padding(14).frame(width: 320)
  }

  private func send() {
    let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !words.isEmpty else { return }
    pick(words)
  }
}

/// The columns Serein proposed before a long collection: rename one in place, drop it, or add
/// one. Every change hands the kept names, joined as one answer, to the form.
struct ColumnsEditor: View {
  let changed: (String) -> Void
  @State private var columns: [String]
  init(proposed: [String], changed: @escaping (String) -> Void) {
    self.changed = changed
    _columns = State(initialValue: proposed)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(columns.indices, id: \.self) { index in
        HStack(spacing: 4) {
          // Reads guard the index: a dropped column's row can draw once more before it goes.
          TextField("Column name", text: Binding(
            get: { index < columns.count ? columns[index] : "" },
            set: { if index < columns.count { columns[index] = $0 } }))
            .textFieldStyle(.serein)
            .accessibilityLabel("Column \(index + 1)")
          Button {
            if index < columns.count { columns.remove(at: index) }
          } label: {
            InterfaceIcon(systemName: "xmark", size: 11)
          }.buttonStyle(QuietButton()).help("Drop this column")
            .accessibilityLabel("Drop column \(index + 1)")
            .disabled(columns.count == 1)
        }
      }
      Button {
        columns.append("")
      } label: {
        HStack(spacing: 4) {
          InterfaceIcon(systemName: "plus", size: 11)
          Text("Add column")
        }
      }.buttonStyle(QuietButton())
        .disabled(columns.count >= RelayAsk.maxColumns)
    }
    .onChange(of: columns, initial: true) { changed(RelayAsk.columnsAnswer(columns)) }
  }
}
