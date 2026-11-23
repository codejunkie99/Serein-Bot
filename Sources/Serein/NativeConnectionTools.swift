import AppKit
import Contacts
import EventKit
import SereinCore

/// Calendar and Reminders through EventKit, Contacts through the Contacts framework, Notes through
/// fixed Apple-event scripts whose values ride as parameters (Settings › Connections). What macOS
/// lets Serein do, and the calls themselves. Every call passes one gate first
/// (`BrowserModel.nativeConnectionCall`, `ApprovalDoor.answer`). Mac run not verified.
@MainActor enum NativeConnections {
  enum Access: Equatable, Sendable { case allowed, notAsked, denied }

  /// One store for the app's life: macOS's answer is per process, and a store is costly to make.
  static let store = EKEventStore()

  /// The connections the person turned on, in a fixed order.
  static var on: [NativeConnection] { NativeConnection.allCases.filter { $0.isOn() } }

  /// The text macOS shows when it asks must be in Serein's Info.plist (scripts/build.sh). A bare
  /// development build has none, and macOS would end Serein on the request, so it never asks then.
  static func describedInBundle(_ connection: NativeConnection) -> Bool {
    let key: String
    switch connection {
    case .calendar: key = "NSCalendarsFullAccessUsageDescription"
    case .reminders: key = "NSRemindersFullAccessUsageDescription"
    case .contacts: key = "NSContactsUsageDescription"
    case .notes: key = "NSAppleEventsUsageDescription"
    }
    return Bundle.main.object(forInfoDictionaryKey: key) != nil
  }

