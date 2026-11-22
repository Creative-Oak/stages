import AppKit
import os
import Reporting
import Sentry

/// Opt-in crash and error reports, sent to Sentry. Off until the user turns on Settings →
/// Privacy → "Send crash and error reports"; turning it off stops the SDK at once.
///
/// What a report holds: the crash or hang stack trace (Stages' own code), the fixed message of
/// an error below with its domain and code, macOS version, Mac model, Stages version, whether
/// Stages has its permissions, and a short trail of Stages' own breadcrumbs (switch started,
/// stage reading unavailable, ...). Never window titles, app or stage names, document paths
/// or file paths: messages are `StaticString`s, errors are summarised by `ErrorSummary`, and
/// `beforeSend` / `beforeBreadcrumb` redact paths and drop the SDK's other breadcrumbs.
///
/// The DSN comes from Info.plist (`SentryDSN`, set from the `SENTRY_DSN` build setting in
/// project.yml). Without one, reporting isn't offered.
enum ErrorReporting {
  static let enabledKey = "sendErrorReports"
  private static let log = Logger(subsystem: "dk.creativeoak.stages", category: "errors")

  static var dsn: String? {
    guard let s = Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String,
          s.hasPrefix("https://") else { return nil }
    return s
  }

  /// A DSN is built in, so reports can be turned on.
  static var isAvailable: Bool { dsn != nil }
  static var isOptedIn: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

  static func startIfOptedIn() {
    if isOptedIn { start() }
  }

  static func setOptedIn(_ on: Bool) {
    UserDefaults.standard.set(on, forKey: enabledKey)
    if on { start() } else if SentrySDK.isEnabled { SentrySDK.close() }
    log.notice("error reports \(on ? "on" : "off", privacy: .public)")
  }

  private static func start() {
    guard let dsn, !SentrySDK.isEnabled else { return }
    SentrySDK.start { o in
      o.dsn = dsn
      #if DEBUG
        o.environment = "development"
      #else
        o.environment = "production"
      #endif
      o.sendDefaultPii = false
      // AppKit otherwise swallows exceptions on the main thread and carries on in an unknown
      // state; with this they crash (and are reported) instead.
      o.enableUncaughtNSExceptionReporting = true
      // Only Sparkle talks to the network; its URLs and failures aren't Stages' errors.
      o.enableNetworkBreadcrumbs = false
      o.enableCaptureFailedRequests = false
      o.maxBreadcrumbs = 60
      // Both run on the SDK's own threads: @Sendable keeps them (and scrub) off the main actor.
      o.beforeBreadcrumb = { @Sendable crumb in
        guard Redactor.allowedBreadcrumbCategories.contains(crumb.category) else { return nil }
        crumb.message = crumb.message.map { Redactor.redact($0) }
        return crumb
      }
      o.beforeSend = { @Sendable event in scrub(event) }
    }
    updateContext()
    log.notice("error reports started")
  }

  /// Strips what could identify the person or their work.
  nonisolated private static func scrub(_ event: Event) -> Event {
    event.serverName = nil
    if let user = event.user {
      // Keep only the SDK's random installation ID (counts affected installs).
      user.email = nil; user.username = nil; user.name = nil; user.ipAddress = nil; user.geo = nil; user.data = nil
    }
    if var context = event.context {
      context["device"]?["name"] = nil
      context["app"]?["device_app_hash"] = nil
      event.context = context
    }
    event.request = nil
    if let m = event.message {
      event.message = SentryMessage(formatted: Redactor.redact(m.formatted))
    }
    event.exceptions?.forEach { e in
      e.value = e.value.map { Redactor.redact($0) }
      e.stacktrace?.frames.forEach { $0.package = $0.package.map { Redactor.redact($0) } }
    }
    event.threads?.forEach { t in
      t.stacktrace?.frames.forEach { $0.package = $0.package.map { Redactor.redact($0) } }
    }
    event.debugMeta?.forEach { $0.codeFile = $0.codeFile.map { Redactor.redact($0) } }
    event.breadcrumbs = event.breadcrumbs?.filter { Redactor.allowedBreadcrumbCategories.contains($0.category) }
    event.breadcrumbs?.forEach { $0.message = $0.message.map { Redactor.redact($0) } }
    return event
  }

  // MARK: Reporting

  /// Messages already reported this run: each problem is sent once, not on every snapshot.
  private static var sent = Set<String>()
  /// The last few problems this run (fixed text only), for "Report a Problem…".
  private(set) static var recent: [String] = []

  enum Level {
    case info, warning, error
    var sentry: SentryLevel {
      switch self {
      case .info: .info
      case .warning: .warning
      case .error: .error
      }
    }
  }

  /// Something went wrong that we want to hear about. `message` is fixed text, so nothing
  /// personal can be interpolated into it; `error` is reduced to its domain and code.
  static func error(_ message: StaticString, _ error: Error? = nil, level: Level = .error) {
    report(message.description, error, level: level)
  }

  /// For messages that come from the packages (StageStore's `onProblem`): fixed text there too.
  static func report(_ message: String, _ error: Error?, level: Level = .error) {
    let summary = error.map(ErrorSummary.describe)
    let line = summary.map { "\(message) [\($0)]" } ?? message
    log.error("\(line, privacy: .public)")
    if !recent.contains(line) { recent.append(line); if recent.count > 10 { recent.removeFirst() } }
    guard SentrySDK.isEnabled, sent.insert(line).inserted else { return }
    let sentryLevel = level.sentry
    SentrySDK.capture(message: message) { @Sendable scope in
      scope.setLevel(sentryLevel)
      if let summary { scope.setTag(value: summary, key: "error") }
      // Group by the message, not by where capture() was called from.
      scope.setFingerprint([message])
    }
  }

  /// A step in Stages' own trail (fixed text; no names or titles).
  static func breadcrumb(_ message: StaticString, level: Level = .info) {
    guard SentrySDK.isEnabled else { return }
    let crumb = Breadcrumb(level: level.sentry, category: "stages")
    crumb.message = message.description
    SentrySDK.addBreadcrumb(crumb)
  }

  /// Permissions and stage-reading state, attached to every report.
  static func updateContext(readingUnavailable: String? = nil) {
    guard SentrySDK.isEnabled else { return }
    let screen = Permissions.screenRecording, ax = Permissions.accessibility
    let wm = UserDefaults(suiteName: "com.apple.WindowManager")
    let stageManager = wm?.object(forKey: "GloballyEnabled") as? Bool ?? false
    let grouping = (wm?.object(forKey: "AppWindowGroupingBehavior") as? Int) == 1 ? "all at once" : "one at a time"
    let displays = NSScreen.screens.count
    SentrySDK.configureScope { @Sendable scope in
      scope.setTag(value: screen ? "yes" : "no", key: "screen_recording")
      scope.setTag(value: ax ? "yes" : "no", key: "accessibility")
      scope.setTag(value: readingUnavailable ?? "ok", key: "stage_reading")
      scope.setContext(value: ["stage_manager": stageManager, "grouping": grouping, "displays": displays], key: "stages")
    }
  }
}
