import Foundation
import SereinCore

/// Serein's computer through Cua Driver: element steps behind the box's code floor (BoxFloor),
/// computer_steps, the person-ask, and secure cards filled inside the computer. ComputerHost.call
/// and perform reach here through one hook each; everything else about the computer stays there.
extension ComputerHost {
  /// A secure card's field inside Serein's computer: the task and computer it was raised for, and
  /// the element as the read showed it. The fill reads its window again and checks it is the same.
  struct BoxField {
    let assistantID: String
    let connectionID: UUID
    let task: String
    let target: BoxTarget
    let stop: BoxFloor.Stop
  }

  /// The person asked to take control of the computer for a step only they can do there. While it
  /// is open, screen steps wait (StepGuard) and looks go on. Hand-back or a dismiss closes it.
  struct PersonAsk: Equatable {
    let task: String
    let reason: String
    let opened: Date
    /// The CAPTCHAs it was opened for (FreshRead.checkID): once it closes they are the person's.
    var checks: Set<String> = []
  }

  /// Which screen a computer's steps go through: the helper (where the place's own commands reach
  /// the screen anyway), or Cua Driver. `driverFailed` says why the driver's last open failed; the
  /// step that met it was refused (driverScreen), and the next step tries again.
  enum ScreenPath: Equatable {
    case helper
    case driver
    case driverFailed(String, at: Date)
  }

  static let driverOnly =
    "Serein's computer here takes x and y only: element refs, set_value and zoom need Cua Driver, which it does not run now. Use computer_screenshot and x, y."

