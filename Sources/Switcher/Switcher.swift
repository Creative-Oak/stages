import Foundation
import StageReader

/// One stage as the switcher sees it. Built by the app from an identified stage.
public struct Candidate: Hashable, Identifiable, Sendable {
  public enum Position: Int, Comparable, Sendable {
    case centre, strip, overflow
    public static func < (a: Position, b: Position) -> Bool { a.rawValue < b.rawValue }
  }

  public var id: UUID
  public var name: String?
  /// Distinct apps, front-to-back.
  public var apps: [String]
  /// Window titles, front-to-back.
  public var titles: [String]
  public var position: Position
  /// Order within its position (strip top-to-bottom, overflow order).
  public var order: Int
  /// Slot key (1–9, 0, a–z).
  public var slot: String?
  public var lastActive: Date?
  public var createdAt: Date

  public init(id: UUID, name: String?, apps: [String], titles: [String], position: Position, order: Int,
              slot: String? = nil, lastActive: Date? = nil, createdAt: Date) {
    self.id = id; self.name = name; self.apps = apps; self.titles = titles; self.position = position
    self.order = order; self.slot = slot; self.lastActive = lastActive; self.createdAt = createdAt
  }

  /// Does every word of the query start a word of the name, an app or a title?
  public func matches(_ query: String) -> Bool {
    let words = Self.words(query)
    guard !words.isEmpty else { return true }
    let haystack = Set(([name].compactMap { $0 } + apps + titles).flatMap(Self.words))
    return words.allSatisfy { w in haystack.contains { $0.hasPrefix(w) } }
  }

  static func words(_ s: String) -> [String] {
    s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
  }
}

public enum SwitcherOrder {
  /// Most recently used first: the centre stage, then by last time in the centre, then stages
  /// never seen in the centre in their on-screen order.
  public static func mru(_ c: [Candidate]) -> [Candidate] {
    c.sorted { a, b in
      if (a.position == .centre) != (b.position == .centre) { return a.position == .centre }
      switch (a.lastActive, b.lastActive) {
      case let (x?, y?) where x != y: return x > y
      case (_?, nil): return true
      case (nil, _?): return false
      default: return (a.position, a.order) < (b.position, b.order)
      }
    }
  }

  /// A stable cycle for next/previous: by slot key (1–9, 0, a–z), then the rest by age. Stage Manager
  /// reorders the strip on every switch, so cycling by strip position would ping-pong between
  /// two stages.
  public static func cycle(_ c: [Candidate]) -> [Candidate] {
    c.sorted { a, b in
      switch (a.slot.flatMap(SlotKeys.index), b.slot.flatMap(SlotKeys.index)) {
      case let (x?, y?): return x < y
      case (_?, nil): return true
      case (nil, _?): return false
      default: return a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id.uuidString < b.id.uuidString
      }
    }
  }

  /// The stage `step` places from `current` in the cycle (wrapping); nil with fewer than 2.
  public static func neighbour(of current: UUID?, in c: [Candidate], step: Int) -> Candidate? {
    let ring = cycle(c)
    guard ring.count >= 2 else { return nil }
    guard let i = ring.firstIndex(where: { $0.id == current }) else { return ring[step > 0 ? 0 : ring.count - 1] }
    return ring[((i + step) % ring.count + ring.count) % ring.count]
  }
}

/// A hold-modifier switching session: open with Tab, step, type to filter, release to switch.
public struct SwitcherSession: Sendable {
  public private(set) var all: [Candidate]
  public private(set) var query = ""
  public private(set) var selection = 0

  /// Opens on the previous stage (index 1), like ⌘⇥ does for apps.
  public init(candidates: [Candidate]) {
    all = SwitcherOrder.mru(candidates)
    selection = all.count > 1 ? 1 : 0
  }

  public var visible: [Candidate] { all.filter { $0.matches(query) } }
  public var selected: Candidate? { visible.indices.contains(selection) ? visible[selection] : nil }

