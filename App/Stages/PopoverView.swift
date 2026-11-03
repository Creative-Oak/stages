import SwiftUI
import StageReader
import StageStore

struct PopoverView: View {
  @Bindable var model: AppModel
  @State private var editing: UUID?

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
      Divider()
      footer
    }
    .frame(width: 360)
  }

  // MARK: Header / footer

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Stages").font(Theme.grotesk(15, .semibold))
      Spacer()
      if let d = model.snapshot?.diagnostics, model.snapshot?.isAvailable == true {
        if d.confidence == .low {
          // State is drawn, not coloured: a ruled label plus the reason on hover.
          Text("Low confidence")
            .font(Theme.grotesk(11, .medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(Rectangle().strokeBorder(.primary, lineWidth: 1))
            .help(d.concerns.joined(separator: "\n"))
        } else {
          Text("\(model.stages.count) stages").font(Theme.mono(11)).foregroundStyle(.secondary)
        }
      }
    }
    .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
  }

  private var footer: some View {
    HStack {
      Button("Copy Diagnostics") { model.copyDiagnostics() }
        .disabled(model.snapshot == nil)
      Button("Matching…") { MatchingDebugWindow.show(model: model) }
      Spacer()
      Button("Quit Stages") { NSApp.terminate(nil) }
        .keyboardShortcut("q")
    }
    .buttonStyle(.borderless)
    .font(.system(size: 12))
    .padding(.horizontal, 14).padding(.vertical, 9)
  }

  // MARK: Content

  @ViewBuilder private var content: some View {
    if let snapshot = model.snapshot, let reason = snapshot.unavailable {
      UnavailableView(reason: reason)
    } else if model.snapshot == nil {
      Text("Reading stages…")
        .font(Theme.serif(14)).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 120)
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          section("Centre", model.stages(.centre),
                  empty: "Nothing on the centre stage. Click a stage in the strip to bring it here.")
          section("Strip", model.stages(.strip), empty: nil)
          section("Overflow", model.stages(.overflow), empty: nil)
        }
        .padding(.bottom, 6)
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(maxHeight: 520)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private func section(_ title: String, _ stages: [IdentifiedStage], empty: String?) -> some View {
    if !stages.isEmpty || empty != nil {
      Theme.label(title)
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
      if stages.isEmpty, let empty {
        Text(empty)
          .font(Theme.serif(13)).foregroundStyle(.secondary)
          .padding(.horizontal, 14).padding(.bottom, 8)
      }
      ForEach(stages) { s in
        StageRow(model: model, stage: s, showsDisplay: model.displayCount > 1,
                 isCurrent: s.id == model.current?.id, editing: $editing)
      }
    }
  }
}

// MARK: - Row

struct StageRow: View {
  let model: AppModel
  let stage: IdentifiedStage
  let showsDisplay: Bool
  let isCurrent: Bool
  @Binding var editing: UUID?
  @State private var hovering = false

  private var isEditing: Bool { editing == stage.id }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.easeOut(duration: 0.18)) { editing = isEditing ? nil : stage.id }
      } label: {
        summary
      }
      .buttonStyle(.plain)
      .contextMenu { StageMenu(model: model, stage: stage) }

      if isEditing {
        StageEditor(model: model, stage: stage)
          .transition(.opacity)
      }
    }
    .background(hovering || isEditing ? Color.primary.opacity(0.05) : .clear)
    // Current stage: the 2 px rule, in its ink when it has one.
    .overlay(alignment: .leading) {
      if isCurrent { Rectangle().fill(stage.record.ink?.color ?? .primary).frame(width: 2) }
    }
    .onHover { hovering = $0 }
  }

  private var summary: some View {
    HStack(alignment: .top, spacing: 10) {
      InkSwatch(ink: stage.record.ink, size: 10)
        .padding(.top, 4)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(stage.title)
            .font(Theme.grotesk(14, stage.isNamed ? .semibold : .regular))
            .foregroundStyle(stage.isNamed ? .primary : .secondary)
            .lineLimit(1)
          Spacer(minLength: 4)
          HStack(spacing: -3) {
            ForEach(Array(stage.appIcons.prefix(4).enumerated()), id: \.offset) { _, icon in
              Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            }
          }
          if let slot = stage.record.slot {
            Text("\(slot)")
              .font(Theme.mono(11, .medium))
              .frame(width: 16, height: 16)
              .overlay(Rectangle().strokeBorder(.primary.opacity(0.5), lineWidth: 1))
              .help("Slot \(slot)")
          }
        }
        if stage.isNamed {
          Text(stage.appsTitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        ForEach(stage.windowTitles.prefix(3), id: \.self) { t in
          Text(t).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
        }
        if stage.windowTitles.count > 3 {
          Text("+\(stage.windowTitles.count - 3) more").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        if showsDisplay {
          Text("Display \(stage.stage.displayID)").font(Theme.mono(10)).foregroundStyle(.tertiary)
        }
      }
    }
    .padding(.horizontal, 14).padding(.vertical, 7)
    .contentShape(Rectangle())
  }
}

