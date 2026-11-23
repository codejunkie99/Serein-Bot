import Foundation

/// Serein's side of Cua Driver's protocol (MCP over stdio, the legacy `2025-06-18` revision): one
/// JSON-RPC 2.0 object per line, both ways, over one raw link connection that runs
/// `CuaDriverRelease.mcpCommand` inside the built-in computer (DriverChannel in the app). Serein
/// is the only client; no agent sees the driver or its tools. Everything the driver sends is
/// untrusted: lines are capped, every message is read into typed fields only, and a shape Serein
/// does not know (a schema change) fails closed with Serein's own words, never the driver's.
public enum DriverWire {
  /// Bytes one line may hold: a 1280×800 desktop picture is a few MB of base64.
  public static let lineLimit = 8 << 20
  /// The revision Serein speaks: legacy `initialize`, then requests without per-request metadata.
  public static let protocolVersion = "2025-06-18"
  public static let serverName = "cua-driver"

  public enum Failure: Error, Equatable {
    /// A line (or the unfinished end of the stream) is longer than `lineLimit`: out of step.
    case lineTooLong
  }

  /// The whole lines in what the driver sent so far; the rest waits for its newline.
  public struct Lines {
    private var buffer = Data()
    /// Bytes at the front of `buffer` already searched for a newline, so a long line arriving in
    /// many pieces is searched once.
    private var searched = 0
    public init() {}
    /// Takes `data` and gives every whole line in it (without the newline, empty lines dropped);
    /// throws when a line passes `lineLimit`, after which the stream must end.
    public mutating func take(_ data: Data) throws -> [Data] {
      var cursor = buffer.index(buffer.startIndex, offsetBy: searched)
      buffer.append(data)
      var lines: [Data] = []
      var start = buffer.startIndex
      while let newline = buffer[cursor...].firstIndex(of: 10) {
        let line = buffer[start..<newline]
        guard line.count <= DriverWire.lineLimit else { throw Failure.lineTooLong }
        if !line.isEmpty { lines.append(Data(line)) }
        start = buffer.index(after: newline)
        cursor = start
      }
      buffer.removeSubrange(buffer.startIndex..<start)
      searched = buffer.count
      guard buffer.count <= DriverWire.lineLimit else { throw Failure.lineTooLong }
      return lines
    }
  }

  // MARK: what Serein sends

  /// The only tools Serein ever calls. A tool that is not a case here (`run_script`, `run_steps`,
  /// `browser_*`, `page`, `clipboard_*`, `launch_app`, `kill_app`,
  /// `install_*`, `check_for_update`, `set_config`, recording and history tools) cannot be named.
  public enum Tool: String, CaseIterable, Sendable {
    case getDesktopState = "get_desktop_state"
    case click
    case typeText = "type_text"
    case pressKey = "press_key"
    case scroll
    case listWindows = "list_windows"
    case getWindowState = "get_window_state"
    case zoom
    case setValue = "set_value"
  }
  /// Tools and arguments Serein never sends, whatever later code asks (checked by `call`).
  public static let neverTools = [
    "run_script", "run_steps", "page", "get_browser_state", "install_ffmpeg", "install_extension", "check_for_update",
    "set_config", "get_config", "launch_app", "kill_app", "clipboard_read", "clipboard_write", "parse_visual_regions",
  ]
  public static let neverArguments = ["screenshot_out_file", "session"]

