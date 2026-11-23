import AppKit
import CoreGraphics
import SereinCore
import SwiftUI
import Virtualization

/// Serein's fixed native renderer stays in its own window; person views mirror the same VM.
/// Views are never moved between windows, which would tear down their native display surface.
/// Only the private render window is captured. Host input and clipboard are never posted.
@MainActor final class MacNativeDisplay {
  private let renderWindow: RenderWindow
  private let renderContainer: NSView
  private let view: InputView
  private weak var personView: InputView?
  private var lockFlags: NSEvent.ModifierFlags = []
  private var lastWake = Date.distantPast
  private var lastInput = Date.distantPast
  private var wakeTimer: Timer?

  init(machine: VZVirtualMachine, personAllowed: @escaping () -> Bool, personActed: @escaping (String) -> Void) {
    let frame = NSRect(x: (NSScreen.screens.map { $0.frame.maxX }.max() ?? 1500) + 64,
                       y: 0, width: CGFloat(ComputerPolicy.screenWidth), height: CGFloat(ComputerPolicy.screenHeight))
    renderWindow = RenderWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    renderWindow.isReleasedWhenClosed = false
    renderWindow.isExcludedFromWindowsMenu = true
    renderWindow.ignoresMouseEvents = true
    renderWindow.canHide = false
    renderWindow.collectionBehavior = [.stationary, .ignoresCycle]
    view = InputView(frame: NSRect(origin: .zero, size: frame.size))
    view.autoresizingMask = [.width, .height]
    view.capturesSystemKeys = false
    view.automaticallyReconfiguresDisplay = false
    view.virtualMachine = machine
    view.personAllowed = personAllowed
    renderContainer = NSView(frame: NSRect(origin: .zero, size: frame.size))
    view.touch = { [weak self] in self?.lastInput = Date() }
    view.personActed = personActed
    renderWindow.contentView = renderContainer
    renderContainer.addSubview(view)
    renderWindow.orderBack(nil)
    let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.view.virtualMachine?.state == .running else { return }
        self.wake()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    wakeTimer = timer
  }

  func close() {
    wakeTimer?.invalidate(); wakeTimer = nil
    personView?.capturesSystemKeys = false
    personView?.virtualMachine = nil
    view.virtualMachine = nil
    view.removeFromSuperview()
    renderWindow.close()
  }

  func makePersonView() -> InputView {
    let live = InputView(frame: .zero)
    live.automaticallyReconfiguresDisplay = false
    updatePersonView(live)
    return live
  }
  func updatePersonView(_ live: InputView) {
    live.personAllowed = view.personAllowed
    live.personActed = view.personActed
    live.touch = { [weak self] in self?.lastInput = Date() }
    live.lockChanged = { [weak self] in self?.lockFlags = $0 }
    if live.virtualMachine !== view.virtualMachine { live.virtualMachine = view.virtualMachine }
    live.capturesSystemKeys = live.personAllowed()
    personView = live
  }

