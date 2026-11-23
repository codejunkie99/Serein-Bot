import AppKit
import ImageIO
import SereinCore
import SwiftUI
import UniformTypeIdentifiers

/// Pictures assistants wear (`AssistantIcon.picture`): read once from an image the person chose,
/// its middle square scaled to 128 pixels as a PNG, and kept in the assistant's own folder in the
/// Library (0700, the picture 0600), which no agent reads. Only the marks draw them; no prompt,
/// tool answer or team file ever holds one.
@MainActor enum AssistantPictures {
  /// The largest file read: anything bigger is refused before it is opened.
  static let maxBytes = 40 * 1024 * 1024
  /// Drawn pictures by file name; a name is never reused, so an entry never goes stale. A missing
  /// file is remembered too, so a mark does not look for it on every redraw.
  private static var cache: [String: NSImage?] = [:]

  /// The picture a mark draws; nil while it is missing (the mark shows the petal).
  static func image(_ name: String, owner: String) -> NSImage? {
    if let cached = cache[name] { return cached }
    guard AssistantIcon.isPictureName(name), let relay = SereinSurface.controller?.relay else { return nil }
    let image = NSImage(contentsOf: file(name, owner: owner, relay: relay))
    cache.updateValue(image, forKey: name)
    return image
  }
  static func file(_ name: String, owner: String, relay: RelayOrchestrator) -> URL {
    relay.browser.library.root.appendingPathComponent(relay.team.folder(owner), isDirectory: true)
      .appendingPathComponent(name)
  }

  /// The open panel for a picture; nil when cancelled (and under checks and previews).
  static func choose() -> URL? {
    guard !RunMode.automated else { return nil }
    let panel = NSOpenPanel()
    panel.title = "Choose a Picture"
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }

  /// Reads a chosen image once: its middle square, 128 pixels a side, as PNG data under a new name
  /// that marks can show at once (the editor's preview, before Save writes it). nil when the file
  /// is too large or is not an image.
  static func read(_ url: URL) -> (name: String, png: Data)? {
    // The size first: a file over the limit is never read.
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
    guard size <= maxBytes, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
      let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue,
      let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue, width > 0, height > 0
    else { return nil }
    let side = Double(AssistantIcon.picturePixels)
    // The shorter side comes out at 128 pixels; the longer one is then cut to its middle.
    let longest = min((side * max(width, height) / min(width, height)).rounded(.up), side * 16)
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: Int(longest),
    ]
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let edge = min(thumbnail.width, thumbnail.height)
    let square = CGRect(x: (thumbnail.width - edge) / 2, y: (thumbnail.height - edge) / 2, width: edge, height: edge)
    let out = NSMutableData()
    guard let cropped = thumbnail.cropping(to: square),
      let destination = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, cropped, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    let png = out as Data
    let name = AssistantIcon.pictureName()
    cache.updateValue(NSImage(data: png), forKey: name)
    return (name, png)
  }

  /// Writes a picture `read` made into the assistant's folder; one that cannot be made private is
  /// removed. False when it was not saved.
  static func save(_ png: Data, as name: String, owner: String, relay: RelayOrchestrator) -> Bool {
    guard AssistantIcon.isPictureName(name) else { return false }
    let url = file(name, owner: owner, relay: relay)
    let fm = FileManager.default
    do {
      try fm.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      guard fm.createFile(atPath: url.path, contents: png, attributes: [.posixPermissions: 0o600]) else { return false }
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      return true
    } catch {
      try? fm.removeItem(at: url)
      return false
    }
  }
}

