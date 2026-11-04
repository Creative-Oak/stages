import AppKit
import Observation
import SwiftUI
import Switcher

/// The hold-⌥⇥ switcher: a non-activating panel (the frontmost app keeps focus; keys arrive
/// through the event tap), one row per stage, overflow included.
final class SwitcherPanel {
  @Observable final class State {
    var session: SwitcherSession?
  }

  private let model: AppModel
  private let state = State()
  private lazy var panel: NSPanel = makePanel()

  init(model: AppModel) { self.model = model }

  /// Build the panel and its SwiftUI view now, so the first ⌥⇥ doesn't pay for it.
  func prewarm() {
    _ = panel.contentView?.fittingSize
  }

  func show(_ session: SwitcherSession) {
    state.session = session
    if !panel.isVisible {
      position()
      panel.orderFrontRegardless()
    }
  }

  func hide() {
    panel.orderOut(nil)
    state.session = nil
  }

  private func position() {
    guard let screen = NSScreen.main else { return }
    let size = panel.contentView?.fittingSize ?? NSSize(width: 460, height: 300)
    let f = screen.visibleFrame
    panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2 + f.height * 0.08,
                          width: size.width, height: size.height), display: true)
  }

  private func makePanel() -> NSPanel {
    let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
                    styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: true)
    p.level = .popUpMenu
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    p.isFloatingPanel = true
    p.hidesOnDeactivate = false
    p.backgroundColor = .clear
    p.isOpaque = false
    p.hasShadow = false   // the Liquid Glass draws its own
    let host = NSHostingView(rootView: SwitcherView(state: state, model: model))
    host.sizingOptions = [.intrinsicContentSize]
    p.contentView = host
    // Re-centre when the content grows or shrinks (filtering).
    NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: host, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.position() }
    }
    return p
  }
}

struct SwitcherView: View {
  let state: SwitcherPanel.State
  let model: AppModel

  var body: some View {
    if let s = state.session {
      NativeSwitcherView(items: s.visible, selected: s.selected?.id, model: model)
    } else {
      // Built once at launch (prewarm) before any session exists.
      NativeSwitcherView(items: [], selected: nil, model: model)
    }
  }
}
