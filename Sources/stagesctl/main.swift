// stagesctl — debug CLI for the stage reader.
//
//   stagesctl read [fixture.json] [--frame N] [--json]   read live (or a fixture) and explain it
//   stagesctl watch                                      print each committed snapshot + poll cost
//   stagesctl record <name> --note "…" [--frames N] [--interval ms] [--delay s] [--out dir] [--keep-titles]
//   stagesctl tiles                                      list WindowManager's strip tiles (AX)
//   stagesctl tile <n> focus-add                         AXFocused on tile n, then AXAddToStage
//   stagesctl tile <n> press|add|click|shift-click       AXPress / AXAddToStage / a synthetic
//                                                        click or Shift-click on tile n (M6 spike)
//   stagesctl gestures                                   spike: print the gesture events a global
//                                                        event tap receives (needs Accessibility)
//
// Run with: xcrun swift run stagesctl …  (never bare `swift`: see README)

import AppKit
import StageReader
import WindowSource

setvbuf(stdout, nil, _IOLBF, 0)

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "read" : args.removeFirst()

func flag(_ name: String) -> Bool {
  guard let i = args.firstIndex(of: name) else { return false }
  args.remove(at: i); return true
}
func option(_ name: String) -> String? {
  guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
  let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}
func fail(_ message: String) -> Never {
  FileHandle.standardError.write((message + "\n").data(using: .utf8)!); exit(1)
}

func warnPermissions(_ c: WindowCapture) {
  if !c.screenRecordingGranted {
    print("⚠️  No Screen Recording permission for this terminal: window titles are missing, so stages can't be read.")
    print("   System Settings → Privacy & Security → Screen & System Audio Recording → enable your terminal, restart it.\n")
  }
}

func label(_ w: StageWindow) -> String {
  "\(w.owner) · \"\(w.title ?? "—")\" · #\(w.id) · z\(w.z) · \(w.frame) · \(w.overlayID.map { "overlay #\($0)" } ?? "no overlay (onscreen)")"
}

func report(_ s: StageSnapshot, capture: WindowCapture? = nil) {
  if let c = capture {
    print("── Stage Manager: \(c.stageManagerEnabled.map { $0 ? "on" : "off" } ?? "unknown")",
          "· AutoHide: \(c.stripAutoHide.map(String.init) ?? "?")",
          "· AppWindowGroupingBehavior: \(c.appWindowGroupingBehavior.map(String.init) ?? "?")")
    print("── Displays:", c.displays.map { "\($0.id)\($0.isMain ? "*" : "") \($0.frame)" }.joined(separator: "  "))
  }
  if let u = s.unavailable { print("── UNAVAILABLE: \(u.message)"); return }
  let d = s.diagnostics
  print("── \(d.rawWindowCount) windows · \(d.overlayCount) overlays · \(d.appIconCount) app icons · \(d.matches.count) matches · confidence \(d.confidence.rawValue)")
  for st in s.stages {
    let icons = st.appIconCount.map { " · \($0) icon(s)" } ?? ""
    print("\n   \(st.position.rawValue.uppercased()) \(st.order) · display \(st.displayID) · \(st.frame)\(icons) · \(st.owners.joined(separator: " + "))")
    for w in st.windows { print("      ", label(w)) }
  }
  if !d.concerns.isEmpty {
    print("\n── Concerns")
    for c in d.concerns { print("    •", c) }
  }
  print("\n── Classification")
  for c in d.classification { print("   ", c) }
  print("\n── Rejected candidates (\(d.rejected.count); \(d.filteredCount) tiny or transparent not listed)")
  for r in d.rejected.prefix(40) { print("    \(r.owner) · \"\(r.title ?? "—")\" · #\(r.windowID) · \(r.bounds) · \(r.reason)") }
  print("\n── signature: \(s.signature)")
}

func json<T: Encodable>(_ v: T) -> String {
  String(data: try! Fixture.encoder().encode(v), encoding: .utf8)!
}

