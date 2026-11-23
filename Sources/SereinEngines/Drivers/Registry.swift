/// Every CLI driver. Add one line per driver file in this folder.
enum DriverRegistry {
  static let all: [any Driver] = [
    ClaudeDriver(),
    CodexDriver(),
    PiDriver(cli: .pi), PiDriver(cli: .ohMyPi),
    CursorDriver(),
    GrokDriver(),
    GeminiDriver(),
    OpenCodeDriver(),
  ]
}
