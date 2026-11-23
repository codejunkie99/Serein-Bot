import Foundation

/// Deterministic per-day parameters, so the drawing is the same all day and new each morning.
struct DailySeed {
  var petals: Int
  var aspect: Double
  var angle: Double
  var x: Double
  var y: Double
  var split: Double
  init(date: Date, calendar: Calendar = .current) {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    let year = parts.year ?? 2026
    let month = parts.month ?? 1
    let day = parts.day ?? 1
    var state = UInt64(year * 10_000 + month * 100 + day)
    func next() -> Double {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      z ^= z >> 31
      return Double(z >> 11) / Double(1 << 53)
    }
    petals = 5 + Int(next() * 5)
    aspect = 0.30 + next() * 0.24
    angle = next() * 180
    x = 0.66 + next() * 0.16
    y = 0.36 + next() * 0.14
    split = 0.3 + next() * 0.4
  }
}
