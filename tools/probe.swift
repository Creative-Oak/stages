#!/usr/bin/env swift
// stage-probe — what can we read about Stage Manager's stages from outside?
//
//   swift probe.swift            one snapshot
//   swift probe.swift --watch    print a new snapshot every time the stages change
//   swift probe.swift --all      also list every window the system reports
//   swift probe.swift --ax       also dump WindowManager's accessibility tree
//
// Run it with the Xcode toolchain: `xcrun swift tools/probe.swift …`. To record fixtures for the
// reader tests, use `xcrun swift run stagesctl record <name> --note "…"`.
//
// Permissions for your terminal app (System Settings → Privacy & Security):
//   Screen & System Audio Recording  → needed for window titles (the overlays are found by title)
//   Accessibility                    → needed only for --ax

import AppKit
import ApplicationServices
import CoreGraphics

setvbuf(stdout, nil, _IOLBF, 0)

let args = CommandLine.arguments
let watch = args.contains("--watch")
let dumpAll = args.contains("--all")
let dumpAX = args.contains("--ax")

let systemOwners: Set<String> = [
  "WindowManager", "Dock", "Window Server", "Control Center", "SystemUIServer",
  "Notification Center", "NotificationCenter", "Spotlight", "TextInputMenuAgent",
  "Wallpaper", "loginwindow", "Siri", "Raycast",
  "CursorUIViewService", "Open and Save Panel Service", "PaperKitExtension",
  "Notification Centre", "Emoji & Symbols", "AutoFill", "universalAccessAuthWarn",
]

// MARK: - Window list

struct Win {
  let id: Int
  let z: Int            // 0 = frontmost
  let owner: String
  let pid: Int32
  let name: String?
  let layer: Int
  let bounds: CGRect
  let alpha: Double
  let onscreen: Bool
}

func windows() -> [Win] {
  guard let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
  var out: [Win] = []
  for (i, d) in raw.enumerated() {
    guard let id = d[kCGWindowNumber as String] as? Int,
          let bd = d[kCGWindowBounds as String] as? NSDictionary,
          let r = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
    out.append(Win(
      id: id, z: i,
      owner: d[kCGWindowOwnerName as String] as? String ?? "?",
      pid: Int32(d[kCGWindowOwnerPID as String] as? Int ?? 0),
      name: d[kCGWindowName as String] as? String,
      layer: d[kCGWindowLayer as String] as? Int ?? 0,
      bounds: r,
      alpha: d[kCGWindowAlpha as String] as? Double ?? 1,
      onscreen: d[kCGWindowIsOnscreen as String] as? Bool ?? false))
  }
  return out
}

/// Screen frames in CG (top-left origin) coordinates.
func screensCG() -> [CGRect] {
  guard let main = NSScreen.screens.first else { return [] }
  let H = main.frame.height
  return NSScreen.screens.map { s in
    CGRect(x: s.frame.minX, y: H - s.frame.maxY, width: s.frame.width, height: s.frame.height)
  }
}

func isAppWindow(_ w: Win) -> Bool {
  w.layer == 0 && !systemOwners.contains(w.owner) && w.alpha > 0 &&
    w.bounds.width >= 40 && w.bounds.height >= 40
}

func overlapRatio(_ a: CGRect, _ b: CGRect) -> CGFloat {
  let i = a.intersection(b)
  if i.isNull || i.isEmpty { return 0 }
  return (i.width * i.height) / max(1, a.width * a.height)
}

// MARK: - Analysis

struct Snapshot {
  var all: [Win]
  var overlays: [Win]
  var tiles: [(overlay: Win, members: [Win])]
  var center: [Win]
  var heuristicTiles: [[Win]]   // small, overlapping windows when no overlays are found
  var offscreen: [Win]
}

func clusters(_ ws: [Win]) -> [[Win]] {
  var groups: [[Win]] = []
  for w in ws {
    let hits = groups.indices.filter { i in groups[i].contains { $0.bounds.intersects(w.bounds) } }
    var merged = [w]
    for i in hits.reversed() { merged += groups.remove(at: i) }
    groups.append(merged)
  }
  return groups
}

func near(_ a: CGRect, _ b: CGRect, _ tol: CGFloat = 4) -> Bool {
  abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol &&
    abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
}

