import Foundation

/// click_point: a click at a spot in a tab's latest screenshot, for maps, seat plans, charts and
/// drawing canvases where a read offers no element to reference. Every click asks, with the
/// screenshot and the spot marked on the card; nothing remembers the answer, Autopilot is not
/// consulted, and a scheduled run never clicks a point. Each screenshot serves one click.
public enum PointClick {
  /// Where the page was when a screenshot was taken: the document, its viewport and scroll in CSS
  /// pixels, the page version and the host. Equal on both sides of the picture, or no click.
  public struct View: Equatable, Sendable {
    public var document: String
    public var width: Double
    public var height: Double
    public var scrollX: Double
    public var scrollY: Double
    public var pageVersion: String
    public var host: String

    /// PageKit's `view()` plus the tab's own page version and host. Nil when unreadable.
    public init?(_ raw: Any?, pageVersion: String, host: String) {
      guard let raw = raw as? [String: Any], let document = raw["document"] as? String, !document.isEmpty,
        let width = (raw["width"] as? NSNumber)?.doubleValue, let height = (raw["height"] as? NSNumber)?.doubleValue,
        let scrollX = (raw["x"] as? NSNumber)?.doubleValue, let scrollY = (raw["y"] as? NSNumber)?.doubleValue,
        width > 0, height > 0
      else { return nil }
      self.document = document
      self.width = width
      self.height = height
      self.scrollX = scrollX
      self.scrollY = scrollY
      self.pageVersion = pageVersion
      self.host = host.lowercased()
    }
  }

  /// One screenshot as click_point uses it: its size in pixels (the coordinates the agent gives)
  /// and the view it shows. Held in memory for the task only.
  public struct Shot: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var view: View
    public init(width: Int, height: Int, view: View) {
      self.width = width
      self.height = height
      self.view = view
    }

    /// The spot in viewport CSS pixels, or nil when it is not a finite point inside the picture.
    public func spot(x: Double, y: Double) -> (x: Double, y: Double)? {
      guard x.isFinite, y.isFinite, x >= 0, y >= 0, x < Double(width), y < Double(height) else { return nil }
      return (x / Double(width) * view.width, y / Double(height) * view.height)
    }
  }

  /// What PageKit found under the spot: its words for the card (named by the page), a reference
  /// for the gate's reading, and whether it is a real control, which is then clicked as `click`
  /// would. `refused` names why nothing may be clicked there.
  public struct Target: Equatable, Sendable {
    public var ref: String
    public var control: Bool
    public var what: String
    public var refused: String?

    public init?(_ raw: Any?) {
      guard let raw = raw as? [String: Any] else { return nil }
      refused = raw["refused"] as? String
      ref = raw["ref"] as? String ?? ""
      control = raw["control"] as? Bool == true
      what = String((raw["what"] as? String ?? "").components(separatedBy: .controlCharacters.union(.newlines)).joined(separator: " ").prefix(200))
      if refused == nil, ref.isEmpty { return nil }
    }
  }

  /// The largest size no provider scales down (long side ≤ 1568, ≤ 1.15 MP, short side ≤ 768), so
  /// click_point's x and y are pixels the model actually saw.
  public static func agentPixels(width: Int, height: Int) -> (width: Int, height: Int) {
    guard width > 0, height > 0 else { return (width, height) }
    let w = Double(width), h = Double(height)
    let scale = min(1, 1568 / max(w, h), 768 / min(w, h), (1_150_000 / (w * h)).squareRoot())
    return (max(1, Int(w * scale)), max(1, Int(h * scale)))
  }

  /// The stamp the yes is bound to: page version, host, document, viewport, scroll and the words
  /// under the spot. Any of them changing between the screenshot and the press refuses it.
  public static func stamp(_ view: View, what: String) -> String {
    [view.pageVersion, view.host, view.document, "\(view.width)x\(view.height)", "\(view.scrollX),\(view.scrollY)", what]
      .joined(separator: "\u{1f}")
  }

  /// A point is never a routine click: whatever the reading says, it asks as unknown or higher.
  public static func effect(_ rated: ApprovalGate.Effect) -> ApprovalGate.Effect {
    switch rated {
    case .read, .scroll, .navigate, .click, .type: return .unknown
    default: return rated
    }
  }

  /// The card's words. `what` is the page's own description of the element, untrusted and shown
  /// only to the person; `summary` is the gate's readback (ActionAdmission.readback).
  public static func cardTitle(host: String) -> String { "Click here on \(host.isEmpty ? "this page" : host)?" }
  public static func cardDetail(what: String, control: Bool, summary: String) -> String {
    let under = what.isEmpty
      ? "The page does not name what is under this spot."
      : "Under this spot: \(what), as the page names it." + (control ? " Serein clicks that control." : "")
    return under + " Serein checks that the page has not moved or changed before it clicks.\n" + summary
  }
  public static let pictureLabel = "Screenshot of the page with a ring where Serein would click"

  public static let noShot =
    "Take a screenshot of this tab first: click_point uses the coordinates of this task's latest screenshot of the tab, and each screenshot serves one click_point."
  public static let outside = "x and y must be pixels inside the latest screenshot of this tab."
  public static let changed =
    "The page moved, scrolled or changed since the screenshot, so nothing was clicked. Take a new screenshot."
  public static let scheduledMessage =
    "click_point never runs in a scheduled task: every click needs the user there to see the spot and approve it."
  public static let frameMessage =
    "The spot is over a frame. Read that frame and use its references, or pick a spot outside it."
  public static let nothingMessage = "There is nothing to click at that spot. Take a new screenshot."
}
