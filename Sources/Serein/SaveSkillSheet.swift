import SereinCore
import SwiftUI

/// Save as Skill: the how-to Serein drafted from a finished task (`TaskSkill.draft`), for the
/// person to edit, then save with the plugins' skills (`PluginHost.saveSkill`). It saves off;
/// the person turns it on in Settings › Plugins.
@MainActor struct SaveSkillSheet: View {
  let close: () -> Void
  /// After a skill saved: the chat's offer under its reply never comes back (SkillOfferLine).
  var saved: (() -> Void)? = nil
  @State private var name: String
  @State private var whenToUse: String
  @State private var steps: String
  @State private var error: String?
  @Environment(\.palette) var p
  init(draft: TaskSkillDraft, saved: (() -> Void)? = nil, close: @escaping () -> Void) {
    self.close = close
    self.saved = saved
    _name = State(initialValue: draft.name)
    _whenToUse = State(initialValue: draft.whenToUse)
    _steps = State(initialValue: draft.steps)
  }
  /// Save waits for a skill name the person typed, and for both texts.
  private var ready: Bool {
    TaskSkill.isName(name.trimmingCharacters(in: .whitespaces))
      && ![whenToUse, steps].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Save as Skill").role(.section)
      Text("A skill is a note for the assistant. It doesn't give any new access.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      field("Name") {
        TextField("weekly-expenses", text: $name).textFieldStyle(.serein).accessibilityLabel("Name")
      }
      field("When to use it") {
        TextField("When the person asks for…", text: $whenToUse, axis: .vertical).lineLimit(2...4)
          .textFieldStyle(.serein).accessibilityLabel("When to use it")
      }
      field("Steps") {
        TextEditor(text: $steps).font(UIStyle.mono(12)).scrollContentBackground(.hidden)
          .frame(height: 220).padding(8)
          .background(p.background, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
          .overlay(RoundedRectangle(cornerRadius: UIStyle.controlRadius).stroke(p.borderStrong))
          .accessibilityLabel("Steps")
      }
      Text("Serein wrote these steps in its own words, with no page text or anything typed. Add the request yourself.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      Text("Name it with lowercase words joined by hyphens. It stays off until you turn it on in Settings › Plugins.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      if let error { Text(error).role(.meta).foregroundStyle(p.danger) }
      HStack {
        Spacer()
        Button("Cancel") { close() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
        Button("Save Skill") { save() }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction).disabled(!ready)
      }
    }.padding(24).frame(width: UIStyle.wide(520)).background(p.panel)
  }
  /// A field under its visible name (VoiceOver reads the field's own label).
  private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(UIStyle.metaStrong).foregroundStyle(p.ink).accessibilityHidden(true)
      content()
    }
  }
  private func save() {
    do {
      let package = try PluginHost.shared.saveSkill(TaskSkillDraft(name: name, whenToUse: whenToUse, steps: steps))
      ToastCenter.shared.show("Saved the skill \(package.name). It stays off until you turn it on in Settings › Plugins.")
      saved?()
      close()
    } catch { self.error = error.localizedDescription }
  }
}
