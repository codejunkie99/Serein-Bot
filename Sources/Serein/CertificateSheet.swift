import SereinCore
import Security
import SwiftUI

/// What the person needs to judge a certificate that failed: who it names, who vouches for it,
/// when it is valid and its fingerprint. Read from the chain the server presented.
struct CertificateSummary {
  struct Entry: Identifiable {
    var id: Int
    var subject: String
    var fingerprint: String
  }
  var host: String
  var reason: String?
  var subject: String
  var issuer: String
  var notBefore: Date?
  var notAfter: Date?
  var fingerprint: String
  var chain: [Entry]

  init?(chain certificates: [SecCertificate], host: String, reason: String?) {
    guard let leaf = certificates.first else { return nil }
    self.host = host
    self.reason = reason
    subject = SecCertificateCopySubjectSummary(leaf) as String? ?? "Unnamed certificate"
    issuer =
      certificates.count > 1
      ? (SecCertificateCopySubjectSummary(certificates[1]) as String? ?? "Unknown")
      : "No issuer was sent (self-signed or incomplete chain)"
    fingerprint = Self.format(TrustExceptions.fingerprint(SecCertificateCopyData(leaf) as Data))
    chain = certificates.enumerated().map { index, certificate in
      Entry(
        id: index, subject: SecCertificateCopySubjectSummary(certificate) as String? ?? "Unnamed",
        fingerprint: Self.format(TrustExceptions.fingerprint(SecCertificateCopyData(certificate) as Data)))
    }
    let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
    let values = SecCertificateCopyValues(leaf, keys, nil) as? [String: [String: Any]]
    func date(_ oid: CFString) -> Date? {
      let value = values?[oid as String]?[kSecPropertyKeyValue as String]
      if let date = value as? Date { return date }
      if let seconds = value as? NSNumber { return Date(timeIntervalSinceReferenceDate: seconds.doubleValue) }
      return nil
    }
    notBefore = date(kSecOIDX509V1ValidityNotBefore)
    notAfter = date(kSecOIDX509V1ValidityNotAfter)
  }
  /// "AB CD EF …" in groups, easy to compare by eye.
  static func format(_ hex: String) -> String {
    stride(from: 0, to: hex.count, by: 2).map {
      let start = hex.index(hex.startIndex, offsetBy: $0)
      return String(hex[start..<hex.index(start, offsetBy: min(2, hex.count - $0))]).uppercased()
    }.joined(separator: " ")
  }
}

struct CertificateSheet: View {
  let summary: CertificateSummary
  var close: () -> Void
  @Environment(\.palette) var p
  func row(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).role(.micro)
      Text(value).role(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Certificate for \(summary.host)").role(.section)
      if let reason = summary.reason { Text(reason).role(.meta).fixedSize(horizontal: false, vertical: true) }
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          row("Issued to", summary.subject)
          row("Issued by", summary.issuer)
          if let from = summary.notBefore {
            row("Valid from", from.formatted(date: .abbreviated, time: .shortened))
          }
          if let to = summary.notAfter {
            row("Valid until", to.formatted(date: .abbreviated, time: .shortened))
          }
          VStack(alignment: .leading, spacing: 2) {
            Text("Fingerprint (SHA-256)").role(.micro)
            Text(summary.fingerprint).font(UIStyle.microMono).textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          if summary.chain.count > 1 {
            Text("Chain").role(.micro)
            ForEach(summary.chain) { entry in
              Text("\(entry.id + 1). \(entry.subject)").role(.body)
            }
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.frame(maxHeight: 320)
      HStack {
        Spacer()
        Button("Done", action: close).buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: UIStyle.wide(440)).background(p.panel)
  }
}