  /// What macOS lets Serein do now. Notes cannot be read on the main thread (`notesAccess`).
  static func access(_ connection: NativeConnection) -> Access {
    switch connection {
    case .calendar: return eventAccess(EKEventStore.authorizationStatus(for: .event))
    case .reminders: return eventAccess(EKEventStore.authorizationStatus(for: .reminder))
    case .contacts:
      let status = CNContactStore.authorizationStatus(for: .contacts)
      return status == .authorized ? .allowed : status == .notDetermined ? .notAsked : .denied
    case .notes: return .notAsked
    }
  }
  /// Full access only: add-only access cannot read, so it counts as not allowed.
  private static func eventAccess(_ status: EKAuthorizationStatus) -> Access {
    status == .fullAccess ? .allowed : status == .notDetermined ? .notAsked : .denied
  }
  /// Whether macOS lets Serein send Notes Apple events, without asking; not asked yet while Notes
  /// is closed, since macOS cannot say then. Blocking for a moment, so callers run it off the main thread.
  nonisolated static func notesAccess() -> Access {
    switch MacAccess.automationState(bundleID: "com.apple.Notes") {
    case .allowed: return .allowed
    case .denied: return .denied
    case .undetermined, nil: return .notAsked
    }
  }
  /// macOS asks the person, once; after that only System Settings changes the answer. Notes asks
  /// on the first Apple event Serein sends it, so this sends one that reads nothing of the person's.
  static func request(_ connection: NativeConnection) async -> Access {
    guard describedInBundle(connection) else { return .denied }
    switch connection {
    case .calendar: _ = try? await store.requestFullAccessToEvents()
    case .reminders: _ = try? await store.requestFullAccessToReminders()
    case .contacts: _ = try? await CNContactStore().requestAccess(for: .contacts)
    case .notes:
      return await Task.detached(priority: .userInitiated) { () -> Access in
        var error: NSDictionary?
        _ = NSAppleScript(source: "tell application \"Notes\" to count folders")?.executeAndReturnError(&error)
        return notesAccess()
      }.value
    }
    return access(connection)
  }
  static func openSettings(_ connection: NativeConnection) {
    let pane: String
    switch connection {
    case .calendar: pane = "Privacy_Calendars"
    case .reminders: pane = "Privacy_Reminders"
    case .contacts: pane = "Privacy_Contacts"
    case .notes: pane = "Privacy_Automation"
    }
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
      NSWorkspace.shared.open(url)
    }
  }

  // MARK: Calendar and Reminders

  /// An event's id for the tools: EventKit's identifier, which every time of a repeating event
  /// shares, and this time's start, so a change or delete reaches exactly the time that was read.
  static func eventID(_ event: EKEvent) -> String {
    "\(event.eventIdentifier ?? "")@\(Int(event.startDate.timeIntervalSince1970))"
  }
  static func event(_ id: String) -> EKEvent? {
    guard let at = id.range(of: "@", options: .backwards), let seconds = Double(String(id[at.upperBound...])) else {
      return nil
    }
    let identifier = String(id[..<at.lowerBound])
    guard !identifier.isEmpty, let first = store.event(withIdentifier: identifier) else { return nil }
    if Int(first.startDate.timeIntervalSince1970) == Int(seconds) { return first }
    let start = Date(timeIntervalSince1970: seconds)
    let around = store.predicateForEvents(
      withStart: start.addingTimeInterval(-1), end: start.addingTimeInterval(1), calendars: first.calendar.map { [$0] })
    return store.events(matching: around).first {
      $0.eventIdentifier == identifier && Int($0.startDate.timeIntervalSince1970) == Int(seconds)
    }
  }
  /// What a yes was given for: a change to the event since the card throws the yes out.
  static func version(_ event: EKEvent?) -> String {
    guard let event else { return "gone" }
    return [String(event.lastModifiedDate?.timeIntervalSince1970 ?? 0), String(event.startDate.timeIntervalSince1970),
            String(event.endDate.timeIntervalSince1970), event.title ?? ""].joined(separator: "|")
  }
  static func calendarVersion(_ id: String) -> String {
    store.calendar(withIdentifier: id).map { "\($0.calendarIdentifier)|\($0.allowsContentModifications)" } ?? "gone"
  }
  /// The named calendar or Reminders list, or the default one, that Serein may add to.
  static func writableCalendar(_ name: String?, for type: EKEntityType) throws -> EKCalendar {
    let noun = type == .event ? "calendar" : "Reminders list"
    let found: EKCalendar?
    if let name {
      found = store.calendars(for: type).first { $0.title.caseInsensitiveCompare(name) == .orderedSame }
    } else {
      found = type == .event ? store.defaultCalendarForNewEvents : store.defaultCalendarForNewReminders()
    }
    guard let found else {
      throw SereinError.invalid(name == nil
        ? "There is no default \(noun) to add to. Name one."
        : "No \(noun) has that name. Read the names with \(type == .event ? "calendar_list" : "reminder_list_apple").")
    }
    guard found.allowsContentModifications else { throw SereinError.invalid("That \(noun) cannot be changed.") }
    return found
  }
  /// One event as the tools return it, inside the caller's untrusted block. Attendees are names only.
  static func eventRow(_ event: EKEvent) -> [String: Any] {
    let start: String = event.isAllDay ? NativeConnection.day(event.startDate) : NativeConnection.stamp(event.startDate)
    let end: String = event.isAllDay ? NativeConnection.day(event.endDate) : NativeConnection.stamp(event.endDate)
    var row: [String: Any] = [
      "id": eventID(event), "title": event.title ?? "", "all_day": event.isAllDay,
      "start": start, "end": end,
      "calendar": event.calendar?.title ?? "",
    ]
    if let location = event.location, !location.isEmpty { row["location"] = location }
    let attendees = (event.attendees ?? []).compactMap(\.name).prefix(30)
    if !attendees.isEmpty { row["attendees"] = Array(attendees) }
    if let notes = event.notes, !notes.isEmpty { row["notes"] = AgentPrivacy.redact(notes, limit: NativeConnection.itemNotesLimit) }
    if event.hasRecurrenceRules { row["repeats"] = true }
    return row
  }
  /// Read on EventKit's own queue, so it touches nothing but the reminder it is given.
  nonisolated static func reminderRow(_ reminder: EKReminder) -> [String: String] {
    var row = ["id": reminder.calendarItemIdentifier, "title": reminder.title ?? "", "list": reminder.calendar?.title ?? ""]
    if let due = reminder.dueDateComponents, let date = Calendar.current.date(from: due) {
      row["due"] = due.hour == nil ? NativeConnection.day(date) : NativeConnection.stamp(date)
    }
    if reminder.isCompleted { row["completed"] = "yes" }
    if let notes = reminder.notes, !notes.isEmpty { row["notes"] = AgentPrivacy.redact(notes, limit: NativeConnection.itemNotesLimit) }
    return row
  }

  // MARK: cards

  /// “Tuesday 27 October 2026, 15:00 to 16:00”, as the person reads it on a card.
  static func when(_ start: Date, _ end: Date, allDay: Bool) -> String {
    let format = DateFormatter()
    format.dateStyle = .full
    format.timeStyle = allDay ? .none : .short
    if allDay {
      return Calendar.current.isDate(start, inSameDayAs: end)
        ? format.string(from: start) + ", all day" : format.string(from: start) + " to " + format.string(from: end) + ", all day"
    }
    return format.string(from: start) + " to " + format.string(from: end)
  }
  /// The exact event, line by line, for the card's box.
  static func eventCard(title: String, start: Date, end: Date, allDay: Bool, location: String?, notes: String?,
                        calendar: String?) -> String {
    var lines = ["Title: " + title, "When: " + when(start, end, allDay: allDay)]
    if let location, !location.isEmpty { lines.append("Where: " + location) }
    if let calendar { lines.append("Calendar: " + calendar) }
    // Every character that is written is shown: notes are refused above itemNotesWriteLimit.
    if let notes, !notes.isEmpty { lines.append("Notes: " + notes) }
    return lines.joined(separator: "\n")
  }
  static func eventCard(_ event: EKEvent) -> String {
    eventCard(title: event.title ?? "", start: event.startDate, end: event.endDate, allDay: event.isAllDay,
              location: event.location, notes: event.notes, calendar: event.calendar?.title)
  }
  static func quoted(_ text: String) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ")
    return "“" + (flat.count > 60 ? String(flat.prefix(59)) + "…" : flat) + "”"
  }

  // MARK: Contacts

  /// Names, email addresses and phone numbers only: no other key is fetched, so notes, birthdays
  /// and addresses never leave the Contacts store. Runs off the main thread.
  nonisolated static func findPeople(_ query: String) throws -> [ContactPerson] {
    let keys: [CNKeyDescriptor] = [
      CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
      CNContactEmailAddressesKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor,
    ]
    let predicate = query.contains("@")
      ? CNContact.predicateForContacts(matchingEmailAddress: query) : CNContact.predicateForContacts(matchingName: query)
    let found = try CNContactStore().unifiedContacts(matching: predicate, keysToFetch: keys)
    return found.prefix(NativeConnection.contactLimit).map { contact in
      ContactPerson(
        name: CNContactFormatter.string(from: contact, style: .fullName) ?? "",
        emails: contact.emailAddresses.prefix(10).map { $0.value as String },
        phones: contact.phoneNumbers.prefix(10).map { $0.value.stringValue })
    }
  }
}

