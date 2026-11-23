import Foundation

/// Delegated tasks asked for while the limit of tasks at once is reached, oldest first. Each
/// starts when a slot frees; Stop takes it out of line before it starts.
@MainActor final class WaitingStarts {
  /// `start` returns false when the task could not start yet and should keep its place.
  typealias Start = () async -> Bool
  private var line: [(id: String, start: Start)] = []
  private let free: () -> Int
  private var pump: Task<Void, Never>?

  init(free: @escaping () -> Int) { self.free = free }

  var ids: [String] { line.map(\.id) }
  /// 1 for the next to start.
  func place(of id: String) -> Int? { line.firstIndex { $0.id == id }.map { $0 + 1 } }

  /// Puts `id` at the end of the line and returns its place.
  @discardableResult func add(_ id: String, start: @escaping Start) -> Int {
    line.append((id, start))
    drain()
    return line.count
  }

  @discardableResult func remove(_ id: String) -> Bool {
    guard let i = line.firstIndex(where: { $0.id == id }) else { return false }
    line.remove(at: i)
    return true
  }

  func removeAll() -> [String] {
    defer { line = [] }
    return ids
  }

  private func drain() {
    guard pump == nil else { return }
    pump = Task { [weak self] in
      while let self, !self.line.isEmpty {
        if self.free() > 0 {
          let next = self.line.removeFirst()
          if await next.start() { continue }
          self.line.insert(next, at: 0)
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
      self?.pump = nil
    }
  }
}
