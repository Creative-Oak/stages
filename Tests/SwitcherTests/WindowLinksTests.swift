import StageReader
import Testing
@testable import Switcher

/// Two Safari windows on the same page (as recorded 2026-11-04: #932 and #487 both
/// "Automate Stage Manager Windows", #921 elsewhere). Safari's own AX order differs from the CG
/// z-order Stage Manager keeps, so the rank guess picks the wrong one.
@Suite struct WindowLinksTests {
  typealias Links = WindowLinks<String>
  let page = "Automate Stage Manager Windows"
  var ax: [Links.AXWindow] {
    [.init(element: "ax-487", title: page, frame: Rect(x: 73, y: 80, w: 1323, h: 830)),
     .init(element: "ax-932", title: page, frame: Rect(x: 73, y: 80, w: 1323, h: 830)),
     .init(element: "ax-921", title: "IKEA", frame: Rect(x: 73, y: 80, w: 1323, h: 830))]
  }

  @Test func retryNeverRaisesTheSameWrongWindow() {
    let links = Links()
    // 932 is in front in CG, so its rank is 0 → Safari's first same-titled window: wrong.
    let first = links.pick(932, title: page, frame: nil, aheadSameTitle: [], among: ax)
    #expect(first == "ax-487")
    let second = links.pick(932, title: page, frame: nil, aheadSameTitle: [], among: ax, avoiding: first)
    #expect(second == "ax-932")
  }

  @Test func aLinkMadeWhileTitlesDifferedOutlivesTheTitleChange() {
    var links = Links()
    links.link(487, "ax-487")   // focused in the centre while it showed another page
    // Now both show the same page: 487 is known, so 932 is the only open one left.
    #expect(links.pick(932, title: page, frame: nil, aheadSameTitle: [487], among: ax) == "ax-932")
    #expect(links.pick(487, title: page, frame: nil, aheadSameTitle: [932], among: ax) == "ax-487")
  }

  @Test func aKnownLinkWinsEvenWhenTheTitleMovedOn() {
    var links = Links()
    links.link(921, "ax-921")
    // The snapshot still has the old title; the AX window already shows a new page.
    #expect(links.pick(921, title: "Old page", frame: nil, aheadSameTitle: [], among: ax) == "ax-921")
  }

  @Test func oneElementIsOneWindow() {
    var links = Links()
    links.link(932, "ax-487")   // a wrong guess…
    links.link(487, "ax-487")   // …corrected when 487 turned out focused with that element
    #expect(links.element(for: 932) == nil)
    #expect(links.element(for: 487) == "ax-487")
  }

  @Test func certainOnlyWithoutDoubt() {
    var links = Links()
    #expect(links.certain(921, title: "IKEA", unlinkedSameTitle: 1, among: ax) == "ax-921")
    // Two unlinked CG windows with this title: not certain.
    #expect(links.certain(932, title: page, unlinkedSameTitle: 2, among: ax) == nil)
    // Once 487 is linked, 932 is the only unlinked one with that title, and only one AX window is open.
    links.link(487, "ax-487")
    #expect(links.certain(932, title: page, unlinkedSameTitle: 1, among: ax) == "ax-932")
  }

  @Test func frameSettlesItForACentreWindow() {
    let centre = [Links.AXWindow(element: "a", title: page, frame: Rect(x: 0, y: 0, w: 800, h: 600)),
                  Links.AXWindow(element: "b", title: page, frame: Rect(x: 73, y: 80, w: 1323, h: 830))]
    #expect(Links().pick(1, title: page, frame: Rect(x: 73, y: 80, w: 1323, h: 830), aheadSameTitle: [2], among: centre) == "b")
  }

  @Test func forgetsClosedWindows() {
    var links = Links()
    links.link(932, "ax-932"); links.link(487, "ax-487")
    links.keep(only: [487])
    #expect(links.byWindow == [487: "ax-487"])
  }
}
