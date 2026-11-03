# Stage Manager behaviour we rely on

Each entry is **verified** (with date and how) or **assumed**. All of it is encoded in
`Sources/StageReader/StageReader.swift`; when one of these changes, that's the file to fix.

Machine: MacBook, single 1470×956 display, macOS 27.2 (26B123), Xcode 26.3 / SDK 26.2.
`com.apple.WindowManager`: `GloballyEnabled=1`, `AutoHide=1`, `AppWindowGroupingBehavior=0`.

## Reading stages

| # | Behaviour | Status |
|---|---|---|
| 1 | `WindowManager` creates one "Gesture Blocking Overlay" per app window in a stage (not per stage). | verified 2026-11 (Magnus's probe) |
| 2 | Overlay bounds equal the window's bounds to the pixel once settled; strip windows are reported at thumbnail size. | verified 2026-11 (probe) for strip tiles. **Open:** on 2026-11-03 the centre window (Claude #251 `[8,41 1454×907]`) had no overlay within ±4 pt. Nearest was an *offscreen* layer-0 WindowManager window `[7,39 1445×907]`. Not yet known whether the centre overlay goes stale or is missing. |
| 3 | Overlay layer 0 = centre stage, layer 19 = strip thumbnail. | verified 2026-11 (probe) |
| 4 | A grouped stage shows as overlapping, slightly offset thumbnails (e.g. `[-237,147 95×155]` + `[-269,166 96×153]`). Grouped tiles fan out to the *right* of the strip column. | overlap verified 2026-11 (probe); fan-out direction **assumed** |
| 5 | "App Icon Window" (layer 19) is one badge per app per tile; 66×82, sits about 23 pt left of the tile, near its bottom. | count verified (probe); geometry verified 2026-11-03 (live capture) |
| 6 | Strip hidden ⇒ thumbnails at x ≈ −269 (on 1470 wide). They may be reported `onscreen=false`. | verified 2026-11 (probe). On 2026-11-03 hidden tiles were reported `onscreen=true` |
| 7 | Overflow stages sit further left, offscreen, with their own overlay and icon. | verified. Observed at x −479 (probe) and x −553 (2026-11-03, Mail, 253 wide). The position varies, so we classify by distance from the strip column, not by a fixed x |
| 8 | Overlay window IDs get reused; app window IDs are stable while the window lives. | verified 2026-11 (probe) |
| 9 | Mid-animation frames are noisy (in-between overlay sizes, placeholders under overlays). | verified 2026-11 (probe); the 2-read gate with overlay sizes in the signature is designed against it but **not yet tested on a recorded animation** |
| 10 | Other WindowManager windows to ignore: `Wallpaper`, `Event Shield Window`, untitled 1×1 at 1e9,1e9. | verified 2026-11 (probe, and 2026-11-03 capture) |
| 11 | Raising any window of a stage brings the whole stage to the centre, overflow stages included. | verified 2026-11 (probe) for Dock clicks; **open** for background windows of overflow stages |
| 12 | Placeholder windows (untitled 64×64 / 500×500 at `[0,456]`) are offscreen and have no overlay. | verified 2026-11-03 (live capture) |
| 13 | Strip column = the rightmost left edge among tile clusters; anything > 24 pt left of it is overflow. In-column tiles that are offscreen while others are onscreen are also overflow. | **assumed** (derived from the numbers above) |
| 14 | When the strip hides, tiles slide off the left edge of *their own* display. A tile outside every display belongs to the display whose vertical span holds it and whose left edge is nearest. | **assumed**. Breaks if a second display sits to the left of the main one (hidden tiles at x −269 would land inside it). Needs a two-display fixture |

## Permissions

| Behaviour | Status |
|---|---|
| Without Screen Recording, `kCGWindowName` is nil for other apps' windows, overlays included, so stages can't be read. The reader reports `noScreenRecording`. | verified 2026-11-03 (fixture `no-screen-recording`) |
| `GloballyEnabled` is readable from a non-sandboxed process via `CFPreferencesCopyAppValue`. | verified 2026-11-03 |

## Performance

- 2026-11-03, release build of `stagesctl watch`: 0.84 % of one core over the first 30 s (fast
  polling, then 1 s), 0.55 % over the next 30 s. Nearly all of it is `CGWindowListCopyWindowInfo`
  (~150 windows). Deep idle (2 s) starts after 60 s without changes.

## Open questions

- Is the centre stage's overlay reliably present and matched (see #2)?
- Does raising a background window of an overflow stage bring the whole stage forward?
- `AppWindowGroupingBehavior` "All at Once" (0) vs "One at a Time" (1)?
- Stages across Spaces and a second display.
- Does WindowManager's AX tree expose strip tiles (e.g. `AXPress`)? Run `xcrun swift tools/probe.swift --ax`.
