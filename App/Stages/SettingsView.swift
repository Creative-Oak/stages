import AppKit
import ServiceManagement
import Sparkle
import SwiftUI

struct SettingsView: View {
  @AppStorage(ShortcutSettings.modifierKey) private var modifier = ShortcutSettings.Modifier.option.rawValue
  @AppStorage(ShortcutSettings.arrowsKey) private var arrows = true
  @AppStorage(ShortcutSettings.swipesKey) private var swipes = false
  @AppStorage(ShortcutSettings.swipeFingersKey) private var fingers = 3
  @State private var trusted = Permissions.accessibility
  @State private var loginStatus = SMAppService.mainApp.status
  @State private var loginError: String?
  private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    Form {
      Section {
        Toggle("Open at login", isOn: Binding(
          get: { loginStatus == .enabled },
          set: { on in
            do {
              if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
              loginError = nil
            } catch {
              loginError = error.localizedDescription
            }
            loginStatus = SMAppService.mainApp.status
          }))
        if loginStatus == .requiresApproval {
          Text("Allow Stages under System Settings → General → Login Items.").font(.callout).foregroundStyle(.secondary)
        }
        if let loginError { Text(loginError).font(.callout).foregroundStyle(.secondary) }
        if !Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/Applications") && !Bundle.main.bundlePath.hasPrefix("/Applications") {
          Text("Stages is running from \(Bundle.main.bundlePath). Install it first (`make install`) so the login item doesn't point at a build folder.")
            .font(.callout).foregroundStyle(.secondary)
        }
      } header: {
        Theme.label("General")
      }
      Section {
        Picker("Stage switcher", selection: $modifier) {
          ForEach(ShortcutSettings.Modifier.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
        }
        Text("Hold the modifier and press ⇥ to step through stages, most recent first. Release to switch, or press a stage's key (1–9, 0, A–Z) to go straight there. Esc cancels.")
          .font(.callout).foregroundStyle(.secondary)
        Toggle("⌃⌥ arrows switch to the previous / next stage", isOn: $arrows)
        Text("Next and previous follow the stages' slot keys: 1–9, 0, then A–Z. Every stage gets the next free key automatically; change it in the popover.")
          .font(.callout).foregroundStyle(.secondary)
      } header: {
        Theme.label("Keyboard")
      }
      Section {
        Toggle("Swipe left / right to switch stages", isOn: $swipes)
        Picker("Fingers", selection: $fingers) {
          Text("3 fingers").tag(3)
          Text("4 fingers").tag(4)
        }
        .pickerStyle(.segmented)
        .disabled(!swipes)
        Text("Swiping left goes to the next stage, right to the previous one. macOS uses the same swipe to move between Spaces and full-screen apps, and Stages can't stop it: turn off “Swipe between full-screen applications” for \(fingers) fingers, or set it to the other count.")
          .font(.callout).foregroundStyle(.secondary)
        Button("Open Trackpad Settings…") {
          if let u = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") { NSWorkspace.shared.open(u) }
        }
      } header: {
        Theme.label("Trackpad")
      }
      if Updater.enabled { UpdatesSection() }
      Section {
        LabeledContent("Accessibility") {
          if trusted {
            Text("Allowed").foregroundStyle(.secondary)
          } else {
            Button("Allow…") { Permissions.requestAccessibility() }
          }
        }
        LabeledContent("Screen Recording") {
          Text(Permissions.screenRecording ? "Allowed" : "Missing").foregroundStyle(.secondary)
        }
        Text("Accessibility lets Stages raise windows to switch stages and listen for its shortcuts. Screen Recording lets it read window titles. Nothing leaves this Mac.")
          .font(.callout).foregroundStyle(.secondary)
      } header: {
        Theme.label("Permissions")
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .onReceive(timer) { _ in trusted = Permissions.accessibility }
  }
}

/// Sparkle's two switches, read straight from (and written to) the updater.
private struct UpdatesSection: View {
  private let updater = Updater.shared.updater
  @State private var checks = Updater.shared.updater.automaticallyChecksForUpdates
  @State private var installs = Updater.shared.updater.automaticallyDownloadsUpdates

  var body: some View {
    Section {
      Toggle("Check for updates automatically", isOn: Binding(
        get: { checks }, set: { checks = $0; updater.automaticallyChecksForUpdates = $0 }))
      Toggle("Install updates automatically", isOn: Binding(
        get: { installs }, set: { installs = $0; updater.automaticallyDownloadsUpdates = $0 }))
        .disabled(!checks)
      LabeledContent("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")") {
        Button("Check Now…") { Updater.shared.checkForUpdates() }
      }
      Text("Updates come from the project's GitHub releases, signed and notarized. Stages relaunches by itself after installing one.")
        .font(.callout).foregroundStyle(.secondary)
    } header: {
      Theme.label("Updates")
    }
  }
}

enum SettingsWindow {
  private static var window: NSWindow?

  static func show() {
    if window == nil {
      let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
      w.title = "Stages Settings"
      w.isReleasedWhenClosed = false
      w.contentView = NSHostingView(rootView: SettingsView())
      w.setContentSize(w.contentView!.fittingSize)
      w.center()
      window = w
    }
    NSApp.activate()
    window?.makeKeyAndOrderFront(nil)
  }
}
