import Foundation

/// Where a project's dev server probably listens, read from files in the project folder, and
/// how a running or vanished server is reported. Pure logic; probing lives in the app.
public enum DevServerPorts {
  /// `server: { port: 3000 }` or `port: 3000` in a Vite, Astro, Nuxt, Svelte or webpack config.
  /// Commented-out lines are skipped.
  public static func fromConfig(_ text: String) -> [Int] {
    var found: [Int] = []
    for line in text.split(whereSeparator: \.isNewline) {
      let s = line.trimmingCharacters(in: .whitespaces)
      if s.hasPrefix("//") || s.hasPrefix("#") || s.hasPrefix("*") { continue }
      found += matches(#"\bport\s*:\s*(?:Number\()?['"]?([0-9]{2,5})\b"#, in: s)
    }
    return found
  }
  /// `web: npm run dev -- -p 4000` or `PORT=4000 node server.js` in a Procfile.
  public static func fromProcfile(_ text: String) -> [Int] {
    var found: [Int] = []
    for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
      let s = String(line)
      found += matches(#"(?:--port|-p)[ =]([0-9]{2,5})\b"#, in: s)
      found += matches(#"\bPORT=([0-9]{2,5})\b"#, in: s)
    }
    return found
  }
  /// All hints merged in a stable order, deduplicated, unprivileged ports only.
  public static func merge(_ groups: [[Int]]) -> [Int] {
    var seen = Set<Int>()
    return groups.flatMap { $0 }.filter { (1024...65535).contains($0) && seen.insert($0).inserted }
  }
  /// Candidate ports from the project's files. Missing files are simply absent.
  public static func candidates(packageJSON: Data?, config: [String], procfile: String?) -> [Int] {
    merge(
      [packageJSON.map(DevServer.ports(packageJSON:)) ?? []]
        + config.map(fromConfig) + [procfile.map(fromProcfile) ?? []])
  }
  private static func matches(_ pattern: String, in text: String) -> [Int] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).compactMap { m in
      Range(m.range(at: 1), in: text).flatMap { Int(text[$0]) }
    }
  }
  /// Config files worth reading, relative to the project root.
  public static let configNames = [
    "vite.config.ts", "vite.config.js", "vite.config.mjs", "vite.config.mts", "astro.config.mjs",
    "astro.config.ts", "nuxt.config.ts", "nuxt.config.js", "svelte.config.js", "next.config.js",
    "next.config.mjs", "webpack.config.js", "vue.config.js",
  ]
}

/// What the project card says about a dev server.
public enum DevServerStatus: Equatable, Sendable {
  case running(port: Int)
  case gone(port: Int)

  public var port: Int {
    switch self {
    case .running(let p), .gone(let p): return p
    }
  }
  public var label: String {
    switch self {
    case .running(let p): return "Dev server: http://localhost:\(p)"
    case .gone(let p): return "Nothing is running on \(p)"
    }
  }
  public var url: String { "http://localhost:\(port)" }
}

/// Turns each probe's listening ports into a status. A server that was seen and then stops
/// becomes `gone` until it returns or is dismissed; a project never seen stays absent.
public struct DevServerTracker: Equatable, Sendable {
  public private(set) var status: [String: DevServerStatus] = [:]
  public init() {}

  /// `listening` are the ports now serving this project, preferred first.
  /// Returns true when the status changed.
  @discardableResult
  public mutating func update(project id: String, listening: [Int]) -> Bool {
    let next: DevServerStatus?
    if let port = listening.first {
      // Keep showing the same port while it still answers, so the label does not flicker.
      if case .running(let old)? = status[id], listening.contains(old) {
        next = .running(port: old)
      } else {
        next = .running(port: port)
      }
    } else if let old = status[id] {
      next = .gone(port: old.port)
    } else {
      next = nil
    }
    guard status[id] != next else { return false }
    status[id] = next
    return true
  }
  /// Forget projects that are no longer registered.
  public mutating func prune(keeping ids: Set<String>) {
    for id in Array(status.keys) where !ids.contains(id) { status[id] = nil }
  }
}