  /// perform's cases for the box tools and the element forms of click, type and scroll; nil for
  /// any other step, which perform runs as before.
  func performBox(_ name: String, _ a: [String: Any], task id: String, computer: Computer, browser: BrowserModel)
    async throws -> [String: Any]?
  {
    switch name {
    case "computer_ask_person":
      guard let reason = a["reason"] as? String, !reason.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw SereinError.invalid("reason is required.")
      }
      openAsk(computer, task: id, reason: reason, browser: browser)
      return ["asked": ComputerTools.askedPerson]
    case "computer_steps":
      return try await runSteps(a, task: id, computer: computer, browser: browser)
    case "computer_screenshot" where computer.carriesDriver && computer.machine?.driverCommand != nil:
      // Every picture of a computer that carries Cua Driver is masked on its reads (DriverScreen.look).
      guard try await driverScreen(computer) != nil else { throw SereinError.invalid(Self.noPicture) }
      return nil
    case "computer_zoom":
      guard let driver = try await driverScreen(computer) else { throw SereinError.invalid(Self.driverOnly) }
      let shot = try await driver.zoom(try driver.element(a["element"]).target)
      return ["content": [
        ["type": "image", "mimeType": "image/jpeg", "data": shot["jpeg"] ?? ""],
        ["type": "text", "text": "A close-up of \(a["element"] ?? "the element"); computer_click takes its ref, not pixels in this picture."],
      ]]
    case "computer_click", "computer_type", "computer_key", "computer_scroll", "computer_set_value":
      let step = String(name.dropFirst("computer_".count))
      if a["element"] == nil, step == "click" || step == "scroll", a["x"] == nil || a["y"] == nil {
        throw SereinError.invalid("\(name) takes element (a ref from computer_tree) or x and y (pixels of computer_screenshot).")
      }
      guard let driver = try await driverScreen(computer) else {
        if a["element"] != nil || step == "set_value" { throw SereinError.invalid(Self.driverOnly) }
        return nil
      }
      return try await boxStep(step, a, task: id, computer: computer, browser: browser, driver: driver)
    default:
      return nil
    }
  }

  /// One screen step on the driver. By ref, or set_value: DriverScreen.step reads the element's
  /// window whole, judges it there and acts. By x, y: DriverScreen.click reads every window at the
  /// point whole and judges every row there. Bare typing and a bare key that types or presses are
  /// refused (Cua Driver reports no focus); a scroll and keys that only move go to perform as before.
  private func boxStep(
    _ step: String, _ a: [String: Any], task id: String, computer: Computer, browser: BrowserModel, driver: DriverScreen
  ) async throws -> [String: Any]? {
    // A value an earlier task filled may still be on the box's clipboard: it is cleared first,
    // and until it is, this task pastes nothing either.
    let filled = FilledValues.shared
    if filled.clipboardOwed(box: computer.id, task: id),
      (try? await computer.helper.call("run", ["command": Self.clearClipboard], timeout: 20))?["code"] as? Int == 0
    {
      filled.clipboardCleared(box: computer.id)
    }
    let facts = BoxFloor.Facts(had: computer.steps.hadChecks, filled: filled.has(task: id) || filled.clipboardOwed(box: computer.id, task: id))
    // A middle click pastes X's own selection.
    if facts.filled, step == "click", a["button"] as? String == "middle" { throw SereinError.invalid(BoxFloor.noPaste) }
    if a["element"] != nil || step == "set_value" {
      if let stopped = try await driver.step(step, on: try driver.element(a["element"]).target, a, facts) {
        return try floorStop(stopped, task: id, computer: computer, browser: browser)
      }
      return Self.answer(step, a)
    }
    switch step {
    case "type":
      throw SereinError.invalid(Self.focusUnknown)
    case "key":
      let presses = DriverCalls.keyPresses(String(describing: a["key"] ?? "")) ?? []
      if presses.contains(where: { BoxFloor.reach($0) != nil }) { throw SereinError.invalid(Self.focusUnknown) }
      if facts.filled, presses.contains(where: BoxFloor.pastes) { throw SereinError.invalid(BoxFloor.noPaste) }
      guard presses.contains(where: BoxFloor.judgedBare) else { return nil }
      if let stopped = try await driver.keys(a, facts) { return try floorStop(stopped, task: id, computer: computer, browser: browser) }
      return Self.answer(step, a)
    case "click":
      if let stopped = try await driver.click(a, facts) { return try floorStop(stopped, task: id, computer: computer, browser: browser) }
      return ["clicked": true]
    default:
      return nil
    }
  }
  static let focusUnknown =
    "Cua Driver reports no keyboard focus, so Serein does not know where that text or key lands and does not send it. Use computer_type or computer_key with element: a ref from computer_tree. Keys that only move (Tab, arrows, Escape, PageUp) need no element."
  static let noPicture =
    "Cua Driver in Serein's computer did not open, and without its read Serein cannot black out where the person's values may show, so it sends no picture. Use computer_tree, and try computer_screenshot again in a moment."

  /// A step's picture for its record (StepPictures): the helper's, which binds no click, masked on
  /// Cua Driver's reads (DriverScreen.stepPicture) on a computer that carries the driver, and none
  /// while the driver is not open there; nil when there is none to keep.
  func stepPicture(_ computer: Computer) async -> Data? {
    let helper = computer.helper, rule = ScreenPicture.rule(isolated: computer.place.capabilities.isolated, driver: false)
    let shoot = { @MainActor () async throws -> Data in
      guard let base64 = try await helper.call("screenshot", timeout: 10)["png"] as? String, let png = Data(base64Encoded: base64),
        Self.screenSize(png, rule: rule) != nil
      else { throw SereinError.invalid("The computer sent no picture.") }
      return png
    }
    guard computer.carriesDriver, computer.machine?.driverCommand != nil else { return nil }
    guard let driver = computer.driver, driver.isOpen else { return nil }
    return try? await driver.stepPicture(shoot)
  }
  private static func answer(_ step: String, _ a: [String: Any]) -> [String: Any] {
    switch step {
    case "click": return ["clicked": true]
    case "type": return ["typed": (a["text"] as? String)?.count ?? 0]
    case "key": return ["pressed": a["key"] as? String ?? ""]
    case "scroll": return ["scrolled": true]
    default: return ["set": true]
    }
  }

  /// The floor said the step is the person's (a secure card Serein fills, or the ask) or is in a
  /// window Serein does not drive (BoxFloor.codeRunner). The step never runs, and nothing the
  /// person types reaches the model.
  private func floorStop(_ stopped: BoxFloor.Stopped, task id: String, computer: Computer, browser: BrowserModel) throws -> [String: Any] {
    let target = stopped.target
    switch stopped.stop {
    case .secureCard(let kind, let part) where target.row.token != nil && computer.driver != nil:
      guard let connectionID = computer.driver?.connectionID else { throw SereinError.invalid(Self.driverDown) }
      let field = BoxField(assistantID: computer.id, connectionID: connectionID, task: id, target: target, stop: stopped.stop)
      let card = SecureCards.Card(
        kind: kind, parts: kind == .card ? [part] : [], host: "Serein's computer", amount: nil, task: id,
        thread: browser.threadID(forTask: id), tab: nil, ref: "\(target.window)/\(target.nth)",
        document: target.row.role + " " + String(target.row.label.prefix(80)), origin: "computer:" + computer.id, pageVersion: "", box: field)
      var fields: [String: Any] = PersonStep.fields(browser.secureCards.raise(card))
      fields["stopped"] = true
      return fields
    case .secureCard:
      // A field the driver gives no address: Serein cannot fill it, so the person does.
      openAsk(computer, task: id, reason: "A field there takes your own details.", browser: browser)
      throw BoxFloor.asked(.personOnly(.password))
    case .askPerson(let mark):
      let captcha = mark == .personOnly(.captcha)
      let reason = mark == .pay ? "A press there pays." : captcha ? Self.botCheckReason : "A step there needs you."
      openAsk(computer, task: id, reason: reason, browser: browser, checks: stopped.check.map { [$0] } ?? [])
      throw BoxFloor.asked(mark)
    case .refused(let why):
      throw SereinError.invalid(why)
    }
  }

  /// computer_steps: each sub-step through perform as its own tool, with StepGuard's rules, in
  /// order. It stops at the first that fails or asks the person, and when the person asks to take
  /// over; then the look asked for.
  private func runSteps(_ a: [String: Any], task id: String, computer: Computer, browser: BrowserModel) async throws
    -> [String: Any]
  {
    guard let steps = a["steps"] as? [[String: Any]], (1...ComputerTools.stepsLimit).contains(steps.count) else {
      throw SereinError.invalid("steps is a list of 1 to \(ComputerTools.stepsLimit) steps.")
    }
    let look = a["look"] as? String ?? "tree"
    guard ["tree", "screenshot", "none"].contains(look) else { throw SereinError.invalid("look is tree, screenshot or none.") }
    var results: [[String: Any]] = []
    var stopped: String?
    for (index, step) in steps.enumerated() {
      guard let tool = step["tool"] as? String, ComputerTools.stepTools.contains(tool) else {
        throw SereinError.invalid("step \(index + 1): tool is " + ComputerTools.stepTools.joined(separator: ", ") + ".")
      }
      let name = "computer_" + tool
      var args = step
      args["tool"] = nil
      if computer.control != .assistant {
        stopped = "step \(index + 1): " + ComputerPolicy.personHasControl
        break
      }
      if let refusal = computer.steps.refusal(tool: name, asking: computer.ask != nil) {
        stopped = "step \(index + 1): " + refusal
        break
      }
      do {
        var result = try await perform(name, args, task: id, computer: computer, browser: browser, pictureStep: nil)
        computer.steps.ran(name, args, into: &result)
        results.append(result)
        if result["stopped"] as? Bool == true {
          stopped = "step \(index + 1) is the person's: Serein asked them on a secure card."
          break
        }
      } catch {
        stopped = "step \(index + 1): " + error.localizedDescription
        break
      }
    }
    var answer: [String: Any] = ["done": results.count, "results": results]
    if let stopped { answer["stopped"] = stopped }
    guard !browser.secureCards.open.contains(where: { $0.box?.assistantID == computer.id }), look != "none", computer.control == .assistant else { return answer }
    let name = look == "tree" ? "computer_tree" : "computer_screenshot"
    var seen = try await perform(name, [:], task: id, computer: computer, browser: browser, pictureStep: nil)
    computer.steps.ran(name, [:], into: &seen)
    return answer.merging(seen) { kept, _ in kept }
  }

  /// Opens the ask: the task's timeline and the activity list say it, and the person takes control
  /// from the computer's view. Screen steps wait until hand-back.
  func openAsk(_ computer: Computer, task id: String, reason: String, browser: BrowserModel, checks: Set<String> = []) {
    let line = "Serein asks you to take control of its computer: " + String(reason.prefix(200))
    if computer.ask == nil { RelayOrchestrator.shared?.note(line, .auto) }
    computer.ask = PersonAsk(task: id, reason: String(reason.prefix(200)), opened: Date(), checks: checks.union(computer.ask?.checks ?? []))
    browser.agentTabs.note(AgentStep(tool: "ask_person", label: line), task: id)
  }
  /// Hand-back or the person's dismiss closes the ask; the task hears it in its chat.
  func closeAsk(_ computer: Computer, handedBack: Bool, browser: BrowserModel?) {
    guard let ask = computer.ask else { return }
    computer.ask = nil
    computer.steps.hadChecks.formUnion(ask.checks)
    guard let browser, let thread = browser.threadID(forTask: ask.task), let agent = browser.intelligenceAgent else { return }
    let text = handedBack
      ? "I did the step on Serein's computer and handed it back. Look at it again before you act, then carry on with the task."
      : "I closed the ask on Serein's computer without doing the step. Carry on with the rest of the task another way."
    Task { if let refused = await agent.flow.deliver(thread, text: text) { browser.notice = refused } }
  }

  /// The person's value into the box field its card was raised for (DriverScreen.fill). The value
  /// is only in that one request line; FilledValues redacts it everywhere else, as for the web.
  func secureFill(_ box: BoxField, _ values: [String: String]) async -> SecureCard.Result {
    guard let computer = computers[box.assistantID], computer.state == .running, computer.control == .assistant,
      computer.holder == box.task, values.count == 1, let value = values.values.first,
      let driver = try? await driverScreen(computer), driver.connectionID == box.connectionID
    else { return .pageChanged }
    // Known to the redactor before any read can show it.
    FilledValues.shared.add(value, task: box.task)
    FilledValues.shared.filled(box: computer.id, task: box.task)
    return (try? await driver.fill(box.target, stop: box.stop, value)) == true ? .filled : .pageChanged
  }

  /// Cua Driver's screen for this computer, opened on the step that needs it (its link and
  /// handshake) and again after its link ended. A model's screen step never runs on the helper
  /// where the computer carries the driver: one that does not open in a few tries (about ten
  /// seconds) refuses the step with the way on, and the next step tries again. A locked computer
  /// (Docker, E2B: its commands run as `shell`, so the driver's floor is the only judge of its
  /// screen) without the driver refuses too. nil only where the place's own commands reach the
  /// screen anyway (Daytona, the built-in computer, the person's desktop or machine, the virtual Mac).
  func driverScreen(_ computer: Computer) async throws -> DriverScreen? {
    guard computer.carriesDriver, let machine = computer.machine, let command = machine.driverCommand else {
      if computer.carriesDriver { throw SereinError.invalid(Self.driverDown) }
      if [.docker, .e2b].contains(computer.place) { throw SereinError.invalid(Self.noDriver(computer.place)) }
      return nil
    }
    let began = Date()
    for pause in [0, 1, 2] as [UInt64] where Date().timeIntervalSince(began) < 10 {
      if let driver = computer.driver, driver.isOpen { return driver }
      computer.driver = nil
      try await Task.sleep(nanoseconds: pause * 1_000_000_000)
      do {
        return try await openDriver(computer, machine, command)
      } catch is CancellationError {
        throw DriverChannel.closed
      } catch {
        computer.screenPath = .driverFailed(error.localizedDescription, at: Date())
      }
    }
    throw SereinError.invalid(Self.driverDown)
  }
  static let driverDown =
    "Cua Driver, which every screen step on Serein's computer goes through, did not start just now. Try the screen step again in a moment. Meanwhile computer_run runs commands there, computer_open_url opens pages, and computer_ask_person hands a screen step to the person."
  static func noDriver(_ place: ComputerPlace) -> String {
    let fix = place == .e2b
      ? "the person builds the E2B template again from the folder Settings › Serein's computer › Show Recipe opens, then Resets it"
      : "the person rebuilds it in Settings › Serein's computer"
    return "Serein's computer here has no Cua Driver, which its screen steps need; to get it, \(fix). Meanwhile computer_run runs commands there, computer_open_url opens pages, and computer_ask_person hands a screen step to the person."
  }
  /// One open of the driver's link and handshake; steps that arrive meanwhile wait on the same one.
  /// CancellationError when the links were closed while it opened (a reset, a pause).
  private func openDriver(_ computer: Computer, _ machine: ComputerBackend, _ command: [String]) async throws -> DriverScreen {
    if let shared = computer.driverOpening {
      do { return try await shared.value } catch where shared.isCancelled { throw CancellationError() }
    }
    let box = computer.id
    let opening = Task { @MainActor () async throws -> DriverScreen in
      let channel = try await DriverChannel.open(machine, command: command)
      let screen = DriverScreen(channel: channel) { try await DriverChannel.open(machine, command: command) }
      screen.saw = { [weak computer] read in computer?.steps.saw(read) }
      screen.values = { FilledValues.shared.shows(box: box) }
      channel.setEndHandler { [weak computer, weak screen] in
        Task { @MainActor in
          guard let computer, let screen, computer.driver === screen else { return }
          computer.driver = nil
        }
      }
      return screen
    }
    computer.driverOpening = opening
    defer { if computer.driverOpening == opening { computer.driverOpening = nil } }
    let screen: DriverScreen
    do { screen = try await opening.value } catch where opening.isCancelled { throw CancellationError() }
    // This one belongs to no computer now.
    guard !opening.isCancelled else {
      screen.close()
      throw CancellationError()
    }
    guard screen.isOpen else { throw DriverChannel.closed }
    computer.driver = screen
    computer.screenPath = .driver
    // Chromium shows its tree only when the session's accessibility is on as it starts (the
    // helper's commands run on that session's bus).
    _ = try? await computer.helper.call("run", ["command": Self.accessibilityOn], timeout: 20)
    // FilledValues lives only while Serein runs, and the box outlives it: what Serein filled before
    // it last started may still be on the clipboard. Owed to every task until a clear works.
    FilledValues.shared.filled(box: computer.id, task: "")
    if (try? await computer.helper.call("run", ["command": Self.clearClipboard], timeout: 20))?["code"] as? Int == 0 {
      FilledValues.shared.clipboardCleared(box: computer.id)
    }
    return screen
  }
  /// computer_run's helper (`helper.py --shell`) as the computer's `shell` user, which the display
  /// and both buses refuse, opened with the other links since it also serves the desktop's
  /// terminals; the screen helper where the backend has no such user. A start that found other
  /// pins never gets here, so an image without the user is refused.
  func shellLink(_ computer: Computer) async throws -> HelperChannel {
    if let shell = computer.shell, shell.isOpen { return shell }
    // One open at a time per computer: two links would each take the terminals' socket
    // (helper.py terminal_serve), and closing either could leave it naming the closed one.
    if let opening = Self.shellOpening[computer.id] { return try await opening.value }
    let opening = Task<HelperChannel, Error> {
      guard let machine = computer.machine else { return computer.helper }
      let shell = HelperChannel()
      guard let stream = try await machine.openShell(machine.helperCommand + ["--shell"], onStdout: shell.sink, onEnd: shell.ender)
      else { return computer.helper }
      shell.attach(stream)
      computer.shell = shell
      return shell
    }
    Self.shellOpening[computer.id] = opening
    defer { Self.shellOpening[computer.id] = nil }
    return try await opening.value
  }
  private static var shellOpening: [String: Task<HelperChannel, Error>] = [:]
  /// A reset empties the `shell` user's files first, as that user: the desktop's user may not
  /// open what a command made private.
  static let shellWipe = "chmod -R u+rwX ~ 2>/dev/null; find -P ~ -mindepth 1 -delete"
  /// A checkpoint goes back as the desktop's user with each file's own mode (so `work` stays the
  /// `shell` user's group's) but no setuid or setgid bit anywhere, never through a `work` that is
  /// a link (exit 3) and never with an old display key; `work` itself is 2770 again after. Where
  /// the computer has that user, helper.py --scrub then strips the bits from folders the walk
  /// could not enter too, and leaves inert what the old home would have the desktop run.
  static let restoreCommand = ["/bin/sh", "-c",
    "umask 002; [ ! -L /home/serein/work ] || exit 3; tar -C /home/serein --exclude=./.Xauthority -xpf - || exit; "
      + "if [ -L /home/serein/work ]; then rm -f /home/serein/work; exit 3; fi; "
      + "find /home/serein -xdev -perm /6000 -exec chmod ug-s {} + 2>/dev/null; [ ! -d /home/serein/work ] || chmod 2770 /home/serein/work; "
      + "! id shell >/dev/null 2>&1 || exec python3 -I /opt/serein/helper.py --scrub"]
  /// The proxy shim's port (127.0.0.1:3128, listening) is held by the desktop's user, so nothing
  /// a command started while no shim ran gets the browser's traffic.
  private static let proxyPortCheck = #"for i in $(seq 100); do u=$(awk '$2=="0100007F:0C38" && $4=="0A" {print $8}' /proc/net/tcp); "#
    + #"[ -n "$u" ] && break; sleep 0.1; done; [ "$u" = "$(id -u)" ]"#
  func proveProxyPort(_ computer: Computer) async throws {
    if let answer = try? await computer.helper.call("run", ["command": Self.proxyPortCheck], timeout: 30),
      answer["code"] as? Int == 0 { return }
    computer.proxy?.close()
    computer.proxy = nil
    throw SereinError.invalid("Something inside the computer holds its proxy port. Reset it in Settings › Serein's computer.")
  }
  /// What a start checks in `place`: Cua Driver too where the seed carries it and the boot step
  /// installs it (the built-in computer), or the image was built with it (Docker).
  static func pinnedFiles(_ machine: ComputerBackend, _ place: ComputerPlace) -> [ComputerPins.File] {
    let box = (machine as? DockerComputer)?.driverArch()
    let withDriver: Bool = (machine as? VirtualMachineComputer)?.carriesDriver ?? (box != nil)
    return ComputerPins.files(for: place, withDriver: withDriver, arch: box ?? .arm64)
  }

  /// A tree that shows a CAPTCHA the person has not had yet leads with the ask and opens it
  /// (FreshRead.botChecks, every depth); a tree of every window, uncut, that shows none closes the
  /// ask it opened and says so, so steps go on. One the person had stays theirs while uncut reads
  /// still show it (StepGuard.saw): a solved check left on the page stops nothing.
  func botCheckLead(_ tree: [String: Any], task id: String, computer: Computer, browser: BrowserModel) -> String {
    let checks = Set(tree["botChecks"] as? [String] ?? []).subtracting(computer.steps.hadChecks)
    guard !checks.isEmpty else {
      guard tree["whole"] as? Bool == true, tree["botChecks"] as? [String] == [], computer.ask?.reason == Self.botCheckReason else { return "" }
      computer.ask = nil
      return "The check that a person is there is gone from the screen, so Serein closed its ask to the person: screen steps run again.\n"
    }
    openAsk(computer, task: id, reason: Self.botCheckReason, browser: browser, checks: checks)
    return BoxFloor.asked(.personOnly(.captcha)).text + "\n"
  }
  static let botCheckReason = "A check that a person is there."
  /// Gives up X's clipboard and selection, so nothing copied before is pasted.
  static let clearClipboard =
    "python3 -c \"import ctypes as c;x=c.CDLL('libX11.so.6');x.XOpenDisplay.restype=c.c_void_p;d=c.c_void_p(x.XOpenDisplay(None));assert d.value;[x.XSetSelectionOwner(d,x.XInternAtom(d,s,0),0,0) for s in (b'CLIPBOARD',b'PRIMARY')];x.XSync(d,0)\""
  static let accessibilityOn = ["IsEnabled", "ScreenReaderEnabled"].map {
    "dbus-send --session --dest=org.a11y.Bus /org/a11y/bus org.freedesktop.DBus.Properties.Set string:org.a11y.Status string:\($0) variant:boolean:true"
  }.joined(separator: "; ")

  /// The built image's arch when its label says it carries this copy's Cua Driver for it. An
  /// image without the driver is not stale: it starts on the helper.
  static func driverArch(image: [String: Any], labels: [String: Any]?) -> CuaDriverRelease.Arch? {
    let arch = CuaDriverRelease.Arch(engine: image["Architecture"] as? String ?? "")
    let driver = labels?[ComputerPins.driverLabelKey] as? String
    return arch.flatMap { driver == $0.binarySHA256 ? $0 : nil }
  }
  /// The labels a build gives the image: Cua Driver's pin when its context carries the driver.
  nonisolated static func imageLabels(_ arch: CuaDriverRelease.Arch?) -> [String: String] {
    var labels = [ComputerPolicy.label: "image"]
    if let arch, driverShipped(arch) { labels[ComputerPins.driverLabelKey] = arch.binarySHA256 }
    return labels
  }

  /// The recipe's own files as the Dockerfile copies them: the image's build context, and the
  /// folder a hosted template is built from (recipeFolder), each with Cua Driver's added.
  nonisolated static func recipeFiles() throws -> [(String, Data, Int)] {
    [
      ("Dockerfile", try shippedFile("Dockerfile", nil), 0o644),
      ("serein-helper.py", try shippedFile("serein-helper", "py"), 0o755),
      ("serein-start.sh", try shippedFile("serein-start", "sh"), 0o755),
    ]
  }
  /// Cua Driver's files for a Docker image of `arch`, as the Dockerfile copies them, each checked
  /// against its pin; none when this copy ships no driver for it. About 56 MB: off the main actor.
  nonisolated static func boxDriverFiles(_ arch: CuaDriverRelease.Arch) throws -> [(String, Data, Int)] {
    guard driverShipped(arch) else { return [] }
    return [
      ("cua-driver", try shippedFile(arch.resource, nil), 0o755),
      ("cua-driver-license.txt", try shippedFile(CuaDriverRelease.licenseResource, "txt"), 0o644),
      ("cua-driver-notices.md", try shippedFile(CuaDriverRelease.noticesResource, "md"), 0o644),
      ("cua-driver-crates.md", try shippedFile(CuaDriverRelease.crateNoticesResource, "md"), 0o644),
    ]
  }
  nonisolated static func driverShipped(_ arch: CuaDriverRelease.Arch) -> Bool {
    Bundle.assets.url(forResource: arch.resource, withExtension: nil, subdirectory: "Computer") != nil
  }
  /// The engine's architecture (`GET /version`), for the image and its driver.
  nonisolated static func engineArch(_ engine: DockerEngine) -> CuaDriverRelease.Arch? {
    guard let reply = try? engine.request("GET", "/version", timeout: 10), reply.ok else { return nil }
    return CuaDriverRelease.Arch(engine: reply.dictionary["Arch"] as? String ?? "")
  }
}