  func image() throws -> CGImage {
    let window = renderWindow
    guard view.virtualMachine?.state == .running, view.window === window, window.isVisible,
      NSApp.windows.contains(where: { $0 === window }),
      // The ID comes only from this private NSWindow; never from agent or guest input.
      let captured = CGWindowListCreateImage(.null, .optionIncludingWindow,
        CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])
    else { throw SereinError.invalid("Serein is connecting its virtual Mac display. Try again in a moment.") }
    // Only this fixed private renderer is sampled, even while a person uses a mirror.
    // No chat, host app, title bar, or other part of Serein can reach a guest screenshot.
    let rect = view.convert(view.bounds, to: nil)
    let scaleX = Double(captured.width) / window.frame.width
    let scaleY = Double(captured.height) / window.frame.height
    let crop = CGRect(x: ceil(rect.minX * scaleX), y: ceil((window.frame.height - rect.maxY) * scaleY),
      width: floor(rect.width * scaleX), height: floor(rect.height * scaleY))
    guard crop.minX >= 0, crop.minY >= 0, crop.maxX <= Double(captured.width), crop.maxY <= Double(captured.height),
      let guest = captured.cropping(to: crop),
      let context = CGContext(data: nil, width: ComputerPolicy.screenWidth, height: ComputerPolicy.screenHeight,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw SereinError.invalid("Serein is connecting its virtual Mac display. Try again in a moment.") }
    context.interpolationQuality = .high
    context.draw(guest, in: CGRect(x: 0, y: 0, width: ComputerPolicy.screenWidth, height: ComputerPolicy.screenHeight))
    guard let image = context.makeImage() else { throw SereinError.invalid("The virtual Mac display could not be read.") }
    return image
  }

  func png() throws -> Data {
    let bitmap = NSBitmapImageRep(cgImage: try image())
    guard let data = bitmap.representation(using: .png, properties: [:]), data.count <= 8_000_000 else {
      throw SereinError.invalid("The virtual Mac display could not be encoded.")
    }
    return data
  }

  #if DEBUG
  var verificationState: String {
    let frame: String
    do {
      let captured = try image()
      frame = "\(captured.width)x\(captured.height), content=\(Self.hasContent(captured))"
    } catch { frame = error.localizedDescription }
    return "running=\(view.virtualMachine?.state == .running), attached=\(view.window === renderWindow), visible=\(renderWindow.isVisible), listed=\(NSApp.windows.contains { $0 === renderWindow }), frame=\(frame)"
  }
  #endif

  /// A running bridge alone cannot make a black, disconnected renderer ready. This samples
  /// only the fixed guest window; it performs no OCR or screen-driven setup.
  nonisolated static func hasContent(_ image: CGImage) -> Bool {
    var pixels = [UInt8](repeating: 0, count: 32 * 20 * 4)
    return pixels.withUnsafeMutableBytes { bytes in
      guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 20,
        bitsPerComponent: 8, bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 20))
      let samples = bytes.bindMemory(to: UInt8.self)
      var low = 765, high = 0
      for offset in stride(from: 0, to: samples.count, by: 4) {
        let value = Int(samples[offset]) + Int(samples[offset + 1]) + Int(samples[offset + 2])
        low = min(low, value); high = max(high, value)
      }
      return high - low > 24
    }
  }

  @discardableResult func wake() -> Bool {
    guard ComputerPolicy.isEnabled(), Date().timeIntervalSince(lastWake) > 20,
      Date().timeIntervalSince(lastInput) > 15, NSEvent.pressedMouseButtons == 0,
      NSEvent.modifierFlags.intersection([.command, .control, .option, .shift, .function]).isEmpty else { return false }
    lastWake = Date()
    // A complete modifier press/release wakes only the guest; it creates no text or host event.
    press(MacKey(code: 59, control: true))
    return true
  }

  func key(_ name: String) throws {
    guard ComputerPolicy.isEnabled() else { throw SereinError.invalid(ComputerPolicy.offMessage) }
    guard let key = MacKey.parse(name) else { throw SereinError.invalid("That key is not supported in the virtual Mac.") }
    press(key)
  }

  func type(_ text: String) async throws {
    guard let strokes = MacGuestKeyboard.strokes(text) else {
      throw SereinError.invalid("The virtual Mac's text connection is not ready for this text yet.")
    }
    for key in strokes {
      try Task.checkCancellation()
      guard ComputerPolicy.isEnabled() else { throw SereinError.invalid(ComputerPolicy.offMessage) }
      guard view.virtualMachine?.state == .running else { throw SereinError.invalid("The virtual Mac stopped while typing.") }
      press(key)
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private func press(_ key: MacKey) {
    lastInput = Date()
    let modifiers: [(Bool, NSEvent.ModifierFlags, UInt16)] = [
      (key.command, .command, 55), (key.option, .option, 58),
      (key.control, .control, 59), (key.shift, .shift, 56),
    ]
    var held = lockFlags
    // The VM needs physical modifier presses; synthetic flagsChanged alone can leave
    // Command shortcuts and paste as bare keys. Deliver complete pairs to this view only.
    for (enabled, flag, code) in modifiers where enabled && code != UInt16(key.code) {
      held.insert(flag); keyEvent(true, held: held, code: code)
    }
    for down in [true, false] { keyEvent(down, held: held, code: UInt16(key.code)) }
    for (enabled, flag, code) in modifiers.reversed() where enabled && code != UInt16(key.code) {
      held.remove(flag); keyEvent(false, held: held, code: code)
    }
  }
  private func keyEvent(_ down: Bool, held: NSEvent.ModifierFlags, code: UInt16) {
    if let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: held,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) {
      view.forward(event)
    }
  }

  func click(x: Double, y: Double, button: String = "left", twice: Bool = false,
             allowed: () -> Bool = { true }) async throws {
    guard ComputerPolicy.isEnabled() else { throw SereinError.invalid(ComputerPolicy.offMessage) }
    lastInput = Date()
    let point = try point(x: x, y: y)
    let types: (NSEvent.EventType, NSEvent.EventType)
    switch button {
    case "left": types = (.leftMouseDown, .leftMouseUp)
    case "right": types = (.rightMouseDown, .rightMouseUp)
    case "middle": types = (.otherMouseDown, .otherMouseUp)
    default: throw SereinError.invalid("The virtual Mac supports left, right and middle clicks.")
    }
    move(point)
    for count in 1...(twice ? 2 : 1) {
      try Task.checkCancellation()
      guard ComputerPolicy.isEnabled(), allowed() else { throw SereinError.invalid("Control of the virtual Mac changed before the click finished.") }
      for type in [types.0, types.1] {
        guard let event = mouse(type, at: point, count: count) else { continue }
        view.forward(event)
      }
      if twice { try await Task.sleep(nanoseconds: 50_000_000) }
    }
  }

  func scroll(x: Double, y: Double, direction: String, amount: Int) throws {
    guard ComputerPolicy.isEnabled() else { throw SereinError.invalid(ComputerPolicy.offMessage) }
    lastInput = Date()
    guard direction == "up" || direction == "down", (1...30).contains(amount) else {
      throw SereinError.invalid("Scroll up or down by 1 to 30 notches.")
    }
    move(try point(x: x, y: y))
    guard let raw = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
      wheel1: Int32(amount * (direction == "up" ? 1 : -1)), wheel2: 0, wheel3: 0),
      let event = NSEvent(cgEvent: raw) else { return }
    // The event is delivered to this view directly. It is never posted to the host event system.
    view.forward(event)
  }
  private func point(x: Double, y: Double) throws -> NSPoint {
    guard x.isFinite, y.isFinite, x >= 0, y >= 0,
      x < Double(ComputerPolicy.screenWidth), y < Double(ComputerPolicy.screenHeight) else {
      throw SereinError.invalid("The point must be inside the latest virtual Mac screenshot.")
    }
    let fraction = y / Double(ComputerPolicy.screenHeight)
    return NSPoint(x: x / Double(ComputerPolicy.screenWidth) * view.bounds.width,
                   y: (view.isFlipped ? fraction : 1 - fraction) * view.bounds.height)
  }
  private func move(_ point: NSPoint) {
    if let event = mouse(.mouseMoved, at: point, count: 0) { view.forward(event) }
  }
  private func mouse(_ type: NSEvent.EventType, at point: NSPoint, count: Int) -> NSEvent? {
    NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
      context: nil, eventNumber: 0, clickCount: count, pressure: 0)
  }
  private final class RenderWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
  }

  final class InputView: VZVirtualMachineView {
    var personAllowed: () -> Bool = { false }
    var personActed: (String) -> Void = { _ in }
    var touch: () -> Void = {}
    var lockChanged: (NSEvent.ModifierFlags) -> Void = { _ in }
    override var acceptsFirstResponder: Bool { personAllowed() && super.acceptsFirstResponder }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { personAllowed() }
    override func mouseDown(with event: NSEvent) { person(event, "clicked") }
    override func rightMouseDown(with event: NSEvent) { person(event, "clicked") }
    override func otherMouseDown(with event: NSEvent) { person(event, "clicked") }
    override func mouseUp(with event: NSEvent) { person(event) }
    override func rightMouseUp(with event: NSEvent) { person(event) }
    override func otherMouseUp(with event: NSEvent) { person(event) }
    override func mouseMoved(with event: NSEvent) { person(event) }
    override func mouseDragged(with event: NSEvent) { person(event) }
    override func rightMouseDragged(with event: NSEvent) { person(event) }
    override func otherMouseDragged(with event: NSEvent) { person(event) }
    override func mouseEntered(with event: NSEvent) { person(event) }
    override func mouseExited(with event: NSEvent) { person(event) }
    override func keyDown(with event: NSEvent) { person(event, "typed or pressed keys") }
    override func keyUp(with event: NSEvent) { person(event) }
    override func flagsChanged(with event: NSEvent) { person(event) }
    override func scrollWheel(with event: NSEvent) { person(event, "scrolled") }
    private func person(_ event: NSEvent, _ step: String? = nil) {
      guard personAllowed() else { return }
      touch()
      if event.type == .flagsChanged { lockChanged(event.modifierFlags.intersection(.capsLock)) }
      if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) { window?.makeFirstResponder(self) }
      if let step { personActed(step) }
      forward(event)
    }
    /// Only MacNativeDisplay's capability-checked calls bypass the person-input gate.
    func forward(_ event: NSEvent) {
      switch event.type {
      case .leftMouseDown: super.mouseDown(with: event)
      case .leftMouseUp: super.mouseUp(with: event)
      case .rightMouseDown: super.rightMouseDown(with: event)
      case .rightMouseUp: super.rightMouseUp(with: event)
      case .otherMouseDown: super.otherMouseDown(with: event)
      case .otherMouseUp: super.otherMouseUp(with: event)
      case .mouseMoved: super.mouseMoved(with: event)
      case .leftMouseDragged: super.mouseDragged(with: event)
      case .rightMouseDragged: super.rightMouseDragged(with: event)
      case .otherMouseDragged: super.otherMouseDragged(with: event)
      case .mouseEntered: super.mouseEntered(with: event)
      case .mouseExited: super.mouseExited(with: event)
      case .keyDown: super.keyDown(with: event)
      case .keyUp: super.keyUp(with: event)
      case .flagsChanged: super.flagsChanged(with: event)
      case .scrollWheel: super.scrollWheel(with: event)
      default: break
      }
    }
  }
}

struct NativeMacScreen: NSViewRepresentable {
  let display: MacNativeDisplay
  func makeNSView(context: Context) -> MacNativeDisplay.InputView { display.makePersonView() }
  func updateNSView(_ live: MacNativeDisplay.InputView, context: Context) { display.updatePersonView(live) }
  static func dismantleNSView(_ live: MacNativeDisplay.InputView, coordinator: ()) {
    live.capturesSystemKeys = false
    live.virtualMachine = nil
  }
}
