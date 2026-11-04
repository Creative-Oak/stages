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

/// What a stage looks like apart from its window IDs, for recognising it after its apps
/// relaunch or the Mac reboots (when every window ID is new).
public struct Fingerprint: Codable, Hashable, Sendable {
  /// Bundle IDs, or `name:<owner>` for processes without one.
  public var apps: Set<String>
  /// Distinct window titles, front-to-back, at most `maxTitles`.
  public var titles: [String]
  /// AX document paths/URLs, when Accessibility is granted.
  public var documents: Set<String>

  public static let maxTitles = 12

  public init(apps: Set<String> = [], titles: [String] = [], documents: Set<String> = []) {
    self.apps = apps; self.titles = titles; self.documents = documents
  }

  public init(stage: Stage, documents: [UInt32: String] = [:]) {
    apps = Set(stage.windows.map { $0.bundleID ?? "name:\($0.owner)" })
    var seen = Set<String>()
    titles = Array(stage.windows.compactMap { w -> String? in
      guard let t = w.title?.trimmingCharacters(in: .whitespaces), !t.isEmpty, seen.insert(t).inserted else { return nil }
      return t
    }.prefix(Self.maxTitles))
    self.documents = Set(stage.windows.compactMap { documents[$0.id] })
  }

  public var isEmpty: Bool { apps.isEmpty }

  /// 0…1. Zero unless the app sets are identical (the brief: "same bundle IDs + similar
  /// titles"); then titles and documents decide.
  public static func similarity(_ a: Fingerprint, _ b: Fingerprint) -> Double {
    guard !a.apps.isEmpty, a.apps == b.apps else { return 0 }
    var total = 0.5, weight = 0.5
    if !a.titles.isEmpty && !b.titles.isEmpty {
      total += 0.35 * titleSimilarity(a.titles, b.titles); weight += 0.35
    }
    if !a.documents.isEmpty && !b.documents.isEmpty {
      total += 0.15 * jaccard(a.documents, b.documents); weight += 0.15
    }
    return total / weight
  }

  /// For each title in `a`, its best token overlap with a title in `b`, averaged.
  static func titleSimilarity(_ a: [String], _ b: [String]) -> Double {
    let tb = b.map(tokens)
    let scores = a.map(tokens).map { ta in tb.map { jaccard(ta, $0) }.max() ?? 0 }
    return scores.reduce(0, +) / Double(max(1, scores.count))
  }

  static func tokens(_ s: String) -> Set<String> {
    Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
  }
}

func jaccard<T>(_ a: Set<T>, _ b: Set<T>) -> Double {
  let union = a.union(b).count
  return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
}

public struct StageRecord: Codable, Hashable, Identifiable, Sendable {
  public enum State: String, Codable, Sendable {
    case active
    /// Absorbed into another record when two stages were grouped (`mergedInto`).
    case dormant
  }

  public var id: UUID
  public var name: String?
  public var ink: Ink?
  /// 1–9, unique across records.
  public var slot: Int?
  /// The stage's window IDs as last seen.
  public var windowIDs: Set<UInt32>
  public var fingerprint: Fingerprint
  public var state: State
  public var mergedInto: UUID?
  /// True once the record's windows were seen together in the centre or strip, where grouping is
  /// visible. Only such records may regroup pooled overflow windows.
  public var membershipSeen: Bool
  public var lastActive: Date?
  /// Last time the record matched a stage on screen.
  public var lastSeen: Date
  public var createdAt: Date

  public init(id: UUID = UUID(), name: String? = nil, ink: Ink? = nil, slot: Int? = nil,
              windowIDs: Set<UInt32>, fingerprint: Fingerprint = Fingerprint(), state: State = .active,
              mergedInto: UUID? = nil, membershipSeen: Bool = false, lastActive: Date? = nil, lastSeen: Date? = nil,
              createdAt: Date = Date()) {
    self.id = id; self.name = name; self.ink = ink; self.slot = slot
    self.windowIDs = windowIDs; self.fingerprint = fingerprint; self.state = state; self.mergedInto = mergedInto
    self.membershipSeen = membershipSeen
    self.lastActive = lastActive; self.lastSeen = lastSeen ?? createdAt; self.createdAt = createdAt
  }

  /// Named, inked or slotted: something the person chose, so never pruned automatically.
  public var isCustomised: Bool { name != nil || ink != nil || slot != nil }

  // Version-1 files (M1) have no fingerprint, state, mergedInto or lastSeen.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    name = try c.decodeIfPresent(String.self, forKey: .name)
    ink = try c.decodeIfPresent(Ink.self, forKey: .ink)
    slot = try c.decodeIfPresent(Int.self, forKey: .slot)
    windowIDs = try c.decode(Set<UInt32>.self, forKey: .windowIDs)
    fingerprint = try c.decodeIfPresent(Fingerprint.self, forKey: .fingerprint) ?? Fingerprint()
    state = try c.decodeIfPresent(State.self, forKey: .state) ?? .active
    mergedInto = try c.decodeIfPresent(UUID.self, forKey: .mergedInto)
    // Records from before this field may hold memberships the old reader got wrong.
    membershipSeen = try c.decodeIfPresent(Bool.self, forKey: .membershipSeen) ?? false
    lastActive = try c.decodeIfPresent(Date.self, forKey: .lastActive)
    createdAt = try c.decode(Date.self, forKey: .createdAt)
    lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen) ?? lastActive ?? createdAt
  }
}

/// Why a stage got the record it did. Shown in the debug window.
public enum MatchReason: Hashable, Sendable {
  /// Shared window IDs.
  case windowIDs(shared: Int, of: Int, jaccard: Double)
  /// The stage holds most of several records' windows (they were grouped): this one was kept,
  /// the others went dormant.
  case merged(absorbed: [UUID], shared: Int)
  /// The record's windows went to several stages: this, the largest part, kept it.
  case keptInSplit(shared: Int, of: Int)
  /// A dormant (merged-away) record whose windows came back as their own stage.
  case revived(shared: Int, of: Int)
  /// No window IDs survived (relaunch or reboot); recognised by apps, titles, documents.
  case fingerprint(score: Double)
  /// Split off another record's stage.
  case splitFrom(UUID)
  /// The first stage holding one of a sleeping record's apps after Stages woke it.
  case woken
  case new

  public var summary: String {
    func pct(_ d: Double) -> String { "\(Int((d * 100).rounded())) %" }
    switch self {
    case let .windowIDs(shared, of, j): return "window IDs: \(shared) of \(of) shared (Jaccard \(pct(j)))"
    case let .merged(absorbed, shared): return "merged \(absorbed.count + 1) stages; kept this record (\(shared) windows shared)"
    case let .keptInSplit(shared, of): return "split: kept by the larger part (\(shared) of \(of) windows)"
    case let .revived(shared, of): return "revived after a merge (\(shared) of \(of) windows)"
    case let .fingerprint(score): return "fingerprint: apps and titles \(pct(score)) similar"
    case .splitFrom: return "new: split off another stage"
    case .woken: return "woken from sleep"
    case .new: return "new stage"
    }
  }
}

/// A stage from the latest snapshot, with the record it was matched to and why.
public struct IdentifiedStage: Hashable, Identifiable, Sendable {
  public var record: StageRecord
  public var stage: Stage
  public var reason: MatchReason
  public var id: UUID { record.id }
}
