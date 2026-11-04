import Foundation
import Testing
@testable import Switcher

private func c(_ name: String?, _ apps: [String], _ pos: Candidate.Position = .strip, order: Int = 0,
               slot: String? = nil, active: Double? = nil, created: Double = 0, titles: [String] = []) -> Candidate {
  Candidate(id: UUID(), name: name, apps: apps, titles: titles, position: pos, order: order, slot: slot,
            lastActive: active.map { Date(timeIntervalSince1970: $0) }, createdAt: Date(timeIntervalSince1970: created))
}

@Suite struct SwitcherOrderTests {
  @Test func mruPutsCentreFirstThenRecency() {
    let centre = c("Now", ["Ghostty"], .centre, active: 10)
    let recent = c("Recent", ["Mail"], .strip, order: 2, active: 9)
    let older = c("Older", ["Safari"], .strip, order: 0, active: 5)
    let never = c(nil, ["Maps"], .overflow, order: 0)
    #expect(SwitcherOrder.mru([never, older, recent, centre]).map(\.name) == ["Now", "Recent", "Older", nil])
  }

  @Test func cycleIsStableSlotsFirst() {
    let a = c("A", ["X"], created: 3), b = c("B", ["Y"], slot: "2", created: 9), d = c("D", ["Z"], slot: "1", created: 5)
    let z = c("Z", ["W"], slot: "0", created: 1), k = c("K", ["V"], slot: "a", created: 0)
    #expect(SwitcherOrder.cycle([k, a, b, z, d]).map(\.name) == ["D", "B", "Z", "K", "A"])   // 1, 2, 0, a, then unslotted
  }

  @Test func neighbourWraps() {
    let a = c("A", ["X"], created: 1), b = c("B", ["Y"], created: 2), d = c("C", ["Z"], created: 3)
    let all = [d, a, b]
    #expect(SwitcherOrder.neighbour(of: a.id, in: all, step: 1)?.name == "B")
    #expect(SwitcherOrder.neighbour(of: d.id, in: all, step: 1)?.name == "A")
    #expect(SwitcherOrder.neighbour(of: a.id, in: all, step: -1)?.name == "C")
    #expect(SwitcherOrder.neighbour(of: nil, in: all, step: 1)?.name == "A")
    #expect(SwitcherOrder.neighbour(of: a.id, in: [a], step: 1) == nil)
  }
}

@Suite struct SwitcherSessionTests {
  let stages = [
    c("Lodestone", ["Safari", "Figma"], .centre, active: 10, titles: ["Lodestone – GitHub"]),
    c("Swifttap", ["Ghostty", "Xcode"], active: 9, titles: ["~/dev/swifttap"]),
    c(nil, ["Mail"], active: 8, titles: ["Inbox – Creativeoak"]),
    c(nil, ["Maps"], .overflow),
  ]

  @Test func opensOnThePreviousStage() {
    #expect(SwitcherSession(candidates: stages).selected?.name == "Swifttap")
  }

  @Test func stepsWrap() {
    var s = SwitcherSession(candidates: stages)
    s.step(1); s.step(1)
    #expect(s.selected?.apps == ["Maps"])
    s.step(1)
    #expect(s.selected?.name == "Lodestone")
    s.step(-1)
    #expect(s.selected?.apps == ["Maps"])
  }

  @Test func typingFiltersByNameAppOrTitle() {
    var s = SwitcherSession(candidates: stages)
    s.type("xco")
    #expect(s.visible.map(\.name) == ["Swifttap"])
    s.backspace(); s.backspace(); s.backspace()
    s.type("inbox cre")
    #expect(s.visible.map(\.apps) == [["Mail"]])
    s.backspace()
    #expect(s.selected?.apps == ["Mail"])
  }

  @Test func noMatchSelectsNothing() {
    var s = SwitcherSession(candidates: stages)
    s.type("zzz")
    #expect(s.selected == nil)
    s.step(1)
    #expect(s.selected == nil)
  }
}

@Suite struct SwipeDetectorTests {
  /// Feeds (fingers, x, y) samples; returns the steps fired.
  func run(_ d: inout SwipeDetector, _ samples: [(Int, Double, Double)]) -> [Int] {
    samples.compactMap { d.feed(fingers: $0.0, x: $0.1, y: $0.2) }
  }

  // Samples from Magnus's recording (`stagesctl gestures`, 2026-11-04 10:22–10:23).
  let threeLeft: [(Int, Double, Double)] = [(1, 0.56, 0.53), (3, 0.74, 0.58), (3, 0.64, 0.59), (3, 0.56, 0.59),
                                            (3, 0.47, 0.59), (3, 0.39, 0.56), (0, 0, 0)]
  let threeRight: [(Int, Double, Double)] = [(1, 0.24, 0.41), (2, 0.33, 0.51), (3, 0.43, 0.52), (3, 0.53, 0.51),
                                             (3, 0.64, 0.53), (3, 0.73, 0.53), (1, 0.63, 0.53), (0, 0, 0)]
  let fourUp: [(Int, Double, Double)] = [(4, 0.54, 0.35), (4, 0.55, 0.45), (4, 0.55, 0.55), (4, 0.55, 0.66),
                                         (2, 0.77, 0.75), (0, 0, 0)]
  let fourRight: [(Int, Double, Double)] = [(4, 0.46, 0.54), (4, 0.56, 0.56), (4, 0.65, 0.59), (3, 0.60, 0.65),
                                            (3, 0.70, 0.68), (1, 0.55, 0.66), (0, 0, 0)]

