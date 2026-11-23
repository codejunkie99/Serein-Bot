import Foundation

/// A chart or diagram fenced in a reply (```chart or ```diagram), drawn natively by the app.
/// The block is the model's text, so it is untrusted: it is bounded and checked here, and
/// anything that does not pass stays a plain code block.
public enum ReplyGraphic: Equatable, Sendable {
  case chart(ReplyChart)
  case diagram(ReplyDiagram)
  case story(ReplyStory)

  /// The fence's language picks the format; nil for any other block or for invalid input.
  public init?(language: String?, source: String) {
    switch language?.lowercased() {
    case "chart": guard let chart = ReplyChart(json: source) else { return nil }; self = .chart(chart)
    case "diagram": guard let diagram = ReplyDiagram(text: source) else { return nil }; self = .diagram(diagram)
    case "story": guard let story = ReplyStory(json: source) else { return nil }; self = .story(story)
    default: return nil
    }
  }
}

/// `{"kind":"bar|line|pie","title":String?,"labels":[String],"series":[{"name":String?,"values":[Number]}],"unit":String?}`
/// Every prompt that offers a chart names exactly this shape (ReplyGraphicPrompt).
public struct ReplyChart: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case bar, line, pie }
  public struct Series: Codable, Equatable, Sendable {
    public var name: String?
    public var values: [Double]
  }
  public var kind: Kind
  public var title: String?
  public var labels: [String]
  public var series: [Series]
  public var unit: String?

  /// Labels × series; more falls back to the code block.
  public static let maxPoints = 200
  /// A pie's slices: the legend's tones stay distinct up to this many.
  public static let maxSlices = 6
  static let maxSource = 32_000
  static let maxCharacters = 80

  public init?(json: String) {
    guard json.utf8.count <= Self.maxSource,
      let chart = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)), chart.valid
    else { return nil }
    self = chart
  }

  /// A decoded chart that can be drawn (`ui_show`'s chart block checks it too).
  public var isValid: Bool { valid }
  private var valid: Bool {
    let names: [String] = series.indices.map { seriesName($0) }
    let values: [Double] = series.flatMap { $0.values }
    var texts: [String] = labels
    texts.append(contentsOf: names)
    texts.append(title ?? "")
    texts.append(unit ?? "")
    guard !labels.isEmpty, !series.isEmpty, labels.count * series.count <= Self.maxPoints,
      series.allSatisfy({ $0.values.count == labels.count }), values.allSatisfy({ $0.isFinite }),
      Set(labels).count == labels.count, Set(names).count == names.count,
      texts.allSatisfy({ $0.count <= Self.maxCharacters })
    else { return false }
    // A pie is one series of shares: none below zero, something to share, and few enough slices
    // that no two share a tone.
    if kind == .pie {
      let total: Double = values.reduce(0, +)
      return series.count == 1 && labels.count <= Self.maxSlices && values.allSatisfy({ $0 >= 0 }) && total > 0
    }
    return true
  }

  /// A series' name, or a plain stand-in when the model gave none.
  public func seriesName(_ index: Int) -> String {
    if let name = series[index].name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
    return series.count == 1 ? (unit ?? "Value") : "Series \(index + 1)"
  }

  public var kindName: String {
    switch kind {
    case .bar: return "Bar chart"
    case .line: return "Line chart"
    case .pie: return "Pie chart"
    }
  }

  public static func valueText(_ value: Double, unit: String?) -> String {
    let number = value.formatted()
    guard let unit, !unit.isEmpty else { return number }
    return unit == "%" ? number + unit : number + " " + unit
  }

  /// VoiceOver's summary: the kind, the title and each series' lowest and highest value.
  public var summary: String {
    let titled: String = title.map { ", \($0)" } ?? ""
    var parts: [String] = ["\(kindName)\(titled)"]
    for index in series.indices {
      let pairs = zip(labels, series[index].values)
      guard let low = pairs.min(by: { $0.1 < $1.1 }), let high = pairs.max(by: { $0.1 < $1.1 }) else { continue }
      parts.append("\(seriesName(index)): lowest \(Self.valueText(low.1, unit: unit)) at \(low.0), highest \(Self.valueText(high.1, unit: unit)) at \(high.0)")
    }
    return parts.joined(separator: ". ") + "."
  }
}