func analyse(_ all: [Win]) -> Snapshot {
  let overlays = all.filter { $0.name == "Gesture Blocking Overlay" }
  // Layer 19 overlays are strip tiles; the layer-0 one covers the centre stage.
  let tileOverlays = overlays.filter { $0.layer != 0 }
  let apps = all.filter(isAppWindow)
  let on = apps.filter { $0.onscreen }

  // A window belongs to a tile when it lines up with it (exact bounds), or sits
  // almost entirely inside it at thumbnail size (stacked windows in a grouped stage).
  var byOverlay: [Int: [Win]] = [:]
  var matched = Set<Int>()
  for w in apps {
    var hit: Win? = tileOverlays.first { near(w.bounds, $0.bounds) }
    if hit == nil {
      hit = tileOverlays
        .filter { o in overlapRatio(w.bounds, o.bounds) > 0.8 && w.bounds.width * w.bounds.height <= 1.2 * o.bounds.width * o.bounds.height }
        .max { overlapRatio(w.bounds, $0.bounds) < overlapRatio(w.bounds, $1.bounds) }
    }
    if let o = hit {
      byOverlay[o.id, default: []].append(w)
      matched.insert(w.id)
    }
  }
  var center = on.filter { !matched.contains($0.id) }

  let tiles = tileOverlays
    .sorted { (a, b) in a.onscreen != b.onscreen ? a.onscreen : a.bounds.minY < b.bounds.minY }
    .map { (overlay: $0, members: byOverlay[$0.id] ?? []) }

  // Fallback: windows that are tiny relative to their screen are probably strip thumbnails.
  var heuristic: [[Win]] = []
  if tileOverlays.isEmpty {
    let screens = screensCG()
    let small = center.filter { w in
      let c = CGPoint(x: w.bounds.midX, y: w.bounds.midY)
      guard let s = screens.first(where: { $0.contains(c) }) else { return false }
      return (w.bounds.width * w.bounds.height) < 0.06 * (s.width * s.height)
    }
    heuristic = clusters(small)
    let smallIDs = Set(small.map(\.id))
    center = center.filter { !smallIDs.contains($0.id) }
  }

  return Snapshot(all: all, overlays: overlays, tiles: tiles, center: center,
                  heuristicTiles: heuristic, offscreen: apps.filter { !$0.onscreen && !matched.contains($0.id) })
}

// MARK: - Output

func label(_ w: Win) -> String {
  let title = (w.name?.isEmpty == false) ? w.name! : "—"
  let b = w.bounds
  return "\(w.owner) · \"\(title)\" · #\(w.id) · z\(w.z) · " +
    String(format: "[%.0f,%.0f %.0f×%.0f]", b.minX, b.minY, b.width, b.height)
}

func signature(_ s: Snapshot) -> String {
  let t = s.tiles.map { $0.members.map { String($0.id) }.sorted().joined(separator: ",") }
  let h = s.heuristicTiles.map { $0.map { String($0.id) }.sorted().joined(separator: ",") }
  let c = s.center.map { String($0.id) }.sorted().joined(separator: ",")
  return (t + h + ["C:" + c]).joined(separator: "|")
}

func report(_ s: Snapshot) {
  print("── Stage Manager:", UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") == true ? "on" : "off (or unknown)")
  print("── Screens:", screensCG().map { String(format: "[%.0f,%.0f %.0f×%.0f]", $0.minX, $0.minY, $0.width, $0.height) }.joined(separator: " "))
  print("── Overlay windows (\"Gesture Blocking Overlay\"): \(s.overlays.count)")
  for o in s.overlays { print("   ", label(o)) }

  print("\n── CENTRE STAGE (\(s.center.count) windows)")
  for w in s.center.sorted(by: { $0.z < $1.z }) { print("   ", label(w)) }

  if !s.tiles.isEmpty {
    print("\n── STRIP, read from overlays (\(s.tiles.count) tiles)")
    let icons = s.all.filter { $0.owner == "WindowManager" && $0.name == "App Icon Window" }
    let hidden = s.tiles.filter { $0.overlay.onscreen }.allSatisfy { $0.overlay.bounds.maxX <= 0 }
    print("   (strip is \(hidden ? "hidden / slid off-screen" : "visible"))")
    for (i, t) in s.tiles.enumerated() {
      let n = icons.filter { t.overlay.bounds.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) }.count
      print("   Tile \(i + 1) — overlay #\(t.overlay.id) \(t.overlay.onscreen ? "" : "(overflow, not in strip) ")· \(n) app icon(s) " +
            String(format: "[%.0f,%.0f %.0f×%.0f]", t.overlay.bounds.minX, t.overlay.bounds.minY, t.overlay.bounds.width, t.overlay.bounds.height))
      if t.members.isEmpty { print("      (no app windows found under this overlay)") }
      for w in t.members.sorted(by: { $0.z < $1.z }) { print("      ", label(w)) }
    }
  }
  if !s.heuristicTiles.isEmpty {
    print("\n── STRIP, guessed from small overlapping windows (\(s.heuristicTiles.count) groups) — no overlays found")
    for (i, g) in s.heuristicTiles.enumerated() {
      print("   Group \(i + 1)")
      for w in g.sorted(by: { $0.z < $1.z }) { print("      ", label(w)) }
    }
  }

  print("\n── Not on screen (hidden, minimised, other Spaces, or off-stage): \(s.offscreen.count)")
  for w in s.offscreen.prefix(40) { print("   ", label(w)) }

  let wm = s.all.filter { $0.owner == "WindowManager" }
  print("\n── All windows owned by WindowManager: \(wm.count)")
  for w in wm { print("   ", label(w), "layer \(w.layer)", w.onscreen ? "onscreen" : "offscreen") }

  if dumpAll {
    print("\n── EVERY WINDOW")
    for w in s.all { print("   ", label(w), "layer \(w.layer)", w.onscreen ? "onscreen" : "offscreen", String(format: "α%.2f", w.alpha)) }
  }
}

