import Foundation

/// One line of `activity.jsonl`: which stage was in the centre, and with what.
public struct ActivityEntry: Codable, Equatable, Sendable {
  public struct Window: Codable, Equatable, Sendable {
    public var bundleId: String?
    public var app: String
    public var title: String?
    public var documentPath: String?

    public init(bundleId: String?, app: String, title: String?, documentPath: String?) {
      self.bundleId = bundleId; self.app = app; self.title = title; self.documentPath = documentPath
    }
  }

  public var ts: Date
  public var stageId: UUID
  public var name: String?
  public var windows: [Window]

  public init(ts: Date, stageId: UUID, name: String?, windows: [Window]) {
    self.ts = ts; self.stageId = stageId; self.name = name; self.windows = windows
  }
}

/// Append-only JSON Lines log of centre-stage changes, in
/// `~/Library/Application Support/Stages/activity.jsonl`. Local only.
///
/// An entry is written when the stage in the centre changes, or when its windows (or their
/// titles or documents) change; repeats of the same state are skipped.
public final class ActivityLog: @unchecked Sendable {
  public let fileURL: URL
  private var last: (stageId: UUID, windows: [ActivityEntry.Window], name: String?)?
  private let lock = NSLock()

  public init(fileURL: URL) { self.fileURL = fileURL }

  /// Appends `entry` unless it repeats the previous one. Returns whether it was written.
  @discardableResult
  public func record(_ entry: ActivityEntry) -> Bool {
    lock.lock(); defer { lock.unlock() }
    if let last, last.stageId == entry.stageId, last.windows == entry.windows, last.name == entry.name { return false }
    do {
      var line = try Self.encoder.encode(entry)
      line.append(0x0A)
      try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: fileURL.path) {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
      }
      let handle = try FileHandle(forWritingTo: fileURL)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: line)
      last = (entry.stageId, entry.windows, entry.name)
      return true
    } catch {
      NSLog("Stages: couldn't append to \(fileURL.path): \(error)")
      return false
    }
  }

  /// All entries (for tests and tools).
  public func read() throws -> [ActivityEntry] {
    let data = try Data(contentsOf: fileURL)
    return try data.split(separator: 0x0A).map { try Self.decoder.decode(ActivityEntry.self, from: Data($0)) }
  }

  private static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]   // one line per entry
    return e
  }()

  private static let decoder: JSONDecoder = {
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
  }()
}
