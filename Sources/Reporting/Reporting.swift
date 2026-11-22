import Foundation

/// What may leave the Mac in an error report. Stages reads window titles, document paths and
/// stage names; none of them belong in a report. These are the rules the app's Sentry
/// `beforeSend` / `beforeBreadcrumb` apply, kept pure so they're tested.
public enum Redactor {
  /// Replaces the home folder with `~`, and any other user's home or a volume name with a
  /// placeholder (`/Users/magnus/Applications/Stages.app` → `~/Applications/Stages.app`).
  public static func redact(_ text: String, home: String = NSHomeDirectory()) -> String {
    var s = text
    if home.count > 1 {
      // Only whole path components: /Users/mag must not turn /Users/magnus into ~nus.
      s = replace(NSRegularExpression.escapedPattern(for: home) + #"(?=/|$|[\s"'])"#, in: s, with: "~")
    }
    s = replace(#"/Users/[^/\s"':]+"#, in: s, with: "/Users/<user>")
    s = replace(#"/Volumes/[^/\s"':]+"#, in: s, with: "/Volumes/<volume>")
    return s
  }

  /// Breadcrumb categories that are allowed through: Stages' own (fixed text, written to be
  /// safe) and the SDK's app-lifecycle ones. Everything else (UI events, network) is dropped.
  public static let allowedBreadcrumbCategories: Set<String> = [
    "stages", "app.lifecycle", "started", "device.event",
  ]

  private static func replace(_ pattern: String, in s: String, with template: String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
    return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
  }
}

/// An error described by type, domain, code and coding path only: never its
/// `localizedDescription`, which can carry file paths or user data.
public enum ErrorSummary {
  public static func describe(_ error: Error) -> String {
    if let e = error as? DecodingError { return describe(e) }
    if let e = error as? EncodingError {
      if case let .invalidValue(_, context) = e { return "EncodingError.invalidValue at \(path(context.codingPath))" }
      return "EncodingError"
    }
    let ns = error as NSError
    var s = "\(ns.domain) \(ns.code)"
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
      s += " (underlying \(underlying.domain) \(underlying.code))"
    }
    return s
  }

  private static func describe(_ e: DecodingError) -> String {
    switch e {
    case let .dataCorrupted(c): return "DecodingError.dataCorrupted at \(path(c.codingPath))"
    case let .keyNotFound(key, c): return "DecodingError.keyNotFound \(key.stringValue) at \(path(c.codingPath))"
    case let .typeMismatch(_, c): return "DecodingError.typeMismatch at \(path(c.codingPath))"
    case let .valueNotFound(_, c): return "DecodingError.valueNotFound at \(path(c.codingPath))"
    @unknown default: return "DecodingError"
    }
  }

  /// Coding keys are the file format's own names (and array indices), not user data.
  private static func path(_ keys: [CodingKey]) -> String {
    keys.isEmpty ? "root" : keys.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
  }
}
