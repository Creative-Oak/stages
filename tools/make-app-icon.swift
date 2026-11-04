// Draws Stages' app icon and writes App/Stages/Assets.xcassets/AppIcon.appiconset.
//   xcrun swift tools/make-app-icon.swift   (or `make icon`)
// A macOS squircle in deep ultramarine → teal; the centre stage as a frosted-glass window, the
// strip as three tinted glass cards in Lodestone inks.
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
  NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func draw(size: CGFloat) -> NSBitmapImageRep {
  let px = Int(size)
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current?.imageInterpolation = .high
  let s = size / 1024
  func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }
  func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: rect, xRadius: radius * s, yRadius: radius * s) }
  func withShadow(_ alpha: CGFloat, y: CGFloat, blur: CGFloat, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor.black.withAlphaComponent(alpha)
    sh.shadowOffset = NSSize(width: 0, height: y * s)
    sh.shadowBlurRadius = blur * s
    sh.set()
    body()
    NSGraphicsContext.restoreGraphicsState()
  }

  // Body: macOS grid squircle (824 pt, 100 pt margin), drop shadow, diagonal gradient.
  let body = rounded(r(100, 100, 824, 824), 185)
  withShadow(0.30, y: -12, blur: 28) { color(0x22379A).setFill(); body.fill() }
  NSGradient(colors: [color(0x2C3F9E), color(0x23559F), color(0x2F7F7A)], atLocations: [0, 0.55, 1],
             colorSpace: .sRGB)!.draw(in: body, angle: -55)

  NSGraphicsContext.saveGraphicsState()
  body.addClip()
  // Soft sheen across the top.
  NSGradient(colors: [NSColor.white.withAlphaComponent(0.20), NSColor.white.withAlphaComponent(0.06), NSColor.white.withAlphaComponent(0)],
             atLocations: [0, 0.3, 0.55], colorSpace: .sRGB)!.draw(in: body, angle: -90)

  // A glass card: tint fill, top-lit gradient, bright rim, inner top highlight.
  func glass(_ rect: NSRect, radius: CGFloat, tint: NSColor, tintAlpha: CGFloat) {
    let path = rounded(rect, radius)
    withShadow(0.28, y: -10, blur: 26) { tint.withAlphaComponent(tintAlpha).setFill(); path.fill() }
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(starting: NSColor.white.withAlphaComponent(0.30), ending: NSColor.white.withAlphaComponent(0.02))!.draw(in: path, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.55).setStroke()
    let rim = rounded(rect.insetBy(dx: 1.5 * s, dy: 1.5 * s), radius - 1.5)
    rim.lineWidth = 3 * s
    rim.stroke()
  }

  // The strip: three tinted glass cards, the front one a touch larger.
  let cards: [(UInt32, CGFloat)] = [(0xE3B72B, 0), (0xD1612F, 1), (0x5F9A4A, 2)]
  for (ink, i) in cards {
    let y = 610 - i * 168
    glass(r(168, y, 148, 128), radius: 30, tint: color(ink), tintAlpha: 0.92)
  }

  // The centre stage: a frosted window.
  let win = r(356, 214, 500, 596)
  glass(win, radius: 48, tint: color(0xFFFFFF), tintAlpha: 0.88)
  // Traffic lights.
  for (i, d) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
    color(UInt32(d)).setFill()
    NSBezierPath(ovalIn: r(400 + CGFloat(i) * 46, 742, 28, 28)).fill()
  }
  // Content: a header block and text lines, in the inks' ultramarine.
  color(0x2C3F9E, 0.85).setFill()
  rounded(r(400, 620, 210, 60), 14).fill()
  for (i, w) in [400, 340, 372, 250].enumerated() {
    color(0x0B0B0C, 0.16).setFill()
    rounded(r(400, 548 - CGFloat(i) * 62, CGFloat(w), 22), 11).fill()
  }
  NSGraphicsContext.restoreGraphicsState()

  // Rim light around the whole squircle.
  NSColor.white.withAlphaComponent(0.18).setStroke()
  let rim = rounded(r(102, 102, 820, 820), 183)
  rim.lineWidth = 4 * s
  rim.stroke()

  NSGraphicsContext.restoreGraphicsState()
  return rep
}

let out = "App/Stages/Assets.xcassets/AppIcon.appiconset"
var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    let data = draw(size: CGFloat(pt * scale)).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
  }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
  .write(to: URL(fileURLWithPath: "\(out)/Contents.json"))
print("wrote \(images.count) icon sizes to \(out)")
