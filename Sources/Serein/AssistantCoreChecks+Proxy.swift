#if DEBUG
import Foundation
import SereinCore

/// The computer proxy's server-name check (TLSClientHello): real ClientHello records captured
/// from a TLS client, for example.com, other.site and no name.
extension AssistantCoreChecks {
  static let helloExample = "FgMBAgABAAH8AwPCHAgLg8rYUSURlU1ATuFA16WEF9AUK4wMGjNCtIGUKiA1MAdHl5mBtiyoqkfu4XzReslk8gIYR2w+R63sTaodowAkEwITAxMBwCzAMMArwC/MqcyowCTAKMAjwCcAnwCeAGsAZwD/AQABjwAAABAADgAAC0V4YW1wbGUuQ09NAAsABAMAAQIACgAWABQAHQAXAB4AGQAYAQABAQECAQMBBAAjAAAAFgAAABcAAAANACoAKAQDBQMGAwgHCAgICQgKCAsIBAgFCAYEAQUBBgEDAwMBAwIEAgUCBgIAKwAFBAMEAwMALQACAQEAMwAmACQAHQAgzJ4hsFkrqBuUl2tnFCrrWk8xZrfdGKrvjB1wl5A3Rg0AFQDiAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
  static let helloOther = "FgMBAgABAAH8AwPU2PxzsQlCQ/BmFR9RbGq8be4WF6JdApOgIHawjF2Y/CBklRaLWlI/oanBsdV6lG+4VmTZCFi7fRwn0ya/CldCiwAkEwITAxMBwCzAMMArwC/MqcyowCTAKMAjwCcAnwCeAGsAZwD/AQABjwAAAA8ADQAACm90aGVyLnNpdGUACwAEAwABAgAKABYAFAAdABcAHgAZABgBAAEBAQIBAwEEACMAAAAWAAAAFwAAAA0AKgAoBAMFAwYDCAcICAgJCAoICwgECAUIBgQBBQEGAQMDAwEDAgQCBQIGAgArAAUEAwQDAwAtAAIBAQAzACYAJAAdACDuYAv5rrz1s+CthIE/eRzb00z53qo/c64THxzgZ/EgGQAVAOMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
  static let helloNoName = "FgMBAgABAAH8AwN5smDaPEA779KYlyqdK37Uz8W1ZKTHrthPl7smu1ljqiCLbOuot+7Y+cMba62JFJ/K/6AJbxgyqZBmdOB06JhDVQAkEwITAxMBwCzAMMArwC/MqcyowCTAKMAjwCcAnwCeAGsAZwD/AQABjwALAAQDAAECAAoAFgAUAB0AFwAeABkAGAEAAQEBAgEDAQQAIwAAABYAAAAXAAAADQAqACgEAwUDBgMIBwgICAkICggLCAQIBQgGBAEFAQYBAwMDAQMCBAIFAgYCACsABQQDBAMDAC0AAgEBADMAJgAkAB0AIEYJs3rMo2ow/KDc8EcxPTi7oO5D23NX7DNuvFT6poVwABUA9gAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="

