import AppKit
import StageReader
import SwiftUI
import WindowSource

/// "Report a Problem…": the tester says what happened, picks which diagnostics to attach (each
/// shown in full before it goes), and sends it to Sentry's User Feedback, or opens a GitHub
/// issue instead. Diagnostics are gathered when the window opens, so they show the moment of
/// the problem rather than of sending.
enum ReportProblemWindow {
  private static var window: NSWindow?

  static func show(model: AppModel, context: String? = nil) {
    // Before the window exists, so the layout capture shows the screen as it was.
    let report = ProblemReport(model: model, context: context)
    window?.close()
    let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    w.title = "Report a Problem"
    w.isReleasedWhenClosed = false
    w.contentView = NSHostingView(rootView: ReportProblemView(report: report) { w.close() })
    w.setContentSize(NSSize(width: 520, height: 560))
    w.contentMinSize = NSSize(width: 460, height: 440)
    w.center()
    window = w
    NSApp.activate()
    w.makeKeyAndOrderFront(nil)
  }
}

/// What a report can carry, gathered once.
@Observable
final class ProblemReport {
  struct Item: Identifiable {
    let id: String
    let title: String
    let detail: String
    let filename: String
    var text: String
    var included: Bool
  }

  var message: String
  var email = ""
  var items: [Item]
  var sent = false

  init(model: AppModel, context: String?) {
    message = context.map { "\($0)\n\n" } ?? ""
    let capture = WindowCapture.redactingTitles([LiveWindowSource().capture()])
    let fixture = Fixture(name: "problem-report", note: context ?? "", intervalMs: 0, frames: capture)
    let layout = (try? Fixture.encoder().encode(fixture)).map { String(decoding: $0, as: UTF8.self) } ?? "(couldn't read the window layout)"
    items = [
      Item(id: "setup", title: "Mac and Stages setup",
           detail: "Versions, Mac model, Stage Manager settings, permissions, problems this run. No titles or names.",
           filename: "setup.txt", text: Feedback.environment(model: model), included: true),
      Item(id: "layout", title: "Window layout",
           detail: "Every window's app, position and size, as Stages reads them. Window titles are replaced (“Safari window 2”).",
           filename: "layout.json", text: layout, included: false),
      Item(id: "log", title: "Recent log",
           detail: "The last hour of Stages' own log: switches, timings, app names. No window titles.",
           filename: "log.txt", text: "Reading the log…", included: false),
    ]
    Task {
      let log = (try? await Task.detached(priority: .userInitiated) { try Feedback.recentLog() }.value)
        ?? "(couldn't read the log)"
      if let i = items.firstIndex(where: { $0.id == "log" }) { items[i].text = log }
    }
  }

  var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
  var included: [Item] { items.filter(\.included) }

  func send() {
    let email = email.trimmingCharacters(in: .whitespaces)
    ErrorReporting.sendReport(
      message: trimmedMessage, email: email.isEmpty ? nil : email,
      attachments: included.map { .init(filename: $0.filename, text: $0.text) })
    sent = true
  }

  /// A GitHub issue with the message and setup in its body. Other attachments are too long for
  /// a URL: they're saved to a folder that opens in Finder, ready to drag into the issue.
  func openIssue() {
    let setup = included.first { $0.id == "setup" }?.text
    Feedback.openIssue(message: trimmedMessage, setup: setup)
    let files = included.filter { $0.id != "setup" }
    guard !files.isEmpty else { return }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HHmmss"
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Stages report \(f.string(from: Date()))")
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let urls = try files.map { item -> URL in
        let url = dir.appendingPathComponent(item.filename)
        try item.text.write(to: url, atomically: true, encoding: .utf8)
        return url
      }
      NSWorkspace.shared.activateFileViewerSelecting(urls)
    } catch {
      ErrorReporting.error("couldn't save report attachments", error, level: .warning)
      NSSound.beep()
    }
  }
}

struct ReportProblemView: View {
  @Bindable var report: ProblemReport
  let close: () -> Void
  @State private var previewing: String?

  var body: some View {
    if report.sent { sentView } else { form }
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 6) {
        Theme.label("What happened?")
        TextEditor(text: $report.message)
          .font(.system(size: 13))
          .frame(minHeight: 110)
          .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
        Text("What you did, what you expected, and what Stages did instead.")
          .font(.callout).foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 6) {
        Theme.label("Attach")
        ForEach($report.items) { $item in
          VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
              Toggle(item.title, isOn: $item.included)
              Spacer()
              Button(previewing == item.id ? "Hide" : "Show") {
                previewing = previewing == item.id ? nil : item.id
              }
              .buttonStyle(.link).font(.callout)
            }
            Text(item.detail).font(.callout).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.leading, 20)
            if previewing == item.id {
              ScrollView([.vertical, .horizontal]) {
                Text(item.text).font(Theme.mono(11)).textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading).padding(6)
              }
              .frame(height: 150)
              .background(.background.secondary)
              .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
              .padding(.leading, 20)
            }
          }
        }
      }

      if ErrorReporting.isAvailable {
        LabeledContent("Email (optional)") {
          TextField("", text: $report.email, prompt: Text("so we can ask follow-up questions"))
            .textFieldStyle(.roundedBorder)
        }
      }

      Spacer(minLength: 0)
      Divider()
      HStack {
        Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
        Spacer()
        Button("Open GitHub Issue…") { report.openIssue(); close() }
          .disabled(report.trimmedMessage.isEmpty)
        if ErrorReporting.isAvailable {
          Button("Send Report") { report.send() }
            .keyboardShortcut(.defaultAction)
            .disabled(report.trimmedMessage.isEmpty)
        }
      }
      Text(ErrorReporting.isAvailable
        ? "Send Report sends your text and the ticked attachments, exactly as shown, to the developer (via Sentry). It works whether or not crash reports are on. GitHub issues are public."
        : "GitHub issues are public.")
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(18)
  }

  private var sentView: some View {
    VStack(spacing: 12) {
      Spacer()
      Text("Thanks — report sent.").font(Theme.grotesk(15, .semibold))
      Text("It arrives with the attachments you ticked. If you left an email, you may hear back.")
        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
      Button("Close", action: close).keyboardShortcut(.defaultAction)
      Spacer()
    }
    .padding(24)
    .frame(maxWidth: .infinity)
  }
}
