import SwiftUI

/// Chips that wrap onto the next line when a row is full.
struct FlowChips<Item: Hashable, Chip: View>: View {
  var items: [Item]
  @ViewBuilder var chip: (Item) -> Chip
  var body: some View {
    FlowLayout(spacing: 4) {
      ForEach(items, id: \.self) { chip($0) }
    }
  }
}
/// A left-to-right flow of subviews, wrapping at the proposed width.
struct FlowLayout: Layout {
  var spacing: CGFloat = 4
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
      widest = max(widest, x - spacing)
    }
    return CGSize(width: min(widest, proposal.width ?? widest), height: y + rowHeight)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX {
        x = bounds.minX
        y += rowHeight + spacing
        rowHeight = 0
      }
      view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}
