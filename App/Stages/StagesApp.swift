import AppKit

@main
enum StagesMain {
  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let model = AppModel()
  private var statusItem: StatusItemController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = StatusItemController(model: model)
    model.start()
  }
}

enum Permissions {
  static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

  /// Adds Stages to the Screen Recording list (prompting once), then opens the pane.
  static func requestScreenRecording() {
    _ = CGRequestScreenCaptureAccess()
    open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
  }

  static func openStageManagerSettings() {
    open("x-apple.systempreferences:com.apple.Desktop-Settings.extension")
  }

  /// Window titles from CGWindowList usually only appear after a relaunch.
  static func relaunch() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
    try? task.run()
    NSApp.terminate(nil)
  }

  private static func open(_ url: String) {
    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
  }
}
