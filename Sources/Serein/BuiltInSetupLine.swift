import SereinCore
import SwiftUI

/// Over the composer while Serein's computer downloads itself at an assistant's first need: 700 MB
/// shouldn't happen out of sight, and Cancel is the person's no (`BuiltInImage.cancel`). A download
/// started from Settings shows there instead.
struct BuiltInSetupLine: View {
  @ObservedObject private var image = BuiltInImage.shared
  @Environment(\.palette) private var p
  private static var preview: Bool { RunMode.previewing && CommandLine.arguments.contains("--ui-computer-setup") }

  var body: some View {
    if Self.preview || (image.working && image.automatic) {
      let share: Double? = Self.preview ? 0.34 : image.fraction
      HStack(spacing: 10) {
        Text("Setting up Serein's computer").font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1)
        if let share {
          ProgressView(value: share).progressViewStyle(.linear).tint(p.accent).frame(maxWidth: 140)
            .accessibilityLabel("Download progress")
        } else {
          ProgressView().controlSize(.mini).accessibilityLabel("Checking the download")
        }
        Spacer(minLength: 0)
        Button("Cancel") { image.cancel() }.buttonStyle(QuietButton())
          .accessibilityLabel("Cancel setting up Serein's computer")
      }.accessibilityElement(children: .contain)
    }
  }
}
