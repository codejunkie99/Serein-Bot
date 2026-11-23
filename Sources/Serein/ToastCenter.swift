import AppKit
import SereinCore
import SwiftUI

/// One short message at the bottom of the window, with an optional action such as Undo.
struct Toast: Identifiable, Sendable {
  var id: String = UUID().uuidString
  var text: String
  var actionTitle: String?
  /// Shown only while this thread is open (a turn's Undo); nil shows everywhere.
  var thread: String?
  /// ⌘Z runs the action while no text field is in use (the turn Undo).
  var commandZ = false
  /// nil: stays until its owner removes it.
  var duration: TimeInterval?
  /// A solid card under the glass, for a toast that often sits over a light page in the dark
  /// palette, where plain glass turns mid-gray and its words lose contrast.
  var opaque = false
}

/// The shared toast stack: up to three at once, newest at the bottom. Each toast is announced
/// to VoiceOver, waits longer when it has an action, and never slides under Reduce Motion.
@MainActor final class ToastCenter: ObservableObject {
  static let shared = ToastCenter()
  @Published private(set) var queue = ToastQueue<Toast>()
  /// The thread whose scoped toasts may show; set by the thread view.
  @Published var visibleThread: String?
  private var actions: [String: @MainActor () -> Void] = [:]
  private var timers: [String: Task<Void, Never>] = [:]

  var visible: [Toast] {
    queue.items.filter { $0.thread == nil || $0.thread == visibleThread }
  }

  /// Shows a toast. `action` runs when its button (or ⌘Z for `commandZ`) is pressed, then the
  /// toast closes.
  @discardableResult
  func show(
    _ text: String, id: String? = nil, actionTitle: String? = nil, thread: String? = nil,
    commandZ: Bool = false, duration: TimeInterval? = 0, opaque: Bool = false,
    action: (@MainActor () -> Void)? = nil
  ) -> String {
    let voiceOver = NSWorkspace.shared.isVoiceOverEnabled
    let wait =
      duration == 0
      ? ToastQueue<Toast>.duration(hasAction: action != nil, voiceOver: voiceOver) : duration
    let toast = Toast(
      id: id ?? UUID().uuidString, text: text, actionTitle: action == nil ? nil : actionTitle ?? "Undo",
      thread: thread, commandZ: commandZ, duration: wait, opaque: opaque)
    for gone in queue.push(toast) { forget(gone) }
    actions[toast.id] = action
    timers[toast.id]?.cancel()
    held.remove(toast.id)
    if let wait { schedule(toast.id, after: wait) }
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [
        .announcement: text + (toast.actionTitle.map { ". \($0) is available." } ?? ""),
        .priority: NSAccessibilityPriorityLevel.medium.rawValue,
      ])
    return toast.id
  }
  private func schedule(_ id: String, after wait: TimeInterval) {
    timers[id]?.cancel()
    timers[id] = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
      if !Task.isCancelled { self?.dismiss(id) }
    }
  }
  /// Toasts the pointer or the keyboard is on: they stay until it leaves, then wait their time
  /// again.
  private var held = Set<String>()
  func hold(_ id: String, _ holding: Bool) {
    guard let toast = queue.items.first(where: { $0.id == id }), let wait = toast.duration else { return }
    if holding {
      held.insert(id)
      timers.removeValue(forKey: id)?.cancel()
    } else if held.remove(id) != nil {
      schedule(id, after: wait)
    }
  }
  func perform(_ id: String) {
    let action = actions[id]
    dismiss(id)
    action?()
  }
  func dismiss(_ id: String) {
    queue.remove(id)
    forget(id)
  }
  private func forget(_ id: String) {
    actions[id] = nil
    held.remove(id)
    timers.removeValue(forKey: id)?.cancel()
  }
}

/// The stack, placed once at the bottom of the main window.
struct ToastStack: View {
  @ObservedObject var center = ToastCenter.shared
  @Environment(\.palette) var p
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Environment(\.sereinReducedEffects) var previewReducedEffects
  var body: some View {
    VStack(spacing: 8) {
      ForEach(center.visible) { toast in
        ToastCard(toast: toast)
          .transition(
            reduceMotion || previewReducedEffects
              ? .opacity : .move(edge: .bottom).combined(with: .opacity))
      }
    }.padding(.bottom, 96).frame(maxWidth: 520)
      .animation(
        reduceMotion || previewReducedEffects ? nil : .easeOut(duration: 0.2),
        value: center.visible.map(\.id))
  }
}

struct ToastCard: View {
  var toast: Toast
  @FocusState private var actionFocused: Bool
  @State private var hovered = false
  @Environment(\.palette) var p
  var center: ToastCenter { .shared }
  var body: some View {
    HStack(spacing: 12) {
      Text(toast.text).font(UIStyle.meta).foregroundStyle(p.ink).lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
      if let title = toast.actionTitle {
        Button(title) { center.perform(toast.id) }.buttonStyle(QuietButton())
          .focused($actionFocused)
          .help(toast.commandZ ? "\(title) (⌘Z when no text field is in use)" : title)
          .background {
            if toast.commandZ { UndoKeyMonitor { center.perform(toast.id) } }
          }
        if toast.commandZ {
          Text("⌘Z").font(UIStyle.microMono).foregroundStyle(p.faint).accessibilityHidden(true)
        }
      }
      Button {
        center.dismiss(toast.id)
      } label: {
        InterfaceIcon(systemName: "xmark", size: 11)
      }.buttonStyle(QuietButton()).accessibilityLabel("Dismiss")
    }.padding(.horizontal, 14).padding(.vertical, 8)
      .background { if toast.opaque { RoundedRectangle(cornerRadius: UIStyle.panelRadius).fill(p.panel) } }
      .darkGlass(UIStyle.panelRadius)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(toast.text)
      // A toast stays while the pointer is on it or its button has the keyboard.
      // Either one alone keeps it.
      .onHover { inside in
        hovered = inside
        center.hold(toast.id, inside || actionFocused)
      }
      .onChange(of: actionFocused) { _, focused in center.hold(toast.id, hovered || focused) }
  }
}
