import AppKit
import SwiftUI
import StageStore

/// Why each stage on screen got its record, plus every record off screen.
struct MatchingDebugView: View {
  let model: AppModel

  private var offScreen: [StageRecord] {
    let shown = Set(model.stages.map(\.id))
    return model.records.filter { !shown.contains($0.id) }.sorted { $0.lastSeen > $1.lastSeen }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        Text("Matching").font(Theme.grotesk(17, .semibold))
        Spacer()
        Text("\(model.records.count) records").font(Theme.mono(11)).foregroundStyle(.secondary)
      }
      .padding(14)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          notes
          Theme.label("On screen").padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
          ForEach(model.stages) { s in
            row(s.record, position: "\(s.stage.position.rawValue) \(s.stage.order)", reason: s.reason.summary,
                windows: s.stage.windows.count)
            Divider().padding(.leading, 14)
          }
          Theme.label("Off screen").padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 4)
          if offScreen.isEmpty {
            Text("Every record is on screen.").font(Theme.serif(13)).foregroundStyle(.secondary).padding(.horizontal, 14)
          }
          ForEach(offScreen) { r in
            row(r, position: r.state == .dormant ? "dormant" : "absent", reason: offScreenReason(r), windows: r.windowIDs.count)
            Divider().padding(.leading, 14)
          }
        }
        .padding(.bottom, 14)
      }
    }
    .frame(minWidth: 520, minHeight: 420)
  }

  @ViewBuilder private var notes: some View {
    let lines = [
      model.discardedStaleIDs ? "Window IDs from before the last reboot were discarded; records match by fingerprint." : nil,
      model.store.lastRejection.map { "Ignored the last snapshot, showing the one before: \($0)." },
      DocumentResolver.isTrusted ? nil : "No Accessibility permission: fingerprints have apps and titles, but no document paths.",
    ].compactMap { $0 }
    if !lines.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(lines, id: \.self) { Text($0).font(Theme.serif(12.5)).foregroundStyle(.secondary) }
      }
      .padding(.horizontal, 14).padding(.top, 10)
    }
  }

  private func offScreenReason(_ r: StageRecord) -> String {
    let seen = r.lastSeen.formatted(.relative(presentation: .named))
    if r.state == .dormant, let into = r.mergedInto {
      let keeper = model.records.first { $0.id == into }
      return "merged into \(keeper?.name ?? String(into.uuidString.prefix(8))), last seen \(seen)"
    }
    return r.isCustomised ? "last seen \(seen); kept (customised)" : "last seen \(seen); pruned after 6 h"
  }

  private func row(_ r: StageRecord, position: String, reason: String, windows: Int) -> some View {
    HStack(alignment: .top, spacing: 10) {
      InkSwatch(ink: r.ink, size: 10).padding(.top, 4)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(r.name ?? r.fingerprint.apps.map(Self.shortApp).sorted().joined(separator: " + "))
            .font(Theme.grotesk(13.5, r.name == nil ? .regular : .semibold))
            .foregroundStyle(r.name == nil ? .secondary : .primary)
          Spacer()
          Text(position).font(Theme.mono(11)).foregroundStyle(.secondary)
          Text(String(r.id.uuidString.prefix(8))).font(Theme.mono(11)).foregroundStyle(.tertiary)
            .textSelection(.enabled)
        }
        Text(reason).font(.system(size: 12))
        Text("\(windows) window(s) · \(r.fingerprint.titles.count) title(s) · \(r.fingerprint.documents.count) document(s)")
          .font(Theme.mono(10.5)).foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 14).padding(.vertical, 7)
  }

  static func shortApp(_ id: String) -> String {
    id.hasPrefix("name:") ? String(id.dropFirst(5)) : (id.split(separator: ".").last.map(String.init) ?? id)
  }
}

final class MatchingDebugWindow {
  private static var window: NSWindow?

  static func show(model: AppModel) {
    if window == nil {
      let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                       styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
      w.title = "Stages — Matching"
      w.isReleasedWhenClosed = false
      w.contentView = NSHostingView(rootView: MatchingDebugView(model: model))
      w.center()
      window = w
    }
    NSApp.activate()
    window?.makeKeyAndOrderFront(nil)
  }
}
