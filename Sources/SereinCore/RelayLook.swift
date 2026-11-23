import Foundation

/// Relay's look: how its hologram (tools/avatar, shown by RelayAvatar) appears in each state.
/// Each state names a ring formation and a core shape, so a state changes the hologram's shape
/// as well as its color. Relay designs looks itself with its look tools, and every look passes
/// `applying` here first: only catalog shapes, numbers in range, and colors bright enough to see.
public struct RelayLook: Codable, Equatable, Sendable {
  public enum State: String, CaseIterable, Codable, Sendable {
    case idle, listening, thinking, speaking, working, alert, error, dormant, done
    public var title: String {
      switch self {
      case .idle: return "Ready"
      case .listening: return "Listening"
      case .thinking: return "Thinking"
      case .speaking: return "Speaking"
      case .working: return "Working"
      case .alert: return "Needs you"
      case .error: return "Something failed"
      case .dormant: return "Paused"
      case .done: return "Done"
      }
    }
    /// What the state means, for whoever designs a look.
    public var meaning: String {
      switch self {
      case .idle: return "waiting for the user"
      case .listening: return "hearing the user's voice"
      case .thinking: return "Serein’s own turn is running"
      case .speaking: return "reading a reply aloud"
      case .working: return "delegated runs are working; each is a satellite"
      case .alert: return "an approval or reminder waits for the user"
      case .error: return "the last request failed"
      case .dormant: return "paused by the kill switch"
      case .done: return "a burst when delegated work finishes (colors and glow only)"
      }
    }
    /// What the hologram shows, the most pressing first.
    public static func current(
      paused: Bool, needsUser: Bool, listening: Bool, speaking: Bool, thinking: Bool, failed: Bool, jobs: Int
    ) -> State {
      if paused { return .dormant }
      if needsUser { return .alert }
      if listening { return .listening }
      if speaking { return .speaking }
      if thinking { return .thinking }
      if failed { return .error }
      return jobs > 0 ? .working : .idle
    }
  }
  public struct Palette: Codable, Equatable, Sendable {
    public var primary: String
    public var rim: String
  }
  public struct Rings: Codable, Equatable, Sendable {
    public var count: Int
    public var thickness: Double
    public var style: String
  }
  public struct Core: Codable, Equatable, Sendable {
    public var shape: String
    public var size: Double
    public var density: Double
  }
  public struct Effects: Codable, Equatable, Sendable {
    public var bloom: Double
    public var scanlines: Double
    public var grain: Double
    public var glitch: Double
    public var aberration: Double
  }
  /// One state's appearance. Without colors it uses the palette, without a core the look's core.
  public struct Style: Codable, Equatable, Sendable {
    public var formation: String?
    public var core: String?
    public var primary: String?
    public var rim: String?
    public var speed: Double?
    public var glow: Double?
    public init(formation: String? = nil, core: String? = nil, primary: String? = nil, rim: String? = nil, speed: Double? = nil, glow: Double? = nil) {
      self.formation = formation
      self.core = core
      self.primary = primary
      self.rim = rim
      self.speed = speed
      self.glow = glow
    }
  }
  public var name: String
  public var palette: Palette
  public var rings: Rings
  public var core: Core
  public var effects: Effects
  public var motion: Double
  public var states: [String: Style]

  // MARK: catalog

