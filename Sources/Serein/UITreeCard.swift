import SereinCore
import SwiftUI

/// A view an assistant drew under its reply (`ui_show`; `UITree`, SereinCore/UITree.swift): the
/// model's tree of blocks, each drawn by one fixed view here in the card style of the chat. The
/// look follows affectUI's cards: a strip of stats split by hairlines, tone badges with a dot,
/// inset tiles, rows with a value at the end, a stepper and a switch. Every string can come from
/// pages or mail, so it is drawn as plain text; a tree with a problem draws nothing. A button
/// sends its own label and the controls' values as the person's message (`UITree.message`).
struct UITreeCard: View {
  let tree: UITree
  /// The reply's id: what the person set in this view is kept under it.
  var id: String = ""
  /// Sends a pressed button's message as the person's own; nil draws the buttons off.
  var send: ((String) -> Void)? = nil
  @Environment(\.palette) private var p

  private var press: ((String) -> Void)? {
    guard let send else { return nil }
    return { label in
      let words: String = UITreeValues.shared.kept.message(tree, in: id, pressing: label)
      UITreeValues.shared.kept.press(words, in: id)
      send(words)
    }
  }

  var body: some View {
    if tree.isValid {
      VStack(alignment: .leading, spacing: UITreeMetrics.gap) {
        if let title = tree.title, !title.isEmpty {
          Text(verbatim: title).font(AssistantType.name).foregroundStyle(p.ink).lineLimit(1)
            .accessibilityAddTraits(.isHeader)
        }
        ForEach(Array(tree.blocks.enumerated()), id: \.offset) { index, block in
          UIBlockView(block: block, path: UITree.path("", index), view: id, press: press)
        }
      }
      .padding(UITreeMetrics.pad)
      .frame(maxWidth: AssistantMetrics.replyMax, alignment: .leading)
      .assistantCard(p)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(tree.title ?? "View")
    }
  }
}

/// What the person set in each drawn view, by the reply's id and the control's place in its tree,
/// and the presses no turn has answered yet. Saved, so a relaunch shows the controls where the
/// person left them, and a press that waited through one still redraws its view.
struct UITreeKept: Codable, Equatable {
  static let maxViews: Int = 200
  private struct Press: Codable, Equatable {
    var view: String
    var words: String
  }
  private var values: [String: [String: UITree.Value]] = [:]
  /// Each view's last press, in the order pressed, until the turn that answers it ends.
  private var presses: [Press] = []
  /// The views by when the person last touched them; the oldest leave past `maxViews`.
  private var order: [String] = []

  init() {}
  /// A file with fewer fields than this build keeps still reads: what is missing starts empty.
  init(from decoder: Decoder) throws {
    let box = try decoder.container(keyedBy: CodingKeys.self)
    values = try box.decodeIfPresent([String: [String: UITree.Value]].self, forKey: .values) ?? [:]
    presses = try box.decodeIfPresent([Press].self, forKey: .presses) ?? []
    order = try box.decodeIfPresent([String].self, forKey: .order) ?? []
  }

