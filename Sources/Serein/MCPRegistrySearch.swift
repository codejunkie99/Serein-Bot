import Foundation
import SereinCore

/// Connect Apps' search of the official MCP Registry (`MCPRegistry`). It runs only when the person
/// presses Search, sends nothing but the search words, follows no redirect and keeps no cookie;
/// an answer is kept for ten minutes.
@MainActor final class MCPRegistrySearch: ObservableObject {
  static let shared = MCPRegistrySearch()
  enum State: Equatable {
    case idle
    case searching(String)
    case found(String, [MCPRegistry.Server])
    case failed(String)
  }
  @Published private(set) var state: State = .idle
  private var cache: [String: (at: Date, servers: [MCPRegistry.Server])] = [:]
  private var running: Task<Void, Never>?
  private static let session = EphemeralHTTP.session(resourceTimeout: 15)
  private static let keep: TimeInterval = 600

  /// The words the last answer or search is for.
  var query: String? {
    switch state {
    case .idle: return nil
    case .searching(let q), .found(let q, _), .failed(let q): return q
    }
  }

  func search(_ raw: String) {
    let query = MCPRegistry.normalizedQuery(raw)
    guard let url = MCPRegistry.searchURL(query) else {
      state = .idle
      return
    }
    if let hit = cache[query], Date().timeIntervalSince(hit.at) < Self.keep {
      state = .found(query, hit.servers)
      return
    }
    running?.cancel()
    state = .searching(query)
    running = Task { [weak self] in
      var request = URLRequest(url: url)
      request.timeoutInterval = 15
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      do {
        let (data, response) = try await Self.session.data(for: request)
        guard !Task.isCancelled, let self else { return }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
          self.state = .failed(query)
          return
        }
        let servers = MCPRegistry.servers(from: data)
        self.cache[query] = (Date(), servers)
        self.state = .found(query, servers)
      } catch {
        guard !Task.isCancelled, let self else { return }
        self.state = .failed(query)
      }
    }
  }

  /// The search box changed: an answer for other words no longer shows.
  func clear(unless raw: String) {
    guard let shown = query, shown != MCPRegistry.normalizedQuery(raw) else { return }
    running?.cancel()
    state = .idle
  }
}
