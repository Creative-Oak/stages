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
  /// All records, on screen or not (debug window).
  private(set) var records: [StageRecord] = []

  @ObservationIgnored let store = StageStore()
  @ObservationIgnored private let poller = StagePoller()
  /// "windowID|title" already sent to the document resolver.
  @ObservationIgnored private var resolvedDocuments = Set<String>()
  @ObservationIgnored private var resolving = false

  func start() {
    poller.onCommit = { [weak self] snapshot in self?.apply(snapshot) }
    store.onEvent = { Self.log.notice("identity: \($0, privacy: .public)") }
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
    records = Array(store.records.values)
    // Counts only: window titles stay out of the system log.
    if let reason = snapshot.unavailable {
      Self.log.notice("committed: unavailable \(reason.rawValue, privacy: .public)")
    } else {
      let d = snapshot.diagnostics
      Self.log.notice("committed: \(snapshot.stages.count) read, \(self.stages.count) stages, \(d.overlayCount) overlays, confidence \(d.confidence.rawValue, privacy: .public)")
    }
    resolveDocuments()
  }

  /// Look up AX document paths for windows (or titles) not seen before.
  private func resolveDocuments() {
    guard !resolving, DocumentResolver.isTrusted else { return }
    let pending = stages.flatMap(\.stage.windows).filter { w in
      w.title != nil && !resolvedDocuments.contains("\(w.id)|\(w.title!)")
    }
    guard !pending.isEmpty else { return }
    resolving = true
    pending.forEach { resolvedDocuments.insert("\($0.id)|\($0.title!)") }
    Task {
      let docs = await DocumentResolver.resolve(pending)
      store.attachDocuments(docs)
      records = Array(store.records.values)
      resolving = false
    }
  }

  var lastReasons: [UUID: MatchReason] { store.lastReasons }
  var discardedStaleIDs: Bool { store.discardedStaleIDs }

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
    records = Array(store.records.values)
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