  func value(at path: String, in view: String) -> UITree.Value? { values[view]?[path] }
  mutating func set(_ value: UITree.Value, at path: String, in view: String) {
    values[view, default: [:]][path] = value
    touch(view)
  }
  /// A button in `view` sent `words` as the person's message, kept as a chat keeps a message.
  mutating func press(_ words: String, in view: String) {
    presses.removeAll { $0.view == view }
    presses.append(Press(view: view, words: words.trimmingCharacters(in: .whitespacesAndNewlines)))
    touch(view)
  }
  /// The views whose press sent `words` and is not answered yet, the last pressed first.
  func pressed(sending words: String) -> [String] { presses.reversed().filter { $0.words == words }.map(\.view) }
  /// The turn that answered `words` in the chat holding `views` ended: that chat's press is done,
  /// so the same words typed later redraw nothing. A press in another chat waits for its own turn.
  mutating func answered(_ words: String, among views: Set<String>) {
    guard let index = presses.lastIndex(where: { $0.words == words && views.contains($0.view) }) else { return }
    forget(presses.remove(at: index).view)
  }
  private mutating func touch(_ view: String) {
    order.removeAll { $0 == view }
    order.append(view)
    while order.count > Self.maxViews {
      let oldest: String = order.removeFirst()
      values[oldest] = nil
      presses.removeAll { $0.view == oldest }
    }
  }
  /// A view with nothing kept leaves the order too.
  private mutating func forget(_ view: String) {
    if values[view] == nil, !presses.contains(where: { $0.view == view }) { order.removeAll { $0 == view } }
  }
  /// The view was drawn again: its controls start where the assistant put them. Its press stays
  /// until the turn ends, so a second view drawn in the same answer takes its place too.
  mutating func clear(_ view: String) {
    values[view] = nil
    forget(view)
  }
  /// What a pressed button sends from the view drawn in reply `view`: its label, then what the
  /// person set there.
  func message(_ tree: UITree, in view: String, pressing label: String) -> String {
    tree.message(pressing: label, values: values[view] ?? [:])
  }
}

@MainActor final class UITreeValues: ObservableObject {
  static let shared = UITreeValues()
  nonisolated static let file: String = "relay/view-values.json"
  @Published var kept = UITreeKept() {
    didSet { if kept != oldValue { library?.saveSoon(kept, to: Self.file) } }
  }
  private var library: Library?

  /// Reads what the last launch kept; what the person sets from now on is saved there. A file
  /// that does not decode is left as it is: this launch keeps its values in memory only.
  func open(_ library: Library) {
    self.library = nil
    switch library.loadGuarded(UITreeKept.self, from: Self.file) {
    case .loaded(let saved): kept = saved
    case .missing: kept = UITreeKept()
    case .unreadable:
      kept = UITreeKept()
      return
    }
    self.library = library
  }
}

enum UITreeMetrics {
  static let pad: CGFloat = 16
  static let gap: CGFloat = 12
  static let tileRadius: CGFloat = 12
}

/// One block and, for a layout block, its children. Validated by the card before it draws.
struct UIBlockView: View {
  let block: UIBlock
  /// Its place in the tree (`UITree.path`) and the reply it is drawn in: where its value is kept.
  let path: String
  let view: String
  let press: ((String) -> Void)?
  @ObservedObject private var store = UITreeValues.shared
  @Environment(\.palette) private var p

  var body: some View {
    switch block.kind {
    case .column: column
    case .row: row
    case .grid: grid
    case .card: tile
    case .text: text
    case .stat: stat
    case .badge: UIBadge(text: block.text ?? "", tone: block.toneValue, dot: block.dot ?? false)
    case .table: table
    case .progress: progress
    case .list: list
    case .divider: hairline
    case .chart:
      if let chart = block.chart { self.chart(chart) }
    case .button: button
    case .toggle: toggle
    case .stepper: stepper
    case .choice: choice
    case .input: input
    case nil: EmptyView()
    }
  }

  private var children: [UIBlock] { block.children ?? [] }
  private func child(_ index: Int, _ block: UIBlock) -> UIBlockView {
    UIBlockView(block: block, path: UITree.path(path, index), view: view, press: press)
  }
  private var value: UITree.Value? { store.kept.value(at: path, in: view) ?? UITree.initial(block) }
  private func set(_ value: UITree.Value) { store.kept.set(value, at: path, in: view) }
  private var label: String { block.label ?? "" }
  /// A badge or a button keeps its own width in a row; the rest share what is left.
  private static func hugs(_ block: UIBlock) -> Bool { block.kind == .badge || block.kind == .button }
  private var hairline: some View { Rectangle().fill(p.line).frame(height: UIStyle.hairline) }
  private func tint(_ tone: UIBlock.Tone) -> Color { UIBadge.tint(tone, p) }

