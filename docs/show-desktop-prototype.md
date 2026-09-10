# Show Desktop: isolated verification build

Status: promoted into the normal Mac Tools app at the user's explicit request on
2026-09-10, accepting the Mission Control entry flash for now. The isolated test
bundle remains unchanged as a comparison build. The production module owns one
Dock observer and passes its presentation state to every note window. Settings
exposes the production app's separate Accessibility approval and connection status.

User verification on 2026-09-10: the isolated test keeps the note visible and
interactive during Show Desktop and eventually hides it in Mission Control.
Remaining regression: the note flashes during entry into Mission Control for
roughly a second before hiding. This is consistent with late AX event delivery,
but arrival timing versus the first animation frame has not been measured.
Do not treat this as a fully passing visual result. The user authorized shipping
the current behavior, not a speculative timing fix. Ad-hoc rebuilds change the signature requirement
and invalidate its existing Accessibility grant.

`xcrun swift scripts/trace-desktop-transition.swift` provides a bounded, read-only
trace of Dock window layers during user-triggered transitions. It does not capture
screens or read window titles. A layer appearing during a transition is only a
candidate heuristic, not proof of a reliable early Mission Control signal.

The user completed the requested Mission Control / Show Desktop sequence in a
60-second trace on 2026-09-10. Dock layer 18 appeared during both transitions, so
its presence alone cannot safely hide notes without also hiding them in Show
Desktop. No AX callback timestamps were captured alongside this trace; it does
not establish the exact notification delay. The observer delivers presentation
updates synchronously, without a debounce or dispatch delay (the two-second
maintenance loop only checks connection health). No timing fix has been verified.

## Mechanism

Keep the editable note at desktop-icon level + 1. Once the Dock observer has
received a real mode event, use stationary behavior to keep the note in place
during Show Desktop. Hide it using alpha and disable mouse/key eligibility during
Mission Control or App Exposé. Do not order out/recreate it or change its frame
when the mode changes; those actions risk losing individual-Space placement.

The observer uses public AX functions with undocumented `AXExposeShowDesktop`,
`AXExposeShowAllWindows`, `AXExposeShowFrontWindows`, and `AXExposeExit` names.
Their provenance is AltTab's implementation, reviewed at revision
`2f3c67739211f790b8f949f427ccb0575c8684a8`:

- [Dock observer](https://github.com/lwouis/alt-tab-macos/blob/2f3c67739211f790b8f949f427ccb0575c8684a8/src/events/DockEvents.swift)
- [Notification definitions](https://github.com/lwouis/alt-tab-macos/blob/2f3c67739211f790b8f949f427ccb0575c8684a8/src/macos/api-wrappers/ApplicationServices.HIServices.framework.swift)
- [Apple AXObserverCreate](https://developer.apple.com/documentation/applicationservices/1460133-axobservercreate)

This is an independently written minimal observer, not copied AltTab source.
The private notification contract may break with macOS updates. Accessibility
permission is required; the app never grants it automatically. No screen capture,
other-app text collection, shortcut interception, or Dock modification is used.
Only trust and Dock-process presence are checked every two seconds; overview
state changes are event-driven. Dock restart triggers re-registration. Permission
loss or registration failure restores the transient fallback. A failed subscription
does not repeatedly retry until the Dock PID changes or the user presses Recheck.

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
requested before all of these checks passed; the entry flash and initial-state
synchronization remain known limitations. Verify on the target Mac using actual
system entry points rather than synthetic policy events:

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
