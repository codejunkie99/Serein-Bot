import SereinCore
import SwiftUI

/// Optional controls stay out of the desktop's first-run instructions.
struct MacComputerOptions: View {
  @ObservedObject var computer: ComputerHost.Computer
  @ObservedObject private var host = ComputerHost.shared
  @Environment(\.palette) var p
  var body: some View {
    DisclosureGroup("More") {
      VStack(alignment: .leading, spacing: 8) {
        Toggle("Network connection", isOn: Binding(
          get: { computer.macInternet }, set: { on in Task { await host.setMacInternet(on, for: computer) } }))
          .disabled(computer.starting != nil || computer.busy || computer.holder != nil)
        Text(computer.macInternet ? "Normal networking is on. Serein cannot enforce site lists on this Mac." : "Off. The virtual Mac cannot reach the internet, this Mac or your local network.")
          .font(UIStyle.micro).foregroundStyle(p.secondary)
        if let root = MacRestoreImage.shared.root {
          Text(verbatim: "Stored in \(root.path)").font(UIStyle.micro).foregroundStyle(p.secondary).textSelection(.enabled)
        }
      }.padding(.top, 8)
    }.font(UIStyle.meta).foregroundStyle(p.secondary)
  }
}
