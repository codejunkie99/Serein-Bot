import Foundation

/// A bounded exhaustive model checker (TEAMS-V2, "Formal verification without TLA+"). A machine is
/// a start state and the steps enabled in a state; each step calls the shipped reducer, so the
/// model cannot drift from the code. Every interleaving is explored breadth-first under the
/// machine's caps, so the first violation found has the shortest trace.
public struct FormalMachine<State: Encodable> {
  public typealias Step = (label: String, next: State)
  public var name: String
  /// The caps, in words, printed with the result.
  public var bounds: String
  public var start: State
  public var steps: (State) -> [Step]
  /// Must hold in every reachable state.
  public var invariants: [(String, (State) -> Bool)] = []
  /// Must hold for every step taken: (before, label, after).
  public var transitions: [(String, (State, String, State) -> Bool)] = []
  /// From every reachable state, some state where this holds is reachable (AG EF).
  public var eventually: [(String, (State) -> Bool)] = []
  /// A state's identity; nil uses its sorted JSON. Two states with one key must behave the same.
  public var key: ((State) -> String)? = nil
  /// Past this many states the run fails instead of hanging: lower the bounds.
  public var stateCap = 1_500_000
}

public struct FormalResult: Sendable {
  public var name: String
  public var bounds: String
  public var states: Int
  public var transitions: Int
  public var depth: Int
  public var seconds: Double
  /// The property broken and the steps from the start that break it; nil on a pass.
  public var violation: (property: String, trace: [String])?

  public var report: String {
    let head = "formal \(name): \(violation == nil ? "PASS" : "FAIL")  states \(states)  transitions \(transitions)  depth \(depth)  "
      + String(format: "%.2f s", seconds) + "  (\(bounds))"
    guard let violation else { return head }
    let steps = violation.trace.isEmpty ? ["  (the start state)"] : violation.trace.enumerated().map { "  \($0.offset + 1). \($0.element)" }
    return ([head, "  broken: \(violation.property)", "  shortest counterexample:"] + steps).joined(separator: "\n")
  }
}

extension FormalMachine {
  public func check() -> FormalResult {
    let clock = Date()
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    func key(_ s: State) -> Data {
      if let key = self.key { return Data(key(s).utf8) }
      return (try? encoder.encode(s)) ?? Data()
    }

    var states = [start]
    var parent = [(-1, "")]
    var depth = [0]
    var seen = [key(start): 0]
    var edges: [[Int]] = [[]]
    var count = 0
    func trace(_ i: Int) -> [String] {
      var path: [String] = []
      var at = i
      while parent[at].0 >= 0 { path.append(parent[at].1); at = parent[at].0 }
      return path.reversed()
    }
    func result(_ broken: (String, [String])?) -> FormalResult {
      FormalResult(name: name, bounds: bounds, states: states.count, transitions: count, depth: depth.max() ?? 0,
                   seconds: Date().timeIntervalSince(clock), violation: broken)
    }
    if let bad = invariants.first(where: { !$0.1(start) }) { return result((bad.0, [])) }

    var head = 0
    while head < states.count {
      let here = states[head]
      for (label, next) in steps(here) {
        count += 1
        if let bad = transitions.first(where: { !$0.1(here, label, next) }) { return result((bad.0, trace(head) + [label])) }
        let k = key(next)
        if let known = seen[k] { edges[head].append(known); continue }
        let i = states.count
        if i >= stateCap { return result(("explored past \(stateCap) states: lower the bounds", trace(head) + [label])) }
        seen[k] = i
        states.append(next)
        parent.append((head, label))
        depth.append(depth[head] + 1)
        edges.append([])
        edges[head].append(i)
        if let bad = invariants.first(where: { !$0.1(next) }) { return result((bad.0, trace(i))) }
      }
      head += 1
    }

    for (property, goal) in eventually {
      var reverse = [[Int]](repeating: [], count: states.count)
      for (from, tos) in edges.enumerated() { for to in tos { reverse[to].append(from) } }
      var reaches = states.map(goal)
      var queue = reaches.indices.filter { reaches[$0] }
      while let at = queue.popLast() {
        for from in reverse[at] where !reaches[from] { reaches[from] = true; queue.append(from) }
      }
      // States are numbered in breadth-first order, so the first stuck one has the shortest trace.
      if let stuck = reaches.firstIndex(of: false) { return result((property, trace(stuck) + ["(no step from here reaches it)"])) }
    }
    return result(nil)
  }
}

/// Every machine `--verify-formal` runs. Frames and SettingsUndo (TEAMS-V2 rows 2a and 10) each
/// add a `Formal/<Name>Machine.swift` with a `static var machine` and one line here.
public enum FormalCheck {
  public static let machines: [(String, @Sendable () -> FormalResult)] = [
    ("chain", { ChainMachine.machine.check() }),
    ("chain-caps", { ChainMachine.capMachine.check() }),
    ("mentions", { ChainMachine.mentionMachine.check() }),
    ("report", { ReportMachine.machine.check() }),
    ("staffing", { StaffingMachine.machine.check() }),
    ("packet", { PacketMachine.machine.check() }),
    ("seats", { SeatMachine.machine.check() }),
  ]

  /// Runs every machine, or only those named in `arguments`, printing one result each; false when any is broken.
  public static func run(_ arguments: [String] = []) -> Bool {
    let named = machines.filter { arguments.contains($0.0) }
    var passed = true
    for (_, check) in named.isEmpty ? machines : named {
      let result = check()
      print(result.report)
      passed = passed && result.violation == nil
    }
    print(passed ? "formal: PASS" : "formal: FAIL")
    return passed
  }
}
