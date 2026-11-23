import AppKit
import SereinCore

@main struct GuestEntry {
  @MainActor static func main() {
    do { try GuestGuard.requireVirtualMac() }
    catch { stderr(error.localizedDescription); exit(1) }
    let app = NSApplication.shared
    let delegate = GuestApplication()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}

@MainActor private final class GuestApplication: NSObject, NSApplicationDelegate {
  private var runtime: GuestRuntime?
  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { @MainActor in
      do {
        try await GuestBootstrap.finishOfflineSetupIfNeeded()
        if try await GuestBootstrap.installAndRelaunchIfNeeded() { NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--native-host") {
          let deadline = Date().addingTimeInterval(120)
          while !FileManager.default.fileExists(atPath: "/Volumes/My Shared Files/control"), Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
          }
        }
        let runtime = try GuestRuntime(exchange: URL(fileURLWithPath: "/Volumes/My Shared Files/control", isDirectory: true))
        self.runtime = runtime
        runtime.start()
      } catch {
        if CommandLine.arguments.contains("--native-host") {
          let message = "Serein's private Mac connection could not start: \(error.localizedDescription)\n"
          stderr(message)
          try? Data(message.utf8).write(to: URL(fileURLWithPath: MacOfflineSetup.home + "/Library/Application Support/Serein/setup-error.log"), options: .atomic)
          exit(1)
          return
        }
        let alert = NSAlert()
        alert.messageText = "Connect Serein to this Mac"
        alert.informativeText = error.localizedDescription
        alert.runModal()
        NSApp.terminate(nil)
      }
    }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

func stderr(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
