import AppKit
import SereinCore
import SwiftUI
import UniformTypeIdentifiers

/// The text of each page an agent task's tools returned (a read, the page after an action, a page
/// read inside a repl program, a repl fetch) and of the page Relay read from the page chip
/// (`current_page`), so a collected table's cells can be checked word for word against the page
/// their row names. It holds only what an agent task's tools returned, after
/// `AgentPrivacy.sanitize`, plus each page's exact address without user, password, query or
/// fragment, used only to open the page on the person's own click (never logged, saved or sent to
/// a model). In memory only, within fixed bounds; a page is dropped when everyone that read it is
/// forgotten (its chat deleted, an outside agent's session ended, a new Relay chat) or when it is
/// the oldest past the bounds.
@MainActor enum CollectedPages {
  static let maxPages = 200
  /// Two full reads of 24,000 characters.
  static let maxCharacters = 48_000
  /// Per attached file: two full table_query answers (`TableQueryAnswer.textLimit`).
  static let maxFileCharacters = 120_000
  /// All pages together, in UTF-8 bytes.
  static let maxTotal = 6_000_000
  private static var byKey: [String: String] = [:]
  private static var order: [String] = []
  /// Who read each page: the chat's thread id for an agent run, the task id for an outside agent,
  /// `relayOwner` for Relay's page-chip reads.
  private static var owners: [String: Set<String>] = [:]
  /// Each page's exact addresses; more than one means several pages share the key.
  private static var links: [String: Set<String>] = [:]
  /// The staged digest of the file each file key's rows came from (`noteFile`).
  private static var digests: [String: String] = [:]
  private static var total = 0
  /// The owner of Relay's own `current_page` reads.
  static let relayOwner = "relay"

  /// Records a browser tool's result as the agent received it (after `AgentPrivacy.sanitize`).
  /// Long pages read in parts add up under one address. `real` is the page's own address before
  /// the agent's redaction.
  static func note(_ result: [String: Any], owner: String, real: String?) {
    let page = result["page"] as? [String: Any] ?? result
    guard let address = page["url"] as? String ?? page["address"] as? String else { return }
    let text: String
    if let read = page["text"] as? String ?? page["text_untrusted"] as? String {
      text = read
    } else if let body = page["body"] as? String {
      // Only the body's start is read; comments, head, noscript, svg and template text are
      // dropped too, so a cell is never "found" in text the page does not show.
      text = RelayWatches.visibleText(String(body.prefix(maxCharacters * 2)), limit: maxCharacters * 2)
    } else {
      return
    }
    let key = CollectedTable.key(address)
    let words = TabText.normalize(text)
    guard !key.isEmpty, !words.isEmpty else { return }
    // Only "one" or "more than one" is ever read, so a key keeps at most two addresses.
    if let real, let link = exact(real), (links[key]?.count ?? 0) < 2 { links[key, default: []].insert(link) }
    record(key: key, words: words, owner: owner, separator: " ", limit: maxCharacters, fromEnd: false)
  }

  /// Records what table_query returned for a file attached to the chat (`TableQueryAnswer.evidence`,
  /// rows apart), under the file's source key (`CollectedTable.filePrefix`), so a reply's table
  /// whose Source names the file is checked against it. The newest results are kept, whole rows
  /// only. Rows of another file under the same name (another chat, a newer version: a different
  /// staged `digest`) replace the old ones rather than join them.
  static func noteFile(_ name: String, rows: String, owner: String, digest: String) {
    let key: String = CollectedTable.key(CollectedTable.filePrefix + name)
    let words: String = TabText.normalize(rows)
    guard !words.isEmpty else { return }
    if let known = digests[key], known != digest { drop(key) }
    digests[key] = digest
    record(
      key: key, words: words, owner: owner, separator: String(CollectedTable.rowBreak), limit: maxFileCharacters,
      fromEnd: true)
  }