/// Replace app window titles with stable placeholders so fixtures can be committed.
/// WindowManager's own titles (overlay, icon) are kept: the reader needs them.
func redact(_ frames: [WindowCapture]) -> [WindowCapture] {
  var names: [UInt32: String] = [:]
  var perOwner: [String: Int] = [:]
  return frames.map { c in
    var c = c
    c.windows = c.windows.map { w in
      var w = w
      guard w.owner != StageManagerConstants.ownerName, let n = w.name, !n.isEmpty else { return w }
      if names[w.id] == nil {
        perOwner[w.owner, default: 0] += 1
        names[w.id] = "\(w.owner) window \(perOwner[w.owner]!)"
      }
      w.name = names[w.id]
      return w
    }
    return c
  }
}

switch command {
case "read":
  let asJSON = flag("--json")
  let frameIndex = option("--frame").flatMap(Int.init)
  let capture: WindowCapture
  if let path = args.first {
    guard let data = FileManager.default.contents(atPath: path) else { fail("can't read \(path)") }
    let fixture = try Fixture.decoder().decode(Fixture.self, from: data)
    print("── Fixture \(fixture.name): \(fixture.note) (\(fixture.frames.count) frame(s))")
    capture = fixture.frames[min(frameIndex ?? fixture.frames.count - 1, fixture.frames.count - 1)]
  } else {
    capture = LiveWindowSource().capture()
    warnPermissions(capture)
  }
  let snapshot = StageReader.read(capture)
  if asJSON { print(json(snapshot)) } else { report(snapshot, capture: capture) }

case "watch":
  let source = LiveWindowSource()
  warnPermissions(source.capture())
  print("Watching. Switch stages, Shift-click to group, drag windows out. Ctrl-C to stop.\n")
  let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss.SSS"
  var reads = 0, unstable = 0, lastSig = ""
  var cpuStart = clock()
  var wallStart = Date()
  let poller = StagePoller(source: source)   // the poll loop holds it weakly; keep it alive here
  poller.onRead = { s in
    reads += 1
    if s.signature != lastSig { unstable += 1 }
    lastSig = s.signature
    let wall = Date().timeIntervalSince(wallStart)
    if wall >= 30 {
      let cpu = Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC)
      print(String(format: "   · %d reads in %.0fs (%d changed), CPU %.2f%% of one core", reads, wall, unstable, 100 * cpu / wall))
      reads = 0; unstable = 0; cpuStart = clock(); wallStart = Date()
    }
  }
  poller.onCommit = { s in
    print("\n═══════════ \(formatter.string(from: s.capturedAt)) committed ═══════════")
    report(s)
  }
  poller.start()
  withExtendedLifetime(poller) { RunLoop.main.run() }

case "record":
  guard let name = args.first, !name.hasPrefix("--") else { fail("usage: stagesctl record <name> --note \"…\"") }
  args.removeFirst()
  let note = option("--note") ?? ""
  let frames = option("--frames").flatMap(Int.init) ?? 1
  let interval = option("--interval").flatMap(Int.init) ?? 200
  let delay = option("--delay").flatMap(Double.init) ?? 0
  let out = option("--out") ?? "Tests/StageReaderTests/Fixtures"
  let keepTitles = flag("--keep-titles")

  let source = LiveWindowSource()
  if delay > 0 {
    print("Recording in \(delay)s…")
    Thread.sleep(forTimeInterval: delay)
  }
  var captures: [WindowCapture] = []
  for i in 0..<frames {
    if i > 0 { Thread.sleep(forTimeInterval: Double(interval) / 1000) }
    captures.append(source.capture())
  }
  warnPermissions(captures[0])
  if !keepTitles { captures = redact(captures) }
  let fixture = Fixture(name: name, note: note, intervalMs: interval, frames: captures)
  try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
  let path = (out as NSString).appendingPathComponent("\(name).json")
  try Fixture.encoder().encode(fixture).write(to: URL(fileURLWithPath: path))
  print("Wrote \(frames) frame(s) to \(path)\(keepTitles ? "" : " (app window titles redacted)")\n")
  report(StageReader.read(captures.last!), capture: captures.last!)

