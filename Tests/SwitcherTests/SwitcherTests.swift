import Foundation
import Testing
@testable import Switcher

private func c(_ name: String?, _ apps: [String], _ pos: Candidate.Position = .strip, order: Int = 0,
               slot: Int? = nil, active: Double? = nil, created: Double = 0, titles: [String] = []) -> Candidate {
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
    let a = c("A", ["X"], created: 3), b = c("B", ["Y"], slot: 2, created: 9), d = c("D", ["Z"], slot: 1, created: 5)
    #expect(SwitcherOrder.cycle([a, b, d]).map(\.name) == ["D", "B", "A"])
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
