import ApplicationServices
import StageReader

/// Finds the document behind each window (`AXDocument`) for stage fingerprints. Needs
/// Accessibility; without it, resolves nothing. AX windows carry no CG window number in the
/// public API, so they are matched by title, and titles that appear twice in one app are skipped.
enum DocumentResolver {
  static var isTrusted: Bool { AXIsProcessTrusted() }

  /// Runs off the main thread; AX calls can block on a busy app (capped at 0.25 s each).
  static func resolve(_ windows: [StageWindow]) async -> [UInt32: String] {
    await Task.detached(priority: .utility) { resolveNow(windows) }.value
  }

  private nonisolated static func resolveNow(_ windows: [StageWindow]) -> [UInt32: String] {
    guard AXIsProcessTrusted() else { return [:] }
    var result: [UInt32: String] = [:]
    for (pid, group) in Dictionary(grouping: windows, by: \.pid) {
      let app = AXUIElementCreateApplication(pid)
      AXUIElementSetMessagingTimeout(app, 0.25)
      var value: CFTypeRef?
      guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
            let axWindows = value as? [AXUIElement] else { continue }
      var byTitle: [String: [String?]] = [:]
      for w in axWindows {
        var t: CFTypeRef?, d: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
        AXUIElementCopyAttributeValue(w, kAXDocumentAttribute as CFString, &d)
        if let title = t as? String { byTitle[title, default: []].append(d as? String) }
      }
      for w in group {
        guard let title = w.title, let docs = byTitle[title], docs.count == 1, let doc = docs[0], !doc.isEmpty else { continue }
        result[w.id] = doc
      }
    }
    return result
  }
}
