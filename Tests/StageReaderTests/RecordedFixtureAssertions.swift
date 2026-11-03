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
  func overflowWithGroupedStage(_ name: String) throws {
    let s = try read(name)
    #expect(owners(s, .centre) == [["Ghostty", "Claude"]])
    #expect(owners(s, .strip) == [["AppCleaner"], ["Chess"], ["Calendar"], ["Safari"]])
    #expect(owners(s, .overflow) == [["Maps", "Mail"]])
    #expect(s.stages(.overflow)[0].appIconCount == 2)
    #expect(s.diagnostics.confidence == .high, "\(s.diagnostics.concerns)")
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
    // Strip shown: overflow sits where hidden strip tiles would (x −269).
    #expect(owners(s, .overflow) == [["Maps", "Mail"]])
    #expect(s.stages(.overflow)[0].frame.minX == -269)
  }

  @Test func stageManagerOffRecorded() throws {
    #expect(try read("stage-manager-off").unavailable == .stageManagerOff)
  }
}