/// One person `contacts_find` returns.
struct ContactPerson: Sendable {
  var name: String
  var emails: [String]
  var phones: [String]
}

/// One connection call, worked out before its card: what the card says and shows, the item it is
/// about and that item's version now, how to read the version again after the answer, and the call.
@MainActor struct ConnectionStep {
  var title: String
  var detail: String
  var button = "Allow"
  /// The exact event, reminder or note, open in the card's box; nil for a read.
  var shown: String?
  var shownName = "the details"
  /// The line in Serein's activity list.
  var label: String
  var item: String
  var version = ""
  var check: @MainActor () async throws -> String = { "" }
  var run: @MainActor () async throws -> [String: Any]
}

/// The Notes connection's scripts: fixed text, never built from a value. Each value arrives as a
/// parameter of the run handler (`Connections.arguments`), and `valueAt` drops its one-character prefix.
private enum NotesScript {
  static let valueAt = """
    on valueAt(argv, k)
      set s to item k of argv
      if (length of s) < 2 then return ""
      return text 2 thru -1 of s
    end valueAt
    """
  static let search = """
    on run argv
      set q to my valueAt(argv, 1)
      set n to (my valueAt(argv, 2)) as integer
      set fs to character id 31
      set rs to character id 30
      set out to ""
      set c to 0
      tell application "Notes"
        repeat with x in (every note whose name contains q or plaintext contains q)
          if c is greater than or equal to n then exit repeat
          if not (password protected of x) then
            set out to out & (id of x) & fs & (name of x) & fs & ((modification date of x) as «class isot» as string) & fs & (name of (container of x)) & rs
            set c to c + 1
          end if
        end repeat
      end tell
      return out
    end run
    """ + "\n" + valueAt
  static let peek = """
    on run argv
      set k to my valueAt(argv, 1)
      tell application "Notes"
        set x to note id k
        set locked to password protected of x
        set n to 0
        if not locked then set n to count of attachments of x
        return (name of x) & (character id 31) & ((modification date of x) as «class isot» as string) & (character id 31) & (locked as string) & (character id 31) & (n as string)
      end tell
    end run
    """ + "\n" + valueAt
  static let read = """
    on run argv
      set k to my valueAt(argv, 1)
      tell application "Notes"
        set x to note id k
        if password protected of x then error "This note is locked." number 1001
        return (name of x) & (character id 31) & ((modification date of x) as «class isot» as string) & (character id 31) & (plaintext of x)
      end tell
    end run
    """ + "\n" + valueAt
  static let create = """
    on run argv
      set b to my valueAt(argv, 1)
      set f to my valueAt(argv, 2)
      tell application "Notes"
        if f is "" then
          set x to make new note with properties {body:b}
        else
          set x to make new note at folder f with properties {body:b}
        end if
        return id of x
      end tell
    end run
    """ + "\n" + valueAt
  static let append = """
    on run argv
      set k to my valueAt(argv, 1)
      set b to my valueAt(argv, 2)
      tell application "Notes"
        set x to note id k
        if password protected of x then error "This note is locked." number 1001
        if (count of attachments of x) > 0 then error "This note has attachments." number 1002
        set body of x to (body of x) & b
        return id of x
      end tell
    end run
    """ + "\n" + valueAt
}

