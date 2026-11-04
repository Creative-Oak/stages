import AppKit
import ApplicationServices
import os
import StageReader

/// Brings a stage to the centre the way a Dock click does: raise one of its windows and make
/// its app frontmost. Stage Manager then moves the whole stage. Needs Accessibility.
///
/// Everything here runs off the main thread: AX calls are round-trips to the target app and
/// can block on a busy one. Window lookups are done ahead of time (`prewarm`, while the switcher
/// is open) so a switch is just "raise" + "frontmost".
nonisolated enum StageActivator {
  enum Outcome: Equatable, Sendable {
    case raised
    /// No AX window matched by title: only the app was activated (Stage Manager picks which of
    /// its stages comes forward).
    case appOnly
    case notTrusted
    case failed(String)
  }

  /// AX window per CG window ID (+ title, since titles decide the match).
  private static let cache = OSAllocatedUnfairLock(initialState: [String: AXUIElementBox]())

  final class AXUIElementBox: @unchecked Sendable {
    let element: AXUIElement
    init(_ e: AXUIElement) { element = e }
  }

  private static func key(_ w: StageWindow) -> String { "\(w.id)|\(w.title ?? "")" }

  /// Look up AX windows for these in the background, so a later `raise` needn't.
  static func prewarm(_ windows: [StageWindow]) {
    guard AXIsProcessTrusted() else { return }
    let missing = windows.filter { w in cache.withLock { $0[key(w)] == nil } }
    guard !missing.isEmpty else { return }
    Task.detached(priority: .userInitiated) {
      for w in missing {
        let app = AXUIElementCreateApplication(w.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        if let el = axWindow(in: app, matching: w) {
          let box = AXUIElementBox(el)
          cache.withLock { $0[key(w)] = box }
        }
      }
    }
  }

  /// Raise `window` (the stage's most recent one) and activate its app. When the app has windows
  /// in no other stage, it's made frontmost first, so keyboard focus moves before the (slower)
  /// window raise, as with ⌘⇥; otherwise the window is raised first so Stage Manager brings the
  /// right one of the app's stages.
  static func raise(_ window: StageWindow, appInOneStage: Bool) async -> Outcome {
    await Task.detached(priority: .userInitiated) { raiseNow(window, frontmostFirst: appInOneStage) }.value
  }

  private static func raiseNow(_ window: StageWindow, frontmostFirst: Bool) -> Outcome {
    guard AXIsProcessTrusted() else { return .notTrusted }
    let app = AXUIElementCreateApplication(window.pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    var frontmost: AXError = .success
    if frontmostFirst {
      frontmost = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
    var target = cache.withLock { $0[key(window)] }?.element
    if let t = target, AXUIElementPerformAction(t, kAXRaiseAction as CFString) != .success {
      cache.withLock { $0[key(window)] = nil }   // stale (window closed or re-created)
      target = nil
    }
    if target == nil, let found = axWindow(in: app, matching: window) {
      AXUIElementPerformAction(found, kAXRaiseAction as CFString)
      let box = AXUIElementBox(found)
      cache.withLock { $0[key(window)] = box }
      target = found
    }
    if let target { AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue) }
    if !frontmostFirst {
      frontmost = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
    if frontmost != .success {
      // AX refused (rare); ask the app through AppKit instead.
      let ok = DispatchQueue.main.sync { NSRunningApplication(processIdentifier: window.pid)?.activate() ?? false }
      guard ok else { return .failed("couldn't activate \(window.owner) (AX error \(frontmost.rawValue))") }
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
