import SwiftUI

/// Gesture-driven tab reordering in the sidebar and horizontal band.
///
/// Item-provider drags (`onDrag`/`onDrop`) never began a usable drag session in the packaged app's
/// button rows, so reordering uses an in-process `DragGesture`: the dragged row follows the
/// cursor, neighbouring rows make room, and an insertion line marks the drop gap. Release commits
/// through `BrowserModel.moveTab`, so persistence stays on the tested path.
enum SidebarTabDragMath {
  /// Insertion gap among the other rows: how many resting midpoints the dragged midpoint passed.
  static func gap(draggedMid: CGFloat, otherMids: [CGFloat]) -> Int {
    otherMids.filter { draggedMid > $0 }.count
  }
  /// Visual offset of a resting row while `sourceIndex` is dragged toward `othersGap`.
  static func shift(index: Int, sourceIndex: Int, othersGap: Int, pitch: CGFloat) -> CGFloat {
    if index == sourceIndex { return 0 }
    if index < sourceIndex { return index >= othersGap ? pitch : 0 }
    return index - 1 < othersGap ? -pitch : 0
  }
  /// The list with the source re-inserted at the gap.
  static func reordered(ids: [String], sourceIndex: Int, othersGap: Int) -> [String] {
    var others = ids
    let source = others.remove(at: sourceIndex)
    others.insert(source, at: min(max(othersGap, 0), others.count))
    return others
  }
  /// A committed order as the model's `(target, after)` insertion: after the new predecessor,
  /// or before the first row when the source leads.
  static func insertionTarget(order: [String], sourceID: String) -> (target: String, after: Bool)? {
    guard order.count > 1, let position = order.firstIndex(of: sourceID) else { return nil }
    return position > 0 ? (order[position - 1], true) : (order[1], false)
  }
}

struct SidebarTabDragState: Equatable {
  static let coordinateSpace = "serein.sidebar.tablist"
  var id: String
  var sourceIndex: Int
  var othersGap: Int
  var translation: CGFloat
}

/// Resting frames of the draggable rows, in `SidebarTabDragState.coordinateSpace`.
struct SidebarTabFrameKey: PreferenceKey {
  static var defaultValue: [String: CGRect] { [:] }
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
  }
}

/// Per-row reorder presentation and gesture forwarding, built by the list.
struct SidebarReorderControls {
  var axis: Axis = .vertical
  var shift: CGFloat = 0
  var dragged = false
  var indicator: Edge? = nil
  var id: String
  var onChanged: (CGFloat) -> Void
  var onEnded: () -> Void
}

struct SidebarReorderModifier: ViewModifier {
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var controls: SidebarReorderControls

  private var indicatorAlignment: Alignment {
    if controls.axis == .horizontal { return controls.indicator == .leading ? .leading : .trailing }
    return controls.indicator == .top ? .top : .bottom
  }

  func body(content: Content) -> some View {
    content
      .overlay(alignment: indicatorAlignment) {
        if controls.indicator != nil, !controls.dragged {
          Capsule().fill(p.accent)
            .frame(width: controls.axis == .horizontal ? 2 : nil,
              height: controls.axis == .vertical ? 2 : nil)
            .padding(controls.axis == .horizontal ? .vertical : .horizontal, 2)
            .offset(x: controls.axis == .horizontal ? (controls.indicator == .leading ? -1 : 1) : 0,
              y: controls.axis == .vertical ? (controls.indicator == .top ? -1 : 1) : 0)
            .allowsHitTesting(false).accessibilityHidden(true)
        }
      }
      .offset(x: controls.axis == .horizontal ? controls.shift : 0,
        y: controls.axis == .vertical ? controls.shift : 0)
      .scaleEffect(controls.dragged ? 1.02 : 1)
      .shadow(color: controls.dragged ? p.shadow(0.38) : .clear, radius: 12, y: 5)
      .zIndex(controls.dragged ? 1 : 0)
      .animation(
        controls.dragged || reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.86),
        value: controls.shift
      )
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: controls.dragged)
      .background {
        GeometryReader { geometry in
          Color.clear.preference(
            key: SidebarTabFrameKey.self,
            value: [controls.id: geometry.frame(in: .named(SidebarTabDragState.coordinateSpace))])
        }
      }
      // Takes the drag before the row's Button consumes the mouse gesture; a stationary click
      // still belongs to the button, movement starts reordering.
      .highPriorityGesture(
        DragGesture(minimumDistance: 3, coordinateSpace: .named(SidebarTabDragState.coordinateSpace))
          .onChanged {
            controls.onChanged(controls.axis == .horizontal ? $0.translation.width : $0.translation.height)
          }
          .onEnded { _ in controls.onEnded() })
  }
}

