#if DEBUG
import Foundation
import SereinCore

/// Who holds a computer's screen, when the person's hold ends by itself, and the steps only the
/// person may do (ComputerHold.swift).
extension AssistantCoreChecks {
  static func computerHold(_ check: Check) throws {
    typealias H = ComputerHold
    try check(H.next(.assistant, .takeOver(stepInFlight: false)) == .person, "Take control with no step in flight passes the hold at once")
    try check(H.next(.assistant, .takeOver(stepInFlight: true)) == .pending, "Take control during a step waits for it to end")
    try check(H.next(.pending, .stepEnded) == .person, "The hold passes when the step in flight ends")
    try check(H.next(.assistant, .stepEnded) == .assistant && H.next(.person, .stepEnded) == .person,
      "A step ending moves nothing else")
    try check(H.next(.person, .takeOver(stepInFlight: false)) == .person, "Take control twice is one hold")
    try check(H.next(.person, .handBack) == .assistant && H.next(.pending, .handBack) == .assistant,
      "Hand back returns the computer from a hold or a waiting take-over")
    try check(H.next(.person, .lapsed) == .assistant, "A hold that ran out goes back to the assistant")
    try check(H.next(.pending, .lapsed) == .pending && H.next(.assistant, .lapsed) == .assistant,
      "Only a hold the person has can run out")

    let input = Date(timeIntervalSince1970: 1_000_000)
    try check(H.afterLastInput == 300 && H.afterViewClosed == 120, "The hold lasts 5 minutes past input and 2 past the view")
    try check(H.lapse(lastInput: input, viewClosedAt: nil, now: input.addingTimeInterval(299)) == nil,
      "An open view with input under 5 minutes ago keeps the hold")
    try check(H.lapse(lastInput: input, viewClosedAt: nil, now: input.addingTimeInterval(300)) == .idle,
      "5 minutes with no input end the hold")
    let closed = input.addingTimeInterval(60)
    try check(H.lapse(lastInput: input, viewClosedAt: closed, now: closed.addingTimeInterval(119)) == nil,
      "A closed view keeps the hold under 2 minutes")
    try check(H.lapse(lastInput: input, viewClosedAt: closed, now: closed.addingTimeInterval(120)) == .closed,
      "2 minutes after the view closed end the hold")
    try check(H.Lapse.idle.line != H.Lapse.closed.line, "The chat says why the hold ended")

    try check(H.personOnly(kind: "type", role: "AXSecureTextField", label: "Name") == .password, "A secret field is the person's")
    try check(H.personOnly(kind: "click", role: "AXCheckBox", label: "I'm not a robot") == .captcha
      && H.personOnly(kind: "click", role: "AXButton", label: "reCAPTCHA") == .captcha
      && H.personOnly(kind: "click", role: "AXButton", label: "Verify you are human") == .captcha,
      "A CAPTCHA is the person's whatever the step")
    try check(H.personOnly(kind: "click", role: "AXButton", label: "Sign in with a passkey") == .passkey,
      "A passkey is the person's")
    try check(H.personOnly(kind: "type", role: "AXTextField", label: "Card number") == .payment
      && H.personOnly(kind: "type", role: "AXTextField", label: "CVC") == .payment
      && H.personOnly(kind: "type", role: "AXTextField", label: "Expiration date") == .payment,
      "Card details are the person's to type")
    try check(H.personOnly(kind: "type", role: "AXTextField", label: "Verification code") == .code
      && H.personOnly(kind: "type", role: "AXTextField", label: "Enter your 2FA code") == .code
      && H.personOnly(kind: "type", role: "AXTextField", label: "Recovery code") == .code,
      "Sign-in codes are the person's to type")
    try check(H.personOnly(kind: "type", role: "AXTextField", label: "PIN") == .password
      && H.personOnly(kind: "type", role: "AXTextField", label: "Passcode") == .password,
      "A password or PIN is the person's to type")
    try check(H.personOnly(kind: "click", role: "AXButton", label: "Card number") == nil
      && H.personOnly(kind: "click", role: "AXButton", label: "Add payment card") == nil,
      "Clicking near card fields is not typing them")
    try check(H.personOnly(kind: "type", role: "AXTextField", label: "Subject") == nil
      && H.personOnly(kind: "type", role: "AXTextField", label: "Shipping address") == nil
      && H.personOnly(kind: "type", role: nil, label: nil) == nil
      && H.personOnly(kind: "type", role: "AXTextField", label: "Spinning class") == nil,
      "Ordinary fields stay the assistant's")
    try check(H.PersonOnly.allCases.allSatisfy { $0.line.hasPrefix("This step is yours: ") },
      "Each person-only step says so in the same plain words")
  }
}
#endif
