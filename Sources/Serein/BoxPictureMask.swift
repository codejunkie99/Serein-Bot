import CoreGraphics
import Foundation
import ImageIO
import os
import SereinCore
import UniformTypeIdentifiers
import Vision

/// A picture of Serein's computer with places blacked out, so a value of the person's shown there
/// reaches neither the model nor a record (DriverScreen.masked).
enum BoxPictureMask {
  /// Chromium's frames sit up to 4 pixels right of what it paints (measured on the box: a field at
  /// 157 painted from 154, a paragraph at 34 whose text starts at 31), plus 2 for a glyph's edge.
  static let margin = 6.0
  static let readLimit = 2.0
  /// `png` (a desktop picture, `scale` desktop pixels to one of its own) with each place, given in
  /// desktop pixels, filled black with `margin` on each side. nil for bytes ScreenPicture does not
  /// pass, or that do not decode to their own header's size.
  static func blackOut(_ png: Data, _ places: [DriverCalls.Row.Frame], scale: Double) -> Data? {
    guard scale > 0, let size = ScreenPicture.size(png, rule: .upTo(DriverCalls.pictureEdge)),
      let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == size.width, image.height == size.height,
      let context = CGContext(
        data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    let whole = CGRect(x: 0, y: 0, width: size.width, height: size.height)
    context.draw(image, in: whole)
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    for place in places {
      let width = Double(place.width) / scale + 2 * margin, height = Double(place.height) / scale + 2 * margin
      // Core Graphics counts y from the bottom.
      let top = Double(place.y) / scale - margin
      context.fill(CGRect(x: Double(place.x) / scale - margin, y: Double(size.height) - top - height, width: width, height: height).intersection(whole))
    }
    let out = NSMutableData()
    guard let masked = context.makeImage(), let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, masked, nil)
    return CGImageDestinationFinalize(destination) ? out as Data : nil
  }
  /// Chromium's frames lag what it paints while a page animates (measured: three reads over 3.7 s
  /// put a bobbing card field at y 310 while a picture between them showed it 140 pixels lower), so
  /// the mask alone can miss one.
  private enum Inspection: Equatable {
    case clear(hasDigits: Bool), hideDesktopEdges(includesFooter: Bool), withhold
  }

  static func shows(_ picture: Data) async -> Bool {
    if case .clear = await inspect(picture) { return false }
    return true
  }

  /// The desktop clock and browser address can together resemble a card. If all the numeral
  /// groups are confined to desktop chrome, cover the header and any implicated bottom panel.
  /// A second read must positively identify text and find no digits anywhere in the image.
  static func screenedPNG(_ png: Data) async -> Data? {
    switch await inspect(png) {
    case .clear: return png
    case .withhold: return nil
    case .hideDesktopEdges(let includesFooter):
      guard let size = ScreenPicture.size(png, rule: .upTo(DriverCalls.pictureEdge)) else { return nil }
      let height = (size.height + 5) / 6
      let header = DriverCalls.Row.Frame(x: 0, y: 0, width: size.width, height: height)
      let footer = DriverCalls.Row.Frame(x: 0, y: size.height - height, width: size.width, height: height)
      let places = includesFooter ? [header, footer] : [header]
      guard let masked = await Task.detached(priority: .userInitiated, operation: { blackOut(png, places, scale: 1) }).value,
        await inspect(masked) == .clear(hasDigits: false), !FilledValues.shared.hasValues
      else { return nil }
      return masked
    }
  }

  private static func inspect(_ picture: Data) async -> Inspection {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .fast
    request.usesLanguageCorrection = false
    return await withCheckedContinuation { done in
      let once = OSAllocatedUnfairLock<CheckedContinuation<Inspection, Never>?>(initialState: done)
      let give = { (result: Inspection) in
        once.withLock { waiting -> CheckedContinuation<Inspection, Never>? in
          defer { waiting = nil }
          return waiting
        }?.resume(returning: result)
      }
      DispatchQueue.global(qos: .userInitiated).async { give(read(picture, request)) }
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + readLimit) {
        give(.withhold)
        request.cancel()
      }
    }
  }
  private static func read(_ picture: Data, _ request: VNRecognizeTextRequest) -> Inspection {
    guard let source = CGImageSourceCreateWithData(picture as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil, let observations = request.results,
      !observations.isEmpty
    else { return .withhold }
    var lines: [String] = []
    var numericLines = 0
    var edgesOnly = true
    var includesFooter = false
    for observation in observations {
      guard let line = observation.topCandidates(1).first?.string, !line.isEmpty else { return .withhold }
      lines.append(line)
      let digits = line.filter(\.isNumber)
      if !digits.isEmpty {
        numericLines += 1
        // Vision's normalized coordinates start at the bottom left.
        let box = observation.boundingBox
        let inFooter = box.maxY <= 1.0 / 6.0
        includesFooter = includesFooter || inFooter
        edgesOnly = edgesOnly && digits.count < 13 && box.width > 0 && box.height > 0
          && CGRect(x: 0, y: 0, width: 1, height: 1).contains(box) && (box.minY >= 5.0 / 6.0 || inFooter)
      }
    }
    guard showsText(lines) else { return .clear(hasDigits: numericLines != 0) }
    return edgesOnly && numericLines >= 2 && !FilledValues.shared.hasValues ? .hideDesktopEdges(includesFooter: includesFooter) : .withhold
  }
  static func showsText(_ lines: [String]) -> Bool {
    guard !lines.isEmpty else { return true }
    if ["\n", " ", ""].contains(where: { separator in
      let text = lines.joined(separator: separator)
      return FilledValues.shared.scrubAll(text) != text
    }) { return true }
    if FilledValues.shared.hasValues {
      let numeric = lines.compactMap { line -> (String, String)? in
        let digits = line.filter(\.isWholeNumber)
        return digits.isEmpty ? nil : (line, digits)
      }
      if FilledValues.shared.containsAcross(labels: numeric.map(\.0), digits: numeric.map(\.1)) { return true }
    }
    return HandBack.containsCardFragments(lines)
  }
}
