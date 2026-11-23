import Foundation
import SereinCore

enum DirectHTTPCompatibility {
  static func schemaLimited(host: String, model: String) -> Bool {
    ["api.moonshot.ai", "api.moonshot.cn", "api.kimi.com"].contains(host)
      || (host == "openrouter.ai" && model.lowercased().hasPrefix("moonshotai/"))
  }

  /// Resolve local schema references, which many hosts refuse. A size-limited host also gets each
  /// schema cut to its cap. The host still validates original arguments.
  static func fittedTools(_ tools: [[String: Any]], sizeLimited: Bool) throws -> [[String: Any]] {
    try tools.map { original in
      guard var function = original["function"] as? [String: Any], let root = function["parameters"] as? [String: Any] else { return original }
      var budget = 24000
      var clipped = false
      func fit(_ value: Any, depth: Int, compact: Bool) -> Any {
        budget -= 1
        if depth >= 29 || budget <= 0 { clipped = true; return [:] as [String: Any] }
        guard let object = value as? [String: Any] else { return value }
        if let ref = object["$ref"] as? String, ref.hasPrefix("#/") {
          var target: Any? = root
          for key in ref.dropFirst(2).components(separatedBy: "/") {
            target = (target as? [String: Any])?[key.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")]
          }
          if let target { return fit(target, depth: depth + 1, compact: compact) }
        }
        var result: [String: Any] = [:]
        for (key, child) in object where !["$defs", "definitions", "$ref"].contains(key) {
          if compact && ["description", "title", "examples", "default"].contains(key) { continue }
          switch key {
          case "properties", "patternProperties", "dependentSchemas":
            if let fields = child as? [String: Any] { result[key] = fields.mapValues { fit($0, depth: depth + 2, compact: compact) } }
          case "allOf", "oneOf", "anyOf", "prefixItems":
            if let list = child as? [Any] { result[key] = list.map { fit($0, depth: depth + 2, compact: compact) } }
          case "items", "additionalProperties", "contains", "not", "if", "then", "else", "propertyNames":
            result[key] = fit(child, depth: depth + 1, compact: compact)
          default: result[key] = child
          }
        }
        return result
      }
      func encodedSize(_ value: Any) throws -> Int {
        let data = try JSONSerialization.data(withJSONObject: value)
        // Go's encoder escapes the three HTML-sensitive ASCII characters as six-byte sequences.
        return data.count + 5 * data.filter { $0 == 60 || $0 == 62 || $0 == 38 }.count
      }
      var schema = fit(root, depth: 0, compact: false)
      // With no cap to meet, a schema too deep to resolve whole goes as it came.
      if !sizeLimited, clipped { return original }
      if !sizeLimited {
        function["parameters"] = schema
        return ["type": "function", "function": function]
      }
      if try encodedSize(schema) > 12000 {
        budget = 24000
        schema = fit(root, depth: 0, compact: true)
      }
      if try encodedSize(schema) > 12000 { schema = ["type": "object"] }
      function["parameters"] = schema
      return ["type": "function", "function": function]
    }
  }

  /// Only a whole call envelope qualifies. Quoted examples embedded in prose remain ordinary text.
  static func localCall(_ text: String) -> DirectHTTPCall? {
    var payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if payload.hasPrefix("<tool_call>"), payload.hasSuffix("</tool_call>") {
      payload = String(payload.dropFirst("<tool_call>".count).dropLast("</tool_call>".count))
    } else if payload.hasPrefix("```json\n"), payload.hasSuffix("\n```") {
      payload = String(payload.dropFirst(8).dropLast(4))
    }
    payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
    if payload.hasPrefix("<function="), payload.hasSuffix("</function>"), let end = payload.firstIndex(of: ">") {
      let name = String(payload[payload.index(payload.startIndex, offsetBy: 10)..<end])
      var rest = String(payload[payload.index(after: end)...].dropLast("</function>".count)).trimmingCharacters(in: .whitespacesAndNewlines)
      var args: [String: Any] = [:]
      while !rest.isEmpty {
        guard rest.hasPrefix("<parameter="), let split = rest.firstIndex(of: ">"),
          let close = rest.range(of: "</parameter>", range: rest.index(after: split)..<rest.endIndex) else { return nil }
        let key = String(rest[rest.index(rest.startIndex, offsetBy: 11)..<split])
        guard !key.isEmpty, args[key] == nil else { return nil }
        let value = String(rest[rest.index(after: split)..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        args[key] = (try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)) ?? value
        rest = String(rest[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      return call(name: name, arguments: args, id: "")
    }
    // Local models also name the arguments "parameters", or send them as a JSON string.
    guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
      Set(object.keys).isSubset(of: ["name", "id", "arguments", "parameters"]), let name = object["name"] as? String,
      object["arguments"] == nil || object["parameters"] == nil, let given = object["arguments"] ?? object["parameters"],
      let args = given as? [String: Any]
        ?? (given as? String).flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
    else { return nil }
    return call(name: name, arguments: args, id: object["id"] as? String ?? "")
  }

  private static func call(name: String, arguments: [String: Any], id: String) -> DirectHTTPCall? {
    guard !name.isEmpty, let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]) else { return nil }
    return DirectHTTPCall(id: id, name: name, arguments: String(decoding: data, as: UTF8.self))
  }
}
