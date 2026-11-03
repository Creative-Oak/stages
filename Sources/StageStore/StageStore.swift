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

  /// Uncustomised records survive this long off screen (other Spaces, short app quits).
  public static let unnamedTTL: TimeInterval = 6 * 60 * 60

  private let fileURL: URL?
  private let now: () -> Date
  private let bootTime: Date
  /// AX document path per window ID, filled in as the app resolves them.
  private var documents: [UInt32: String] = [:]

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
  public func reconcile(_ snapshot: StageSnapshot) -> [IdentifiedStage] {
    guard snapshot.isAvailable else { return [] }
    let t = now()
    let stages = regroupPooled(snapshot.stages)
    let inputs = stages.map { StageMatcher.Input(windowIDs: $0.windowIDs, fingerprint: Fingerprint(stage: $0, documents: documents)) }
    let plan = StageMatcher.plan(stages: inputs, records: Array(records.values))

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
      record.fingerprint = inputs[i].fingerprint
      record.state = .active
      record.mergedInto = nil
      record.lastSeen = t
      if !stage.pooled { record.membershipSeen = true }
      if stage.position == .centre { record.lastActive = t }
      records[record.id] = record
      reasons[record.id] = reason
      result.append(IdentifiedStage(record: record, stage: stage, reason: reason))
    }
    lastReasons = reasons
    prune(at: t, onScreen: Set(reasons.keys))
    save()
    return result
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
    var merged: [String: Int] = [:]   // record id or pool hint -> index in result
    for s in stages {
      guard s.pooled, let wid = s.windows.first?.id else { result.append(s); continue }
      // History first; without it, the reader's hint (same app, under All at Once).
      guard let key = owner[wid].map({ "record:\($0)" }) ?? s.poolHint.map({ "hint:\($0)" }) else {
        result.append(s); continue
      }
      let rid = key
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

  public func setInk(_ id: UUID, _ ink: Ink?) { update(id) { $0.ink = ink } }

  /// Assigning a slot takes it away from whichever record had it.
  public func setSlot(_ id: UUID, _ slot: Int?) {
    precondition(slot.map { (1...9).contains($0) } ?? true, "slot must be 1–9")
    if let slot {
      for (other, r) in records where r.slot == slot && other != id { records[other]?.slot = nil }
    }
    update(id) { $0.slot = slot }
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
