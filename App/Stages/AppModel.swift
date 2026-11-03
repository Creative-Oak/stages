import AppKit
import Observation
import os
import StageReader
import StageStore
import WindowSource

@Observable
final class AppModel {
  private(set) var snapshot: StageSnapshot?
  private(set) var stages: [IdentifiedStage] = []

  @ObservationIgnored let store = StageStore()
  @ObservationIgnored private let poller = StagePoller()

  func start() {
    poller.onCommit = { [weak self] snapshot in self?.apply(snapshot) }
    poller.start()
  }

  /// The centre stage on the main display (the reader orders the main display first).
  var current: IdentifiedStage? { stages.first { $0.stage.position == .centre } }

  func stages(_ position: Stage.Position) -> [IdentifiedStage] {
    stages.filter { $0.stage.position == position }
  }

  var displayCount: Int { Set(stages.map(\.stage.displayID)).count }

  private func apply(_ snapshot: StageSnapshot) {
    self.snapshot = snapshot
    stages = store.reconcile(snapshot)
    // Counts only: window titles stay out of the system log.
    if let reason = snapshot.unavailable {
      Self.log.notice("committed: unavailable \(reason.rawValue, privacy: .public)")
    } else {
      let d = snapshot.diagnostics
      Self.log.notice("committed: \(snapshot.stages.count) stages, \(d.overlayCount) overlays, confidence \(d.confidence.rawValue, privacy: .public)")
    }
  }

  @ObservationIgnored private static let log = Logger(subsystem: "dk.creativeoak.stages", category: "stages")

  // MARK: Actions

  func rename(_ id: UUID, _ name: String) { store.rename(id, to: name); refresh() }
  func setInk(_ id: UUID, _ ink: Ink?) { store.setInk(id, ink); refresh() }
  func setSlot(_ id: UUID, _ slot: Int?) { store.setSlot(id, slot); refresh() }

  /// Re-read records after an edit without waiting for the next snapshot.
  private func refresh() {
    stages = stages.map { s in
      var s = s
      if let r = store.records[s.id] { s.record = r }
      return s
    }
  }

  func pokePoller() { poller.poke() }

  func copyDiagnostics() {
    guard let snapshot, let data = try? Fixture.encoder().encode(snapshot),
          let text = String(data: data, encoding: .utf8) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

extension IdentifiedStage {
  /// The name, or the stage's apps when unnamed.
  var title: String { record.name ?? appsTitle }

  var appsTitle: String {
    let owners = stage.owners
    switch owners.count {
    case 0: return "Empty stage"
    case 1, 2: return owners.joined(separator: " + ")
    default: return "\(owners[0]) + \(owners.count - 1) more"
    }
  }

  var isNamed: Bool { record.name != nil }

  /// Distinct window titles, front-to-back.
  var windowTitles: [String] {
    var seen = Set<String>()
    return stage.windows.compactMap { w in
      guard let t = w.title?.trimmingCharacters(in: .whitespaces), !t.isEmpty, seen.insert(t).inserted else { return nil }
      return t
    }
  }

  /// One icon per app, front-to-back.
  var appIcons: [NSImage] {
    var seen = Set<Int32>()
    return stage.windows.compactMap { w in
      guard seen.insert(w.pid).inserted else { return nil }
      return NSRunningApplication(processIdentifier: w.pid)?.icon
    }
  }
}