  /// One request line: `method` with `params`, under `id`.
  public static func request(id: Int, method: String, params: [String: Any]) -> Data? {
    line(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
  }
  /// The legacy handshake's first request.
  public static func initialize(id: Int) -> Data? {
    request(id: id, method: "initialize", params: [
      "protocolVersion": protocolVersion, "capabilities": [String: Any](), "clientInfo": ["name": "Serein", "version": "1"],
    ])
  }
  /// The notification that ends the handshake.
  public static var initialized: Data? { line(["jsonrpc": "2.0", "method": "notifications/initialized"]) }
  /// One `tools/call` line, or nil when the arguments hold a name Serein never sends or are not
  /// plain JSON.
  public static func call(id: Int, _ tool: Tool, _ arguments: [String: Any]) -> Data? {
    guard !arguments.keys.contains(where: { neverArguments.contains($0) }) else { return nil }
    return request(id: id, method: "tools/call", params: ["name": tool.rawValue, "arguments": arguments])
  }
  /// The answer to a request the driver sent Serein (Serein offers it nothing): method not found.
  public static func refusal(toRequest id: Any) -> Data? {
    let plain: Any?
    if let number = integer(id) {
      plain = number
    } else if let text = id as? String, text.count <= 64 {
      plain = text
    } else {
      plain = nil
    }
    guard let plain else { return nil }
    return line(["jsonrpc": "2.0", "id": plain, "error": ["code": -32601, "message": "Serein answers no requests."]])
  }
  static func line(_ object: [String: Any]) -> Data? {
    guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else { return nil }
    return data + Data([10])
  }

  // MARK: what the driver sends

  public enum Message {
    /// The result of Serein's request `id`, an object.
    case result(id: Int, [String: Any])
    /// The error answer to Serein's request `id`: only its code is kept (the message is the driver's).
    case failure(id: Int, code: Int)
    /// A request from the driver to Serein, refused with `refusal(toRequest:)`.
    case request(id: Any)
    case notification
    /// Not JSON-RPC 2.0, or an answer Serein cannot pair with a request.
    case malformed
  }
  public static func message(_ line: Data) -> Message {
    guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], object["jsonrpc"] as? String == "2.0"
    else { return .malformed }
    if let method = object["method"] as? String, !method.isEmpty {
      if let id = object["id"], !(id is NSNull) { return .request(id: id) }
      return .notification
    }
    guard let id = integer(object["id"]) else { return .malformed }
    if let result = object["result"] as? [String: Any] { return .result(id: id, result) }
    if let error = object["error"] as? [String: Any], let code = integer(error["code"]) { return .failure(id: id, code: code) }
    return .malformed
  }

  /// Why the driver's `initialize` result is not the pinned driver speaking Serein's revision, or nil.
  public static func handshakeRefusal(_ result: [String: Any]) -> String? {
    let info = result["serverInfo"] as? [String: Any]
    let capabilities = result["capabilities"] as? [String: Any]
    let offersTools: Bool = capabilities?["tools"] is [String: Any]
    guard result["protocolVersion"] as? String == protocolVersion, info?["name"] as? String == serverName, offersTools
    else { return "Cua Driver in this computer did not answer as Serein expects, so Serein did not use it." }
    guard info?["version"] as? String == CuaDriverRelease.version else {
      return "Cua Driver in this computer is not the version this copy of Serein pins, so Serein did not use it."
    }
    return nil
  }

  /// The arguments Serein may send each tool (DriverCalls builds them from these names only).
  public static func argumentNames(_ tool: Tool) -> [String] {
    let target = ["target", "delivery_mode"]
    // An element of one window's latest read: its process and the read's token (`s<read>:<index>`).
    let element = ["pid", "element_token"]
    switch tool {
    case .getDesktopState: return ["max_image_dimension"]
    case .click: return target + element + ["x", "y", "button", "count", "capture_id"]
    case .typeText: return target + element + ["text"]
    case .pressKey: return target + element + ["key", "modifiers"]
    case .scroll: return target + element + ["x", "y", "direction", "amount"]
    case .setValue: return element + ["delivery_mode", "value"]
    case .listWindows: return ["on_screen_only"]
    case .getWindowState: return ["pid", "window_id", "max_elements", "timeout_ms", "include_screenshot", "tree_format"]
    case .zoom: return ["window_id", "x1", "y1", "x2", "y2"]
    }
  }
  /// Why the driver's `tools/list` result does not offer what Serein calls, or nil: every Tool by
  /// name, with an input schema that names every argument Serein sends it (the pinned subset).
  public static func inventoryRefusal(_ result: [String: Any]) -> String? {
    guard let tools = result["tools"] as? [[String: Any]] else {
      return "Cua Driver in this computer did not list its tools as Serein expects, so Serein did not use it."
    }
    for tool in Tool.allCases {
      let entry = tools.first { $0["name"] as? String == tool.rawValue }
      let schema = entry?["inputSchema"] as? [String: Any]
      let properties = schema?["properties"] as? [String: Any] ?? [:]
      let named: Bool = argumentNames(tool).allSatisfy { properties[$0] != nil }
      guard entry != nil, named else {
        return "Cua Driver in this computer does not offer \(tool.rawValue) as this copy of Serein expects, so Serein did not use it."
      }
    }
    return nil
  }
  /// A result Serein cannot read: it is dropped, never shown.
  public static func unreadable(_ tool: Tool) -> String {
    "Cua Driver answered \(tool.rawValue) in a form this copy of Serein does not read, so Serein did not use the answer."
  }

