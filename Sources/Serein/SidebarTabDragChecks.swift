#if DEBUG
import Foundation

@MainActor func checkSidebarTabDrag() {
  func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assert(condition(), "Sidebar tab drag check failed: \(message)")
  }
  // Gap counting from resting midpoints along the drag axis.
  check(SidebarTabDragMath.gap(draggedMid: 40, otherMids: [15, 45, 75]) == 1, "a midpoint between rows opens the next gap")
  check(SidebarTabDragMath.gap(draggedMid: 5, otherMids: [15, 45]) == 0, "a midpoint above every row opens the first gap")
  check(SidebarTabDragMath.gap(draggedMid: 400, otherMids: [15, 45]) == 2, "a midpoint below every row opens the last gap")
  // Row shifts while another row is dragged.
  let pitch: CGFloat = 31
  check(SidebarTabDragMath.shift(index: 0, sourceIndex: 1, othersGap: 1, pitch: pitch) == 0, "rows before the insertion point stay put")
  check(SidebarTabDragMath.shift(index: 2, sourceIndex: 0, othersGap: 2, pitch: pitch) == -pitch, "rows between the source and a later gap move up")
  check(SidebarTabDragMath.shift(index: 1, sourceIndex: 2, othersGap: 0, pitch: pitch) == pitch, "rows before the source move down when the gap leads")
  check(SidebarTabDragMath.shift(index: 1, sourceIndex: 1, othersGap: 0, pitch: pitch) == 0, "the dragged row tracks the cursor instead of shifting")
  // Committed orders and their (target, after) expression.
  check(SidebarTabDragMath.reordered(ids: ["a", "b", "c"], sourceIndex: 0, othersGap: 2) == ["b", "c", "a"], "a leading source reinserts after the last other row")
  check(SidebarTabDragMath.reordered(ids: ["a", "b", "c"], sourceIndex: 2, othersGap: 0) == ["c", "a", "b"], "a trailing source reinserts before the first other row")
  check(SidebarTabDragMath.reordered(ids: ["a", "b", "c"], sourceIndex: 1, othersGap: 1) == ["a", "b", "c"], "an unchanged gap commits the original order")
  let moved = SidebarTabDragMath.reordered(ids: ["a", "b", "c"], sourceIndex: 0, othersGap: 1)
  check(moved == ["b", "a", "c"], "a mid-list source reinserts at the gap")
  let mid = SidebarTabDragMath.insertionTarget(order: moved, sourceID: "a")
  check(mid?.target == "b" && mid?.after == true, "a mid-list insert targets its new predecessor with after enabled")
  let lead = SidebarTabDragMath.insertionTarget(order: ["c", "a", "b"], sourceID: "c")
  check(lead?.target == "a" && lead?.after == false, "a leading insert targets the first other row with after disabled")
  check(SidebarTabDragMath.insertionTarget(order: ["a"], sourceID: "a") == nil, "a single-row list has no insertion target")
  // Exercise the callbacks used by real button rows, including a scrolled horizontal strip.
  let horizontal = SidebarTabDragController(axis: .horizontal)
  let rowIDs = ["a", "b", "c"]
  horizontal.rowFrames = [
    "a": CGRect(x: -140, y: 0, width: 140, height: 32),
    "b": CGRect(x: 2, y: 0, width: 140, height: 32),
    "c": CGRect(x: 144, y: 0, width: 140, height: 32),
  ]
  var committed: (String, String, Bool)?
  func horizontalControls(_ index: Int) -> SidebarReorderControls {
    horizontal.controls(id: rowIDs[index], index: index, ids: rowIDs, pitch: 142,
      commit: { committed = ($0, $1, $2) })
  }
  horizontalControls(0).onChanged(290)
  check(horizontal.drag?.othersGap == 2, "horizontal movement passes x midpoints despite equal y midpoints")
  check(horizontalControls(0).shift == 290, "the horizontal source follows the pointer")
  check(horizontalControls(1).shift == -142, "horizontal neighbours leave room for the source")
  check(horizontalControls(2).indicator == .trailing, "a final horizontal gap has a trailing indicator")
  // Preference updates during a drag must not replace the captured resting positions.
  horizontal.rowFrames["c"] = CGRect(x: 1000, y: 0, width: 140, height: 32)
  horizontalControls(0).onChanged(290)
  check(horizontal.drag?.othersGap == 2, "geometry changes preserve the resting-frame snapshot")
  horizontalControls(0).onEnded()
  check(committed?.0 == "a" && committed?.1 == "c" && committed?.2 == true,
    "horizontal release inserts after the last neighbour")
  check(horizontal.drag == nil, "release clears drag presentation")
  committed = nil
  horizontalControls(2).onChanged(-1300)
  check(horizontal.drag?.othersGap == 0, "a reverse drag reaches the leading gap")
  check(horizontalControls(0).indicator == .leading, "a first horizontal gap has a leading indicator")
  horizontalControls(2).onEnded()
  check(committed?.0 == "c" && committed?.1 == "a" && committed?.2 == false,
    "reverse release inserts before the first neighbour")
  committed = nil
  horizontalControls(1).onChanged(3)
  horizontalControls(1).onEnded()
  check(committed == nil, "a small drag within the same gap leaves the model alone")
  horizontalControls(0).onChanged(290)
  horizontal.cancelIfStale(ids: ["a", "c"])
  horizontalControls(0).onEnded()
  check(horizontal.drag == nil && committed == nil, "a changed visible list cancels without moving a tab")
  let vertical = SidebarTabDragController()
  vertical.rowFrames = [
    "a": CGRect(x: 0, y: 0, width: 200, height: 30),
    "b": CGRect(x: 0, y: 32, width: 200, height: 30),
    "c": CGRect(x: 0, y: 64, width: 200, height: 30),
  ]
  let verticalSource = vertical.controls(id: "c", index: 2, ids: rowIDs, pitch: 32,
    commit: { committed = ($0, $1, $2) })
  verticalSource.onChanged(-70)
  check(vertical.drag?.othersGap == 0, "sidebar movement still uses y midpoints")
  verticalSource.onEnded()
  check(committed?.0 == "c" && committed?.1 == "a" && committed?.2 == false,
    "sidebar release keeps its existing insertion behavior")
  // The model move reproduces the committed order and leaves folded tabs where they were.
  let browser = try! BrowserModel(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
  for address in ["https://a.example/", "https://b.example/", "https://c.example/"] {
    let tab = BrowserTab()
    tab.address = address
    browser.tabs.append(tab)
  }
  let ids = browser.tabs.map(\.id)
  check(browser.moveTab(ids[0], to: ids[1], after: true), "moving after a neighbour succeeds")
  check(browser.tabs.map(\.id) == [ids[1], ids[0], ids[2]], "the moved tab follows its target")
  check(browser.moveTab(ids[2], to: ids[1], after: false), "moving before the first row succeeds")
  check(browser.tabs.map(\.id) == [ids[2], ids[1], ids[0]], "the moved tab precedes its target")
  check(!browser.moveTab(ids[0], to: "missing", after: true), "an unknown target moves nothing")
  check(browser.tabs.map(\.id) == [ids[2], ids[1], ids[0]], "a failed move leaves the order intact")
  // Tab groups' order: the named tabs first, the others after them in their own order.
  browser.arrangeTabs([ids[0], "missing", ids[2]])
  check(browser.tabs.map(\.id) == [ids[0], ids[2], ids[1]], "arranging keeps every tab and puts the named ones first")
}
#endif