/// Our own small grammar: one `A -> B: label` line per arrow (the label is optional) and an
/// optional `title: …` line. Any other line makes the block a plain code block.
public struct ReplyDiagram: Equatable, Sendable {
  public struct Edge: Equatable, Sendable {
    public var from: Int
    public var to: Int
    public var label: String?
  }
  public var title: String?
  /// In order of first mention.
  public var nodes: [String]
  public var edges: [Edge]

  public static let maxNodes = 40
  public static let maxEdges = 200
  static let maxCharacters = 80

  public init?(text: String) {
    guard text.utf8.count <= 32_000 else { return nil }
    var title: String?
    var nodes: [String] = []
    var edges: [Edge] = []
    func node(_ name: String) -> Int {
      if let index = nodes.firstIndex(of: name) { return index }
      nodes.append(name)
      return nodes.count - 1
    }
    for raw in text.components(separatedBy: "\n") {
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty { continue }
      if let arrow = line.range(of: "->") {
        let from = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        let rest = line[arrow.upperBound...]
        let colon = rest.firstIndex(of: ":")
        let to = rest[..<(colon ?? rest.endIndex)].trimmingCharacters(in: .whitespaces)
        let label = colon.map { rest[rest.index(after: $0)...].trimmingCharacters(in: .whitespaces) }
        guard !from.isEmpty, !to.isEmpty, !to.contains("->"), from.count <= Self.maxCharacters,
          to.count <= Self.maxCharacters, (label?.count ?? 0) <= Self.maxCharacters
        else { return nil }
        edges.append(Edge(from: node(from), to: node(to), label: label?.isEmpty == false ? label : nil))
        guard nodes.count <= Self.maxNodes, edges.count <= Self.maxEdges else { return nil }
      } else if title == nil, line.lowercased().hasPrefix("title:") {
        let words = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        guard words.count <= Self.maxCharacters else { return nil }
        title = words.isEmpty ? nil : words
      } else {
        return nil
      }
    }
    guard !edges.isEmpty else { return nil }
    self.title = title
    self.nodes = nodes
    self.edges = edges
  }

  /// Each arrow as VoiceOver reads it, in order: "Browser to Server: request".
  public var spoken: [String] {
    edges.map { (edge: Edge) -> String in
      let target: String = edge.from == edge.to ? "itself" : nodes[edge.to]
      let label: String = edge.label.map { ": \($0)" } ?? ""
      return "\(nodes[edge.from]) to \(target)\(label)"
    }
  }
}

/// The sites and files a turn read, by host or file name, and the day it read them: the
/// source line under a chart or diagram in its reply. Never page text.
public struct ReplySources: Codable, Equatable, Sendable {
  public static let limit = 20
  public var names: [String] = []
  /// Names past `limit`, counted so the line still says how many.
  public var more = 0
  public var day = Date()
  public init(day: Date = Date()) { self.day = day }