  /// A `tools/call` result read into typed parts: whether the tool failed, its text and image
  /// parts, and its structured content. All of it is untrusted.
  public struct ToolAnswer {
    public struct Image: Equatable, Sendable {
      public var mimeType: String
      /// Base64, as sent.
      public var data: String
      public init(mimeType: String, data: String) {
        self.mimeType = mimeType
        self.data = data
      }
    }
    public var isError: Bool
    public var texts: [String]
    public var images: [Image]
    public var structured: [String: Any]?
    public init(isError: Bool, texts: [String], images: [Image], structured: [String: Any]?) {
      self.isError = isError
      self.texts = texts
      self.images = images
      self.structured = structured
    }
  }
  /// The parts a result may hold: at most this many.
  public static let partLimit = 16
  /// The result as a ToolAnswer, or nil when its shape is not MCP's (content not a list of text
  /// and image parts, structured content not an object).
  public static func toolAnswer(_ result: [String: Any]) -> ToolAnswer? {
    guard let content = result["content"] as? [[String: Any]], content.count <= partLimit else { return nil }
    var texts: [String] = []
    var images: [ToolAnswer.Image] = []
    for part in content {
      switch part["type"] as? String {
      case "text":
        guard let text = part["text"] as? String else { return nil }
        texts.append(String(text.prefix(4_000)))
      case "image":
        guard let data = part["data"] as? String, let mime = part["mimeType"] as? String else { return nil }
        images.append(ToolAnswer.Image(mimeType: mime, data: data))
      default:
        return nil
      }
    }
    let structured: [String: Any]?
    if let value = result["structuredContent"] {
      guard let object = value as? [String: Any] else { return nil }
      structured = object
    } else {
      structured = nil
    }
    let isError: Bool
    if let flag = result["isError"] {
      guard let value = flag as? Bool else { return nil }
      isError = value
    } else {
      isError = false
    }
    return ToolAnswer(isError: isError, texts: texts, images: images, structured: structured)
  }

  /// The driver's own code for a failure (`structuredContent.code`, `.error.code`, or a refused
  /// action's `effect`), when it is a plain short word; "unknown" otherwise.
  public static func failureCode(_ answer: ToolAnswer) -> String {
    let structured = answer.structured ?? [:]
    let nested: String? = (structured["error"] as? [String: Any])?["code"] as? String
    let refused: Bool = structured["effect"] as? String == "refused"
    let effect: String? = refused ? "refused" : nil
    let own: String? = structured["code"] as? String
    let refusal: String? = (structured["refusal"] as? [String: Any])?["code"] as? String
    let code: String = own ?? nested ?? refusal ?? effect ?? ""
    let plain = !code.isEmpty && code.count <= 48 && code.allSatisfy { "abcdefghijklmnopqrstuvwxyz0123456789_".contains($0) }
    return plain ? code : "unknown"
  }
  /// The one-use picture binding failed: the picture is gone or too old (the driver keeps one
  /// for 60 seconds and lets one action use it).
  public static let staleCaptureCodes: Set<String> = ["capture_not_found", "capture_expired"]
  public static let staleCapture =
    "The screen picture this click was aimed at is too old or was already used. Take a new screenshot with computer_screenshot, then click again."
  /// Serein's words for a failed step: never the driver's text, which is untrusted.
  public static func refusal(_ tool: Tool, code: String) -> String {
    if staleCaptureCodes.contains(code) { return staleCapture }
    return "Serein's computer did not do that step (\(tool.rawValue): \(code)). Take a screenshot to see where things are."
  }

  // MARK: typed values

  /// An integer from untrusted JSON: a number with no fraction (never a boolean).
  public static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let double = number.doubleValue
    guard double.isFinite, double == double.rounded(), abs(double) < 1e15 else { return nil }
    return Int(double)
  }
  /// A finite number from untrusted JSON (never a boolean).
  public static func number(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
      return nil
    }
    return number.doubleValue
  }
}
