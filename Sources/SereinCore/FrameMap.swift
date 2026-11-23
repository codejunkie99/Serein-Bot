import Foundation

/// One map of a page: a whole-page read lists the controls of the page's visible child frames
/// (a sign-in box, a booking widget, an embedded form) after its own, each row with the frame it
/// is in and that frame's site. Actions already route a reference to its frame, so these rows are
/// usable as they are. Before, the agent had to read each frame by its id. Pure, so the checks run
/// it without a browser.
///
/// A frame adds no rows when it holds the user's own fields (sensitive, user steps) or a
/// verification check. A frame with the user's fields is named in `frame_steps` with its steps,
/// so the agent leaves it to the user and goes on with the rest of the page; the page's own
/// `sensitive` and `user_steps` stay the main document's, as before (the host's fail-closed
/// checks probe every frame separately). Only rows with a reference come in: a frame's file field
/// (no reference) stays in that frame's own read.
public enum FrameMap {
  /// The most child frames that add rows to one read.
  public static let frameLimit = 8
  /// The most rows all child frames add to one read.
  public static let rowLimit = 150
  /// The most child frames read for one page, visible or not.
  public static let readLimit = 16
  /// The longest a page read spends on its child frames, in seconds.
  public static let readBudget: TimeInterval = 1
  /// A frame smaller than this (CSS pixels) is a tracker or a hidden frame: its rows stay out.
  public static let smallest = (width: 40, height: 20)

  /// A child frame's own read (PageKit `read`), with the frame's id and site from WebKit.
  public struct Child {
    public let id: String
    public let site: String
    public let page: [String: Any]
    public init(id: String, site: String, page: [String: Any]) {
      self.id = id
      self.site = site
      self.page = page
    }
  }

  /// Told to the agent with `frame_steps`.
  public static let frameStepsNote =
    "These frames hold the user's own fields (passwords, card details, codes). Their controls are not listed: leave them to the user and go on with the rest of the page."

  /// The page with its children's rows, the frames that hold the user's fields, and the summed
  /// redaction counts. The page's own text, notes and rows are unchanged.
  public static func merge(_ page: [String: Any], children: [Child]) -> [String: Any] {
    var page = page
    var rows = page["elements"] as? [[String: Any]] ?? []
    var frameSteps: [[String: Any]] = []
    var counts = redaction(page)
    var added = 0
    var framesAdded = 0
    for child in children {
      let own = redaction(child.page)
      counts.inspected += own.inspected
      counts.withheld += own.withheld
      // A hidden frame (a tracker, a sign-in helper) shows the person nothing: no rows, no note.
      guard isVisible(child.page) else { continue }
      let childSteps = child.page["user_steps"] as? [String] ?? []
      if child.page["sensitive"] as? Bool == true || !childSteps.isEmpty {
        frameSteps.append(["frame": child.id, "site": child.site, "steps": childSteps])
        continue
      }
      guard !hasChallenge(child.page), framesAdded < frameLimit, added < rowLimit, page["elements"] != nil
      else { continue }
      var took = 0
      for row in child.page["elements"] as? [[String: Any]] ?? [] {
        guard added < rowLimit else { break }
        guard row["ref"] is String else { continue }
        var row = row.filter { $0.key != "x" && $0.key != "y" }
        row["frame"] = child.id
        row["site"] = child.site
        rows.append(row)
        added += 1
        took += 1
      }
      if took > 0 { framesAdded += 1 }
    }
    if page["elements"] != nil { page["elements"] = rows }
    if !frameSteps.isEmpty {
      page["frame_steps"] = frameSteps
      page["frame_steps_note"] = frameStepsNote
    }
    page["redaction"] = ["inspected": counts.inspected, "withheld": counts.withheld]
    page["viewport"] = nil
    page["shown_frames"] = nil
    return page
  }

  /// How many frames the top document shows at a usable size (PageKit `shown_frames`). With none,
  /// no child frame is read, so a page without visible frames costs nothing more.
  public static func shownFrames(_ page: [String: Any]) -> Int { int(page["shown_frames"]) ?? 0 }

  /// PageKit's counts of the controls a read looked at and the user's own it left out.
  static func redaction(_ page: [String: Any]) -> (inspected: Int, withheld: Int) {
    let counts = page["redaction"] as? [String: Any] ?? [:]
    return (int(counts["inspected"]) ?? 0, int(counts["withheld"]) ?? 0)
  }

  /// A number from a page read: NSNumber from WebKit, Int from the checks.
  static func int(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? Double, value.isFinite { return Int(value) }
    return (value as? NSNumber)?.intValue
  }

  static func hasChallenge(_ page: [String: Any]) -> Bool {
    guard let challenge = page["challenge"] else { return false }
    return !(challenge is NSNull)
  }

  /// The frame's own window size (PageKit `viewport`). A read with no size counts as hidden.
  public static func isVisible(_ page: [String: Any]) -> Bool {
    guard let size = page["viewport"] as? [Any], size.count == 2, let width = int(size[0]), let height = int(size[1])
    else { return false }
    return width >= smallest.width && height >= smallest.height
  }
}
