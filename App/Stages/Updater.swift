import AppKit
import Sparkle

/// Sparkle auto-updates from GitHub Releases (`SUFeedURL` in Info.plist; `make release` publishes).
/// Checks every 6 hours; with automatic installs on, an update is downloaded in the background and
/// installed straight away (Stages relaunches in about a second), since a menu-bar app rarely quits.
/// Debug builds don't check: they aren't signed with the release identity.
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
  static let shared = Updater()

  private(set) lazy var controller = SPUStandardUpdaterController(
    startingUpdater: Self.enabled, updaterDelegate: self, userDriverDelegate: self)

  static var enabled: Bool {
    #if DEBUG
      false
    #else
      true
    #endif
  }

  var updater: SPUUpdater { controller.updater }

  func start() { _ = controller }

  func checkForUpdates() { controller.checkForUpdates(nil) }

  // MARK: SPUUpdaterDelegate

  /// An update downloaded in the background would otherwise wait for Stages to quit.
  func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
               immediateInstallationBlock: @escaping () -> Void) -> Bool {
    immediateInstallationBlock()
    return true
  }

  // MARK: SPUStandardUserDriverDelegate

  /// Stages is a background (menu-bar) app: no alert windows popping up over other apps when
  /// automatic installs are off; the update waits for "Check for Updates…".
  var supportsGentleScheduledUpdateReminders: Bool { true }
}
