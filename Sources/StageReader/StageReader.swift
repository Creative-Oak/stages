import Foundation

// Everything that depends on how Stage Manager happens to draw itself lives in this file.
// When a macOS update breaks stage reading, this is the file to fix. See NOTES.md for which
// of these behaviours are verified and which are assumed.

public enum StageManagerConstants {
  public static let defaultsDomain = "com.apple.WindowManager"
  public static let enabledKey = "GloballyEnabled"
  public static let groupingKey = "AppWindowGroupingBehavior"
  public static let autoHideKey = "AutoHide"

  public static let ownerName = "WindowManager"
  public static let overlayTitle = "Gesture Blocking Overlay"
  public static let appIconTitle = "App Icon Window"

  /// Overlay layer for a window on the centre stage.
  public static let centreLayer = 0
  /// Overlay layer for a strip thumbnail.
  public static let stripLayer = 19

  /// Window ↔ overlay bounds tolerance on each of x, y, w, h.
  public static let matchTolerance = 4.0
  /// A strip component whose left edge is more than this left of the strip column is overflow.
  public static let stripColumnTolerance = 24.0
  public static let minWindowSide = 40.0

  /// Processes whose windows are never stage members.
  public static let excludedOwners: Set<String> = [
    "WindowManager", "Dock", "Window Server", "Control Center", "SystemUIServer", "Spotlight",
    "CursorUIViewService", "Open and Save Panel Service", "PaperKitExtension",
    "Notification Centre", "Notification Center", "NotificationCenter", "Emoji & Symbols", "AutoFill",
    "TextInputMenuAgent", "loginwindow", "universalAccessAuthWarn",
  ]
}

// MARK: - Output

public struct StageWindow: Codable, Hashable, Sendable {
  public var id: UInt32
  public var pid: Int32
  public var owner: String
  public var bundleID: String?
  public var title: String?
  /// The window's reported frame (thumbnail frame when in the strip).
  public var frame: Rect
  /// nil for a centre window that Stage Manager drew no overlay for (common; see NOTES.md #2).
  public var overlayID: UInt32?
  /// Front-to-back order across the whole window list.
  public var z: Int
}

public struct Stage: Codable, Hashable, Sendable {
  public enum Position: String, Codable, Sendable { case centre, strip, overflow }

  public var position: Position
  /// Order within its position on its display: strip top-to-bottom, overflow top-to-bottom.
  public var order: Int
  public var displayID: UInt32
  /// Front-to-back.
  public var windows: [StageWindow]
  /// Union of the stage's overlays.
  public var frame: Rect
  /// Number of "App Icon Window" badges on the tile; nil for the centre stage.
  public var appIconCount: Int?

  public var windowIDs: Set<UInt32> { Set(windows.map(\.id)) }
  /// Distinct apps, front-to-back.
  public var owners: [String] {
    var seen = Set<String>()
    return windows.compactMap { seen.insert($0.owner).inserted ? $0.owner : nil }
  }
}

public struct Diagnostics: Codable, Hashable, Sendable {
  public enum Confidence: String, Codable, Sendable { case high, low }

  public struct Match: Codable, Hashable, Sendable {
    public var windowID: UInt32
    public var overlayID: UInt32
    public var overlayLayer: Int
    /// Largest absolute difference across x, y, w, h.
    public var delta: Double
  }

  public struct Rejection: Codable, Hashable, Sendable {
    public var windowID: UInt32
    public var owner: String
    public var title: String?
    public var bounds: Rect
    public var reason: String
  }

  public var rawWindowCount = 0
  public var overlayCount = 0
  public var appIconCount = 0
  public var matches: [Match] = []
  /// Non-system windows that were not taken as stage members, and why.
  public var rejected: [Rejection] = []
  /// Overlays that matched no window. Offscreen leftovers are routine; onscreen ones are a concern.
  public var unmatchedOverlayIDs: [UInt32] = []
  /// Centre windows taken because they are onscreen, not because an overlay matched them.
  public var centreWithoutOverlay: [UInt32] = []
  /// Layer-0 windows dropped as tiny (< 40×40) or transparent; counted, not listed.
  public var filteredCount = 0
  /// How each strip component was classified (strip vs overflow), for debugging.
  public var classification: [String] = []
  public var confidence: Confidence = .high
  /// Why confidence is low (empty when high).
  public var concerns: [String] = []
}

