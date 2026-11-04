import AppKit
import ApplicationServices
import os
import StageReader
import Switcher

/// Brings a stage to the centre the way a Dock click does: raise one of its windows and make
/// its app frontmost. Stage Manager then moves the whole stage. Needs Accessibility.
///
/// Everything here runs off the main thread: AX calls are round-trips to the target app and
/// can block on a busy one. Which AX window is which CG window is learned ahead of time (`learn`,
/// after every snapshot and when the switcher opens), so a switch is usually just "raise" +
/// "frontmost".
nonisolated enum StageActivator {
  enum Outcome: Equatable, Sendable {
    case raised
    /// No AX window matched: only the app was activated (Stage Manager picks which of its
    /// stages comes forward).
    case appOnly
    case notTrusted
    case failed(String)
  }

  /// An AX element as a value: equal when `CFEqual` (same app, same element).
  final class AXUIElementBox: @unchecked Sendable, Hashable {
    let element: AXUIElement
    init(_ e: AXUIElement) { element = e }
    static func == (a: AXUIElementBox, b: AXUIElementBox) -> Bool { CFEqual(a.element, b.element) }
    func hash(into h: inout Hasher) { h.combine(CFHash(element)) }
  }

  typealias Links = WindowLinks<AXUIElementBox>

  /// CG window ID → its AX window, where certain (see `WindowLinks`).
  private static let links = OSAllocatedUnfairLock(initialState: Links())
  /// What the last attempt raised for a window, so a retry tries a different one, and a switch
  /// that lands can confirm it.
  private static let lastRaised = OSAllocatedUnfairLock(initialState: [UInt32: AXUIElementBox]())
  /// Per app, what its windows looked like when last searched for certain links (skip unchanged).
  private static let looked = OSAllocatedUnfairLock(initialState: [Int32: [String]]())
  private static let learning = OSAllocatedUnfairLock(initialState: false)

  /// Link what can be linked for certain: `focused` (the frontmost app's front window in the
  /// centre) to the app's AX focused window, and windows whose title is unique to them.
  static func learn(_ windows: [StageWindow], focused: StageWindow?) {
    guard AXIsProcessTrusted() else { return }
    guard learning.withLock({ busy in defer { busy = true }; return !busy }) else { return }
    Task.detached(priority: .utility) {
      defer { learning.withLock { $0 = false } }
      links.withLock { $0.keep(only: Set(windows.map(\.id))) }
      if let focused { linkFocused(focused) }
      for (pid, ws) in Dictionary(grouping: windows, by: \.pid) {
        let linked = links.withLock { l in ws.filter { l.element(for: $0.id) != nil }.map(\.id) }
        guard linked.count < ws.count else { continue }
        let signature = ws.map { "\($0.id)|\($0.title ?? "")" }.sorted() + linked.sorted().map { "=\($0)" }
        guard looked.withLock({ $0[pid] }) != signature else { continue }
        looked.withLock { $0[pid] = signature }
        let ax = axWindows(AXUIElementCreateApplication(pid))
        guard !ax.isEmpty else { continue }
        // Each link rules its element out for the rest, which can make another certain.
        while links.withLock({ l in
          var progress = false
          let unlinked = ws.filter { l.element(for: $0.id) == nil }
          for w in unlinked {
            let same = unlinked.filter { $0.title == w.title }.count
            if let e = l.certain(w.id, title: w.title, unlinkedSameTitle: same, among: ax) {
              l.link(w.id, e); progress = true
            }
          }
          return progress
        }) {}
      }
    }
  }

  /// A switch landed on the stage that holds only this window of its app: what was raised is it.
  static func confirm(_ windowID: UInt32) {
    guard let e = lastRaised.withLock({ $0[windowID] }) else { return }
    links.withLock { $0.link(windowID, e) }
  }

  /// Raise `window` (the stage's most recent one) and activate its app. When the app has windows
  /// in no other stage, it's made frontmost first, so keyboard focus moves before the (slower)
  /// window raise, as with ⌘⇥; otherwise the window is raised first so Stage Manager brings the
  /// right one of the app's stages. `aheadSameTitle`: the app's same-titled windows in front of
  /// this one (CG z-order), for the last-resort guess. `retry`: the previous attempt brought
  /// another stage of this app, so the AX window it raised is another window: don't raise it again.
  static func raise(_ window: StageWindow, appInOneStage: Bool, aheadSameTitle: [UInt32] = [], retry: Bool = false) async -> Outcome {
    await Task.detached(priority: .userInitiated) {
      raiseNow(window, frontmostFirst: appInOneStage, aheadSameTitle: aheadSameTitle, retry: retry)
    }.value
  }

  private static func raiseNow(_ window: StageWindow, frontmostFirst: Bool, aheadSameTitle: [UInt32], retry: Bool) -> Outcome {
    guard AXIsProcessTrusted() else { return .notTrusted }
    let app = AXUIElementCreateApplication(window.pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    var frontmost: AXError = .success
    if frontmostFirst {
      frontmost = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
    let avoid = retry ? lastRaised.withLock { $0[window.id] } : nil
    if let avoid { links.withLock { if $0.element(for: window.id) == avoid { $0.unlink(window.id) } } }
    var target = links.withLock { $0.element(for: window.id) }
    if let t = target, AXUIElementPerformAction(t.element, kAXRaiseAction as CFString) != .success {
      links.withLock { $0.unlink(window.id) }   // stale (window closed or re-created)
      target = nil
    }
    if target == nil {
      let ax = axWindows(app)
      if let found = links.withLock({ $0.pick(window.id, title: window.title, frame: window.frame,
                                              aheadSameTitle: aheadSameTitle, among: ax, avoiding: avoid) }) {
        AXUIElementPerformAction(found.element, kAXRaiseAction as CFString)
        target = found
      }
    }
    if let target {
      lastRaised.withLock { $0[window.id] = target }
      AXUIElementSetAttributeValue(target.element, kAXMainAttribute as CFString, kCFBooleanTrue)
    }
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

  /// Close `window` with its close button (the app may ask to save first). Off the main thread.
  static func close(_ windows: [StageWindow]) {
    guard AXIsProcessTrusted(), !windows.isEmpty else { return }
    Task.detached(priority: .userInitiated) {
      for w in windows {
        let app = AXUIElementCreateApplication(w.pid)
        var target = links.withLock { $0.element(for: w.id) }
        if target == nil {
          let ax = axWindows(app)
          target = links.withLock { $0.pick(w.id, title: w.title, frame: w.frame, aheadSameTitle: [], among: ax) }
        }
        guard let el = target?.element else { continue }
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXCloseButtonAttribute as CFString, &button) == .success, let button,
              CFGetTypeID(button) == AXUIElementGetTypeID() else { continue }
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
      }
    }
  }

  /// The app's focused AX window is the CG window in front in the centre, when the titles agree.
  private static func linkFocused(_ w: StageWindow) {
    let app = AXUIElementCreateApplication(w.pid)
    AXUIElementSetMessagingTimeout(app, 0.3)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &v) == .success,
          let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return }
    let box = AXUIElementBox(v as! AXUIElement)
    guard title(of: box.element) == w.title else { return }
    links.withLock { $0.link(w.id, box) }
  }

  /// The app's AX windows, front to back, with title and frame.
  private static func axWindows(_ app: AXUIElement) -> [Links.AXWindow] {
    AXUIElementSetMessagingTimeout(app, 0.3)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return [] }
    return windows.map { Links.AXWindow(element: AXUIElementBox($0), title: title(of: $0), frame: frame(of: $0)) }
  }

  private static func title(of el: AXUIElement) -> String? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &v) == .success ? v as? String : nil
  }

  private static func frame(of el: AXUIElement) -> Rect? {
    var p: CFTypeRef?, s: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return Rect(x: point.x, y: point.y, w: size.width, h: size.height)
  }
}
