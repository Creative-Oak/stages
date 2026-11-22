import Foundation
import Testing
@testable import StageReader

@Suite struct RedactionTests {
  private func capture(_ windows: [RawWindow], tiles: [StripTile]? = nil) -> WindowCapture {
    WindowCapture(stageManagerEnabled: true, screenRecordingGranted: true,
                  displays: [DisplayInfo(id: 1, frame: Rect(x: 0, y: 0, w: 1470, h: 956), isMain: true)],
                  windows: windows, stripTiles: tiles)
  }

  private func window(_ id: UInt32, _ owner: String, _ name: String?) -> RawWindow {
    RawWindow(id: id, z: Int(id), owner: owner, pid: 1, name: name, layer: 0, bounds: Rect(x: 0, y: 0, w: 10, h: 10))
  }

  @Test func titlesBecomePlaceholdersAndWindowManagersStay() throws {
    let frames = [
      capture([window(1, "Safari", "Bank statement"), window(2, "Safari", "Plans"),
               window(3, "WindowManager", StageManagerConstants.overlayTitle), window(4, "Finder", nil)],
              tiles: [StripTile(windowIDs: [2], frame: Rect(x: 0, y: 0, w: 1, h: 1), title: "Plans")]),
      capture([window(2, "Safari", "Plans, renamed"), window(1, "Safari", "Bank statement")]),
    ]
    let out = WindowCapture.redactingTitles(frames)
    #expect(out[0].windows.map(\.name) == ["Safari window 1", "Safari window 2", StageManagerConstants.overlayTitle, nil])
    #expect(out[0].stripTiles?.first?.title == "Safari window 2")
    // The same window keeps its placeholder across frames, whatever its title became.
    #expect(out[1].windows.map(\.name) == ["Safari window 2", "Safari window 1"])
    let json = try String(decoding: Fixture.encoder().encode(out), as: UTF8.self)
    #expect(!json.contains("Bank") && !json.contains("Plans"))
  }

  @Test func aTileWithAnUnknownTitleIsStillRedacted() {
    let out = WindowCapture.redactingTitles([
      capture([window(1, "Mail", "Inbox")], tiles: [StripTile(windowIDs: [9], frame: Rect(x: 0, y: 0, w: 1, h: 1), title: "Secret")]),
    ])
    #expect(out[0].stripTiles?.first?.title == "tile")
  }
}
