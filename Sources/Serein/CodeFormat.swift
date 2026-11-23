import Foundation

/// The name over a code box: what the reply labelled it, spelled as people know it, or a
/// guess from the block itself when the reply gave none (a post draft reads "Text").
enum CodeFormat {
  /// Fence labels and the names a person reads.
  static let names: [String: String] = [
    "swift": "Swift", "js": "JavaScript", "javascript": "JavaScript", "jsx": "JSX",
    "ts": "TypeScript", "typescript": "TypeScript", "tsx": "TSX", "py": "Python", "python": "Python",
    "sh": "Shell", "bash": "Shell", "zsh": "Shell", "shell": "Shell", "console": "Shell",
    "json": "JSON", "md": "Markdown", "markdown": "Markdown", "html": "HTML", "css": "CSS",
    "yaml": "YAML", "yml": "YAML", "toml": "TOML", "xml": "XML", "sql": "SQL", "go": "Go",
    "rs": "Rust", "rust": "Rust", "rb": "Ruby", "ruby": "Ruby", "java": "Java", "kt": "Kotlin",
    "kotlin": "Kotlin", "c": "C", "cpp": "C++", "c++": "C++", "cs": "C#", "csharp": "C#",
    "php": "PHP", "diff": "Diff", "text": "Text", "txt": "Text", "plain": "Text", "plaintext": "Text",
  ]
  /// Past this size a block is not parsed to tell whether it is JSON.
  static let jsonProbeLimit = 200_000
  private static let shellCommands = ["git ", "npm ", "pnpm ", "yarn ", "swift ", "cd ", "brew ", "curl ",
    "python3 ", "python ", "pip ", "ls ", "mkdir ", "open ", "sudo ", "export "]
  private static let codeSigns = ["func ", "let ", "var ", "def ", "import ", "const ", "return ", "=>",
    "class ", "struct ", "#include", "fn ", "public "]

  static func name(_ code: String, language: String?) -> String {
    if let label = language?.trimmingCharacters(in: .whitespaces), !label.isEmpty {
      return names[label.lowercased()] ?? label.prefix(1).uppercased() + label.dropFirst()
    }
    return guess(code)
  }

  static func guess(_ code: String) -> String {
    let body = code.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return "Text" }
    if (body.hasPrefix("{") || body.hasPrefix("[")), body.utf8.count <= jsonProbeLimit,
      (try? JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed])) != nil {
      return "JSON"
    }
    if body.hasPrefix("<"), body.contains("</") { return "HTML" }
    let lines = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    let first = lines.first ?? ""
    if first.hasPrefix("$ ") || shellCommands.contains(where: first.hasPrefix) { return "Shell" }
    if lines.contains(where: { line in codeSigns.contains { line.hasPrefix($0) } })
      || lines.contains(where: { $0.hasSuffix(";") || $0.hasSuffix("{") }) {
      return "Code"
    }
    let markdown = lines.contains { line in
      ["# ", "## ", "### ", "- ", "* ", "> ", "1. "].contains(where: line.hasPrefix)
    } || body.contains("**") || body.contains("](")
    return markdown ? "Markdown" : "Text"
  }
}
