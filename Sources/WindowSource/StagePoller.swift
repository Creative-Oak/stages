import AppKit
import StageReader

/// Polls a `WindowSource`, runs the reader, and publishes stable snapshots.
///
/// Polls fast (250 ms) while things are changing or after an app activation, and backs off
/// when nothing has changed for a while.
@MainActor
public final class StagePoller {
  public struct Pacing: Sendable {
    public var fast: Duration = .milliseconds(250)
    public var idle: Duration = .seconds(1)
    public var deepIdle: Duration = .seconds(2)
    /// Quiet time before dropping to `idle`, then `deepIdle`.
    public var idleAfter: Duration = .seconds(5)
    public var deepIdleAfter: Duration = .seconds(60)
    public init() {}
  }

  public private(set) var latest: StageSnapshot?
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
  private var observer: NSObjectProtocol?
  private var wake: CheckedContinuation<Void, Never>?

  public init(source: WindowSource = LiveWindowSource(), pacing: Pacing = Pacing()) {
    self.source = source
    self.pacing = pacing
  }

  public func start() {
    guard task == nil else { return }
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.poke() }
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
    if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    observer = nil
    poke()
  }

  /// Read now and go back to fast polling.
  public func poke() {
    lastChange = .now
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
    if let committed = gate.feed(snapshot) {
      latest = committed
      onCommit?(committed)
    }

    let quiet = ContinuousClock.now - lastChange
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

  /// Cheap change detector over the raw list (ids, layers, bounds, onscreen).
  static func rawSignature(_ c: WindowCapture) -> String {
    var h = Hasher()
    for w in c.windows { h.combine(w.id); h.combine(w.layer); h.combine(w.bounds); h.combine(w.onscreen); h.combine(w.name) }
    h.combine(c.stageManagerEnabled); h.combine(c.screenRecordingGranted)
    return String(h.finalize())
  }
}
