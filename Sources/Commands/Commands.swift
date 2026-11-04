import Foundation
import StageReader

/// A `stages://` URL, parsed. Raycast Quicklinks (or anything else) open these.
///
///   stages://switch?slot=3            stages://switch?name=Swifttap      stages://switch?id=<uuid>
///   stages://next                     stages://previous
///   stages://name?value=Lodestone     (current stage; empty value clears)
///   stages://ink?value=teal           (or none)
///   stages://slot?value=3             (or none)
///   stages://wake?name=Reading        (relaunch a sleeping stage's apps and documents)
public enum Command: Equatable, Sendable {
  case switchToSlot(String)
  case switchToName(String)
  case switchToID(UUID)
  case next
  case previous
  case rename(String?)
  case ink(String?)
  case slot(String?)
  case wake(String)

  public enum ParseError: Error, Equatable, CustomStringConvertible {
    case notStages(String)
    case unknownCommand(String)
    case missing(String)
    case invalid(String, String)

    public var description: String {
      switch self {
      case let .notStages(s): "not a stages:// URL: \(s)"
      case let .unknownCommand(c): "unknown command “\(c)” (switch, next, previous, name, ink, slot, wake)"
      case let .missing(p): "missing parameter “\(p)”"
      case let .invalid(p, v): "invalid \(p): “\(v)”"
      }
    }
  }

  public static let scheme = "stages"

  public static func parse(_ url: URL) -> Result<Command, ParseError> {
    guard url.scheme?.lowercased() == scheme else { return .failure(.notStages(url.absoluteString)) }
    // stages://switch?… has the command as host; stages:switch?… (no slashes) as path.
    let name = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func param(_ key: String) -> String? { items.first { $0.name.lowercased() == key }?.value }

    switch name {
    case "switch":
      if let s = param("slot") {
        guard SlotKeys.isValid(s) else { return .failure(.invalid("slot", s)) }
        return .success(.switchToSlot(s.lowercased()))
      }
      if let n = param("name") {
        let trimmed = n.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure(.invalid("name", n)) }
        return .success(.switchToName(trimmed))
      }
      if let i = param("id") {
        guard let id = UUID(uuidString: i) else { return .failure(.invalid("id", i)) }
        return .success(.switchToID(id))
      }
      return .failure(.missing("slot, name or id"))
    case "next": return .success(.next)
    case "previous", "prev": return .success(.previous)
    case "name":
      guard let v = param("value") else { return .failure(.missing("value")) }
      let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
      return .success(.rename(trimmed.isEmpty ? nil : trimmed))
    case "ink":
      guard let v = param("value")?.lowercased() else { return .failure(.missing("value")) }
      return .success(.ink(v == "none" || v.isEmpty ? nil : v))
    case "slot":
      guard let v = param("value")?.lowercased() else { return .failure(.missing("value")) }
      if v == "none" || v.isEmpty { return .success(.slot(nil)) }
      guard SlotKeys.isValid(v) else { return .failure(.invalid("slot", v)) }
      return .success(.slot(v))
    case "wake":
      guard let n = param("name")?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return .failure(.missing("name")) }
      return .success(.wake(n))
    default:
      return .failure(.unknownCommand(name))
    }
  }

  /// Which stage a `switch?name=` value means, in order: an exact (case-insensitive) match,
  /// where a name someone chose beats a generated one ("Safari + Notes"); the only name it is a
  /// prefix of; the only name in which every query word starts a word ("word" → "Microsoft
  /// Word + Signal"). nil if none or ambiguous: it never guesses between equals.
  public static func resolve(name query: String, chosen: [(id: UUID, name: String)],
                             generated: [(id: UUID, name: String)] = []) -> UUID? {
    let q = query.lowercased().trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return nil }
    for group in [chosen, generated] {
      let exact = group.filter { $0.name.lowercased() == q }
      if exact.count == 1 { return exact[0].id }
      if exact.count > 1 { return nil }
    }
    let names = chosen + generated
    let prefixed = names.filter { $0.name.lowercased().hasPrefix(q) }
    if prefixed.count == 1 { return prefixed[0].id }
    if prefixed.count > 1 { return nil }
    let qWords = words(q)
    let byWords = names.filter { n in
      let w = words(n.name)
      return qWords.allSatisfy { qw in w.contains { $0.hasPrefix(qw) } }
    }
    return byWords.count == 1 ? byWords[0].id : nil
  }

  static func words(_ s: String) -> [String] {
    s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
  }
}
