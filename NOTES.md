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
| 3 | Overlay layer 0 = centre stage, layer 19 = strip thumbnail, **except during a stage switch, when every overlay and app-icon badge drops to layer 0**. So a layer-0 overlay wholly in the strip band (right edge ≤ display x + 290) is read as a thumbnail. | layers verified 2026-11 (probe); switch exception verified 2026-11-04 (`settings-centre` frame 4); fix confirmed live by Magnus (menu bar stays on System Settings) |
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
| 19 | During Stage Manager animations a strip thumbnail can be onscreen with no overlay under it, which the centre rule (#15) would take as a centre window. Windows lying wholly in the strip band (right edge ≤ display x + 290) are never centre windows, and the full frame of every overlay-less centre window is in the stability signature, so moving windows can't commit. | **inferred** 2026-11-04 from a record that absorbed ten apps after launching an app; guarded and unit-tested |
| 18 | ~~Pooled overflow windows with no history are grouped by app under "All at Once".~~ **Rejected 2026-11-04:** Magnus verified that windows of one app can live in different stages, so the guess was dropped. Overflow windows without history show one stage per window until seen in the strip. | verified 2026-11-04 (Magnus, M2 test step 5) |

## Stage identity (StageStore)

| Behaviour | Status |
|---|---|
| A stage only reaches overflow from the strip, and a new window first appears in the centre, so a stage's membership is always observable at some point while Stages runs. Overflow windows are regrouped from records whose membership was seen in the centre or strip (`membershipSeen`); records written before that field existed are not trusted for this. | reasoning (Magnus, 2026-11-03); "new windows appear in the centre" **assumed**: Apple's guide is silent on where a launched app or a ⌘N window goes |
| Apple's guide documents grouping only as dragging an app onto the centre group, and ungrouping as dragging it back to the strip. Shift-click grouping, strip capacity and overflow are undocumented. | read 2026-11-03 (support.apple.com mac-help "Use Stage Manager" and "Desktop & Dock settings", macOS 27) |
| Window IDs restart after a reboot and may collide with stored ones, so the store records the boot time (`kern.boottime`) and, on a new boot, drops stored window IDs and matches by fingerprint (apps + titles + AX documents). | verified 2026-11-04 after a reboot: "Claude" came back by fingerprint (score 100); Screen Recording and Accessibility grants survived; collision risk itself **assumed** |
| Launching an app, and opening a new window (⌘N in Mail), each create a new stage. | verified 2026-11-04 (Magnus, M2 test step 4) |
| Apps relaunched with a named stage get the name back (fingerprint). | verified 2026-11-04 (Magnus, M2 test step 3; log: `fingerprint: … score 100`) |
| Some state shows every window at once with no strip thumbnails matched: the reader then sees one centre stage holding everything ("1 read, 1 stages", repeatedly). Probably Mission Control / App Exposé or a drag in flight; **not yet identified**. 2026-11-04 09:41:00–09:41:20 it lasted 20 s (13–15 windows from 10–11 records), around Magnus opening System Settings; all ten snapshots were rejected and no record changed. One step in Stage Manager only adds a window or one stage to another, so the store ignores any snapshot with a visible stage spanning windows of 3+ active records, and shows the last good state. | episodes verified 2026-11-04 (app log 09:25–09:27); guard unit-tested |
| Fingerprint matches require identical app sets, as the brief says ("same bundle IDs + similar titles"); half overlap let a Finder + Mail stage take a Finder stage's name. | 2026-11-04 (Magnus, M2 test step 2) |
| A merge is inferred only where grouping is visible (centre or strip, never pooled overflow) and only for exactly two records: a drag adds one stage to another. Keeper: customised, else most recently in the centre (the drag target), else older. A record whose windows went to several stages is a split (largest part keeps it). Dormant records revive when their windows split off again. | 2026-11-04: Magnus's test showed the earlier rules merging five overflow records into one ("B") and keeping the dragged stage's name instead of the target's; fixed and unit-tested, live re-test **to do** |

## Permissions

| Behaviour | Status |
|---|---|
| Without Screen Recording, `kCGWindowName` is nil for other apps' windows, overlays included, so stages can't be read. The reader reports `noScreenRecording`. | verified 2026-11-03 (fixture `no-screen-recording`) |
| `GloballyEnabled` is readable from a non-sandboxed process via `CFPreferencesCopyAppValue`. | verified 2026-11-03 |
| An ad-hoc signed app's designated requirement is its cdhash (`cdhash H"2894…"`), so each rebuild is a different app to TCC. Signed with the local identity it is `identifier "dk.creativeoak.stages" and certificate root = H"6b8d…"`, unchanged across rebuilds. | requirement: verified 2026-11-03 (`codesign -d -r-` before/after two rebuilds). Grant surviving a rebuild: verified 2026-11-03 (rebuilt, relaunched, read 4 stages with no prompt) |

## Switching and gestures (M3)

| Behaviour | Status |
|---|---|
| Switching = make the stage's app frontmost (`AXFrontmost`) and `AXRaise` its most recent window, matched by title (frame breaks ties for centre windows; strip windows are scaled in CG but not in AX). Then wait up to 1.5 s for a committed snapshot with that stage in the centre; retry once; report. | verified 2026-11-04 (Magnus: ⌥⇥, ⌃⇥, ⌘⇥ and ⌃⌥ arrows work; log: every paced switch reached the centre on attempt 1). Rapid presses fought each other (old retries re-raising outdated targets); now only the newest switch retries, and arrow bursts raise once after 180 ms |
| Next/previous (⌃⌥ arrows) follow a fixed cycle (slots, then age). Stage Manager reorders the strip after each switch, so cycling by strip position would ping-pong. | design 2026-11-04 |
| Swipe spike: a listen-only `CGEventTap` (Accessibility) receives CG type 29 (gesture) events for all trackpad touches, and `NSEvent.allTouches()` on them gives finger count and normalized positions (public API). 3-finger left: x 0.74→0.39; right: 0.43→0.73; 4-finger up: y 0.35→0.66; 4-finger right: x 0.46→0.65. | verified 2026-11-04 (`stagesctl gestures`, Magnus's swipes) |
| The same swipes also produce CG type 30 events, the Dock's gesture events (Spaces, full-screen apps, Mission Control). AppKit can't convert them and their fields are undocumented; suppressing or parsing them would be SPI. So a Stages swipe and the system's swipe both fire unless the system gesture is turned off (Trackpad → More Gestures) or uses the other finger count. | verified 2026-11-04 |

| Swipes (opt-in, Settings): `SwipeDetector` steps once per horizontal swipe of the configured finger count (≥ 18 % of trackpad width, mostly horizontal); left = next. A swipe with more fingers than configured is ignored until all fingers lift. Tested on Magnus's recorded samples. | built 2026-11-04; **to verify live** |
| Stepping is unpredictable if the ring is recomputed per press: Stage Manager regroups while animating (with "All at Once", switching to one Finder stage briefly pulls the other Finder stage's windows into the centre, so two records split and merge on each switch), and the centre lags behind the target. A stepping session now freezes the ring at its first press and walks it from the last target; activations and intermediate snapshots don't move the target until 2.5 s after the last press. | observed 2026-11-04 (Magnus's screen recording + log 10:51:41–10:52:03: split/revive/merge of the Finder stages mid-walk); fix unit-tested, **to verify live** |
| Switcher latency work (2026-11-04): the tap callback now returns at once (switching ran AX calls inside it, holding up every keystroke); AX raise/frontmost run off the main thread; AX windows are looked up ahead of time (when the switcher opens and after each snapshot), so a switch is two AX calls; the panel appears only if the modifier is still held after 100 ms (a quick ⌘⇥ tap switches without a flash), is built at launch, and icons are cached. Remaining: Stage Manager's own ~0.7 s animation, which the native ⌘⇥ also pays when the target app is in another stage. Logged as `switch: raise took … ms` / `reached centre … after … ms`. | built 2026-11-04; **to measure live** |
| Overflow working as a switch target (raising a window of an overflow stage brings that whole stage forward). | verified 2026-11-04 (Magnus) |
| Stage Manager's animation (~0.7 s) dominates switch latency. WindowManager's binary contains an `animationSpeed=` log string, and one community source lists an `AnimationSpeed` key in `com.apple.WindowManager`, but no values or semantics are documented. Stages doesn't write it. | strings checked 2026-11-04 (macOS 27.2); key behaviour **unknown** |

## URL scheme and state (M4)

| Behaviour | Status |
|---|---|
| `open stages://…` reaches the running app (LaunchServices, `CFBundleURLTypes`), and `application(_:open:)` handles it; Stages deactivates afterwards so the frontmost app keeps focus. | routing verified 2026-11-04 (`open -g 'stages://switch?slot=9'` → "No stage has slot 9"); focus behaviour from Raycast **to verify** |
| `state.json` written on change: 11 stages, document paths present for windows whose AX document resolved. | verified 2026-11-04 |

## Activity log (M5)

| Behaviour | Status |
|---|---|
| `activity.jsonl` gets an entry on each committed change of the centre stage or of its windows/titles/documents (repeats skipped), and again when document paths resolve. | verified 2026-11-04 (first entry on launch) |
| Switch latency measured: Stages' part (key release → AX raise + frontmost) 12–63 ms, typically ~27 ms; stage confirmed in the centre ~970 ms after release (Stage Manager's animation plus two reads). | measured 2026-11-04 (Magnus's log) |

## Performance

- 2026-11-03, release build of `stagesctl watch`: 0.84 % of one core over the first 30 s (fast
  polling, then 1 s), 0.55 % over the next 30 s. Nearly all of it is `CGWindowListCopyWindowInfo`
  (~150 windows). Deep idle (2 s) starts after 60 s without changes.

## WindowManager's accessibility tree (M6 spike)

| Behaviour | Status |
|---|---|
| WindowManager (pid of `com.apple.WindowManager`) exposes `AXApplication` (actions `AXShowDesktop`, `AXHideDesktop`) → `AXGroup id=sm.space` → `AXList id=sm.strip` → one `AXButton` per visible strip tile, titled with the tile's front window title, with actions **`AXPress`** and **`AXAddToStage`**. Tile frames match the thumbnails' union (e.g. `[-268,166 252×157]`). Overflow stages have no tiles. | read 2026-11-04 (`probe.swift --ax`, `stagesctl tiles`); what the actions do: **to verify** (`stagesctl tile <n> press|add`) |
| First try (2026-11-04, strip auto-hidden, tiles at x −268): `AXAddToStage` on a tile and `AXPress` on another both returned success, but nothing changed on screen. Afterwards the strip no longer slid in on hover, even with Stages quit and an invisible full-screen `screencaptureui` overlay (left over from a screen recording) removed. Turning Stage Manager off and on fixed it. Cause unclear: the AX actions, or the overlay. | observed 2026-11-04 |
| Retest (strip working, no overlay): `AXAddToStage` and `AXPress` return success but do nothing, with the strip hidden (tiles at x −245) and with it shown (tiles at x 16). So WindowManager's tile actions can't group or switch from an outside AX client. Hover kept working, so the stuck strip earlier was most likely the `screencaptureui` overlay. | verified 2026-11-04 (Magnus) |
| Synthetic pointer: a single warp to the left edge doesn't reveal the auto-hidden strip; approaching it in steps with negative deltas and pushing against it for ~0.7 s does, after which a synthetic click on a tile works. **Decision (Magnus, 2026-11-04): Stages never moves the user's pointer**, so grouping (Shift-click on a tile) is not automated. Sleeping stages wake into separate stages, and the UI says so. | verified 2026-11-04 (`stagesctl tile <n> click`) |

## Open questions

- When exactly does Stage Manager create and drop centre overlays? (It doesn't matter for reading any more; see #15.)
- A grouped tile *in the visible strip, strip hidden* hasn't been recorded (`grouped.json` captured no group).
- A grouped stage of *several apps* that is already in overflow when Stages first launches can't be regrouped (no history, and the same-app hint doesn't apply): it shows as separate stages until it's seen in the strip.
- Where does a newly launched app go: its own stage, or the current centre stage? And a ⌘N window?
- Does raising a background window of an overflow stage bring the whole stage forward?
- `AppWindowGroupingBehavior` "All at Once" (0) vs "One at a Time" (1)?
- Stages across Spaces and a second display.