/// The icon choice, in the editor and in the inspector's popover: Petal · Emoji · Symbol · Picture,
/// then the choice itself. Each pick goes to `choose` (a new picture with its PNG data, read once
/// and not saved yet), which answers why it was refused or nil.
struct AssistantIconPicker: View {
  let name: String
  var tint: String?
  var icon: AssistantIcon?
  var choose: (AssistantIcon?, Data?) -> String?
  enum Kind: String, CaseIterable { case petal = "Petal", emoji = "Emoji", symbol = "Symbol", picture = "Picture" }
  @State private var kind: Kind
  @State private var emoji: String
  @State private var error: String?
  @Environment(\.palette) var p
  init(name: String, tint: String?, icon: AssistantIcon?, choose: @escaping (AssistantIcon?, Data?) -> String?) {
    self.name = name
    self.tint = tint
    self.icon = icon
    self.choose = choose
    switch icon {
    case nil: _kind = State(initialValue: .petal)
    case .emoji?: _kind = State(initialValue: .emoji)
    case .symbol?: _kind = State(initialValue: .symbol)
    case .picture?: _kind = State(initialValue: .picture)
    }
    if case .emoji(let text)? = icon { _emoji = State(initialValue: text) } else { _emoji = State(initialValue: "") }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker("Icon", selection: $kind) {
        ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Icon")
        .onChange(of: kind) { _, now in
          error = nil
          // Petal applies at once; an emoji already typed too. Symbol and Picture wait for a pick.
          if now == .petal { pick(nil) }
          if now == .emoji, let typed = AssistantIcon.cleanEmoji(emoji) { pick(typed) }
        }
      switch kind {
      case .petal:
        Text("The petal in \(name)'s colour.").role(.meta)
      case .emoji:
        HStack(spacing: 8) {
          TextField("One emoji", text: $emoji).textFieldStyle(.serein).frame(width: 96)
            .accessibilityLabel("Emoji")
            .onChange(of: emoji) { _, value in
              guard !value.isEmpty else { error = nil; return }
              if let typed = AssistantIcon.cleanEmoji(value) { pick(typed) } else { error = "Use one emoji." }
            }
          Button("Emoji & Symbols") { NSApp.orderFrontCharacterPalette(nil) }.buttonStyle(QuietButton())
            .help("Opens the emoji viewer")
        }
      case .symbol:
        FlowLayout(spacing: 4) {
          ForEach(AssistantIcon.symbols, id: \.self) { symbol in
            let selected = icon == .symbol(symbol)
            Button { pick(.symbol(symbol)) } label: {
              InterfaceIcon(systemName: symbol, size: 14).foregroundStyle(p.assistantTint(tint))
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(p.ink, lineWidth: 2).opacity(selected ? 1 : 0))
                .contentShape(Circle())
            }.buttonStyle(.pressable).hoverWash(in: Circle())
              .accessibilityLabel(AssistantIcon.symbolLabels[symbol] ?? symbol)
              .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
          }
        }.accessibilityElement(children: .contain).accessibilityLabel("Symbols")
      case .picture:
        Button(icon?.pictureFile == nil ? "Choose Picture…" : "Choose Another…", action: choosePicture)
          .buttonStyle(QuietButton())
        Text("Serein keeps a small copy on this Mac. It is never shown to an assistant or an AI app.").role(.meta)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let error { Text(error).font(UIStyle.micro).foregroundStyle(p.danger) }
    }
  }
  private func pick(_ next: AssistantIcon?, picture: Data? = nil) {
    guard next != icon || picture != nil else { return }
    error = choose(next, picture)
  }
  private func choosePicture() {
    guard let url = AssistantPictures.choose() else { return }
    guard let read = AssistantPictures.read(url) else {
      error = "Serein couldn't read that picture. Choose a photo or an image file."
      return
    }
    pick(.picture(read.name), picture: read.png)
  }
}

/// An assistant's mark that follows its own state, for the places that do not already hold it
/// (the hand-off rows): it watches what `RelayOrchestrator.assistantStatus` reads.
struct AssistantLiveMark: View {
  let relay: RelayOrchestrator
  let profile: RelayProfile?
  var size: CGFloat = 16
  var body: some View {
    AssistantLiveMarkBody(relay: relay, agent: relay.agent, hub: relay.agent.hub, profile: profile, size: size)
  }
}
private struct AssistantLiveMarkBody: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject var agent: AgentModel
  @ObservedObject var hub: AgentHub
  let profile: RelayProfile?
  let size: CGFloat
  @ObservedObject private var network = NetworkMonitor.shared
  @ObservedObject private var surface = SereinSurface.main
  var body: some View {
    let status = profile.map {
      relay.assistantStatus($0.id, hub: hub, online: SereinSurface.online(network.online),
                            connected: SereinSurface.connected(agent), unread: surface.unread)
    }
    AssistantMark(profile: profile, size: size, status: status)
  }
}

/// The typing dots after a speaker's mark while its reply streams in: Core Animation's loop, or
/// three still dots under Reduce Motion. VoiceOver already hears the reply.
struct ReplyTypingDots: View {
  @Environment(\.palette) var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  var body: some View {
    Group {
      if systemReduceMotion || previewReducedEffects {
        HStack(spacing: 2) {
          ForEach(0..<3, id: \.self) { _ in Circle().fill(p.secondary).frame(width: 3, height: 3) }
        }
      } else {
        TypingDots(color: p.secondary)
      }
    }.frame(width: 15, height: 6).accessibilityHidden(true)
  }
}