  private var column: some View {
    VStack(alignment: .leading, spacing: UITreeMetrics.gap) {
      ForEach(Array(children.enumerated()), id: \.offset) { index, block in child(index, block) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Children side by side in equal shares; badges and buttons keep their own width, so a row of
  /// only those is a group at the leading edge. A row of stats is one strip, split by hairlines.
  private var row: some View {
    let strip: Bool = children.allSatisfy { $0.kind == .stat }
    let group: Bool = children.allSatisfy { Self.hugs($0) }
    let centered: Bool = children.contains { Self.hugs($0) }
    return HStack(alignment: centered ? .center : .top, spacing: group ? 8 : UITreeMetrics.gap) {
      ForEach(Array(children.enumerated()), id: \.offset) { index, block in
        if strip, index > 0 { Rectangle().fill(p.line).frame(width: UIStyle.hairline) }
        if Self.hugs(block) {
          child(index, block)
        } else {
          child(index, block).frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }

  /// The chart's title above it: `ReplyChartView` draws the plot and legend only.
  private func chart(_ chart: ReplyChart) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if let title = chart.title, !title.isEmpty {
        Text(verbatim: title).font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1)
      }
      ReplyChartView(chart: chart)
    }
  }

  private var grid: some View {
    let columns: [GridItem] = Array(
      repeating: GridItem(.flexible(), spacing: UITreeMetrics.gap, alignment: .topLeading), count: block.gridColumns)
    return LazyVGrid(columns: columns, alignment: .leading, spacing: UITreeMetrics.gap) {
      ForEach(Array(children.enumerated()), id: \.offset) { index, block in
        child(index, block).frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  /// An inset tile: its own plane and edge inside the card.
  private var tile: some View {
    let shape = RoundedRectangle(cornerRadius: UITreeMetrics.tileRadius, style: .continuous)
    return VStack(alignment: .leading, spacing: 8) {
      if let title = block.title, !title.isEmpty {
        Text(verbatim: title).font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1)
      }
      ForEach(Array(children.enumerated()), id: \.offset) { index, block in child(index, block) }
    }
    .padding(UITreeMetrics.gap)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(p.ink.opacity(0.04), in: shape)
    .overlay(shape.strokeBorder(p.line, lineWidth: UIStyle.hairline))
  }

  private var text: some View {
    let words: String = block.text ?? ""
    let font: Font
    let ink: Color
    switch block.styleValue {
    case .title:
      font = AssistantType.title
      ink = p.ink
    case .body:
      font = AssistantType.body
      ink = p.ink
    case .meta:
      font = AssistantType.meta
      ink = p.secondary
    }
    return Text(verbatim: words).font(font).foregroundStyle(ink)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var stat: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(verbatim: block.label ?? "").font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1)
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(verbatim: block.value ?? "").font(UIStyle.font(20, weight: .medium)).monospacedDigit()
          .foregroundStyle(block.toneValue == .neutral ? p.ink : tint(block.toneValue))
          .lineLimit(1).minimumScaleFactor(0.7)
        if block.trendValue != nil || !(block.change ?? "").isEmpty {
          UITrend(direction: block.trendValue ?? .flat, text: block.change ?? "")
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(block.label ?? "")
    .accessibilityValue([block.value, block.change].compactMap { $0 }.joined(separator: ", "))
  }

  /// Pressing it sends its label, and what the view's controls hold, as the person's message.
  private var button: some View {
    Button { press?(label) } label: { Text(verbatim: label).lineLimit(1) }
      .buttonStyle(PillButton(kind: block.buttonStyle == .primary ? .solid : .tinted, small: true))
      .disabled(press == nil)
      .help("Sends “\(label)” as your message")
      .accessibilityHint("Sends it as your message")
  }

  private func controlLabel(_ font: Font, _ ink: Color) -> some View {
    Text(verbatim: label).font(font).foregroundStyle(ink).lineLimit(1)
  }

  private var toggle: some View {
    let on: Binding<Bool> = Binding(
      get: { if case .on(let on) = value { return on } else { return false } },
      set: { set(.on($0)) })
    return HStack(spacing: 8) {
      controlLabel(AssistantType.body, p.ink)
      Spacer(minLength: 8)
      Toggle(label, isOn: on).toggleStyle(SereinSwitchStyle(labeled: false)).accessibilityLabel(label)
    }
  }

  /// affectUI's stepper: the number between a minus and a plus, each off at its end.
  private var stepper: some View {
    let number: Double = { if case .number(let number) = value { return number } else { return block.low } }()
    return HStack(spacing: 8) {
      controlLabel(AssistantType.body, p.ink)
      Spacer(minLength: 8)
      step("minus", "Less", from: number, direction: -1)
      Text(verbatim: UITree.words(.number(number))).font(AssistantType.figures).foregroundStyle(p.ink)
        .lineLimit(1).frame(minWidth: 28)
        .accessibilityLabel(label).accessibilityValue(UITree.words(.number(number)))
      step("plus", "More", from: number, direction: 1)
    }
  }
  private func step(_ icon: String, _ name: String, from number: Double, direction: Double) -> some View {
    let next: Double = UITree.stepped(block, from: number, direction: direction)
    return Button { set(.number(next)) } label: {
      InterfaceIcon(systemName: icon, size: 11).foregroundStyle(p.ink)
        .frame(width: 24, height: 24).background(p.track, in: Circle()).contentShape(Circle())
    }
    .buttonStyle(AssistantPressStyle())
    .disabled(next == number)
    .opacity(next == number ? 0.4 : 1)
    .accessibilityLabel("\(name): \(label)")
  }

  /// One of a few: the inspector's segments, or a menu where they do not fit.
  private var choice: some View {
    let options: [String] = block.options ?? []
    let pick: Binding<String> = Binding(
      get: { if case .pick(let option) = value { return option } else { return options.first ?? "" } },
      set: { set(.pick($0)) })
    return VStack(alignment: .leading, spacing: 6) {
      controlLabel(AssistantType.meta, p.secondary)
      ViewThatFits(in: .horizontal) {
        GoalSegments(label: label, options: options.map { ($0, $0) }, selection: pick)
        Picker(label, selection: pick) {
          ForEach(options, id: \.self) { option in Text(verbatim: option).tag(option) }
        }
        .pickerStyle(.menu).labelsHidden().fixedSize()
      }
    }
  }

  /// One line of typed text. Never a secure field: `UITree.problem` refuses a view that asks for a secret.
  private var input: some View {
    let typed: Binding<String> = Binding(
      get: { if case .words(let words) = value { return words } else { return "" } },
      set: { set(.words(String($0.prefix(UITree.maxTyped)))) })
    return VStack(alignment: .leading, spacing: 6) {
      controlLabel(AssistantType.meta, p.secondary)
      TextField(block.placeholder ?? "", text: typed)
        .textFieldStyle(.plain).font(AssistantType.body).foregroundStyle(p.ink)
        .padding(.horizontal, 10).frame(height: 32)
        .background(p.track, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel(label)
    }
  }

  private var progress: some View {
    let share: CGFloat = CGFloat(min(max(block.percent ?? 0, 0), 100) / 100)
    let detail: String = block.detail ?? "\(Int((block.percent ?? 0).rounded()))%"
    return VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(verbatim: block.label ?? "").font(AssistantType.body).foregroundStyle(p.ink).lineLimit(1)
        Spacer(minLength: 8)
        Text(verbatim: detail).font(AssistantType.figures).foregroundStyle(p.secondary).lineLimit(1)
      }
      Capsule().fill(p.track).frame(height: 6)
        .overlay(alignment: .leading) {
          GeometryReader { bar in Capsule().fill(p.accent).frame(width: bar.size.width * share) }
        }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(block.label ?? "")
    .accessibilityValue(detail)
  }

  private var list: some View {
    let items: [UIBlock.Item] = block.items ?? []
    return VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          if let tone = item.toneValue {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(tint(tone)).frame(width: 7, height: 7)
              .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
              .accessibilityHidden(true)
          } else if block.markerValue == .bullet {
            Text(verbatim: "•").font(AssistantType.body).foregroundStyle(p.faint).accessibilityHidden(true)
          } else if block.markerValue == .number {
            Text(verbatim: "\(index + 1).").font(AssistantType.figures).foregroundStyle(p.faint)
          }
          VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: item.title).font(AssistantType.body).foregroundStyle(p.ink)
              .fixedSize(horizontal: false, vertical: true)
            if let detail = item.detail, !detail.isEmpty {
              Text(verbatim: detail).font(AssistantType.meta).foregroundStyle(p.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          if let value = item.value, !value.isEmpty {
            Text(verbatim: value).font(AssistantType.figures).foregroundStyle(p.secondary).lineLimit(1)
          }
        }
        .accessibilityElement(children: .combine)
      }
    }
  }

  /// Headers in `meta`, cells under them, a hairline between rows. The first column takes the
  /// room that is left; the others are as wide as their words and sit at the trailing edge.
  private var table: some View {
    let rows: [[String]] = block.rows ?? []
    return Grid(alignment: .leading, horizontalSpacing: UITreeMetrics.gap, verticalSpacing: 0) {
      if let headers = block.headers {
        GridRow {
          ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
            cell(header, column: index, font: AssistantType.meta, ink: p.secondary).padding(.bottom, 8)
          }
        }
      }
      ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
        if index > 0 || block.headers != nil {
          Rectangle().fill(p.line).frame(height: UIStyle.hairline).gridCellUnsizedAxes(.horizontal)
        }
        GridRow {
          ForEach(Array(row.enumerated()), id: \.offset) { column, words in
            cell(words, column: column, font: column == 0 ? AssistantType.body : AssistantType.figures, ink: p.ink)
              .padding(.vertical, 8)
          }
        }
      }
    }
  }
  private func cell(_ words: String, column: Int, font: Font, ink: Color) -> some View {
    Text(verbatim: words).font(font).foregroundStyle(ink).lineLimit(2)
      .fixedSize(horizontal: column > 0, vertical: true)
      .frame(maxWidth: column == 0 ? .infinity : nil, alignment: .leading)
      .gridColumnAlignment(column == 0 ? .leading : .trailing)
  }
}

/// A small label in a tone, with an optional dot (affectUI's Badge).
struct UIBadge: View {
  let text: String
  var tone: UIBlock.Tone = .neutral
  var dot: Bool = false
  @Environment(\.palette) private var p