case "tiles", "tile":
  // M6 spike: WindowManager publishes the strip as AXButtons with AXPress and AXAddToStage.
  guard AXIsProcessTrusted() else { fail("needs Accessibility for this terminal.") }
  let tiles = TileActions.list()
  if command == "tiles" || args.isEmpty {
    if tiles.isEmpty { print("No strip tiles (is the strip empty, or Stage Manager off?)") }
    for (i, t) in tiles.enumerated() { print("\(i + 1). \"\(t.title)\" \(t.frame) actions: \(t.actions.joined(separator: ", "))") }
    // What the poller reads each time (WindowSource.StripTiles): membership, and its cost.
    let clock = ContinuousClock()
    var latest: [StripTile]?
    let elapsed = clock.measure { for _ in 0..<20 { latest = StripTiles.read() } }
    for t in latest ?? [] { print("   tile \"\(t.title ?? "—")\" windows \(t.windowIDs)") }
    print(String(format: "StripTiles.read(): %.1f ms per read (20 reads)", Double(elapsed.components.attoseconds) / 1e15 / 20 + Double(elapsed.components.seconds) * 1000 / 20))
    break
  }
  guard let n = Int(args[0]), tiles.indices.contains(n - 1), args.count > 1 else {
    fail("usage: stagesctl tile <n> press|add   (n from `stagesctl tiles`)")
  }
  if args[1] == "shift-click" || args[1] == "click" {
    let withShift = args[1] == "shift-click"
    // Reveal the strip (pointer to the left edge), Shift-click the tile, put the pointer back.
    let back = CGEvent(source: nil)?.location ?? .zero
    let main = CGDisplayBounds(CGMainDisplayID())
    func move(_ p: CGPoint, dx: Int64 = 0, dy: Int64 = 0) {
      let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
      e?.setIntegerValueField(.mouseEventDeltaX, value: dx)
      e?.setIntegerValueField(.mouseEventDeltaY, value: dy)
      e?.post(tap: .cghidEventTap)
    }
    // Approach the left edge in steps, then keep pushing against it, like a hand would: a single
    // jump to the edge doesn't reveal the strip.
    let y = main.midY
    var x = main.minX + 120
    move(CGPoint(x: x, y: y))
    while x > main.minX {
      x = max(main.minX, x - 12)
      move(CGPoint(x: x, y: y), dx: -12)
      Thread.sleep(forTimeInterval: 0.016)
    }
    func stripShown() -> Bool { TileActions.list().contains { $0.frame.hasPrefix("[") && !$0.frame.hasPrefix("[-") } }
    var revealed = false
    for _ in 0..<45 {   // ~0.7 s of pushing at the edge
      move(CGPoint(x: main.minX, y: y), dx: -3)
      Thread.sleep(forTimeInterval: 0.016)
      if stripShown() { revealed = true; break }
    }
    guard revealed else {
      move(back)
      fail("the strip didn't slide in: synthetic pointer movement doesn't reveal it (no click sent)")
    }
    Thread.sleep(forTimeInterval: 0.35)   // let the slide finish
    let shown = TileActions.list()   // positions once the strip has slid in
    guard shown.indices.contains(n - 1) else { fail("tile \(n) is gone") }
    let f = shown[n - 1].frame   // "[x,y w×h]"
    let nums = f.split { !"-0123456789.".contains($0) }.compactMap { Double($0) }
    guard nums.count == 4 else { fail("couldn't read the tile's frame \(f)") }
    let p = CGPoint(x: nums[0] + nums[2] / 2, y: nums[1] + nums[3] / 2)
    move(p)
    Thread.sleep(forTimeInterval: 0.15)
    // A HID-state source, so the Shift press below is part of the live modifier state that UI
    // reads, not just a flag on the click.
    let source = CGEventSource(stateID: .hidSystemState)
    let shiftKey: CGKeyCode = 56
    if withShift {
      CGEvent(keyboardEventSource: source, virtualKey: shiftKey, keyDown: true)?.post(tap: .cghidEventTap)
      Thread.sleep(forTimeInterval: 0.08)
    }
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
      let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
      e?.setIntegerValueField(.mouseEventClickState, value: 1)
      if withShift { e?.flags = .maskShift }
      e?.post(tap: .cghidEventTap)
      Thread.sleep(forTimeInterval: 0.08)
    }
    if withShift {
      CGEvent(keyboardEventSource: source, virtualKey: shiftKey, keyDown: false)?.post(tap: .cghidEventTap)
    }
    Thread.sleep(forTimeInterval: 0.3)
    move(back)
    print("\(withShift ? "Shift-clicked" : "Clicked") \"\(shown[n - 1].title)\" at \(Int(p.x)),\(Int(p.y)) \(f)")
    break
  }
  if args[1] == "focus-add" {
    // VoiceOver acts on the element it has focused; try the same: focus the strip, then the tile.
    let t = tiles[n - 1]
    var parent: CFTypeRef?
    AXUIElementCopyAttributeValue(t.element, kAXParentAttribute as CFString, &parent)
    if let list = parent { AXUIElementSetAttributeValue(list as! AXUIElement, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
    let focus = AXUIElementSetAttributeValue(t.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    var focused: CFTypeRef?
    AXUIElementCopyAttributeValue(t.element, kAXFocusedAttribute as CFString, &focused)
    Thread.sleep(forTimeInterval: 0.2)
    let err = AXUIElementPerformAction(t.element, "AXAddToStage" as CFString)
    print("focus: \(focus == .success ? "ok" : "AX error \(focus.rawValue)") (focused now: \(focused as? Bool ?? false)); AXAddToStage on \"\(t.title)\": \(err == .success ? "ok" : "AX error \(err.rawValue)")")
    break
  }
  let action = args[1] == "add" ? "AXAddToStage" : args[1] == "press" ? "AXPress" : args[1]
  let t = tiles[n - 1]
  let err = AXUIElementPerformAction(t.element, action as CFString)
  print("\(action) on \"\(t.title)\": \(err == .success ? "ok" : "AX error \(err.rawValue)")")

case "gestures":
  // Swipe spike (M3): which trackpad gesture events reach a public, listen-only event tap?
  guard AXIsProcessTrusted() else {
    fail("gestures needs Accessibility for this terminal (System Settings → Privacy & Security → Accessibility).")
  }
  print("Listening. Try 2-, 3- and 4-finger swipes left/right/up/down, pinches, and a scroll. Ctrl-C to stop.\n")
  guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: CGEventMask.max,
    callback: { _, type, cg, _ in
      MainActor.assumeIsolated {
        // CG type 30 is the Dock's own gesture event (Spaces, Mission Control); AppKit can't
        // convert it and its contents are undocumented. Count it, don't parse it.
        if type.rawValue == 30 {
          GestureSpike.dockEvents += 1
          if GestureSpike.dockEvents % 15 == 1 { print("\(Date().formatted(date: .omitted, time: .standard)) cg type 30 (Dock gesture) ×\(GestureSpike.dockEvents)") }
          return
        }
        guard let e = NSEvent(cgEvent: cg), !GestureSpike.noisy.contains(e.type) else { return }
        let f = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        switch e.type {
        case .scrollWheel:
          // Summarise scrolls: one line per gesture phase change.
          guard e.phase == .began || e.phase == .ended || Date().timeIntervalSince(GestureSpike.lastScroll) > 1 else { return }
          GestureSpike.lastScroll = Date()
          print("\(f) scroll    phase=\(e.phase.rawValue) momentum=\(e.momentumPhase.rawValue) dX=\(e.scrollingDeltaX) dY=\(e.scrollingDeltaY) precise=\(e.hasPreciseScrollingDeltas)")
        case .swipe:
          print("\(f) SWIPE     dX=\(e.deltaX) dY=\(e.deltaY) phase=\(e.phase.rawValue)")
        case .gesture:
          // Public touch data: finger count and their average position (0…1 on the trackpad).
          let touches = e.allTouches().filter { $0.phase != .ended && $0.phase != .cancelled }
          let n = touches.count
          let x = n == 0 ? 0 : touches.map(\.normalizedPosition.x).reduce(0, +) / CGFloat(n)
          let y = n == 0 ? 0 : touches.map(\.normalizedPosition.y).reduce(0, +) / CGFloat(n)
          guard n != GestureSpike.lastFingers || abs(x - GestureSpike.lastX) > 0.08 || abs(y - GestureSpike.lastY) > 0.08 else { return }
          GestureSpike.lastFingers = n; GestureSpike.lastX = x; GestureSpike.lastY = y
          print("\(f) gesture   fingers=\(n) x=\(String(format: "%.2f", x)) y=\(String(format: "%.2f", y)) phase=\(e.phase.rawValue)")
        case .magnify, .rotate, .smartMagnify, .beginGesture, .endGesture, .pressure, .quickLook, .directTouch, .changeMode:
          print("\(f) \(String(describing: e.type).padding(toLength: 9, withPad: " ", startingAt: 0)) phase=\(e.phase.rawValue) dX=\(e.deltaX) dY=\(e.deltaY) magnification=\(e.type == .magnify ? e.magnification : 0)")
        default:
          print("\(f) type \(e.type.rawValue) (cg \(type.rawValue))")
        }
      }
      return Unmanaged.passUnretained(cg)
    }, userInfo: nil)
  else { fail("couldn't create the event tap") }
  CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
  CGEvent.tapEnable(tap: tap, enable: true)
  RunLoop.main.run()

default:
  fail("unknown command \(command). Commands: read, watch, record, tiles, tile, gestures")
}

/// State for the gestures spike's C callback, which can't capture context.
enum GestureSpike {
  static let noisy: Set<NSEvent.EventType> = [.mouseMoved, .keyDown, .keyUp, .flagsChanged, .leftMouseDragged,
                                              .rightMouseDragged, .otherMouseDragged, .cursorUpdate, .mouseEntered, .mouseExited]
  static var lastScroll = Date.distantPast
  static var dockEvents = 0
  static var lastFingers = -1
  static var lastX: CGFloat = 0, lastY: CGFloat = 0
}

/// WindowManager's strip tiles as AX elements, for trying their actions (M6 spike).
enum TileActions {
  struct Tile { let element: AXUIElement; let title: String; let frame: String; let actions: [String] }

  static func list() -> [Tile] {
    guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first?.processIdentifier
    else { return [] }
    let app = AXUIElementCreateApplication(pid)
    var out: [Tile] = []
    func children(_ e: AXUIElement) -> [AXUIElement] {
      var v: CFTypeRef?
      return AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success ? (v as? [AXUIElement] ?? []) : []
    }
    func string(_ e: AXUIElement, _ a: String) -> String? {
      var v: CFTypeRef?
      return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v as? String : nil
    }
    func walk(_ e: AXUIElement, depth: Int) {
      guard depth < 6 else { return }
      if string(e, kAXRoleAttribute) == kAXButtonRole as String {
        var names: CFArray?
        AXUIElementCopyActionNames(e, &names)
        var p: CFTypeRef?, sz: CFTypeRef?
        var point = CGPoint.zero, size = CGSize.zero
        if AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p) == .success { AXValueGetValue(p as! AXValue, .cgPoint, &point) }
        if AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sz) == .success { AXValueGetValue(sz as! AXValue, .cgSize, &size) }
        out.append(Tile(element: e, title: string(e, kAXTitleAttribute) ?? "—",
                        frame: String(format: "[%.0f,%.0f %.0f×%.0f]", point.x, point.y, size.width, size.height),
                        actions: (names as? [String]) ?? []))
      }
      for c in children(e) { walk(c, depth: depth + 1) }
    }
    walk(app, depth: 0)
    return out
  }
}
