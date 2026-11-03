import AppKit
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
      windows: windows)
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