/// Drag state for one list of rows: call `changed` from each row's gesture and `commit` on release.
@MainActor final class SidebarTabDragController: ObservableObject {
  let axis: Axis
  @Published var drag: SidebarTabDragState?
  /// Read only when a drag starts. Not published: it changes on every layout pass (a resize, a tab
  /// that opens or closes), and each change would redraw every row.
  var rowFrames: [String: CGRect] = [:]
  private var dragFrames: [String: CGRect] = [:]
  private var dragOrder: [String] = []
  /// The drag went to the Assistants list (AssistantDrop), so the rest of it moves nothing here.
  private var handedOff = false

  init(axis: Axis = .vertical) { self.axis = axis }

  func controls(
    id: String, index: Int, ids: [String], pitch: CGFloat, commit: @escaping (String, String, Bool) -> Void
  ) -> SidebarReorderControls {
    var shift: CGFloat = 0
    var indicator: Edge? = nil
    let dragged = drag?.id == id
    if let state = drag {
      if dragged {
        shift = state.translation
      } else {
        shift = SidebarTabDragMath.shift(
          index: index, sourceIndex: state.sourceIndex, othersGap: state.othersGap, pitch: pitch)
        let collapsed = index < state.sourceIndex ? index : index - 1
        if collapsed == state.othersGap {
          indicator = axis == .horizontal ? .leading : .top
        } else if collapsed == state.othersGap - 1 {
          indicator = axis == .horizontal ? .trailing : .bottom
        }
      }
    }
    return SidebarReorderControls(
      axis: axis, shift: shift, dragged: dragged, indicator: indicator, id: id,
      onChanged: { [weak self] translation in
        self?.changed(id: id, index: index, ids: ids, pitch: pitch, translation: translation)
      },
      onEnded: { [weak self] in self?.commit(ids: ids, perform: commit) })
  }

  private func changed(id: String, index: Int, ids: [String], pitch: CGFloat, translation: CGFloat) {
    guard !handedOff else { return }
    if drag?.id != id {
      // Frames are captured before any row is offset, so the snapshot holds resting positions.
      guard ids.indices.contains(index), rowFrames[id] != nil else { return }
      drag = SidebarTabDragState(id: id, sourceIndex: index, othersGap: index, translation: translation)
      dragFrames = rowFrames
      dragOrder = ids
    }
    guard var state = drag, ids == dragOrder, let draggedFrame = dragFrames[id] else { return }
    let sourceMid = axis == .horizontal ? draggedFrame.midX : draggedFrame.midY
    let draggedMid = sourceMid + translation
    let otherMids = ids.enumerated().compactMap { offset, other -> CGFloat? in
      guard offset != state.sourceIndex else { return nil }
      // Rows without a captured frame still occupy a slot one pitch apart.
      let frame = dragFrames[other]
      let midpoint = axis == .horizontal ? frame?.midX : frame?.midY
      return midpoint ?? sourceMid + CGFloat(offset - state.sourceIndex) * pitch
    }
    state.translation = translation
    state.othersGap = SidebarTabDragMath.gap(draggedMid: draggedMid, otherMids: otherMids)
    drag = state
  }

  /// The sidebar sprang to Assistants under this drag: the row goes back to rest and the release
  /// reorders nothing.
  func letGo() {
    reset()
    handedOff = true
  }

  /// Drops a drag whose list changed underneath it (a tab closed or opened).
  func cancelIfStale(ids: [String]) {
    guard drag != nil, ids != dragOrder else { return }
    reset()
  }

  private func commit(ids: [String], perform: (String, String, Bool) -> Void) {
    defer { reset() }
    guard !handedOff, let state = drag, ids == dragOrder, ids.indices.contains(state.sourceIndex),
      ids[state.sourceIndex] == state.id
    else { return }
    let order = SidebarTabDragMath.reordered(
      ids: ids, sourceIndex: state.sourceIndex, othersGap: state.othersGap)
    guard order != ids,
      let (target, after) = SidebarTabDragMath.insertionTarget(order: order, sourceID: state.id)
    else { return }
    perform(state.id, target, after)
  }

  private func reset() {
    handedOff = false
    drag = nil
    dragFrames = [:]
    dragOrder = []
  }
}
