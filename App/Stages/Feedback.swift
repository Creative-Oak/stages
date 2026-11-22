import AppKit
import OSLog
import StageReader

/// "Report a Problem…" and "Save Log…" (Settings → Privacy & Feedback).
enum Feedback {
  static let newIssueURL = "https://github.com/Creative-Oak/stages/issues/new"

  /// Opens a new GitHub issue with the questions to answer and the facts about this Mac and
  /// Stages filled in. Issues are public, so those facts hold no titles, names or paths.
  static func reportProblem(model: AppModel) {
    let body = """
      **What happened?**


      **What did you expect to happen?**


      **How can it be reproduced?**


      <!-- If it's about how stages are read or matched, "Copy Diagnostics" in the popover copies \
      the current reading, and Settings → Save Log… saves Stages' recent log. Both include window \
      titles or app names: look them over before attaching. -->

      ---
      \(environment(model: model))
      """
    var c = URLComponents(string: newIssueURL)!
    c.queryItems = [URLQueryItem(name: "body", value: body)]
    if let url = c.url { NSWorkspace.shared.open(url) }
  }

  /// Version, macOS, Mac model, Stage Manager settings, permissions and reading state.
  static func environment(model: AppModel) -> String {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? "?"
    let build = info["CFBundleVersion"] as? String ?? "?"
    let wm = UserDefaults(suiteName: "com.apple.WindowManager")
    let stageManager = (wm?.object(forKey: "GloballyEnabled") as? Bool ?? false) ? "on" : "off"
    let grouping = (wm?.object(forKey: "AppWindowGroupingBehavior") as? Int) == 1 ? "all at once" : "one at a time"
    let reading: String
    if let snapshot = model.snapshot {
      reading = snapshot.unavailable.map { "unavailable (\($0.rawValue))" }
        ?? "\(model.stages.count) stages, confidence \(snapshot.diagnostics.confidence.rawValue)"
    } else {
      reading = "no reading yet"
    }
    var lines = [
      "- Stages \(version) (\(build))\(Updater.enabled ? "" : ", debug build")",
      "- macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(macModel)",
      "- Stage Manager \(stageManager), windows \(grouping), \(NSScreen.screens.count) display(s)",
      "- Screen Recording \(Permissions.screenRecording ? "yes" : "no"), Accessibility \(Permissions.accessibility ? "yes" : "no")",
      "- Reading: \(reading)",
      "- Error reports \(ErrorReporting.isOptedIn ? "on" : "off")",
    ]
    if !ErrorReporting.recent.isEmpty {
      lines.append("- Problems this run:")
      lines += ErrorReporting.recent.map { "  - \($0)" }
    }
    return lines.joined(separator: "\n")
  }

  private static var macModel: String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    guard size > 0 else { return "unknown Mac" }
    var bytes = [UInt8](repeating: 0, count: size)
    sysctlbyname("hw.model", &bytes, &size, nil, 0)
    return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
  }

  /// Saves the last hour of Stages' own log (this run) to a file the user picks.
  static func saveLog() {
    Task {
      let text: String
      do {
        text = try await Task.detached(priority: .userInitiated) { try recentLog() }.value
      } catch {
        ErrorReporting.error("couldn't read the log", error, level: .warning)
        NSSound.beep()
        return
      }
      let panel = NSSavePanel()
      let f = DateFormatter()
      f.dateFormat = "yyyy-MM-dd HHmm"
      panel.nameFieldStringValue = "Stages log \(f.string(from: Date())).txt"
      panel.allowedContentTypes = [.plainText]
      NSApp.activate()
      guard panel.runModal() == .OK, let url = panel.url else { return }
      do { try text.write(to: url, atomically: true, encoding: .utf8) } catch {
        ErrorReporting.error("couldn't save the log", error, level: .warning)
        NSSound.beep()
      }
    }
  }

  nonisolated private static func recentLog() throws -> String {
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    let start = store.position(date: Date().addingTimeInterval(-3600))
    let entries = try store.getEntries(at: start, matching: NSPredicate(format: "subsystem == %@", "dk.creativeoak.stages"))
    let time = DateFormatter()
    time.dateFormat = "HH:mm:ss.SSS"
    let lines = entries.compactMap { $0 as? OSLogEntryLog }.map {
      "\(time.string(from: $0.date)) [\($0.category)] \($0.composedMessage)"
    }
    let info = Bundle.main.infoDictionary ?? [:]
    let header = """
      Stages \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?")), \
      macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
      The last hour of this run's log. It includes app names and stage IDs (no window titles): \
      look it over before sharing.

      """
    return header + lines.joined(separator: "\n") + "\n"
  }
}