extension BrowserModel {
  /// One call of a connection tool (BrowserModel.perform). In order: the person's switch, macOS
  /// access, the gate (a read as every read; adding, changing or deleting asks every time and is
  /// refused unattended, before anything is read), the card with the exact item, then the task,
  /// its Mac grant and the switch again and the item's version against the one the card showed.
  /// What comes back is fenced as untrusted (UntrustedText) and redacted.
  func nativeConnectionCall(
    _ tool: String, _ connection: NativeConnection, _ a: [String: Any], taskID id: String, operationID: UUID
  ) async throws -> [String: Any] {
    guard connection.isOn() else { throw SereinError.invalid(connection.turnedOff) }
    guard let effect = NativeConnection.effect(tool: tool) else { throw SereinError.invalid("Unknown browser tool") }
    if connection != .notes, NativeConnections.access(connection) != .allowed {
      throw SereinError.invalid(connection.noAccess)
    }
    let relay = relayTask(id, tasks[id])
    // Unattended runs, as for Mail and Messages: no call at all unless the person turned on
    // "Scheduled tasks may use this" for this connection, and never in a webhook's run.
    if isUnattended(task: id), !connection.scheduledOn() || webhookRun(task: id) {
      relay?.note("\(connection.label): \(AgentStep.label(tool: tool, arguments: a)) in a run nobody watches", .refused)
      throw SereinError.invalid(connection.scheduledOff)
    }
    // Unattended, a change asks: its card is deferred and goes ahead only after Allow, for that
    // exact step (RelayDeferred). The person's words cover reading only (UnattendedAuthority).
    let unattended = isUnattended(task: id)
    let named: [String] = ["title", "name"].compactMap { a[$0] as? String }
    let ownWords: Bool = unattended && relay?.wordsCover(effect, targets: named) == true
    let covered: Bool = ownWords || (unattended && relay?.grantWaits(thread: threadID(forTask: id)) == true)
    let judge = { (standing: ApprovalDoor.Standing) throws -> RelayAutonomy.Decision in
      try ApprovalDoor.answer(
        .init(.nativeConnection(tool: tool, yesWaits: covered), standing, taskID: id),
        facts: .init(
          secureField: false, botCheck: false, pays: .no, covered: false, path: nil, hostKeyChanged: nil,
          runsAnything: false, ref: "")
      ).decision()
    }
    var decision = try judge(RelayOrchestrator.standing(relay, present: !unattended))
    // The one-time consent card only before a routine step, then judged again.
    if decision == .auto, let relay {
      guard await relay.settleConsent(thread: threadID(forTask: id)) else { throw SereinError.invalid(RelayOrchestrator.stoppedStep) }
      decision = try judge(relay.standing(present: !isUnattended(task: id)))
    }
    let step = try await connectionStep(tool, a, taskID: id)
    let intent = ApprovalGate.record(
      ApprovalGate.GateAction(kind: tool, elementID: step.item, pageVersion: step.version),
      effect: effect, mint: { UUID().uuidString })
    let human: ApprovalGate.HumanAnswer
    if decision == .auto {
      human = .yes
    } else {
      guard let asker = relay ?? RelayOrchestrator.shared else { throw SereinError.invalid(ActionAdmission.needsPerson) }
      human = await asker.confirmAnswer(
        step.title, step.detail, button: step.button, thread: threadID(forTask: id), more: step.shown,
        moreName: step.shownName, app: connection == .notes ? "Notes" : nil, moreOpen: step.shown != nil, effect: effect)
    }
    let allowed = human == .yes
    if let context = behaviorContexts[id], !recordBehavior(
      context, .permissionAnswered, operationID: operationID, tool: .browser(tool),
      decision: decision == .auto ? .allowedByAutopilot : allowed ? .allowedOnce : .denied)
    {
      throw SereinError.invalid("The \(connection.label) step was not run because its approval could not be recorded.")
    }
    relay?.note(step.label, decision == .auto ? .auto : allowed ? .allowed : .declined)
    guard allowed else { throw SereinError.invalid(human == .no ? ActionAdmission.declined : ActionAdmission.needsPerson) }
    // Anything turned off while the card was up wins over the yes.
    guard let live = tasks[id], !live.finished else { throw SereinError.invalid("The task ended while awaiting approval") }
    guard live.allowMac else { throw SereinError.invalid("Mac automation is off for this task") }
    guard connection.isOn() else { throw SereinError.invalid(connection.turnedOff) }
    let version = try await step.check()
    guard ApprovalGate.beforeInput(
      intent: intent, answer: human, liveElement: step.item, liveVersion: version,
      liveEffect: NativeConnection.effect(tool: tool) ?? .unknown)
    else { throw SereinError.invalid(NativeConnection.changedSinceCard) }
    // What a read (or an update, which returns the event as it is now) brings in marks the task
    // and its chat (notePersonalRead): such a chat may not use Serein's computer. Marked before
    // the call, so a mark that cannot be saved stops it before anything is read or changed.
    if effect == .read || tool == "calendar_update" {
      guard notePersonalRead(task: id) else { throw SereinError.invalid(Self.personalMarkFailed) }
    }
    return try await step.run()
  }

