import AppKit
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

  static let iconSize: CGFloat = 68
  static let itemWidth: CGFloat = 84
  static let spacing: CGFloat = 2
  static let perRow = 11

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
    let where_ = c.position == .overflow ? "In overflow" : c.position == .centre ? "On stage" : nil
    return [where_, c.titles.first].compactMap { $0 }.joined(separator: " · ")
  }

  private func item(_ c: Candidate, isSelected: Bool) -> some View {
    let icons = stage(c)?.appIcons ?? []
    return VStack(spacing: 3) {
      ZStack(alignment: .bottomTrailing) {
        if let front = icons.first {
          Image(nsImage: front).resizable().interpolation(.high).frame(width: Self.iconSize, height: Self.iconSize)
        } else {
          RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.1))
            .frame(width: Self.iconSize, height: Self.iconSize)
        }
        // The stage's other apps, as small badges.
        HStack(spacing: -7) {
          ForEach(Array(icons.dropFirst().prefix(3).enumerated()), id: \.offset) { _, icon in
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 24, height: 24)
              .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
          }
        }
        .offset(x: 5, y: 3)
      }
      .frame(width: Self.iconSize + 6, height: Self.iconSize + 2)
      .opacity(c.position == .overflow ? 0.55 : 1)
      HStack(spacing: 5) {
        Circle().fill(stage(c)?.record.ink?.color ?? .secondary.opacity(0.4)).frame(width: 6, height: 6)
        Text(c.slot?.uppercased() ?? "–")
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(isSelected ? .primary : .secondary)
      }
    }
    .padding(.vertical, 6)
    .frame(width: Self.itemWidth)
    .background {
      if isSelected { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.12)) }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title(c)), slot \(c.slot ?? "none")")
  }
}