  @Test func threeFingerSwipesStepOnce() {
    var d = SwipeDetector(fingers: 3)
    #expect(run(&d, threeLeft) == [1])
    #expect(run(&d, threeRight) == [-1])
  }

  @Test func otherFingerCountsAndVerticalSwipesAreIgnored() {
    var three = SwipeDetector(fingers: 3)
    // A 4-finger swipe lifting through 3 fingers must not count as a 3-finger one.
    #expect(run(&three, fourRight) == [])
    var four = SwipeDetector(fingers: 4)
    #expect(run(&four, fourUp) == [])
    #expect(run(&four, threeLeft) == [])
    #expect(run(&four, fourRight) == [-1])
  }

  @Test func shortMovementsDoNotCount() {
    var d = SwipeDetector(fingers: 3)
    #expect(run(&d, [(3, 0.5, 0.5), (3, 0.55, 0.5), (3, 0.45, 0.5), (0, 0, 0)]) == [])
  }
}

@Suite struct RingWalkTests {
  let a = UUID(), b = UUID(), c = UUID(), d = UUID()

  @Test func walksFromTheLastTargetNotTheCentre() {
    var w = RingWalk(ring: [a, b, c, d], from: a)
    let live: Set = [a, b, c, d]
    #expect(w.step(1, live: live) == b)
    #expect(w.step(1, live: live) == c)
    #expect(w.step(1, live: live) == d)
    #expect(w.step(1, live: live) == a)
    #expect(w.step(-1, live: live) == d)
  }

  @Test func skipsStagesThatDisappeared() {
    var w = RingWalk(ring: [a, b, c, d], from: a)
    #expect(w.step(1, live: [a, c, d]) == c)          // b merged away mid-walk
    #expect(w.step(1, live: [a, b, c, d]) == d)       // b back: still walks on from c
  }

  @Test func startsAtTheTopWhenTheCentreIsNotInTheRing() {
    var w = RingWalk(ring: [a, b, c], from: nil)
    #expect(w.step(1, live: [a, b, c]) == a)
    var back = RingWalk(ring: [a, b, c], from: nil)
    #expect(back.step(-1, live: [a, b, c]) == c)
  }

  @Test func needsAnotherLiveStage() {
    var w = RingWalk(ring: [a, b], from: a)
    #expect(w.step(1, live: [a]) == nil)
  }
}

@Suite struct SwitcherRefreshTests {
  @Test func aClosedStageDropsOutAndTheSelectionStays() {
    let now = c("Now", ["Claude"], .centre, active: 10)
    let closed = c(nil, ["System Settings"], .strip, active: 9)
    let mail = c(nil, ["Mail"], .strip, active: 8)
    var s = SwitcherSession(candidates: [now, closed, mail])
    s.step(1)   // on Mail
    #expect(s.selected?.id == mail.id)
    s.refresh([now, mail])
    #expect(s.all.map(\.id) == [now.id, mail.id])
    #expect(s.selected?.id == mail.id)
  }

  @Test func whenTheSelectedStageClosesTheSelectionStaysInPlace() {
    let now = c("Now", ["Claude"], .centre, active: 10)
    let closed = c(nil, ["Calendar"], .strip, active: 9)
    let mail = c(nil, ["Mail"], .strip, active: 8)
    var s = SwitcherSession(candidates: [now, closed, mail])
    #expect(s.selected?.id == closed.id)
    s.refresh([now, mail])
    #expect(s.selected?.id == mail.id)
  }

  @Test func newStagesJoinAtTheEndWithoutReshuffling() {
    let a = c("A", ["A"], .centre, active: 10), b = c("B", ["B"], .strip, active: 9)
    var s = SwitcherSession(candidates: [a, b])
    let fresh = c("New", ["Notes"], .strip, active: 11)
    s.refresh([a, b, fresh])
    #expect(s.all.map(\.name) == ["A", "B", "New"])
  }
}

@Suite struct SwitcherRemoveTests {
  @Test func quittingTheSelectedItemKeepsTheSelectionInPlace() {
    let a = c("A", ["A"], .centre, active: 10), b = c("B", ["B"], .strip, active: 9), d = c("D", ["D"], .strip, active: 8)
    var s = SwitcherSession(candidates: [a, b, d])
    #expect(s.selected?.id == b.id)
    s.remove(b.id)
    #expect(s.selected?.id == d.id)
    s.remove(d.id)
    #expect(s.selected?.id == a.id)
  }
}
