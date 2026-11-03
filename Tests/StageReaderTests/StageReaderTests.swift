import Foundation
import Testing
@testable import StageReader

@Suite struct StageReaderTests {
  @Test func singleAppStages() {
    let s = StageReader.read(Scene.singles(stripX: 8).capture)
    #expect(s.isAvailable)
    #expect(s.stages(.centre).map(\.owners) == [["Claude"]])
    #expect(s.stages(.strip).map(\.owners) == [["Ghostty"], ["Calendar"], ["Safari"], ["Maps"]])
    #expect(s.stages(.strip).map(\.order) == [0, 1, 2, 3])
    #expect(s.stages(.overflow).isEmpty)
    #expect(s.stages(.strip).allSatisfy { $0.appIconCount == 1 })
    #expect(s.diagnostics.confidence == .high, "\(s.diagnostics.concerns)")
  }

  @Test func placeholdersAreNotMembers() {
    let s = StageReader.read(Scene.singles().capture)
    let members = s.stages.flatMap(\.windows).map(\.frame)
    #expect(!members.contains { $0.y == 456 })
    #expect(s.diagnostics.rejected.contains { $0.bounds == Rect(x: 0, y: 456, w: 500, h: 500) })
  }

  @Test func groupedStage() {
    var scene = Scene()
    scene.wmNoise()
    scene.stageWindow("Ghostty", "~/dev", Rect(x: 8, y: 41, w: 1454, h: 907), strip: false)
    // Verified geometry for System Settings + Claude grouped (strip hidden).
    let settings = scene.stageWindow("System Settings", "Displays", Rect(x: -237, y: 147, w: 95, h: 155), strip: true)
    let claude = scene.stageWindow("Claude", "Claude", Rect(x: -269, y: 166, w: 96, h: 153), strip: true)
    scene.stageWindow("Maps", "Copenhagen", Rect(x: -269, y: 344, w: 145, h: 156), strip: true)

    let s = StageReader.read(scene.capture)
    let strip = s.stages(.strip)
    #expect(strip.count == 2)
    #expect(strip[0].windowIDs == [settings, claude])
    #expect(strip[0].appIconCount == 2)
    #expect(strip[1].owners == ["Maps"])
    #expect(s.diagnostics.confidence == .high, "\(s.diagnostics.concerns)")
  }

  @Test func stripHiddenOffscreen() {
    // Strip hidden: thumbnails at negative x and possibly reported offscreen. Still the strip.
    let s = StageReader.read(Scene.singles(stripX: -269, onscreen: false).capture)
    #expect(s.stages(.strip).map(\.owners) == [["Ghostty"], ["Calendar"], ["Safari"], ["Maps"]])
    #expect(s.stages(.overflow).isEmpty)
  }

  @Test func overflowStage() {
    for (stripX, onscreen) in [(-269.0, true), (-269.0, false), (8.0, true)] {
      var scene = Scene.singles(stripX: stripX, onscreen: onscreen)
      // Verified: overflow sits further left, offscreen, with its own overlay and icon.
      let mail = scene.stageWindow("Mail", "Inbox", Rect(x: -553, y: 355, w: 253, h: 159), strip: true, onscreen: false)
      let s = StageReader.read(scene.capture)
      #expect(s.stages(.strip).count == 4, "strip at \(stripX)")
      #expect(s.stages(.overflow).map(\.windowIDs) == [[mail]], "strip at \(stripX)")
      #expect(s.stages(.overflow).first?.appIconCount == 1)
    }
  }

  @Test func offscreenInColumnIsOverflowWhenOthersOnscreen() {
    var scene = Scene.singles(stripX: 8, onscreen: true)
    let hidden = scene.stageWindow("Notes", "Shopping", Rect(x: 8, y: 840, w: 120, h: 100), strip: true, onscreen: false)
    let s = StageReader.read(scene.capture)
    #expect(s.stages(.overflow).map(\.windowIDs) == [[hidden]])
  }

