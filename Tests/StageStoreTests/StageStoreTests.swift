import Foundation
import Testing
import StageReader
@testable import StageStore

/// A stage whose windows belong to `apps` (cycled) with the given titles.
private func stage(_ ids: [UInt32], _ position: Stage.Position = .strip, order: Int = 0,
                   apps: [String] = ["App"], titles: [String?] = []) -> Stage {
  Stage(position: position, order: order, displayID: 1,
        windows: ids.enumerated().map { i, id in
          let app = apps[i % apps.count]
          return StageWindow(id: id, pid: 1, owner: app, bundleID: "com.example.\(app.lowercased())",
                             title: i < titles.count ? titles[i] : nil,
                             frame: Rect(x: 0, y: 0, w: 100, h: 100), overlayID: nil, z: i)
        },
        frame: Rect(x: 0, y: 0, w: 100, h: 100), appIconCount: nil)
}

private func snapshot(_ stages: [Stage]) -> StageSnapshot {
  StageSnapshot(capturedAt: Date(), unavailable: nil, stages: stages, diagnostics: Diagnostics())
}

private func pooled(_ id: UInt32, order: Int) -> Stage {
  var s = stage([id], .overflow, order: order)
  s.pooled = true
  return s
}

private func tempDir() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("stages-tests-\(UUID().uuidString)")
}

