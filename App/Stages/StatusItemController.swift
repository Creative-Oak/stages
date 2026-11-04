import AppKit
import Observation
import SwiftUI

/// The menu-bar item: the current stage's ink square and name, opening the popover.
final class StatusItemController: NSObject, NSPopoverDelegate {
  private let model: AppModel
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let popover = NSPopover()

  static let maxTitleLength = 28

  init(model: AppModel) {
    self.model = model
    super.init()
    popover.behavior = .transient
    popover.animates = true
    popover.delegate = self
    let host = NSHostingController(rootView: PopoverView(model: model))
    host.sizingOptions = .preferredContentSize
    popover.contentViewController = host

    if let button = item.button {
      button.target = self
      button.action = #selector(toggle)
      button.imagePosition = .imageLeading
    }
    observe()
  }

  @objc private func toggle() {
    if popover.isShown {
      popover.performClose(nil)
    } else if let button = item.button {
      model.pokePoller()
      NSApp.activate()
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      popover.contentViewController?.view.window?.makeKey()
    }
  }

  private func observe() {
    withObservationTracking { render() } onChange: { [weak self] in
      Task { @MainActor in self?.observe() }
    }
  }

  private func render() {
    guard let button = item.button else { return }
    var ink: NSColor?
    var unavailable = false
    if let snapshot = model.snapshot, !snapshot.isAvailable {
      unavailable = true
      button.toolTip = snapshot.unavailable?.message
    } else if let current = model.current {
      ink = current.record.ink?.nsColor
      button.toolTip = [current.title, current.windowTitles.first].compactMap { $0 }.joined(separator: " — ")
    } else {
      button.toolTip = model.snapshot == nil ? "Stages" : "Desktop"
    }
    button.image = Self.glyph(ink: ink, unavailable: unavailable)
    button.imagePosition = .imageOnly
    button.title = ""
    button.setAccessibilityLabel("Stages: " + (button.toolTip ?? ""))
  }

  /// Stages' own menu-bar glyph (not an SF Symbol): the centre stage as a window, the strip as
  /// three marks to its left. The window is filled with the current stage's ink; the rest is
  /// drawn in the menu bar's own text colour, so it follows light and dark menu bars. Without an
  /// ink (or a readable stage) it's a plain template image; dashed when stages can't be read.
  static func glyph(ink: NSColor?, unavailable: Bool) -> NSImage {
    let size = NSSize(width: 20, height: 15)
    let image = NSImage(size: size, flipped: false) { _ in
      // Template images are tinted by the system; otherwise use the menu bar's label colour.
      let line: NSColor = ink == nil ? .black : .labelColor
      line.setStroke(); line.setFill()
      // Strip: three short rounded marks on the left.
      for i in 0..<3 {
        NSBezierPath(roundedRect: NSRect(x: 1, y: 2.5 + CGFloat(i) * 4, width: 3.5, height: 2.5), xRadius: 1, yRadius: 1).fill()
      }
      // Centre stage: a rounded window.
      let win = NSRect(x: 6.5, y: 1.5, width: 12.5, height: 12)
      let path = NSBezierPath(roundedRect: win, xRadius: 2.6, yRadius: 2.6)
      if let ink {
        ink.setFill(); path.fill()
        // Title-bar hint, in the paper colour, so the shape still reads as a window.
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: 8.3, y: 10.6, width: 4.5, height: 1.4), xRadius: 0.7, yRadius: 0.7).fill()
      } else {
        path.lineWidth = 1.4
        if unavailable { path.setLineDash([2, 1.6], count: 2, phase: 0) }
        line.setStroke(); path.stroke()
      }
      return true
    }
    image.isTemplate = ink == nil
    return image
  }

  static func truncate(_ s: String) -> String {
    s.count <= maxTitleLength ? s : String(s.prefix(maxTitleLength - 1)) + "…"
  }
}