  public static let formations: [(name: String, shape: String)] = [
    ("logo", "the Serein logo: five tilted rings turning slowly"),
    ("dish", "a dish of rings turned toward the user; the voice ripples in from the rim"),
    ("gyro", "a gyroscope: every ring spins on its own axis"),
    ("waveform", "rings side by side like a voice meter, leaping with each word"),
    ("orbit", "an orrery; running jobs ride the orbits as satellites"),
    ("lantern", "meridians around an equator, beating like a heart"),
    ("shatter", "broken arcs drifting apart and jolting"),
    ("horizon", "every ring settled into one dim horizon"),
    ("halo", "nested gimbals facing the user"),
    ("helix", "rings threaded on a turning spiral"),
    ("crown", "petals opening around the core"),
    ("tower", "a stack of halos breathing in turn"),
  ]
  public static let cores: [(name: String, shape: String)] = [
    ("orb", "a sphere of points"), ("lattice", "an icosahedron's edges"), ("crystal", "a tall diamond"),
    ("cube", "a cube inside a cube"), ("star", "twelve rays"), ("torus", "a ring of light"), ("knot", "a trefoil knot"),
    ("galaxy", "a spiral galaxy"), ("helix", "a double helix"), ("heart", "a heart"),
    ("scatter", "loose drifting points"), ("spark", "one small spark"),
  ]
  public static let styles = ["solid", "dashed", "dotted", "double"]
  public static let effectNames = ["bloom", "scanlines", "grain", "glitch", "aberration"]
  static let ranges: [String: ClosedRange<Double>] = [
    "rings.count": 3...8, "rings.thickness": 0.006...0.05, "core.size": 0.5...1.6, "core.density": 0.25...1,
    "effects": 0...1, "motion": 0.25...2, "speed": 0.25...3, "glow": 0.3...1.6,
  ]
  /// The brightest channel a color needs to glow on the dark stage (hex 40 and 70).
  static let darkest = (primary: 0x40, rim: 0x70)

  /// How to write a look, for look_get and for people who make looks by hand.
  public static let guide = """
    A look is JSON. name: up to 40 characters. palette: {primary, rim} as #rrggbb; rim is the edge light, usually the lighter of the two. \
    rings: {count 3–8, thickness 0.006–0.05, style solid|dashed|dotted|double}. core: {shape, size 0.5–1.6, density 0.25–1}. \
    effects: {bloom, scanlines, grain, glitch, aberration}, each 0–1. motion: 0.25–2. \
    states: {state: {formation, core, primary, rim, speed 0.25–3, glow 0.3–1.6}} for idle, listening, thinking, speaking, working, alert, error, dormant; \
    done is a burst and takes only primary, rim and glow. A state without colors uses the palette, without core the look's core. \
    Give look_set only what changes; objects merge, and null puts a key back to Serein's default.
    """

  // MARK: presets

  /// Serein's looks, the first is the default. tools/avatar/src/presets.json holds the same
  /// text for the renderer's gallery; SereinChecks compares them.
  public static let presets: [RelayLook] = {
    guard let looks = try? JSONDecoder().decode([RelayLook].self, from: Data(presetsJSON.utf8)), !looks.isEmpty else {
      return [fallback]
    }
    return looks
  }()
  public static var serein: RelayLook { presets[0] }
  public static func preset(_ name: String) -> RelayLook? {
    let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
    return presets.first { $0.name.lowercased() == wanted }
  }
  /// Used only if the presets above could not be read (SereinChecks makes sure they can).
  static let fallback = RelayLook(
    name: "Serein", palette: Palette(primary: "#4c7dff", rim: "#a9caff"), rings: Rings(count: 5, thickness: 0.018, style: "solid"),
    core: Core(shape: "orb", size: 1, density: 1),
    effects: Effects(bloom: 0.55, scanlines: 0.5, grain: 0.3, glitch: 0.3, aberration: 0.5),
    motion: 1,
    states: [
      "idle": Style(formation: "logo"), "listening": Style(formation: "dish"), "thinking": Style(formation: "gyro", core: "lattice"),
      "speaking": Style(formation: "waveform"), "working": Style(formation: "orbit", core: "galaxy"),
      "alert": Style(formation: "lantern", core: "crystal", primary: "#e8892a", rim: "#f5c98f"),
      "error": Style(formation: "shatter", core: "scatter", primary: "#ff4d5e", rim: "#ffb3bb"),
      "dormant": Style(formation: "horizon", core: "spark", primary: "#4a5878", rim: "#8a98b8", glow: 0.5),
      "done": Style(primary: "#3ddc97", rim: "#b9f6dc", glow: 1.3),
    ])

