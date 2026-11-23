#if DEBUG
import Foundation
import SereinCore
@testable import SereinEngines

/// The shell payment guard: which connections wait for the person's card (PayGuard.judge), and
/// the TLS server-name check after a tunnel opens. No socket: names resolve from a fixed table.
extension AssistantCoreChecks {
  static func enginePayGuard(_ check: Check) throws {
    let stripeIP = "198.137.150.221"
    let book = PayGuard.Book(addresses: [stripeIP: "api.stripe.com"])
    let table: [String: [String]] = [
      "api.stripe.com": [stripeIP], "example.com": ["93.184.215.14"], "registry.npmjs.org": ["104.16.1.35"],
      "198-137-150-221.nip.io": [stripeIP], "checkout.company.io": ["203.0.113.9"], "mcp.polar.sh": ["76.76.21.21"],
      "api.polar.sh": ["76.76.21.22"], "notstripe.com": ["203.0.113.10"], "internal.dev": ["10.0.0.7"],
    ]
    func judge(_ name: String) -> PayGuard.Ruling { PayGuard.judge(name: name, book: book) { table[$0] ?? [] } }

    try check(judge("api.stripe.com") == .ask(host: "api.stripe.com", dial: stripeIP, reason: .named), "A shell call to api.stripe.com asks")
    try check(judge("API.Stripe.com.") == .ask(host: "api.stripe.com", dial: stripeIP, reason: .named), "Case and a closing dot do not hide Stripe")
    try check(judge("api.polar.sh") == .ask(host: "api.polar.sh", dial: "76.76.21.22", reason: .named), "Polar's API asks")
    try check(judge("example.com") == .pass(dial: "93.184.215.14"), "example.com passes at the address the guard resolved")
    try check(judge("registry.npmjs.org") == .pass(dial: "104.16.1.35"), "The npm registry passes")
    try check(judge("checkout.company.io") == .pass(dial: "203.0.113.9"), "A name that only contains a money word passes")
    try check(judge("notstripe.com") == .pass(dial: "203.0.113.10"), "A name that only ends in a money name's letters passes")
    try check(judge("mcp.polar.sh") == .pass(dial: "76.76.21.21"), "Polar's MCP host (Grok's every turn) passes")
    try check(judge(stripeIP) == .ask(host: stripeIP, dial: stripeIP, reason: .sharesAddress(with: "api.stripe.com")),
      "Stripe's own address with no name asks, naming Stripe")
    try check(judge("1.1.1.1") == .ask(host: "1.1.1.1", dial: "1.1.1.1", reason: .byAddress), "Any other public address asks, naming the address")
    try check(judge("[2606:4700::1111]") == .ask(host: "2606:4700::1111", dial: "2606:4700::1111", reason: .byAddress), "A public IPv6 address asks")
    try check(judge("10.0.0.5") == .pass(dial: "10.0.0.5") && judge("127.0.0.1") == .pass(dial: "127.0.0.1"),
      "Private and loopback addresses pass")
    try check(judge("internal.dev") == .pass(dial: "10.0.0.7"), "A name on a private address passes")
    try check(judge("198-137-150-221.nip.io") == .pass(dial: stripeIP),
      "A name is judged by its name only, never by a shared address (PAYGUARD-REVIEW H1)")
    try check(judge("nowhere.invalid") == .unresolved, "A name with no answer is unresolved, never dialed")
    try check(Set(PayGuard.Book().domains) == Set(PayGuard.hosts) && Set(LocalExecution.paymentHosts).isSubset(of: PayGuard.hosts),
      "The guard has its own money list, holding the approval door's (PAYGUARD-REVIEW L8)")
    try check(!LocalExecution.paymentHosts.contains("polar.sh"), "Polar is listed by its API hosts only, so mcp.polar.sh stays quiet")

    guard let example = Data(base64Encoded: helloExample), let other = Data(base64Encoded: helloOther) else {
      try check(false, "The sample ClientHellos decode")
      return
    }
    // The recorded ClientHello names example.com; here example.com stands in for a money host.
    let fronting = PayGuard.Book(domains: ["example.com"])
    try check(!PayGuard.helloAllowed(TLSClientHello.read(example), opened: "harmless.io", book: fronting),
      "A money server name inside a tunnel opened for another name is refused")
    try check(PayGuard.helloAllowed(TLSClientHello.read(example), opened: "EXAMPLE.com", book: fronting),
      "A money server name inside its own tunnel goes on")
    try check(PayGuard.helloAllowed(TLSClientHello.read(other), opened: "harmless.io", book: fronting),
      "Another site's name in a harmless tunnel goes on")
    try check(PayGuard.helloAllowed(TLSClientHello.read(Data("SSH-2.0-OpenSSH\r\n".utf8)), opened: "github.com", book: fronting),
      "A tunnel that is not TLS (ssh) goes on")
    try check(PayGuard.accessDenied == Data([0x15, 0x03, 0x03, 0x00, 0x02, 0x02, 0x31]), "The refusal is a fatal access_denied alert")
  }
}
#endif
