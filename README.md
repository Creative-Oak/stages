# Stages

A macOS menu-bar app that gives Stage Manager stages a lasting identity: name, ink, slot, and
a switcher that moves between stages instead of apps. Read-only access to stages through public
CGWindowList / AX APIs; see `NOTES.md` for every Stage Manager behaviour this relies on.

## Layout

- `Sources/StageReader` contains the pure rules: `WindowCapture -> StageSnapshot`, plus the stability gate. All Stage-Manager-specific constants live here.
- `Sources/WindowSource` covers live CGWindowList capture and `StagePoller` (adaptive polling + activation notifications).
- `Sources/stagesctl` is the debug CLI: record fixtures, read live or recorded captures, watch.
- `Tests/StageReaderTests` holds the reader tests; recorded fixtures are in `Fixtures/`.
- `tools/probe.swift` is the original standalone probe, kept as a debugging tool.

## Build and test

Always use the Xcode toolchain (`xcodebuild` / `xcrun`), never a bare `swift` from `PATH`.

```bash
xcodebuild test -scheme Stages-Package -destination 'platform=macOS,arch=arm64'
```

```bash
xcrun swift run stagesctl read          # explain the current stages
xcrun swift run stagesctl watch         # print each committed snapshot + CPU use
xcrun swift run stagesctl record <name> --note "what I set up"
xcrun swift tools/probe.swift --ax      # original probe, plus WindowManager's AX tree
```

The terminal running these needs Screen Recording permission (window titles), and
Accessibility for `--ax`. `record` redacts app window titles by default (`--keep-titles` to keep
them), so fixtures can be committed without leaking what you were working on.
