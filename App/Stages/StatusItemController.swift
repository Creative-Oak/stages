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
    var ink: NSColor?
    var symbol = "squares.leading.rectangle"   // the system's Stage Manager glyph
    if let snapshot = model.snapshot, !snapshot.isAvailable {
      title = "Stages"
      symbol = "exclamationmark.triangle"
      button.toolTip = snapshot.unavailable?.message
    } else if let current = model.current {
      title = Self.truncate(current.title)
      ink = current.record.ink?.nsColor
      button.toolTip = current.windowTitles.first
    } else {
      title = model.snapshot == nil ? "Stages" : "Desktop"
      button.toolTip = nil
    }
    // A template symbol (follows the menu bar's light/dark), then the ink as a small dot and
    // the name in the menu bar font.
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Stages")?
      .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    image?.isTemplate = true
    button.image = image
    button.imagePosition = .imageLeading
    let font = NSFont.menuBarFont(ofSize: 0)
    let text = NSMutableAttributedString()
    if let ink {
      text.append(NSAttributedString(string: "  ●", attributes: [.foregroundColor: ink, .font: NSFont.systemFont(ofSize: 8),
                                                              .baselineOffset: 1.5]))
      text.append(NSAttributedString(string: " " + title, attributes: [.font: font]))
    } else {
      text.append(NSAttributedString(string: " " + title, attributes: [.font: font]))
    }
    button.attributedTitle = text
  }

  static func truncate(_ s: String) -> String {
    s.count <= maxTitleLength ? s : String(s.prefix(maxTitleLength - 1)) + "…"
  }
}
