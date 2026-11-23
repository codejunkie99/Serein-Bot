import SwiftUI

/// A message field and its controls in one card: attach, ask first, the AI app in use, dictation
/// and send. A footer strip under them names the folder in use and the connected apps.
struct ComposerCard: View {
  @Binding var text: String
  /// Serein asks before it acts while this is on.
  @Binding var asksFirst: Bool
  @Binding var model: String
  let models: [String]
  var placeholder = "Ask anything"
  /// The folder's name; nil shows "Work in a folder".
  var folder: String? = nil
  /// Connected apps as slug and name; the footer shows the first three logos.
  var apps: [(id: String, name: String)] = []
  var attach: () -> Void = {}
  var dictate: () -> Void = {}
  var pickFolder: () -> Void = {}
  var connectApps: () -> Void = {}
  let send: () -> Void
  @FocusState private var focused: Bool
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var reduce
  private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: AssistantMetrics.sheetRadius, style: .continuous)
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        TextField(placeholder, text: $text, axis: .vertical).textFieldStyle(.plain).lineLimit(1...6)
          .font(AssistantType.bubble).foregroundStyle(p.ink).focused($focused)
          .onSubmit { if !empty { send() } }
          .shiftReturnNewLine()
        HStack(spacing: 6) {
          icon("plus", label: "Add a file", action: attach)
          Button { withAnimation(Motion.swapping(reduce)) { asksFirst.toggle() } } label: {
            HStack(spacing: 5) {
              InterfaceIcon(systemName: "hand.raised", size: 12)
              Text("Ask first")
            }
          }.buttonStyle(PillButton(kind: asksFirst ? .tinted : .quiet, small: true))
            .accessibilityValue(asksFirst ? "On" : "Off").help("Serein asks before it acts")
          Spacer(minLength: 8)
          // The system's own menu button: a drawn label loses its order inside a borderless menu.
          Menu(model) {
            ForEach(models, id: \.self) { name in Button(name) { model = name } }
          }.menuStyle(.borderlessButton).fixedSize().font(AssistantType.meta).accessibilityLabel("AI app")
          icon("mic", label: "Dictate", action: dictate)
          Button(action: send) {
            InterfaceIcon(systemName: "arrow.up", size: 13).foregroundStyle(empty ? p.faint : p.onAccent)
              .frame(width: 28, height: 28).background(empty ? p.track : p.accent, in: Circle())
          }.buttonStyle(AssistantPressStyle()).disabled(empty).accessibilityLabel("Send")
            .animation(Motion.swapping(reduce), value: empty)
        }
      }.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
      HStack(spacing: 8) {
        Button(action: pickFolder) {
          HStack(spacing: 6) {
            InterfaceIcon(systemName: "folder", size: 13)
            Text(folder ?? "Work in a folder").lineLimit(1).truncationMode(.middle)
          }
        }.buttonStyle(AssistantPressStyle())
        Spacer(minLength: 8)
        Button(action: connectApps) {
          HStack(spacing: 6) {
            Text("Connect apps")
            HStack(spacing: 3) {
              ForEach(apps.prefix(3), id: \.id) { app in AppLogoTile(id: app.id, name: app.name, size: 16) }
            }
          }
        }.buttonStyle(AssistantPressStyle())
      }.font(AssistantType.meta).foregroundStyle(p.secondary)
        .padding(.horizontal, 14).frame(height: 36).background(p.track)
    }
    .clipShape(shape).assistantCard(p, radius: AssistantMetrics.sheetRadius)
    .overlay(shape.strokeBorder(focused ? p.borderStrong : p.line, lineWidth: 1))
    .animation(Motion.swapping(reduce), value: focused)
    .frame(maxWidth: AssistantMetrics.column)
  }

  private func icon(_ name: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      InterfaceIcon(systemName: name, size: 15).foregroundStyle(p.secondary).frame(width: 28, height: 28)
    }.buttonStyle(AssistantPressStyle()).accessibilityLabel(label).help(label)
  }
}