  static func tint(_ tone: UIBlock.Tone, _ p: Palette) -> Color {
    switch tone {
    case .neutral: return p.secondary
    case .accent: return p.accent
    case .success: return p.success
    case .warning: return p.warning
    case .danger: return p.danger
    }
  }

  var body: some View {
    let ink: Color = Self.tint(tone, p)
    HStack(spacing: 5) {
      if dot { Circle().fill(ink).frame(width: 6, height: 6).accessibilityHidden(true) }
      Text(verbatim: text).font(AssistantType.meta).lineLimit(1)
    }
    .foregroundStyle(ink)
    .padding(.vertical, 3).padding(.horizontal, 8)
    .background(ink.opacity(0.12), in: Capsule())
    .fixedSize()
  }
}

/// How a stat moved: an arrow and a few words, in the dashboard card's tones.
private struct UITrend: View {
  let direction: DashboardSpec.Direction
  let text: String
  @Environment(\.palette) private var p

  private var tone: Color {
    switch direction {
    case .up: return p.success
    case .down: return p.danger
    case .flat: return p.secondary
    }
  }
  private var arrow: String {
    switch direction {
    case .up: return "arrow.up.right"
    case .down: return "arrow.down.right"
    case .flat: return "arrow.right"
    }
  }

  var body: some View {
    HStack(spacing: 2) {
      Image(systemName: arrow).font(.system(size: 9, weight: .semibold)).accessibilityHidden(true)
      if !text.isEmpty { Text(verbatim: text).font(AssistantType.meta).lineLimit(1) }
    }
    .foregroundStyle(tone)
    .fixedSize()
  }
}
