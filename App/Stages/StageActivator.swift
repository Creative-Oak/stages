import AppKit
import ApplicationServices
import StageReader

/// Brings a stage to the centre the way a Dock click does: make its app frontmost and raise one
/// of its windows. Stage Manager then moves the whole stage. Needs Accessibility.
enum StageActivator {
  enum Outcome: Equatable {
    case raised
    /// No AX window matched by title: only the app was activated (Stage Manager picks which of
    /// its stages comes forward).
    case appOnly
    case notTrusted
    case failed(String)
  }

  /// Raise `window`, the stage's most recent one.
  static func raise(_ window: StageWindow) -> Outcome {
    guard AXIsProcessTrusted() else { return .notTrusted }
    let app = AXUIElementCreateApplication(window.pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    let target = axWindow(in: app, matching: window)
    if let target {
      AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
      AXUIElementPerformAction(target, kAXRaiseAction as CFString)
    }
    let frontmost = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    if frontmost != .success {
      // AX refused (rare); ask the app through AppKit instead.
      guard NSRunningApplication(processIdentifier: window.pid)?.activate() == true else {
        return .failed("couldn't activate \(window.owner) (AX error \(frontmost.rawValue))")
      }
    }
    return target == nil ? .appOnly : .raised
  }

  /// The AX window with the same title; among several, the one whose frame matches (only true
  /// for centre windows: strip thumbnails are scaled in CG but not in AX).
  private static func axWindow(in app: AXUIElement, matching w: StageWindow) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement], !windows.isEmpty else { return nil }
    let titled = windows.filter { title(of: $0) == w.title }
    if titled.count <= 1 { return titled.first }
    return titled.first { frame(of: $0).map { near($0, w.frame) } ?? false } ?? titled.first
  }

  private static func title(of el: AXUIElement) -> String? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &v) == .success ? v as? String : nil
  }

  private static func frame(of el: AXUIElement) -> CGRect? {
    var p: CFTypeRef?, s: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
  }

  private static func near(_ a: CGRect, _ b: Rect) -> Bool {
    abs(a.minX - b.x) <= 4 && abs(a.minY - b.y) <= 4 && abs(a.width - b.w) <= 4 && abs(a.height - b.h) <= 4
  }
}