  public mutating func add(_ raw: String) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = trimmed.hasPrefix("www.") ? String(trimmed.dropFirst(4)) : trimmed
    guard !name.isEmpty, !names.contains(name) else { return }
    if names.count < Self.limit { names.append(name) } else { more += 1 }
  }

  /// "From example.com and data.csv, read today", or that no new external sources were read when the turn's
  /// record shows none. nil when there is no record (a summary, an older chat, a
  /// linked session's reply): what that turn read is unknown, so nothing is claimed.
  public static func line(_ sources: ReplySources?, now: Date = Date(), calendar: Calendar = .current) -> String? {
    guard let sources else { return nil }
    if sources.names.isEmpty && sources.more == 0 { return "No new external sources were read for this reply." }
    let shown = Array(sources.names.prefix(3))
    let rest = sources.names.count - shown.count + sources.more
    let list: String
    if rest > 0 {
      list = shown.joined(separator: ", ") + " and \(rest) more"
    } else if shown.count == 1 {
      list = shown[0]
    } else {
      list = shown.dropLast().joined(separator: ", ") + " and " + shown[shown.count - 1]
    }
    let when = calendar.isDate(sources.day, inSameDayAs: now)
      ? "read today" : "read on " + sources.day.formatted(date: .abbreviated, time: .omitted)
    return "From \(list), \(when)"
  }

  /// A page with password, one-time-code or card fields is named only this way, never by host.
  public static let privatePage = "a page"

  /// What a turn's context chips hand the model, as PageContext.render sends it: the hosts of
  /// the pages (at most `maxTabs`, only with their words), a selection with text and the pointed
  /// elements, and the names of attached documents.
  public static func carried(_ turn: PageContext.Turn) -> ReplySources? {
    var read = ReplySources()
    var pages: [PageContext.Page] = []
    if let page = turn.page { pages.append(page) }
    pages.append(contentsOf: turn.tabs)
    for page in pages.prefix(PageContext.maxTabs) where !page.unavailable && !page.text.isEmpty {
      if page.sensitive {
        read.add(privatePage)
      } else if let host = URL(string: page.url)?.host {
        read.add(host)
      }
    }
    if let selection = turn.selection, !selection.text.isEmpty, let host = URL(string: selection.url)?.host {
      read.add(host)
    }
    // A sensitive element keeps only its position and styles, never its words.
    for element in turn.elements.prefix(PageContext.maxElements) where !element.sensitive {
      if let host = URL(string: element.url)?.host { read.add(host) }
    }
    for document in turn.documents { read.add(document.name) }
    return read.names.isEmpty ? nil : read
  }

  /// The host of the page a browser tool's result carries words from (`privatePage` for a page
  /// with password or card fields); nil for any other result, including an empty one.
  public static func readHost(_ page: [String: Any]) -> String? {
    let words: String = page["text"] as? String ?? page["text_untrusted"] as? String ?? page["body"] as? String ?? ""
    guard !words.isEmpty, let address = page["url"] as? String ?? page["address"] as? String,
      let host = URL(string: address)?.host, !host.isEmpty
    else { return nil }
    return page["sensitive"] as? Bool == true ? privatePage : host
  }

  /// What a harness step's past-tense line says it read (RunActivity.done): a file's name for
  /// "Read Sources/App.swift", the host for a fetch's "Read example.com"; nil for other steps.
  public static func readName(tool: String, done: String) -> String? {
    switch tool {
    case "read":
      guard done.hasPrefix("Read ") else { return nil }
      let target = String(done.dropFirst(5))
      return target == "files" || target == "a file" ? "a file" : URL(fileURLWithPath: target).lastPathComponent
    case "search": return "a file search"
    case "web":
      if done.hasPrefix("Searched the web") { return "a web search" }
      // Other harnesses' fetches and searches arrive as "Used the web", with no address.
      guard done.hasPrefix("Read ") else { return "a web page" }
      let host = String(done.dropFirst(5))
      return host == "a page" ? "a web page" : host
    default: return nil
    }
  }
}

/// The two block formats, in the assistant's stable prompt.
public enum ReplyGraphicPrompt {
  public static let relay = "For a dense answer, an explanation or a result that is hard to follow, use the installed explain-visually skill: read it with skill_read and choose the simplest useful format. Use plain text when a visual would add no value. Serein renders validated chart, diagram and story fences natively; the skill contains their formats. Preserve the person's requested format and keep uncertainty visible."
}