  @Test func overlayLayerDecidesCentre() {
    var scene = Scene.singles()
    // A second centre window, overlapping the first.
    let notes = scene.stageWindow("Notes", "Notes", Rect(x: 717, y: 40, w: 734, h: 904), strip: false)
    let s = StageReader.read(scene.capture)
    #expect(s.stages(.centre).count == 1)
    #expect(s.stages(.centre)[0].windowIDs.contains(notes))
    #expect(s.stages(.centre)[0].owners == ["Claude", "Notes"])
  }

  @Test func matchingIsOneToOneWithTolerance() {
    var scene = Scene()
    let a = scene.appWindow("Safari", "A", Rect(x: 100, y: 100, w: 800, h: 600), onscreen: true)
    let b = scene.appWindow("Safari", "B", Rect(x: 103, y: 102, w: 800, h: 600), onscreen: false)
    scene.overlay(Rect(x: 101, y: 100, w: 800, h: 600), layer: 0)   // closer to a
    scene.overlay(Rect(x: 120, y: 100, w: 800, h: 600), layer: 0)   // out of tolerance for both, onscreen
    let s = StageReader.read(scene.capture)
    #expect(s.stages(.centre).first?.windowIDs == [a])
    #expect(s.diagnostics.rejected.contains { $0.windowID == b })
    #expect(s.diagnostics.unmatchedOverlayIDs.count == 1)
    #expect(s.diagnostics.confidence == .low)
  }

  @Test func ignoresExcludedOwnersAndTinyWindows() {
    var scene = Scene.singles()
    scene.appWindow("Open and Save Panel Service", "Open", Rect(x: 8, y: 41, w: 1454, h: 907), onscreen: true)
    scene.appWindow("Safari", "tiny", Rect(x: 8, y: 41, w: 30, h: 30), onscreen: true)
    let s = StageReader.read(scene.capture)
    #expect(s.stages(.centre).first?.owners == ["Claude"])
  }

  @Test func stageManagerOff() {
    var scene = Scene.singles()
    scene.stageManagerEnabled = false
    let s = StageReader.read(scene.capture)
    #expect(s.unavailable == .stageManagerOff)
    #expect(s.stages.isEmpty)
  }

  @Test func noOverlaysIsUnavailableNotGuessed() {
    var scene = Scene()
    scene.wmNoise()
    scene.appWindow("Safari", "Apple", Rect(x: 8, y: 41, w: 1454, h: 907), onscreen: true)
    scene.stageManagerEnabled = nil   // unreadable preference: must still not guess
    #expect(StageReader.read(scene.capture).unavailable == .noOverlays)
  }

  @Test func noScreenRecording() {
    var scene = Scene.singles()
    scene.screenRecordingGranted = false
    #expect(StageReader.read(scene.capture).unavailable == .noScreenRecording)
  }

  @Test func twoDisplays() {
    var scene = Scene.singles()
    scene.displays.append(DisplayInfo(id: 2, frame: Rect(x: 1470, y: -200, w: 1920, h: 1080), isMain: false))
    let ext = scene.stageWindow("Xcode", "Stages", Rect(x: 1600, y: -150, w: 1600, h: 900), strip: false)
    let s = StageReader.read(scene.capture)
    #expect(s.stages(.centre).map(\.displayID) == [1, 2])
    #expect(s.stages(.centre)[1].windowIDs == [ext])
    #expect(s.stages(.strip).allSatisfy { $0.displayID == 1 })
  }

  @Test func identityIsWindowIDsNotOverlayIDs() {
    // Overlay IDs get reused; the stage must be identified by its window IDs.
    let a = StageReader.read(Scene.singles().capture)
    var reordered = Scene.singles()
    reordered.windows = reordered.windows.map { w in
      var w = w
      if w.owner == "WindowManager" { w.id += 10_000 }
      return w
    }
    let b = StageReader.read(reordered.capture)
    #expect(a.stages.map(\.windowIDs) == b.stages.map(\.windowIDs))
    #expect(a.signature == b.signature)
  }
}

