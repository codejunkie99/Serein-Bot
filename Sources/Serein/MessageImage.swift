import AppKit
import SwiftUI

/// A picture in a chat message: a screenshot the agent took (AgentMessage.images) or a line that
/// is only a Markdown image. Only a local image file in the chat's folders shows (`file`). A web
/// address stays text, so a chat loads nothing from a server. A click opens the picture full size
/// in Serein (`PictureViewer`), not in another app.
struct MessageImage: View {
  let source: String
  var alt = ""
  /// A sent picture in the person's bubble: small, beside its words.
  var thumbnail = false
  @Environment(\.palette) private var p
  @Environment(\.chatFolder) private var folder
  @State private var viewing = false
  var body: some View {
    if let url = Self.file(source, folder: folder), let image = Self.image(url) {
      Button { viewing = true } label: {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
          .frame(maxWidth: min(thumbnail ? 220 : 560, image.size.width), maxHeight: thumbnail ? 180 : 420,
                 alignment: thumbnail ? .trailing : .leading)
          .clipShape(RoundedRectangle(cornerRadius: thumbnail ? 14 : 10, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: thumbnail ? 14 : 10, style: .continuous).stroke(p.line))
      }.buttonStyle(.pressable).help("View the picture")
        .accessibilityLabel(alt.isEmpty ? "Picture" : alt)
        // Copy it out, or drag it into another app, as the file it is.
        .contextMenu {
          Button("Copy Image") { Self.copy(image, url: url) }
          Button("Open in \(PictureViewer.appName(for: url))") { NSWorkspace.shared.open(url) }
          Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .sheet(isPresented: $viewing) {
          PictureViewer(items: [.init(url: url, name: alt.isEmpty ? url.lastPathComponent : alt, kind: .image)]) { viewing = false }
            .environment(\.palette, p)
        }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .accessibilityAction(named: "Copy Image") { Self.copy(image, url: url) }
    } else {
      Text(verbatim: alt.isEmpty ? source : "\(alt) (\(source))").font(UIStyle.meta)
        .foregroundStyle(p.secondary).textSelection(.enabled)
    }
  }

  /// The picture on the clipboard, as the image and as its file, so it pastes into apps either way.
  static func copy(_ image: NSImage, url: URL) {
    let board = NSPasteboard.general
    board.clearContents()
    board.writeObjects([image, url as NSURL])
  }

  static let kinds: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"]
  /// The local image file `source` names (an absolute path, a file:// address, a ~/ path or a
  /// path in the library), or nil: a web address, a file outside the chat's folders, another kind
  /// of file, one over 20 MB, or a missing one. The chat's folders are the library's chat-images
  /// and Anywhere folders and the thread's project (`folder`), with symlinks resolved, so an agent
  /// a page steers cannot show other files (Messages attachments, Photos) in the chat.
  @MainActor static func file(_ source: String, library: URL? = nil, folder: URL? = nil) -> URL? {
    // Serein's own chat can draw before the menus set BrowserContext; its router knows the library too.
    guard let library = library ?? BrowserContext.browser?.library.root ?? SereinRouter.browser?.library.root else { return nil }
    var path = source
    if path.hasPrefix("file://") {
      guard let url = URL(string: path), url.isFileURL else { return nil }
      path = url.path
    } else if path.hasPrefix("~/") {
      path = NSHomeDirectory() + String(path.dropFirst(1))
    } else if !path.hasPrefix("/") {
      path = library.appendingPathComponent(path).path
    }
    func real(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
    let url = URL(fileURLWithPath: real(URL(fileURLWithPath: path)))
    let roots = [library.appendingPathComponent("chat-images"), library.appendingPathComponent("Anywhere")]
      + (folder.map { [$0] } ?? [])
    guard roots.contains(where: { url.path.hasPrefix(real($0) + "/") }),
      kinds.contains(url.pathExtension.lowercased()),
      let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
      size <= 20_000_000
    else { return nil }
    return url
  }
  /// Decoded once: a transcript redraws often while a reply streams.
  private static let cache = NSCache<NSURL, NSImage>()
  static func image(_ url: URL) -> NSImage? {
    if let image = cache.object(forKey: url as NSURL) { return image }
    guard let image = NSImage(contentsOf: url) else { return nil }
    cache.setObject(image, forKey: url as NSURL)
    return image
  }
}

/// The thread's project folder, where MessageImage may also show pictures. A plain key, not
/// `@Entry`.
private struct ChatFolderKey: EnvironmentKey {
  static let defaultValue: URL? = nil
}

extension EnvironmentValues {
  var chatFolder: URL? {
    get { self[ChatFolderKey.self] }
    set { self[ChatFolderKey.self] = newValue }
  }
}
