import Foundation

/// Pure matching of snapshot stages to records. See `plan`.
public enum StageMatcher {
  /// Minimum window-ID Jaccard for a plain match (a split's larger part also qualifies; see below).
  public static let idThreshold = 0.3
  /// A record counts as "inside" a stage when more than this share of its windows are there.
  public static let containedShare = 0.5
  public static let fingerprintThreshold = 0.6

  public struct Input: Sendable {
    public var windowIDs: Set<UInt32>
    public var fingerprint: Fingerprint
    public init(windowIDs: Set<UInt32>, fingerprint: Fingerprint) {
      self.windowIDs = windowIDs; self.fingerprint = fingerprint
    }
  }

  public struct Plan: Sendable {
    /// Stage index → existing record (nil = create one) and why.
    public var assignments: [Int: (record: UUID?, reason: MatchReason)] = [:]
    /// Records that go dormant, absorbed into the given record.
    public var dormant: [UUID: UUID] = [:]
  }

  /// 1. Merges: a stage containing most of the windows of two or more active records keeps the
  ///    customised (else oldest) one; the rest go dormant with a link to it.
  /// 2. Window IDs: remaining pairs, most shared windows first, 1:1. Dormant records take part, so
  ///    a merged-away record comes back when its windows split off again. A split's larger part
  ///    keeps the record; smaller parts get new records.
  /// 3. Fingerprint: stages still unmatched vs. records none of whose window IDs exist any more.
  public static func plan(stages: [Input], records: [StageRecord]) -> Plan {
    var plan = Plan()
    var claimed = Set<UUID>()
    let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    func preferred(_ a: StageRecord, _ b: StageRecord) -> Bool {
      if a.isCustomised != b.isCustomised { return a.isCustomised }
      if a.state != b.state { return a.state == .active }
      return a.createdAt < b.createdAt
    }

    // 1. Merges.
    let active = records.filter { $0.state == .active && !$0.windowIDs.isEmpty }
    for (i, s) in stages.enumerated() {
      let inside = active.filter { r in
        !claimed.contains(r.id) &&
          Double(s.windowIDs.intersection(r.windowIDs).count) / Double(r.windowIDs.count) > containedShare
      }
      guard inside.count >= 2 else { continue }
      let sorted = inside.sorted(by: preferred)
      let keeper = sorted[0]
      let absorbed = sorted.dropFirst().map(\.id)
      plan.assignments[i] = (keeper.id, .merged(absorbed: absorbed, shared: s.windowIDs.intersection(keeper.windowIDs).count))
      claimed.formUnion(inside.map(\.id))
      for id in absorbed { plan.dormant[id] = keeper.id }
    }

    // 2. Window IDs.
    struct Pair { var stage: Int; var record: StageRecord; var shared: Int; var jaccard: Double }
    var pairs: [Pair] = []
    for (i, s) in stages.enumerated() where plan.assignments[i] == nil {
      for r in records where !claimed.contains(r.id) {
        let shared = s.windowIDs.intersection(r.windowIDs).count
        guard shared > 0 else { continue }
        let j = jaccard(s.windowIDs, r.windowIDs)
        let largerPart = Double(shared) / Double(r.windowIDs.count) > containedShare
        if j >= idThreshold || largerPart { pairs.append(Pair(stage: i, record: r, shared: shared, jaccard: j)) }
      }
    }
    pairs.sort { a, b in
      if a.shared != b.shared { return a.shared > b.shared }
      if a.jaccard != b.jaccard { return a.jaccard > b.jaccard }
      return preferred(a.record, b.record)
    }
    for p in pairs where plan.assignments[p.stage] == nil && !claimed.contains(p.record.id) {
      let r = p.record
      // Split: some of this record's windows are in another stage.
      let elsewhere = stages.indices.contains { $0 != p.stage && !stages[$0].windowIDs.isDisjoint(with: r.windowIDs) }
      let reason: MatchReason =
        r.state == .dormant ? .revived(shared: p.shared, of: r.windowIDs.count) :
        elsewhere ? .keptInSplit(shared: p.shared, of: r.windowIDs.count) :
        .windowIDs(shared: p.shared, of: r.windowIDs.count, jaccard: p.jaccard)
      plan.assignments[p.stage] = (r.id, reason)
      claimed.insert(r.id)
    }

    // 3. Fingerprints, only against records whose windows are all gone.
    let live = stages.reduce(into: Set<UInt32>()) { $0.formUnion($1.windowIDs) }
    var fpPairs: [(stage: Int, record: StageRecord, score: Double)] = []
    for (i, s) in stages.enumerated() where plan.assignments[i] == nil && !s.fingerprint.isEmpty {
      for r in records where !claimed.contains(r.id) && r.state == .active && r.windowIDs.isDisjoint(with: live) {
        let score = Fingerprint.similarity(s.fingerprint, r.fingerprint)
        if score >= fingerprintThreshold { fpPairs.append((i, r, score)) }
      }
    }
    fpPairs.sort { a, b in a.score != b.score ? a.score > b.score : preferred(a.record, b.record) }
    for p in fpPairs where plan.assignments[p.stage] == nil && !claimed.contains(p.record.id) {
      plan.assignments[p.stage] = (p.record.id, .fingerprint(score: p.score))
      claimed.insert(p.record.id)
    }

    // The rest are new; note when they split off a record another stage kept.
    for (i, s) in stages.enumerated() where plan.assignments[i] == nil {
      let source = records.first { r in
        claimed.contains(r.id) && !s.windowIDs.isDisjoint(with: r.windowIDs) && byID[r.id] != nil
      }
      plan.assignments[i] = (nil, source.map { .splitFrom($0.id) } ?? .new)
    }
    return plan
  }
}
