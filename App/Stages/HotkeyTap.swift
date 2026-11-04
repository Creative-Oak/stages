import AppKit
import Carbon.HIToolbox
import CoreGraphics
import os
import StageReader
import Switcher

/// Global keyboard shortcuts through a `CGEventTap` (needs Accessibility):
///   hold ⌥ (configurable) + ⇥  open the switcher on the previous stage; ⇥/⇧⇥, ←/→ or ↑/↓ step;
///                              a stage's slot key (1–9, 0, a–z but q/w) goes straight there; Q quits, W closes; release ⌥
///                              to switch; Esc cancels; ↩ switches.
///   ⌃⌥ ←/↑ and →/↓            previous / next stage in the stable cycle.
///   3- or 4-finger swipe        (opt-in) left = next, right = previous; never swallowed, so
///                              macOS's own swipe for that finger count must be turned off.
/// Keys are swallowed only while the switcher is open or when a shortcut matches.
final class HotkeyTap {
  private let model: AppModel
  private let panel: SwitcherPanel
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var retry: Timer?
  private var session: SwitcherSession?
  /// Set while the in-stage switcher (modifier + `) is open: its items are windows.
  private var windowItems: [UUID: StageWindow]?
  private var swipes = SwipeDetector()
  /// The panel appears only if the modifier is still held after this, like ⌘⇥: a quick tap
  /// switches without flashing anything.
  private static let panelDelay: DispatchTimeInterval = .milliseconds(100)
  private var panelShown = false
  private var panelGeneration = 0
  /// CG event type for trackpad gesture events (NSEvent.EventType.gesture); not in CGEventType.
  private static let gestureType: UInt32 = 29
  private static let log = Logger(subsystem: "dk.creativeoak.stages", category: "hotkeys")

  private enum Key {
    static let tab: Int64 = 48, escape: Int64 = 53, returnKey: Int64 = 36, keypadEnter: Int64 = 76
    static let delete: Int64 = 51, left: Int64 = 123, right: Int64 = 124, down: Int64 = 125, up: Int64 = 126
    /// The key under Esc: ` on ANSI (US) keyboards (code 50); on ISO keyboards (Danish: $ / §)
    /// it's code 10, and 50 is the < key by left Shift, so 50 only counts on ANSI.
    static let underEscISO: Int64 = 10, graveANSI: Int64 = 50
    static func isUnderEsc(_ key: Int64) -> Bool {
      key == underEscISO || (key == graveANSI && KBGetLayoutType(Int16(LMGetKbdType())) != kKeyboardISO)
    }
    /// ⌘W, ⌘Q, ⌘M, ⌘H close, quit, minimise or hide: the stages change, so look sooner.
    static let windowChanging: Set<Int64> = [13, 12, 46, 4]
  }

  init(model: AppModel, panel: SwitcherPanel) {
    self.model = model
    self.panel = panel
    model.onCommitted = { [weak self] in self?.refreshSession() }
  }

  /// A newer snapshot while the switcher is open: drop stages that closed, keep the rest in place.
  private func refreshSession() {
    guard windowItems == nil, var s = session else { return }
    s.refresh(model.switcherCandidates())
    session = s
    if panelShown { panel.show(s) }
  }

