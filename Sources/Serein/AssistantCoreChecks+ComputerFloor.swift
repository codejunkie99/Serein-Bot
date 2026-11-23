#if DEBUG
import SereinCore

extension AssistantCoreChecks {
  static func computerCheckout(_ check: Check) throws {
    for layout in ["document", "panel", "separate panels"] {
      for (labels, pays) in [(["USD", "19.99"], true), (["19.99", "€"], true),
                             (["Total USD", "", "19.99"], true),
                             (["Step 3", "Try it free"], false), (["Step 3 Try it free"], false)] {
        var rows: [DriverCalls.Row] = []
        func add(_ role: String, _ label: String, parent: Int?) -> Int {
          let i = rows.count
          rows.append(.init(depth: parent.map { rows[$0].depth + 1 } ?? 0, role: role, label: label,
                            frame: nil, index: i, parent: parent))
          return i
        }
        let document = add("document", "", parent: nil)
        let group = layout == "panel" ? add("panel", "", parent: document) : document
        for label in labels {
          let holder = layout == "separate panels" ? add("panel", "", parent: group) : group
          _ = add("label", label, parent: holder)
        }
        let button = add("push button", "Continue", parent: document)
        let read = FreshRead(pid: 1, window: 1, rows: rows, cut: false)
        let stop = BoxFloor.judge(press: button, in: read)?.stop
        try check(stop == (pays ? .askPerson(.pay) : nil), "Checkout press with \(labels) under \(layout)")
      }
    }
  }
  static func computerImageChallenge(_ check: Check) throws {
    for illustration in [true, false] {
      var rows = [DriverCalls.Row(depth: 0, role: "document", label: "", frame: nil, index: 0)]
      if illustration {
        rows.append(.init(depth: 1, role: "article", label: "", frame: nil, index: 1, parent: 0))
      }
      let picture = rows.count
      rows.append(.init(depth: illustration ? 2 : 1, role: "image", label: illustration ? "CAPTCHA example" : "CAPTCHA",
                        frame: nil, index: picture, parent: illustration ? 1 : 0))
      let field = rows.count
      rows.append(.init(depth: 1, role: "entry", label: illustration ? "Feedback" : "Answer",
                        frame: nil, index: field, parent: 0))
      let button = rows.count
      rows.append(.init(depth: 1, role: "push button", label: illustration ? "Send feedback" : "New image",
                        frame: nil, index: button, parent: 0))
      let verify = rows.count
      rows.append(.init(depth: 1, role: "push button", label: "Verify", frame: nil, index: verify, parent: 0))
      let read = FreshRead(pid: 1, window: 1, rows: rows, cut: false)
      for index in [picture, field, button, verify] {
        let stop = BoxFloor.judge(press: index, in: read)?.stop
        try check(stop == (illustration ? nil : .askPerson(.personOnly(.captcha))),
                  "CAPTCHA handoff on \(rows[index].role), illustration=\(illustration)")
      }
    }
    let separateForms: [DriverCalls.Row] = [
      .init(depth: 0, role: "document", label: "", frame: nil, index: 0),
      .init(depth: 1, role: "form", label: "", frame: nil, index: 1, parent: 0),
      .init(depth: 2, role: "image", label: "CAPTCHA", frame: nil, index: 2, parent: 1),
      .init(depth: 1, role: "form", label: "", frame: nil, index: 3, parent: 0),
      .init(depth: 2, role: "entry", label: "Answer", frame: nil, index: 4, parent: 3),
      .init(depth: 2, role: "push button", label: "Verify", frame: nil, index: 5, parent: 3)
    ]
    let read = FreshRead(pid: 1, window: 1, rows: separateForms, cut: false)
    try check(BoxFloor.judge(.type("sample"), at: 4, in: read) == nil && BoxFloor.judge(press: 5, in: read) == nil,
              "A CAPTCHA in another form leaves typing and pressing available")
  }

}
#endif