  // MARK: JSON

  /// The look as JSON values (what look_get returns and the renderer takes).
  public var json: [String: Any] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(self), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return [:]
    }
    return object
  }
  public var jsonText: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
  }

  /// This look with `patch` applied: a full or partial look (objects merge; null puts a key back
  /// to Serein's default). Throws one message that names every problem.
  public func applying(_ patch: [String: Any]) throws -> RelayLook {
    var look = self
    var problems: [String] = []
    let base = RelayLook.serein
    func isNull(_ v: Any) -> Bool { v is NSNull }
    func object(_ v: Any, _ path: String, keys: [String]) -> [String: Any]? {
      guard let o = v as? [String: Any] else {
        problems.append("\(path) must be an object")
        return nil
      }
      for key in o.keys.sorted() where !keys.contains(key) {
        problems.append("\(path).\(key) is not part of a look; \(path) takes \(keys.joined(separator: ", "))")
      }
      return o
    }
    func number(_ v: Any, _ path: String, _ range: ClosedRange<Double>) -> Double? {
      guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
        problems.append("\(path) must be a number from \(Self.format(range.lowerBound)) to \(Self.format(range.upperBound))")
        return nil
      }
      guard range.contains(n.doubleValue) else {
        problems.append("\(path) must be from \(Self.format(range.lowerBound)) to \(Self.format(range.upperBound)), not \(Self.format(n.doubleValue))")
        return nil
      }
      return n.doubleValue
    }
    func choice(_ v: Any, _ path: String, among: [String]) -> String? {
      guard let s = v as? String, among.contains(s) else {
        problems.append("\(path) must be one of \(among.joined(separator: ", "))")
        return nil
      }
      return s
    }
    func color(_ v: Any, _ path: String, rim: Bool) -> String? {
      guard let s = (v as? String)?.lowercased(), let value = Self.rgb(s) else {
        problems.append("\(path) must be a color written #rrggbb")
        return nil
      }
      let least = rim ? Self.darkest.rim : Self.darkest.primary
      guard max(value.r, value.g, value.b) >= least else {
        problems.append("\(path) \(s) is too dark to see on the hologram's dark stage; use a brighter color, with one channel at least \(String(least, radix: 16)) in hex")
        return nil
      }
      return s
    }
    for key in patch.keys.sorted() {
      let value = patch[key]!
      switch key {
      case "name":
        if isNull(value) { look.name = base.name; continue }
        guard let name = Self.name(value) else {
          problems.append("name must be 1 to 40 characters on one line")
          continue
        }
        look.name = name
      case "palette":
        if isNull(value) { look.palette = base.palette; continue }
        guard let o = object(value, "palette", keys: ["primary", "rim"]) else { continue }
        if let v = o["primary"] { look.palette.primary = isNull(v) ? base.palette.primary : color(v, "palette.primary", rim: false) ?? look.palette.primary }
        if let v = o["rim"] { look.palette.rim = isNull(v) ? base.palette.rim : color(v, "palette.rim", rim: true) ?? look.palette.rim }
      case "rings":
        if isNull(value) { look.rings = base.rings; continue }
        guard let o = object(value, "rings", keys: ["count", "thickness", "style"]) else { continue }
        if let v = o["count"] {
          if isNull(v) { look.rings.count = base.rings.count }
          else if let n = number(v, "rings.count", Self.ranges["rings.count"]!) {
            if n.rounded() == n { look.rings.count = Int(n) } else { problems.append("rings.count must be a whole number") }
          }
        }
        if let v = o["thickness"] { look.rings.thickness = isNull(v) ? base.rings.thickness : number(v, "rings.thickness", Self.ranges["rings.thickness"]!) ?? look.rings.thickness }
        if let v = o["style"] { look.rings.style = isNull(v) ? base.rings.style : choice(v, "rings.style", among: Self.styles) ?? look.rings.style }
      case "core":
        if isNull(value) { look.core = base.core; continue }
        guard let o = object(value, "core", keys: ["shape", "size", "density"]) else { continue }
        if let v = o["shape"] { look.core.shape = isNull(v) ? base.core.shape : choice(v, "core.shape", among: Self.cores.map(\.name)) ?? look.core.shape }
        if let v = o["size"] { look.core.size = isNull(v) ? base.core.size : number(v, "core.size", Self.ranges["core.size"]!) ?? look.core.size }
        if let v = o["density"] { look.core.density = isNull(v) ? base.core.density : number(v, "core.density", Self.ranges["core.density"]!) ?? look.core.density }
      case "effects":
        if isNull(value) { look.effects = base.effects; continue }
        guard let o = object(value, "effects", keys: Self.effectNames) else { continue }
        for name in Self.effectNames {
          guard let v = o[name] else { continue }
          let set = isNull(v) ? base.effects[name] : number(v, "effects.\(name)", Self.ranges["effects"]!)
          if let set { look.effects[name] = set }
        }
      case "motion":
        if isNull(value) { look.motion = base.motion; continue }
        look.motion = number(value, "motion", Self.ranges["motion"]!) ?? look.motion
      case "states":
        if isNull(value) { look.states = base.states; continue }
        guard let o = value as? [String: Any] else {
          problems.append("states must be an object")
          continue
        }
        for stateName in o.keys.sorted() {
          let v = o[stateName]!
          guard let state = State(rawValue: stateName) else {
            problems.append("states.\(stateName) is not a state; states are \(State.allCases.map(\.rawValue).joined(separator: ", "))")
            continue
          }
          if isNull(v) { look.states[stateName] = base.states[stateName]; continue }
          let path = "states.\(stateName)"
          let keys = state == .done ? ["primary", "rim", "glow"] : ["formation", "core", "primary", "rim", "speed", "glow"]
          guard let s = object(v, path, keys: keys) else { continue }
          var style = look.states[stateName] ?? base.states[stateName] ?? Style()
          if state != .done {
            if let v = s["formation"] { style.formation = isNull(v) ? base.states[stateName]?.formation : choice(v, "\(path).formation", among: Self.formations.map(\.name)) ?? style.formation }
            if let v = s["core"] { style.core = isNull(v) ? nil : choice(v, "\(path).core", among: Self.cores.map(\.name)) ?? style.core }
            if let v = s["speed"] { style.speed = isNull(v) ? nil : number(v, "\(path).speed", Self.ranges["speed"]!) ?? style.speed }
          }
          if let v = s["primary"] { style.primary = isNull(v) ? nil : color(v, "\(path).primary", rim: false) ?? style.primary }
          if let v = s["rim"] { style.rim = isNull(v) ? nil : color(v, "\(path).rim", rim: true) ?? style.rim }
          if let v = s["glow"] { style.glow = isNull(v) ? nil : number(v, "\(path).glow", Self.ranges["glow"]!) ?? style.glow }
          look.states[stateName] = style
        }
      default:
        problems.append("\(key) is not part of a look; a look takes name, palette, rings, core, effects, motion and states")
      }
    }
    problems += look.problems().filter { !problems.contains($0) }
    guard problems.isEmpty else { throw SereinError.invalid("The look was not applied: " + problems.joined(separator: "; ") + ".") }
    return look
  }

  /// A whole look written out (a file, an import): what it leaves out is Serein's, except that a
  /// state without colors, core, speed or glow uses the look's own palette and core.
  public static func parse(_ object: [String: Any]) throws -> RelayLook {
    var blank = serein
    for (key, style) in blank.states { blank.states[key] = Style(formation: style.formation) }
    return try blank.applying(object)
  }

  /// What is wrong with a whole look (a saved or hand-made one); empty when it is fine.
  public func problems() -> [String] {
    var out: [String] = []
    if Self.name(name) != name { out.append("name must be 1 to 40 characters on one line") }
    for (path, value, rim) in [("palette.primary", palette.primary, false), ("palette.rim", palette.rim, true)] {
      if !Self.visible(value, rim: rim) { out.append("\(path) must be a visible #rrggbb color") }
    }
    if !(3...8).contains(rings.count) { out.append("rings.count must be from 3 to 8") }
    if !Self.ranges["rings.thickness"]!.contains(rings.thickness) { out.append("rings.thickness is out of range") }
    if !Self.styles.contains(rings.style) { out.append("rings.style must be one of \(Self.styles.joined(separator: ", "))") }
    if !Self.cores.contains(where: { $0.name == core.shape }) { out.append("core.shape is not a core") }
    if !Self.ranges["core.size"]!.contains(core.size) || !Self.ranges["core.density"]!.contains(core.density) { out.append("core.size or core.density is out of range") }
    for name in Self.effectNames where !(0...1).contains(effects[name] ?? -1) { out.append("effects.\(name) must be from 0 to 1") }
    if !Self.ranges["motion"]!.contains(motion) { out.append("motion must be from 0.25 to 2") }
    for key in states.keys where State(rawValue: key) == nil { out.append("states.\(key) is not a state") }
    for state in State.allCases {
      let s = states[state.rawValue]
      if state != .done, !Self.formations.contains(where: { $0.name == s?.formation }) {
        out.append("states.\(state.rawValue).formation must be one of \(Self.formations.map(\.name).joined(separator: ", "))")
      }
      guard let s else { continue }
      if state == .done, s.formation != nil || s.core != nil || s.speed != nil { out.append("states.done takes only primary, rim and glow") }
      if let c = s.core, !Self.cores.contains(where: { $0.name == c }) { out.append("states.\(state.rawValue).core is not a core") }
      if let c = s.primary, !Self.visible(c, rim: false) { out.append("states.\(state.rawValue).primary must be a visible #rrggbb color") }
      if let c = s.rim, !Self.visible(c, rim: true) { out.append("states.\(state.rawValue).rim must be a visible #rrggbb color") }
      if let v = s.speed, !Self.ranges["speed"]!.contains(v) { out.append("states.\(state.rawValue).speed is out of range") }
      if let v = s.glow, !Self.ranges["glow"]!.contains(v) { out.append("states.\(state.rawValue).glow is out of range") }
    }
    return out
  }

  /// A short description of what a look does in each state, for people and for Relay.
  public var summary: String {
    State.allCases.filter { $0 != .done }.map { state -> String in
      let s = states[state.rawValue]
      return "\(state.rawValue): \(s?.formation ?? "?") + \(s?.core ?? core.shape)"
    }.joined(separator: ", ")
  }

  static func rgb(_ s: String) -> (r: Int, g: Int, b: Int)? {
    guard s.count == 7, s.hasPrefix("#"), let v = Int(s.dropFirst(), radix: 16), s.dropFirst().allSatisfy(\.isHexDigit) else { return nil }
    return (v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff)
  }
  static func visible(_ s: String, rim: Bool) -> Bool {
    guard s == s.lowercased(), let v = rgb(s) else { return false }
    return max(v.r, v.g, v.b) >= (rim ? darkest.rim : darkest.primary)
  }
  static func name(_ value: Any) -> String? {
    guard let raw = value as? String else { return nil }
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...40).contains(name.count), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else { return nil }
    return name
  }
  static func format(_ v: Double) -> String { v.rounded() == v ? String(Int(v)) : String(v) }
}

