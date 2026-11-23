#if DEBUG
import Foundation
import SereinCore

/// The Search palette's list (SearchPalette.swift): what shows before anything is typed, what a
/// query keeps, and where the ⌘ hints stop.
extension AssistantCoreChecks {
  static func searchPalette(_ check: Check) throws {
    typealias Row = SearchPalette.Row
    let assistants: [Row] = [Row(id: "main", title: "Serein", line: "Your flight is booked.")]
      + (1...10).map { Row(id: "a\($0)", title: "Scout \($0)") }
    let chats: [Row] = (1...30).map { Row(id: "c\($0)", title: "Fix the build \($0)", line: "serein · \($0) h") }
    let settings: [Row] = [Row(id: "General", title: "General"), Row(id: "Talking", title: "Voice")]
    func sections(_ query: String) -> [SearchPalette.Section] {
      SearchPalette.sections(query: query, assistants: assistants, chats: chats, settings: settings)
    }

    let open = sections("")
    try check(open.map(\.kind) == [.assistants, .chats, .settings], "Nothing typed: Assistants, then Chats, then Settings")
    try check(open[0].rows == assistants && open[2].rows == settings, "Nothing typed: every assistant and every Settings page")
    try check(open[1].rows.map(\.id) == (1...SearchPalette.recentChats).map { "c\($0)" }, "Nothing typed: the 8 newest chats, in the order given")
    try check(sections("   ").map(\.kind) == open.map(\.kind), "Spaces alone are no query")

    let voice = sections("VOICE")
    try check(voice.map(\.kind) == [.settings] && voice[0].rows.map(\.id) == ["Talking"], "A query that matches one section shows that section alone, any case")
    try check(sections("flight").first?.rows.map(\.id) == ["main"], "A query matches the line under a name")
    try check(sections("build").first?.rows.count == SearchPalette.matchedChats, "A query lists 20 chats at most")
    try check(sections("unicorn").isEmpty, "A query that matches nothing leaves no section")

    let hints = assistants.indices.map(SearchPalette.hint)
    try check(hints.prefix(9).compactMap { $0 } == (1...9).map { "⌘\($0)" } && hints.dropFirst(9).allSatisfy { $0 == nil } && SearchPalette.hint(-1) == nil,
              "⌘1 to ⌘9 mark the first nine assistants and no row after them")
  }
}
#endif
