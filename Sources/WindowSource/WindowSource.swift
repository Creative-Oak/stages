import AppKit
import ApplicationServices
import CoreGraphics
import os
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
  /// Read WindowManager's strip tiles (an AX round trip, up to 0.15 s if it's busy). Off for the
  /// quick read the switcher does as it opens.
  public var readTiles: Bool
  public init(readTiles: Bool = true) { self.readTiles = readTiles }

  public func capture() -> WindowCapture {
    let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    var bundleIDs = Self.bundleIDCache.withLock { $0 }
    var seen = Set<Int32>()
    var windows: [RawWindow] = []
    windows.reserveCapacity(raw.count)
    for (z, d) in raw.enumerated() {
      guard let id = d[kCGWindowNumber as String] as? Int,
            let bd = d[kCGWindowBounds as String] as? NSDictionary,
            let r = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
      let pid = Int32(d[kCGWindowOwnerPID as String] as? Int ?? 0)
      seen.insert(pid)
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

    // Keep only live pids, so a reused pid is looked up again.
    let live = bundleIDs.filter { seen.contains($0.key) }
    Self.bundleIDCache.withLock { $0 = live }

    let domain = StageManagerConstants.defaultsDomain as CFString
    CFPreferencesAppSynchronize(domain)
    func pref(_ key: String) -> CFPropertyList? { CFPreferencesCopyAppValue(key as CFString, domain) }

    return WindowCapture(
      capturedAt: Date(),
      stageManagerEnabled: (pref(StageManagerConstants.enabledKey) as? NSNumber)?.boolValue,
      screenRecordingGranted: Self.screenRecordingGranted(),
      appWindowGroupingBehavior: (pref(StageManagerConstants.groupingKey) as? NSNumber)?.intValue,
      stripAutoHide: (pref(StageManagerConstants.autoHideKey) as? NSNumber)?.boolValue,
      displays: Self.displays(),
      windows: windows,
      stripTiles: readTiles ? Self.tiles(for: windows) : nil)
  }

  /// The strip tiles, read from WindowManager's AX tree only when the window structure (layer 0
  /// ids and onscreen) changed lately: tiles only regroup when windows come, go or move on or off
  /// screen. After a change it's read until three reads in a row saw the same structure (AX can
  /// lag the window list), then reused, refreshed at least every 10 s.
  private static func tiles(for windows: [RawWindow]) -> [StripTile]? {
    var h = Hasher()
    for w in windows where w.layer == 0 { h.combine(w.id); h.combine(w.onscreen) }
    let sig = h.finalize()
    let now = ContinuousClock.now
    if let c = tileCache.withLock({ $0 }), c.signature == sig, c.sameReads >= 3, now - c.readAt < .seconds(10) {
      return c.tiles
    }
    let tiles = StripTiles.read()
    tileCache.withLock { c in
      let same = c?.signature == sig ? (c?.sameReads ?? 0) + 1 : 1
      // An unreadable tree (nil) is never reused.
      c = tiles == nil ? nil : TileCache(signature: sig, tiles: tiles, readAt: now, sameReads: same)
    }
    return tiles
  }

  private struct TileCache { var signature: Int; var tiles: [StripTile]?; var readAt: ContinuousClock.Instant; var sameReads: Int }
  private static let tileCache = OSAllocatedUnfairLock<TileCache?>(initialState: nil)

  /// pid → bundle ID across polls. `NSRunningApplication.bundleIdentifier` is a LaunchServices
  /// round trip per process, the biggest cost of a poll when made every time.
  private static let bundleIDCache = OSAllocatedUnfairLock<[Int32: String?]>(initialState: [:])

  /// `CGPreflightScreenCaptureAccess()` asks TCC each time (~7.6 ms measured 2026-11-04), and
  /// this runs on every poll; the answer is reused for 2 s (a grant is noticed within that).
  private static let screenRecording = OSAllocatedUnfairLock<(granted: Bool, at: ContinuousClock.Instant)?>(initialState: nil)
  static func screenRecordingGranted() -> Bool {
    if let c = screenRecording.withLock({ $0 }), ContinuousClock.now - c.at < .seconds(2) { return c.granted }
    let granted = CGPreflightScreenCaptureAccess()
    screenRecording.withLock { $0 = (granted, .now) }
    return granted
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
    guard AXIsProcessTrusted(), let pid = windowManagerPID() else { return nil }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.15)
    var lists: [AXUIElement] = []
    func walk(_ e: AXUIElement, depth: Int) {
      guard depth < 4 else { return }
      if string(e, "AXIdentifier") == "sm.strip" { lists.append(e); return }
      for c in children(e) { walk(c, depth: depth + 1) }
    }
    // An unreadable tree (WindowManager busy, restarting) is "unknown", not "no tiles". Look its
    // pid up again next time, in case it restarted.
    guard !children(app).isEmpty else { cachedPID.withLock { $0 = nil }; return nil }
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

  private static let cachedPID = OSAllocatedUnfairLock<pid_t?>(initialState: nil)

  /// WindowManager's pid, kept between polls (a LaunchServices query otherwise).
  private static func windowManagerPID() -> pid_t? {
    if let pid = cachedPID.withLock({ $0 }), kill(pid, 0) == 0 { return pid }
    let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first?.processIdentifier
    cachedPID.withLock { $0 = pid }
    return pid
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
