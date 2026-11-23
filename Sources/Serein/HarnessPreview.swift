import Foundation
import SereinCore

extension HarnessRegistry {
  /// UI previews: a fixed, synthetic set of harness states (no probe, no CLI). Covers every
  /// state a row can show: ready, needs sign-in, update available, limited, not installed.
  func installSyntheticPreview() {
    let args = CommandLine.arguments
    ProviderStore.shared.installPreview(args.firstIndex(of: "--ui-providers").flatMap { args.dropFirst($0 + 1).first } ?? "mixed")
    let settings = HarnessSettings()
    var snapshots: [HarnessDriver: HarnessSnapshot] = [:]
    let now = Date()
    for instance in settings.instances {
      var s = HarnessSnapshot(instance: instance)
      s.checkedAt = now
      switch instance.driver {
      case .claude:
        s.installed = true
        s.version = "2.1.0"
        s.signedIn = true
        s.account = "Preview plan"
        s.models = Self.claudeManifest?.models(cliVersion: nil) ?? []
      case .codex:
        s.installed = true
        s.version = "0.150.0"
        s.signedIn = true
      case .cursor:
        s.installed = true
        s.version = "2026.01.01"
        s.signedIn = false
      case .opencode:
        s.installed = true
        s.version = "1.18.0"
        s.signedIn = true
        s.needsUpdate = true
        s.latestVersion = "1.19.0"
        s.account = "2 providers connected"
        s.models = [
          HarnessModel(id: "preview/fast-model", name: "Preview Fast", blurb: "Through OpenCode · Preview", subProvider: "Preview",
            options: [.effort(["low", "medium", "high"], default: "medium")]),
          HarnessModel(id: "preview/deep-model", name: "Preview Deep", blurb: "Through OpenCode · Preview", isNew: true, subProvider: "Preview"),
        ] + ProviderStore.shared.previewOpenCodeModels
      case .grok:
        s.installed = true
        s.version = "1.0.0"
        s.signedIn = true
      case .gemini:
        s.installed = true
        s.version = "1.0.0"
        s.signedIn = true
        s.acpArguments = ["--approval-mode", "default", "--acp"]
      case .pi, .ohMyPi:
        s.installed = false
      }
      s.path = s.installed ? "/usr/local/bin/" + instance.driver.binaries[0] : nil
      let (status, message) = HarnessSnapshot.summarize(s, name: instance.name)
      s.status = status
      s.message = message
      snapshots[instance.driver] = s
    }
    installPreview(snapshots, settings: settings)
  }
}
