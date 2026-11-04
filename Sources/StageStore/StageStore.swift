import Darwin
import Foundation
import StageReader

/// Stage records, matched to each committed snapshot and saved as JSON in
/// `~/Library/Application Support/Stages/stages.json`.
@MainActor
public final class StageStore {
  public private(set) var records: [UUID: StageRecord] = [:]
  /// Why each record on screen matched, from the last `reconcile` (debug view).
  public private(set) var lastReasons: [UUID: MatchReason] = [:]
  /// Set when the stored window IDs belonged to an earlier boot and were discarded.
  public private(set) var discardedStaleIDs = false
  /// Identity events (merge, split, revive, fingerprint match), record IDs only: no names or
  /// titles. The app sends them to the system log.
  public var onEvent: ((String) -> Void)?

  /// Uncustomised records survive this long off screen (other Spaces, short app quits).
  public static let unnamedTTL: TimeInterval = 6 * 60 * 60

  private let fileURL: URL?
  private let now: () -> Date
  private let bootTime: Date
  /// AX document path per window ID, filled in as the app resolves them.
  public private(set) var documents: [UInt32: String] = [:]

  public static var defaultDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Stages", isDirectory: true)
  }

  /// `directory: nil` keeps everything in memory (tests).
  public init(directory: URL? = StageStore.defaultDirectory, now: @escaping () -> Date = Date.init,
              bootTime: Date = StageStore.systemBootTime()) {
    self.now = now
    self.bootTime = bootTime
    self.fileURL = directory?.appendingPathComponent("stages.json")
    load()
  }

  /// Match the snapshot's stages to records, creating, merging and reviving records as needed.
  /// An impossible snapshot (see `implausibility`) is not learned from: the previous result is
  /// returned unchanged.
  public func reconcile(_ snapshot: StageSnapshot) -> [IdentifiedStage] {
    guard snapshot.isAvailable else { return [] }
    var snapshot = snapshot
    snapshot.stages = carveBorrowed(snapshot.stages)
    if let why = implausibility(snapshot.stages) {
      lastRejection = why
      onEvent?("rejected snapshot: \(why)")
      return lastResult
    }
    lastRejection = nil
    let result = learn(snapshot)
    lastResult = result
    return result
  }

  /// Why the last snapshot was ignored, if it was.
  public private(set) var lastRejection: String?
  private var lastResult: [IdentifiedStage] = []

  /// Activating an app can pull the windows of its *other* stages into the centre too (seen
  /// with "One at a Time", Magnus's setting; likely with "All at Once" as well). That's
  /// borrowing, not grouping: the centre stage is the one owning the
  /// frontmost window, and windows of other known stages made only of apps already in it go
  /// back to their own stage (listed with the strip, since that's where they return). A drag of
  /// a different app is still a merge. Cost: grouping two stages of the same app by hand isn't
  /// detected.
  func carveBorrowed(_ stages: [Stage]) -> [Stage] {
    var owner: [UInt32: UUID] = [:]
    for r in records.values where r.state == .active && r.membershipSeen { for id in r.windowIDs { owner[id] = r.id } }
    var result: [Stage] = []
    var carved: [Stage] = []
    for s in stages {
      guard s.position == .centre, !s.pooled, let front = s.windows.min(by: { $0.z < $1.z }) else { result.append(s); continue }
      let keeper = owner[front.id]
      // The stage's own windows: the keeper's, plus new ones no record knows yet.
      let home = s.windows.filter { owner[$0.id] == nil || owner[$0.id] == keeper }
      let homeApps = Set(home.map(\.owner))
      var byOwner: [UUID: [StageWindow]] = [:]
      for w in s.windows { if let o = owner[w.id], o != keeper { byOwner[o, default: []].append(w) } }
      var kept = s
      for (o, windows) in byOwner.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
        let ids = Set(windows.map(\.id))
        // Only same-app windows are borrowed; a different app joining is a real merge.
        guard !homeApps.isEmpty, Set(windows.map(\.owner)).isSubset(of: homeApps), records[o] != nil else { continue }
        kept.windows.removeAll { ids.contains($0.id) }
        let frame = windows.dropFirst().reduce(windows[0].frame) { $0.union($1.frame) }
        carved.append(Stage(position: .strip, order: 0, displayID: s.displayID, windows: windows.sorted { $0.z < $1.z },
                            frame: frame, appIconCount: nil, pooled: true))
      }
      result.append(kept)
    }
    // Borrowed stages sort after the strip, so the strip's own order is untouched.
    for (i, var c) in carved.enumerated() {
      c.order = (result.filter { $0.position == .strip && $0.displayID == c.displayID }.map(\.order).max() ?? -1) + 1 + i
      result.append(c)
    }
    return result
  }

  /// Stage Manager changes one step at a time: a new window, or one stage dragged into another.
  /// So a visible stage holding windows of three or more known records is a misread (Mission
  /// Control, a drag in flight, an animation), not a stage.
  func implausibility(_ stages: [Stage]) -> String? {
    var owner: [UInt32: UUID] = [:]
    // Active records only: a dormant record shares its windows with the record that absorbed it.
    for r in records.values where r.state == .active { for id in r.windowIDs { owner[id] = r.id } }
    for s in stages where !s.pooled && !s.authoritative {
      let owners = Set(s.windows.compactMap { owner[$0.id] })
      if owners.count >= 3 {
        return "\(s.position.rawValue) stage with windows of \(owners.count) records (\(s.windows.count) windows)"
      }
    }
    return nil
  }

  private func learn(_ snapshot: StageSnapshot) -> [IdentifiedStage] {
    let t = now()
    let stages = regroupPooled(snapshot.stages)
    let inputs = stages.map {
      StageMatcher.Input(windowIDs: $0.windowIDs, fingerprint: Fingerprint(stage: $0, documents: documents),
                         groupingVisible: !$0.pooled, authoritative: $0.authoritative)
    }
    var plan = StageMatcher.plan(stages: inputs, records: Array(records.values))
    claimWakes(&plan, inputs: inputs, at: t)
    lastLiveWindowIDs = snapshot.allWindowIDs

    for (loser, keeper) in plan.dormant {
      records[loser]?.state = .dormant
      records[loser]?.mergedInto = keeper
    }
    var result: [IdentifiedStage] = []
    var reasons: [UUID: MatchReason] = [:]
    for (i, stage) in stages.enumerated() {
      let (existing, reason) = plan.assignments[i]!
      var record = existing.flatMap { records[$0] } ?? StageRecord(windowIDs: [], createdAt: t)
      record.windowIDs = stage.windowIDs
      let fresh = inputs[i].fingerprint
      if reason == .woken, record.recipe == nil, !fresh.apps.isSuperset(of: record.fingerprint.apps) {
        record.recipe = record.fingerprint   // keep the full recipe until all its apps are back
      } else if let recipe = record.recipe, fresh.apps.isSuperset(of: recipe.apps) {
        record.recipe = nil                  // regrouped by hand: the stage is whole again
      }
      record.fingerprint = fresh
      record.state = .active
      record.mergedInto = nil
      record.lastSeen = t
      if !stage.pooled { record.membershipSeen = true }
      if stage.position == .centre { record.lastActive = t }
      records[record.id] = record
      reasons[record.id] = reason
      result.append(IdentifiedStage(record: record, stage: stage, reason: reason))
      if let event = Self.event(reason, record.id, windows: stage.windowIDs.count) { onEvent?(event) }
    }
    lastReasons = reasons
    prune(at: t, onScreen: Set(reasons.keys))   // first, so freed keys are reused at once
    assignAuto(onScreen: result.map(\.id))
    for i in result.indices { if let r = records[result[i].id] { result[i].record = r } }
    save()
    return result
  }

  private static func event(_ reason: MatchReason, _ id: UUID, windows: Int) -> String? {
    func short(_ u: UUID) -> String { String(u.uuidString.prefix(8)) }
    switch reason {
    case .windowIDs, .new: return nil
    case let .merged(absorbed, _): return "merge: \(short(id)) kept, absorbed \(absorbed.map(short).joined(separator: ",")) (\(windows) windows)"
    case let .keptInSplit(shared, of): return "split: \(short(id)) kept \(shared) of \(of) windows"
    case let .splitFrom(source): return "split: \(short(id)) new, off \(short(source))"
    case let .revived(shared, _): return "revive: \(short(id)) (\(shared) windows)"
    case let .fingerprint(score): return "fingerprint: \(short(id)) score \(Int(score * 100))"
    case .woken: return "woken: \(short(id)) (\(windows) windows)"
    }
  }

  // MARK: Sleeping and waking

  /// Window IDs present anywhere in the last capture.
  private var lastLiveWindowIDs: Set<UInt32> = []
  /// Records Stages just woke: their apps, and until when a new stage may claim them.
  private var wakes: [UUID: (apps: Set<String>, until: Date)] = [:]
  public static let wakeWindow: TimeInterval = 30

  /// Named stages whose windows have all closed (not on another Space: those windows still
  /// exist), most recently used first. They can be woken.
  public var sleeping: [StageRecord] {
    let onScreen = Set(lastReasons.keys)
    return records.values
      .filter { $0.name != nil && $0.state == .active && !onScreen.contains($0.id) && $0.windowIDs.isDisjoint(with: lastLiveWindowIDs) }
      .sorted { ($0.lastActive ?? $0.createdAt) > ($1.lastActive ?? $1.createdAt) }
  }

  /// Stages is about to relaunch this record's apps: the first new stage made only of those apps
  /// takes the record (and its name) back.
  public func expectWake(_ id: UUID) {
    guard let r = records[id] else { return }
    wakes[id] = (r.wakeRecipe.apps, now().addingTimeInterval(Self.wakeWindow))
  }

  private func claimWakes(_ plan: inout StageMatcher.Plan, inputs: [StageMatcher.Input], at t: Date) {
    wakes = wakes.filter { $0.value.until > t }
    guard !wakes.isEmpty else { return }
    let taken = Set(plan.assignments.values.compactMap(\.record))
    for i in inputs.indices.sorted() where plan.assignments[i]?.record == nil {
      let apps = inputs[i].fingerprint.apps
      guard !apps.isEmpty,
            let (id, _) = wakes.first(where: { !taken.contains($0.key) && apps.isSubset(of: $0.value.apps) })
      else { continue }
      plan.assignments[i] = (id, .woken)
      wakes[id] = nil
    }
  }

  /// Uncustomised records off screen for longer than `unnamedTTL` go; customised ones stay.
  private func prune(at t: Date, onScreen: Set<UUID>) {
    for (id, r) in records where !onScreen.contains(id) && !r.isCustomised && t.timeIntervalSince(r.lastSeen) > Self.unnamedTTL {
      records[id] = nil
    }
    // Dangling merge links.
    for (id, r) in records where r.mergedInto.map({ records[$0] == nil }) ?? false {
      records[id]?.mergedInto = nil
    }
  }

  /// Document paths found through Accessibility; used in fingerprints from the next reconcile.
  public func attachDocuments(_ docs: [UInt32: String]) {
    guard !docs.isEmpty else { return }
    documents.merge(docs) { _, new in new }
    for (id, r) in records {
      let found = r.windowIDs.compactMap { documents[$0] }
      if !found.isEmpty { records[id]?.fingerprint.documents.formUnion(found) }
    }
    save()
  }

  /// The reader can't see which overflow windows share a stage (they're all parked at one spot),
  /// so it reports one pooled stage per window. A stage only reaches overflow from the strip,
  /// where its members were visible: windows a record knew as one stage go back together.
  func regroupPooled(_ stages: [Stage]) -> [Stage] {
    var owner: [UInt32: UUID] = [:]
    let live = records.values.filter { $0.state == .active && $0.membershipSeen }
    for r in live.sorted(by: { ($0.lastActive ?? $0.createdAt) < ($1.lastActive ?? $1.createdAt) }) {
      for id in r.windowIDs { owner[id] = r.id }   // most recently active record wins a shared ID
    }
    var result: [Stage] = []
    var merged: [UUID: Int] = [:]   // record id -> index in result
    for s in stages {
      // Without history the grouping is unknown, and windows of one app can be in different
      // stages, so an unknown pooled window stays on its own.
      guard s.pooled, let wid = s.windows.first?.id, let rid = owner[wid] else { result.append(s); continue }
      if let i = merged[rid] {
        result[i].windows = (result[i].windows + s.windows).sorted { $0.z < $1.z }
        result[i].frame = result[i].frame.union(s.frame)
      } else {
        merged[rid] = result.count
        result.append(s)
      }
    }
    // Keep overflow order contiguous after merging.
    var next: [UInt32: Int] = [:]
    for i in result.indices where result[i].position == .overflow {
      result[i].order = next[result[i].displayID, default: 0]
      next[result[i].displayID, default: 0] += 1
    }
    return result
  }

  // MARK: Editing

  public func rename(_ id: UUID, to name: String?) {
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    update(id) { $0.name = (trimmed?.isEmpty ?? true) ? nil : trimmed }
  }

  public func setInk(_ id: UUID, _ ink: Ink?) { update(id) { $0.ink = ink; $0.autoInk = false } }

  /// Removes a record (and links to it). Named records are never pruned otherwise.
  public func forget(_ id: UUID) {
    records[id] = nil
    for (other, r) in records where r.mergedInto == id { records[other]?.mergedInto = nil }
    save()
  }

  /// Assigning a slot takes it away from whichever record had it (that one gets the next free
  /// key on the next snapshot, if it's on screen).
  public func setSlot(_ id: UUID, _ slot: String?) {
    let slot = slot?.lowercased()
    precondition(slot.map(SlotKeys.isValid) ?? true, "slot must be one of 1–9, 0, a–z")
    if let slot {
      for (other, r) in records where r.slot == slot && other != id { records[other]?.slot = nil }
    }
    update(id) { $0.slot = slot; $0.autoSlot = false }
  }

  /// Gives each on-screen record without one the lowest free slot key, and an ink: the one in
  /// least use on screen (ties in palette order). Both marked auto.
  private func assignAuto(onScreen ids: [UUID]) {
    var taken = Set(records.values.compactMap(\.slot))
    var inkUse: [Ink: Int] = Dictionary(uniqueKeysWithValues: Ink.allCases.map { ($0, 0) })
    for id in ids { if let ink = records[id]?.ink { inkUse[ink, default: 0] += 1 } }
    for id in ids {
      guard var r = records[id] else { continue }
      if r.slot == nil, let key = SlotKeys.all.first(where: { !taken.contains($0) }) {
        r.slot = key; r.autoSlot = true; taken.insert(key)
      }
      if r.ink == nil {
        let ink = Ink.allCases.min { (inkUse[$0]!, Ink.allCases.firstIndex(of: $0)!) < (inkUse[$1]!, Ink.allCases.firstIndex(of: $1)!) }!
        r.ink = ink; r.autoInk = true; inkUse[ink, default: 0] += 1
      }
      records[id] = r
    }
  }

  private func update(_ id: UUID, _ change: (inout StageRecord) -> Void) {
    guard var r = records[id] else { return }
    change(&r)
    records[id] = r
    save()
  }

  // MARK: Persistence

  private struct File: Codable {
    var version: Int
    /// Window IDs are only meaningful within one boot.
    var bootTime: Date?
    var records: [StageRecord]
  }

  private func load() {
    guard let fileURL, let data = try? Data(contentsOf: fileURL),
          let file = try? Self.decoder.decode(File.self, from: data) else { return }
    records = Dictionary(uniqueKeysWithValues: file.records.map { ($0.id, $0) })
    // After a reboot window IDs restart and can collide with old ones: match by fingerprint only.
    if let stored = file.bootTime, abs(stored.timeIntervalSince(bootTime)) > 2 {
      for id in records.keys { records[id]?.windowIDs = [] }
      discardedStaleIDs = true
    }
  }

  private func save() {
    guard let fileURL else { return }
    let file = File(version: 2, bootTime: bootTime, records: records.values.sorted { $0.createdAt < $1.createdAt })
    do {
      try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Self.encoder.encode(file).write(to: fileURL, options: .atomic)
    } catch {
      NSLog("Stages: couldn't save \(fileURL.path): \(error)")
    }
  }

  public static func systemBootTime() -> Date {
    var tv = timeval()
    var size = MemoryLayout<timeval>.size
    guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return .distantPast }
    return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
  }

  private static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    return e
  }()

  private static let decoder: JSONDecoder = {
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
  }()
}
