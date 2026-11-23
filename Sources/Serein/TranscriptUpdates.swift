import Foundation

/// Keep the complete run transcript immediately, but present bursts at most 30 times a
/// second. Completion, saving and switching threads flush/cancel this presentation work.
@MainActor final class TranscriptUpdates {
  private let interval: UInt64
  private var lastDelivery: UInt64?
  private var pending: (() -> Void)?
  private var timer: Task<Void, Never>?

  init(interval: UInt64 = 33_333_333) { self.interval = interval }

  func submit(_ update: @escaping () -> Void) {
    pending = update
    let now = DispatchTime.now().uptimeNanoseconds
    guard let lastDelivery, now - lastDelivery < interval else {
      flush()
      return
    }
    guard timer == nil else { return }
    let remaining = interval - (now - lastDelivery)
    timer = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: remaining) } catch { return }
      guard !Task.isCancelled else { return }
      self?.flush()
    }
  }

  func flush() {
    timer?.cancel()
    timer = nil
    guard let update = pending else { return }
    pending = nil
    lastDelivery = DispatchTime.now().uptimeNanoseconds
    update()
  }

  func cancel() {
    timer?.cancel()
    timer = nil
    pending = nil
    lastDelivery = nil
  }
}
