import Foundation
import Testing
@testable import Commands

private func parse(_ s: String) -> Result<Command, Command.ParseError> { Command.parse(URL(string: s)!) }

@Suite struct CommandParseTests {
  @Test func switching() {
    #expect(parse("stages://switch?slot=3") == .success(.switchToSlot("3")))
    #expect(parse("stages://switch?slot=0") == .success(.switchToSlot("0")))
    #expect(parse("stages://switch?slot=B") == .success(.switchToSlot("b")))
    #expect(parse("stages://switch?name=Swifttap") == .success(.switchToName("Swifttap")))
    #expect(parse("stages://switch?name=Lodestone%20Library") == .success(.switchToName("Lodestone Library")))
    let id = UUID()
    #expect(parse("stages://switch?id=\(id.uuidString)") == .success(.switchToID(id)))
    #expect(parse("stages://next") == .success(.next))
    #expect(parse("stages://previous") == .success(.previous))
    #expect(parse("STAGES://Next") == .success(.next))
    #expect(parse("stages:next") == .success(.next))
  }

  @Test func editing() {
    #expect(parse("stages://name?value=Lodestone") == .success(.rename("Lodestone")))
    #expect(parse("stages://name?value=") == .success(.rename(nil)))
    #expect(parse("stages://ink?value=Teal") == .success(.ink("teal")))
    #expect(parse("stages://ink?value=none") == .success(.ink(nil)))
    #expect(parse("stages://slot?value=3") == .success(.slot("3")))
    #expect(parse("stages://slot?value=k") == .success(.slot("k")))
    #expect(parse("stages://slot?value=none") == .success(.slot(nil)))
    #expect(parse("stages://wake?name=Reading") == .success(.wake("Reading")))
    #expect(parse("stages://wake") == .failure(.missing("name")))
  }

  @Test func errors() {
    #expect(parse("stages://switch?slot=10") == .failure(.invalid("slot", "10")))
    #expect(parse("stages://switch?slot=å") == .failure(.invalid("slot", "å")))
    #expect(parse("stages://switch") == .failure(.missing("slot, name or id")))
    #expect(parse("stages://fly") == .failure(.unknownCommand("fly")))
    #expect(parse("stages://name") == .failure(.missing("value")))
    #expect(parse("https://example.com") == .failure(.notStages("https://example.com")))
  }

  @Test func nameResolution() {
    let a = UUID(), b = UUID(), c = UUID()
    let names = [(id: a, name: "Swifttap"), (id: b, name: "Lodestone"), (id: c, name: "Lodestone Library")]
    #expect(Command.resolve(name: "swifttap", chosen: names) == a)
    #expect(Command.resolve(name: "swift", chosen: names) == a)
    #expect(Command.resolve(name: "lodestone", chosen: names) == b)        // exact beats prefix
    #expect(Command.resolve(name: "lodestone l", chosen: names) == c)
    #expect(Command.resolve(name: "lode", chosen: names) == nil)            // ambiguous
    #expect(Command.resolve(name: "x", chosen: names) == nil)
  }
}

@Suite struct GeneratedNameTests {
  let named = UUID(), wordSignal = UUID(), safari = UUID(), finderA = UUID(), finderB = UUID()
  var chosen: [(id: UUID, name: String)] { [(named, "Safari")] }   // a stage someone named "Safari"
  var generated: [(id: UUID, name: String)] {
    [(wordSignal, "Microsoft Word + Signal"), (safari, "Safari"), (finderA, "Finder"), (finderB, "Finder")]
  }
  func resolve(_ q: String) -> UUID? { Command.resolve(name: q, chosen: chosen, generated: generated) }

  @Test func matchesGeneratedNames() {
    #expect(resolve("microsoft word + signal") == wordSignal)
    #expect(resolve("micro") == wordSignal)
    #expect(resolve("word") == wordSignal)        // word prefix
    #expect(resolve("sig") == wordSignal)
  }

  @Test func chosenNamesWinExactTies() {
    #expect(resolve("Safari") == named)
  }

  @Test func ambiguousGeneratedNamesDoNotGuess() {
    #expect(resolve("finder") == nil)   // two unnamed Finder stages
    #expect(resolve("fin") == nil)
  }
}
