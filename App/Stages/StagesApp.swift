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
  private var hotkeys: HotkeyTap?
  private var ring: RingPanel?

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = StatusItemController(model: model)
    model.start()
    let ring = RingPanel(model: model)
    self.ring = ring
    model.onStep = { ring.show(target: $0) }
    hotkeys = HotkeyTap(model: model, panel: SwitcherPanel(model: model))
    hotkeys?.start()
  }
}

enum Permissions {
  static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

  /// Adds Stages to the Screen Recording list (prompting once), then opens the pane.
  static func requestScreenRecording() {
    _ = CGRequestScreenCaptureAccess()
    open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
  }

  /// Needed to raise windows (switching) and for the keyboard shortcuts' event tap.
  static var accessibility: Bool { AXIsProcessTrusted() }

  /// Shows the system prompt (which adds Stages to the list) and opens the pane.
  static func requestAccessibility() {
    // kAXTrustedCheckOptionPrompt is a C global Swift 6 won't read; its value is this string.
    let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
  }

  static func openStageManagerSettings() {
    open("x-apple.systempreferences:com.apple.Desktop-Settings.extension")
  }

  /// Window titles from CGWindowList usually only appear after a relaunch.
  static func relaunch() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    // Wait for this process to exit first; `open` on a still-quitting app just re-activates it.
    task.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"",
                      Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
    try? task.run()
    NSApp.terminate(nil)
  }

  private static func open(_ url: String) {
    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
  }
}
