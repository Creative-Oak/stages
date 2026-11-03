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
    let title: String
    let image: NSImage
    if let snapshot = model.snapshot, !snapshot.isAvailable {
      title = "Stages"
      image = Self.swatch(nil, dashed: true)
      button.toolTip = snapshot.unavailable?.message
    } else if let current = model.current {
      title = Self.truncate(current.title)
      image = Self.swatch(current.record.ink?.nsColor, dashed: false)
      button.toolTip = current.windowTitles.first
    } else {
      title = model.snapshot == nil ? "Stages" : "Desktop"
      image = Self.swatch(nil, dashed: false)
      button.toolTip = nil
    }
    button.image = image
    button.title = " " + title
    button.font = .menuBarFont(ofSize: 0)
  }

  static func truncate(_ s: String) -> String {
    s.count <= maxTitleLength ? s : String(s.prefix(maxTitleLength - 1)) + "…"
  }

  /// A 9 pt ink square, or a hairline outline (template, so it follows the menu bar) when the
  /// stage has no ink. Dashed when stages can't be read.
  static func swatch(_ color: NSColor?, dashed: Bool) -> NSImage {
    let side: CGFloat = 9
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
      if let color {
        color.setFill()
        rect.fill()
      } else {
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        if dashed { path.setLineDash([2, 1.5], count: 2, phase: 0) }
        NSColor.black.setStroke()
        path.stroke()
      }
      return true
    }
    image.isTemplate = color == nil
    return image
  }
}
