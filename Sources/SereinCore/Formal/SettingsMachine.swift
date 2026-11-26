import Foundation

/// Settings changed from the chat (`ChatSettings.admit`, `SettingsLedger`) read through the turn
/// frames (`TurnFrames`), folding TEAMS-V2's Frames and SettingsUndo machines into one: two chats
/// whose turns start, read a page, end and end late, in every order, each calling `setting_change`
/// with its own words or the other chat's, beside a change on the Settings page and every Undo,
/// replays included.
struct SettingsWorld: Encodable, Equatable {
  static let threads = ["a", "b"]
  static let turnsPerThread = 2
  static let changesCap = 3
  /// The code floor and paying: never written by any step but a page change, which these have none of.
  static let floorNames = ["secure_card", "pay_limit"]
  static let start: [String: String] = [
    ChatSettings.approvalLevel: ApprovalLevel.everyStep.title, "hologram": "on", "secure_card": "on", "pay_limit": "on",
  ]

  var frames = TurnFrames()
  var serials: [String: Int] = [:]
  var values = SettingsWorld.start
  var ledger = SettingsLedger()
  /// Every change that applied, in order; its id is its index.
  var issued: [SettingChange] = []
  /// Restores Undo wrote, per change id.
  var restored: [String: Int] = [:]
  var pageChanged = false
  /// What the step just taken did, for the transition properties.
  var last: Last?

  struct Last: Equatable {
    var thread: String
    /// The thread of the frame the call read; "" for none.
    var read: String
    var applied: Bool
    var quoteFrom: String
    var byPerson: Bool
    var readOutside: Bool
    var narrows: Bool
    var undoOf: Int?
  }

  static func words(_ thread: String, _ serial: Int) -> String { "please change my setting \(thread)\(serial)" }

  /// The state's identity: everything the steps read.
  var key: String {
    let turns = Self.threads.map { t in
      frames[t].map { "\($0.serial)\($0.admission == .person ? "p" : "s")\($0.readOutside ? "o" : "")" } ?? "-"
    }
    let open = ledger.open.map(\.id).joined(separator: ",")
    let lastKey = last.map {
      "\($0.thread)\($0.read)\($0.applied)\($0.quoteFrom)\($0.byPerson)\($0.readOutside)\($0.narrows)\($0.undoOf ?? -1)"
    } ?? ""
    return [turns.joined(separator: "/"), Self.threads.map { "\(serials[$0] ?? 0)" }.joined(), values.sorted { $0.key < $1.key }.map(\.value).joined(separator: ","),
            open, "\(issued.count)", restored.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","),
            "\(pageChanged)", lastKey].joined(separator: "|")
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(key)
  }

  /// The other value a setting can take from here.
  static func choices(_ name: String, from value: String?) -> [String] {
    if name == ChatSettings.approvalLevel { return ApprovalLevel.allCases.map(\.title).filter { $0 != value } }
    return [value == "on" ? "off" : "on"]
  }

  static func steps(_ w: SettingsWorld) -> [(label: String, next: SettingsWorld)] {
    var out: [(label: String, next: SettingsWorld)] = []
    func add(_ label: String, _ change: (inout SettingsWorld) -> Void) {
      var n = w
      n.last = nil
      change(&n)
      out.append((label, n))
    }
    for t in threads {
      let serial = w.serials[t] ?? 0
      if let frame = w.frames[t] {
        if !frame.readOutside { add("\(t): the turn reads a page") { $0.frames.noteReadOutside(t) } }
        add("\(t): turn \(frame.serial) ends") { $0.frames.end(t, serial: frame.serial) }
        if frame.serial > 1 { add("late end: \(t) turn \(frame.serial - 1)") { $0.frames.end(t, serial: frame.serial - 1) } }
      } else if serial < turnsPerThread {
        for person in [true, false] {
          add("\(t): \(person ? "the person's" : "another assistant's") turn \(serial + 1) starts") {
            $0.serials[t] = serial + 1
            $0.frames.begin(TurnFrame(
              thread: t, serial: serial + 1, admission: person ? .person : .assistant, unattended: false,
              personWords: person ? words(t, serial + 1) : nil, readOutside: false, profile: "main", acting: "main"))
          }
        }
      }
      // setting_change from a running turn on `t`, quoting either chat's person.
      guard w.frames[t] != nil, w.issued.count < changesCap else { continue }
      for name in [ChatSettings.approvalLevel, "hologram"] + floorNames {
        for value in choices(name, from: w.values[name]) {
          for from in threads {
            guard let said = w.frames[from], said.byPerson else { continue }
            add("\(t): setting_change \(name) \(value), quoting \(from)") { n in
              // RelayToolHost.call binds the entry frame of `t`; the host's `frame` reads it back.
              let frame = n.frames.frame(for: n.frames[t]) ?? TurnFrame(
                thread: "", serial: 0, admission: .unattended, unattended: true, personWords: nil, readOutside: false,
                profile: "", acting: nil)
              let narrows = name == ChatSettings.approvalLevel
                ? ChatSettings.level(value).map { ChatSettings.asks($0) >= ChatSettings.asks(ChatSettings.level(n.values[name] ?? "") ?? .everyStep) } ?? false
                : value == "off"
              let verdict = frame.byPerson
                ? ChatSettings.admit(
                  name: name, quote: words(from, said.serial), personMessages: [frame.typedWords], readOutside: frame.readOutside,
                  narrows: narrows)
                : .refuse("not the person's turn")
              n.last = Last(
                thread: t, read: frame.thread, applied: verdict == .apply, quoteFrom: from, byPerson: frame.byPerson,
                readOutside: frame.readOutside, narrows: narrows, undoOf: nil)
              guard verdict == .apply else { return }
              let change = SettingChange(id: String(n.issued.count), name: name, before: n.values[name] ?? "", after: value)
              n.values[name] = value
              n.issued.append(change)
              n.ledger.landed(change)
            }
          }
        }
      }
    }
    // The person changes it on the Settings page: no ledger entry.
    if !w.pageChanged {
      for name in [ChatSettings.approvalLevel, "hologram"] {
        for value in choices(name, from: w.values[name]) {
          add("Settings page: \(name) \(value)") { n in
            n.values[name] = value
            n.pageChanged = true
          }
        }
      }
    }
    // Undo on every change's receipt, again after it was used.
    for change in w.issued {
      add("Undo change \(change.id) (\(change.name) \(change.before) to \(change.after))") { n in
        n.last = Last(thread: "", read: "", applied: false, quoteFrom: "", byPerson: false, readOutside: false, narrows: false,
                      undoOf: Int(change.id))
        let values = n.values
        guard case .restore(let back) = n.ledger.undo(change.id, current: { values[$0] }) else { return }
        n.values[back.name] = back.before
        n.restored[back.id, default: 0] += 1
      }
    }
    return out
  }
}

