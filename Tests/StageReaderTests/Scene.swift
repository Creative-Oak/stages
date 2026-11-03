import Foundation
import StageReader

/// Builds synthetic captures. Geometry is taken from a live capture on a 1470×956 MacBook
/// display (strip hidden at x −269, overflow at x −553, placeholders at [0,456]).
struct Scene {
  var windows: [RawWindow] = []
  var displays = [DisplayInfo(id: 1, frame: Rect(x: 0, y: 0, w: 1470, h: 956), isMain: true)]
  var stageManagerEnabled: Bool? = true
  var screenRecordingGranted = true
  private var nextID: UInt32 = 100
  private var pids: [String: Int32] = [:]

  private mutating func add(owner: String, name: String?, layer: Int, _ r: Rect, onscreen: Bool, alpha: Double = 1) -> UInt32 {
    nextID += 1
    let pid = pids[owner] ?? Int32(500 + pids.count)
    pids[owner] = pid
    windows.append(RawWindow(id: nextID, z: windows.count, owner: owner, pid: pid,
                             bundleID: owner == "WindowManager" ? nil : "com.example.\(owner.lowercased())",
                             name: name, layer: layer, bounds: r, alpha: alpha, onscreen: onscreen))
    return nextID
  }

  /// An app window plus the overlay Stage Manager puts on it.
  @discardableResult
  mutating func stageWindow(_ owner: String, _ title: String, _ r: Rect, strip: Bool, onscreen: Bool = true,
                            icon: Bool = true) -> UInt32 {
    let id = add(owner: owner, name: title, layer: 0, r, onscreen: onscreen)
    _ = add(owner: "WindowManager", name: StageManagerConstants.overlayTitle,
            layer: strip ? StageManagerConstants.stripLayer : 0, r, onscreen: onscreen)
    if strip && icon {
      _ = add(owner: "WindowManager", name: StageManagerConstants.appIconTitle, layer: 19,
              Rect(x: r.x - 23, y: r.maxY - 68, w: 66, h: 82), onscreen: onscreen)
    }
    return id
  }

  @discardableResult
  mutating func appWindow(_ owner: String, _ title: String?, _ r: Rect, onscreen: Bool = false) -> UInt32 {
    add(owner: owner, name: title, layer: 0, r, onscreen: onscreen)
  }

  @discardableResult
  mutating func overlay(_ r: Rect, layer: Int, onscreen: Bool = true) -> UInt32 {
    add(owner: "WindowManager", name: StageManagerConstants.overlayTitle, layer: layer, r, onscreen: onscreen)
  }

  /// WindowManager noise that must be ignored.
  mutating func wmNoise() {
    _ = add(owner: "WindowManager", name: nil, layer: 0, Rect(x: 1e9, y: 1e9, w: 1, h: 1), onscreen: true)
    _ = add(owner: "WindowManager", name: "Wallpaper", layer: -2147483624, Rect(x: 0, y: 0, w: 1470, h: 956), onscreen: true)
    _ = add(owner: "WindowManager", name: "Event Shield Window", layer: 0, Rect(x: 0, y: 0, w: 1470, h: 956), onscreen: false)
    _ = add(owner: "Dock", name: "Dock", layer: 20, Rect(x: 0, y: 900, w: 1470, h: 56), onscreen: true)
  }

  /// Invisible placeholder windows apps keep around (offscreen, never matched).
  mutating func placeholders() {
    appWindow("Safari", nil, Rect(x: 0, y: 456, w: 500, h: 500))
    appWindow("Calendar", nil, Rect(x: 0, y: 456, w: 64, h: 64))
  }

  var capture: WindowCapture {
    WindowCapture(stageManagerEnabled: stageManagerEnabled, screenRecordingGranted: screenRecordingGranted,
                  displays: displays, windows: windows)
  }

  /// Centre Claude + four single-app strip stages, strip shown at `stripX` or hidden at −269.
  static func singles(stripX: Double = -269, onscreen: Bool = true) -> Scene {
    var s = Scene()
    s.wmNoise()
    s.stageWindow("Claude", "Claude", Rect(x: 8, y: 41, w: 1454, h: 907), strip: false)
    s.stageWindow("Ghostty", "~/dev", Rect(x: stripX, y: 164, w: 197, h: 174), strip: true, onscreen: onscreen)
    s.stageWindow("Calendar", "Calendar", Rect(x: stripX, y: 344, w: 146, h: 131), strip: true, onscreen: onscreen)
    s.stageWindow("Safari", "Apple", Rect(x: stripX, y: 500, w: 197, h: 162), strip: true, onscreen: onscreen)
    s.stageWindow("Maps", "Copenhagen", Rect(x: stripX, y: 669, w: 145, h: 156), strip: true, onscreen: onscreen)
    s.placeholders()
    return s
  }
}

extension StageSnapshot {
  func stages(_ p: Stage.Position) -> [Stage] { stages.filter { $0.position == p } }
}