public struct StageSnapshot: Codable, Hashable, Sendable {
  public enum Unavailable: String, Codable, Sendable {
    case stageManagerOff, noScreenRecording, noOverlays

    public var message: String {
      switch self {
      case .stageManagerOff: "Stage Manager is off."
      case .noScreenRecording: "Can't see stages: Screen Recording permission is missing."
      case .noOverlays: "Can't see stages: Stage Manager's overlays weren't found."
      }
    }
  }

  public var capturedAt: Date
  /// nil when stages were read; otherwise why they couldn't be.
  public var unavailable: Unavailable?
  /// Per display: centre first, then strip top-to-bottom, then overflow.
  public var stages: [Stage]
  public var diagnostics: Diagnostics
  /// Sizes of every overlay, matched or not, sorted. Part of the signature so that two
  /// mid-animation reads that happen to agree on membership still differ.
  public var overlaySizes: [String] = []

  public var isAvailable: Bool { unavailable == nil }
  public var centre: [Stage] { stages.filter { $0.position == .centre } }

  /// Equal for two reads of the same settled state. Covers membership, placement and tile
  /// sizes (sizes change mid-animation; positions change while the hidden strip slides, so
  /// they are left out).
  public var signature: String {
    if let unavailable { return "unavailable:\(unavailable.rawValue)" }
    let parts = stages.map { s in
      let ids = s.windows.map { String($0.id) }.sorted().joined(separator: ",")
      return "\(s.displayID):\(s.position.rawValue):\(s.order):\(ids):\(Int(s.frame.w.rounded()))x\(Int(s.frame.h.rounded()))"
    }
    return (parts + ["overlays:" + overlaySizes.joined(separator: ",")]).joined(separator: "|")
  }
}

// MARK: - Rules

