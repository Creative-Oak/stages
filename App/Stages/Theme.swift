import AppKit
import SwiftUI
import StageStore

/// The design system's flair on top of native controls: Familjen Grotesk for structure
/// (names, labels, numbers), JetBrains Mono for slot numbers, Source Serif 4 for the odd
/// sentence, square ink swatches and hairline rules. Everything else stays system-native.
enum Theme {
  static func grotesk(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    family("Familjen Grotesk", size, weight) ?? .system(size: size, weight: weight)
  }

  static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    family("JetBrains Mono", size, weight) ?? .system(size: size, weight: weight, design: .monospaced)
  }

  static func serif(_ size: CGFloat) -> Font {
    family("Source Serif 4", size, .regular) ?? .system(size: size, design: .serif)
  }

  /// Uppercase labels, tracked +0.06em.
  static func label(_ text: String) -> some View {
    Text(text.uppercased())
      .font(grotesk(10.5, .semibold))
      .tracking(0.63)
      .foregroundStyle(.secondary)
  }

  private static var available: [String: Bool] = [:]

  private static func family(_ name: String, _ size: CGFloat, _ weight: Font.Weight) -> Font? {
    if available[name] == nil {
      available[name] = NSFontManager.shared.availableFontFamilies.contains(name)
    }
    return available[name]! ? .custom(name, size: size).weight(weight) : nil
  }

  static let hairline: CGFloat = 1 / max(1, NSScreen.main?.backingScaleFactor ?? 2)
}

extension Ink {
  var color: Color { Color(nsColor: nsColor) }

  var nsColor: NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
  }

  var title: String { rawValue.capitalized }
}

/// A square of ink. No ink is drawn as a dashed outline, so it reads in greyscale.
struct InkSwatch: View {
  var ink: Ink?
  var size: CGFloat = 10

  var body: some View {
    if let ink {
      Rectangle().fill(ink.color).frame(width: size, height: size)
    } else {
      Rectangle()
        .strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
        .frame(width: size, height: size)
    }
  }
}
