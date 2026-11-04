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
    let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                    styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: true)
    p.level = .popUpMenu
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    p.isFloatingPanel = true
    p.hidesOnDeactivate = false
    p.backgroundColor = .clear
    p.isOpaque = false
    p.hasShadow = true
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
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Theme.label("Stages")
        Spacer()
        if let q = state.session?.query, !q.isEmpty {
          Text(q).font(Theme.mono(13, .medium))
        } else {
          Text("type to filter").font(Theme.mono(12)).foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, 14).padding(.vertical, 10)
      Rectangle().fill(.separator).frame(height: 1)
      if let s = state.session {
        if s.visible.isEmpty {
          Text("No stage matches “\(s.query)”.").font(Theme.serif(14)).foregroundStyle(.secondary)
            .padding(14)
        }
        ForEach(Array(s.visible.prefix(12).enumerated()), id: \.element.id) { i, c in
          row(c, selected: i == s.selection)
        }
      }
    }
    .frame(width: 460)
    .background(.regularMaterial)
    .overlay(Rectangle().strokeBorder(.separator, lineWidth: 1))
  }

  /// Where the stage is now. Overflow stages aren't visible anywhere, so their tag is drawn
  /// dashed (the design system's mark for "not shown"); the centre stage is plain "now".
  @ViewBuilder private func positionTag(_ p: Candidate.Position) -> some View {
    switch p {
    case .centre:
      Text("now").font(Theme.mono(10.5)).foregroundStyle(.secondary).frame(width: 68, alignment: .trailing)
    case .strip:
      Text("strip").font(Theme.mono(10.5)).foregroundStyle(.tertiary).frame(width: 68, alignment: .trailing)
    case .overflow:
      Text("overflow")
        .font(Theme.mono(10.5, .medium))
        .padding(.horizontal, 5).padding(.vertical, 1)
        .overlay(Rectangle().strokeBorder(.primary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .frame(width: 68, alignment: .trailing)
    }
  }

  private func row(_ c: Candidate, selected: Bool) -> some View {
    let stage = model.stages.first { $0.id == c.id }
    return HStack(alignment: .center, spacing: 10) {
      InkSwatch(ink: stage?.record.ink, size: 12)
      VStack(alignment: .leading, spacing: 2) {
        Text(c.name ?? stage?.appsTitle ?? c.apps.joined(separator: " + "))
          .font(Theme.grotesk(15, c.name == nil ? .regular : .semibold))
          .foregroundStyle(c.name == nil ? .secondary : .primary)
          .lineLimit(1)
        if let t = c.titles.first {
          Text(t).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
      }
      Spacer(minLength: 8)
      HStack(spacing: -4) {
        ForEach(Array((stage?.appIcons ?? []).prefix(4).enumerated()), id: \.offset) { _, icon in
          Image(nsImage: icon).resizable().frame(width: 22, height: 22)
        }
      }
      positionTag(c.position)
      if let slot = c.slot {
        Text("\(slot)").font(Theme.mono(11, .medium)).frame(width: 18, height: 18)
          .overlay(Rectangle().strokeBorder(.primary.opacity(0.5), lineWidth: 1))
      }
    }
    .padding(.horizontal, 14).padding(.vertical, 8)
    .background(selected ? Color.primary.opacity(0.08) : .clear)
    // Selected: the 2 px rule, in the stage's ink when it has one.
    .overlay(alignment: .leading) {
      if selected { Rectangle().fill(stage?.record.ink?.color ?? .primary).frame(width: 2) }
    }
  }
}