@MainActor @Suite struct StageStoreTests {
  @Test func newStagesGetRecordsAndKeepThem() {
    let store = StageStore(directory: nil)
    let first = store.reconcile(snapshot([stage([1, 2], .centre), stage([3])]))
    let second = store.reconcile(snapshot([stage([3], .centre), stage([1, 2])]))
    #expect(first.map(\.id) == [second[1].id, second[0].id])
    #expect(first.map(\.reason) == [.new, .new])
    #expect(second[0].reason == .windowIDs(shared: 1, of: 1, jaccard: 1))
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

  @Test func centreUpdatesLastActive() {
    var t = Date(timeIntervalSince1970: 100)
    let store = StageStore(directory: nil, now: { t })
    let id = store.reconcile(snapshot([stage([1], .centre)]))[0].id
    t = Date(timeIntervalSince1970: 200)
    _ = store.reconcile(snapshot([stage([1])]))
    #expect(store.records[id]?.lastActive == Date(timeIntervalSince1970: 100))
    #expect(store.records[id]?.lastSeen == Date(timeIntervalSince1970: 200))
  }

  @Test func persistsAcrossInstances() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let boot = Date(timeIntervalSince1970: 1_000)
    let a = StageStore(directory: dir, bootTime: boot)
    let id = a.reconcile(snapshot([stage([1, 2])]))[0].id
    a.rename(id, to: "Lodestone"); a.setInk(id, .violet); a.setSlot(id, 1)
    let b = StageStore(directory: dir, bootTime: boot)
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

@MainActor @Suite struct PruningTests {
  @Test func unnamedRecordsSurviveAWhileOffScreen() {
    var t = Date(timeIntervalSince1970: 0)
    let store = StageStore(directory: nil, now: { t })
    let s = store.reconcile(snapshot([stage([1]), stage([2])]))
    store.setInk(s[0].id, .teal)
    // Off screen (another Space, say) for an hour: both kept, and they match again on return.
    t += 3600
    _ = store.reconcile(snapshot([stage([9])]))
    t += 60
    let back = store.reconcile(snapshot([stage([1]), stage([2])]))
    #expect(back.map(\.id) == s.map(\.id))
    // Gone for longer than the TTL: the unnamed one is pruned, the inked one stays.
    t += StageStore.unnamedTTL + 1
    _ = store.reconcile(snapshot([stage([9])]))
    #expect(store.records[s[0].id] != nil)
    #expect(store.records[s[1].id] == nil)
  }

  @Test func namedRecordsAreNeverPruned() {
    var t = Date(timeIntervalSince1970: 0)
    let store = StageStore(directory: nil, now: { t })
    let id = store.reconcile(snapshot([stage([1])]))[0].id
    store.rename(id, to: "Keep")
    t += 365 * 24 * 3600
    _ = store.reconcile(snapshot([stage([9])]))
    #expect(store.records[id]?.name == "Keep")
  }
}

@MainActor @Suite struct MergeSplitTests {
  @Test func groupingTwoStagesKeepsTheNamedRecord() {
    let store = StageStore(directory: nil)
    let s = store.reconcile(snapshot([stage([1], apps: ["Safari"]), stage([2], apps: ["Notes"])]))
    store.rename(s[1].id, to: "Research")
    let merged = store.reconcile(snapshot([stage([1, 2], apps: ["Safari", "Notes"])]))
    #expect(merged.count == 1)
    #expect(merged[0].id == s[1].id && merged[0].record.name == "Research")
    #expect(merged[0].reason == .merged(absorbed: [s[0].id], shared: 1))
    #expect(store.records[s[0].id]?.state == .dormant)
    #expect(store.records[s[0].id]?.mergedInto == s[1].id)
  }

  @Test func mergingUnnamedKeepsTheOlder() {
    var t = Date(timeIntervalSince1970: 0)
    let store = StageStore(directory: nil, now: { t })
    let a = store.reconcile(snapshot([stage([1])]))[0].id
    t += 10
    let b = store.reconcile(snapshot([stage([1]), stage([2])]))[1].id
    let merged = store.reconcile(snapshot([stage([1, 2])]))
    #expect(merged[0].id == a)
    #expect(store.records[b]?.state == .dormant)
  }

  @Test func splitKeepsRecordOnLargerPart() {
    let store = StageStore(directory: nil)
    let id = store.reconcile(snapshot([stage([1, 2, 3])]))[0].id
    store.rename(id, to: "Big")
    let split = store.reconcile(snapshot([stage([1, 2]), stage([3])]))
    #expect(split[0].id == id && split[0].record.name == "Big")
    #expect(split[0].reason == .keptInSplit(shared: 2, of: 3))
    #expect(split[1].id != id && split[1].record.name == nil)
    #expect(split[1].reason == .splitFrom(id))
  }

  @Test func dormantRecordRevivesWhenItsWindowsSplitOffAgain() {
    let store = StageStore(directory: nil)
    let s = store.reconcile(snapshot([stage([1]), stage([2])]))
    store.rename(s[0].id, to: "Mail"); store.rename(s[1].id, to: "Notes")
    _ = store.reconcile(snapshot([stage([1, 2])]))   // grouped: one goes dormant
    let apart = store.reconcile(snapshot([stage([1]), stage([2])]))
    #expect(Set(apart.map(\.id)) == Set(s.map(\.id)))
    #expect(apart.map(\.record.name) == ["Mail", "Notes"])
    #expect(apart.contains { if case .revived = $0.reason { true } else { false } })
    #expect(store.records.values.allSatisfy { $0.state == .active })
  }
}

@MainActor @Suite struct FingerprintMatchingTests {
  @Test func appRelaunchMatchesByAppsAndTitles() {
    let store = StageStore(directory: nil)
    let s = store.reconcile(snapshot([
      stage([1, 2], apps: ["Ghostty", "Xcode"], titles: ["~/dev/swifttap", "Swifttap — Package.swift"]),
      stage([3], apps: ["Safari"], titles: ["Apple Developer Documentation"]),
    ]))
    store.rename(s[0].id, to: "Swifttap")
    // Both apps quit and relaunched: all-new window IDs, similar titles.
    let later = store.reconcile(snapshot([
      stage([3], apps: ["Safari"], titles: ["Apple Developer Documentation"]),
      stage([40, 41], apps: ["Ghostty", "Xcode"], titles: ["~/dev/swifttap", "Swifttap — Sources"]),
    ]))
    #expect(later[1].id == s[0].id && later[1].record.name == "Swifttap")
    guard case let .fingerprint(score) = later[1].reason else { Issue.record("\(later[1].reason)"); return }
    #expect(score >= StageMatcher.fingerprintThreshold)
  }

  @Test func differentAppsDoNotMatchByFingerprint() {
    let store = StageStore(directory: nil)
    let id = store.reconcile(snapshot([stage([1], apps: ["Mail"], titles: ["Inbox"])]))[0].id
    store.rename(id, to: "Mail")
    let later = store.reconcile(snapshot([stage([50], apps: ["Notes"], titles: ["Inbox"])]))
    #expect(later[0].id != id && later[0].reason == .new)
  }

  @Test func titlesDisambiguateTwoStagesOfOneApp() {
    let store = StageStore(directory: nil)
    let s = store.reconcile(snapshot([
      stage([1], apps: ["Safari"], titles: ["Lodestone prototype – GitHub"]),
      stage([2], apps: ["Safari"], titles: ["Stage Manager – Apple Support"]),
    ]))
    store.rename(s[0].id, to: "Lodestone"); store.rename(s[1].id, to: "Research")
    let later = store.reconcile(snapshot([
      stage([20], apps: ["Safari"], titles: ["Stage Manager – Apple Support"]),
      stage([21], apps: ["Safari"], titles: ["Lodestone prototype – GitHub"]),
    ]))
    #expect(later.map(\.record.name) == ["Research", "Lodestone"])
  }

  @Test func fingerprintIgnoresRecordsWhoseWindowsAreStillOnScreen() {
    let store = StageStore(directory: nil)
    let s = store.reconcile(snapshot([stage([1], apps: ["Safari"], titles: ["A"])]))
    // A second Safari stage with the same title appears while the first is still there.
    let later = store.reconcile(snapshot([stage([1], apps: ["Safari"], titles: ["A"]),
                                          stage([2], apps: ["Safari"], titles: ["A"])]))
    #expect(later[0].id == s[0].id)
    #expect(later[1].reason == .new)
  }

  @Test func documentsAreAttachedToFingerprints() {
    let store = StageStore(directory: nil)
    let id = store.reconcile(snapshot([stage([1], apps: ["Preview"], titles: ["paper.pdf"])]))[0].id
    store.attachDocuments([1: "file:///Users/m/paper.pdf"])
    #expect(store.records[id]?.fingerprint.documents == ["file:///Users/m/paper.pdf"])
  }
}

@MainActor @Suite struct RebootTests {
  @Test func newBootDiscardsWindowIDsAndMatchesByFingerprint() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = StageStore(directory: dir, bootTime: Date(timeIntervalSince1970: 1_000))
    let id = a.reconcile(snapshot([stage([5], apps: ["Mail"], titles: ["Inbox – Creativeoak"]),
                                   stage([6], apps: ["Notes"], titles: ["Shopping"])]))[0].id
    a.rename(id, to: "Mail")
    // After a reboot, window 6 now happens to be Mail's and 5 is Notes': IDs must not be trusted.
    let b = StageStore(directory: dir, bootTime: Date(timeIntervalSince1970: 90_000))
    #expect(b.discardedStaleIDs)
    let later = b.reconcile(snapshot([stage([5], apps: ["Notes"], titles: ["Shopping"]),
                                      stage([6], apps: ["Mail"], titles: ["Inbox – Creativeoak"])]))
    #expect(later[1].id == id && later[1].record.name == "Mail")
    #expect(later[0].record.name == nil)
  }

  @Test func sameBootKeepsWindowIDs() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let boot = Date(timeIntervalSince1970: 1_000)
    _ = StageStore(directory: dir, bootTime: boot).reconcile(snapshot([stage([5])]))
    let b = StageStore(directory: dir, bootTime: boot.addingTimeInterval(0.4))
    #expect(!b.discardedStaleIDs)
    #expect(b.records.values.first?.windowIDs == [5])
  }

