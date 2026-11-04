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
  /// The app a switch is making frontmost, and when the switch started (to log how long until
  /// macOS reports it frontmost: the moment the switch is felt).
  @ObservationIgnored private var awaitingActivation: (pid: Int32, since: ContinuousClock.Instant)?

  /// Apps by last activation, most recent first (orders the in-stage switcher; CG z-order under
  /// Stage Manager doesn't reliably put the active app's window in front).
  @ObservationIgnored private var appRecency: [Int32] = []

  private func activated(_ pid: Int32?) {
    activatedAt = .now
    if let pid { appRecency.removeAll { $0 == pid }; appRecency.insert(pid, at: 0); if appRecency.count > 64 { appRecency.removeLast() } }
    if let a = awaitingActivation, a.pid == pid {
      Self.log.notice("switch: frontmost after \(Self.ms(ContinuousClock.now - a.since)) ms")
      awaitingActivation = nil
    }
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
    // Stages switched to by other means (Dock, clicking the strip) join the recent list once
    // confirmed; not while a switch of ours is in flight (that snapshot may predate it).
    if pendingTarget == nil, let c = committedCentre, recent.first != c { noteUsed(c) }
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
    onCommitted?()
    prewarmSwitching()   // links AX windows to CG windows where certain (cheap when nothing changed)
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
  func setSlot(_ id: UUID, _ slot: String?) { store.setSlot(id, slot); refresh() }
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
        return report(records.contains { $0.slot == n } ? "The stage in slot \(n.uppercased()) isn't open." : "No stage has slot \(n.uppercased()).")
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
    guard record.wakeRecipe.apps.count == 1 else {
      return report("\(record.name ?? "That stage") has \(record.wakeRecipe.apps.count) apps; Stages can only wake single-app stages, since Stage Manager would split the rest into separate stages.")
    }
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

  /// Recently used stages, most recent first, updated the moment a switch starts (snapshots
  /// confirm a switch only after Stage Manager's ~1 s animation, so their order lags; a quick
  /// second ⌘⇥ would otherwise target the stage you're already going to).
  @ObservationIgnored private var recent: [UUID] = []
  /// The stage a switch in flight is going to.
  @ObservationIgnored private var pendingTarget: UUID?

  private func noteUsed(_ id: UUID) {
    recent.removeAll { $0 == id }
    recent.insert(id, at: 0)
    if recent.count > 64 { recent.removeLast(recent.count - 64) }
  }

  /// While a switch is in flight its target is "current" and the stage it left is most recent.
  var candidates: [Candidate] { candidates(current: pendingTarget ?? committedCentre) }

  /// The switcher's list as it opens. The committed snapshot can be a second behind (a window just
  /// closed; Stage Manager still animating), so this takes a quick read of its own (window list
  /// only, no AX: a few ms) and leaves out stages none of whose windows Stage Manager shows any
  /// more. That catches windows an app keeps after closing them (Calendar does: ordered out, so
  /// they still exist). The current stage is the one just switched to, else the one in the centre
  /// now, else the frontmost app's.
  func switcherCandidates() -> [Candidate] {
    let fresh = StageReader.read(LiveWindowSource(readTiles: false).capture())
    let shown: Set<UInt32>
    if fresh.isAvailable {
      shown = Set(fresh.stages.flatMap { $0.windows.map(\.id) })
    } else {
      shown = Self.existingWindows(stages.flatMap { $0.stage.windows.map(\.id) })
    }
    let gone = Set(stages.filter { s in !s.stage.windows.contains { shown.contains($0.id) } }.map(\.id))
    let freshFront = fresh.stages.first { $0.position == .centre }?.windows.min(by: { $0.z < $1.z })?.id
    let freshCentre = freshFront.flatMap { id in stages.first { $0.stage.windows.contains { $0.id == id } }?.id }
    var current = pendingTarget ?? provisionalCurrent ?? freshCentre ?? committedCentre
    if current.map(gone.contains) ?? true { current = frontmostStage(excluding: gone) }
    return candidates(current: current).filter { !gone.contains($0.id) }
  }

  /// The in-stage switcher's list (modifier + `): the current stage's windows front to back, from
  /// a quick read of its own (so it's right even mid-animation or just after a close), as
  /// switcher candidates (most recent = front, so the session opens on the previous window).
  func stageWindowCandidates() -> (candidates: [Candidate], windows: [UUID: StageWindow]) {
    let fresh = StageReader.read(LiveWindowSource(readTiles: false).capture())
    guard fresh.isAvailable, let centre = fresh.stages.first(where: { $0.position == .centre }) else { return ([], [:]) }
    let now = Date()
    var windows: [UUID: StageWindow] = [:]
    // Frontmost app first, then apps by last activation; within an app, front to back.
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    func rank(_ pid: Int32) -> Int { pid == front ? -1 : (appRecency.firstIndex(of: pid) ?? Int.max) }
    let ordered = centre.windows.sorted { (rank($0.pid), $0.z) < (rank($1.pid), $1.z) }
    let candidates = ordered.enumerated().map { i, w -> Candidate in
      let id = Self.uuid(forWindow: w.id)
      windows[id] = w
      return Candidate(id: id, name: w.owner, apps: [w.owner], titles: [w.title].compactMap { $0 },
                       position: i == 0 ? .centre : .strip, order: i, slot: nil,
                       lastActive: now.addingTimeInterval(-Double(i)), createdAt: now)
    }
    return (candidates, windows)
  }

  private static func uuid(forWindow id: UInt32) -> UUID {
    UUID(uuidString: String(format: "57A6E500-0000-4000-8000-%012X", id))!
  }

  // MARK: Quit and close from the switcher (Q / W, as in macOS's ⌘⇥)

  /// W on a stage: close its windows.
  func closeStage(_ id: UUID) {
    guard let s = stages.first(where: { $0.id == id }) else { return }
    StageActivator.close(s.stage.windows)
    poller.poke()
  }

  /// Q on a stage: quit its apps, except an app that also has windows in other stages, whose
  /// windows here are closed instead (quitting it would empty those stages too).
  func quitStage(_ id: UUID) {
    guard let s = stages.first(where: { $0.id == id }) else { return }
    var close: [StageWindow] = []
    for pid in Set(s.stage.windows.map(\.pid)) {
      let elsewhere = stages.contains { $0.id != id && $0.stage.windows.contains { $0.pid == pid } }
      if elsewhere { close += s.stage.windows.filter { $0.pid == pid } }
      else { NSRunningApplication(processIdentifier: pid)?.terminate() }
    }
    StageActivator.close(close)
    poller.poke()
  }

  /// W in the in-stage switcher: close that window. Q: quit its app.
  func closeWindow(_ w: StageWindow) { StageActivator.close([w]); poller.poke() }
  func quitApp(of w: StageWindow) { NSRunningApplication(processIdentifier: w.pid)?.terminate(); poller.poke() }

  /// A stage's app icons, most recently used app first (then front to back).
  func appIcons(_ stage: IdentifiedStage) -> [NSImage] {
    func rank(_ pid: Int32) -> Int { appRecency.firstIndex(of: pid) ?? Int.max }
    var seen = Set<Int32>()
    return stage.stage.windows.sorted { (rank($0.pid), $0.z) < (rank($1.pid), $1.z) }.compactMap { w in
      guard seen.insert(w.pid).inserted else { return nil }
      return IconCache.icon(for: w.pid, bundleID: w.bundleID)
    }
  }

  /// Bring one window of the current stage forward (the in-stage switcher). As with ⌘⇥: an app
  /// whose windows are all in this stage is made frontmost first (the instant part), then the
  /// window is raised; an app with windows in other stages gets the window raised first, so
  /// Stage Manager stays on this stage.
  func focusWindow(_ window: StageWindow) {
    let elsewhere = stages.contains { s in s.stage.position != .centre && s.stage.windows.contains { $0.pid == window.pid } }
    let started = ContinuousClock.now
    awaitingActivation = (window.pid, started)
    Task { _ = await StageActivator.raise(window, appInOneStage: !elsewhere) }
  }

  /// Called after each committed snapshot (the open switcher refreshes).
  @ObservationIgnored var onCommitted: (() -> Void)?

  /// Which of these CG windows still exist (a cheap lookup of just these IDs).
  private static func existingWindows(_ ids: [UInt32]) -> Set<UInt32> {
    guard !ids.isEmpty else { return [] }
    var values: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
    guard let array = CFArrayCreate(kCFAllocatorDefault, &values, values.count, nil),
          let info = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]]
    else { return Set(ids) }   // can't tell: assume they all do
    return Set(info.compactMap { ($0[kCGWindowNumber as String] as? Int).map { UInt32($0) } })
  }

  /// The stage holding the frontmost app's front window.
  private func frontmostStage(excluding gone: Set<UUID>) -> UUID? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
    let mine = stages.filter { !gone.contains($0.id) }
      .flatMap { s in s.stage.windows.filter { $0.pid == pid }.map { (window: $0.id, stage: s.id) } }
    guard let first = mine.first else { return nil }
    if Set(mine.map(\.stage)).count == 1 { return first.stage }
    // Several stages of this app: the one with its frontmost on-screen window.
    let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for d in onScreen {
      guard let n = d[kCGWindowNumber as String] as? Int else { continue }
      if let hit = mine.first(where: { $0.window == UInt32(n) }) { return hit.stage }
    }
    return first.stage
  }

  private func candidates(current currentID: UUID?) -> [Candidate] {
    let rank = Dictionary(uniqueKeysWithValues: recent.enumerated().map { ($1, $0) })
    let now = Date()
    return stages.map { s in
      let position: Candidate.Position =
        s.id == currentID ? .centre :
        s.stage.position == .centre ? .strip : Candidate.Position(s.stage.position)
      let lastActive = rank[s.id].map { now.addingTimeInterval(-Double($0)) } ?? s.record.lastActive.map { min($0, now.addingTimeInterval(-1000)) }
      return Candidate(id: s.id, name: s.record.name, apps: s.stage.owners, titles: s.windowTitles,
                       position: position, order: s.stage.order, slot: s.record.slot,
                       lastActive: lastActive, createdAt: s.record.createdAt)
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
  /// Only the newest switch may retry or report; older ones stop when superseded.
  @ObservationIgnored private var switchGeneration = 0

  /// Raise the stage's most recent window, then check the next snapshots for the stage in the
  /// centre; retry once, then report.
  func switchTo(_ id: UUID) {
    guard let stage = stages.first(where: { $0.id == id }), let window = stage.stage.windows.min(by: { $0.z < $1.z }) else { return }
    switchGeneration += 1
    let generation = switchGeneration
    guard committedCentre != id || pendingTarget != nil else { provisionalCurrent = nil; return }
    if let from = pendingTarget ?? committedCentre, from != id { noteUsed(from) }
    noteUsed(id)
    let inFlight = pendingTarget   // an earlier switch's stage may still land; that's no evidence
    pendingTarget = id
    provisionalCurrent = id
    poller.poke()
    let started = ContinuousClock.now
    Task { [weak self] in
      guard let self else { return }
      var wrongWindow = false
      for attempt in 1...2 {
        guard self.switchGeneration == generation else { return }
        let leaving = self.committedCentre
        let inOneStage = self.stages.filter { s in s.stage.windows.contains { $0.pid == window.pid } }.count <= 1
        self.awaitingActivation = (window.pid, started)
        // Same-titled windows of this app in front of the target (z-order), for the last-resort guess.
        let ahead = self.stages.flatMap(\.stage.windows)
          .filter { $0.pid == window.pid && $0.title == window.title && $0.z < window.z }.map(\.id)
        let outcome = await StageActivator.raise(window, appInOneStage: inOneStage, aheadSameTitle: ahead, retry: wrongWindow)
        Self.log.notice("switch: raise took \(Self.ms(ContinuousClock.now - started)) ms (attempt \(attempt))")
        switch outcome {
        case .notTrusted:
          self.pendingTarget = nil
          self.switchProblem = "Switching needs Accessibility permission."
          return
        case let .failed(why):
          Self.log.notice("switch: attempt \(attempt) failed: \(why, privacy: .public)")
        case .raised, .appOnly:
          switch await self.waitForCentre(id, from: [leaving, inFlight], pid: window.pid, timeout: .milliseconds(1500)) {
          case .reached:
            guard self.switchGeneration == generation else { return }
            self.pendingTarget = nil
            self.switchProblem = nil
            // The stage holds only this window of the app: the AX window raised is this one.
            if outcome == .raised, stage.stage.windows.filter({ $0.pid == window.pid }).count == 1 {
              StageActivator.confirm(window.id)
            }
            Self.log.notice("switch: reached centre on attempt \(attempt) after \(Self.ms(ContinuousClock.now - started)) ms (\(outcome == .raised ? "window raised" : "app only", privacy: .public))")
            return
          case .otherStageOfApp:
            // Same-titled windows: the raise picked another window of this app. Try another one now.
            wrongWindow = true
            Self.log.notice("switch: attempt \(attempt) brought another stage of the same app")
          case .timeout:
            Self.log.notice("switch: not in centre after attempt \(attempt)")
          }
        }
      }
      guard self.switchGeneration == generation else { return }
      self.pendingTarget = nil
      self.switchProblem = "Couldn't bring \(stage.title) to the centre."
      NSSound.beep()
    }
  }

  /// Look up AX windows for every stage's most recent window, so a switch needn't (called when
  /// the switcher opens).
  func prewarmSwitching() {
    let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let focused = stages.filter { $0.stage.position == .centre }.flatMap(\.stage.windows)
      .filter { $0.pid == frontPid }.min(by: { $0.z < $1.z })
    StageActivator.learn(stages.flatMap(\.stage.windows), focused: focused)
  }

  static func ms(_ d: Duration) -> Int {
    Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
  }

  private enum CentreWait { case reached, otherStageOfApp, timeout }

  /// Waits for `id` in the centre. A different stage of the same app arriving instead (not one
  /// in `from`: the stage the attempt left, an earlier switch's target) means the wrong one of
  /// its windows was raised. A timeout means only "slow".
  private func waitForCentre(_ id: UUID, from: [UUID?], pid: Int32, timeout: Duration) async -> CentreWait {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if let c = committedCentre {
        if c == id { return .reached }
        if !from.contains(c), stages.first(where: { $0.id == c })?.stage.windows.contains(where: { $0.pid == pid }) == true {
          return .otherStageOfApp
        }
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return committedCentre == id ? .reached : .timeout
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
      return IconCache.icon(for: w.pid, bundleID: w.bundleID)
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

  static func icon(for pid: Int32, bundleID: String? = nil) -> NSImage? {
    if let icon = icons[pid] { return icon }
    // An app that just quit (System Settings does when its last window closes) has no running
    // process left to ask: use its bundle's icon.
    let icon = NSRunningApplication(processIdentifier: pid)?.icon
      ?? bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.map { NSWorkspace.shared.icon(forFile: $0.path) }
    icons[pid] = icon
    return icon
  }
}
