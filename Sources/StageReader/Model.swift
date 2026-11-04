import Foundation

/// A rectangle in CG global space (top-left origin, points). Kept free of CoreGraphics so the
/// reader stays pure and fixtures stay readable.
public struct Rect: Codable, Hashable, Sendable, CustomStringConvertible {
  public var x: Double
  public var y: Double
  public var w: Double
  public var h: Double

  public init(x: Double, y: Double, w: Double, h: Double) {
    self.x = x; self.y = y; self.w = w; self.h = h
  }

  public var minX: Double { x }
  public var minY: Double { y }
  public var maxX: Double { x + w }
  public var maxY: Double { y + h }
  public var midX: Double { x + w / 2 }
  public var midY: Double { y + h / 2 }
  public var area: Double { max(0, w) * max(0, h) }

  /// True when the two rectangles share a region of positive area (touching edges don't count).
  public func overlaps(_ o: Rect) -> Bool {
    min(maxX, o.maxX) > max(minX, o.minX) && min(maxY, o.maxY) > max(minY, o.minY)
  }

  public func intersectionArea(_ o: Rect) -> Double {
    max(0, min(maxX, o.maxX) - max(minX, o.minX)) * max(0, min(maxY, o.maxY) - max(minY, o.minY))
  }

  public func contains(x px: Double, y py: Double) -> Bool {
    px >= minX && px < maxX && py >= minY && py < maxY
  }

  public func union(_ o: Rect) -> Rect {
    let x0 = min(minX, o.minX), y0 = min(minY, o.minY)
    return Rect(x: x0, y: y0, w: max(maxX, o.maxX) - x0, h: max(maxY, o.maxY) - y0)
  }

  public var description: String {
    String(format: "[%.0f,%.0f %.0f×%.0f]", x, y, w, h)
  }
}

/// One entry of `CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)`, as captured.
public struct RawWindow: Codable, Hashable, Sendable {
  /// `kCGWindowNumber`. Stable while the window lives; overlay IDs get reused.
  public var id: UInt32
  /// Position in the list; 0 = frontmost.
  public var z: Int
  public var owner: String
  public var pid: Int32
  /// Resolved from the pid at capture time (`NSRunningApplication`); nil for daemons.
  public var bundleID: String?
  /// `kCGWindowName`; nil without Screen Recording permission.
  public var name: String?
  public var layer: Int
  public var bounds: Rect
  public var alpha: Double
  public var onscreen: Bool

  public init(id: UInt32, z: Int, owner: String, pid: Int32, bundleID: String? = nil, name: String?,
              layer: Int, bounds: Rect, alpha: Double = 1, onscreen: Bool = true) {
    self.id = id; self.z = z; self.owner = owner; self.pid = pid; self.bundleID = bundleID
    self.name = name; self.layer = layer; self.bounds = bounds; self.alpha = alpha; self.onscreen = onscreen
  }
}

public struct DisplayInfo: Codable, Hashable, Sendable {
  public var id: UInt32
  /// `CGDisplayBounds`, CG global space.
  public var frame: Rect
  public var isMain: Bool

  public init(id: UInt32, frame: Rect, isMain: Bool) {
    self.id = id; self.frame = frame; self.isMain = isMain
  }
}

/// One strip tile from WindowManager's accessibility tree (`AXList sm.strip` → `AXButton`):
/// the stage's exact window IDs (`AXWindowsIDs`), its frame and its front window's title.
public struct StripTile: Codable, Hashable, Sendable {
  public var windowIDs: [UInt32]
  public var frame: Rect
  public var title: String?

  public init(windowIDs: [UInt32], frame: Rect, title: String?) {
    self.windowIDs = windowIDs; self.frame = frame; self.title = title
  }
}

/// Everything the reader needs from one poll. This is also the fixture frame format.
public struct WindowCapture: Codable, Hashable, Sendable {
  public var capturedAt: Date
  /// `com.apple.WindowManager` `GloballyEnabled`; nil if unreadable.
  public var stageManagerEnabled: Bool?
  /// `CGPreflightScreenCaptureAccess()`. Without it window titles are nil.
  public var screenRecordingGranted: Bool
  /// `com.apple.WindowManager` `AppWindowGroupingBehavior` (recorded to answer an open question).
  public var appWindowGroupingBehavior: Int?
  /// `com.apple.WindowManager` `AutoHide` (strip hidden until hovered).
  public var stripAutoHide: Bool?
  public var displays: [DisplayInfo]
  public var windows: [RawWindow]
  /// WindowManager's strip tiles, when its accessibility tree could be read (Accessibility
  /// granted); nil otherwise. Overflow stages have no tiles.
  public var stripTiles: [StripTile]?

  public init(capturedAt: Date = Date(timeIntervalSince1970: 0), stageManagerEnabled: Bool?,
              screenRecordingGranted: Bool, appWindowGroupingBehavior: Int? = nil, stripAutoHide: Bool? = nil,
              displays: [DisplayInfo], windows: [RawWindow], stripTiles: [StripTile]? = nil) {
    self.capturedAt = capturedAt; self.stageManagerEnabled = stageManagerEnabled
    self.screenRecordingGranted = screenRecordingGranted
    self.appWindowGroupingBehavior = appWindowGroupingBehavior; self.stripAutoHide = stripAutoHide
    self.displays = displays; self.windows = windows; self.stripTiles = stripTiles
  }
}

/// A recorded scenario: one or more captures taken ~200 ms apart.
public struct Fixture: Codable, Sendable {
  public var name: String
  /// What the person recording it set up, in their words.
  public var note: String
  public var intervalMs: Int
  public var frames: [WindowCapture]

  public init(name: String, note: String, intervalMs: Int, frames: [WindowCapture]) {
    self.name = name; self.note = note; self.intervalMs = intervalMs; self.frames = frames
  }

  public static func decoder() -> JSONDecoder {
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
  }

  public static func encoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return e
  }
}

/// Slot keys, in assignment order: 1–9, then 0, then a–z (36 in all). A stage's slot is the key
/// that reaches it (switcher, Raycast Hyper+key).
public enum SlotKeys {
  public static let all: [String] = (1...9).map(String.init) + ["0"] + "abcdefghijklmnopqrstuvwxyz".map(String.init)

  /// Position in assignment order; nil if not a slot key.
  public static func index(of key: String) -> Int? { all.firstIndex(of: key.lowercased()) }

  public static func isValid(_ key: String) -> Bool { index(of: key) != nil }
}
