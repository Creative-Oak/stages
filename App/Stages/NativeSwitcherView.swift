import AppKit
import SwiftUI
import StageStore
import Switcher

/// The switcher's look, after macOS's own ⌘⇥: a dark glass panel with a row of large icons, a
/// rounded highlight on the selection, and its name underneath. Each item is a stage: the front
/// app's icon with the stage's other apps as small badges, its slot key and ink below.
struct NativeSwitcherView: View {
  let items: [Candidate]
  let selected: UUID?
  let model: AppModel

  static let iconSize: CGFloat = 72
  static let itemWidth: CGFloat = 96
  static let perRow = 10

  var body: some View {
    let current = items.first { $0.id == selected }
    VStack(spacing: 10) {
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.itemWidth), spacing: 6), count: min(max(items.count, 1), Self.perRow)),
                spacing: 8) {
        ForEach(items) { c in item(c, isSelected: c.id == selected) }
      }
      VStack(spacing: 2) {
        Text(current.map(title) ?? " ")
          .font(.system(size: 14, weight: .semibold))
          .lineLimit(1)
        Text(subtitle(current))
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .frame(maxWidth: CGFloat(min(items.count, Self.perRow)) * (Self.itemWidth + 6))
    }
    .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    .environment(\.colorScheme, .dark)
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
    return VStack(spacing: 6) {
      ZStack(alignment: .bottomTrailing) {
        if let front = icons.first {
          Image(nsImage: front).resizable().interpolation(.high).frame(width: Self.iconSize, height: Self.iconSize)
        } else {
          RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.1))
            .frame(width: Self.iconSize, height: Self.iconSize)
        }
        // The stage's other apps, as small badges.
        HStack(spacing: -8) {
          ForEach(Array(icons.dropFirst().prefix(3).enumerated()), id: \.offset) { _, icon in
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 30, height: 30)
              .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
          }
        }
        .offset(x: 6, y: 4)
      }
      .frame(width: Self.iconSize + 8, height: Self.iconSize + 4)
      .opacity(c.position == .overflow ? 0.55 : 1)
      HStack(spacing: 5) {
        Circle().fill(stage(c)?.record.ink?.color ?? .white.opacity(0.25)).frame(width: 7, height: 7)
        Text(c.slot?.uppercased() ?? "–")
          .font(.system(size: 12, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(isSelected ? .primary : .secondary)
      }
    }
    .padding(.vertical, 8)
    .frame(width: Self.itemWidth)
    .background {
      if isSelected { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.16)) }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title(c)), slot \(c.slot ?? "none")")
  }
}
