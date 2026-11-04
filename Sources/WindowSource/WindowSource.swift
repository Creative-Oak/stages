import AppKit
import ApplicationServices
import CoreGraphics
import StageReader

/// Something that can produce a `WindowCapture`. Live in the app, fixtures in tests.
public protocol WindowSource: Sendable {
  func capture() -> WindowCapture
}

/// Replays fixture frames in order, then keeps returning the last one.
public final class FixtureWindowSource: WindowSource, @unchecked Sendable {
  private let frames: [WindowCapture]
  private var index = 0
  private let lock = NSLock()

  public init(_ frames: [WindowCapture]) { self.frames = frames }

  public func capture() -> WindowCapture {
    lock.withLock {
      defer { index = min(index + 1, frames.count - 1) }
      return frames[index]
    }
  }
}

public struct LiveWindowSource: WindowSource {
  public init() {}

  public func capture() -> WindowCapture {
    let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    var bundleIDs: [Int32: String?] = [:]
    var windows: [RawWindow] = []
    windows.reserveCapacity(raw.count)
    for (z, d) in raw.enumerated() {
      guard let id = d[kCGWindowNumber as String] as? Int,
            let bd = d[kCGWindowBounds as String] as? NSDictionary,
            let r = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
      let pid = Int32(d[kCGWindowOwnerPID as String] as? Int ?? 0)
      if bundleIDs[pid] == nil {
        bundleIDs[pid] = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
      }
      windows.append(RawWindow(
        id: UInt32(id), z: z,
        owner: d[kCGWindowOwnerName as String] as? String ?? "?",
        pid: pid,
        bundleID: bundleIDs[pid] ?? nil,
        name: d[kCGWindowName as String] as? String,
        layer: d[kCGWindowLayer as String] as? Int ?? 0,
        bounds: Rect(x: r.minX, y: r.minY, w: r.width, h: r.height),
        alpha: d[kCGWindowAlpha as String] as? Double ?? 1,
        onscreen: d[kCGWindowIsOnscreen as String] as? Bool ?? false))
    }

    let domain = StageManagerConstants.defaultsDomain as CFString
    CFPreferencesAppSynchronize(domain)
    func pref(_ key: String) -> CFPropertyList? { CFPreferencesCopyAppValue(key as CFString, domain) }

    return WindowCapture(
      capturedAt: Date(),
      stageManagerEnabled: (pref(StageManagerConstants.enabledKey) as? NSNumber)?.boolValue,
      screenRecordingGranted: CGPreflightScreenCaptureAccess(),
      appWindowGroupingBehavior: (pref(StageManagerConstants.groupingKey) as? NSNumber)?.intValue,
      stripAutoHide: (pref(StageManagerConstants.autoHideKey) as? NSNumber)?.boolValue,
      displays: Self.displays(),
      windows: windows,
      stripTiles: StripTiles.read())
  }

  public static func displays() -> [DisplayInfo] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    let main = CGMainDisplayID()
    return ids.prefix(Int(count)).map { id in
      let b = CGDisplayBounds(id)
      return DisplayInfo(id: id, frame: Rect(x: b.minX, y: b.minY, w: b.width, h: b.height), isMain: id == main)
    }
  }
}

/// Reads WindowManager's strip tiles from its accessibility tree: `AXList` `sm.strip` holds one
/// `AXButton` per strip stage, whose `AXWindowsIDs` are the stage's window IDs. Exact membership,
/// read-only, no pointer. Needs Accessibility; nil without it (the reader falls back to geometry).
public enum StripTiles {
  public static func read() -> [StripTile]? {
    guard AXIsProcessTrusted(),
          let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first?.processIdentifier
    else { return nil }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.15)
    var lists: [AXUIElement] = []
    func walk(_ e: AXUIElement, depth: Int) {
      guard depth < 4 else { return }
      if string(e, "AXIdentifier") == "sm.strip" { lists.append(e); return }
      for c in children(e) { walk(c, depth: depth + 1) }
    }
    // An unreadable tree (WindowManager busy, restarting) is "unknown", not "no tiles".
    guard !children(app).isEmpty else { return nil }
    walk(app, depth: 0)
    var tiles: [StripTile] = []
    for list in lists {
      for button in children(list) {
        var ids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(button, "AXWindowsIDs" as CFString, &ids) == .success,
              let numbers = ids as? [NSNumber] else { continue }
        tiles.append(StripTile(windowIDs: numbers.map { $0.uint32Value }, frame: frame(button) ?? Rect(x: 0, y: 0, w: 0, h: 0),
                               title: string(button, kAXTitleAttribute)))
      }
    }
    return tiles
  }

  private static func children(_ e: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success ? (v as? [AXUIElement] ?? []) : []
  }

  private static func string(_ e: AXUIElement, _ a: String) -> String? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v as? String : nil
  }

  private static func frame(_ e: AXUIElement) -> Rect? {
    var p: CFTypeRef?, s: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p) == .success,
          AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &s) == .success else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return Rect(x: point.x, y: point.y, w: size.width, h: size.height)
  }
}