enum SettingsMachine {
  static var machine: FormalMachine<SettingsWorld> {
    FormalMachine(
      name: "settings-undo",
      bounds: "2 chats, 2 turns each (the person's or an assistant's), \(SettingsWorld.changesCap) changes, 1 Settings page change, every Undo and replay",
      start: SettingsWorld(), steps: SettingsWorld.steps,
      invariants: [
        ("the code floor and paying never change", { w in SettingsWorld.floorNames.allSatisfy { w.values[$0] == "on" } }),
        ("each change is undone at most once", { w in w.restored.values.allSatisfy { $0 <= 1 } }),
        ("a frame sits under its own thread only", { w in
          SettingsWorld.threads.allSatisfy { t in w.frames[t].map { $0.thread == t } ?? true }
        }),
      ],
      transitions: [
        ("a call reads only its own thread's frame", { _, _, after in
          guard let last = after.last, last.undoOf == nil else { return true }
          return last.read == last.thread || last.read == ""
        }),
        ("a change applies only with the calling turn's own person's words", { _, _, after in
          guard let last = after.last, last.applied else { return true }
          return last.byPerson && last.quoteFrom == last.thread && (last.narrows || !last.readOutside)
        }),
        ("Undo writes back exactly the value before, and only over the value its change wrote", { before, _, after in
          guard let i = after.last?.undoOf else { return true }
          let change = before.issued[i]
          let moved = Set(before.values.keys.filter { before.values[$0] != after.values[$0] })
          guard !moved.isEmpty else { return true }
          return moved == [change.name] && before.values[change.name] == change.after && after.values[change.name] == change.before
        }),
        ("a late end clears no newer turn", { before, label, after in
          !label.hasPrefix("late end") || before.frames == after.frames
        }),
      ],
      eventually: [("every open Undo can be used or refused", { w in w.ledger.open.isEmpty })],
      key: \.key)
  }
}
