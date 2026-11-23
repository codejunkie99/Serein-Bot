import Foundation

extension Bundle {
  static var assets: Bundle {
    if let resources = Bundle.main.resourceURL,
      let bundled = Bundle(url: resources.appendingPathComponent("Serein_Serein.bundle"))
    {
      return bundled
    }
    return .module
  }
}
