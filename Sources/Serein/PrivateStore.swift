import WebKit

/// Reference-counts non-persistent data stores used by private tabs. Private tabs in the main window
/// share one store; a store is emptied when the last tab using it goes away. A tab moved to another
/// window keeps its registration, so closing that window cannot sign out tabs elsewhere.
@MainActor final class PrivateStorePool {
  static let shared = PrivateStorePool()
  private var mainStore: WKWebsiteDataStore?
  private var users: [ObjectIdentifier: Set<String>] = [:]
  private var assigned: [String: WKWebsiteDataStore] = [:]

  /// The store for private tabs opened in the main window.
  func mainWindowStore() -> WKWebsiteDataStore {
    if let mainStore { return mainStore }
    let store = WKWebsiteDataStore.nonPersistent()
    mainStore = store
    return store
  }
  func register(tabID: String, store: WKWebsiteDataStore) {
    if let old = assigned[tabID], old !== store { release(tabID: tabID) }
    assigned[tabID] = store
    users[ObjectIdentifier(store), default: []].insert(tabID)
  }
  func release(tabID: String) {
    guard let store = assigned.removeValue(forKey: tabID) else { return }
    let key = ObjectIdentifier(store)
    users[key]?.remove(tabID)
    if users[key]?.isEmpty ?? true { wipe(store) }
  }
  /// Empties a store that no registered tab uses (for example when its window had no tabs left).
  func wipeIfUnused(_ store: WKWebsiteDataStore) {
    if users[ObjectIdentifier(store)]?.isEmpty ?? true { wipe(store) }
  }
  func userCount(_ store: WKWebsiteDataStore) -> Int { users[ObjectIdentifier(store)]?.count ?? 0 }
  private func wipe(_ store: WKWebsiteDataStore) {
    users[ObjectIdentifier(store)] = nil
    if store === mainStore { mainStore = nil }
    store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
  }
}