  @Test func readsVersionOneFiles() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let v1 = """
    {"version":1,"records":[{"id":"6B3A1C2E-0000-4000-8000-000000000001","name":"Old","ink":"teal","slot":2,
     "windowIDs":[11052],"lastActive":"2026-11-03T17:00:00Z","createdAt":"2026-11-03T16:00:00Z"}]}
    """
    try Data(v1.utf8).write(to: dir.appendingPathComponent("stages.json"))
    let store = StageStore(directory: dir)
    let r = try #require(store.records.values.first)
    #expect(r.name == "Old" && r.ink == .teal && r.slot == 2 && r.windowIDs == [11052])
    #expect(r.state == .active && r.fingerprint.isEmpty)
    #expect(!store.discardedStaleIDs)   // no boot time recorded: keep IDs
  }
}

@Suite struct FingerprintSimilarityTests {
  @Test func weighsAppsTitlesDocuments() {
    let a = Fingerprint(apps: ["com.apple.Safari"], titles: ["Stage Manager – Apple Support"])
    #expect(Fingerprint.similarity(a, a) == 1)
    let b = Fingerprint(apps: ["com.apple.Safari"], titles: ["Something else entirely"])
    #expect(Fingerprint.similarity(a, b) < StageMatcher.fingerprintThreshold)
    let c = Fingerprint(apps: ["com.apple.Notes"], titles: ["Stage Manager – Apple Support"])
    #expect(Fingerprint.similarity(a, c) == 0)
  }
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

@MainActor @Suite struct RegroupTrustTests {
  @Test func onlyObservedMembershipsRegroupOverflow() throws {
    // A record written before membershipSeen existed claims six overflow windows (old reader bug).
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let v2 = """
    {"version":2,"records":[{"id":"6B3A1C2E-0000-4000-8000-000000000002",
     "windowIDs":[1,2,3,4,5,6],"createdAt":"2026-11-03T16:00:00Z"}]}
    """
    try Data(v2.utf8).write(to: dir.appendingPathComponent("stages.json"))
    let store = StageStore(directory: dir)
    let s = store.reconcile(snapshot((1...6).map { pooled(UInt32($0), order: Int($0) - 1) }))
    #expect(s.count == 6)
  }