  /// Installs the tap now, or as soon as Accessibility is granted.
  func start() {
    guard tap == nil else { return }
    if install() { return }
    retry?.invalidate()
    retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.install() else { return }
        self.retry?.invalidate(); self.retry = nil
      }
    }
  }

  var isInstalled: Bool { tap != nil }

  private func install() -> Bool {
    guard AXIsProcessTrusted() else { return false }
    let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
    let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) } | (1 << Self.gestureType)
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
      callback: { _, type, event, refcon in
        // The tap's run-loop source is on the main run loop, so this runs on the main thread.
        nonisolated(unsafe) let event = event
        nonisolated(unsafe) var result: Unmanaged<CGEvent>?
        MainActor.assumeIsolated {
          let me = Unmanaged<HotkeyTap>.fromOpaque(refcon!).takeUnretainedValue()
          result = me.handle(type, event)
        }
        return result
      },
      userInfo: Unmanaged.passUnretained(self).toOpaque())
    else {
      Self.log.error("event tap could not be created")
      return false
    }
    let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    self.tap = tap
    self.source = source
    Self.log.notice("event tap installed")
    return true
  }

  // MARK: Events

  private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    if type.rawValue == Self.gestureType {
      swipe(event)
      return Unmanaged.passUnretained(event)
    }
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return Unmanaged.passUnretained(event)
    case .flagsChanged:
      // Releasing the switcher's modifier switches.
      if session != nil, !event.flags.contains(ShortcutSettings.modifier.flag) { commit() }
      return Unmanaged.passUnretained(event)
    case .keyDown:
      return keyDown(event) ? nil : Unmanaged.passUnretained(event)
    case .keyUp:
      return session != nil ? nil : Unmanaged.passUnretained(event)
    default:
      return Unmanaged.passUnretained(event)
    }
  }

  /// True when the event was ours (swallowed).
  private func keyDown(_ event: CGEvent) -> Bool {
    let key = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let shift = flags.contains(.maskShift)

    if var s = session {
      switch key {
      case Key.tab: s.step(shift ? -1 : 1)
      case _ where Key.isUnderEsc(key): s.step(shift ? -1 : 1)
      case Key.down, Key.right: s.step(1)
      case Key.up, Key.left: s.step(-1)
      case Key.escape: cancel(); return true
      case Key.returnKey, Key.keypadEnter: commit(); return true
      default:
        let char = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased()
        // Q quits, W closes the selected item, as in macOS's ⌘⇥; the session goes on without it.
        if char == "q" || char == "w", let item = s.selected {
          let quit = char == "q", window = windowItems?[item.id]
          later {
            if let window { quit ? self.model.quitApp(of: window) : self.model.closeWindow(window) }
            else { quit ? self.model.quitStage(item.id) : self.model.closeStage(item.id) }
          }
          s.remove(item.id)
          if s.visible.isEmpty { cancel(); return true }
          break
        }
        // A slot key, typed with the modifier held (so use the unmodified character): switch
        // straight to that stage.
        if let key = char, SlotKeys.isValid(key), let target = s.candidate(slot: key) {
          commit(to: target.id)
        }
        return true
      }
      session = s
      // Any further key shows the panel at once (and updates it).
      let items = windowItems
      later { self.panelShown = true; self.panel.show(s, windows: items) }
      return true
    }

    let modifier = ShortcutSettings.modifier
    let others: CGEventFlags = [.maskAlternate, .maskControl, .maskCommand]
    let held = flags.intersection(others)

    if held == .maskCommand, Key.windowChanging.contains(key) { later { self.model.pokePoller() } }

    if Key.isUnderEsc(key), held == modifier.flag {
      // The in-stage switcher: this stage's windows. Swallowed even with one window, so the
      // modifier's own ` shortcut (⌘`, which under Stage Manager swaps stages' windows) never fires.
      let (candidates, windows) = model.stageWindowCandidates()
      guard candidates.count > 1 else { return true }
      open(SwitcherSession(candidates: candidates), windows: windows)
      // Link this stage's windows to their AX windows now, so the switch is two AX calls.
      let ws = Array(windows.values)
      later { StageActivator.learn(ws, focused: nil) }
      return true
    }

    if key == Key.tab, held == modifier.flag {
      let candidates = model.switcherCandidates()
      guard candidates.count > 1 else { return false }
      open(SwitcherSession(candidates: candidates), windows: nil)
      later { self.model.prewarmSwitching(); self.model.pokePoller() }
      return true
    }

    if ShortcutSettings.arrowsEnabled, held == [.maskControl, .maskAlternate] {
      switch key {
      case Key.left, Key.up: later { self.model.step(-1) }; return true
      case Key.right, Key.down: later { self.model.step(1) }; return true
      default: break
      }
    }
    return false
  }

  /// Starts a session; the panel appears only if the modifier is still held after `panelDelay`.
  private func open(_ s: SwitcherSession, windows: [UUID: StageWindow]?) {
    session = s
    windowItems = windows
    panelShown = false
    panelGeneration += 1
    let generation = panelGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.panelDelay) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, let current = self.session, self.panelGeneration == generation, !self.panelShown else { return }
        self.panelShown = true
        self.panel.show(current, windows: self.windowItems)
      }
    }
  }

  private func swipe(_ event: CGEvent) {
    guard ShortcutSettings.swipesEnabled, let e = NSEvent(cgEvent: event) else { return }
    swipes.fingers = ShortcutSettings.swipeFingers
    let touches = e.allTouches().filter { $0.phase != .ended && $0.phase != .cancelled }
    let n = touches.count
    let x = n == 0 ? 0 : touches.map { Double($0.normalizedPosition.x) }.reduce(0, +) / Double(n)
    let y = n == 0 ? 0 : touches.map { Double($0.normalizedPosition.y) }.reduce(0, +) / Double(n)
    if let step = swipes.feed(fingers: n, x: x, y: y) { later { self.model.step(step) } }
  }

  private func commit(to id: UUID? = nil) {
    let target = id ?? session?.selected?.id
    let window = target.flatMap { windowItems?[$0] }
    let isWindows = windowItems != nil
    session = nil
    windowItems = nil
    panelGeneration += 1
    let wasShown = panelShown
    panelShown = false
    later {
      if let window { self.model.focusWindow(window) } else if !isWindows, let target { self.model.switchTo(target) }
      if wasShown { self.panel.hide() }
    }
  }

  /// Runs after the tap callback has returned: the callback must stay fast, or every keystroke
  /// on the system waits (and macOS disables slow taps).
  private func later(_ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
  }

  private func cancel() {
    session = nil
    windowItems = nil
    panelGeneration += 1
    panelShown = false
    later { self.panel.hide() }
  }
}
