// stagesctl — debug CLI for the stage reader.
//
//   stagesctl read [fixture.json] [--frame N] [--json]   read live (or a fixture) and explain it
//   stagesctl watch                                      print each committed snapshot + poll cost
//   stagesctl record <name> --note "…" [--frames N] [--interval ms] [--delay s] [--out dir] [--keep-titles]
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
  "\(w.owner) · \"\(w.title ?? "—")\" · #\(w.id) · z\(w.z) · \(w.frame) · overlay #\(w.overlayID)"
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
  print("\n── Rejected candidates (\(d.rejected.count))")
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

default:
  fail("unknown command \(command). Commands: read, watch, record")
}
