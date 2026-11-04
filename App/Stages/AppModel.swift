import ActivityLog
import AppKit
import Observation
import os
import StageReader
import Commands
import StageStore
import Switcher
import WindowSource

@Observable
final class AppModel {
  private(set) var snapshot: StageSnapshot?
  private(set) var stages: [IdentifiedStage] = []
  /// All records, on screen or not (debug window).
  private(set) var records: [StageRecord] = []
  /// Named stages whose windows have all closed; they can be woken.
  private(set) var sleeping: [StageRecord] = []
  /// After waking a stage: what happened (shown in the popover for a while).
  private(set) var wakeNote: String?

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
    // While stepping, activations come from Stage Manager's animation; the target stands.
    guard !steppingActive else { return }
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
    sleeping = store.sleeping
    writeState()
    logActivity()
    // Mid-walk, intermediate snapshots don't move the menu bar off the target.
    if !steppingActive || committedCentre == provisionalCurrent { provisionalCurrent = nil }
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
    prewarmSwitching()   // only looks up windows not cached yet
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
      writeState()
      logActivity()
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
  /// Drop a sleeping stage for good.
  func forget(_ id: UUID) { store.forget(id); sleeping = store.sleeping; refresh() }

  /// Re-read records after an edit without waiting for the next snapshot.
  private func refresh() {
    stages = stages.map { s in
      var s = s
      if let r = store.records[s.id] { s.record = r }
      return s
    }
    records = Array(store.records.values)
    writeState()
  }

  func pokePoller() { poller.poke() }

  // MARK: stages:// commands

  func handle(_ url: URL) {
    switch Command.parse(url) {
    case let .failure(error): report("\(error)")
    case let .success(command): run(command)
    }
  }

  private func run(_ command: Command) {
    Self.log.notice("command: \(String(describing: command).prefix(40), privacy: .public)")
    switch command {
    case let .switchToSlot(n):
      guard let s = stages.first(where: { $0.record.slot == n }) else {
        return report(records.contains { $0.slot == n } ? "The stage in slot \(n) isn't open." : "No stage has slot \(n).")
      }
      switchTo(s.id)
    case let .switchToName(name):
      // Names people chose first (they win exact ties), then generated ones ("Safari + Notes").
      let named = stages.compactMap { s in s.record.name.map { (id: s.id, name: $0) } }
      let generated = stages.filter { $0.record.name == nil }.map { (id: $0.id, name: $0.appsTitle) }
      guard let id = Command.resolve(name: name, chosen: named, generated: generated) else {
        return report("No open stage matches “\(name)” (or several do).")
      }
      switchTo(id)
    case let .switchToID(id):
      guard stages.contains(where: { $0.id == id }) else { return report("That stage isn't open.") }
      switchTo(id)
    case .next: step(1)
    case .previous: step(-1)
    case let .rename(name):
      guard let id = current?.id else { return report("No stage in the centre to name.") }
      rename(id, name ?? "")
    case let .ink(value):
      guard let id = current?.id else { return report("No stage in the centre.") }
      guard let value else { return setInk(id, nil) }
      guard let ink = Ink(rawValue: value) else {
        return report("Unknown ink “\(value)”. Inks: \(Ink.allCases.map(\.rawValue).joined(separator: ", ")).")
      }
      setInk(id, ink)
    case let .slot(n):
      guard let id = current?.id else { return report("No stage in the centre.") }
      setSlot(id, n)
    case let .wake(name):
      let names = sleeping.compactMap { r in r.name.map { (id: r.id, name: $0) } }
      guard let id = Command.resolve(name: name, chosen: names) else {
        return report("No sleeping stage matches “\(name)”.")
      }
      wake(id)
    }
  }