  /// Adds `words` to `key`'s text unless it already holds them, within `limit` characters: the
  /// oldest kept (`fromEnd` false) or the newest, starting after a `separator` so no part-row is
  /// kept. Then drops the oldest keys past the bounds.
  private static func record(key: String, words: String, owner: String, separator: String, limit: Int, fromEnd: Bool) {
    owners[key, default: []].insert(owner)
    let known: String = byKey[key] ?? ""
    order.removeAll { $0 == key }
    order.append(key)
    if !known.contains(words) {
      let joined: String = known.isEmpty ? words : known + separator + words
      var kept: String = fromEnd ? String(joined.suffix(limit)) : String(joined.prefix(limit))
      if fromEnd && kept.count < joined.count, let cut = kept.range(of: separator) {
        kept = String(kept[cut.upperBound...])
      }
      total += kept.utf8.count - known.utf8.count
      byKey[key] = kept
    }
    while order.count > maxPages || total > maxTotal, let oldest = order.first { drop(oldest) }
  }

  /// Drops these owners' reads; a page no remaining owner read goes.
  static func forget(owners gone: Set<String>) {
    guard !gone.isEmpty else { return }
    for (key, readers) in owners {
      let left = readers.subtracting(gone)
      if left.isEmpty { drop(key) } else if left.count < readers.count { owners[key] = left }
    }
  }

  /// The recorded text for each of these page addresses, keyed by `CollectedTable.key`. A key
  /// several pages share is left out: its values cannot be checked.
  static func texts(for addresses: [String]) -> [String: String] {
    var out: [String: String] = [:]
    for address in addresses {
      let key = CollectedTable.key(address)
      if (links[key]?.count ?? 0) <= 1, let text = byKey[key] { out[key] = text }
    }
    return out
  }

  /// The exact page a row's (redacted) address stands for, when only one read page has its key.
  static func link(for address: String) -> String? {
    guard let known = links[CollectedTable.key(address)], known.count == 1 else { return nil }
    return known.first
  }

  private static func drop(_ key: String) {
    total -= byKey.removeValue(forKey: key)?.utf8.count ?? 0
    order.removeAll { $0 == key }
    owners[key] = nil
    links[key] = nil
    digests[key] = nil
  }

  /// A web address without user, password, query or fragment; its path is kept.
  private static func exact(_ address: String) -> String? {
    guard var parts = URLComponents(string: address), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
      parts.host?.isEmpty == false
    else { return nil }
    parts.user = nil
    parts.password = nil
    parts.query = nil
    parts.fragment = nil
    return parts.string
  }
}

/// A reply's table with a Source column (`CollectedTable`): a card with the row count, Copy,
/// Save as CSV… and Save as Markdown…, the column headers, and one row per page with its site
/// linked to the exact page. A cell not found word for word on its page has a “not checked”
/// mark. Rows are lazy and of one height, so a 500-row table scrolls without laying out them all.
@MainActor struct CollectedTableCard: View {
  let table: CollectedTable
  /// One per value column (the Source column's own alignment is dropped).
  let alignment: [MessageTableAlignment]
  /// Each value column's width, from its header and first rows.
  private let widths: [CGFloat]
  @Environment(\.palette) private var p
  @Environment(\.openURL) private var openURL
  @State private var checks: [[Bool]]?
  /// Rows whose page was not read in this session (or names no page), so nothing was compared.
  @State private var unread: Set<Int> = []
  @State private var copied = false

  static let rowHeight: CGFloat = 32
  static let headerHeight: CGFloat = 34
  static let sourceWidth: CGFloat = 150
  static let notCheckedHelp = "Not found word for word on its source page. Check it there before you rely on it."
  static let unreadHelp = "Its page was not read in this session, so this value could not be checked."
  /// The same for a row from a file the person attached (its Source is the file).
  static let fileNotCheckedHelp = "Not found word for word in what Serein read from this file. Check it there before you rely on it."
  static let fileUnreadHelp = "This file was not read in this session, so this value could not be checked."

  init(table: CollectedTable, alignment: [MessageTableAlignment]) {
    self.table = table
    self.alignment = alignment.enumerated().filter { $0.offset != table.sourceIndex }.map(\.element)
    // shortcut: width from character counts of the first 60 rows; measure text if columns look off.
    widths = table.columns.indices.map { column in
      let longest = ([table.columns[column]] + table.rows.prefix(60).map { $0.cells[column] }).map(\.count).max() ?? 0
      return min(max(CGFloat(longest) * 7.5 + 20, 72), 280)
    }
  }

