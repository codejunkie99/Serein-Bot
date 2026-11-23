import Foundation

/// The native conversation that learns what to call the person, chooses the AI app and model,
/// then asks what help the person wants (kept as their note, never here). This records choices,
/// never credentials, a running job or permission to replay a job.
public struct SereinChatSetupState: Codable, Equatable, Sendable {
  public enum Phase: String, Codable, Sendable {
    /// `about`: the AI app and model are chosen; one last question asks what help is wanted.
    case computer, name, harness, connecting, model, about, complete, skipped
  }

  public private(set) var phase: Phase = .name
  /// The assistant's chosen name from setups before the person's name was asked. Not set now.
  public private(set) var assistantName: String?
  /// What the person asked to be called (nil: not asked yet, or they would rather not say).
  public private(set) var personName: String?
  public private(set) var selectedHarness: HarnessDriver?
  /// An empty string is the selected harness's default model; nil means no model was chosen.
  public private(set) var selectedModel: String?
  public private(set) var threadID: String?
  /// An account was chosen and then undone (back, or a connection that stopped): the account
  /// question comes again without its greeting.
  public private(set) var accountChosenBefore = false

  public init() {}

  /// No check-in or brief while setup is unfinished: nobody has chosen an AI app or said what they
  /// want, so nothing may read their calendar or use their AI usage yet. “Not now” is browsing, not
  /// a yes. An install set up before this chat existed has no record here and isn't held
  /// (`firstRunFinished`).
  public func holdsCheckIns(firstRunFinished: Bool) -> Bool {
    guard phase != .complete else { return false }
    return threadID != nil || phase == .skipped || !firstRunFinished
  }

  /// Bind the question once. Another chat cannot take over an unanswered question or a job's
  /// callbacks; moving setup to another chat requires the explicit restart action.
  @discardableResult public mutating func begin(in thread: String, needsComputer: Bool = false) -> Bool {
    guard Self.validThread(thread), phase != .complete, phase != .skipped,
      threadID == nil || threadID == thread else { return false }
    if threadID == nil, phase == .name, needsComputer { phase = .computer }
    threadID = thread
    return true
  }

  /// The app's verified Mac preparation finishes before questions about the person or AI app.
  @discardableResult public mutating func computerReady(in thread: String) -> Bool {
    guard owns(thread), phase == .computer else { return false }
    phase = .name
    return true
  }

  /// The person's own name, or nil when they would rather not say. The assistant keeps its name.
  @discardableResult public mutating func selectPersonName(_ name: String?, in thread: String) -> Bool {
    let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard owns(thread), phase == .name, clean.map(Self.validName) ?? true else { return false }
    personName = clean
    phase = .harness
    return true
  }

  @discardableResult public mutating func selectHarness(
    _ driver: HarnessDriver, in thread: String, needsConnection: Bool
  ) -> Bool {
    guard owns(thread), phase == .harness else { return false }
    selectedHarness = driver
    selectedModel = nil
    phase = needsConnection ? .connecting : .model
    return true
  }

  /// Only the connection belonging to this question can advance it. A late success from a
  /// different driver, a cancelled connection or a previous chat is ignored.
  @discardableResult public mutating func connected(_ driver: HarnessDriver, in thread: String) -> Bool {
    guard owns(thread), phase == .connecting, selectedHarness == driver else { return false }
    phase = .model
    return true
  }

  /// The host calls this only after validating the current catalog and applying the native
  /// route choice, including any required cost-change confirmation. The AI app is then ready;
  /// what help the person wants is asked last (`answerAbout`).
  @discardableResult public mutating func complete(model: String, in thread: String) -> Bool {
    guard owns(thread), phase == .model, selectedHarness != nil, Self.validModel(model) else { return false }
    selectedModel = model
    phase = .about
    return true
  }

  /// The last question is answered, or passed over: setup is complete. The answer itself is the
  /// person's note, kept by the host where notes live.
  @discardableResult public mutating func answerAbout(in thread: String) -> Bool {
    guard owns(thread), phase == .about else { return false }
    phase = .complete
    return true
  }

  @discardableResult public mutating func back(in thread: String) -> Bool {
    guard owns(thread), phase == .connecting || phase == .model else { return false }
    resetChoice()
    return true
  }

