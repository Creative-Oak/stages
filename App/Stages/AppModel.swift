import AppKit
import Observation
import os
import StageReader
import StageStore
import Switcher
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
  /// Set on app activation, before the next snapshot confirms which stage is in the centre.
  private(set) var provisionalCurrent: UUID?
  @ObservationIgnored private var activatedAt: ContinuousClock.Instant?
  @ObservationIgnored private var activationObserver: NSObjectProtocol?

  func start() {
    poller.onCommit = { [weak self] snapshot in self?.apply(snapshot) }
    store.onEvent = { Self.log.notice("identity: \($0, privacy: .public)") }
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
      MainActor.assumeIsolated { self?.activated(pid) }
    }
    poller.start()
  }

  /// The centre stage on the main display (the reader orders the main display first), or,
  /// right after switching apps, the stage the activated app belongs to.
  var current: IdentifiedStage? {
    if let p = provisionalCurrent, let s = stages.first(where: { $0.id == p }) { return s }
    return stages.first { $0.stage.position == .centre }
  }

  /// Activating an app brings its stage to the centre. Show that at once when the app is in
  /// exactly one stage; the next committed snapshot confirms or corrects it.
  private func activated(_ pid: Int32?) {
    activatedAt = .now
    let containing = pid.map { pid in stages.filter { $0.stage.windows.contains { $0.pid == pid } } } ?? []
    // Every activation replaces the guess (or clears it), so an older one can't linger.
    provisionalCurrent = containing.count == 1 ? containing[0].id : nil
    // If no snapshot confirms it (nothing on screen changed), fall back to the committed centre.
    provisionalGeneration += 1
    let generation = provisionalGeneration
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard let self, self.provisionalGeneration == generation else { return }
      self.provisionalCurrent = nil
    }
  }
  @ObservationIgnored private var provisionalGeneration = 0

  func stages(_ position: Stage.Position) -> [IdentifiedStage] {
    stages.filter { $0.stage.position == position }
  }

  var displayCount: Int { Set(stages.map(\.stage.displayID)).count }

  private func apply(_ snapshot: StageSnapshot) {
    self.snapshot = snapshot
    stages = store.reconcile(snapshot)
    records = Array(store.records.values)
    provisionalCurrent = nil
    if let settle = poller.lastSettle {
      let ms = Int(settle.duration.components.seconds * 1000 + settle.duration.components.attoseconds / 1_000_000_000_000_000)
      let sinceActivation = activatedAt.map { ContinuousClock.now - $0 }
      let am = sinceActivation.map { Int($0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000) }
      Self.log.notice("settle: \(ms) ms over \(settle.reads) reads; since activation: \(am.map(String.init) ?? "–", privacy: .public) ms")
      activatedAt = nil
    }
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

  // MARK: Switching

  /// Set when the last switch didn't bring its stage to the centre (shown in the popover).
  private(set) var switchProblem: String?

  /// The committed centre stage, ignoring any provisional guess.
  private var committedCentre: UUID? { stages.first { $0.stage.position == .centre }?.id }

  var candidates: [Candidate] {
    stages.map { s in
      Candidate(id: s.id, name: s.record.name, apps: s.stage.owners, titles: s.windowTitles,
                position: Candidate.Position(s.stage.position), order: s.stage.order, slot: s.record.slot,
                lastActive: s.record.lastActive, createdAt: s.record.createdAt)
    }
  }

  /// Next/previous in the stable cycle (slots first, then by age). Rapid presses only move the
  /// target (the menu bar follows at once); the window is raised after a short pause, so a burst
  /// of presses costs one Stage Manager animation.
  func step(_ by: Int) {
    guard let target = SwitcherOrder.neighbour(of: current?.id, in: candidates, step: by) else { return }
    provisionalCurrent = target.id
    pendingStep?.cancel()
    pendingStep = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled else { return }
      self?.switchTo(target.id)
    }
  }
  @ObservationIgnored private var pendingStep: Task<Void, Never>?
  /// Only the newest switch may retry or report; older ones stop when superseded.
  @ObservationIgnored private var switchGeneration = 0

  /// Raise the stage's most recent window, then check the next snapshots for the stage in the
  /// centre; retry once, then report.
  func switchTo(_ id: UUID) {
    guard let stage = stages.first(where: { $0.id == id }), let window = stage.stage.windows.min(by: { $0.z < $1.z }) else { return }
    switchGeneration += 1
    let generation = switchGeneration
    guard committedCentre != id else { provisionalCurrent = nil; return }
    provisionalCurrent = id
    poller.poke()
    Task { [weak self] in
      guard let self else { return }
      for attempt in 1...2 {
        guard self.switchGeneration == generation else { return }
        let outcome = StageActivator.raise(window)
        switch outcome {
        case .notTrusted:
          self.switchProblem = "Switching needs Accessibility permission."
          return
        case let .failed(why):
          Self.log.notice("switch: attempt \(attempt) failed: \(why, privacy: .public)")
        case .raised, .appOnly:
          if await self.waitForCentre(id, timeout: .milliseconds(1500)) {
            guard self.switchGeneration == generation else { return }
            self.switchProblem = nil
            Self.log.notice("switch: reached centre on attempt \(attempt) (\(outcome == .raised ? "window raised" : "app only", privacy: .public))")
            return
          }
          Self.log.notice("switch: not in centre after attempt \(attempt)")
        }
      }
      guard self.switchGeneration == generation else { return }
      self.switchProblem = "Couldn't bring \(stage.title) to the centre."
      NSSound.beep()
    }
  }

  private func waitForCentre(_ id: UUID, timeout: Duration) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if committedCentre == id { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return committedCentre == id
  }

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

extension Candidate.Position {
  init(_ p: Stage.Position) {
    switch p {
    case .centre: self = .centre
    case .strip: self = .strip
    case .overflow: self = .overflow
    }
  }
}

/// The switcher's keyboard settings (UserDefaults).
enum ShortcutSettings {
  enum Modifier: String, CaseIterable {
    case option, control, command

    var flag: CGEventFlags {
      switch self {
      case .option: .maskAlternate
      case .control: .maskControl
      case .command: .maskCommand
      }
    }

    var label: String {
      switch self {
      case .option: "⌥⇥"
      case .control: "⌃⇥"
      case .command: "⌘⇥ (replaces the app switcher)"
      }
    }
  }

  static let modifierKey = "switcherModifier"
  static let arrowsKey = "arrowsEnabled"

  static var modifier: Modifier {
    UserDefaults.standard.string(forKey: modifierKey).flatMap(Modifier.init) ?? .option
  }

  /// ⌃⌥←/→ (and ↑/↓) for previous/next stage.
  static var arrowsEnabled: Bool {
    UserDefaults.standard.object(forKey: arrowsKey) as? Bool ?? true
  }
}
