import AppKit
import ImageIO
import SereinCore
import SwiftUI

/// The Library (SPEC.md 2.9, the library boards): what the assistants and the person kept, in one
/// person-only view (no tool reads it). "Library" in the title size, an end-to-end search field
/// ("Search your library", `LibraryQuery`), the filter chips Date, Type and Assistant, then the
/// results newest first under their kind's heading (`LibraryKind.title`): photos as a grid, the
/// rest as rows (glyph, the name as written with middle truncation, "From Scout, today", its
/// size). ⇧⌘L opens it; Esc goes back to the chat. A click opens the file; Show in Finder is on
/// its menu. Today it lists the files kept from tasks and computers this launch
/// (`AssistantLibrary`); the memory store's file records join it when that store lists them.
struct AssistantLibraryView: View {
  @ObservedObject var relay: RelayOrchestrator
  var close: () -> Void
  @ObservedObject private var library = AssistantLibrary.shared
  @State private var text = ""
  @State private var kind: LibraryKind?
  @State private var assistant: String?
  @State private var span: Span = .any
  @State private var shownCount = LibraryQuery.defaultLimit
  @FocusState private var searching: Bool
  @Environment(\.palette) private var p
  static let show = Notification.Name("SereinShowLibrary")
  /// ⇧⌘L from anywhere: Serein's chat shows first (`SereinRouter.show`), then the Library opens
  /// over it. A chat that comes on screen only now opens it when it appears (`pending`).
  @MainActor static func open() {
    pending = true
    SereinRouter.show()
    NotificationCenter.default.post(name: show, object: nil)
  }
  /// ⇧⌘L was pressed and no chat on screen has opened the Library yet.
  @MainActor static var pending = false

  enum Span: String, CaseIterable, Identifiable {
    case today, week, month, any
    var id: String { rawValue }
    var title: String {
      switch self {
      case .today: return "Today"
      case .week: return "This week"
      case .month: return "This month"
      case .any: return "Any time"
      }
    }
    func range(now: Date, calendar: Calendar) -> ClosedRange<Date>? {
      let start: Date?
      switch self {
      case .today: start = calendar.startOfDay(for: now)
      case .week: start = calendar.date(byAdding: .day, value: -7, to: now)
      case .month: start = calendar.date(byAdding: .month, value: -1, to: now)
      case .any: start = nil
      }
      return start.map { $0...now }
    }
  }

  /// The things that may show: kept files that are still on disk, by their record.
  private var entries: [(item: SereinCore.LibraryItem, url: URL)] {
    let files = FileManager.default
    return library.records.filter { $0.kind == .kept && files.fileExists(atPath: $0.url.path) }.map { record in
      let item = SereinCore.LibraryItem(
        id: record.id.uuidString, title: record.url.lastPathComponent,
        kind: LibraryKind(url: record.url) ?? .file, assistant: record.owners.first, date: record.at,
        detail: record.url.deletingLastPathComponent().lastPathComponent)
      return (item: item, url: record.url)
    }
  }
  private var query: LibraryQuery {
    let words: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return LibraryQuery(
      text: words.isEmpty ? nil : words, kind: kind, assistant: assistant,
      dates: span.range(now: Date(), calendar: .current), limit: shownCount)
  }