  @Test func pooledStagesDoNotEarnMembership() {
    let store = StageStore(directory: nil)
    let s = store.reconcile(snapshot([pooled(1, order: 0)]))
    #expect(store.records[s[0].id]?.membershipSeen == false)
    _ = store.reconcile(snapshot([stage([1])]))
    #expect(store.records[s[0].id]?.membershipSeen == true)
  }
}

@MainActor @Suite struct NoHistoryOverflowTests {
  @Test func recordedFinderGroupWithoutHistoryStaysSeparate() throws {
    // `curious`: Finder's three windows are one overflow stage, but a fresh store can't know
    // that (one app's windows can live in different stages), so it doesn't guess.
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../StageReaderTests/Fixtures/curious.json")
    let fixture = try Fixture.decoder().decode(Fixture.self, from: Data(contentsOf: url))
    let s = StageStore(directory: nil).reconcile(StageReader.read(fixture.frames[0]))
    let overflow = s.filter { $0.stage.position == .overflow }.map(\.stage.owners)
    #expect(overflow == [["Finder"], ["Finder"], ["Finder"], ["Calendar"], ["Maps"], ["Notes"]])
  }
}

@MainActor @Suite struct MergeGuardTests {
  @Test func draggingIntoTheCentreKeepsTheCentreStagesName() {
    var t = Date(timeIntervalSince1970: 0)
    let store = StageStore(directory: nil, now: { t })
    // B is created first (older), A is in the centre when B is dragged into it.
    let b = store.reconcile(snapshot([stage([2], .centre)]))[0].id
    t += 10
    let a = store.reconcile(snapshot([stage([1], .centre), stage([2])]))[0].id
    store.rename(a, to: "A"); store.rename(b, to: "B")
    t += 10
    let merged = store.reconcile(snapshot([stage([1, 2], .centre)]))
    #expect(merged[0].record.name == "A")
    #expect(store.records[b]?.state == .dormant)
  }