  public mutating func step(_ by: Int) {
    let n = visible.count
    guard n > 0 else { return }
    selection = ((selection + by) % n + n) % n
  }

  public mutating func type(_ s: String) { query += s; selection = 0 }

  /// The stage whose slot is `key`, if one is listed: pressing a slot key switches straight there.
  public func candidate(slot key: String) -> Candidate? {
    all.first { $0.slot == key.lowercased() }
  }

  /// A newer snapshot while the switcher is open: stages that closed drop out, the rest keep
  /// their place (nothing moves under the user), new ones join at the end, and the selection
  /// stays on the same stage (or the nearest place, if that one closed).
  public mutating func refresh(_ candidates: [Candidate]) {
    let selectedID = selected?.id
    let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var next = all.compactMap { byID[$0.id] }
    let kept = Set(next.map(\.id))
    next += SwitcherOrder.mru(candidates.filter { !kept.contains($0.id) })
    all = next
    if let selectedID, let i = visible.firstIndex(where: { $0.id == selectedID }) {
      selection = i
    } else {
      selection = min(selection, max(visible.count - 1, 0))
    }
  }

  /// An item quit or closed from the switcher: it goes at once, the selection stays in place.
  public mutating func remove(_ id: UUID) {
    all.removeAll { $0.id == id }
    selection = min(selection, max(visible.count - 1, 0))
  }

  public mutating func backspace() {
    guard !query.isEmpty else { return }
    query.removeLast()
    selection = query.isEmpty && visible.count > 1 ? 1 : 0
  }
}

/// Turns trackpad touch samples (finger count, average normalized position) into one step per
/// horizontal swipe. Fingers moving left means "next", like swiping between Spaces.
public struct SwipeDetector: Sendable {
  public var fingers: Int
  /// Horizontal travel, as a share of the trackpad width, before a swipe counts.
  public var threshold: Double
  private var start: (x: Double, y: Double)?
  private var fired = false
  /// More fingers than configured touched down: ignore until all are lifted.
  private var blocked = false

  public init(fingers: Int = 3, threshold: Double = 0.18) {
    self.fingers = fingers; self.threshold = threshold
  }

  /// +1 (next), -1 (previous) once per swipe, else nil.
  public mutating func feed(fingers count: Int, x: Double, y: Double) -> Int? {
    if count == 0 { start = nil; fired = false; blocked = false; return nil }
    if blocked { return nil }
    if count > fingers { blocked = true; start = nil; return nil }
    guard count == fingers else { return nil }   // landing or lifting
    guard let s = start else { start = (x, y); return nil }
    guard !fired else { return nil }
    let dx = x - s.x, dy = y - s.y
    guard abs(dx) >= threshold, abs(dx) >= 2 * abs(dy) else { return nil }
    fired = true
    return dx < 0 ? 1 : -1
  }
}

/// One stepping session over a ring frozen at its first step, so repeated presses move along a
/// list that doesn't change under them (Stage Manager reshuffles, groups and splits stages while
/// it animates). Each step starts from the last target, not from what's in the centre.
public struct RingWalk: Sendable {
  public let ring: [UUID]
  public private(set) var position: UUID?

  public init(ring: [UUID], from position: UUID?) {
    self.ring = ring; self.position = position
  }

  /// The next live entry `by` places along (wrapping), skipping entries no longer on screen.
  public mutating func step(_ by: Int, live: Set<UUID>) -> UUID? {
    let n = ring.count
    guard n > 0, by != 0 else { return nil }
    let start = position.flatMap { ring.firstIndex(of: $0) } ?? (by > 0 ? -1 : n)
    let dir = by > 0 ? 1 : -1
    var remaining = abs(by), i = start
    for _ in 0..<(n * abs(by)) {
      i = ((i + dir) % n + n) % n
      guard live.contains(ring[i]), ring[i] != position || remaining > 1 else { continue }
      remaining -= 1
      if remaining == 0 { position = ring[i]; return ring[i] }
    }
    return nil
  }
}
