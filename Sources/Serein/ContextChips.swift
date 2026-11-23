import AppKit
import SereinCore
import SwiftUI
import UniformTypeIdentifiers

/// Removable chips for what goes with the next message, plus "Show what will be sent".
struct ContextChips: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @ObservedObject var context = ComposerContext.shared
  /// The task panel shows its own eye toggle for "what will be sent" instead.
  var sentToggle = true
  @State private var showSent = false
  @Environment(\.palette) var p
  var awaitingApproval: Bool {
    context.awaitingApproval.contains(agent.conversationID) && !agent.running
  }
  var lastSent: String? {
    context.lastSent[agent.conversationID].flatMap { $0.isEmpty ? nil : $0 }
  }
  var visible: Bool {
    context.hasChips || context.planMode || awaitingApproval || context.pointing
      || context.notice != nil || (sentToggle && lastSent != nil)
  }
  var body: some View {
    // A task reply's plan while it waits for the person's yes: the plan to edit, then Start.
    let reply: AgentMessage? = awaitingApproval ? agent.messages.last(where: { $0.role == "assistant" }) : nil
    let plan: PlanDraft? = reply.flatMap { PlanDraft(reply: $0.text) }
    if visible {
      VStack(alignment: .leading, spacing: 8) {
        if context.hasChips || context.planMode || context.pointing {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) { chips }
          }
        }
        if let plan, let reply {
          PlanDraftCard(draft: plan, start: { agent.send($0) }).id(reply.id)
        }
        HStack(spacing: 10) {
          if sentToggle && (context.hasChips || context.planMode || lastSent != nil) {
            Button(showSent ? "Hide details" : context.hasChips || context.planMode ? "Show what will be sent" : "Show what was sent") {
              showSent.toggle()
            }.buttonStyle(.pressable).font(UIStyle.meta).foregroundStyle(p.secondary)
              .accessibilityHint("Shows the exact text that goes to the agent with your message")
          }
          if awaitingApproval, plan == nil {
            Button("Go ahead with the plan") { agent.send("Go ahead") }
              .buttonStyle(QuietButton()).font(UIStyle.meta)
              .help("Sends “Go ahead”. In a project, the agent may edit files for this one reply.")
          }
          if let notice = context.notice {
            Text(notice).role(.meta).lineLimit(2)
            Button {
              context.notice = nil
            } label: {
              InterfaceIcon(systemName: "xmark", size: 10).frame(width: 20, height: 20)
            }.buttonStyle(QuietButton()).accessibilityLabel("Dismiss")
          }
          Spacer(minLength: 0)
        }
        if showSent {
          ScrollView {
            Text(sentText).font(UIStyle.microMono).foregroundStyle(p.secondary)
              .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
          }.frame(maxHeight: 220).background(
            p.track, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius)
          )
        }
      }.padding(.horizontal, 16).padding(.top, 12)
    }
  }
  var sentText: String {
    if context.hasChips || context.planMode {
      let text = context.preview(browser: browser, agent: agent, draft: agent.draft)
      return text.isEmpty ? "Only your message." : text
    }
    return lastSent ?? "Only your message."
  }
  @ViewBuilder var chips: some View {
    if context.pointing {
      ContextChip(icon: "scope", text: "Pointing… click part of the page", detail: "Esc cancels") {
        if let tab = browser.active { PagePointer.cancel(tab) }
      }
    }
    if let page = context.page {
      ContextChip(
        icon: "globe", text: page.title.isEmpty ? page.url : page.title,
        detail: page.sensitive
          ? "Page text not included: password or payment fields"
          : page.unavailable ? "Only the address and title" : "Page") { context.page = nil }
    }
    if let selection = context.selection {
      ContextChip(
        icon: "text.quote",
        text: "Selected text · “\(selection.text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(40))”",
        detail: nil
      ) { context.selection = nil }
    }
    ForEach(Array(context.elements.enumerated()), id: \.element.id) { index, element in
      ContextChip(
        icon: "cursorarrow.rays", text: "\(index + 1) · \(element.label)",
        detail: element.sensitive
          ? "Position and styles only" : element.picture == nil ? "Details only" : "With a picture"
      ) { context.elements.removeAll { $0.id == element.id } }
    }
    ForEach(context.tabs) { tab in
      ContextChip(
        icon: "rectangle.on.rectangle", text: tab.title.isEmpty ? tab.url : tab.title,
        detail: tab.sensitive ? "Text not included" : tab.unavailable ? "Reading…" : "Tab"
      ) { context.tabs.removeAll { $0.id == tab.id } }
    }
    ForEach(context.pictures) { picture in
      ContextChip(icon: "photo", text: picture.name, detail: "Picture") {
        context.pictures.removeAll { $0.id == picture.id }
      }
    }
    ForEach(context.documents) { document in
      ContextChip(icon: "doc.text", text: document.name, detail: DocumentText.detail(document)) {
        context.documents.removeAll { $0.id == document.id }
      }
    }
    if let console = context.console {
      ContextChip(
        icon: "exclamationmark.triangle", text: "Page errors (\(console.entries.count))",
        detail: "From \(console.title.isEmpty ? console.url : console.title)"
      ) { context.console = nil }
    }
    if context.planMode {
      ContextChip(icon: "list.number", text: "Plan first", detail: "Proposes changes and makes none") {
        context.planMode = false
      }
    }
  }
}

