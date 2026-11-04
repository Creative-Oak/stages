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

  static let iconSize: CGFloat = 68
  static let itemWidth: CGFloat = 84
  static let spacing: CGFloat = 2
  static let perRow = 11

  /// Icon size when a stage shows `n` apps, all equal.
  static func stackedSize(_ n: Int) -> CGFloat { [iconSize, 54, 46][min(max(n, 1), 3) - 1] }

  /// The icon row's width: the text below never makes the panel wider than this.
  private var rowWidth: CGFloat {
    let n = CGFloat(min(max(items.count, 1), Self.perRow))
    return n * Self.itemWidth + (n - 1) * Self.spacing
  }

  var body: some View {
    let current = items.first { $0.id == selected }
    VStack(spacing: 6) {
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.itemWidth), spacing: Self.spacing), count: min(max(items.count, 1), Self.perRow)),
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

  private func title(_ c: Candidate) -> String { c.name ?? stage(c)?.appsTitle ?? c.apps.joined(separator: " + ") }

  private func subtitle(_ c: Candidate?) -> String {
    guard let c else { return " " }
    if windows != nil { return c.titles.first ?? " " }
    let where_ = c.position == .overflow ? "In overflow" : c.position == .centre ? "On stage" : nil
    return [where_, c.titles.first].compactMap { $0 }.joined(separator: " · ")
  }

  private func item(_ c: Candidate, isSelected: Bool) -> some View {
    let icons: [NSImage] = if let w = windows?[c.id] { [IconCache.icon(for: w.pid, bundleID: w.bundleID)].compactMap { $0 } }
                           else { stage(c).map(model.appIcons) ?? [] }
    return VStack(spacing: 3) {
      // One icon per app, all the same size (up to three), stepped diagonally from the top left;
      // the most recently used app is on top, at the bottom right.
      ZStack(alignment: .topLeading) {
        let shown = Array(icons.prefix(3))
        if shown.isEmpty {
          RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.1))
            .frame(width: Self.iconSize, height: Self.iconSize)
        } else {
          let size = Self.stackedSize(shown.count)
          let step = shown.count > 1 ? (Self.iconSize + 4 - size) / CGFloat(shown.count - 1) : 0
          ForEach(Array(shown.enumerated().reversed()), id: \.offset) { i, icon in
            let place = CGFloat(shown.count - 1 - i)   // 0 = back (oldest), top left
            Image(nsImage: icon).resizable().interpolation(.high)
              .frame(width: size, height: size)
              .shadow(color: .black.opacity(i == shown.count - 1 ? 0 : 0.28), radius: 2.5, y: 1)   // casts onto the ones behind
              .offset(x: place * step + (shown.count == 1 ? 3 : 0), y: place * step * 0.85 + (shown.count == 1 ? 1 : 0))
          }
        }
      }
      .frame(width: Self.iconSize + 6, height: Self.iconSize + 2)
      .opacity(c.position == .overflow ? 0.55 : 1)
      if windows == nil {
        HStack(spacing: 5) {
          Circle().fill(stage(c)?.record.ink?.color ?? .secondary.opacity(0.4)).frame(width: 6, height: 6)
          Text(c.slot?.uppercased() ?? "–")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isSelected ? .primary : .secondary)
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
    .accessibilityLabel("\(title(c)), slot \(c.slot ?? "none")")
  }
}
