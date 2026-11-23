import Foundation

/// A task shell reaches any host (owner, 2026-11-18). Tools that read the proxy environment send
/// their HTTP and HTTPS through the thread's policy proxy (`PluginEgress(policy:)`), which raises
/// the person's card for a payment service below Allow all. Nothing is fenced: a tool that
/// ignores the environment goes direct, so the guard is a courtesy card for cooperative tools,
/// not a wall (PAYGUARD-REVIEW M3, M4).
public enum ShellNetwork {
  /// The thread's proxy port. There is no unguarded plan.
  public struct Plan: Hashable, Sendable {
    public let port: UInt16

    public init(port: UInt16) { self.port = port }
  }

  /// HTTPS and plain http through the proxy; Node only reads these with `NODE_USE_ENV_PROXY`.
  /// The proxy chains to the person's own `HTTPS_PROXY`; hosts in their `NO_PROXY` stay direct.
  public static func environment(port: UInt16, inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    let proxy = "http://127.0.0.1:\(port)"
    let own = inherited["NO_PROXY"] ?? inherited["no_proxy"] ?? ""
    let local = (["localhost", "127.0.0.1", "::1"] + own.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
      .filter { !$0.isEmpty }.joined(separator: ",")
    return [
      "HTTPS_PROXY": proxy, "https_proxy": proxy, "HTTP_PROXY": proxy, "http_proxy": proxy, "NODE_USE_ENV_PROXY": "1",
      "NO_PROXY": local, "no_proxy": local,
    ]
  }

  /// Codex's permissions-profile `network` value: the shell's network is on. Its shells get the
  /// proxy through `shell_environment_policy.set`, as every other CLI's shells get it.
  public static let codexNetwork: [String: Any] = ["enabled": true]

  /// Claude's `sandbox.network`: its Bash reaches the network only through these ports, here
  /// the thread's proxy, which serves both framings (Claude gives Bash `ALL_PROXY=socks5h://`).
  public static func claudeNetwork(port: UInt16) -> [String: Any] {
    ["httpProxyPort": Int(port), "socksProxyPort": Int(port)]
  }
}