  private func report(_ problem: String) {
    switchProblem = problem
    Self.log.notice("command failed: \(problem, privacy: .public)")
    NSSound.beep()
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(8))
      if self?.switchProblem == problem { self?.switchProblem = nil }
    }
  }

  // MARK: Sleeping stages

  /// Relaunch a sleeping stage's apps and documents. Stage Manager gives each app its own
  /// stage; the first one to appear takes the name back.
  func wake(_ id: UUID) {
    guard let record = store.records[id] else { return }
    store.expectWake(id)
    wakeNote = "Waking \(record.name ?? "stage")…"
    poller.poke()
    Task { [weak self] in
      let result = await StageWaker.wake(record)
      guard let self else { return }
      Self.log.notice("wake: \(result.apps.count) app(s), \(result.documents) document(s), \(result.problems.count) problem(s)")
      var note = result.apps.isEmpty ? "Couldn't wake \(record.name ?? "the stage")." :
        "Woke \(record.name ?? "stage"): \(result.apps.joined(separator: ", "))" +
        (result.documents > 0 ? ", \(result.documents) document\(result.documents == 1 ? "" : "s")." : ".")
      if result.apps.count > 1 {
        note += " Each app opened as its own stage: Shift-click their tiles in the strip to group them again."
      }
      if !result.problems.isEmpty { note += " " + result.problems.joined(separator: "; ") + "." }
      self.wakeNote = note
      try? await Task.sleep(for: .seconds(20))
      if self.wakeNote == note { self.wakeNote = nil }
    }
  }

  // MARK: activity.jsonl

  @ObservationIgnored private let activity = ActivityLog(
    fileURL: StageStore.defaultDirectory.appendingPathComponent("activity.jsonl"))

  /// One line whenever the centre stage, or what's in it, changes (repeats are skipped).
  private func logActivity() {
    guard let centre = stages.first(where: { $0.stage.position == .centre }) else { return }
    let windows = centre.stage.windows.map {
      ActivityEntry.Window(bundleId: $0.bundleID, app: $0.owner, title: $0.title, documentPath: store.documents[$0.id])
    }
    activity.record(ActivityEntry(ts: Date(), stageId: centre.id, name: centre.record.name, windows: windows))
  }

  // MARK: state.json

  @ObservationIgnored private var lastStateData: Data?

  /// Rewrites state.json when its content changes (stages, names, inks, slots, titles, paths).
  private func writeState() {
    guard snapshot?.isAvailable == true else { return }
    let file = StateFile.make(stages: stages, records: Array(store.records.values), documents: store.documents)
    guard let data = try? file.encoded(), data != lastStateData else { return }
    lastStateData = data
    let url = StageStore.defaultDirectory.appendingPathComponent("state.json")
    do { try data.write(to: url, options: .atomic) } catch {
      Self.log.error("couldn't write state.json: \(error.localizedDescription, privacy: .public)")
    }
  }

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
  ///
  /// A burst of steps is one session over a ring frozen at its first step: each step moves one
  /// place from the last target, whatever Stage Manager shows meanwhile.
  func step(_ by: Int) {
    let now = ContinuousClock.now
    var walk: RingWalk
    if let session = ringSession, now < session.until {
      walk = session.walk
    } else {
      walk = RingWalk(ring: SwitcherOrder.cycle(candidates).map(\.id), from: committedCentre ?? current?.id)
    }
    guard let target = walk.step(by, live: Set(stages.map(\.id))) else { return }
    ringSession = (walk, now + Self.ringSessionLength)
    provisionalCurrent = target
    onStep?(target, walk.ring)
    pendingStep?.cancel()
    pendingStep = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled else { return }
      self?.switchTo(target)
    }
  }
  @ObservationIgnored private var pendingStep: Task<Void, Never>?
  @ObservationIgnored private var ringSession: (walk: RingWalk, until: ContinuousClock.Instant)?
  private static let ringSessionLength: Duration = .milliseconds(2500)
  private var steppingActive: Bool { ringSession.map { ContinuousClock.now < $0.until } ?? false }
  /// Called with each step's target and the frozen ring (the ring panel shows them).
  @ObservationIgnored var onStep: ((UUID, [UUID]) -> Void)?
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
    let started = ContinuousClock.now
    Task { [weak self] in
      guard let self else { return }
      for attempt in 1...2 {
        guard self.switchGeneration == generation else { return }
        let outcome = await StageActivator.raise(window)
        Self.log.notice("switch: raise took \(Self.ms(ContinuousClock.now - started)) ms (attempt \(attempt))")
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
            Self.log.notice("switch: reached centre on attempt \(attempt) after \(Self.ms(ContinuousClock.now - started)) ms (\(outcome == .raised ? "window raised" : "app only", privacy: .public))")
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

  /// Look up AX windows for every stage's most recent window, so a switch needn't (called when
  /// the switcher opens).
  func prewarmSwitching() {
    StageActivator.prewarm(stages.compactMap { $0.stage.windows.min(by: { $0.z < $1.z }) })
  }

  static func ms(_ d: Duration) -> Int {
    Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
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

  /// One icon per app, front-to-back (cached per process: the switcher redraws on every key).
  var appIcons: [NSImage] {
    var seen = Set<Int32>()
    return stage.windows.compactMap { w in
      guard seen.insert(w.pid).inserted else { return nil }
      return IconCache.icon(for: w.pid)
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
  static let swipesKey = "swipesEnabled"
  static let swipeFingersKey = "swipeFingers"

  /// Horizontal 3- or 4-finger swipes for previous/next stage. Off by default: macOS uses
  /// these swipes too, and Stages can't stop it.
  static var swipesEnabled: Bool { UserDefaults.standard.bool(forKey: swipesKey) }
  static var swipeFingers: Int { UserDefaults.standard.integer(forKey: swipeFingersKey) == 4 ? 4 : 3 }

  static var modifier: Modifier {
    UserDefaults.standard.string(forKey: modifierKey).flatMap(Modifier.init) ?? .option
  }

  /// ⌃⌥←/→ (and ↑/↓) for previous/next stage.
  static var arrowsEnabled: Bool {
    UserDefaults.standard.object(forKey: arrowsKey) as? Bool ?? true
  }
}

enum IconCache {
  private static var icons: [Int32: NSImage] = [:]

  static func icon(for pid: Int32) -> NSImage? {
    if let icon = icons[pid] { return icon }
    let icon = NSRunningApplication(processIdentifier: pid)?.icon
    icons[pid] = icon
    return icon
  }
}
