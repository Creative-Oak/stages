import AppKit
import StageReader
import SwiftUI
import StageStore
import Switcher

/// The switcher's look, after macOS's own ⌘⇥: a compact Liquid Glass panel with a row of app
/// icons, a rounded highlight on the selection, and its name underneath. Each item is a stage: the front
/// app's icon with the stage's other apps as small badges, its slot key and ink below.
struct NativeSwitcherView: View {
  let items: [Candidate]
  let selected: UUID?
  let model: AppModel
  /// The in-stage switcher: items are this stage's windows (icon = the app's, no slot keys).
  var windows: [UUID: StageWindow]? = nil
  /// Icons per row before wrapping; `perRow(on:)` fits the row to the display.
  var perRow = 11
  /// The display the switcher is on. Stages on another display (when displays have separate
  /// Spaces, each has its own Stage Manager) get a display mark and the display's name.
  var displayID: UInt32? = nil

  static let iconSize: CGFloat = 68
  static let itemWidth: CGFloat = 84
  static let spacing: CGFloat = 2

  /// As many icons as fit in 75% of the display's width, counting the panel's padding.
  static func perRow(on screen: NSScreen?) -> Int {
    guard let screen else { return 11 }
    let chrome: CGFloat = 2 * 10 + 2 * 20
    return max(1, Int((screen.visibleFrame.width * 0.75 - chrome + spacing) / (itemWidth + spacing)))
  }

  /// The square the icons sit in; (itemWidth − iconBox) / 2 equals the vertical padding, so the
  /// highlight has the same margin on every side.
  static let iconBox: CGFloat = 72

  /// Icon size when a stage shows `n` apps, all equal.
  static func stackedSize(_ n: Int) -> CGFloat { [iconSize, 54, 46][min(max(n, 1), 3) - 1] }

  /// The icon row's width: the text below never makes the panel wider than this.
  private var rowWidth: CGFloat {
    let n = CGFloat(min(max(items.count, 1), perRow))
    return n * Self.itemWidth + (n - 1) * Self.spacing
  }

  var body: some View {
    let current = items.first { $0.id == selected }
    VStack(spacing: 6) {
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.itemWidth), spacing: Self.spacing), count: min(max(items.count, 1), perRow)),
                spacing: 4) {
        ForEach(items) { c in item(c, isSelected: c.id == selected) }
      }
      VStack(spacing: 2) {
        Text(current.map(title) ?? " ")
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(1)
        Text(subtitle(current))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .frame(width: max(rowWidth, 180))   // truncates (middle) instead of widening the panel
    }
    .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 9)
    .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
    .padding(20)   // room for the glass's shadow inside the borderless panel
    .fixedSize()
  }

  private func stage(_ c: Candidate) -> IdentifiedStage? { model.stages.first { $0.id == c.id } }

  /// The other display a stage is on, or nil when it's on the switcher's own display.
  private func otherDisplay(_ c: Candidate) -> UInt32? {
    guard windows == nil, let displayID, let d = stage(c)?.stage.displayID, d != displayID else { return nil }
    return d
  }

  private func displayName(_ id: UInt32) -> String {
    NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?
      .localizedName ?? "another display"
  }

  private func title(_ c: Candidate) -> String { c.name ?? stage(c)?.appsTitle ?? c.apps.joined(separator: " + ") }

  private func subtitle(_ c: Candidate?) -> String {
    guard let c else { return " " }
    if windows != nil { return c.titles.first ?? " " }
    let where_ = if let d = otherDisplay(c) { "On \(displayName(d))" + (c.position == .overflow ? ", in overflow" : "") }
                 else { c.position == .overflow ? "In overflow" : c.position == .centre ? "On stage" : nil }
    return [where_, c.titles.first].compactMap { $0 }.joined(separator: " · ")
  }

  private func item(_ c: Candidate, isSelected: Bool) -> some View {
    let icons: [NSImage] = if let w = windows?[c.id] { [IconCache.icon(for: w.pid, bundleID: w.bundleID)].compactMap { $0 } }
                           else { stage(c).map(model.appIcons) ?? [] }
    return VStack(spacing: 3) {
      // One icon per app, all the same size (up to three), stepped diagonally by equal amounts on
      // both axes and centred in a square box (so the highlight sits evenly around it); the most
      // recently used app is on top, at the bottom right.
      let shown = Array(icons.prefix(3))
      let box = Self.iconBox
      ZStack(alignment: .topLeading) {
        if shown.isEmpty {
          RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.1))
            .frame(width: Self.iconSize, height: Self.iconSize)
            .offset(x: (box - Self.iconSize) / 2, y: (box - Self.iconSize) / 2)
        } else {
          let size = Self.stackedSize(shown.count)
          let step = shown.count > 1 ? (box - size) / CGFloat(shown.count - 1) : 0
          let start = (box - size - step * CGFloat(shown.count - 1)) / 2
          ForEach(Array(shown.enumerated().reversed()), id: \.offset) { i, icon in
            let place = CGFloat(shown.count - 1 - i)   // 0 = back (oldest), top left
            Image(nsImage: icon).resizable().interpolation(.high)
              .frame(width: size, height: size)
              .shadow(color: .black.opacity(i == shown.count - 1 ? 0 : 0.28), radius: 2.5, y: 1)   // casts onto the ones behind
              .offset(x: start + place * step, y: start + place * step)
          }
        }
      }
      .frame(width: box, height: box, alignment: .topLeading)
      .opacity(c.position == .overflow ? 0.55 : 1)
      if windows == nil {
        HStack(spacing: 5) {
          Circle().fill(stage(c)?.record.ink?.color ?? .secondary.opacity(0.4)).frame(width: 6, height: 6)
          Text(c.slot?.uppercased() ?? "–")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isSelected ? .primary : .secondary)
          if otherDisplay(c) != nil {
            Image(systemName: "display")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(isSelected ? .primary : .secondary)
          }
        }
      }
    }
    .padding(.vertical, 6)
    .frame(width: Self.itemWidth)
    .background {
      // Selection is drawn, not just tinted: a 2 pt rule (readable in greyscale, on any wallpaper
      // behind the glass) over a firmer fill.
      if isSelected {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        shape.fill(.primary.opacity(0.16))
          .overlay(shape.strokeBorder(.primary.opacity(0.75), lineWidth: 2))
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title(c)), slot \(c.slot ?? "none")" + (otherDisplay(c).map { ", on \(displayName($0))" } ?? ""))
  }
}