public enum StageReader {
  public static func read(_ capture: WindowCapture) -> StageSnapshot {
    typealias C = StageManagerConstants
    var diag = Diagnostics()
    diag.rawWindowCount = capture.windows.count

    func unavailable(_ reason: StageSnapshot.Unavailable) -> StageSnapshot {
      StageSnapshot(capturedAt: capture.capturedAt, unavailable: reason, stages: [], diagnostics: diag)
    }

    if capture.stageManagerEnabled == false { return unavailable(.stageManagerOff) }
    if !capture.screenRecordingGranted { return unavailable(.noScreenRecording) }

    // 1. Collect overlays, app icons and candidate app windows.
    let wm = capture.windows.filter { $0.owner == C.ownerName }
    let overlays = wm.filter { $0.name == C.overlayTitle }
    let icons = wm.filter { $0.name == C.appIconTitle && $0.layer == C.stripLayer }
    diag.overlayCount = overlays.count
    diag.appIconCount = icons.count
    if overlays.isEmpty { return unavailable(.noOverlays) }

    var candidates: [RawWindow] = []
    for w in capture.windows where !C.excludedOwners.contains(w.owner) {
      let reason: String? =
        w.layer != 0 ? "layer \(w.layer)" :
        w.alpha <= 0 ? "transparent" :
        (w.bounds.w < C.minWindowSide || w.bounds.h < C.minWindowSide) ? "smaller than 40×40" : nil
      if reason != nil {
        // Menu-bar strips (h 33), zero-size helpers, tooltips: noise, so only counted.
        if w.layer == 0 { diag.filteredCount += 1 }
      } else {
        candidates.append(w)
      }
    }

    // 2. Match window ↔ overlay 1:1 by near-equal bounds, closest pairs first.
    struct Pair { var w: RawWindow; var o: RawWindow; var delta: Double; var cost: Double }
    var pairs: [Pair] = []
    for w in candidates {
      for o in overlays {
        let d = [abs(w.bounds.x - o.bounds.x), abs(w.bounds.y - o.bounds.y),
                 abs(w.bounds.w - o.bounds.w), abs(w.bounds.h - o.bounds.h)]
        if let m = d.max(), m <= C.matchTolerance {
          pairs.append(Pair(w: w, o: o, delta: m, cost: d.reduce(0, +)))
        }
      }
    }
    pairs.sort { ($0.cost, $0.w.z, $0.o.z) < ($1.cost, $1.w.z, $1.o.z) }
    var overlayOf: [UInt32: RawWindow] = [:]   // window id -> overlay
    var usedOverlays = Set<UInt32>()
    for p in pairs where overlayOf[p.w.id] == nil && !usedOverlays.contains(p.o.id) {
      overlayOf[p.w.id] = p.o
      usedOverlays.insert(p.o.id)
      diag.matches.append(.init(windowID: p.w.id, overlayID: p.o.id, overlayLayer: p.o.layer, delta: p.delta))
    }
    diag.unmatchedOverlayIDs = overlays.filter { !usedOverlays.contains($0.id) }.map(\.id)

    let members = candidates.filter { overlayOf[$0.id] != nil }
    // Stage Manager often draws no overlay for centre windows (or a stale one a few pt off).
    // Every recording shows that onscreen, unmatched candidates are exactly the centre windows;
    // the placeholders this rule must keep out are always offscreen.
    let unmatchedOnscreen = candidates.filter { overlayOf[$0.id] == nil && $0.onscreen }
    for w in candidates where overlayOf[w.id] == nil && !w.onscreen {
      diag.rejected.append(.init(windowID: w.id, owner: w.owner, title: w.name, bounds: w.bounds,
                                 reason: "offscreen, no overlay within ±\(Int(C.matchTolerance)) pt"))
    }

    func stageWindow(_ w: RawWindow) -> StageWindow {
      StageWindow(id: w.id, pid: w.pid, owner: w.owner, bundleID: w.bundleID, title: w.name,
                  frame: w.bounds, overlayID: overlayOf[w.id]?.id, z: w.z)
    }

    let displays = capture.displays.isEmpty
      ? [DisplayInfo(id: 0, frame: Rect(x: -1e6, y: -1e6, w: 2e6, h: 2e6), isMain: true)]
      : capture.displays
    func display(for r: Rect) -> DisplayInfo {
      if let d = displays.first(where: { $0.frame.contains(x: r.midX, y: r.midY) }) { return d }
      // Strip tiles slide off a display's left edge when the strip hides. Assumed: they belong to
      // the display whose vertical span holds them and whose left edge is nearest.
      let rows = displays.filter { r.midY >= $0.frame.minY && r.midY < $0.frame.maxY }
      return (rows.isEmpty ? displays : rows).min { abs($0.frame.minX - r.midX) < abs($1.frame.minX - r.midX) }!
    }

    var stages: [Stage] = []
    for d in displays.sorted(by: { ($0.isMain ? 0 : 1, $0.id) < ($1.isMain ? 0 : 1, $1.id) }) {
      let here = members.filter { display(for: overlayOf[$0.id]!.bounds).id == d.id }

      // 3. Centre stage = matched windows whose overlay is layer 0, plus onscreen candidates
      //    with no overlay at all.
      let bare = unmatchedOnscreen.filter { display(for: $0.bounds).id == d.id }
      diag.centreWithoutOverlay += bare.map(\.id)
      let centre = (here.filter { overlayOf[$0.id]!.layer == C.centreLayer } + bare).sorted { $0.z < $1.z }
      if !centre.isEmpty {
        let bounds = centre.map { overlayOf[$0.id]?.bounds ?? $0.bounds }
        let frame = bounds.dropFirst().reduce(bounds[0]) { $0.union($1) }
        stages.append(Stage(position: .centre, order: 0, displayID: d.id, windows: centre.map(stageWindow),
                            frame: frame, appIconCount: nil))
      }

      // 4. Strip stages = connected components of intersecting layer-19 overlays.
      let strip = here.filter { overlayOf[$0.id]!.layer == C.stripLayer }
      for w in here where ![C.centreLayer, C.stripLayer].contains(overlayOf[w.id]!.layer) {
        diag.concerns.append("window #\(w.id) matched an overlay on unexpected layer \(overlayOf[w.id]!.layer)")
      }
      var parent = Array(strip.indices)
      func root(_ i: Int) -> Int { var i = i; while parent[i] != i { i = parent[i] }; return i }
      for i in strip.indices {
        for j in strip.indices where j > i && overlayOf[strip[i].id]!.bounds.overlaps(overlayOf[strip[j].id]!.bounds) {
          parent[root(j)] = root(i)
        }
      }
      let components: [[RawWindow]] = Dictionary(grouping: strip.indices, by: root).values
        .map { $0.map { strip[$0] }.sorted { $0.z < $1.z } }

      struct Component { var windows: [RawWindow]; var frame: Rect; var anyOnscreen: Bool }
      let comps = components.map { ws in
        let os = ws.map { overlayOf[$0.id]! }
        return Component(windows: ws, frame: os.dropFirst().reduce(os[0].bounds) { $0.union($1.bounds) },
                         anyOnscreen: os.contains { $0.onscreen })
      }
      guard !comps.isEmpty else { continue }

      // The strip column is the rightmost left edge; grouped stages fan out to the right of it.
      let columnX = comps.map(\.frame.minX).max()!
      var inColumn = comps.filter { $0.frame.minX >= columnX - C.stripColumnTolerance }
      var overflow = comps.filter { $0.frame.minX < columnX - C.stripColumnTolerance }
      // Offscreen while others in the column are onscreen ⇒ overflow too.
      if inColumn.contains(where: \.anyOnscreen) {
        overflow += inColumn.filter { !$0.anyOnscreen }
        inColumn = inColumn.filter(\.anyOnscreen)
      }
      diag.classification.append(String(format: "display %u: strip column x=%.0f", d.id, columnX))

      func tileIcons(_ c: Component) -> Int {
        icons.filter { c.frame.contains(x: $0.bounds.midX, y: $0.bounds.midY) }.count
      }
      for (position, group) in [(Stage.Position.strip, inColumn), (.overflow, overflow)] {
        for (i, c) in group.sorted(by: { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }).enumerated() {
          let stage = Stage(position: position, order: i, displayID: d.id, windows: c.windows.map(stageWindow),
                            frame: c.frame, appIconCount: tileIcons(c))
          diag.classification.append("\(position.rawValue) \(i) \(c.frame) x=\(Int(c.frame.minX)) \(c.anyOnscreen ? "onscreen" : "offscreen") apps=\(stage.owners)")
          if stage.appIconCount != stage.owners.count {
            diag.concerns.append("\(position.rawValue) stage \(i) has \(stage.owners.count) app(s) but \(stage.appIconCount ?? 0) icon badge(s)")
          }
          stages.append(stage)
        }
      }
    }

    // 6. Confidence: anything we can't explain lowers it.
    let liveUnmatched = overlays.filter { !usedOverlays.contains($0.id) && $0.onscreen }
    if !liveUnmatched.isEmpty {
      diag.concerns.append("\(liveUnmatched.count) onscreen overlay(s) matched no window: " +
                           liveUnmatched.map { "#\($0.id) \($0.bounds)" }.joined(separator: ", "))
    }
    if !stages.contains(where: { $0.position == .centre }) {
      diag.concerns.append("no centre stage (desktop shown, or the centre overlay wasn't matched)")
    }
    diag.confidence = diag.concerns.isEmpty ? .high : .low

    return StageSnapshot(capturedAt: capture.capturedAt, unavailable: nil, stages: stages, diagnostics: diag,
                         overlaySizes: overlays.map { "\(Int($0.bounds.w.rounded()))x\(Int($0.bounds.h.rounded()))" }.sorted())
  }
}

// MARK: - Stability gate

/// 5. Publish a snapshot only when two consecutive reads agree, and only when it differs from
/// the last one published.
public struct StabilityGate: Sendable {
  private var lastRead: String?
  private var committed: String?

  public init() {}

  public mutating func feed(_ snapshot: StageSnapshot) -> StageSnapshot? {
    let sig = snapshot.signature
    defer { lastRead = sig }
    guard sig == lastRead, sig != committed else { return nil }
    committed = sig
    return snapshot
  }

  /// True if the last read was not yet stable (useful to poll faster).
  public var isSettling: Bool { lastRead != committed }
}