  var body: some View {
    let all = entries
    let urls: [String: URL] = Dictionary(all.map { ($0.item.id, $0.url) }, uniquingKeysWith: { first, _ in first })
    let found: [SereinCore.LibraryItem] = query.run(all.map(\.item))
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Library").font(AssistantType.title).foregroundStyle(p.ink).accessibilityAddTraits(.isHeader)
        Spacer()
        Button(action: close) {
          Text("Done").font(AssistantType.meta).foregroundStyle(p.secondary).linkTarget()
        }.buttonStyle(.pressable)
          .keyboardShortcut(.cancelAction)
      }
      searchField
      filters
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          if all.isEmpty {
            note("Nothing here yet. Things your assistants keep show up here.")
          } else if found.isEmpty {
            note("No match for “\(text.trimmingCharacters(in: .whitespacesAndNewlines))”.")
          }
          ForEach(LibraryKind.allCases, id: \.self) { section in
            let items: [SereinCore.LibraryItem] = found.filter { $0.kind == section }
            if !items.isEmpty {
              Text(section.title).font(AssistantType.name).foregroundStyle(p.ink).padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
              if section == .photo {
                LibraryPhotoGrid(items: items, urls: urls)
              } else {
                ForEach(items) { item in LibraryResultRow(item: item, url: urls[item.id], owner: ownerName(item.assistant)) }
              }
            }
          }
          if found.count >= shownCount {
            Button { shownCount = min(LibraryQuery.maxLimit, shownCount + LibraryQuery.defaultLimit) } label: {
              Text("Show more").font(AssistantType.meta).foregroundStyle(p.accent).linkTarget()
            }.buttonStyle(.pressable)
          }
        }
      }
    }
    .padding(18)
    .frame(width: 520, height: 600)
    .background(p.overlay)
    .onAppear { searching = true }
    .onExitCommand(perform: close)
  }

  /// The search field from end to end: 36 high, its words and placeholder centred.
  private var searchField: some View {
    HStack(spacing: 8) {
      InterfaceIcon(systemName: "magnifyingglass", size: 14).foregroundStyle(p.secondary).accessibilityHidden(true)
      TextField("Search your library", text: $text)
        .textFieldStyle(.plain).font(AssistantType.body).focused($searching)
        .frame(maxWidth: .infinity).frame(height: 36)
        .accessibilityLabel("Search the library")
      if !text.isEmpty {
        Button { text = "" } label: {
          InterfaceIcon(systemName: "xmark", size: 10).foregroundStyle(p.overlay)
            .frame(width: 15, height: 15).background(p.secondary, in: Circle())
            .frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.pressable).accessibilityLabel("Clear the search")
      }
    }
    .padding(.horizontal, 12)
    .background(p.wash(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  /// Date, Type and Assistant, as chips that open their choices.
  private var filters: some View {
    HStack(spacing: 8) {
      Menu {
        ForEach(Span.allCases) { option in Button(option.title) { span = option } }
      } label: {
        chip("calendar", span == .any ? "Date" : span.title)
      }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Date, \(span.title)")
      Menu {
        Button("All") { kind = nil }
        ForEach(LibraryKind.allCases, id: \.self) { option in Button(option.title) { kind = option } }
      } label: {
        chip("square.grid.2x2", kind?.title ?? "Type")
      }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Type, \(kind?.title ?? "all")")
      Menu {
        Button("Anyone") { assistant = nil }
        ForEach(relay.team.profiles) { profile in Button(profile.name) { assistant = profile.id } }
      } label: {
        chip("person.2", assistant.map { ownerName($0) } ?? "Assistant")
      }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Assistant, \(assistant.map { ownerName($0) } ?? "anyone")")
      Spacer(minLength: 0)
    }
  }
  private func chip(_ icon: String, _ words: String) -> some View {
    HStack(spacing: 5) {
      InterfaceIcon(systemName: icon, size: 11)
      Text(verbatim: words).font(AssistantType.meta).lineLimit(1)
      InterfaceIcon(systemName: "chevron.down", size: 9)
    }
    .foregroundStyle(p.ink)
    .padding(.horizontal, 12).frame(height: 28)
    .background(p.wash(0.05), in: Capsule())
  }
  private func note(_ words: String) -> some View {
    Text(verbatim: words).font(AssistantType.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
  }
  private func ownerName(_ id: String?) -> String {
    guard let id else { return "you" }
    return relay.profileName(id)
  }
}

/// A row of the Library (`file-search`): a glyph, the name as written (middle truncation), "From
/// Scout, today", and the size in Geist Mono. A click opens it; its menu has Show in Finder.
private struct LibraryResultRow: View {
  let item: SereinCore.LibraryItem
  let url: URL?
  let owner: String
  @Environment(\.palette) private var p
  private var size: String {
    guard let url, let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return "" }
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }
  private var glyph: String {
    switch item.kind {
    case .photo: return "photo"
    case .audio: return "waveform"
    case .link: return "link"
    case .dashboard: return "square.grid.2x2"
    case .file: return "doc"
    }
  }
  var body: some View {
    Button { if let url { _ = NSWorkspace.shared.open(url) } } label: {
      HStack(spacing: 12) {
        InterfaceIcon(systemName: glyph, size: 16).foregroundStyle(p.secondary)
          .frame(width: 42, height: 42).background(p.wash(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: item.title).font(AssistantType.name).foregroundStyle(p.accent).lineLimit(1).truncationMode(.middle)
          Text(verbatim: "From \(owner), " + LibraryResultRow.day(item.date)).font(AssistantType.meta).foregroundStyle(p.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
        Text(size).font(AssistantType.figures).foregroundStyle(p.secondary)
      }.padding(.vertical, 6).contentShape(Rectangle())
    }
    .buttonStyle(.pressable)
    .contextMenu {
      if let url { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    }
    .accessibilityLabel("\(item.title), from \(owner), \(LibraryResultRow.day(item.date))")
  }
  static func day(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "today" }
    if calendar.isDateInYesterday(date) { return "yesterday" }
    return date.formatted(.dateTime.day().month(.abbreviated))
  }
}

/// Photos as a grid (`layout-photo-grid`): 140 by 110 tiles, radius 12, 8 apart, each a small
/// thumbnail read once with ImageIO (a skeleton until it is there). In the chat it shows 4 tiles
/// and "Show all {n}".
struct LibraryPhotoGrid: View {
  let items: [SereinCore.LibraryItem]
  let urls: [String: URL]
  /// In the chat: at most this many tiles, then "Show all {n}".
  var limit: Int? = nil
  var showAll: (() -> Void)? = nil
  @Environment(\.palette) private var p
  var body: some View {
    let shown: [SereinCore.LibraryItem] = limit.map { Array(items.prefix($0)) } ?? items
    VStack(alignment: .leading, spacing: 8) {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 160), spacing: 8)], alignment: .leading, spacing: 8) {
        ForEach(shown) { item in PhotoTile(item: item, url: urls[item.id]) }
      }
      if let showAll, shown.count < items.count {
        Button(action: showAll) {
          Text("Show all \(items.count)").font(AssistantType.meta).foregroundStyle(p.accent).linkTarget()
        }.buttonStyle(.pressable)
      }
    }
  }
}

private struct PhotoTile: View {
  let item: SereinCore.LibraryItem
  let url: URL?
  @State private var thumbnail: NSImage?
  @Environment(\.palette) private var p
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    Button { if let url { _ = NSWorkspace.shared.open(url) } } label: {
      ZStack {
        if let thumbnail {
          Image(nsImage: thumbnail).resizable().scaledToFill()
        } else {
          SkeletonBar(width: 140, height: 110, radius: 12)
        }
      }
      .frame(width: 140, height: 110).clipShape(shape).contentShape(shape)
    }
    .buttonStyle(AssistantPressStyle())
    .contextMenu {
      if let url { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    }
    .accessibilityLabel(item.title)
    .task(id: url) { thumbnail = url.flatMap { PhotoTile.thumbnail($0) } }
  }
  /// A thumbnail at most 320 pixels on its long side, without reading the whole picture.
  static func thumbnail(_ url: URL) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: 320,
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
  }
}