  @Test func threeRecordsAtOnceIsNotAMerge() {
    let store = StageStore(directory: nil)
    let s = store.reconcile(snapshot([stage([1]), stage([2]), stage([3])]))
    let bogus = store.reconcile(snapshot([stage([1, 2, 3], .centre)]))
    #expect(store.records.values.allSatisfy { $0.state == .active })
    if case .merged = bogus[0].reason { Issue.record("merged") }
    // When things settle, every stage still has its own record.
    let back = store.reconcile(snapshot([stage([1]), stage([2]), stage([3])]))
    #expect(Set(back.map(\.id)) == Set(s.map(\.id)))
  }

  @Test func pooledStagesNeverMerge() {
    let store = StageStore(directory: nil)
    _ = store.reconcile(snapshot([stage([1]), stage([2])]))
    var p = stage([1, 2], .overflow)
    p.pooled = true
    _ = store.reconcile(snapshot([p]))
    #expect(store.records.values.allSatisfy { $0.state == .active })
  }

  @Test func eventsAreReportedWithoutNames() {
    let store = StageStore(directory: nil)
    var events: [String] = []
    store.onEvent = { events.append($0) }
    let s = store.reconcile(snapshot([stage([1]), stage([2])]))
    store.rename(s[0].id, to: "Secret name")
    _ = store.reconcile(snapshot([stage([1, 2])]))
    #expect(events.count == 1 && events[0].hasPrefix("merge:"))
    #expect(!events[0].contains("Secret"))
  }
}

@MainActor @Suite struct ImplausibleSnapshotTests {
  @Test func allWindowsInOneStageIsIgnored() {
    // Mission Control (or similar): every window shows at once with no thumbnails matched.
    let store = StageStore(directory: nil)
    var events: [String] = []
    store.onEvent = { events.append($0) }
    let good = store.reconcile(snapshot([stage([1], .centre), stage([2, 3]), stage([4]), stage([5])]))
    store.rename(good[1].id, to: "B")
    let before = store.records
    let bogus = store.reconcile(snapshot([stage([1, 2, 3, 4, 5], .centre)]))
    #expect(bogus.map(\.id) == good.map(\.id))   // last good state, unchanged
    #expect(store.records == before)
    #expect(store.lastRejection != nil)
    #expect(events.last?.hasPrefix("rejected snapshot") == true)
    // Back to normal: same identities, and B wasn't touched.
    let after = store.reconcile(snapshot([stage([1], .centre), stage([2, 3]), stage([4]), stage([5])]))
    #expect(after.map(\.id) == good.map(\.id))
    #expect(after[1].record.name == "B" && store.lastRejection == nil)
  }

