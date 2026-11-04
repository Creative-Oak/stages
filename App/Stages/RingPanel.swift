import AppKit
import Observation
import SwiftUI
import Switcher

/// Shown while stepping with ⌃⌥ arrows or swipes: the fixed ring of stages that next/previous
/// walk, with the target marked, so "next" is something you can see. Fades after a pause.
final class RingPanel {
  @Observable final class State {
    var target: UUID?
  }

  private let model: AppModel
  private let state = State()
  private lazy var panel: NSPanel = makePanel()
  private var hideTask: Task<Void, Never>?

  init(model: AppModel) { self.model = model }

  func show(target: UUID) {
    state.target = target
    if !panel.isVisible {
      panel.alphaValue = 1
      position()
      panel.orderFrontRegardless()
    }
    hideTask?.cancel()
    hideTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(1100))
      guard !Task.isCancelled, let self else { return }
      await NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.18
        self.panel.animator().alphaValue = 0
      }
      guard !Task.isCancelled else { return }
      self.panel.orderOut(nil)
    }
  }

  private func position() {
    guard let screen = NSScreen.main else { return }
    let size = panel.contentView?.fittingSize ?? NSSize(width: 300, height: 200)
    let f = screen.visibleFrame
    panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2 + f.height * 0.08,
                          width: size.width, height: size.height), display: true)
  }

  private func makePanel() -> NSPanel {
    let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                    styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: true)
    p.level = .popUpMenu
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    p.ignoresMouseEvents = true
    p.backgroundColor = .clear
    p.isOpaque = false
    p.hasShadow = true
    let host = NSHostingView(rootView: RingView(state: state, model: model))
    host.sizingOptions = [.intrinsicContentSize]
    p.contentView = host
    return p
  }
}

struct RingView: View {
  let state: RingPanel.State
  let model: AppModel

  var body: some View {
    let ring = SwitcherOrder.cycle(model.candidates)
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Theme.label("Ring")
        Spacer()
        Text("⌃⌥ ← →").font(Theme.mono(10.5)).foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 12).padding(.vertical, 8)
      Rectangle().fill(.separator).frame(height: 1)
      ForEach(ring) { c in row(c, isTarget: c.id == state.target) }
    }
    .frame(width: 300)
    .background(.regularMaterial)
    .overlay(Rectangle().strokeBorder(.separator, lineWidth: 1))
  }

  private func row(_ c: Candidate, isTarget: Bool) -> some View {
    let stage = model.stages.first { $0.id == c.id }
    return HStack(spacing: 8) {
      Text(c.slot.map(String.init) ?? "·")
        .font(Theme.mono(11, .medium)).foregroundStyle(c.slot == nil ? .tertiary : .secondary)
        .frame(width: 14)
      InkSwatch(ink: stage?.record.ink, size: 9)
      Text(c.name ?? stage?.appsTitle ?? c.apps.joined(separator: " + "))
        .font(Theme.grotesk(13, isTarget ? .semibold : .regular))
        .foregroundStyle(isTarget || c.name != nil ? .primary : .secondary)
        .lineLimit(1)
      Spacer(minLength: 6)
      if c.position == .overflow {
        Text("overflow").font(Theme.mono(9.5))
          .padding(.horizontal, 4)
          .overlay(Rectangle().strokeBorder(.primary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 5)
    .background(isTarget ? Color.primary.opacity(0.08) : .clear)
    .overlay(alignment: .leading) {
      if isTarget { Rectangle().fill(stage?.record.ink?.color ?? .primary).frame(width: 2) }
    }
  }
}
