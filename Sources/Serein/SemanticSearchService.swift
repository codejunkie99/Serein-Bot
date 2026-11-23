import Foundation
import NaturalLanguage
import SereinCore

extension Notification.Name {
  static let sereinHistoryCleared = Notification.Name("SereinHistoryCleared")
}

/// Serializes index writers and deletion without doing embedding work on the UI actor.
/// A visit is indexed when it is saved and old history in the background, a batch at a time,
/// so a search mostly only searches.
actor SemanticSearchService {
  static let shared = SemanticSearchService()
  /// Embeddings indexed between yields, so a search or a clear waits at most one batch.
  static let batch = 32
  /// Bumped by every clear and prune: an indexing pass that started before one stops, so it
  /// cannot put back a vector of a visit that was just cleared.
  private var generation = 0
  private var backfilling = false

  private static func file(_ library: URL) -> URL { library.appendingPathComponent("index/semantic.sqlite") }
  private static func embedding() throws -> (NLEmbedding, String) {
    guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
      throw SereinError.invalid(
        "This Mac’s English sentence embedding is unavailable. Use exact search instead.")
    }
    return (embedding, "english-sentence-\(embedding.revision)-\(embedding.dimension)")
  }
  func search(query: String, visits: [Visit], library: URL, among: Set<String>? = nil, limit: Int = 20)
    async throws -> [String]
  {
    try Task.checkCancellation()
    let (embedding, model) = try Self.embedding()
    guard let vector = embedding.vector(for: query) else {
      throw SereinError.invalid(
        "This Mac’s English sentence embedding is unavailable. Use exact search instead.")
    }
    // Usually nothing is left: visits are indexed as they are saved and old ones in the background.
    try await self.index(visits, library: library)
    let store = try SemanticIndex(url: Self.file(library))
    // Only visits the caller holds: a vector whose visit is gone never takes a result's place.
    return try store.nearest(
      vector, model: model, limit: limit, among: among ?? Set(visits.map(\.id)), cancelled: { Task.isCancelled })
  }
  /// Embeds the visits the index lacks, or holds for other text, yielding every `batch`.
  func index(_ visits: [Visit], library: URL) async throws {
    guard !visits.isEmpty else { return }
    let (embedding, model) = try Self.embedding()
    let index = try SemanticIndex(url: Self.file(library))
    let started = generation
    // One query for many visits; a single saved visit asks SQLite directly.
    let stored: [String: String]? = try visits.count > 1 ? index.fingerprints(model: model) : nil
    var embedded = 0
    for visit in visits {
      try Task.checkCancellation()
      guard generation == started else { return }
      let text = visit.title + " " + AgentPrivacy.clipped(visit.textExcerpt, limit: 2000)
      let fingerprint = SemanticIndex.fingerprint(text)
      let present = try stored.map { $0[visit.id] == fingerprint }
        ?? index.contains(id: visit.id, fingerprint: fingerprint, model: model)
      guard !present, let vector = embedding.vector(for: text) else { continue }
      try index.put(id: visit.id, fingerprint: fingerprint, model: model, vector: vector)
      embedded += 1
      if embedded % Self.batch == 0 { await Task.yield() }
    }
  }
  /// Indexes every saved day in the background, read straight from the Library so the app's
  /// own copy of history stays the launch window. Starts again if a clear interrupts it.
  func backfill(library: URL) async {
    guard !backfilling else { return }
    backfilling = true
    defer { backfilling = false }
    var started: Int
    repeat {
      started = generation
      guard let saved = try? Library(root: library) else { return }
      try? await index(saved.visits(), library: library)
    } while started != generation && !Task.isCancelled
  }
  func clear(library: URL) throws {
    generation += 1
    let index = try SemanticIndex(url: Self.file(library))
    try index.retain(ids: [])
  }
  func prune(library: URL, ids: Set<String>) throws {
    generation += 1
    let index = try SemanticIndex(url: Self.file(library))
    try index.retain(ids: ids)
  }
}
extension BrowserModel {
  func clearSemanticHistory() {
    NotificationCenter.default.post(name: .sereinHistoryCleared, object: nil)
    let root = library.root
    Task {
      do { try await SemanticSearchService.shared.clear(library: root) } catch {
        notice = "Could not clear search index: " + error.localizedDescription
      }
    }
  }
}