// MARK: - Accessibility tree of WindowManager

func axAttr(_ el: AXUIElement, _ a: String) -> CFTypeRef? {
  var v: CFTypeRef?
  return AXUIElementCopyAttributeValue(el, a as CFString, &v) == .success ? v : nil
}
func axString(_ el: AXUIElement, _ a: String) -> String? { axAttr(el, a) as? String }
func axFrame(_ el: AXUIElement) -> String {
  var p = CGPoint.zero, s = CGSize.zero
  if let v = axAttr(el, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
  if let v = axAttr(el, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgSize, &s) }
  return String(format: "[%.0f,%.0f %.0f×%.0f]", p.x, p.y, s.width, s.height)
}

var axCount = 0
func axDump(_ el: AXUIElement, _ depth: Int) {
  guard depth <= 8, axCount < 500 else { return }
  axCount += 1
  var parts: [String] = []
  for (k, a) in [("role", kAXRoleAttribute), ("sub", kAXSubroleAttribute), ("id", "AXIdentifier"),
                 ("title", kAXTitleAttribute), ("desc", kAXDescriptionAttribute), ("help", kAXHelpAttribute)] {
    if let v = axString(el, a), !v.isEmpty { parts.append("\(k)=\"\(v)\"") }
  }
  if let v = axString(el, kAXValueAttribute), !v.isEmpty { parts.append("value=\"\(v)\"") }
  var actions: CFArray?
  if AXUIElementCopyActionNames(el, &actions) == .success, let a = actions as? [String], !a.isEmpty {
    parts.append("actions=\(a.joined(separator: ","))")
  }
  print(String(repeating: "  ", count: depth) + parts.joined(separator: " ") + " " + axFrame(el))
  let kids = axAttr(el, kAXChildrenAttribute) as? [AXUIElement] ?? []
  for k in kids { axDump(k, depth + 1) }
}

func runAX(_ all: [Win]) {
  let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
  guard AXIsProcessTrustedWithOptions(opts) else {
    print("\n⚠️  --ax needs Accessibility permission for your terminal app. Grant it, restart the terminal, run again.")
    return
  }
  let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first?.processIdentifier
    ?? all.first(where: { $0.owner == "WindowManager" })?.pid
  guard let pid = pid, pid > 0 else { print("\n⚠️  Couldn't find the WindowManager process."); return }
  print("\n── Accessibility tree of WindowManager (pid \(pid))")
  axDump(AXUIElementCreateApplication(pid), 0)
  if axCount >= 500 { print("   … truncated at 500 nodes") }
}

// MARK: - Main

if !CGPreflightScreenCaptureAccess() {
  print("⚠️  No Screen Recording permission: window titles will be missing, so the overlays can't be found by name.")
  print("   Grant it to your terminal app (Privacy & Security → Screen & System Audio Recording), restart the terminal, run again.\n")
  _ = CGRequestScreenCaptureAccess()
}

if watch {
  print("Watching. Switch stages, Shift-click to group, drag windows out. Ctrl-C to stop.\n")
  var last = ""
  while true {
    let s = analyse(windows())
    let sig = signature(s)
    if sig != last {
      let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
      print("\n═══════════ \(f.string(from: Date())) ═══════════")
      report(s)
      last = sig
    }
    Thread.sleep(forTimeInterval: 1.0)
  }
} else {
  let all = windows()
  report(analyse(all))
  if dumpAX { runAX(all) }
}
