# Stage Manager behaviour we rely on

Each entry is **verified** (with date and how) or **assumed**. All of it is encoded in
`Sources/StageReader/StageReader.swift`; when one of these changes, that's the file to fix.

Machine: MacBook, single 1470×956 display, macOS 27.2 (26B123), Xcode 27.2 (from 2026-11-03; earlier fixtures built with 26.3).
`com.apple.WindowManager`: `GloballyEnabled=1`, `AutoHide=1`, `AppWindowGroupingBehavior=0`.

## Reading stages

| # | Behaviour | Status |
|---|---|---|
| 1 | `WindowManager` creates one "Gesture Blocking Overlay" per app window in a stage (not per stage). | verified 2026-11 (Magnus's probe) |
| 2 | Strip overlays equal their window's bounds to the pixel. **Centre overlays are unreliable:** in 4 of the 6 Stage Manager-on recordings the centre windows had no overlay at all; when present they are layer 0, reported offscreen, and inset 1–5 pt (Calendar `[221,120 1028×749]` vs overlay `[222,121 1024×747]`). | strip: verified 2026-11-03 (all fixtures). Centre: verified 2026-11-03 (`strip-hidden`, `overflow` vs `centre-two-apps`, `mid-animation`) |
| 3 | Overlay layer 0 = centre stage, layer 19 = strip thumbnail. | verified 2026-11 (probe) |
| 4 | A grouped stage shows as overlapping, slightly offset thumbnails. Members fan out on both sides of the strip column: Ghostty `[9,471]` + Claude `[40,452]` with the column at x 16; three Finder windows `[-269,695]`, `[-253,701]`, `[-237,695]`. Group members overlap by ≥ 70 % of the smaller thumbnail, but **neighbouring tiles can touch by 1 pt** (Signal ends at y 667, Claude starts at 666; Mail's tile and a parked overflow thumbnail share x −269…−268), so tiles group only at ≥ 25 % overlap. (Overlapping *overflow* thumbnails are not groups; see #17.) | verified 2026-11-03 (`mid-animation`, `many-overlays`, `curious`) |
| 5 | "App Icon Window" (layer 19) is one badge per app per tile; 66×82, sits about 23 pt left of the tile, near its bottom. | count verified (probe); geometry verified 2026-11-03 (live capture) |
| 6 | Strip hidden ⇒ thumbnails at x −269 (on 1470 wide), reported `onscreen=true`. Shown ⇒ column at x 16, and tiles are larger (Mail 197×181 hidden, 253×159 shown). | verified 2026-11-03 (`strip-hidden`, `strip-visible`). The brief's probe saw `onscreen=false` once; the reader handles both |
| 7 | Overflow stages sit left of the strip column, offscreen, with their own overlays and icons. | verified 2026-11-03 (`overflow`, `mid-animation`, `many-overlays`) |
| 17 | **Overflow stages are pooled at one parking spot.** Every overflow thumbnail shares one anchor, whatever its size: right edge x −300 and vertical centre y 434.5 with the strip hidden (right edge −16 with it shown). All overflow icon badges sit at one point (`[-379,401]`). So overlap says nothing about grouping: the reader reports one pooled stage per overflow window, and StageStore regroups windows a record knew as one stage. | anchor verified 2026-11-03 (3 fixtures). Separate stages verified by Magnus via the Dock (Calendar alone, Mail alone). A grouped stage in overflow keeps its fan around the anchor (Finder ×3: right edges −300, −284, −268, all centred at y 434.5): verified 2026-11-03 (`curious`) |
| 8 | Overlay window IDs get reused; app window IDs are stable while the window lives. | verified 2026-11 (probe) |
| 9 | Mid-animation frames are noisy: the grouped tile grew 122→126 wide over ~300 ms, and the centre window was briefly 5 pt off its overlay. The two-read gate with overlay sizes in the signature committed only at frame 4 (first equal pair). | verified 2026-11-03 (`mid-animation`) |
| 10 | Other WindowManager windows to ignore: `Wallpaper`, `Event Shield Window`, untitled 1×1 at 1e9,1e9. | verified 2026-11 (probe, and 2026-11-03 capture) |
| 11 | Raising any window of a stage brings the whole stage to the centre, overflow stages included. | verified 2026-11 (probe) for Dock clicks; **open** for background windows of overflow stages |
| 12 | Placeholder windows (untitled 64×64 / 500×500 at `[0,456]`) are offscreen and have no overlay. | verified 2026-11-03 (live capture) |
| 13 | Strip column = the rightmost left edge among tile clusters; anything > 24 pt left of it is overflow. In-column tiles that are offscreen while others are onscreen are also overflow. | verified 2026-11-03 for the 24 pt rule (overflow is ~285 pt left; groups stick out ≤ 7 pt). The onscreen rule is **assumed** (never triggered in recordings) |
| 15 | **Centre rule (deviates from the brief):** centre = windows matched to a layer-0 overlay **plus onscreen candidates with no overlay**. In every recorded frame, onscreen layer-0 app windows were exactly the strip thumbnails (all matched) plus the centre windows; placeholders (`[0,456]` 64×64 / 500×500) were always offscreen. Listed in `Diagnostics.centreWithoutOverlay`. | verified 2026-11-03 (all fixtures, 21 frames) |
| 16 | Leftover overlays that match nothing are routine and offscreen (e.g. `[381,221 1454×865]` layer 0, `[-248,684 205×91]` layer 19, a duplicate of Mail's overlay). Only *onscreen* unmatched overlays lower confidence. | verified 2026-11-03 |
| 14 | When the strip hides, tiles slide off the left edge of *their own* display. A tile outside every display belongs to the display whose vertical span holds it and whose left edge is nearest. | **assumed**. Breaks if a second display sits to the left of the main one (hidden tiles at x −269 would land inside it). Needs a two-display fixture |

## Permissions

| Behaviour | Status |
|---|---|
| Without Screen Recording, `kCGWindowName` is nil for other apps' windows, overlays included, so stages can't be read. The reader reports `noScreenRecording`. | verified 2026-11-03 (fixture `no-screen-recording`) |
| `GloballyEnabled` is readable from a non-sandboxed process via `CFPreferencesCopyAppValue`. | verified 2026-11-03 |
| An ad-hoc signed app's designated requirement is its cdhash (`cdhash H"2894…"`), so each rebuild is a different app to TCC. Signed with the local identity it is `identifier "dk.creativeoak.stages" and certificate root = H"6b8d…"`, unchanged across rebuilds. | requirement: verified 2026-11-03 (`codesign -d -r-` before/after two rebuilds). Grant surviving a rebuild: verified 2026-11-03 (rebuilt, relaunched, read 4 stages with no prompt) |

## Performance

- 2026-11-03, release build of `stagesctl watch`: 0.84 % of one core over the first 30 s (fast
  polling, then 1 s), 0.55 % over the next 30 s. Nearly all of it is `CGWindowListCopyWindowInfo`
  (~150 windows). Deep idle (2 s) starts after 60 s without changes.

## Open questions

- When exactly does Stage Manager create and drop centre overlays? (It doesn't matter for reading any more; see #15.)
- A grouped tile *in the visible strip, strip hidden* hasn't been recorded (`grouped.json` captured no group).
- A grouped stage that is already in overflow when Stages first launches can't be regrouped (no history): it shows as separate stages until it's seen in the strip.
- Does raising a background window of an overflow stage bring the whole stage forward?
- `AppWindowGroupingBehavior` "All at Once" (0) vs "One at a Time" (1)?
- Stages across Spaces and a second display.
- Does WindowManager's AX tree expose strip tiles (e.g. `AXPress`)? `--ax` not yet run: Ghostty needs Accessibility.