  private var notChecked: Int { checks?.joined().filter { !$0 }.count ?? 0 }
  /// Every row came from a file the person attached, so the card speaks of files, not pages.
  private var fromFiles: Bool { table.rows.allSatisfy { $0.source.map(CollectedTable.isFile) ?? false } }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      bar
      Rectangle().fill(p.line).frame(height: 1)
      ScrollView([.horizontal, .vertical]) {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
          Section {
            ForEach(table.rows.indices, id: \.self) { index in
              row(index)
            }
          } header: {
            header
          }
        }
      }.frame(height: min(Self.headerHeight + CGFloat(table.rows.count) * (Self.rowHeight + 1), 420))
    }
    .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
    .clipShape(RoundedRectangle(cornerRadius: UIStyle.panelRadius))
    .overlay(RoundedRectangle(cornerRadius: UIStyle.panelRadius).strokeBorder(p.borderStrong, lineWidth: UIStyle.hairline))
    .frame(maxWidth: .infinity, alignment: .leading)
    // A streaming reply changes the table; the wait lets the next change cancel this check.
    .task(id: table) {
      copied = false
      checks = nil
      try? await Task.sleep(nanoseconds: 250_000_000)
      guard !Task.isCancelled else { return }
      let pages = CollectedPages.texts(for: table.rows.compactMap(\.source))
      if let result = await table.checks(pages: pages) {
        unread = Set(table.rows.indices.filter { index in
          table.rows[index].source.map { pages[CollectedTable.key($0)] == nil } ?? true
        })
        checks = result
      }
    }
  }

  /// Row count, the check's outcome, and the card's actions: one line, or two when the chat is
  /// narrow (Serein beside a page), so no button is cut.
  private var bar: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        summary
        Spacer(minLength: 8)
        actions
      }.frame(height: 36)
      VStack(alignment: .leading, spacing: 2) {
        summary
        actions
      }.padding(.vertical, 6)
    }.padding(.leading, 12).padding(.trailing, 6)
  }

  private var summary: some View {
    HStack(spacing: 8) {
      Text("\(table.rows.count) \(table.rows.count == 1 ? "row" : "rows")").font(UIStyle.micro).foregroundStyle(p.secondary)
      Text(status).font(UIStyle.micro).foregroundStyle(p.secondary).lineLimit(1)
    }
  }

  private var actions: some View {
    HStack(spacing: 4) {
      Button(copied ? "Copied" : "Copy") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(table.tabSeparated(), forType: .string)
        copied = true
      }.buttonStyle(QuietButton()).help("Copy as tab-separated text for a spreadsheet")
        .task(id: copied) {
          if copied {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { copied = false }
          }
        }
      Button("Save as CSV…") {
        ChatExport.saveText(named: "Table.csv", panelTitle: "Save Table as CSV", message: Self.saveNote,
          types: [UTType.commaSeparatedText]) { table.csv() }
      }.buttonStyle(QuietButton())
      Button("Save as Markdown…") {
        ChatExport.saveText(named: "Table.md", panelTitle: "Save Table as Markdown", message: Self.saveNote,
          types: ChatExport.markdownTypes) { table.markdown() }
      }.buttonStyle(QuietButton())
    }
  }

  static let saveNote = "Recognised keys, tokens and passwords are replaced, and links lose their query."

  private var status: String {
    guard let checks else { return fromFiles ? "Checking values against the file…" : "Checking values against their pages…" }
    if checks.isEmpty { return "" }
    if unread.count == table.rows.count {
      return fromFiles ? "File not read in this session; values not checked" : "Pages not read in this session; values not checked"
    }
    let n = notChecked
    if n == 0 { return fromFiles ? "Every value is in its file" : "Every value is on its page" }
    return "\(n) \(n == 1 ? "value" : "values") not checked"
  }

  private func align(_ column: Int) -> Alignment {
    switch column < alignment.count ? alignment[column] : .left {
    case .right: return .trailing
    case .center: return .center
    case .left: return .leading
    }
  }

  private var header: some View {
    HStack(spacing: 0) {
      ForEach(table.columns.indices, id: \.self) { column in
        let name = CollectedTable.plain(table.columns[column])
        Text(name).font(UIStyle.bodyStrong).foregroundStyle(p.ink).lineLimit(1).truncationMode(.tail)
          .frame(width: widths[column], alignment: align(column)).padding(.horizontal, 10)
          .help(name).accessibilityAddTraits(.isHeader)
      }
      Text(CollectedTable.sourceName).font(UIStyle.bodyStrong).foregroundStyle(p.ink)
        .frame(width: Self.sourceWidth, alignment: .leading).padding(.horizontal, 10)
        .accessibilityAddTraits(.isHeader)
    }.frame(height: Self.headerHeight)
      .background(p.card)
      .overlay(alignment: .bottom) { Rectangle().fill(p.borderStrong).frame(height: 1) }
  }

  private func row(_ index: Int) -> some View {
    let row = table.rows[index]
    return HStack(spacing: 0) {
      ForEach(table.columns.indices, id: \.self) { column in
        cell(row.cells[column], note: note(index, column), column: column)
      }
      source(row.source)
    }.frame(height: Self.rowHeight)
      .overlay(alignment: .bottom) { Rectangle().fill(p.line).frame(height: 1) }
      .padding(.bottom, 1)
  }

  /// Why a cell is unchecked (not found, or its page or file never read); nil when checked.
  private func note(_ index: Int, _ column: Int) -> String? {
    if isChecked(index, column) { return nil }
    let file: Bool = table.rows[index].source.map(CollectedTable.isFile) ?? false
    if unread.contains(index) { return file ? Self.fileUnreadHelp : Self.unreadHelp }
    return file ? Self.fileNotCheckedHelp : Self.notCheckedHelp
  }

  /// Unchecked only once the check said so; a table that just changed waits for its new check.
  private func isChecked(_ row: Int, _ column: Int) -> Bool {
    guard let checks, row < checks.count, column < checks[row].count else { return true }
    return checks[row][column]
  }

  /// `note`: why the value is unchecked (not found, or its page never read), nil when checked.
  private func cell(_ value: String, note: String?, column: Int) -> some View {
    let plain = CollectedTable.plain(value)
    return HStack(spacing: 4) {
      Text(messageInlineText(value, size: 13, weight: .regular, color: p.ink, accent: p.accent))
        .lineLimit(1).truncationMode(.tail)
      if let note {
        InterfaceIcon(systemName: "exclamationmark.triangle", size: 11).foregroundStyle(p.warning)
          .help(note)
      }
    }.frame(width: widths[column], alignment: align(column)).padding(.horizontal, 10)
      .help(note.map { plain + "\n" + $0 } ?? plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(CollectedTable.plain(table.columns[column])): \(plain)\(note == nil ? "" : ", not checked")")
      .accessibilityHint(note ?? "")
  }

  @ViewBuilder private func source(_ address: String?) -> some View {
    // A file the person attached: named, with nothing to open.
    if let address, CollectedTable.isFile(address) {
      let name = CollectedTable.fileName(address)
      HStack(spacing: 4) {
        InterfaceIcon(systemName: "paperclip", size: 11).foregroundStyle(p.secondary)
        Text(name).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.middle)
      }.frame(width: Self.sourceWidth, alignment: .leading).padding(.horizontal, 10)
        .help("From \(name), a file you attached")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Source: \(name), an attached file")
    } else if let address, let url = URL(string: CollectedPages.link(for: address) ?? address) {
      // The exact page Serein read, when the agent's address was redacted (a long slug) and only
      // one read page matches it.
      let site = CollectedTable.site(address)
      Button { openURL(url) } label: {
        Text(site).underline().font(UIStyle.meta).foregroundStyle(p.accent).lineLimit(1).truncationMode(.middle)
      }.buttonStyle(.pressable)
        .frame(width: Self.sourceWidth, alignment: .leading).padding(.horizontal, 10)
        .help(address)
        .accessibilityLabel("Source: \(site)")
        .accessibilityHint("Opens the page this row came from")
    } else {
      Text("No page").font(UIStyle.meta).foregroundStyle(p.secondary)
        .frame(width: Self.sourceWidth, alignment: .leading).padding(.horizontal, 10)
        .help("This row names no page, so its values could not be checked.")
    }
  }
}
