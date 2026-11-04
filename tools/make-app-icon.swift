// Draws Stages' app icon and writes App/Stages/Assets.xcassets/AppIcon.appiconset.
//   xcrun swift tools/make-app-icon.swift
// A macOS squircle on a paper ground: the centre stage as a window, the strip as three cards in
// Lodestone inks (teal, oxide, ultramarine).
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
  let s = size / 1024   // design on a 1024 grid
  func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

  // Squircle body (macOS grid: 824 pt body, 100 pt margin), with a soft shadow.
  let body = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
  shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
  shadow.shadowBlurRadius = 24 * s
  shadow.set()
  color(0xF4F4F1).setFill()
  body.fill()
  NSGraphicsContext.restoreGraphicsState()
  NSGradient(starting: color(0xFBFBFA), ending: color(0xE4E4DF))!.draw(in: body, angle: -90)

  body.addClip()

  func card(_ rect: NSRect, fill: NSColor, radius: CGFloat, shadowAlpha: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor.black.withAlphaComponent(shadowAlpha)
    sh.shadowOffset = NSSize(width: 0, height: -6 * s)
    sh.shadowBlurRadius = 18 * s
    sh.set()
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius * s, yRadius: radius * s).fill()
    NSGraphicsContext.restoreGraphicsState()
  }

  // The strip: three cards on the left, slightly recessed, in inks.
  let inks: [UInt32] = [0x2F7F7A, 0xD1612F, 0x2C3F9E]
  for (i, ink) in inks.enumerated() {
    let y = 640 - CGFloat(i) * 190
    card(r(178, y, 150, 120), fill: color(ink), radius: 22, shadowAlpha: 0.22)
    // A hint of a title bar on each thumbnail.
    color(0xFFFFFF, 0.35).setFill()
    NSBezierPath(roundedRect: r(192, y + 92, 60, 12), xRadius: 6 * s, yRadius: 6 * s).fill()
  }

  // The centre stage: a window.
  let win = r(372, 236, 476, 552)
  card(win, fill: color(0xFFFFFF), radius: 34, shadowAlpha: 0.30)
  // Title bar with the three traffic lights.
  let dots: [UInt32] = [0xFF5F57, 0xFEBC2E, 0x28C840]
  for (i, d) in dots.enumerated() {
    color(d).setFill()
    NSBezierPath(ovalIn: r(408 + CGFloat(i) * 44, 728, 26, 26)).fill()
  }
  color(0x0B0B0C, 0.08).setFill()
  NSBezierPath(rect: r(372, 704, 476, 2)).fill()
  // Content: a few hairline text lines.
  for (i, w) in [360, 300, 330, 220].enumerated() {
    color(0x0B0B0C, 0.12).setFill()
    NSBezierPath(roundedRect: r(412, 640 - CGFloat(i) * 56, CGFloat(w), 18), xRadius: 9 * s, yRadius: 9 * s).fill()
  }

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
try! #"{ "info" : { "author" : "xcode", "version" : 1 } }"#.write(toFile: "App/Stages/Assets.xcassets/Contents.json", atomically: true, encoding: .utf8)
print("wrote \(images.count) icon sizes to \(out)")
