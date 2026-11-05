import AppKit
import os
import StageReader

/// Polls a `WindowSource`, runs the reader, and publishes stable snapshots.
///
/// Polls fast (250 ms) while things are changing or after an app activation, and backs off
/// when nothing has changed for a while.
@MainActor
public final class StagePoller {
  public struct Pacing: Sendable {
    public var fast: Duration = .milliseconds(250)
    /// Right after an app activation (a stage switch is likely animating), poll faster so the
    /// two equal reads the gate needs come soon after the animation ends.
    public var burst: Duration = .milliseconds(100)
    public var burstFor: Duration = .seconds(2)
    public var idle: Duration = .seconds(1)
    public var deepIdle: Duration = .seconds(2)
    /// Quiet time before dropping to `idle`, then `deepIdle`.
    public var idleAfter: Duration = .seconds(5)
    public var deepIdleAfter: Duration = .seconds(60)
    public init() {}
  }

  public private(set) var latest: StageSnapshot?
  /// For the last commit: time from the first read that differed from the committed state to
  /// the commit, and reads taken.
  public private(set) var lastSettle: (duration: Duration, reads: Int)?
  /// Called on the main actor with each committed (stable, changed) snapshot.
  public var onCommit: ((StageSnapshot) -> Void)?
  /// Called with every read, stable or not (debug views).
  public var onRead: ((StageSnapshot) -> Void)?

  private let source: WindowSource
  private let pacing: Pacing
  private var gate = StabilityGate()
  private var task: Task<Void, Never>?
  private var lastRawSignature = ""
  private var lastChange = ContinuousClock.now
  /// First read since the last commit whose snapshot differed from it, and reads since then.
  private var unsettledSince: ContinuousClock.Instant?
  private var readsSinceChange = 0
  private var lastPoke: ContinuousClock.Instant?
  private var observers: [NSObjectProtocol] = []
  private var wake: CheckedContinuation<Void, Never>?

  public init(source: WindowSource = LiveWindowSource(), pacing: Pacing = Pacing()) {
    self.source = source
    self.pacing = pacing
  }

  public func start() {
    guard task == nil else { return }
    // Activations (a stage switch), launches and quits (a stage appears or goes) mean a change.
    let center = NSWorkspace.shared.notificationCenter
    observers = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                 NSWorkspace.didTerminateApplicationNotification].map { name in
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.poke() }
      }
    }
    task = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let delay = self.tick()
        await self.sleep(delay)
      }
    }
  }

  public func stop() {
    task?.cancel(); task = nil
    observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    observers = []
    poke()
  }

  /// Read now and go back to fast polling.
  public func poke() {
    lastChange = .now
    lastPoke = .now
    wake?.resume(); wake = nil
  }

  /// One poll. Returns how long to wait before the next.
  @discardableResult
  public func tick() -> Duration {
    let capture = source.capture()
    let rawSig = Self.rawSignature(capture)
    if rawSig != lastRawSignature { lastChange = .now; lastRawSignature = rawSig }

    let snapshot = StageReader.read(capture)
    onRead?(snapshot)
    readsSinceChange += 1
    if let committed = gate.feed(snapshot) {
      lastSettle = unsettledSince.map { (ContinuousClock.now - $0, readsSinceChange) }
      unsettledSince = nil
      latest = committed
      onCommit?(committed)
    } else if gate.isSettling, unsettledSince == nil {
      unsettledSince = .now; readsSinceChange = 1
    }

    let next = nextDelay()
    Self.log.debug("tick: next in \(next, privacy: .public), settling \(self.gate.isSettling)")
    return next
  }

  private static let log = Logger(subsystem: "dk.creativeoak.stages", category: "poller")

  private func nextDelay() -> Duration {
    let quiet = ContinuousClock.now - lastChange
    if let lastPoke, ContinuousClock.now - lastPoke < pacing.burstFor { return pacing.burst }
    if gate.isSettling || quiet < pacing.idleAfter { return pacing.fast }
    return quiet < pacing.deepIdleAfter ? pacing.idle : pacing.deepIdle
  }

  private var sleepGeneration = 0

  private func sleep(_ d: Duration) async {
    sleepGeneration += 1
    let generation = sleepGeneration
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      wake = c
      Task { [weak self] in
        try? await Task.sleep(for: d)
        // A poke may already have ended this sleep and a newer one begun.
        guard let self, self.sleepGeneration == generation else { return }
        self.wake?.resume(); self.wake = nil
      }
    }
  }

  /// Cheap structural change detector: which normal (layer 0) windows exist and which are on
  /// screen. That's what changes when a stage forms, splits or goes. Titles and geometry are left
  /// out: apps retitle windows constantly (terminal spinners, streaming chat, page loads) and
  /// windows move and resize while you work, and either kept polling at the fast rate for as long
  /// as you used the Mac. Switches are covered by the activation poke; a moved or retitled window
  /// still shows up on the next idle read, and the gate polls fast until that settles.
  static func rawSignature(_ c: WindowCapture) -> String {
    var h = Hasher()
    for w in c.windows where w.layer == 0 { h.combine(w.id); h.combine(w.onscreen) }
    h.combine(c.stageManagerEnabled); h.combine(c.screenRecordingGranted)
    return String(h.finalize())
  }
}
