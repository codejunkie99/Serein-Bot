import AppKit
import SereinCore

extension AgentModel {
  /// `given`: a transcript picked in the Agents list; nil asks for one. The workspace folder is
  /// always confirmed by the user (it opens at the folder the transcript records).
  func importSession(_ given: URL? = nil) {
    guard !running else { return }
    let file: URL
    if let given {
      file = given
    } else {
      let panel = NSOpenPanel()
      panel.message =
        "Select one Codex rollout or Claude conversation JSONL file. Only user/assistant text and its session ID are imported."
      panel.allowsMultipleSelection = false
      guard panel.runModal() == .OK, let picked = panel.url else { return }
      file = picked
    }
    do {
      let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size < 32_000_000 else {
        throw SereinError.invalid("Choose a session file smaller than 32 MB")
      }
      let text = try String(contentsOf: file)
      var provider: Provider = .codex
      var nativeID: String?
      var cwd: String?
      var imported: [AgentMessage] = []
      for line in text.split(separator: "\n") {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else { continue }
        if obj["type"] as? String == "session_meta", let payload = obj["payload"] as? [String: Any]
        {
          nativeID = payload["id"] as? String
          cwd = payload["cwd"] as? String
        }
        if let id = obj["sessionId"] as? String {
          provider = .claude
          nativeID = id
          cwd = obj["cwd"] as? String ?? cwd
        }
        let payload =
          (obj["payload"] as? [String: Any]) ?? (obj["message"] as? [String: Any]) ?? [:]
        guard let role = payload["role"] as? String, ["user", "assistant"].contains(role) else {
          continue
        }
        let content: String
        if let parts = payload["content"] as? [[String: Any]] {
          content = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
          content = payload["content"] as? String ?? ""
        }
        if !content.isEmpty {
          imported.append(
            AgentMessage(
              role: role == "user" ? "you" : "assistant", text: String(content.prefix(100000))))
        }
      }
      guard !imported.isEmpty, let nativeID, UUID(uuidString: nativeID) != nil else {
        throw SereinError.invalid("No valid conversation and native session ID found")
      }
      let folderPanel = NSOpenPanel()
      folderPanel.canChooseDirectories = true
      folderPanel.canChooseFiles = false
      folderPanel.message =
        "Choose the workspace for this imported conversation. The file suggests: \(cwd ?? "unknown"). Confirm the folder yourself."
      if let cwd { folderPanel.directoryURL = URL(fileURLWithPath: cwd) }
      guard folderPanel.runModal() == .OK, let folder = folderPanel.url else { return }
      guard let cwd,
        URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
          == folder.resolvingSymlinksInPath().path
      else {
        throw SereinError.invalid(
          "Native resume must use the original workspace. Choose the folder recorded in the session."
        )
      }
      let id = UUID().uuidString
      // Keep the imported conversation read-only until the user explicitly selects edit permission.
      let scope = "\(provider.rawValue)|\(TaskMode.project.rawValue)|\(id)|false|false"
      NotificationCenter.default.post(
        name: Notification.Name("SereinImportProject"),
        object: ProjectWithConversation(
          project: Project(name: folder.lastPathComponent, path: folder.path, source: .added),
          provider: provider,
          nativeID: nativeID, messages: imported, scope: scope))
    } catch { self.error = error.localizedDescription }
  }
  func acceptImported(_ value: ProjectWithConversation, browser: BrowserModel) {
    var project = value.project
    // The folder comes from the imported file: never one inside Serein's own data.
    if browser.insideSereinData(project.path) { return browser.refuseSereinDataFolder() }
    if let known = browser.projects.first(where: { $0.path == project.path }) {
      project = known
    } else {
      browser.projects.append(project)
      browser.saveProjects()
      browser.warnIfHoldsSereinData([project.path])
    }
    clear()
    let item = Conversation(
      id: UUID().uuidString,
      title: String(value.messages.first?.text.prefix(100) ?? "Imported conversation"),
      messages: value.messages, provider: value.provider, mode: .project, projectID: project.id,
      remoteID: value.nativeID,
      // The first send keeps the native session (Agent.send compares its own scope string).
      scope: AgentModel.adoptScope(value.provider),
      updatedAt: Date())
    allowActions = false
    allowProjectEdits = false
    restore(item)
    saveConversation()
    browser.section = ShellSection.thread
  }
}
struct ProjectWithConversation {
  var project: Project
  var provider: Provider
  var nativeID: String
  var messages: [AgentMessage]
  var scope: String
}
