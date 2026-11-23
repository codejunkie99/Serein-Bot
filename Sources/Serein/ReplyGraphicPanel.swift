import Accessibility
import AppKit
import Charts
import SereinCore
import SwiftUI

/// A chart or diagram from a reply's fenced block (MessageContent), drawn natively in the code
/// panel's frame: no web view, no script, nothing fetched. Under it, the source line says what
/// the turn read, by host or file name and day, or that the model answered from its own knowledge.
struct ReplyGraphicPanel: View {
  let graphic: ReplyGraphic
  /// The block as the reply wrote it, fences included: Copy keeps it.
  let fenced: String
  let read: ReplySources?
  var showsCopyButton = true
  @Environment(\.palette) private var p
  private var kind: String {
    if case .chart = graphic { return "chart" }
    if case .story = graphic { return "story" }
    return "diagram"
  }
  private var title: String? {
    switch graphic {
    case .chart(let chart): return chart.title
    case .diagram(let diagram): return diagram.title
    case .story(let story): return story.title
    }
  }
  var body: some View {
    if case .story(let story) = graphic {
      ReplyStoryCard(story: story, sourceLine: ReplySources.line(read))
    } else {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(verbatim: kind).font(UIStyle.mono(11)).foregroundStyle(p.secondary)
        Spacer()
        CodeCopyButton(text: fenced, label: "Copy \(kind)")
          .opacity(showsCopyButton ? 1 : 0)
          .allowsHitTesting(showsCopyButton)
          .accessibilityHidden(!showsCopyButton)
      }.padding(.leading, 12).padding(.trailing, 5).frame(height: 28)
        .background(p.codeHeader)
      Rectangle().fill(p.line).frame(height: 1)
      VStack(alignment: .leading, spacing: 10) {
        // VoiceOver hears the title in the chart's summary or the diagram's label.
        if let title { Text(verbatim: title).font(UIStyle.bodyStrong).foregroundStyle(p.ink).accessibilityHidden(true) }
        switch graphic {
        case .chart(let chart): ReplyChartView(chart: chart)
        case .diagram(let diagram): ReplyDiagramView(diagram: diagram)
        case .story: EmptyView()
        }
        // No record (a summary, an older chat) claims nothing about what was read.
        if let line = ReplySources.line(read) {
          Text(verbatim: line).font(UIStyle.micro).foregroundStyle(p.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }.padding(.horizontal, 12).padding(.vertical, 10)
    }.background(p.codePanel, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
      .clipShape(RoundedRectangle(cornerRadius: UIStyle.panelRadius))
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct ReplyChartPoint: Identifiable {
  let id: Int
  let label: String
  let series: String
  let seriesIndex: Int
  let value: Double
}

struct ReplyChartView: View {
  let chart: ReplyChart
  @Environment(\.palette) private var p
  private var points: [ReplyChartPoint] {
    chart.series.indices.flatMap { series in
      chart.labels.indices.map { label in
        ReplyChartPoint(id: series * chart.labels.count + label, label: chart.labels[label],
          series: chart.seriesName(series), seriesIndex: series, value: chart.series[series].values[label])
      }
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      plot
        .accessibilityElement(children: .contain)
        .accessibilityLabel(chart.summary)
        .accessibilityChartDescriptor(ReplyChartDescriptor(chart: chart))
      if chart.kind == .pie || chart.series.count > 1 { legend }
    }
  }
  @ViewBuilder private var plot: some View {
    switch chart.kind {
    case .bar:
      Chart(points) { point in
        BarMark(x: .value("Label", point.label), y: .value("Value", point.value))
          .position(by: .value("Series", point.series))
          .foregroundStyle(tint(point.seriesIndex))
          .cornerRadius(2)
          .accessibilityLabel(point.label)
          .accessibilityValue(spoken(point))
      }
      .chartXAxis { labelAxis }
      .chartYAxis { valueAxis }
      .frame(height: 200)
    case .line:
      Chart(points) { point in
        LineMark(x: .value("Label", point.label), y: .value("Value", point.value),
          series: .value("Series", point.series))
          .foregroundStyle(tint(point.seriesIndex))
          .symbol(.circle)
          .accessibilityLabel(point.label)
          .accessibilityValue(spoken(point))
      }
      .chartXAxis { labelAxis }
      .chartYAxis { valueAxis }
      .frame(height: 200)
    case .pie:
      Chart(points) { point in
        SectorMark(angle: .value("Value", point.value), innerRadius: .ratio(0.55), angularInset: 1)
          .foregroundStyle(tint(point.id))
          .accessibilityLabel(point.label)
          .accessibilityValue(spoken(point))
      }
      .frame(height: 180)
    }
  }
  private var labelAxis: some AxisContent {
    AxisMarks { value in
      AxisValueLabel {
        if let label = value.as(String.self) { Text(verbatim: label).font(UIStyle.micro).foregroundStyle(p.secondary) }
      }
    }
  }
  private var valueAxis: some AxisContent {
    AxisMarks(position: .leading) { value in
      AxisGridLine()
      AxisValueLabel {
        if let number = value.as(Double.self) {
          Text(verbatim: number.formatted()).font(UIStyle.microMono).foregroundStyle(p.secondary)
        }
      }
    }
  }
  /// Series (or a pie's slices) take neutral tones and the accent, in both palettes; the legend
  /// names each one, so no tone carries meaning alone.
  private func tint(_ index: Int) -> Color {
    let tones = [p.accent, p.ink.opacity(0.8), p.secondary, p.accent.opacity(0.45), p.faint.opacity(0.6), p.ink.opacity(0.3)]
    return tones[index % tones.count]
  }
  private func spoken(_ point: ReplyChartPoint) -> String {
    let value = ReplyChart.valueText(point.value, unit: chart.unit)
    return chart.series.count > 1 ? point.series + ", " + value : value
  }
  /// The series, or a pie's slices with their values. VoiceOver reads these from the chart.
  private var legend: some View {
    var names: [String] = []
    if chart.kind == .pie {
      for index in chart.labels.indices {
        let value: String = ReplyChart.valueText(chart.series[0].values[index], unit: chart.unit)
        names.append("\(chart.labels[index]) · \(value)")
      }
    } else {
      for index in chart.series.indices { names.append(chart.seriesName(index)) }
    }
    return LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12, alignment: .leading)],
      alignment: .leading, spacing: 4) {
      ForEach(names.indices, id: \.self) { index in
        HStack(spacing: 6) {
          Circle().fill(tint(index)).frame(width: 8, height: 8)
          Text(verbatim: names[index]).font(UIStyle.micro).foregroundStyle(p.secondary)
            .lineLimit(1).truncationMode(.tail)
        }
      }
    }.accessibilityHidden(true)
  }
}

/// The chart for VoiceOver's audio graph and data table: one category per label, each series'
/// values, in the reply's unit.
private struct ReplyChartDescriptor: AXChartDescriptorRepresentable {
  let chart: ReplyChart
  func makeChartDescriptor() -> AXChartDescriptor {
    let values = chart.series.flatMap(\.values)
    let low = min(0, values.min() ?? 0)
    let high = max(values.max() ?? 0, low + 1)
    let unit = chart.unit
    let xAxis = AXCategoricalDataAxisDescriptor(title: "Label", categoryOrder: chart.labels)
    let yAxis = AXNumericDataAxisDescriptor(title: unit ?? "Value", range: low...high, gridlinePositions: [],
      valueDescriptionProvider: { ReplyChart.valueText($0, unit: unit) })
    let series = chart.series.indices.map { index in
      AXDataSeriesDescriptor(name: chart.seriesName(index), isContinuous: chart.kind == .line,
        dataPoints: zip(chart.labels, chart.series[index].values).map { AXDataPoint(x: $0.0, y: $0.1) })
    }
    return AXChartDescriptor(title: chart.title ?? chart.kindName, summary: chart.summary, xAxis: xAxis,
      yAxis: yAxis, additionalAxes: [], series: series)
  }
}

/// A diagram laid out as columns, one per box in order of first mention, with each arrow on its
/// own row in the order written, so a flow and a sequence both read top to bottom.
private struct ReplyDiagramView: View {
  let diagram: ReplyDiagram
  @Environment(\.palette) private var p
  private static let column: CGFloat = 132
  private static let head: CGFloat = 44
  private static let row: CGFloat = 34
  private func x(_ node: Int) -> CGFloat { Self.column * (CGFloat(node) + 0.5) }
  private func y(_ edge: Int) -> CGFloat { Self.head + Self.row * (CGFloat(edge) + 0.5) + 6 }
  private var loops: Bool { diagram.edges.contains { $0.from == $0.to } }
  private var spokenLabel: String {
    let titled: String = diagram.title.map { ", \($0)" } ?? ""
    return "Diagram\(titled), \(diagram.nodes.count) boxes, \(diagram.edges.count) arrows"
  }
  /// An arrow label's centre: right of its box's line for a loop, else between the two boxes.
  private func labelX(_ edge: ReplyDiagram.Edge, loop: Bool, span: CGFloat) -> CGFloat {
    if loop { return x(edge.from) + 26 + span / 2 }
    let sum: CGFloat = x(edge.from) + x(edge.to)
    return sum / 2
  }
  private func labelY(_ index: Int, loop: Bool) -> CGFloat {
    let middle: CGFloat = y(index)
    return loop ? middle : middle - 11
  }
  var body: some View {
    // A loop's label sits right of its box's line, so the last column may need the room.
    let width = Self.column * CGFloat(diagram.nodes.count) + (loops ? Self.column / 2 : 0)
    let height = Self.head + Self.row * CGFloat(diagram.edges.count) + 8
    ScrollView(.horizontal) {
      ZStack(alignment: .topLeading) {
        Canvas { context, _ in draw(&context) }
        ForEach(diagram.nodes.indices, id: \.self) { index in
          Text(verbatim: diagram.nodes[index]).font(UIStyle.metaStrong).foregroundStyle(p.ink)
            .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center)
            .padding(.horizontal, 6)
            .frame(width: Self.column - 16, height: 32)
            .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: UIStyle.controlRadius).stroke(p.borderStrong, lineWidth: UIStyle.hairline))
            .position(x: x(index), y: 18)
        }
        ForEach(diagram.edges.indices, id: \.self) { index in
          if let label = diagram.edges[index].label { edgeLabel(label, edge: index) }
        }
      }.frame(width: width, height: height)
    }.frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(spokenLabel)
      .accessibilityValue(diagram.spoken.joined(separator: ". "))
  }
  private func draw(_ context: inout GraphicsContext) {
    let bottom = Self.head + Self.row * CGFloat(diagram.edges.count)
    for node in diagram.nodes.indices {
      var line = Path()
      line.move(to: CGPoint(x: x(node), y: 34))
      line.addLine(to: CGPoint(x: x(node), y: bottom))
      context.stroke(line, with: .color(p.borderStrong), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }
    for (index, edge) in diagram.edges.enumerated() {
      let rowY = y(index)
      let start = x(edge.from)
      var path = Path()
      if edge.from == edge.to {
        path.move(to: CGPoint(x: start, y: rowY - 8))
        path.addLine(to: CGPoint(x: start + 20, y: rowY - 8))
        path.addLine(to: CGPoint(x: start + 20, y: rowY + 6))
        path.addLine(to: CGPoint(x: start + 8, y: rowY + 6))
        context.stroke(path, with: .color(p.secondary), lineWidth: 1)
        context.fill(arrowhead(CGPoint(x: start + 2, y: rowY + 6), direction: -1), with: .color(p.secondary))
      } else {
        let end = x(edge.to)
        let direction: CGFloat = end > start ? 1 : -1
        path.move(to: CGPoint(x: start, y: rowY))
        path.addLine(to: CGPoint(x: end - direction * 8, y: rowY))
        context.stroke(path, with: .color(p.secondary), lineWidth: 1)
        context.fill(arrowhead(CGPoint(x: end - direction * 2, y: rowY), direction: direction), with: .color(p.secondary))
      }
    }
  }
  private func arrowhead(_ tip: CGPoint, direction: CGFloat) -> Path {
    var path = Path()
    path.move(to: tip)
    path.addLine(to: CGPoint(x: tip.x - direction * 7, y: tip.y - 4))
    path.addLine(to: CGPoint(x: tip.x - direction * 7, y: tip.y + 4))
    path.closeSubpath()
    return path
  }
  private func edgeLabel(_ label: String, edge index: Int) -> some View {
    let edge = diagram.edges[index]
    let loop = edge.from == edge.to
    let span = max(40, loop ? Self.column - 32 : abs(x(edge.to) - x(edge.from)) - 12)
    return Text(verbatim: label).font(UIStyle.micro).foregroundStyle(p.secondary)
      .lineLimit(1).truncationMode(.tail)
      .frame(width: span, alignment: loop ? .leading : .center)
      .position(x: labelX(edge, loop: loop, span: span), y: labelY(index, loop: loop))
  }
}
