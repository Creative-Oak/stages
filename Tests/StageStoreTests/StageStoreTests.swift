import Foundation
import Testing
import StageReader
@testable import StageStore

private func stage(_ ids: [UInt32], _ position: Stage.Position = .strip, order: Int = 0) -> Stage {
  Stage(position: position, order: order, displayID: 1,
        windows: ids.map { StageWindow(id: $0, pid: 1, owner: "App", bundleID: nil, title: nil,
                                       frame: Rect(x: 0, y: 0, w: 100, h: 100), overlayID: nil, z: 0) },
        frame: Rect(x: 0, y: 0, w: 100, h: 100), appIconCount: nil)
}

private func snapshot(_ stages: [Stage]) -> StageSnapshot {
  StageSnapshot(capturedAt: Date(), unavailable: nil, stages: stages, diagnostics: Diagnostics())
}

@MainActor @Suite struct StageStoreTests {
  @Test func newStagesGetRecordsAndKeepThem() {
    let store = StageStore(directory: nil)
    let first = store.reconcile(snapshot([stage([1, 2], .centre), stage([3])]))
    let second = store.reconcile(snapshot([stage([3], .centre), stage([1, 2])]))
    #expect(first.map(\.id) == [second[1].id, second[0].id])
  }

  @Test func nameSurvivesWindowChurn() {
    let store = StageStore(directory: nil)
    let id = store.reconcile(snapshot([stage([1, 2])]))[0].id
    store.rename(id, to: "  Swifttap ")
    let later = store.reconcile(snapshot([stage([1, 2, 5])]))   // a window opened
    #expect(later[0].id == id)
    #expect(later[0].record.name == "Swifttap")
  }

  @Test func blankNameClears() {
    let store = StageStore(directory: nil)
    let id = store.reconcile(snapshot([stage([1])]))[0].id
    store.rename(id, to: "x"); store.rename(id, to: "  ")
    #expect(store.records[id]?.name == nil)
  }

  @Test func slotsAreUnique() {
    let store = StageStore(directory: nil)
    let s = store.reconcile(snapshot([stage([1]), stage([2])]))
    store.setSlot(s[0].id, 3)
    store.setSlot(s[1].id, 3)
    #expect(store.records[s[0].id]?.slot == nil)
    #expect(store.records[s[1].id]?.slot == 3)
  }

  @Test func uncustomisedRecordsArePrunedCustomisedKept() {
    let store = StageStore(directory: nil)
    let s = store.reconcile(snapshot([stage([1]), stage([2])]))
    store.setInk(s[0].id, .teal)
    _ = store.reconcile(snapshot([stage([9])]))
    #expect(store.records[s[0].id] != nil)
    #expect(store.records[s[1].id] == nil)
  }

  @Test func centreUpdatesLastActive() {
    var t = Date(timeIntervalSince1970: 100)
    let store = StageStore(directory: nil, now: { t })
    let id = store.reconcile(snapshot([stage([1], .centre)]))[0].id
    t = Date(timeIntervalSince1970: 200)
    _ = store.reconcile(snapshot([stage([1])]))
    #expect(store.records[id]?.lastActive == Date(timeIntervalSince1970: 100))
  }

  @Test func persistsAcrossInstances() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = StageStore(directory: dir)
    let id = a.reconcile(snapshot([stage([1, 2])]))[0].id
    a.rename(id, to: "Lodestone"); a.setInk(id, .violet); a.setSlot(id, 1)
    let b = StageStore(directory: dir)
    let r = try #require(b.reconcile(snapshot([stage([2, 1])])).first?.record)
    #expect(r.id == id && r.name == "Lodestone" && r.ink == .violet && r.slot == 1)
  }

  @Test func unavailableSnapshotChangesNothing() {
    let store = StageStore(directory: nil)
    _ = store.reconcile(snapshot([stage([1])]))
    let off = StageSnapshot(capturedAt: Date(), unavailable: .stageManagerOff, stages: [], diagnostics: Diagnostics())
    #expect(store.reconcile(off).isEmpty)
    #expect(store.records.count == 1)
  }
}

@Suite struct StageMatcherTests {
  @Test func bestOverlapWinsAndIsExclusive() {
    let a = StageRecord(windowIDs: [1, 2, 3]), b = StageRecord(windowIDs: [3, 4])
    let m = StageMatcher.match(stages: [[1, 2], [3, 4], [7]], records: [a, b])
    #expect(m == [0: a.id, 1: b.id])
  }

  @Test func tieGoesToCustomisedRecord() {
    let plain = StageRecord(windowIDs: [1], createdAt: Date(timeIntervalSince1970: 0))
    let named = StageRecord(name: "Mail", windowIDs: [1], createdAt: Date(timeIntervalSince1970: 10))
    #expect(StageMatcher.match(stages: [[1]], records: [plain, named]) == [0: named.id])
  }
}

private func pooled(_ id: UInt32, order: Int) -> Stage {
  var s = stage([id], .overflow, order: order)
  s.pooled = true
  return s
}

@MainActor @Suite struct PooledOverflowTests {
  @Test func groupSeenInStripIsReunitedInOverflow() {
    let store = StageStore(directory: nil)
    let group = store.reconcile(snapshot([stage([1], .centre), stage([2, 3]), stage([4])]))
    store.rename(group[1].id, to: "Research")
    // Pushed to overflow: the reader can only report one pooled stage per window.
    let later = store.reconcile(snapshot([stage([1], .centre), stage([4]), pooled(2, order: 0), pooled(3, order: 1)]))
    let overflow = later.filter { $0.stage.position == .overflow }
    #expect(overflow.count == 1)
    #expect(overflow[0].id == group[1].id && overflow[0].record.name == "Research")
    #expect(overflow[0].stage.windowIDs == [2, 3])
  }

  @Test func separateStagesStaySeparate() {
    let store = StageStore(directory: nil)
    let first = store.reconcile(snapshot([stage([2]), stage([3])]))
    let later = store.reconcile(snapshot([pooled(2, order: 0), pooled(3, order: 1)]))
    #expect(later.map(\.id) == first.map(\.id))
    #expect(later.map(\.stage.order) == [0, 1])
  }

  @Test func unknownPooledWindowsStayAlone() {
    let store = StageStore(directory: nil)
    let s = store.reconcile(snapshot([pooled(7, order: 0), pooled(8, order: 1)]))
    #expect(s.count == 2)
  }
}
