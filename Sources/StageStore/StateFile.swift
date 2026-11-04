import Foundation
import StageReader

/// `~/Library/Application Support/Stages/state.json`: the current stages for other tools (a
/// Raycast extension showing "files relevant to this stage"). Local only; rewritten when it
/// changes. Named stages that aren't on screen are included with their last-known titles and
/// documents.
public struct StateFile: Codable, Equatable, Sendable {
  public struct Window: Codable, Equatable, Sendable {
    public var id: UInt32
    public var app: String
    public var bundleID: String?
    public var title: String?
    public var documentPath: String?
  }

  public struct StageEntry: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String?
    public var ink: String?
    public var slot: Int?
    /// "centre", "strip", "overflow", or "absent" for a named stage not on screen.
    public var position: String
    public var order: Int?
    public var displayID: UInt32?
    public var apps: [String]
    public var windows: [Window]
    /// For absent stages: what they had when last seen.
    public var lastTitles: [String]?
    public var lastDocuments: [String]?
    public var lastActive: Date?
  }

  public var version = 1
  public var current: UUID?
  public var stages: [StageEntry]

  public static func make(stages: [IdentifiedStage], records: [StageRecord], documents: [UInt32: String]) -> StateFile {
    let shown = Set(stages.map(\.id))
    var entries = stages.map { s in
      StageEntry(
        id: s.id, name: s.record.name, ink: s.record.ink?.rawValue, slot: s.record.slot,
        position: s.stage.position.rawValue, order: s.stage.order, displayID: s.stage.displayID,
        apps: s.stage.owners,
        windows: s.stage.windows.map {
          Window(id: $0.id, app: $0.owner, bundleID: $0.bundleID, title: $0.title, documentPath: documents[$0.id])
        },
        lastTitles: nil, lastDocuments: nil, lastActive: s.record.lastActive)
    }
    let absent = records
      .filter { !shown.contains($0.id) && $0.name != nil && $0.state == .active }
      .sorted { ($0.lastActive ?? $0.createdAt) > ($1.lastActive ?? $1.createdAt) }
    entries += absent.map { r in
      StageEntry(id: r.id, name: r.name, ink: r.ink?.rawValue, slot: r.slot, position: "absent", order: nil,
                 displayID: nil, apps: r.fingerprint.apps.sorted(), windows: [],
                 lastTitles: r.fingerprint.titles, lastDocuments: r.fingerprint.documents.sorted(),
                 lastActive: r.lastActive)
    }
    let current = stages.first { $0.stage.position == .centre }?.id
    return StateFile(current: current, stages: entries)
  }

  public func encoded() throws -> Data {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try e.encode(self)
  }
}