// MARK: - Editing

struct StageEditor: View {
  let model: AppModel
  let stage: IdentifiedStage
  @State private var draft = ""
  @FocusState private var nameFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      TextField(stage.appsTitle, text: $draft)
        .textFieldStyle(.roundedBorder)
        .font(Theme.grotesk(13))
        .focused($nameFocused)
        .onSubmit { model.rename(stage.id, draft) }

      HStack(spacing: 6) {
        ForEach(Ink.allCases, id: \.self) { ink in swatchButton(ink) }
        swatchButton(nil)
        Spacer()
      }

      HStack(spacing: 8) {
        Theme.label("Slot")
        Picker("Slot", selection: Binding(
          get: { stage.record.slot ?? 0 },
          set: { model.setSlot(stage.id, $0 == 0 ? nil : $0) })
        ) {
          Text("–").tag(0)
          ForEach(1...9, id: \.self) { Text("\($0)").font(Theme.mono(11)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
      }
    }
    .padding(.leading, 34).padding(.trailing, 14).padding(.bottom, 10).padding(.top, 2)
    .onAppear { draft = stage.record.name ?? ""; nameFocused = true }
    .onDisappear { if draft != (stage.record.name ?? "") { model.rename(stage.id, draft) } }
  }

  private func swatchButton(_ ink: Ink?) -> some View {
    let selected = stage.record.ink == ink
    return Button { model.setInk(stage.id, ink) } label: {
      InkSwatch(ink: ink, size: 18)
        .padding(2)
        // Selected: the 2 px rule around the swatch.
        .overlay(Rectangle().strokeBorder(selected ? Color.primary : .clear, lineWidth: 2))
    }
    .buttonStyle(.plain)
    .help(ink?.title ?? "No ink")
    .accessibilityLabel(ink?.title ?? "No ink")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// Right-click menu: the same actions, the native way.
struct StageMenu: View {
  let model: AppModel
  let stage: IdentifiedStage

  var body: some View {
    Menu("Ink") {
      ForEach(Ink.allCases, id: \.self) { ink in
        Toggle(ink.title, isOn: Binding(get: { stage.record.ink == ink }, set: { _ in model.setInk(stage.id, ink) }))
      }
      Divider()
      Button("None") { model.setInk(stage.id, nil) }
    }
    Menu("Slot") {
      ForEach(1...9, id: \.self) { n in
        Toggle("\(n)", isOn: Binding(get: { stage.record.slot == n }, set: { _ in model.setSlot(stage.id, n) }))
      }
      Divider()
      Button("None") { model.setSlot(stage.id, nil) }
    }
    if stage.isNamed {
      Divider()
      Button("Clear Name") { model.rename(stage.id, "") }
    }
  }
}

// MARK: - Can't see stages

struct UnavailableView: View {
  let reason: StageSnapshot.Unavailable

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(reason.message).font(Theme.grotesk(14, .semibold))
      Text(explanation).font(Theme.serif(13)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        switch reason {
        case .noScreenRecording:
          Button("Open Privacy Settings") { Permissions.requestScreenRecording() }
            .buttonStyle(.borderedProminent)
          Button("Relaunch Stages") { Permissions.relaunch() }
        case .stageManagerOff:
          Button("Open Desktop & Dock") { Permissions.openStageManagerSettings() }
            .buttonStyle(.borderedProminent)
        case .noOverlays:
          Button("Relaunch Stages") { Permissions.relaunch() }
        }
      }
      .controlSize(.regular)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var explanation: String {
    switch reason {
    case .noScreenRecording:
      "Stages finds Stage Manager's stages through window titles, which macOS only shares with apps allowed to record the screen. Stages never captures pixels, and titles never leave this Mac. After allowing it, relaunch Stages."
    case .stageManagerOff:
      "Turn on Stage Manager in Control Centre or in Desktop & Dock settings, and your stages will appear here."
    case .noOverlays:
      "Stage Manager is on, but its stage overlays weren't in the window list. If you just allowed Screen Recording, relaunch Stages. Otherwise, Copy Diagnostics and send it to the developer."
    }
  }
}
