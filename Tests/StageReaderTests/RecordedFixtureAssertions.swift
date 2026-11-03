import Foundation
import Testing
@testable import StageReader

/// Expectations for fixtures recorded on Magnus's Mac, 2026-11-03 (macOS 27.2, 1470×956).
@Suite struct RecordedFixtureAssertions {
  func read(_ name: String, frame: Int? = nil) throws -> StageSnapshot {
    let f = try RecordedFixtureTests.fixture(name)
    return StageReader.read(f.frames[frame ?? f.frames.count - 1])
  }

  func owners(_ s: StageSnapshot, _ p: Stage.Position) -> [[String]] { s.stages(p).map(\.owners) }

  @Test(arguments: ["strip-hidden", "strip-visible", "grouped"])
  func singlesWithSplitCentre(_ name: String) throws {
    // Ghostty + Claude side by side in the centre, with no overlays drawn for them.
    let s = try read(name)
    #expect(owners(s, .centre) == [["Ghostty", "Claude"]])
    #expect(s.diagnostics.centreWithoutOverlay.count == 2)
    #expect(owners(s, .strip) == [["Mail"], ["Calendar"], ["Safari"], ["Maps"]])
    #expect(s.stages(.overflow).isEmpty)
    #expect(s.diagnostics.confidence == .high, "\(s.diagnostics.concerns)")
  }

  @Test func stripVisibleColumn() throws {
    let s = try read("strip-visible")
    #expect(s.stages(.strip).allSatisfy { $0.frame.minX == 16 })
  }

  @Test(arguments: ["overflow", "centre-two-apps"])
  func overflowIsPooled(_ name: String) throws {
    // Maps and Mail overlap offscreen only because overflow stages share one parking spot.
    let s = try read(name)
    #expect(owners(s, .centre) == [["Ghostty", "Claude"]])
    #expect(owners(s, .strip) == [["AppCleaner"], ["Chess"], ["Calendar"], ["Safari"]])
    #expect(owners(s, .overflow) == [["Maps"], ["Mail"]])
    #expect(s.stages(.overflow).allSatisfy { $0.pooled })
    #expect(s.diagnostics.confidence == .high, "\(s.diagnostics.concerns)")
  }

  @Test func manyOverlaysOverflowIsFourStages() throws {
    // Verified by Magnus via the Dock: Calendar and Mail each come forward alone.
    let s = try read("many-overlays")
    #expect(owners(s, .centre) == [["Ghostty"]])
    #expect(owners(s, .strip) == [["Signal"], ["Safari"], ["Claude"], ["Finder"]])
    #expect(s.stages(.strip)[3].windows.count == 3)   // three Finder windows fanned in one tile
    #expect(owners(s, .overflow) == [["Calendar"], ["Maps"], ["Notes"], ["Mail"]])
    #expect(s.diagnostics.unmatchedOverlayIDs.count == 7)   // offscreen leftovers
    #expect(s.diagnostics.confidence == .high, "\(s.diagnostics.concerns)")
  }

  @Test(arguments: ["overflow", "many-overlays", "mid-animation"])
  func overflowThumbnailsShareOneAnchor(_ name: String) throws {
    // Every overflow thumbnail: same right edge and vertical centre, whatever its size.
    let frames = try read(name).stages(.overflow).map(\.frame)
    #expect(frames.count >= 2)
    #expect(Set(frames.map(\.maxX)).count == 1)
    #expect(Set(frames.map(\.midY)).count == 1)
  }

  @Test func centreOverlaysWhenPresentAreUsed() throws {
    let s = try read("centre-two-apps")
    #expect(s.diagnostics.centreWithoutOverlay.isEmpty)
    #expect(s.stages(.centre)[0].windows.allSatisfy { $0.overlayID != nil })
  }

  @Test func midAnimationCommitsOnceSettled() throws {
    let f = try RecordedFixtureTests.fixture("mid-animation")
    var gate = StabilityGate()
    let committed = f.frames.enumerated().compactMap { i, c in gate.feed(StageReader.read(c)).map { (i, $0) } }
    // Frames 0–3 are still moving (grouped tile growing 122→126 wide); 3 and 4 are the first equal pair.
    #expect(committed.map(\.0) == [4])
    let s = try #require(committed.first?.1)
    #expect(owners(s, .centre) == [["Calendar"]])
    #expect(owners(s, .strip) == [["AppCleaner"], ["Chess"], ["Ghostty", "Claude"], ["Safari"]])
    #expect(s.stages(.strip)[2].appIconCount == 2)
    // Strip shown: the overflow anchor moves right with the column (right edge −16, not −300).
    #expect(owners(s, .overflow) == [["Maps"], ["Mail"]])
    #expect(s.stages(.overflow).allSatisfy { $0.frame.maxX == -16 })
  }

  @Test func stageManagerOffRecorded() throws {
    #expect(try read("stage-manager-off").unavailable == .stageManagerOff)
  }
}

@Suite struct TouchingTilesTests {
  @Test func touchingTilesAreSeparateStages() throws {
    // Signal ends at y 667, Claude starts at 666; Mail touches a parked Finder thumbnail by 1 pt.
    let f = try RecordedFixtureTests.fixture("curious")
    for frame in f.frames {
      let s = StageReader.read(frame)
      #expect(s.stages(.strip).map(\.owners) == [["Safari"], ["Mail"], ["Signal"], ["Claude"]])
      #expect(s.stages(.overflow).map(\.owners) == [["Finder"], ["Finder"], ["Finder"], ["Calendar"], ["Maps"], ["Notes"]])
    }
  }

  @Test func groupedOverflowFansAroundTheAnchor() throws {
    // Finder's three-window stage in overflow: same vertical centre, right edges offset by 16.
    let s = StageReader.read(try RecordedFixtureTests.fixture("curious").frames[0])
    let finder = s.stages(.overflow).filter { $0.owners == ["Finder"] }.map(\.frame)
    #expect(Set(finder.map(\.midY)) == [434.5])
    #expect(Set(finder.map(\.maxX)) == [-300, -284, -268])
  }
}