  /// What one call would do, read before its card: nothing here changes the person's data.
  private func connectionStep(_ tool: String, _ a: [String: Any], taskID id: String) async throws -> ConnectionStep {
    func text(_ key: String) -> String? {
      guard let value = (a[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
      return value
    }
    func need(_ key: String) throws -> String {
      guard let value = text(key) else { throw SereinError.invalid("\(key) is required.") }
      return value
    }
    func date(_ key: String) throws -> (date: Date, dateOnly: Bool)? {
      guard let raw = text(key) else { return nil }
      guard let parsed = NativeConnection.date(raw) else {
        throw SereinError.invalid("\(key) is an ISO 8601 date or date-time, such as 2026-10-27 or 2026-10-27T15:00.")
      }
      return parsed
    }
    let store = NativeConnections.store
    // A value per line (UntrustedText.json): compact JSON is one line, which the line cap would cut.
    let fence = { (tag: String, value: Any) in UntrustedText.outside(tag, UntrustedText.json(value)) }
    let readNote = "What it reads goes to the AI app you chose."
    switch tool {
    case "calendar_list":
      let from = try date("from")?.date ?? Date()
      let to = try date("to")?.date ?? from.addingTimeInterval(7 * 86_400)
      guard to > from, to.timeIntervalSince(from) <= Double(NativeConnection.rangeDays) * 86_400 else {
        throw SereinError.invalid("to is after from, at most \(NativeConnection.rangeDays) days later.")
      }
      let names = (a["calendars"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
      let chosen: [EKCalendar]? = names.isEmpty ? nil : store.calendars(for: .event).filter { calendar in
        names.contains { $0.caseInsensitiveCompare(calendar.title) == .orderedSame }
      }
      if chosen?.isEmpty == true { throw SereinError.invalid("No calendar has those names. Leave calendars out to read every calendar.") }
      return ConnectionStep(
        title: "Serein wants to read your calendar",
        detail: "Events from \(NativeConnections.when(from, to, allDay: false)): titles, times, places, attendees and notes. \(readNote)",
        label: "Read the calendar", item: "calendar",
        run: {
          let found = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: chosen))
            .sorted { $0.startDate < $1.startDate }
          // Up to eventLimit events and about listingBytes of them; more says some were left out.
          var rows: [[String: Any]] = []
          var bytes = 0
          for event in found.prefix(NativeConnection.eventLimit) {
            let row = NativeConnections.eventRow(event)
            // Counted as fenced, and under the outside block cap with room for the calendar names,
            // so the cap never cuts events that `more` would not report.
            bytes += UntrustedText.json(row).utf8.count
            if bytes > min(NativeConnection.listingBytes, UntrustedText.blockLimit * 3 / 4) { break }
            rows.append(row)
          }
          return [
            "calendar": fence("calendar", ["calendars": store.calendars(for: .event).map(\.title), "events": Array(rows)] as [String: Any]),
            "count": rows.count, "more": found.count > rows.count,
          ]
        })
    case "calendar_create":
      let title = try need("title")
      guard let start = try date("start"), let end = try date("end") else { throw SereinError.invalid("start and end are required.") }
      let allDay = a["all_day"] as? Bool ?? (start.dateOnly && end.dateOnly)
      guard (allDay ? end.date >= start.date : end.date > start.date) else { throw SereinError.invalid("end is after start.") }
      let calendar = try NativeConnections.writableCalendar(text("calendar"), for: .event)
      let calendarID = calendar.calendarIdentifier
      let location = text("location"), notes = text("notes")
      guard (notes?.count ?? 0) <= NativeConnection.itemNotesWriteLimit else { throw SereinError.invalid(NativeConnection.notesTooLong) }
      return ConnectionStep(
        title: "Serein wants to add \(NativeConnections.quoted(title)) to your calendar",
        detail: "\(NativeConnections.when(start.date, end.date, allDay: allDay)), in \(calendar.title). The box shows the exact event.",
        button: "Add Event",
        shown: NativeConnections.eventCard(title: title, start: start.date, end: end.date, allDay: allDay,
                                           location: location, notes: notes, calendar: calendar.title),
        shownName: "the event", label: "Calendar: add \(NativeConnections.quoted(title))", item: calendarID,
        version: NativeConnections.calendarVersion(calendarID), check: { NativeConnections.calendarVersion(calendarID) },
        run: {
          guard let live = store.calendar(withIdentifier: calendarID) else { throw SereinError.invalid(NativeConnection.changedSinceCard) }
          let event = EKEvent(eventStore: store)
          event.title = title
          event.startDate = start.date
          event.endDate = end.date
          event.isAllDay = allDay
          event.location = location
          event.notes = notes
          event.calendar = live
          try store.save(event, span: .thisEvent, commit: true)
          return [
            "created": NativeConnections.eventID(event), "event": fence("calendar", NativeConnections.eventRow(event)),
            "verification": "Read it back with calendar_list before reporting.",
          ]
        })
    case "calendar_update":
      let eventID = try need("id")
      guard let event = NativeConnections.event(eventID) else {
        throw SereinError.invalid("No event has that id now. Read calendar_list again.")
      }
      guard event.calendar?.allowsContentModifications == true else { throw SereinError.invalid("That event's calendar cannot be changed.") }
      let title = text("title") ?? event.title ?? ""
      let start = try date("start")?.date ?? event.startDate!
      let end = try date("end")?.date ?? event.endDate!
      let allDay = a["all_day"] as? Bool ?? event.isAllDay
      // An empty location or notes clears it; leaving it out keeps it.
      let location = a["location"] != nil ? text("location") : event.location
      let notes = a["notes"] != nil ? text("notes") : event.notes
      if a["notes"] != nil, (notes?.count ?? 0) > NativeConnection.itemNotesWriteLimit {
        throw SereinError.invalid(NativeConnection.notesTooLong)
      }
      guard (allDay ? end >= start : end > start) else { throw SereinError.invalid("end is after start.") }
      let before = NativeConnections.eventCard(event)
      let after = NativeConnections.eventCard(title: title, start: start, end: end, allDay: allDay, location: location,
                                              notes: notes, calendar: event.calendar?.title)
      guard before != after else { throw SereinError.invalid("Nothing would change. Give only the fields to change.") }
      return ConnectionStep(
        title: "Serein wants to change \(NativeConnections.quoted(event.title ?? "")) in your calendar",
        detail: "The box shows the event now and after the change."
          + (event.hasRecurrenceRules ? " It repeats; only this time changes." : ""),
        button: "Change Event", shown: "Now:\n" + before + "\n\nAfter:\n" + after, shownName: "the event",
        label: "Calendar: change \(NativeConnections.quoted(event.title ?? ""))", item: eventID,
        version: NativeConnections.version(event), check: { NativeConnections.version(NativeConnections.event(eventID)) },
        run: {
          guard let live = NativeConnections.event(eventID) else { throw SereinError.invalid(NativeConnection.changedSinceCard) }
          live.title = title
          live.startDate = start
          live.endDate = end
          live.isAllDay = allDay
          live.location = location
          live.notes = notes
          try store.save(live, span: .thisEvent, commit: true)
          return [
            "updated": NativeConnections.eventID(live), "event": fence("calendar", NativeConnections.eventRow(live)),
            "verification": "Read it back with calendar_list before reporting.",
          ]
        })
    case "calendar_delete":
      let eventID = try need("id")
      guard let event = NativeConnections.event(eventID) else {
        throw SereinError.invalid("No event has that id now. Read calendar_list again.")
      }
      guard event.calendar?.allowsContentModifications == true else { throw SereinError.invalid("That event's calendar cannot be changed.") }
      var detail: String = NativeConnections.when(event.startDate, event.endDate, allDay: event.isAllDay) + "."
      if event.hasRecurrenceRules { detail += " It repeats; only this time is deleted." }
      detail += " The box shows the exact event."
      return ConnectionStep(
        title: "Serein wants to delete \(NativeConnections.quoted(event.title ?? "")) from your calendar",
        detail: detail,
        button: "Delete Event", shown: NativeConnections.eventCard(event), shownName: "the event",
        label: "Calendar: delete \(NativeConnections.quoted(event.title ?? ""))", item: eventID,
        version: NativeConnections.version(event), check: { NativeConnections.version(NativeConnections.event(eventID)) },
        run: {
          guard let live = NativeConnections.event(eventID) else { throw SereinError.invalid(NativeConnection.changedSinceCard) }
          try store.remove(live, span: .thisEvent, commit: true)
          return ["deleted": eventID]
        })
    case "reminder_list_apple":
      let name = text("list")
      let completed = a["include_completed"] as? Bool ?? false
      let lists = store.calendars(for: .reminder)
      let chosen: [EKCalendar]? = name.map { name in lists.filter { $0.title.caseInsensitiveCompare(name) == .orderedSame } }
      if chosen?.isEmpty == true { throw SereinError.invalid("No Reminders list has that name. Leave list out to read every list.") }
      let which: String = completed ? "All" : "Open"
      let within: String = name.map { " in \(NativeConnections.quoted($0))" } ?? ""
      return ConnectionStep(
        title: "Serein wants to read your reminders",
        detail: "\(which) reminders\(within): titles, due dates and notes. \(readNote)",
        label: "Read Reminders", item: "reminders",
        run: {
          let predicate = completed
            ? store.predicateForReminders(in: chosen)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: chosen)
          let rows: [[String: String]] = await withCheckedContinuation { done in
            _ = store.fetchReminders(matching: predicate) { @Sendable found in
              done.resume(returning: (found ?? []).prefix(NativeConnection.reminderLimit).map(NativeConnections.reminderRow))
            }
          }
          return ["reminders": fence("reminders", ["lists": lists.map(\.title), "reminders": rows] as [String: Any]), "count": rows.count]
        })
    case "reminder_create_apple":
      let title = try need("title")
      let due = try date("due")
      let notes = text("notes")
      guard (notes?.count ?? 0) <= NativeConnection.itemNotesWriteLimit else { throw SereinError.invalid(NativeConnection.notesTooLong) }
      let list = try NativeConnections.writableCalendar(text("list"), for: .reminder)
      let listID = list.calendarIdentifier
      let dueWords = due.map { due in
        due.dateOnly ? DateFormatter.localizedString(from: due.date, dateStyle: .full, timeStyle: .none)
          : DateFormatter.localizedString(from: due.date, dateStyle: .full, timeStyle: .short)
      }
      // Built in typed steps: as one chained expression the type checker gives up.
      let dueLine: String = dueWords ?? "no due date"
      var shownLines: [String] = ["Title: \(title)", "Due: \(dueLine)", "List: \(list.title)"]
      if let notes { shownLines.append("Notes: \(notes)") }
      let shown: String = shownLines.joined(separator: "\n")
      let dueDetail: String = dueWords.map { "Due \($0)" } ?? "No due date"
      return ConnectionStep(
        title: "Serein wants to add \(NativeConnections.quoted(title)) to Reminders",
        detail: "\(dueDetail), in \(list.title). The box shows the exact reminder.",
        button: "Add Reminder", shown: shown, shownName: "the reminder",
        label: "Reminders: add \(NativeConnections.quoted(title))", item: listID,
        version: NativeConnections.calendarVersion(listID), check: { NativeConnections.calendarVersion(listID) },
        run: {
          guard let live = store.calendar(withIdentifier: listID) else { throw SereinError.invalid(NativeConnection.changedSinceCard) }
          let reminder = EKReminder(eventStore: store)
          reminder.title = title
          reminder.notes = notes
          reminder.calendar = live
          if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
              due.dateOnly ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute], from: due.date)
          }
          try store.save(reminder, commit: true)
          return ["created": reminder.calendarItemIdentifier, "reminder": fence("reminders", NativeConnections.reminderRow(reminder))]
        })
    case "contacts_find":
      let query = try need("query")
      return ConnectionStep(
        title: "Serein wants to look up \(NativeConnections.quoted(query)) in your Contacts",
        detail: "Names, email addresses and phone numbers only. \(readNote)",
        label: "Contacts: look up \(NativeConnections.quoted(query))", item: "contacts",
        run: {
          let people = try await Task.detached(priority: .userInitiated) { try NativeConnections.findPeople(query) }.value
          let rows = people.map { ["name": $0.name, "emails": $0.emails, "phones": $0.phones] as [String: Any] }
          return ["contacts": fence("contacts", rows), "count": rows.count]
        })
    case "notes_search":
      let query = try need("query")
      let limit = min(max(a["limit"] as? Int ?? NativeConnection.noteLimit, 1), NativeConnection.noteLimit)
      return ConnectionStep(
        title: "Serein wants to search your notes",
        detail: "For \(NativeConnections.quoted(query)): titles, folders and when each changed. \(readNote)",
        label: "Notes: search for \(NativeConnections.quoted(query))", item: "notes",
        run: { [weak self] in
          guard let self else { throw SereinError.invalid("The task ended") }
          let output = try await self.notesScript(NotesScript.search, [query, String(limit)], taskID: id)
          // Split first, then redact each field, so a redaction never swallows a separator.
          let rows = Connections.records(output, fields: 4).compactMap { fields -> [String: String]? in
            fields.count >= 4
              ? ["id": fields[0], "title": AgentPrivacy.redact(fields[1], limit: 500), "changed": fields[2],
                 "folder": AgentPrivacy.redact(fields[3], limit: 200)]
              : nil
          }
          return ["notes": fence("notes", rows), "count": rows.count]
        })
    case "notes_read":
      let noteID = try need("id")
      return ConnectionStep(
        title: "Serein wants to read one of your notes", detail: "Its title and text. \(readNote)",
        label: "Notes: read a note", item: noteID,
        run: { [weak self] in
          guard let self else { throw SereinError.invalid("The task ended") }
          let fields = try await self.notesScript(NotesScript.read, [noteID], taskID: id).components(separatedBy: "\u{1F}")
          guard fields.count >= 3 else { throw SereinError.invalid("Notes did not return that note. Search again.") }
          let body = fields[2...].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
          // Not `fence`: the text is one JSON value of up to 20,000 characters, which the line cap
          // would cut to its first 4,000. The note limit already bounds it.
          return ["note": UntrustedText.outsideNote + "\n" + UntrustedText.wrap("note", UntrustedText.json([
            "id": noteID, "title": AgentPrivacy.redact(fields[0], limit: 500), "changed": fields[1],
            "text": AgentPrivacy.redact(body, limit: NativeConnection.noteTextLimit),
          ]))]
        })
    case "notes_create":
      let title = try need("title")
      let body = try need("text")
      let folder = text("folder")
      guard title.count <= 200, body.count <= NativeConnection.noteTextLimit else {
        throw SereinError.invalid("A note's title is at most 200 characters and its text at most \(NativeConnection.noteTextLimit).")
      }
      let place: String = folder.map { "the folder \(NativeConnections.quoted($0))" } ?? "your default Notes folder"
      return ConnectionStep(
        title: "Serein wants to create the note \(NativeConnections.quoted(title))",
        detail: "In \(place). The box shows the exact note.",
        button: "Create Note", shown: "Title: \(title)\n\n\(body)", shownName: "the note",
        label: "Notes: create \(NativeConnections.quoted(title))", item: "new-note",
        run: { [weak self] in
          guard let self else { throw SereinError.invalid("The task ended") }
          let created = try await self.notesScript(
            NotesScript.create, [NativeConnection.noteHTML(title: title, text: body), folder ?? ""], taskID: id)
          return ["created": AgentPrivacy.redact(created.trimmingCharacters(in: .whitespacesAndNewlines)),
                  "verification": "Read it back with notes_read before reporting."]
        })
    case "notes_append":
      let noteID = try need("id")
      let addition = try need("text")
      guard addition.count <= NativeConnection.noteTextLimit else {
        throw SereinError.invalid("Add at most \(NativeConnection.noteTextLimit) characters at a time.")
      }
      // The note's title for the card, and its last change and attachment count for the version,
      // read before the card.
      let peek = { [weak self] () async throws -> [String] in
        guard let self else { throw SereinError.invalid("The task ended") }
        return try await self.notesScript(NotesScript.peek, [noteID], taskID: id)
          .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1F}")
      }
      let now = try await peek()
      guard now.count >= 4 else { throw SereinError.invalid("Notes did not return that note. Search again.") }
      guard now[2] != "true" else { throw SereinError.invalid("That note is locked, so Serein leaves it alone.") }
      // Writing a note's body back drops its pictures, scans, drawings and files.
      guard now[3] == "0" else {
        throw SereinError.invalid(
          "That note has attachments, which adding text through Notes scripting would remove, so Serein leaves it alone.")
      }
      return ConnectionStep(
        title: "Serein wants to add to the note \(NativeConnections.quoted(now[0]))",
        detail: "The box shows the exact text added at its end.",
        button: "Add to Note", shown: "Note: \(now[0])\n\nAdded at the end:\n\(addition)", shownName: "the text",
        label: "Notes: add to \(NativeConnections.quoted(now[0]))", item: noteID, version: now[1] + "|" + now[3],
        check: {
          let live = try await peek()
          return live.count >= 4 ? live[1] + "|" + live[3] : "gone"
        },
        run: { [weak self] in
          guard let self else { throw SereinError.invalid("The task ended") }
          let updated = try await self.notesScript(
            NotesScript.append, [noteID, NativeConnection.noteHTML(text: addition)], taskID: id)
          return ["updated": AgentPrivacy.redact(updated.trimmingCharacters(in: .whitespacesAndNewlines)),
                  "verification": "Read it back with notes_read before reporting."]
        })
    default:
      throw SereinError.invalid("Unknown browser tool")
    }
  }

  /// A Notes script through the raw osascript runner (MacTasks.rawScript), its values as
  /// run-handler parameters. The answer is unredacted: each caller splits it into fields and
  /// redacts every field it returns. A refusal by macOS becomes plain words the person can act on.
  private func notesScript(_ source: String, _ values: [String], taskID: String) async throws -> String {
    do {
      let output = try await rawScript(Connections.arguments(source, values), taskID: taskID)
      RelayOrchestrator.shared?.learnAutomation(app: "Notes", .allowed)
      return output
    } catch {
      let text = "\(error)"
      if text.contains("-1743") || text.localizedCaseInsensitiveContains("not authorized to send apple events") {
        RelayOrchestrator.shared?.learnAutomation(app: "Notes", .denied)
        throw SereinError.invalid(NativeConnection.notes.noAccess)
      }
      throw error
    }
  }
}
