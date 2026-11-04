# Stages

A macOS menu-bar app that gives Stage Manager stages a lasting identity: name, ink, slot, and
a switcher that moves between stages instead of apps. Read-only access to stages through public
CGWindowList / AX APIs; see `NOTES.md` for every Stage Manager behaviour this relies on.

## Layout

- `Sources/StageReader` contains the pure rules: `WindowCapture -> StageSnapshot`, plus the stability gate. All Stage-Manager-specific constants live here.
- `Sources/WindowSource` covers live CGWindowList capture and `StagePoller` (adaptive polling + activation notifications).
- `Sources/StageStore` holds stage records (name, ink, slot) matched to snapshots by window IDs, saved to `~/Library/Application Support/Stages/stages.json`.
- `App/` is the menu-bar app (`App/project.yml` → XcodeGen; sources in `App/Stages/`). Native AppKit/SwiftUI controls, with the design system's type, inks and rules.
- `Sources/stagesctl` is the debug CLI: record fixtures, read live or recorded captures, watch.
- `Tests/StageReaderTests` holds the reader tests; recorded fixtures are in `Fixtures/`.
- `tools/probe.swift` is the original standalone probe, kept as a debugging tool.

## Build and test

Always use the Xcode toolchain (`xcodebuild` / `xcrun`), never a bare `swift` from `PATH`.

```bash
make test      # package tests (xcodebuild, at the repo root)
```

```bash
make run       # generate the Xcode project, build Stages.app, (re)launch it
```

```bash
make install   # build, copy to ~/Applications/Stages.app and run it from there
```

Then turn on Settings… → General → Open at login.

The app needs its own Screen Recording grant (separate from your terminal's).

### Raycast (URL scheme)

Bind these as Raycast Quicklinks (e.g. Hyper+1…9). Errors beep and show in the popover.

| URL | Does |
|---|---|
| `stages://switch?slot=3` | switch to the stage in slot 3 |
| `stages://switch?name=Swifttap` | switch by name (exact, else a unique prefix) |
| `stages://switch?id=<uuid>` | switch by record ID (from `state.json`) |
| `stages://next`, `stages://previous` | step through the ring (slots, then age) |
| `stages://name?value=Lodestone` | name the current stage (empty value clears) |
| `stages://ink?value=teal` | ink the current stage (`none` clears): teal, ultramarine, oxide, violet, grass, sienna, chrome |
| `stages://slot?value=3` | give the current stage slot 3 (`none` clears) |
| `stages://wake?name=Reading` | wake a sleeping single-app stage (relaunch the app and its documents) |

`~/Library/Application Support/Stages/state.json` holds the current stages (names, inks, slots,
apps, window titles, document paths) plus named stages that aren't open, with their last titles
and documents. It's rewritten when anything changes and never leaves the Mac.

### Sleeping stages

A named stage whose windows have all closed stays in the popover under **Sleeping**, with its
apps and documents (AX document paths and page URLs; also in `state.json`). A single-app stage
can be woken: **Wake** relaunches the app and reopens its documents, and the stage gets its name
back. Multi-app stages can't be woken: Stage Manager would split them into one stage per app,
and the only way to regroup them is a pointer Shift-click, which Stages never fakes. Right-click
a sleeping stage to forget it.

### Activity log

`~/Library/Application Support/Stages/activity.jsonl` gets one line each time the centre stage
changes, or its windows, titles or documents do: `{ts, stageId, name, windows: [{bundleId, app,
title, documentPath}]}`. Append-only, local only: data for "used with this Assembly" in Lodestone.

### Signing

Builds are signed with a local self-signed identity, "Stages Local Signing" (no Apple account
involved; Developer ID comes later). That makes the designated requirement certificate-based,
so macOS keeps Stages' Screen Recording and Accessibility grants across rebuilds. On a new Mac:

```bash
sh tools/make-signing-identity.sh
```

The first build afterwards asks for keychain access for `codesign`: choose Always Allow.
`make app` prints the designated requirement; it should end in `certificate root = H"…"`. If
grants got confused by older ad-hoc builds, clear them once and grant again:

```bash
tccutil reset ScreenCapture dk.creativeoak.stages
```

The app logs one line per committed snapshot (counts only, no titles):

```bash
/usr/bin/log show --last 5m --predicate 'subsystem == "dk.creativeoak.stages"' --style compact
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