  /// Loading a saved connection never restarts an install or sign-in. The person chooses again.
  @discardableResult public mutating func connectionInterrupted(in thread: String) -> Bool {
    guard owns(thread), phase == .connecting else { return false }
    resetChoice()
    return true
  }

  /// Skipping remains distinct from a confirmed model choice and grants no permissions. Once the
  /// model is chosen there is nothing to skip: the last question is passed over instead.
  @discardableResult public mutating func skip(in thread: String) -> Bool {
    guard owns(thread), phase != .about, phase != .complete, phase != .skipped else { return false }
    selectedHarness = nil
    selectedModel = nil
    phase = .skipped
    return true
  }

  @discardableResult public mutating func restart(in thread: String, needsComputer: Bool = false) -> Bool {
    guard Self.validThread(thread) else { return false }
    self = Self()
    threadID = thread
    if needsComputer { phase = .computer }
    return true
  }

  private func owns(_ thread: String) -> Bool {
    Self.validThread(thread) && threadID == thread
  }
  private mutating func resetChoice() {
    phase = .harness
    selectedHarness = nil
    selectedModel = nil
    accountChosenBefore = true
  }
  private static func validThread(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  private static func validModel(_ value: String) -> Bool {
    value == value.trimmingCharacters(in: .whitespacesAndNewlines)
      && value.rangeOfCharacter(from: .controlCharacters) == nil
  }
  /// What to call the person from the full name on their Mac account ("Ziwen Xu" → "Ziwen"), so
  /// setup does not have to ask. Nil for an account name that is not a person's name: one word in
  /// lower case (a user name such as "ziwenxu"), digits, or nothing.
  public static func likelyName(fullName: String) -> String? {
    let words = fullName.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
    guard let first = words.first, first.count <= 30,
      first.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" }), first.first?.isLetter == true
    else { return nil }
    // A single lower-case word is a login name, not what the person goes by.
    if words.count == 1, first == first.lowercased() { return nil }
    return validName(first) ? first : nil
  }

  private static func validName(_ value: String) -> Bool {
    !value.isEmpty && value.count <= RelayPersona.nameBudget
      && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
      && value.rangeOfCharacter(from: .controlCharacters) == nil
  }

  private enum CodingKeys: String, CodingKey {
    case phase, assistantName, personName, selectedHarness, selectedModel, threadID, accountChosenBefore
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    phase = try values.decode(Phase.self, forKey: .phase)
    assistantName = try values.decodeIfPresent(String.self, forKey: .assistantName)
    personName = try values.decodeIfPresent(String.self, forKey: .personName)
    // An app Serein no longer has reads as none: a setup still connecting
    // to it or choosing its model asks for the app again, and a later one keeps its place.
    let savedHarness = try values.decodeIfPresent(String.self, forKey: .selectedHarness)
    selectedHarness = savedHarness.flatMap(HarnessDriver.init(rawValue:))
    let dropped = savedHarness != nil && selectedHarness == nil
    selectedModel = try values.decodeIfPresent(String.self, forKey: .selectedModel)
    if dropped, phase == .connecting || phase == .model {
      phase = .harness
      selectedModel = nil
    }
    threadID = try values.decodeIfPresent(String.self, forKey: .threadID)
    accountChosenBefore = try values.decodeIfPresent(Bool.self, forKey: .accountChosenBefore) ?? false
    let bound = threadID.map(Self.validThread) == true
    let valid: Bool
    switch phase {
    case .computer:
      valid = bound && assistantName == nil && personName == nil
        && selectedHarness == nil && selectedModel == nil
    case .name:
      valid = (threadID == nil || bound) && assistantName == nil && personName == nil
        && selectedHarness == nil && selectedModel == nil
    case .harness:
      valid = (threadID == nil || bound) && selectedHarness == nil && selectedModel == nil
    case .connecting, .model:
      valid = bound && selectedHarness != nil && selectedModel == nil
    case .about, .complete:
      valid = bound && (selectedHarness != nil || dropped) && selectedModel.map(Self.validModel) == true
    case .skipped:
      valid = bound && selectedHarness == nil && selectedModel == nil
    }
    guard valid, assistantName == nil || assistantName.map(Self.validName) == true,
      personName == nil || personName.map(Self.validName) == true else {
      throw DecodingError.dataCorruptedError(
        forKey: .phase, in: values, debugDescription: "The saved chat setup has inconsistent choices.")
    }
  }
}
