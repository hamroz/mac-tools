# Show Desktop: isolated verification build

Status: promoted into the normal Mac Tools app at the user's explicit request on
2026-09-10. The isolated test bundle remains unchanged as a comparison build; it
still shows the Mission Control entry flash. The production module owns one fast
Dock-window probe and, optionally, one AX Dock observer. The probe alone drives
pinning and Mission Control hiding, so Accessibility is no longer required;
Settings exposes the observer as an optional fallback.

The entry flash was fixed in the production app after a live trace captured the
Dock's window signature: Mission Control and App Exposé create a full-screen
layer-18 window together with a new full-screen layer-20 window, while Show
Desktop creates the layer-18 window alone. The 30 Hz probe hides notes as soon as
the pair appears, on the first animation frame. A later run showed the note at
alpha 0 about 30 ms after the pair appeared and restored to alpha 1 when the pair
disappeared. The undocumented AX notifications remain an optional fallback hide
path.

`xcrun swift scripts/trace-desktop-transition.swift` provides a bounded, read-only
trace of Dock window layers during user-triggered transitions. It does not capture
screens or read window titles. Its layer-only output was later supplemented by a
trace that recorded window numbers, bounds and alpha for Dock-owned windows and
for Mac Tools note windows. On 2026-09-10 the user triggered the transitions and
the extended trace showed: Show Desktop creates a layer-18 window alone and the
note stays at alpha 1; Mission Control and App Exposé create layer 18 plus a new
full-screen layer 20 and the note hides 200–400 ms later, after the AX event.
Layer 18 alone is therefore not a safe signal, but the pair is. A separate
extended trace over a Space switch showed wallpaper and desktop-level windows
moving with no layer-18/20 pair, so space changes do not hide notes.

The observer delivers presentation updates synchronously, without a debounce or
dispatch delay (the two-second maintenance loop only checks connection health).
The probe polls on the main actor, at 30 Hz while pinning is active and 4 Hz
otherwise, and only reads window ownership, layer, bounds and number. No timing
fix is speculative anymore; the pair detection was verified against the live
trace.

## Mechanism

Keep the editable note at desktop-icon level + 1. As soon as the window probe has
read the Dock once, use stationary behavior to keep the note in place during Show
Desktop. Hide it using alpha and disable mouse/key eligibility during Mission
Control or App Exposé. Do not order out/recreate it or change its frame when the
mode changes; those actions risk losing individual-Space placement.

The production app adds `DockOverviewOverlayProbe`, a main-actor task that polls
Dock-owned on-screen windows while notes are pinned. It records window numbers
for full-screen windows at layer 18 and layer 20. A layer-18 window appearing
together with a new full-screen layer-20 window within 165 ms means Mission
Control or App Exposé, and the probe sets `overlayHidesNotes` on
`DesktopPresentation` immediately. The flag clears when every layer-18 window is
gone. A layer-18 window alone (Show Desktop) never hides notes, and small helper
windows such as the Dock bar are ignored by a 90% screen-coverage threshold.
Polling runs at 30 Hz while notes are pinned and at 4 Hz otherwise. If the Dock
restarts, the probe re-baselines without treating existing windows as a
transition. When the probe sees the overlay end it also clears any stale
fallback-hide state, so a lost Dock notification cannot leave notes invisible.

The observer uses public AX functions with undocumented `AXExposeShowDesktop`,
`AXExposeShowAllWindows`, `AXExposeShowFrontWindows`, and `AXExposeExit` names.
Their provenance is AltTab's implementation, reviewed at revision
`2f3c67739211f790b8f949f427ccb0575c8684a8`:

- [Dock observer](https://github.com/lwouis/alt-tab-macos/blob/2f3c67739211f790b8f949f427ccb0575c8684a8/src/events/DockEvents.swift)
- [Notification definitions](https://github.com/lwouis/alt-tab-macos/blob/2f3c67739211f790b8f949f427ccb0575c8684a8/src/macos/api-wrappers/ApplicationServices.HIServices.framework.swift)
- [Apple AXObserverCreate](https://developer.apple.com/documentation/applicationservices/1460133-axobservercreate)

This is an independently written minimal observer, not copied AltTab source.
The private notification contract may break with macOS updates, so the observer is
optional: the app never grants Accessibility automatically, and the probe keeps
working when the observer is unavailable. No screen capture, other-app text
collection, shortcut interception, or Dock modification is used. Only trust and
Dock-process presence are checked every two seconds; overview state changes are
event-driven. Dock restart triggers re-registration. Permission loss or
registration failure leaves the probe in charge. A failed subscription does not
repeatedly retry until the Dock PID changes or the user presses Recheck.

## Run

Run `zsh scripts/build-desktop-probe.sh`, then open
`.build/probe/Mac Tools Desktop Test.app`.

This has a separate bundle ID, no note repository, no global shortcut, and no
launch-at-login registration. It creates a single temporary TEST NOTE, discarded
on quit. It does not replace `.build/app/Mac Tools.app`.

The Enable Accessibility button requests approval. The user must allow **Mac Tools
Desktop Test** in System Settings → Privacy & Security → Accessibility. This is a
broad macOS permission even though this prototype only observes Dock events.

Initial state is deliberately unknown: the observer has no documented state query.
After connecting, enter and exit Show Desktop once to synchronize, then test again.
The first cycle is not proof of pinning. Relaunch or Dock restart requires another
synchronization cycle. This is a prototype limitation to resolve before release.

## Acceptance gate

The original complete acceptance gate remains below. Promotion was explicitly
requested before all of these checks passed. The entry flash and pinning are
addressed by the window-pair probe, without Accessibility; cancellation edge
cases and full-screen Spaces still need manual checks. Verify on the target Mac
using actual system entry points rather than synthetic policy events:

- Command–F3 and the configured hot corner keep the TEST NOTE fully in place.
- Hover controls, direct text entry, selection, dragging, and resizing work while
  Show Desktop is active and after exit.
- Mission Control and App Exposé hide the note; exiting restores it without
  activating Mac Tools or stealing keyboard focus.
- Both all-workspace and individual-workspace modes preserve their intended placement.
- Rapid/canceled gestures, mode-to-mode transitions, full-screen spaces, and
  observer/permission failure do not leave the note permanently hidden or key.
- Relaunch and Dock restart handle unknown state honestly.

Tests exercise deterministic state policy and native window properties only.
They cannot establish that these private events arrive on this macOS version,
that their timing avoids animation artifacts, or that Finder delivers real input.