  @Test func secondDragIntoAMergedGroupIsStillAMerge() {
    let store = StageStore(directory: nil)
    let s = store.reconcile(snapshot([stage([1], .centre), stage([2]), stage([3])]))
    _ = store.reconcile(snapshot([stage([1, 2], .centre), stage([3])]))      // first drag
    let second = store.reconcile(snapshot([stage([1, 2, 3], .centre)]))      // second drag
    #expect(store.lastRejection == nil)
    #expect(second.count == 1 && second[0].id == s[0].id)
    if case .merged = second[0].reason {} else { Issue.record("\(second[0].reason)") }
  }
}

@MainActor @Suite struct StrictFingerprintTests {
  @Test func extraAppMeansNoFingerprintMatch() {
    // A Finder + Mail stage must not inherit a Finder-only stage's name.
    let store = StageStore(directory: nil)
    let id = store.reconcile(snapshot([stage([1], apps: ["Finder"], titles: ["Recents"])]))[0].id
    store.rename(id, to: "B")
    let later = store.reconcile(snapshot([stage([7, 8], apps: ["Finder", "Mail"], titles: ["Recents", "New Message"])]))
    #expect(later[0].id != id && later[0].record.name == nil)
  }
}

@MainActor @Suite struct StateFileTests {
  @Test func listsOnScreenStagesThenNamedAbsentOnes() throws {
    let store = StageStore(directory: nil)
    let s = store.reconcile(snapshot([stage([1], .centre, apps: ["Ghostty"], titles: ["~/dev"]),
                                      stage([2], apps: ["Preview"], titles: ["paper.pdf"])]))
    store.rename(s[1].id, to: "Reading"); store.setInk(s[1].id, .teal); store.setSlot(s[1].id, 2)
    store.attachDocuments([2: "file:///Users/m/paper.pdf"])
    // Preview's stage goes away; it is named, so it stays listed as absent.
    let later = store.reconcile(snapshot([stage([1], .centre, apps: ["Ghostty"], titles: ["~/dev"])]))
    let file = StateFile.make(stages: later, records: Array(store.records.values), documents: store.documents)
    #expect(file.current == s[0].id)
    #expect(file.stages.map(\.position) == ["centre", "absent"])
    let reading = file.stages[1]
    #expect(reading.name == "Reading" && reading.ink == "teal" && reading.slot == 2)
    #expect(reading.lastTitles == ["paper.pdf"] && reading.lastDocuments == ["file:///Users/m/paper.pdf"])
    #expect(file.stages[0].windows.first?.title == "~/dev")
    _ = try file.encoded()
  }
}

private func snapshot(_ stages: [Stage], live: Set<UInt32>) -> StageSnapshot {
  StageSnapshot(capturedAt: Date(), unavailable: nil, stages: stages, diagnostics: Diagnostics(), allWindowIDs: live)
}

@MainActor @Suite struct SleepingTests {
  @Test func namedStageWithClosedWindowsSleeps() {
    let store = StageStore(directory: nil)
    let s = store.reconcile(snapshot([stage([1], .centre, apps: ["Ghostty"]), stage([2, 3], apps: ["Preview", "Notes"])],
                                     live: [1, 2, 3]))
    store.rename(s[1].id, to: "Reading")
    // Preview and Notes quit: their windows are gone from the capture entirely.
    _ = store.reconcile(snapshot([stage([1], .centre, apps: ["Ghostty"])], live: [1]))
    #expect(store.sleeping.map(\.name) == ["Reading"])
  }

  @Test func stageOnAnotherSpaceIsNotSleeping() {
    let store = StageStore(directory: nil)
    let s = store.reconcile(snapshot([stage([1], .centre), stage([2])], live: [1, 2]))
    store.rename(s[1].id, to: "Elsewhere")
    // Window 2 still exists (another Space), it's just not in a stage here.
    _ = store.reconcile(snapshot([stage([1], .centre)], live: [1, 2]))
    #expect(store.sleeping.isEmpty)
  }

  @Test func wakingGivesTheNameToTheFirstNewStageOfItsApps() {
    let store = StageStore(directory: nil)
    let s = store.reconcile(snapshot([stage([1], .centre, apps: ["Ghostty"]), stage([2, 3], apps: ["Preview", "Notes"])],
                                     live: [1, 2, 3]))
    store.rename(s[1].id, to: "Reading")
    _ = store.reconcile(snapshot([stage([1], .centre, apps: ["Ghostty"])], live: [1]))
    store.expectWake(s[1].id)
    // Relaunched: Preview and Notes come back as two separate stages, with new window IDs.
    let woke = store.reconcile(snapshot([stage([10], .centre, apps: ["Preview"]), stage([1], apps: ["Ghostty"]),
                                         stage([11], apps: ["Notes"])], live: [1, 10, 11]))
    #expect(woke[0].id == s[1].id && woke[0].record.name == "Reading" && woke[0].reason == .woken)
    #expect(woke[2].record.name == nil)
    #expect(store.sleeping.isEmpty)
  }

  @Test func unrelatedNewStagesDoNotClaimAWake() {
    let store = StageStore(directory: nil)
    let s = store.reconcile(snapshot([stage([2], apps: ["Preview"])], live: [2]))
    store.rename(s[0].id, to: "Reading")
    _ = store.reconcile(snapshot([], live: []))
    store.expectWake(s[0].id)
    let other = store.reconcile(snapshot([stage([9], apps: ["Mail"])], live: [9]))
    #expect(other[0].id != s[0].id)
  }
}
