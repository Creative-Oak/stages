import AppKit
import SwiftUI

struct SettingsView: View {
  @AppStorage(ShortcutSettings.modifierKey) private var modifier = ShortcutSettings.Modifier.option.rawValue
  @AppStorage(ShortcutSettings.arrowsKey) private var arrows = true
  @State private var trusted = Permissions.accessibility
  private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    Form {
      Section {
        Picker("Stage switcher", selection: $modifier) {
          ForEach(ShortcutSettings.Modifier.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
        }
        Text("Hold the modifier and press ⇥ to step through stages, most recent first. Type to filter, release to switch, Esc to cancel.")
          .font(.callout).foregroundStyle(.secondary)
        Toggle("⌃⌥ arrows switch to the previous / next stage", isOn: $arrows)
        Text("Next and previous follow a fixed order: slots 1–9 first, then the oldest stages.")
          .font(.callout).foregroundStyle(.secondary)
      } header: {
        Theme.label("Keyboard")
      }
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
