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
  /// Two thumbnails belong to one grouped tile only if they overlap by at least this share of
  /// the smaller one. Grouped tiles overlap ≥ 70 %; neighbouring tiles touch by ~1 pt.
  public static let groupOverlapRatio = 0.25
  public static let minWindowSide = 40.0
  /// Right edge of the strip band, from the display's left edge. Shown strip tiles end by x 269
  /// (column 16 + 253 wide); hidden ones are at negative x.
  public static let stripBandRight = 290.0

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

  public init(id: UInt32, pid: Int32, owner: String, bundleID: String?, title: String?, frame: Rect,
              overlayID: UInt32?, z: Int) {
    self.id = id; self.pid = pid; self.owner = owner; self.bundleID = bundleID; self.title = title
    self.frame = frame; self.overlayID = overlayID; self.z = z
  }
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
  /// Number of "App Icon Window" badges on the tile; nil for the centre stage and pooled overflow.
  public var appIconCount: Int?
  /// Overflow stages are all parked at one spot, so geometry can't tell which windows share a
  /// stage. A pooled stage is one overflow window; StageStore regroups them from history.
  public var pooled: Bool
  /// Membership read from WindowManager itself (a strip tile's `AXWindowsIDs`), not inferred.
  public var authoritative: Bool

  public init(position: Position, order: Int, displayID: UInt32, windows: [StageWindow], frame: Rect,
              appIconCount: Int?, pooled: Bool = false, authoritative: Bool = false) {
    self.position = position; self.order = order; self.displayID = displayID
    self.windows = windows; self.frame = frame; self.appIconCount = appIconCount; self.pooled = pooled
    self.authoritative = authoritative
  }

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

  public init() {}
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
  /// Every window ID in the capture, stage member or not (hidden, other Spaces, minimised).
  /// A stage whose windows are all absent from this has closed; one whose windows are here but
  /// not in a stage is elsewhere (another Space). Not part of the signature.
  public var allWindowIDs: Set<UInt32> = []
  /// "Show windows from an application: All at Once" (`AppWindowGroupingBehavior` 1; 0 is One at
  /// a Time). Diagnostic only.
  public var allAtOnce: Bool = false

  public init(capturedAt: Date, unavailable: Unavailable?, stages: [Stage], diagnostics: Diagnostics,
              overlaySizes: [String] = [], allWindowIDs: Set<UInt32> = [], allAtOnce: Bool = false) {
    self.capturedAt = capturedAt; self.unavailable = unavailable; self.stages = stages
    self.diagnostics = diagnostics; self.overlaySizes = overlaySizes; self.allWindowIDs = allWindowIDs
    self.allAtOnce = allAtOnce
  }

  public var isAvailable: Bool { unavailable == nil }
  public var centre: [Stage] { stages.filter { $0.position == .centre } }

  /// Equal for two reads of the same settled state. Covers membership, placement and tile
  /// sizes (sizes change mid-animation; positions change while the hidden strip slides, so
  /// they are left out), plus the full frame of every centre window that has no overlay: that
  /// rule is only trusted once such windows have stopped moving.
  public var signature: String {
    if let unavailable { return "unavailable:\(unavailable.rawValue)" }
    let parts = stages.map { s in
      let ids = s.windows.map { String($0.id) }.sorted().joined(separator: ",")
      return "\(s.displayID):\(s.position.rawValue):\(s.order):\(ids):\(Int(s.frame.w.rounded()))x\(Int(s.frame.h.rounded()))"
    }
    let bare = stages.filter { $0.position == .centre }.flatMap(\.windows).filter { $0.overlayID == nil }
      .map { "\($0.id)@\(Int($0.frame.x)),\(Int($0.frame.y)),\(Int($0.frame.w)),\(Int($0.frame.h))" }
    return (parts + ["overlays:" + overlaySizes.joined(separator: ","), "bare:" + bare.joined(separator: ",")])
      .joined(separator: "|")
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
    // Badges are layer 19 normally but drop to layer 0 with the overlays during a switch.
    let icons = wm.filter { $0.name == C.appIconTitle }
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
    let candidateByID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    if let tiles = capture.stripTiles {
      diag.classification.append("strip from WindowManager's AX tiles: \(tiles.count) tile(s)")
    }
    for d in displays.sorted(by: { ($0.isMain ? 0 : 1, $0.id) < ($1.isMain ? 0 : 1, $1.id) }) {
      let here = members.filter { display(for: overlayOf[$0.id]!.bounds).id == d.id }
      // WindowManager's own strip tiles (AXWindowsIDs), when readable: exact strip membership.
      let tilesHere = capture.stripTiles?.filter { display(for: $0.frame).id == d.id }
      let tileIDs = Set((tilesHere ?? []).flatMap(\.windowIDs))

      // 3. Centre stage = matched windows whose overlay is layer 0, plus onscreen candidates
      //    with no overlay at all.
      //    A window with no overlay lying wholly in the strip band is a thumbnail mid-animation
      //    (its overlay not caught up), not a centre window.
      let unmatchedHere = unmatchedOnscreen.filter { display(for: $0.bounds).id == d.id }
      let inStripBand = unmatchedHere.filter { $0.bounds.maxX <= d.frame.minX + C.stripBandRight }
      let bare = unmatchedHere.filter { $0.bounds.maxX > d.frame.minX + C.stripBandRight }
      for w in inStripBand {
        diag.rejected.append(.init(windowID: w.id, owner: w.owner, title: w.name, bounds: w.bounds,
                                   reason: "in the strip band with no overlay (mid-animation?)"))
      }
      if !inStripBand.isEmpty {
        diag.concerns.append("\(inStripBand.count) thumbnail-like window(s) with no overlay in the strip band")
      }
      diag.centreWithoutOverlay += bare.map(\.id)
      // During a stage switch every overlay drops to layer 0, strip thumbnails' included, so a
      // layer-0 overlay wholly in the strip band is still a thumbnail.
      func inBand(_ r: Rect) -> Bool { r.maxX <= d.frame.minX + C.stripBandRight }
      let layerZero = here.filter { overlayOf[$0.id]!.layer == C.centreLayer }
      let demoted = layerZero.filter { inBand(overlayOf[$0.id]!.bounds) }
      if !demoted.isEmpty {
        diag.classification.append("\(demoted.count) layer-0 overlay(s) in the strip band read as thumbnails")
      }
      let centre = (layerZero.filter { !inBand(overlayOf[$0.id]!.bounds) } + bare)
        .filter { !tileIDs.contains($0.id) }   // a tile's window is in the strip, whatever its overlay says
        .sorted { $0.z < $1.z }
      if !centre.isEmpty {
        let bounds = centre.map { overlayOf[$0.id]?.bounds ?? $0.bounds }
        let frame = bounds.dropFirst().reduce(bounds[0]) { $0.union($1) }
        stages.append(Stage(position: .centre, order: 0, displayID: d.id, windows: centre.map(stageWindow),
                            frame: frame, appIconCount: nil))
      }

      let strip = here.filter { overlayOf[$0.id]!.layer == C.stripLayer } + demoted

      // 4a. With tiles: one strip stage per tile, top to bottom, with exactly its windows; every
      //     other strip-layer window is overflow (overflow stages have no tiles).
      if let tilesHere {
        for (i, t) in tilesHere.sorted(by: { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }).enumerated() {
          let ws = t.windowIDs.compactMap { candidateByID[$0] }.sorted { $0.z < $1.z }
          guard !ws.isEmpty else {
            diag.concerns.append("strip tile “\(t.title ?? "?")” lists no window in the capture")
            continue
          }
          let badges = icons.filter { t.frame.contains(x: $0.bounds.midX, y: $0.bounds.midY) }.count
          let stage = Stage(position: .strip, order: i, displayID: d.id, windows: ws.map(stageWindow),
                            frame: t.frame, appIconCount: badges, authoritative: true)
          diag.classification.append("strip \(i) (tile) \(t.frame) apps=\(stage.owners)")
          stages.append(stage)
        }
        let pool = strip.filter { !tileIDs.contains($0.id) }.sorted { $0.z < $1.z }
        for (i, w) in pool.enumerated() {
          stages.append(Stage(position: .overflow, order: i, displayID: d.id, windows: [stageWindow(w)],
                              frame: overlayOf[w.id]!.bounds, appIconCount: nil, pooled: true))
        }
        if !pool.isEmpty { diag.classification.append("overflow pool: \(pool.count) window(s), apps=\(pool.map(\.owner))") }
        continue
      }

      // 4b. Without tiles (no Accessibility): strip stages = connected components of
      //     substantially overlapping layer-19 overlays.
      func grouped(_ a: Rect, _ b: Rect) -> Bool {
        a.intersectionArea(b) >= C.groupOverlapRatio * min(a.area, b.area)
      }
      for w in here where ![C.centreLayer, C.stripLayer].contains(overlayOf[w.id]!.layer) {
        diag.concerns.append("window #\(w.id) matched an overlay on unexpected layer \(overlayOf[w.id]!.layer)")
      }
      var parent = Array(strip.indices)
      func root(_ i: Int) -> Int { var i = i; while parent[i] != i { i = parent[i] }; return i }
      for i in strip.indices {
        for j in strip.indices where j > i && grouped(overlayOf[strip[i].id]!.bounds, overlayOf[strip[j].id]!.bounds) {
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
      for (i, c) in inColumn.sorted(by: { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }).enumerated() {
        let stage = Stage(position: .strip, order: i, displayID: d.id, windows: c.windows.map(stageWindow),
                          frame: c.frame, appIconCount: tileIcons(c))
        diag.classification.append("strip \(i) \(c.frame) x=\(Int(c.frame.minX)) \(c.anyOnscreen ? "onscreen" : "offscreen") apps=\(stage.owners)")
        if stage.appIconCount != stage.owners.count {
          diag.concerns.append("strip stage \(i) has \(stage.owners.count) app(s) but \(stage.appIconCount ?? 0) icon badge(s)")
        }
        stages.append(stage)
      }

      // Overflow: every stage's thumbnail is parked at the same anchor (right edge and vertical
      // centre), so overlapping says nothing about grouping. One pooled stage per window,
      // front-to-back.
      let pool = overflow.flatMap(\.windows).sorted { $0.z < $1.z }
      for (i, w) in pool.enumerated() {
        stages.append(Stage(position: .overflow, order: i, displayID: d.id, windows: [stageWindow(w)],
                            frame: overlayOf[w.id]!.bounds, appIconCount: nil, pooled: true))
      }
      if !pool.isEmpty {
        let poolIcons = overflow.map(tileIcons).reduce(0, +)
        diag.classification.append("overflow pool: \(pool.count) window(s), \(poolIcons) icon badge(s), apps=\(pool.map(\.owner))")
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
                         overlaySizes: overlays.map { "\(Int($0.bounds.w.rounded()))x\(Int($0.bounds.h.rounded()))" }.sorted(), allWindowIDs: Set(capture.windows.map(\.id)),
                         allAtOnce: capture.appWindowGroupingBehavior == 1)
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
