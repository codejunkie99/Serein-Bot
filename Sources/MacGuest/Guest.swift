import AppKit
import ScreenCaptureKit
import ApplicationServices
import Darwin
import SereinCore
import CryptoKit
import ServiceManagement

enum GuestGuard {
    static func requireVirtualMac() throws {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { throw MacGuestFailure("Cannot verify this is a virtual Mac; guest control is disabled") }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0,
              String(cString: bytes).hasPrefix("VirtualMac") else {
            throw MacGuestFailure("The guest helper only runs inside a virtual Mac. It will not control your host desktop.")
        }
    }
}

@MainActor
final class GuestRuntime: NSObject {
    var mailbox: MacMailbox
    private let exchange: URL
    private var lastMailboxRefresh = Date.distantPast
    var loop: Task<Void, Never>?
    var window: NSWindow?
    var label: NSTextField?
    var lastRequest = Date.distantPast

    let tools: URL
    var lastUpdateCheck = Date.distantPast
    var nativeHost = CommandLine.arguments.contains("--native-host") || UserDefaults.standard.bool(forKey: "nativeHostControl")

    init(exchange: URL) throws {
        try GuestGuard.requireVirtualMac()
        self.exchange = exchange
        tools = exchange.deletingLastPathComponent().appendingPathComponent("tools")
        mailbox = try MacMailbox(exchange)
        super.init()
    }
    func start() {
        if nativeHost { UserDefaults.standard.set(true, forKey: "nativeHostControl") }
        GuestBootstrap.registerForGuestLogin()
        NSApp.setActivationPolicy(nativeHost ? .accessory : .regular)
        if !nativeHost { showPermissionWindow() }
        loop = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                self.label?.stringValue = self.permissionStatus
                do {
                    // A saved-state restore can replace the virtio-fs server while the
                    // guest keeps an old directory handle. Reopen only this fixed private
                    // mailbox; MacMailbox still pins it and refuses links on every open.
                    let now = Date()
                    if nativeHost, abs(now.timeIntervalSince(lastMailboxRefresh)) >= 1 {
                        lastMailboxRefresh = now
                        mailbox = try MacMailbox(exchange)
                    }
                    for request in try mailbox.requests() {
                        lastRequest = Date()
                        // A command or a file may take a while: it is answered on its own, so
                        // screen and keyboard requests keep being answered meanwhile.
                        if MacGuestShell.actions.contains(request.action) {
                            Task { @MainActor [weak self] in await self?.handleShell(request) }
                        } else {
                            await handle(request)
                        }
                    }
                } catch { stderr(error.localizedDescription) }
                if Date().timeIntervalSince(lastUpdateCheck) > 30 { lastUpdateCheck = Date(); GuestBootstrap.updateFromSharedTools(tools) }
                try? await Task.sleep(nanoseconds: Date().timeIntervalSince(lastRequest) < 3 ? 3_000_000 : 40_000_000)
            }
        }
    }
    private func showPermissionWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Serein Computer"
        let title = NSTextField(labelWithString: "Connect Serein to this Mac")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString: "Allow Screen Recording and Accessibility here so Serein can use this virtual Mac. These permissions apply inside this Mac only.")
        let status = NSTextField(wrappingLabelWithString: permissionStatus)
        let capture = NSButton(title: "Allow Screen Recording", target: self, action: #selector(screenPermission))
        let accessibility = NSButton(title: "Allow Accessibility", target: self, action: #selector(accessibilityPermission))
        let buttons = NSStackView(views: [capture, accessibility]); buttons.orientation = .horizontal
        let login = NSButton(title: "Guest Login Items…", target: self, action: #selector(loginSettings))
        let stack = NSStackView(views: [title, description, status, buttons, login])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        self.window = window; self.label = status
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    var permissionStatus: String {
        "Screen Recording: \(CGPreflightScreenCaptureAccess() ? "allowed" : "needed")   ·   Accessibility: \(AXIsProcessTrusted() ? "allowed" : "needed")"
    }
    @objc func screenPermission() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc func accessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    @objc func loginSettings() { SMAppService.openSystemSettingsLoginItems() }
    func handle(_ request: MacGuestRequest) async {
        guard request.deadline > Date() else { return }
        do {
            try GuestGuard.requireVirtualMac()
            var values: [String: String] = [:]
            switch request.action {
            case "status":
                let bounds = CGDisplayBounds(CGMainDisplayID())
                values = ["screenRecording": String(CGPreflightScreenCaptureAccess()), "accessibility": String(AXIsProcessTrusted()),
                          "width": String(Int(bounds.width)), "height": String(Int(bounds.height)),
                          "build": Self.buildHash, "nativeHost": String(nativeHost),
                          "setupComplete": String(GuestBootstrap.offlineFilesReady
                            && !FileManager.default.fileExists(atPath: MacOfflineSetup.marker)
                            && NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.SetupAssistant").isEmpty
                            && !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").isEmpty),
                          "sessionUser": NSUserName(),
                          "frontmostBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
                          "offlineSetupVersion": String(UserDefaults.standard.integer(forKey: "offlineSetupVersion"))]
            case "clipboard":
                guard nativeHost, let text = request.arguments["text"], text.utf8.count <= 32768 else {
                    throw MacGuestFailure("The native text connection needs text of at most 32 KiB")
                }
                // This is the guest's clipboard only. The host posts the paste key into its
                // native VM view; no Accessibility or Screen Recording grant is needed here.
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(text, forType: .string) else {
                    throw MacGuestFailure("The virtual Mac could not receive the text")
                }
            case "native_host":
                // An already installed, hash-checked bridge can migrate without sending the
                // person through its old screen-control permission window again.
                nativeHost = true
                UserDefaults.standard.set(true, forKey: "nativeHostControl")
                window?.orderOut(nil); window = nil; label = nil
                NSApp.setActivationPolicy(.accessory)
            case "screenshot", "snapshot":
                guard CGPreflightScreenCaptureAccess() else { throw MacGuestFailure("Allow Screen Recording for Serein Computer inside the VM, then reopen the helper if macOS requests it") }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { throw MacGuestFailure("No guest display is available") }
                let config = SCStreamConfiguration()
                config.width = ComputerPolicy.screenWidth; config.height = ComputerPolicy.screenHeight
                config.showsCursor = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
                guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw MacGuestFailure("Cannot encode guest screenshot") }
                let filename = "image-\(request.id.uuidString).png"
                try mailbox.write(png, named: filename)
                values = ["image": filename, "width": String(image.width), "height": String(image.height)]
            case "click", "move":
                try requireAccessibility()
                let point = try coordinates(request)
                let right = request.arguments["button"] == "right"
                let middle = request.arguments["button"] == "middle"
                guard ["left", "right", "middle"].contains(request.arguments["button"] ?? "left") else { throw MacGuestFailure("Invalid mouse button") }
                let button: CGMouseButton = right ? .right : middle ? .center : .left
                if request.action == "move" { try postMouse(.mouseMoved, point: point, button: button) }
                else {
                    // `count` continues a multi-click the viewer already started, so a double click is two requests.
                    let count = try number(request, "count", fallback: 1, range: 1...3)
                    let clicks = request.arguments["double"] == "true" ? 1...2 : count...count
                    for n in clicks {
                        try postMouse(right ? .rightMouseDown : middle ? .otherMouseDown : .leftMouseDown, point: point, button: button, count: n)
                        try postMouse(right ? .rightMouseUp : middle ? .otherMouseUp : .leftMouseUp, point: point, button: button, count: n)
                    }
                }
            case "drag":
                try requireAccessibility()
                let start = try coordinates(request)
                let end = try coordinates(request, x: "x2", y: "y2")
                try postMouse(.leftMouseDown, point: start, button: .left)
                let steps = max(2, min(30, Int(hypot(end.x - start.x, end.y - start.y) / 12)))
                for step in 1...steps {
                    let t = Double(step) / Double(steps)
                    try postMouse(.leftMouseDragged, point: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t), button: .left)
                    try await Task.sleep(nanoseconds: 8_000_000)
                }
                try postMouse(.leftMouseUp, point: end, button: .left)
            case "scroll":
                try requireAccessibility()
                if request.arguments["x"] != nil { try postMouse(.mouseMoved, point: coordinates(request), button: .left) }
                let dy = try number(request, "dy", range: -1000...1000)
                let dx = Int(request.arguments["dx"] ?? "0") ?? 0
                guard (-1000...1000).contains(dx), let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { throw MacGuestFailure("Invalid scroll") }
                event.post(tap: .cghidEventTap)
            case "type":
                try requireAccessibility()
                guard let text = request.arguments["text"], text.utf8.count <= 32768 else { throw MacGuestFailure("Provide text (maximum 32 KiB)") }
                // Unicode events avoid modifying the guest or host clipboard.
                var chunk: [UniChar] = []
                func send() throws {
                    guard !chunk.isEmpty else { return }
                    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                          let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { throw MacGuestFailure("Cannot create keyboard event") }
                    // Literal text must not inherit modifiers from a preceding shortcut.
                    down.flags = []; up.flags = []
                    chunk.withUnsafeBufferPointer { ptr in down.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: ptr.baseAddress!) }
                    down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap); chunk.removeAll(keepingCapacity: true)
                }
                for character in text {
                    let units = Array(String(character).utf16)
                    if chunk.count + units.count > 16 { try send() }
                    chunk += units
                }
                try send()
            case "open_url":
                guard let raw = request.arguments["url"], let url = URL(string: raw),
                      ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                      url.user == nil, url.password == nil else { throw MacGuestFailure("Invalid website address") }
                guard NSWorkspace.shared.open(url) else { throw MacGuestFailure("The guest browser could not open the address") }
            case "key":
                try requireAccessibility()
                try press(request.arguments["key"] ?? "")
            default: throw MacGuestFailure("Unknown guest action: \(request.action)")
            }
            try mailbox.respond(MacGuestReply(id: request.id, values: values))
        } catch { try? mailbox.respond(MacGuestReply(id: request.id, error: error.localizedDescription)) }
    }
    /// Shell and files (GuestShell): a command, a file's text, a file for the Outbox.
    func handleShell(_ request: MacGuestRequest) async {
        guard request.deadline > Date() else { return }
        let box = mailbox
        do {
            try GuestGuard.requireVirtualMac()
            let values: [String: String]
            switch request.action {
            case "run":
                let seconds = min(MacGuestShell.timeout, max(1, Int(request.arguments["timeout"] ?? "") ?? MacGuestShell.timeout))
                values = try await GuestShell.run(request.arguments["command"] ?? "", timeout: seconds)
            case "read_file":
                values = try await GuestShell.read(request.arguments["path"] ?? "", start: max(0, Int(request.arguments["start"] ?? "0") ?? 0))
            case "file_out":
                values = try await GuestShell.fileOut(request.arguments["path"] ?? "", id: request.id, mailbox: box)
            default: throw MacGuestFailure("Unknown guest action: \(request.action)")
            }
            try box.respond(MacGuestReply(id: request.id, values: values))
        } catch { try? box.respond(MacGuestReply(id: request.id, error: error.localizedDescription)) }
    }
    static let buildHash: String = {
        guard let url = Bundle.main.executableURL, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }()
    func requireAccessibility() throws {
        guard AXIsProcessTrusted() else { throw MacGuestFailure("Allow Accessibility for Serein Computer inside the VM") }
    }
    func number(_ request: MacGuestRequest, _ key: String, fallback: Int? = nil, range: ClosedRange<Int>) throws -> Int {
        if request.arguments[key] == nil, let fallback { return fallback }
        guard let raw = request.arguments[key], let value = Int(raw), range.contains(value) else { throw MacGuestFailure("Invalid \(key); expected \(range)") }
        return value
    }
    func coordinates(_ request: MacGuestRequest, x: String = "x", y: String = "y") throws -> CGPoint {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: try number(request, x, range: 0...(Int(bounds.width) - 1)), y: try number(request, y, range: 0...(Int(bounds.height) - 1)))
    }
    func postMouse(_ type: CGEventType, point: CGPoint, button: CGMouseButton, count: Int = 1) throws {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { throw MacGuestFailure("Cannot create mouse event") }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        event.post(tap: .cghidEventTap)
    }
    func press(_ chord: String) throws {
        let parts = chord.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.last, let code = Self.keys[key] else { throw MacGuestFailure("Unknown key: \(chord). Example: cmd+space, return, ctrl+a") }
        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command", "super": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "option": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            default: throw MacGuestFailure("Unknown modifier: \(modifier)")
            }
        }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { throw MacGuestFailure("Cannot create key") }
            event.flags = flags; event.post(tap: .cghidEventTap)
        }
    }
    static let keys: [String: CGKeyCode] = [
        "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,
        "1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,"0":29,
        "]":30,"o":31,"u":32,"[":33,"i":34,"p":35,"return":36,"enter":36,"l":37,"j":38,"'":39,"k":40,";":41,"\\":42,",":43,"/":44,"n":45,"m":46,".":47,
        "tab":48,"space":49,"backspace":51,"escape":53,"esc":53,"home":115,"pageup":116,"delete":117,"end":119,"pagedown":121,
        "left":123,"right":124,"down":125,"up":126,"f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,"f7":98,"f8":100,"f9":101,"f10":109,"f11":103,"f12":111
    ]
}