struct ContextChip: View {
  var icon: String
  var text: String
  var detail: String?
  var remove: () -> Void
  @Environment(\.palette) var p
  var body: some View {
    HStack(spacing: 6) {
      InterfaceIcon(systemName: icon, size: 12).foregroundStyle(p.secondary)
      Text(text).font(UIStyle.meta).lineLimit(1).truncationMode(.middle)
        .frame(maxWidth: 200, alignment: .leading)
      Button(action: remove) {
        InterfaceIcon(systemName: "xmark", size: 9).foregroundStyle(p.secondary)
          .frame(width: 20, height: 20).contentShape(Rectangle())
      }.buttonStyle(.pressable).help("Remove").accessibilityLabel("Remove \(text)")
    }.padding(.leading, 10).padding(.trailing, 3).frame(height: 26)
      .background(p.track, in: Capsule())
      .help(detail.map { "\(text) · \($0)" } ?? text)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(detail.map { "\(text), \($0)" } ?? text)
  }
}

/// Pictures and documents dropped or pasted into the composer; dropped links go into the draft.
struct ComposerDrop: ViewModifier {
  @ObservedObject var agent: AgentModel
  @State private var targeted = false
  @Environment(\.palette) var p
  func body(content: Content) -> some View {
    content
      .overlay {
        if targeted {
          RoundedRectangle(cornerRadius: UIStyle.composerRadius).stroke(p.accent, lineWidth: 2)
            .allowsHitTesting(false)
        }
      }
      .onDrop(of: [.image, .fileURL, .url], isTargeted: $targeted) { providers in
        Self.accept(providers, agent: agent)
      }
      .onPasteCommand(of: [.png, .tiff, .image, .fileURL]) { providers in
        _ = Self.accept(providers, agent: agent)
      }
  }
  @MainActor static func accept(_ providers: [NSItemProvider], agent: AgentModel) -> Bool {
    var handled = false
    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        handled = true
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
          guard let url else { return }
          let isImage = (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image)) == true
          let data = isImage ? try? Data(contentsOf: url) : nil
          Task { @MainActor in
            if let data {
              ComposerContext.shared.attachPicture(data, name: url.lastPathComponent)
            } else if DocumentText.kind(url) != nil {
              ComposerContext.shared.attachDocument(url)
            } else {
              ComposerContext.shared.notice =
                "Serein attaches pictures and PDF, text, Markdown, CSV, RTF or Word files."
            }
          }
        }
      } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        handled = true
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
          guard let data else { return }
          Task { @MainActor in ComposerContext.shared.attachPicture(data, name: "Pasted picture") }
        }
      } else if provider.canLoadObject(ofClass: URL.self) {
        handled = true
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
          guard let url, ["http", "https"].contains(url.scheme ?? "") else { return }
          Task { @MainActor in
            agent.draft += (agent.draft.isEmpty || agent.draft.hasSuffix(" ") ? "" : " ")
              + url.absoluteString
          }
        }
      }
    }
    return handled
  }
  @MainActor static func chooseFiles() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.image] + DocumentText.types
    panel.prompt = "Attach"
    panel.message = "Choose pictures or documents to send with your message. Serein reads documents on this Mac."
    guard panel.runModal() == .OK else { return }
    for url in panel.urls {
      if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
        if let data = try? Data(contentsOf: url) {
          ComposerContext.shared.attachPicture(data, name: url.lastPathComponent)
        }
      } else {
        ComposerContext.shared.attachDocument(url)
      }
    }
  }
}

extension View {
  func composerDrop(_ agent: AgentModel) -> some View { modifier(ComposerDrop(agent: agent)) }
}
