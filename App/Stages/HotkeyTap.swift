import AppKit
import CoreGraphics
import os
import Switcher

/// Global keyboard shortcuts through a `CGEventTap` (needs Accessibility):
///   hold ⌥ (configurable) + ⇥  open the switcher on the previous stage; ⇥/⇧⇥ or ↑/↓ step;
///                              type to filter; release ⌥ to switch; Esc cancels; ↩ switches.
///   ⌃⌥ ←/↑ and →/↓            previous / next stage in the stable cycle.
/// Keys are swallowed only while the switcher is open or when a shortcut matches.
final class HotkeyTap {
  private let model: AppModel
  private let panel: SwitcherPanel
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var retry: Timer?
  private var session: SwitcherSession?
  private static let log = Logger(subsystem: "dk.creativeoak.stages", category: "hotkeys")

  private enum Key {
    static let tab: Int64 = 48, escape: Int64 = 53, returnKey: Int64 = 36, keypadEnter: Int64 = 76
    static let delete: Int64 = 51, left: Int64 = 123, right: Int64 = 124, down: Int64 = 125, up: Int64 = 126
  }

  init(model: AppModel, panel: SwitcherPanel) {
    self.model = model
    self.panel = panel
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
    let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
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
      case Key.down: s.step(1)
      case Key.up: s.step(-1)
      case Key.escape: cancel(); return true
      case Key.returnKey, Key.keypadEnter: commit(); return true
      case Key.delete: s.backspace()
      default:
        // Letters typed with the modifier held: use the unmodified character.
        guard let chars = NSEvent(cgEvent: event)?.charactersIgnoringModifiers,
              chars.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.punctuationCharacters).union(.whitespaces).contains($0) }),
              !chars.isEmpty else { return true }
        s.type(chars.lowercased())
      }
      session = s
      panel.show(s)
      return true
    }

    let modifier = ShortcutSettings.modifier
    let others: CGEventFlags = [.maskAlternate, .maskControl, .maskCommand]
    let held = flags.intersection(others)

    if key == Key.tab, held == modifier.flag {
      let candidates = model.candidates
      guard candidates.count > 1 else { return false }
      let s = SwitcherSession(candidates: candidates)
      session = s
      panel.show(s)
      model.pokePoller()
      return true
    }

    if ShortcutSettings.arrowsEnabled, held == [.maskControl, .maskAlternate] {
      switch key {
      case Key.left, Key.up: model.step(-1); return true
      case Key.right, Key.down: model.step(1); return true
      default: break
      }
    }
    return false
  }

  private func commit() {
    let target = session?.selected
    session = nil
    panel.hide()
    if let target { model.switchTo(target.id) }
  }

  private func cancel() {
    session = nil
    panel.hide()
  }
}
