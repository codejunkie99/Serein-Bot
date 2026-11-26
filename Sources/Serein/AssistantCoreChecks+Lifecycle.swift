#if DEBUG
import Foundation
import SereinCore

/// Unit 3: faces, making and deleting an assistant, list sections, quick-reply chips and the job
/// guess from a name (AssistantLifecycle.swift).
extension AssistantCoreChecks {
  static func lifecycle(_ check: Check) throws {
    try lifecycleFaces(check)
    try lifecycleMake(check)
    try lifecycleDelete(check)
    try lifecycleSections(check)
    try lifecycleChips(check)
    try lifecycleNames(check)
  }

  /// True when no word of `text` is a feature word the person must not see.
  private static func lifecyclePlain(_ text: String) -> Bool {
    let words = Set(text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
    return ReceiptCopy.bannedWords.intersection(words).isEmpty
  }

  // MARK: faces

  private static func lifecycleFaces(_ check: Check) throws {
    let abc = AssistantFace(id: "abc")
    try check(abc.blob == .soft && abc.tint == "sky", "SHA-256 of the id picks the face: \"abc\" is a soft Sky blob")
    let main = AssistantFace(id: "main")
    try check(main.blob == .hex && main.tint == "violet", "SHA-256 of the id picks the face: \"main\" is a Violet hexagon")
    try check(AssistantFace(id: "abc") == abc, "One id always gives the same face")
    try check(AssistantFace.tints == ["sky", "teal", "violet", "rose", "tangerine", "moss"], "Faces use the six assistant tints, not Slate or Indigo")
    try check(AssistantFace.Blob.allCases.count == 5, "There are five face shapes")

    var blobs = Set<AssistantFace.Blob>()
    var tints = Set<String>()
    for i in 0..<60 {
      let face = AssistantFace(id: "assistant-\(i)")
      blobs.insert(face.blob)
      tints.insert(face.tint)
    }
    try check(blobs.count == 5 && tints == Set(AssistantFace.tints), "Sixty ids use every shape and every tint")

    let team = RelayTeam(profiles: [RelayProfile(id: "main", name: "Serein"), RelayProfile(id: "p1", name: "Scout")], activeID: "main")
    if let renamed = team.renaming("p1", to: "Ranger"), let after = renamed.profiles.first(where: { $0.id == "p1" }) {
      try check(after.name == "Ranger" && AssistantFace(id: after.id) == AssistantFace(id: "p1"), "A rename keeps the face (the seed is the id)")
    } else {
      try check(false, "A rename keeps the face (the seed is the id)")
    }
    try check(abc.wearing("rose").tint == "rose" && abc.wearing("rose").blob == abc.blob, "The face can use the tint on the assistant's row and keeps its shape")
    try check(abc.wearing("blue").tint == "sky", "An earlier build's colour reads as today's tint")
    try check(abc.wearing(nil) == abc && abc.wearing("mauve") == abc, "No colour, or one no build knows, keeps the tint from the id")

    for blob in AssistantFace.Blob.allCases {
      let steps = AssistantFace.outline(blob)
      var startsWithMove = false
      if let first = steps.first, case .move = first { startsWithMove = true }
      try check(startsWithMove && steps.last == AssistantFace.Step.close, "The \(blob.rawValue) outline starts with a move and ends with close")
      let box = 0...AssistantFace.box
      let inBox = lifecycleFacePoints(steps).allSatisfy { box.contains($0.x) && box.contains($0.y) }
      try check(inBox, "Every point of the \(blob.rawValue) outline is in the 24 by 24 box")
      let polygon = lifecycleFacePolygon(steps)
      let eyes = AssistantFace.eyes(blob)
      let inside = lifecycleFaceContains(polygon, eyes.left) && lifecycleFaceContains(polygon, eyes.right)
      try check(inside && eyes.left.x < eyes.right.x, "Both eyes of the \(blob.rawValue) face are inside its outline, left before right")
    }
    let outlines: [[AssistantFace.Step]] = AssistantFace.Blob.allCases.map { AssistantFace.outline($0) }
    var distinct = true
    for i in outlines.indices {
      for j in outlines.indices where j > i && outlines[i] == outlines[j] { distinct = false }
    }
    try check(distinct, "The five outlines are different")
    try check(abc.outline == AssistantFace.outline(.soft), "A face's outline is its shape's outline")
  }

  private static func lifecycleFacePoints(_ steps: [AssistantFace.Step]) -> [AssistantFace.Point] {
    var points: [AssistantFace.Point] = []
    for step in steps {
      switch step {
      case .move(let p), .line(let p): points.append(p)
      case .curve(to: let end, control1: let c1, control2: let c2): points.append(contentsOf: [end, c1, c2])
      case .close: break
      }
    }
    return points
  }

  /// The outline as a polygon: each curve becomes 16 short lines.
  private static func lifecycleFacePolygon(_ steps: [AssistantFace.Step]) -> [AssistantFace.Point] {
    var polygon: [AssistantFace.Point] = []
    var current = AssistantFace.Point(0, 0)
    for step in steps {
      switch step {
      case .move(let p), .line(let p):
        polygon.append(p)
        current = p
      case .curve(to: let end, control1: let c1, control2: let c2):
        for i in 1...16 {
          let u = Double(i) / 16
          let v = 1 - u
          let a = v * v * v
          let b = 3 * v * v * u
          let c = 3 * v * u * u
          let d = u * u * u
          let x = a * current.x + b * c1.x + c * c2.x + d * end.x
          let y = a * current.y + b * c1.y + c * c2.y + d * end.y
          polygon.append(AssistantFace.Point(x, y))
        }
        current = end
      case .close: break
      }
    }
    return polygon
  }

  private static func lifecycleFaceContains(_ polygon: [AssistantFace.Point], _ point: AssistantFace.Point) -> Bool {
    guard !polygon.isEmpty else { return false }
    var inside = false
    var j = polygon.count - 1
    for i in polygon.indices {
      let a = polygon[i]
      let b = polygon[j]
      if (a.y > point.y) != (b.y > point.y) {
        let crossX = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
        if point.x < crossX { inside.toggle() }
      }
      j = i
    }
    return inside
  }

  // MARK: make

  private static func lifecycleMake(_ check: Check) throws {
    typealias Draft = AssistantDraft
    let person: Set<AssistantPlace> = [.web, .mail, .calendar, .connectedApps]
    let team = RelayTeam(
      profiles: [RelayProfile(id: "main", name: "Serein"), RelayProfile(id: "p1", name: "Planner", colour: "sky")], activeID: "main")
    func draft(_ a: [String: Any]) -> Result<Draft, Draft.Problem> { Draft.parse(a, person: person, team: team) }
    func problem(_ result: Result<Draft, Draft.Problem>) -> Draft.Problem? {
      if case .failure(let p) = result { return p }
      return nil
    }
    func value(_ result: Result<Draft, Draft.Problem>) -> Draft? {
      if case .success(let d) = result { return d }
      return nil
    }

    let inbox = value(draft(["name": "  Inbox Zero  "]))
    try check(inbox?.name == "Inbox Zero", "A new name is trimmed")
    try check(inbox?.job == NameReading.job(for: "Inbox Zero") && inbox?.jobFromName == true, "With no job, the job comes from the name")
    try check(inbox?.places == [.web, .mail, .calendar], "With no can_use, it gets the person's places except connected apps")
    try check(problem(draft(["name": "   "])) == .noName, "An empty name is refused")
    try check(problem(draft(["name": String(repeating: "a", count: 41)])) == .nameTooLong, "A name of 41 characters is refused")
    try check(value(draft(["name": String(repeating: "a", count: 40)])) != nil, "A name of 40 characters is allowed")
    try check(problem(draft(["name": "planner"])) == .nameTaken("Planner"), "A name another assistant has, in any case, is refused")
    try check(problem(draft(["name": "Two\nlines"])) == .notOneLine, "A name is one line")
    try check(problem(draft(["name": "Ok", "job": "One\ntwo"])) == .notOneLine, "A job is one line")
    try check(problem(draft(["name": "Ok", "job": String(repeating: "a", count: 161)])) == .jobTooLong, "A job of more than 160 characters is refused")
    let typed = value(draft(["name": "Inbox Zero", "job": "It files receipts."]))
    try check(typed?.job == "It files receipts." && typed?.jobFromName == false, "A job in the words wins over the name")
    let bob = value(draft(["name": "Bob 3000"]))
    try check(bob != nil && bob?.job == nil && bob?.jobFromName == false, "A name that says nothing leaves the job empty, so the assistant asks")

    let scout = value(draft(["name": "Scout", "can_use": ["Web", "Messages", "connected apps", "Moon"]]))
    try check(scout?.places == [.web], "Places clip to the person's places")
    try check(scout?.dropped == ["Messages", "Connected apps", "Moon"], "What it cannot have is listed for the card, connected apps too")
    try check(value(draft(["name": "Scout", "can_use": "web, mail"]))?.places == [.web, .mail], "can_use can be one line with commas")
    try check(value(draft(["name": "Scout", "can_use": [String]()]))?.places == [], "An empty can_use gives no places")

    var big = team
    for i in 0..<40 { big.profiles.append(RelayProfile(id: "x\(i)", name: "Helper \(i)")) }
    if case .success = big.making(Draft(name: "One more", job: nil, places: [.web]), person: person) {
      try check(true, "A roster of any size takes one more assistant")
    } else {
      try check(false, "A roster of any size takes one more assistant")
    }
    let problems: [Draft.Problem] = [.noName, .nameTooLong, .notOneLine, .nameTaken("Planner"), .jobTooLong, .notSaved]
    try check(problems.allSatisfy { lifecyclePlain($0.words) && !$0.words.isEmpty }, "Every make refusal is in plain words")

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    guard let inboxDraft = value(draft(["name": "Inbox Zero", "can_use": ["web", "mail"]])) else {
      try check(false, "Inbox Zero's draft reads")
      return
    }
    guard case .success(let plan) = team.making(inboxDraft, person: person, id: "new-1", now: now) else {
      try check(false, "Inbox Zero can be made")
      return
    }
    try check(plan.team.profiles.count == 3 && plan.team.profiles.last == plan.profile, "Making adds one assistant at the end of the roster")
    try check(plan.profile.id == "new-1" && plan.profile.createdAt == now, "The new assistant has the id and time given")
    try check(plan.face == AssistantFace(id: "new-1"), "The new assistant's face comes from its id")
    try check(plan.profile.colour == "teal", "It takes the next free tint")
    try check(plan.profile.scope?.destinations == [.web, .mail], "It can use only the places it asked for that the person allows")
    try check(plan.team.activeID == team.activeID, "Making does not switch the assistant on screen")
    let job = NameReading.job(for: "Inbox Zero") ?? "?"
    try check(plan.profile.scope?.instructions.contains(job) == true, "Its job is kept in its instructions")
    let receipt = plan.receipt(entry: "j1")
    try check(receipt.line == "Inbox Zero is ready. " + job, "The receipt says it is ready and what it does")
    try check(ReceiptCopy.lint(receipt.line, name: "Inbox Zero").isEmpty, "The make receipt is plain")
    try check(receipt.kind == .assistantMade && receipt.undo?.kind == .assistantMade, "A made assistant keeps its Undo")
    try check(plan.line == "You made Inbox Zero" && !plan.asksFirst, "The chat line says who made it")
    if case .failure(let p) = plan.team.making(inboxDraft, person: person) {
      try check(p == .nameTaken("Inbox Zero"), "A make checks the name again when it applies")
    } else {
      try check(false, "A make checks the name again when it applies")
    }
    if case .success(let narrow) = team.making(inboxDraft, person: [.web], id: "new-2") {
      try check(narrow.profile.scope?.destinations == [.web], "A make clips the places again to what the person allows now")
    } else {
      try check(false, "A make clips the places again to what the person allows now")
    }
    if case .success(let clash) = team.making(inboxDraft, person: person, id: "p1") {
      try check(clash.profile.id != "p1", "A make never reuses an id on the roster")
    } else {
      try check(false, "A make never reuses an id on the roster")
    }
    if let bob, case .success(let bobPlan) = team.making(bob, person: person, id: "new-3") {
      let line = bobPlan.receipt(entry: "j3").line
      try check(bobPlan.asksFirst && line == "Bob 3000 is ready.", "A name-only assistant is ready and asks in its first turn")
      try check(ReceiptCopy.lint(line, name: "Bob 3000").isEmpty, "The name-only receipt is plain")
    } else {
      try check(false, "Bob 3000 can be made")
    }
  }

  // MARK: delete

  private static func lifecycleDelete(_ check: Check) throws {
    typealias Item = DeletePlan.Item
    let profiles = [
      RelayProfile(id: "main", name: "Serein"), RelayProfile(id: "p1", name: "Planner"),
      RelayProfile(id: "p2", name: "Old notes"), RelayProfile(id: "p3", name: "Scout"),
    ]
    let roster = RelayTeam(profiles: profiles, activeID: "main", groups: [AssistantGroup(id: "g1", name: "Trip", memberIDs: ["p1", "p2"], leadID: "p2")])

    if case .failure(let r) = roster.deleting("main", owned: []) {
      try check(r == .main("Serein") && lifecyclePlain(r.words), "The main assistant cannot be deleted")
    } else {
      try check(false, "The main assistant cannot be deleted")
    }
    let onScout = RelayTeam(profiles: profiles, activeID: "p3")
    if case .failure(let r) = onScout.deleting("p3", owned: []) {
      try check(r == .active("Scout") && lifecyclePlain(r.words), "The assistant on screen cannot be deleted")
    } else {
      try check(false, "The assistant on screen cannot be deleted")
    }
    if case .failure(let r) = roster.deleting("nobody", owned: []) {
      try check(r == .unknown, "An id not on the roster is refused")
    } else {
      try check(false, "An id not on the roster is refused")
    }

    let owned = [
      Item(kind: .handoff, id: "h1", title: "Find hotels"), Item(kind: .routine, id: "r1", title: "Clear inbox"),
      Item(kind: .watch, id: "w1", title: "Fare to Lisbon", on: false), Item(kind: .link, id: "l1", title: "GitHub"),
      Item(kind: .watch, id: "w2", title: "News"), Item(kind: .routine, id: "r1", title: "Clear inbox"),
    ]
    guard case .success(let plan) = roster.deleting("p2", owned: owned) else {
      try check(false, "Old notes can be deleted")
      return
    }
    try check(plan.title == "Delete Old notes?", "The card asks \"Delete Old notes?\"")
    try check(plan.ends.map(\.id) == ["r1", "w1", "w2", "l1", "h1"], "The card lists what ends once each: routines, watches, links, then hand-offs")
    try check(
      plan.detail == "Its chats stay in History. Its 1 routine, 2 watches, 1 link and 1 open hand-off end. You can undo for 10 seconds.",
      "The card counts what ends in plain words")
    try check(lifecyclePlain(plan.detail) && lifecyclePlain(plan.title), "The delete card uses no feature words")
    try check(DeletePlan.confirm == "Delete assistant" && DeletePlan.keep == "Keep it", "The card's buttons are Delete assistant and Keep it")
    try check(!plan.team.profiles.contains(where: { $0.id == "p2" }) && plan.index == 2, "The plan takes the assistant off the roster and keeps its place")
    let trip = plan.team.teams.first { $0.id == "g1" }
    try check(trip?.memberIDs == ["p1"] && trip?.leadID == nil, "The plan takes it out of every team")
    try check(plan.undo.resume.map(\.id) == ["r1", "w2", "l1"], "Undo turns on again only what was on, and no hand-off")
    try check(plan.undo.restoring(plan.team) == roster, "Undo gives the roster back as it was")
    if let later = plan.team.adding("Writer") {
      try check(plan.undo.restoring(later) == nil, "Undo waits until newer changes are undone")
    } else {
      try check(false, "A later change can be made")
    }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let receipt = plan.receipt(entry: "j2", now: now)
    let liveAt9 = receipt.undo?.isLive(now: now.addingTimeInterval(9)) ?? false
    let liveAt10 = receipt.undo?.isLive(now: now.addingTimeInterval(10)) ?? true
    try check(receipt.kind == .assistantDeleted && liveAt9 && !liveAt10, "After a delete, Undo lasts 10 seconds")
    try check(ReceiptCopy.lint(receipt.line).isEmpty, "The delete receipt is plain")

    if case .success(let one) = roster.deleting("p2", owned: [Item(kind: .routine, id: "r1", title: "Clear inbox")]) {
      try check(one.detail == "Its chats stay in History. Its 1 routine ends. You can undo for 10 seconds.", "One routine reads \"Its 1 routine ends.\"")
    } else {
      try check(false, "One routine reads \"Its 1 routine ends.\"")
    }
    if case .success(let none) = roster.deleting("p3", owned: []) {
      try check(none.detail == "Its chats stay in History. You can undo for 10 seconds." && none.ends.isEmpty, "Nothing that ends is not mentioned")
    } else {
      try check(false, "Scout can be deleted")
    }
  }

  // MARK: sections

  private static func lifecycleSections(_ check: Check) throws {
    typealias S = AssistantSections
    let rows = [
      S.Row(id: "a", status: .ready), S.Row(id: "b", status: .working(2)), S.Row(id: "c", status: .needsYou),
      S.Row(id: "d", status: .replying), S.Row(id: "e", status: .unread), S.Row(id: "f", status: .paused),
    ]
    let parts = S.arrange(rows)
    try check(parts.map(\.section) == [.needsYou, .working, .quiet], "Sections come in the order Needs you, Working, Quiet")
    try check(parts.map(\.ids) == [["c"], ["b", "d"], ["a", "e", "f"]], "State alone sets the section, in roster order")
    try check(S.Section.allCases.map(\.title) == ["Needs you", "Working", "Quiet"], "The section titles are Needs you, Working and Quiet")
    try check(S.arrange([S.Row(id: "a", status: .ready)]) == [S.Part(section: .quiet, ids: ["a"])], "An empty section is left out")
    try check(S.arrange(rows + [S.Row(id: "a", status: .needsYou)]) == parts, "A row given twice shows once")

    let manual = S.arrange(rows, manualOrder: ["f", "d", "c", "a"])
    try check(manual.map(\.ids) == [["c"], ["d", "b"], ["f", "a", "e"]], "A manual order wins inside a section and never moves a row to another section")

    let changed = [
      S.Row(id: "a", status: .needsYou), S.Row(id: "b", status: .working(1)), S.Row(id: "c", status: .ready),
      S.Row(id: "d", status: .replying), S.Row(id: "f", status: .paused), S.Row(id: "g", status: .working(1)),
    ]
    let held = S.arrange(changed, dragging: true, frozen: parts)
    try check(held.map(\.ids) == [["c"], ["b", "d", "g"], ["a", "f"]], "During a drag the order holds; a new row goes last in its section and a gone row leaves")
    try check(S.arrange(changed).map(\.ids) == [["a"], ["b", "d", "g"], ["c", "f"]], "After the drag, state sets the sections again")
    try check(S.arrange(rows, dragging: true, frozen: []) == parts, "A drag with nothing held arranges as usual")

    let order = S.moving("f", to: 0, in: parts)
    try check(order == ["c", "b", "d", "f", "a", "e"], "A drop moves the row inside its own section")
    try check(S.arrange(rows, manualOrder: order).map(\.ids) == [["c"], ["b", "d"], ["f", "a", "e"]], "The drop's order is the manual order after")
    try check(S.moving("zz", to: 0, in: parts) == parts.flatMap(\.ids), "A drop of an unknown row changes nothing")
  }

  // MARK: chips

  private static func lifecycleChips(_ check: Check) throws {
    let ask = "I cannot tell my job from my name. What should I do for you?"
    let parsed = QuickReplies.parse(ask + "\nCHIPS: Watch prices | Plan my week | Sum up Slack")
    try check(parsed.text == ask, "The chips line is taken out of the reply")
    try check(parsed.chips == ["Watch prices", "Plan my week", "Sum up Slack"], "The chips line gives its chips")
    try check(QuickReplies.parse("Hi\nCHIPS: a | b | c | d").chips == ["a", "b", "c"], "At most three chips")
    let mixed = QuickReplies.parse("Hi\nCHIPS: ok | This chip is far too long to fit | **Bold** | [link](x) | https://a.b | | OK | Next")
    try check(mixed.chips == ["ok", "Next"], "Chips that are too long, use markup, link, are empty or repeat are dropped")
    let edge = String(repeating: "a", count: 24)
    try check(QuickReplies.parse("Hi\nCHIPS: \(edge) | \(edge)b").chips == [edge], "A chip has 1 to 24 characters")
    try check(QuickReplies.parse("Hi\nCHIPS: a\u{200B}b | c").chips == ["c"], "A chip with a hidden character is dropped")
    try check(QuickReplies.parse("Hi\nCHIPS: “Yes please” | 'No'").chips == ["Yes please", "No"], "Quotes around a chip go")
    let trailing = QuickReplies.parse("Hello\nCHIPS: a | b\n\n  ")
    try check(trailing.text == "Hello" && trailing.chips == ["a", "b"], "Blank lines after the chips line do not matter")
    let only = QuickReplies.parse("chips: a")
    try check(only.text == "" && only.chips == ["a"], "A reply can be only the chips line")
    let none = QuickReplies.parse("Just text\nwith two lines")
    try check(none.text == "Just text\nwith two lines" && none.chips.isEmpty, "A reply with no chips line comes back unchanged")
    let notLast = QuickReplies.parse("CHIPS: a | b\nMore text")
    try check(notLast.text == "CHIPS: a | b\nMore text" && notLast.chips.isEmpty, "Only the last line can be the chips line")
    let invalid = QuickReplies.parse("Hi\nCHIPS: **x**")
    try check(invalid.text == "Hi" && invalid.chips.isEmpty, "The chips line goes even when no chip in it is valid")
  }

  // MARK: name reading

  private static func lifecycleNames(_ check: Check) throws {
    let listed = [
      "Inbox", "Mail", "Email", "Calendar", "Schedule", "Travel", "Trip", "Flights", "Fares", "Writer", "Notes", "Research",
      "News", "Finance", "Budget", "Fitness", "Recipes", "Shopping",
    ]
    for word in listed {
      let job = NameReading.job(for: word)
      try check(job != nil, "\"\(word)\" gives a job guess")
      if let job {
        let oneSentence = job.hasPrefix("It ") && job.hasSuffix(".") && job.filter({ $0 == "." }).count == 1
        try check(oneSentence && job.count <= 80 && lifecyclePlain(job), "The guess for \"\(word)\" is one plain sentence")
      }
    }
    try check(NameReading.job(for: "Inbox Zero") == "It sorts your mail and asks before it sends anything.", "Inbox Zero sorts your mail")
    try check(NameReading.job(for: "Trip fares") == NameReading.job(for: "Trip"), "The first word that tells a job wins")
    try check(NameReading.job(for: "FareWatcher") == NameReading.job(for: "Fares"), "Words joined in one name are read apart")
    try check(NameReading.job(for: "e-mail helper") == NameReading.job(for: "Mail"), "\"e-mail\" reads as mail")
    try check(NameReading.job(for: "Bob 3000") == nil && NameReading.job(for: "Ana") == nil, "A name that says nothing gives nil")
    try check(NameReading.job(for: "Farewell") == nil, "Only whole words count")
    try check(lifecyclePlain(NameReading.question) && lifecyclePlain(QuickReplies.instruction), "The question and the chips instruction are plain")
  }
}
#endif