extension RelayLook.Effects {
  subscript(name: String) -> Double? {
    get {
      switch name {
      case "bloom": return bloom
      case "scanlines": return scanlines
      case "grain": return grain
      case "glitch": return glitch
      case "aberration": return aberration
      default: return nil
      }
    }
    set {
      guard let newValue else { return }
      switch name {
      case "bloom": bloom = newValue
      case "scanlines": scanlines = newValue
      case "grain": grain = newValue
      case "glitch": glitch = newValue
      case "aberration": aberration = newValue
      default: break
      }
    }
  }
}

/// The look Relay wears and the ones before it, kept in Relay's folder (relay/look.json).
/// Relay may change its look on its own (when the user allows it) up to twice a day; anything
/// it does is undone with Undo, and Reset goes back to Serein.
public struct RelayLookStore: Codable, Equatable, Sendable {
  public enum Author: String, Codable, Sendable { case preset, you, relay }
  public struct Entry: Codable, Equatable, Sendable {
    public var look: RelayLook
    public var by: Author
    /// Relay chose it in a turn it started itself, not because the user asked.
    public var own: Bool
    public var reason: String?
    public var at: Date
  }
  public var current: Entry
  /// Earlier looks, newest last.
  public var history: [Entry] = []
  /// When Relay changed its look, for the daily limits.
  public var changes: [Date] = []
  public var ownChanges: [Date] = []
  public static let kept = 20
  public static let dailyChanges = 12
  public static let dailyOwnChanges = 2