@Suite struct StabilityGateTests {
  /// Mid-switch: the centre overlay is shrinking toward the strip and a 500×500 placeholder
  /// happens to sit under an in-between overlay.
  static func midAnimation(_ step: Double) -> WindowCapture {
    var scene = Scene()
    scene.wmNoise()
    scene.appWindow("Claude", "Claude", Rect(x: 8, y: 41, w: 1454, h: 907), onscreen: true)
    scene.overlay(Rect(x: 8 - step, y: 41, w: 1454 - 4 * step, h: 907 - 3 * step), layer: 0)
    scene.appWindow("Safari", nil, Rect(x: 0, y: 456, w: 500, h: 500), onscreen: true)
    scene.overlay(Rect(x: 2, y: 455, w: 498, h: 502), layer: 0)
    return scene.capture
  }

  @Test func midAnimationFramesAreNotCommitted() {
    let settled = Scene.singles().capture
    var gate = StabilityGate()
    let frames = [Self.midAnimation(80), Self.midAnimation(40), settled, settled, settled]
    let committed = frames.map { gate.feed(StageReader.read($0)) }
    #expect(committed.map { $0 != nil } == [false, false, false, true, false])
    #expect(committed[3]?.stages(.centre).first?.owners == ["Claude"])
  }

  @Test func midAnimationReadsDifferFromEachOther() {
    let a = StageReader.read(Self.midAnimation(80)), b = StageReader.read(Self.midAnimation(40))
    #expect(a.signature != b.signature)
  }

  @Test func commitsAgainOnlyOnChange() {
    var gate = StabilityGate()
    let one = StageReader.read(Scene.singles().capture)
    var scene = Scene.singles()
    scene.stageWindow("Mail", "Inbox", Rect(x: -553, y: 355, w: 253, h: 159), strip: true, onscreen: false)
    let two = StageReader.read(scene.capture)
    let results = [one, one, one, two, two, one, one].map { gate.feed($0) != nil }
    #expect(results == [false, true, false, false, true, false, true])
  }

  @Test func hiddenStripSlidingDoesNotRecommit() {
    var gate = StabilityGate()
    _ = gate.feed(StageReader.read(Scene.singles(stripX: -269).capture))
    #expect(gate.feed(StageReader.read(Scene.singles(stripX: -269).capture)) != nil)
    _ = gate.feed(StageReader.read(Scene.singles(stripX: -200).capture))
    #expect(gate.feed(StageReader.read(Scene.singles(stripX: -200).capture)) == nil)
  }
}

@Suite struct RecordedFixtureTests {
  static func fixture(_ name: String) throws -> Fixture {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Fixture.decoder().decode(Fixture.self, from: Data(contentsOf: url))
  }

  static var allNames: [String] {
    let dir = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
      .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
  }

  @Test func noScreenRecordingRecorded() throws {
    let f = try Self.fixture("no-screen-recording")
    #expect(StageReader.read(f.frames[0]).unavailable == .noScreenRecording)
  }

  @Test(arguments: allNames) func everyFixtureDecodesAndReads(_ name: String) throws {
    let f = try Self.fixture(name)
    #expect(!f.frames.isEmpty)
    for frame in f.frames { _ = StageReader.read(frame) }
  }
}

@Suite struct CentreWithoutOverlayTests {
  @Test func onscreenUnmatchedWindowsAreCentre() {
    var scene = Scene.singles()
    let ghostty = scene.appWindow("Ghostty", "~/dev", Rect(x: 8, y: 41, w: 723, h: 907), onscreen: true)
    let s = StageReader.read(scene.capture)
    #expect(s.stages(.centre).first?.windowIDs.contains(ghostty) == true)
    #expect(s.diagnostics.centreWithoutOverlay == [ghostty])
    #expect(s.stages(.centre).first?.windows.first { $0.id == ghostty }?.overlayID == nil)
  }

  @Test func offscreenLeftoverOverlaysDoNotLowerConfidence() {
    var scene = Scene.singles(stripX: 8)
    scene.overlay(Rect(x: 381, y: 221, w: 1454, h: 865), layer: 0, onscreen: false)
    scene.overlay(Rect(x: -248, y: 684, w: 205, h: 91), layer: 19, onscreen: false)
    let s = StageReader.read(scene.capture)
    #expect(s.diagnostics.unmatchedOverlayIDs.count == 2)
    #expect(s.diagnostics.confidence == .high, "\(s.diagnostics.concerns)")
  }
}
