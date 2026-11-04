import Foundation
import Testing
@testable import ActivityLog

@Suite struct ActivityLogTests {
  func tempLog() -> ActivityLog {
    ActivityLog(fileURL: FileManager.default.temporaryDirectory
      .appendingPathComponent("stages-activity-\(UUID().uuidString)/activity.jsonl"))
  }

  let mail = ActivityEntry.Window(bundleId: "com.apple.mail", app: "Mail", title: "Inbox", documentPath: nil)
  let paper = ActivityEntry.Window(bundleId: "com.apple.Preview", app: "Preview", title: "paper.pdf",
                                   documentPath: "file:///Users/m/paper.pdf")

  @Test func appendsOneLinePerChangeAndSkipsRepeats() throws {
    let log = tempLog()
    defer { try? FileManager.default.removeItem(at: log.fileURL.deletingLastPathComponent()) }
    let a = UUID(), b = UUID()
    #expect(log.record(.init(ts: Date(timeIntervalSince1970: 1), stageId: a, name: "Mail", windows: [mail])))
    #expect(!log.record(.init(ts: Date(timeIntervalSince1970: 2), stageId: a, name: "Mail", windows: [mail])))
    #expect(log.record(.init(ts: Date(timeIntervalSince1970: 3), stageId: b, name: nil, windows: [paper])))
    #expect(log.record(.init(ts: Date(timeIntervalSince1970: 4), stageId: b, name: nil, windows: [paper, mail])))
    let entries = try log.read()
    #expect(entries.map(\.stageId) == [a, b, b])
    #expect(entries[1].windows[0].documentPath == "file:///Users/m/paper.pdf")
    let text = try String(contentsOf: log.fileURL, encoding: .utf8)
    #expect(text.split(separator: "\n").count == 3)
    #expect(text.contains("\"ts\":\"1970-01-01T00:00:01Z\""))
  }

  @Test func keepsExistingLinesAcrossInstances() throws {
    let first = tempLog()
    defer { try? FileManager.default.removeItem(at: first.fileURL.deletingLastPathComponent()) }
    first.record(.init(ts: Date(), stageId: UUID(), name: nil, windows: [mail]))
    let second = ActivityLog(fileURL: first.fileURL)
    second.record(.init(ts: Date(), stageId: UUID(), name: nil, windows: [paper]))
    #expect(try second.read().count == 2)
  }
}
