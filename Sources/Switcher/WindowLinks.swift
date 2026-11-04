import StageReader

/// Which of an app's accessibility windows is which CG window. Accessibility exposes no window
/// number (the call that would is SPI), and titles repeat: two Safari windows on the same page.
/// But an AX window element stays the same object while its window lives, so a link made once
/// survives later title changes, and every linked element is ruled out for the app's other
/// windows. Links are made only when they're certain: the app's focused window while its stage is
/// in the centre, a title only one window has, or a switch that brought exactly that window's
/// stage forward. Generic over the element so it can be tested without AX.
public struct WindowLinks<Element: Hashable> {
  public private(set) var byWindow: [UInt32: Element] = [:]

  public init() {}

  public func element(for windowID: UInt32) -> Element? { byWindow[windowID] }

  /// One element is one window: linking it here unlinks it from any other window.
  public mutating func link(_ windowID: UInt32, _ element: Element) {
    for (id, e) in byWindow where e == element && id != windowID { byWindow[id] = nil }
    byWindow[windowID] = element
  }

  public mutating func unlink(_ windowID: UInt32) { byWindow[windowID] = nil }

  /// Forget windows that no longer exist.
  public mutating func keep(only live: Set<UInt32>) {
    byWindow = byWindow.filter { live.contains($0.key) }
  }

  public struct AXWindow {
    public var element: Element
    public var title: String?
    public var frame: Rect?
    public init(element: Element, title: String?, frame: Rect?) {
      self.element = element; self.title = title; self.frame = frame
    }
  }

  /// The app's same-titled AX windows not linked to another window (and not `avoid`).
  private func open(_ windowID: UInt32, title: String?, among windows: [AXWindow], avoiding avoid: Element?) -> [AXWindow] {
    let taken = Set(byWindow.filter { $0.key != windowID }.map(\.value))
    return windows.filter { $0.title == title && !taken.contains($0.element) && $0.element != avoid }
  }

  /// The element for `windowID` when there's no doubt: only one of the app's unlinked CG windows
  /// has this title (`unlinkedSameTitle` counts them, this one included) and only one open AX
  /// window does.
  public func certain(_ windowID: UInt32, title: String?, unlinkedSameTitle: Int, among windows: [AXWindow]) -> Element? {
    if let known = byWindow[windowID] { return known }
    guard unlinkedSameTitle == 1 else { return nil }
    let candidates = open(windowID, title: title, among: windows, avoiding: nil)
    return candidates.count == 1 ? candidates[0].element : nil
  }

  /// Best guess for raising `windowID`: its link; else the one open same-titled AX window; else
  /// the one whose frame matches (centre windows report their real frame); else by rank among
  /// the unlinked same-titled windows in front of it (`aheadSameTitle`, CG z-order), which
  /// Stage Manager doesn't keep in step with the app's own order, hence a guess. `avoid`: the
  /// element a failed attempt raised.
  public func pick(_ windowID: UInt32, title: String?, frame: Rect?, aheadSameTitle: [UInt32],
                   among windows: [AXWindow], avoiding avoid: Element? = nil) -> Element? {
    if let known = byWindow[windowID], known != avoid, windows.contains(where: { $0.element == known }) { return known }
    let candidates = open(windowID, title: title, among: windows, avoiding: avoid)
    if candidates.count <= 1 { return candidates.first?.element }
    if let frame {
      let near = candidates.filter { $0.frame.map { Self.close($0, frame) } ?? false }
      if near.count == 1 { return near[0].element }
    }
    let rank = aheadSameTitle.filter { byWindow[$0] == nil }.count
    return candidates[min(rank, candidates.count - 1)].element
  }

  static func close(_ a: Rect, _ b: Rect) -> Bool {
    abs(a.x - b.x) <= 4 && abs(a.y - b.y) <= 4 && abs(a.w - b.w) <= 4 && abs(a.h - b.h) <= 4
  }
}

extension WindowLinks: Sendable where Element: Sendable {}
extension WindowLinks.AXWindow: Sendable where Element: Sendable {}
