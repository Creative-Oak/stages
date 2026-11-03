import Foundation
import StageReader

/// The section inks from Lodestone.
public enum Ink: String, CaseIterable, Codable, Sendable {
  case teal, ultramarine, oxide, violet, grass, sienna, chrome

  /// sRGB hex, from the design system's section palette.
  public var hex: UInt32 {
    switch self {
    case .teal: 0x2F7F7A
    case .ultramarine: 0x2C3F9E
    case .oxide: 0xD1612F
    case .violet: 0x6E4AA0
    case .grass: 0x5F9A4A
    case .sienna: 0x8A5A3B
    case .chrome: 0xE3B72B
    }
  }
}

public struct StageRecord: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var name: String?
  public var ink: Ink?
  /// 1–9, unique across records.
  public var slot: Int?
  /// The stage's window IDs as last seen.
  public var windowIDs: Set<UInt32>
  public var lastActive: Date?
  public var createdAt: Date

  public init(id: UUID = UUID(), name: String? = nil, ink: Ink? = nil, slot: Int? = nil,
              windowIDs: Set<UInt32>, lastActive: Date? = nil, createdAt: Date = Date()) {
    self.id = id; self.name = name; self.ink = ink; self.slot = slot
    self.windowIDs = windowIDs; self.lastActive = lastActive; self.createdAt = createdAt
  }

  /// Named, inked or slotted: something the person chose, so never pruned automatically.
  public var isCustomised: Bool { name != nil || ink != nil || slot != nil }
}

/// A stage from the latest snapshot, with the record it was matched to.
public struct IdentifiedStage: Hashable, Identifiable, Sendable {
  public var record: StageRecord
  public var stage: Stage
  public var id: UUID { record.id }
}

public enum StageMatcher {
  public static let threshold = 0.3

  public static func jaccard(_ a: Set<UInt32>, _ b: Set<UInt32>) -> Double {
    let union = a.union(b).count
    return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
  }

  /// Assigns each stage (by index) at most one record and each record at most one stage,
  /// highest Jaccard overlap on window IDs first. Pairs below `threshold` stay unmatched.
  public static func match(stages: [Set<UInt32>], records: [StageRecord]) -> [Int: UUID] {
    var pairs: [(score: Double, stage: Int, record: UUID)] = []
    for (i, ids) in stages.enumerated() {
      for r in records {
        let s = jaccard(ids, r.windowIDs)
        if s >= threshold { pairs.append((s, i, r.id)) }
      }
    }
    // Ties: prefer customised, then older records, so a name survives an ambiguous moment.
    let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    pairs.sort { a, b in
      if a.score != b.score { return a.score > b.score }
      let ra = byID[a.record]!, rb = byID[b.record]!
      if ra.isCustomised != rb.isCustomised { return ra.isCustomised }
      return ra.createdAt < rb.createdAt
    }
    var result: [Int: UUID] = [:]
    var used = Set<UUID>()
    for p in pairs where result[p.stage] == nil && !used.contains(p.record) {
      result[p.stage] = p.record
      used.insert(p.record)
    }
    return result
  }
}

/// Stage records, matched to each committed snapshot and saved as JSON.
///
/// M1 scope: window-ID matching only. Fingerprint fallback, merge/split and pruning rules
/// beyond "drop uncustomised records that aren't on screen" come in M2.
@MainActor
public final class StageStore {
  public private(set) var records: [UUID: StageRecord] = [:]
  private let fileURL: URL?
  private let now: () -> Date

  public static var defaultDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Stages", isDirectory: true)
  }

  /// `directory: nil` keeps everything in memory (tests).
  public init(directory: URL? = StageStore.defaultDirectory, now: @escaping () -> Date = Date.init) {
    self.now = now
    self.fileURL = directory?.appendingPathComponent("stages.json")
    load()
  }

  /// Match the snapshot's stages to records, creating records for new stages.
  public func reconcile(_ snapshot: StageSnapshot) -> [IdentifiedStage] {
    guard snapshot.isAvailable else { return [] }
    let stages = snapshot.stages
    let matches = StageMatcher.match(stages: stages.map(\.windowIDs), records: Array(records.values))
    var seen = Set<UUID>()
    var result: [IdentifiedStage] = []
    for (i, stage) in stages.enumerated() {
      var record = matches[i].flatMap { records[$0] } ?? StageRecord(windowIDs: [], createdAt: now())
      record.windowIDs = stage.windowIDs
      if stage.position == .centre { record.lastActive = now() }
      records[record.id] = record
      seen.insert(record.id)
      result.append(IdentifiedStage(record: record, stage: stage))
    }
    // Records not on screen: keep the customised ones (with their last window IDs), drop the rest.
    for (id, r) in records where !seen.contains(id) && !r.isCustomised { records[id] = nil }
    save()
    return result
  }

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
    var version = 1
    var records: [StageRecord]
  }

  private func load() {
    guard let fileURL, let data = try? Data(contentsOf: fileURL),
          let file = try? Self.decoder.decode(File.self, from: data) else { return }
    records = Dictionary(uniqueKeysWithValues: file.records.map { ($0.id, $0) })
  }

  private func save() {
    guard let fileURL else { return }
    let file = File(records: records.values.sorted { $0.createdAt < $1.createdAt })
    do {
      try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Self.encoder.encode(file).write(to: fileURL, options: .atomic)
    } catch {
      NSLog("Stages: couldn't save \(fileURL.path): \(error)")
    }
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