  public init(look: RelayLook = .serein) {
    current = Entry(look: look, by: .preset, own: false, reason: nil, at: .distantPast)
  }
  public var look: RelayLook { current.look }

  public mutating func set(_ look: RelayLook, by: Author, own: Bool = false, reason: String? = nil, at: Date = Date()) {
    guard look != current.look else { return }
    history.append(current)
    if history.count > Self.kept { history.removeFirst(history.count - Self.kept) }
    current = Entry(look: look, by: by, own: own, reason: reason.map { String($0.prefix(160)) }, at: at)
    guard by == .relay else { return }
    changes = Array((changes + [at]).suffix(50))
    if own { ownChanges = Array((ownChanges + [at]).suffix(50)) }
  }
  /// Goes back to the look before; false when there is none.
  @discardableResult public mutating func undo() -> Bool {
    guard let previous = history.popLast() else { return false }
    current = previous
    return true
  }
  /// Why Relay may not change its look now, or nil when it may. `own` is a turn Relay started.
  public func refusal(own: Bool, allowedOnOwn: Bool, now: Date, calendar: Calendar = .current) -> String? {
    if own && !allowedOnOwn {
      return "The user turned off changing your look on your own. Change it only when they ask."
    }
    let today: (Date) -> Bool = { calendar.isDate($0, inSameDayAs: now) }
    if changes.filter(today).count >= Self.dailyChanges {
      return "You already changed your look \(Self.dailyChanges) times today. Keep this one until tomorrow."
    }
    if own && ownChanges.filter(today).count >= Self.dailyOwnChanges {
      return "You already changed your look on your own today. Keep this one unless the user asks."
    }
    return nil
  }
  /// A saved store with a look that no longer passes (edited by hand) falls back to Serein.
  public func repaired() -> RelayLookStore {
    var store = self
    if !current.look.problems().isEmpty { store.current = Entry(look: .serein, by: .preset, own: false, reason: nil, at: Date()) }
    store.history = history.filter { $0.look.problems().isEmpty }
    return store
  }
}