  static func proxyServerName(_ check: Check) throws {
    guard let ex = Data(base64Encoded: helloExample), let other = Data(base64Encoded: helloOther),
      let none = Data(base64Encoded: helloNoName)
    else {
      try check(false, "The sample records decode")
      return
    }
    typealias T = TLSClientHello
    try check(T.read(ex) == .name("example.com"), "A real ClientHello gives its server name, lowercased")
    try check(T.refusal(T.read(ex), host: "example.com") == nil, "The matching host may go on")
    try check(T.refusal(T.read(ex), host: "EXAMPLE.com.") == nil, "Case and a closing dot do not matter")
    try check(T.refusal(T.read(other), host: "example.com") != nil, "Another site behind an allowed host is refused")
    try check(T.read(none) == .noName, "A ClientHello without a name reads as no name")
    try check(T.refusal(.noName, host: "example.com") != nil, "No name for a named host is refused")
    try check(T.refusal(.noName, host: "93.184.216.34") == nil, "No name for an IPv4 host may go on")
    try check(T.refusal(.noName, host: "[2606:2800:220:1::1]") == nil, "No name for an IPv6 host may go on")
    try check(T.read(ex.prefix(3)) == .needMore(count: 5), "Three bytes need more")
    try check(T.read(ex.prefix(40)) == .needMore(count: ex.count), "A partial record asks for the whole record")
    try check(T.read(Data("GET / HTTP/1.1\r\n\r\n".utf8)) == .notTLS, "Plain text is not TLS")
    try check(T.refusal(.notTLS, host: "example.com") != nil, "A tunnel that is not TLS is refused")
    var long = [UInt8](ex)
    long[3] = 0xFF
    long[4] = 0xFF
    try check(T.read(Data(long)) == .notTLS, "A record longer than 16 KiB is refused")
    var cut = [UInt8](ex)
    cut[6] = 0x7F
    try check(T.read(Data(cut)) == .notTLS, "A ClientHello longer than its record is refused")
    for index in stride(from: 5, to: ex.count, by: 7) {
      var flipped = [UInt8](ex)
      flipped[index] ^= 0xA5
      _ = T.read(Data(flipped))
    }
    try check(true, "Flipped bytes never crash the parser")

    // Built records: every extension is read, and Encrypted Client Hello is refused.
    let groups: [UInt8] = [0, 2, 0, 0x1D]
    let ech: [UInt8] = [0, 1, 2, 3]
    try check(T.read(clientHello([(0, serverNameData("example.com"))])) == .name("example.com"), "A built ClientHello gives its name")
    try check(
      T.read(clientHello([(0x0A, groups), (0, serverNameData("example.com"))])) == .name("example.com"),
      "A name after other extensions is read")
    let echAfter = T.read(clientHello([(0, serverNameData("example.com")), (T.encryptedHelloKind, ech)]))
    try check(echAfter == .encryptedHello, "Encrypted Client Hello after the name is found")
    try check(T.refusal(echAfter, host: "example.com") != nil, "Encrypted Client Hello is refused for the matching host")
    let echFirst = T.read(clientHello([(T.encryptedHelloKind, ech), (0, serverNameData("example.com"))]))
    try check(echFirst == .encryptedHello, "Encrypted Client Hello before the name is found")
    try check(T.refusal(.encryptedHello, host: "93.184.216.34") != nil, "Encrypted Client Hello is refused for an IP address too")
    let twice = T.read(clientHello([(0, serverNameData("example.com")), (0, serverNameData("other.site"))]))
    try check(twice == .notTLS, "Two server names are refused")
    try check(T.read(clientHello([(0x0A, groups)])) == .noName, "A built ClientHello with no name reads as no name")
  }

  /// One TLS record with a ClientHello that holds `extensions` (kind, data) in order: TLS 1.2,
  /// a zero random, no session, one cipher suite and no compression.
  static func clientHello(_ extensions: [(Int, [UInt8])]) -> Data {
    var list: [UInt8] = []
    for (kind, data) in extensions {
      let head: [UInt8] = [UInt8(kind >> 8), UInt8(kind & 0xFF), UInt8(data.count >> 8), UInt8(data.count & 0xFF)]
      list.append(contentsOf: head)
      list.append(contentsOf: data)
    }
    var body: [UInt8] = [0x03, 0x03]
    body.append(contentsOf: [UInt8](repeating: 0, count: 32))
    body.append(contentsOf: [0, 0, 2, 0x13, 0x01, 1, 0])
    body.append(contentsOf: [UInt8(list.count >> 8), UInt8(list.count & 0xFF)])
    body.append(contentsOf: list)
    var handshake: [UInt8] = [0x01, UInt8(body.count >> 16), UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)]
    handshake.append(contentsOf: body)
    var record: [UInt8] = [0x16, 0x03, 0x01, UInt8(handshake.count >> 8), UInt8(handshake.count & 0xFF)]
    record.append(contentsOf: handshake)
    return Data(record)
  }
  /// A server_name extension's data for one host name.
  static func serverNameData(_ host: String) -> [UInt8] {
    let name: [UInt8] = Array(host.utf8)
    var entry: [UInt8] = [0, UInt8(name.count >> 8), UInt8(name.count & 0xFF)]
    entry.append(contentsOf: name)
    var data: [UInt8] = [UInt8(entry.count >> 8), UInt8(entry.count & 0xFF)]
    data.append(contentsOf: entry)
    return data
  }
}
#endif