extension RelayLook {
  static let presetsJSON = #"""
    [
      {"name":"Serein","palette":{"primary":"#4c7dff","rim":"#a9caff"},"rings":{"count":5,"thickness":0.018,"style":"solid"},"core":{"shape":"orb","size":1,"density":1},"effects":{"bloom":0.55,"scanlines":0.5,"grain":0.3,"glitch":0.3,"aberration":0.5},"motion":1,"states":{"idle":{"formation":"logo","speed":1,"glow":1},"listening":{"formation":"dish","primary":"#3fb2ff","rim":"#b7e6ff","speed":1,"glow":1.15},"thinking":{"formation":"gyro","core":"lattice","primary":"#6a72ff","rim":"#c3c8ff","speed":1,"glow":1.1},"speaking":{"formation":"waveform","primary":"#5f98ff","rim":"#c9defa","speed":1,"glow":1.15},"working":{"formation":"orbit","core":"galaxy","primary":"#3f8cff","rim":"#9fd8ff","speed":1,"glow":1},"alert":{"formation":"lantern","core":"crystal","primary":"#e8892a","rim":"#f5c98f","speed":1,"glow":1},"error":{"formation":"shatter","core":"scatter","primary":"#ff4d5e","rim":"#ffb3bb","speed":1,"glow":1},"dormant":{"formation":"horizon","core":"spark","primary":"#4a5878","rim":"#8a98b8","speed":1,"glow":0.5},"done":{"primary":"#3ddc97","rim":"#b9f6dc","glow":1.3}}},
      {"name":"Reactor","palette":{"primary":"#29c8ff","rim":"#e6fbff"},"rings":{"count":6,"thickness":0.022,"style":"double"},"core":{"shape":"torus","size":1.1,"density":1},"effects":{"bloom":0.7,"scanlines":0.35,"grain":0.2,"glitch":0.2,"aberration":0.4},"motion":1.1,"states":{"idle":{"formation":"halo","speed":1,"glow":1},"listening":{"formation":"dish","core":"orb","speed":1,"glow":1.2},"thinking":{"formation":"gyro","core":"knot","primary":"#4f8bff","rim":"#d8e8ff","speed":1.2,"glow":1.1},"speaking":{"formation":"waveform","speed":1,"glow":1.2},"working":{"formation":"orbit","speed":1,"glow":1},"alert":{"formation":"lantern","core":"star","primary":"#ffb020","rim":"#ffe7a8","speed":1,"glow":1.1},"error":{"formation":"shatter","core":"scatter","primary":"#ff3b5c","rim":"#ffc2cc","speed":1,"glow":1},"dormant":{"formation":"horizon","core":"spark","primary":"#3d5a73","rim":"#86a6bf","speed":1,"glow":0.5},"done":{"primary":"#3dffc5","rim":"#d5fff1","glow":1.4}}},
      {"name":"Aurora","palette":{"primary":"#2fe0a8","rim":"#c9b6ff"},"rings":{"count":7,"thickness":0.012,"style":"solid"},"core":{"shape":"galaxy","size":1.1,"density":1},"effects":{"bloom":0.6,"scanlines":0.2,"grain":0.25,"glitch":0.15,"aberration":0.6},"motion":0.85,"states":{"idle":{"formation":"crown","speed":1,"glow":1},"listening":{"formation":"dish","core":"orb","primary":"#36d6e8","rim":"#d4f7ff","speed":1,"glow":1.15},"thinking":{"formation":"helix","core":"helix","primary":"#8a6cff","rim":"#e0d4ff","speed":1,"glow":1.1},"speaking":{"formation":"waveform","core":"orb","speed":1,"glow":1.15},"working":{"formation":"orbit","speed":1,"glow":1},"alert":{"formation":"lantern","core":"crystal","primary":"#ffa040","rim":"#ffe0b8","speed":1,"glow":1},"error":{"formation":"shatter","core":"scatter","primary":"#ff4f7b","rim":"#ffc0d0","speed":1,"glow":1},"dormant":{"formation":"horizon","core":"spark","primary":"#3a6a66","rim":"#8fbab4","speed":1,"glow":0.5},"done":{"primary":"#7dff9a","rim":"#e2ffe8","glow":1.3}}},
      {"name":"Ember","palette":{"primary":"#ff7a2f","rim":"#ffd29a"},"rings":{"count":5,"thickness":0.02,"style":"dashed"},"core":{"shape":"star","size":1,"density":0.9},"effects":{"bloom":0.6,"scanlines":0.45,"grain":0.4,"glitch":0.35,"aberration":0.5},"motion":1,"states":{"idle":{"formation":"logo","speed":1,"glow":1},"listening":{"formation":"dish","core":"orb","primary":"#ff9d4a","rim":"#ffe2bd","speed":1,"glow":1.15},"thinking":{"formation":"gyro","core":"cube","primary":"#ff5e3a","rim":"#ffc4a8","speed":1.1,"glow":1.1},"speaking":{"formation":"waveform","core":"orb","speed":1,"glow":1.15},"working":{"formation":"tower","core":"galaxy","speed":1,"glow":1},"alert":{"formation":"lantern","core":"crystal","primary":"#ffd23f","rim":"#fff1b8","speed":1,"glow":1.1},"error":{"formation":"shatter","core":"scatter","primary":"#ff3d81","rim":"#ffc0d8","speed":1,"glow":1},"dormant":{"formation":"horizon","core":"spark","primary":"#6e4a3a","rim":"#b89484","speed":1,"glow":0.5},"done":{"primary":"#ffe066","rim":"#fff6cc","glow":1.3}}},
      {"name":"Mono","palette":{"primary":"#9aa4b8","rim":"#f2f5fb"},"rings":{"count":4,"thickness":0.01,"style":"dotted"},"core":{"shape":"lattice","size":0.9,"density":0.7},"effects":{"bloom":0.35,"scanlines":0.15,"grain":0.15,"glitch":0.1,"aberration":0.15},"motion":0.8,"states":{"idle":{"formation":"halo","speed":1,"glow":1},"listening":{"formation":"dish","core":"orb","speed":1,"glow":1.1},"thinking":{"formation":"gyro","core":"cube","speed":1,"glow":1.05},"speaking":{"formation":"waveform","core":"orb","speed":1,"glow":1.1},"working":{"formation":"orbit","speed":1,"glow":1},"alert":{"formation":"lantern","core":"crystal","primary":"#ffb020","rim":"#ffe4a8","speed":1,"glow":1},"error":{"formation":"shatter","core":"scatter","primary":"#ff5a5a","rim":"#ffc8c8","speed":1,"glow":1},"dormant":{"formation":"horizon","core":"spark","primary":"#5a6070","rim":"#a0a6b4","speed":1,"glow":0.5},"done":{"primary":"#e8fff4","rim":"#ffffff","glow":1.2}}},
      {"name":"Sakura","palette":{"primary":"#ff7eb6","rim":"#ffd1e6"},"rings":{"count":5,"thickness":0.016,"style":"solid"},"core":{"shape":"heart","size":1.2,"density":1},"effects":{"bloom":0.6,"scanlines":0.2,"grain":0.2,"glitch":0.15,"aberration":0.35},"motion":0.9,"states":{"idle":{"formation":"logo","speed":1,"glow":1},"listening":{"formation":"dish","core":"orb","primary":"#ff9ccd","rim":"#ffe3f1","speed":1,"glow":1.15},"thinking":{"formation":"helix","core":"star","primary":"#c58bff","rim":"#ecdcff","speed":1,"glow":1.1},"speaking":{"formation":"waveform","core":"orb","speed":1,"glow":1.15},"working":{"formation":"orbit","core":"galaxy","speed":1,"glow":1},"alert":{"formation":"lantern","core":"crystal","primary":"#ffb347","rim":"#ffe5c2","speed":1,"glow":1},"error":{"formation":"shatter","core":"scatter","primary":"#ff4d6d","rim":"#ffc4cf","speed":1,"glow":1},"dormant":{"formation":"horizon","core":"spark","primary":"#7a5068","rim":"#c49ab2","speed":1,"glow":0.5},"done":{"primary":"#9dffb0","rim":"#e6ffec","glow":1.3}}}
    ]
    """#
}
