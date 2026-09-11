# Menu Bar Organizer: implementation and verification

Target: macOS 14+, Swift 6; development Mac: macOS 26.6.2, Xcode 26.6.

## Failures in the original implementation

- Setting another application's AXPosition is not a supported NSStatusItem hiding API. AX errors were incorrectly counted as success.
- The installed app and development bundle had different ad-hoc designated requirements, each tied to a different executable hash. The installed copy remained the original implementation.
- The replacement divider had been saved at preferred position 491 and the arrow at 677. AppKit measures these offsets from the right, so the divider was to the right of its access button. Collapsing was consequently refused.
- A dropdown of application names did not implement the requested horizontal icon tray.
- Simulated position tests did not prove WindowServer accepted a real menu bar move.

## Current design

The organizer owns two persistent NSStatusItems: an access chevron and a divider. At launch it repairs reversed saved positions before inserting either item. If the user subsequently moves them out of order, the controller repairs their actual order before arranging other items. Hidden items are grouped left of the divider; visible items are on its right. Expanding the divider's allocated width pushes only the left group into menu bar overflow. Removing the divider restores access without requiring Accessibility.

AX discovery provides app identity and labels. On macOS 26, Control Center owns the status windows, and some source apps report stale proxy geometry. System-wide Accessibility hit testing of visible status windows resolves their source app, including hits on glyph descendants. Current WindowServer bounds are then retained by window ID while hidden. Same-process geometry matching is reserved for directly owned windows; an unrelated nearby icon is never used as a substitute. Window identity survives an AX omission but is discarded when the source process or window exits. Preferences remain saved for apps without a current hosted icon, and those apps do not create dead tray buttons. Items are moved with short-lived, tagged CoreGraphics event delivery to the owning process and session. The controller checks actual relative positions before committing Hide/Show.

Left-clicking the chevron opens an AppKit panel below the menu bar, containing a horizontal row of hidden icons. Clicking an icon temporarily moves only that item into the visible region and clicks its native status button, keeping the other items collapsed. The item returns after the reveal timeout, delayed while an elevated menu/popover from its process is open. Click delivery aligns the physical cursor with the target briefly, then restores it. Right-clicking the chevron provides arrangement and recovery commands. Escape and outside clicks dismiss the tray, removing its event monitors.

ScreenCaptureKit snapshots only the identified status-item windows to obtain their actual glyphs. This requires Screen Recording approval. Capture starts only after the explicit permission button has been used or macOS already reports approval. Images are transient memory only; no desktop capture, audio capture, recording file, or network service is used. App icons serve as the fallback without approval.

## Signing and permissions

`scripts/sign-app.sh` creates a local self-signed code-signing identity in the user's login Keychain on first use. Subsequent builds reuse it. The designated requirement pins both the bundle identifier and self-signed certificate anchor fingerprint. It deliberately does not use an identifier-only ad-hoc requirement. No root certificate trust, keychain-wide ACL, global partition list, or system security setting is changed. Temporary PKCS#12/private-key files are removed after import. `MAC_TOOLS_SIGNING_IDENTITY` can select an existing developer identity instead.

Switching from an old ad-hoc app to this identity requires one fresh Accessibility approval for the installed app. Thereafter app updates signed by this certificate satisfy the same requirement. The app checks trust silently on launch, polling, and enablement. Only an explicit permission button prompts. This prevents repeated requests from the app; macOS remains the authority for permission grants and revocation.

Use the installed `/Applications/Mac Tools.app` consistently. Keep the Keychain identity when cleaning build artifacts. Do not delete and recreate that identity for each build.

## API evidence and compatibility

- Apple [NSStatusItem.length](https://developer.apple.com/documentation/appkit/nsstatusitem/length) documents allocating space for our status item. Using overflow as a hidden section is a macOS behavior, not a public API to hide another app's icon.
- Apple [AXUIElementSetAttributeValue](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue) defines failure as failure. No error is promoted to success.
- Apple [TN2206](https://developer.apple.com/library/archive/technotes/tn2206/) explains identity continuity through designated requirements and self-signed identities.
- Apple [SCContentFilter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(desktopindependentwindow:)) and [SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager) provide individual-window capture on the supported OS.
- Ice, revision `11edd39115f3f43a83ae114b5348df6a0e1741cf`, GPL-3.0, macOS 14+: studied as evidence for divider overflow and window-targeted event routing. Mac Tools' implementation is independent. The window-number CGEvent field `0x33` is undocumented; it is isolated in `MenuBarEventDriver.swift`. The CGEvent tap creation/post functions are public. These mechanics require real testing after macOS updates.

- Thaw revision `d5eab80b4e1f62328a8b130994220e49524a48d1`, GPL-3.0: studied source/host PID separation and hosted click routing on macOS 26. No implementation was copied. Mac Tools uses public `AXUIElementCopyElementAtPosition` for source identification. The optional string attribute `AXFrame` is undocumented and falls back to public position/size reads.

## Acceptance checks

Automated tests cover saved position reversal, identity/persistence, hide/show commitment after successful movement, refusal/failure, disable, cancellation, permission prompting policy, single-item temporary reveal, app relaunch, fixed system items, and existing Desktop Stickies behavior.

Release verification must also observe the actual installed signed app: hide several third-party icons, verify they disappear, open the tray, click one, inspect its native menu, restore it, reorder, disable/re-enable, and quit/relaunch repeatedly without a new Accessibility request. Check the actual glyphs after Screen Recording approval. Test overflow/notch, display changes, and another menu bar manager separately. Unit tests do not establish those behaviors.

Live testing was explicitly approved, including the installed build, a one-time refresh of its stale Accessibility entry, and icon capture. Rebuilt bundles retain the same certificate-pinned identity. The completed live checks are recorded below.


## Observed on the development Mac — 2026-09-11

- The installed `/Applications/Mac Tools.app` retained effective Accessibility and Screen Recording access through repeated signed rebuilds and quit/relaunch cycles. No further privacy prompt appeared after refreshing the old ad-hoc Accessibility entry once.
- Docker, ChatGPT, Passwords, CopyClip, and Wooting were present as real Control Center hosted status windows. With the divider expanded, their window bounds moved to negative x coordinates, outside the display. The chosen visible icons remained on-screen.
- The tray displayed all five original glyphs in one horizontal row after relaunch. Escape and the settings gear dismissed it. Ollama and Cursor exposed source-app proxies but had no hosted status window, so their preferences remain saved without showing unusable tray buttons.
- Clicking Wooting in the tray brought only that icon on-screen and created Wooting's own native menu: owner PID 1601, window 104762, level 101, frame `(1266, 40, 216, 154)`. The other four windows stayed off-screen. After the menu closed and the reveal timer elapsed, Wooting returned between its original neighbors.
- Show Wooting changed the count to four hidden and left its host window on-screen at x=1281 while the other four remained off-screen. Hide returned it to the hidden group.
- The settings arrow buttons successfully reordered both hidden and visible icons. The final hidden order was restored to Docker, ChatGPT, Passwords, CopyClip, Wooting; visible input source, AirDrop, and Bluetooth were restored to their initial relative order.
- Disabling removed the divider and returned all five hosted app icons on-screen (x=1127 through x=1281 in the captured layout). Existing note content remained present throughout the relaunch checks.
- Re-enabling restored the five-icon tray. A final normal quit/relaunch of the installed bundle preserved all five entries, their order, original glyphs, and effective permissions without a prompt.
- Final automated suite: 56 tests passed; release compilation and strict signature verification passed. The tests cover cancellation, failure without committing a false selection, permission revocation, recreated windows in the same process, temporary-reveal order restoration, and existing notes functionality.

Unverified separately: attaching/removing displays, full-screen/Space transitions, and simultaneous operation with Bartender or another organizer. The undocumented event field and menu bar overflow behavior remain compatibility boundaries after macOS updates.

## Follow-up: flashing hidden icons and removed controls

Routine Hide/Show, reordering, and reconciliation of a newly created status window previously expanded the divider first. This briefly exposed every hidden icon. These operations now retain the collapsed divider and move only the necessary icons. Explicit Reveal All and Arrange still expand it. A new window does not prematurely return an icon whose native menu is being used, and movement failure leaves unrelated hidden icons collapsed.

macOS Remove disables the icon itself; it is distinct from placing a live icon in Mac Tools' hidden section. The organizer now persists an icon catalog alongside its existing Hide/Show choices. Missing or Removed lists absent icons after removal, source-app exit, and relaunch. Sound, Now Playing, and AirDrop are offered even if they were removed before this version. Restore uses existing Accessibility access to operate the matching Menu Bar setting, verifies it became enabled, and waits for an actual status window before reporting restoration. Sound and Now Playing are set to Always Show. No global Control Center reset or private preference mutation is used.

Third-party allow switches can expose string-valued states and linked labels. Recovery reads those representations and verifies the enabled state. If macOS recreates an app's icon directly in overflow, recovery observes the newly created windows, requires a unique unidentified candidate, and briefly moves only that candidate into view for an actual AX owner hit. A stale source proxy is matched only with direct owner evidence and a single source item. The verified window is returned beside its original neighbor, retaining the hidden group and the app's saved selection. Ambiguous candidates are not assigned to an app. Restore may refresh that app's allow switch to recreate a stale host window.

Apple's [Menu Bar settings guide](https://support.apple.com/guide/mac-help/change-menu-bar-settings-mchlad96d366/mac) describes the system controls and app allow switches. On this Mac, live inspection confirmed that removed Sound and Now Playing controls had unchecked `controlcenter-sound-id` / `controlcenter-nowPlaying-id` settings. The installed ControlCenterSettings extension identifies the settings deep link. The recovery integration is verified on macOS 26 with English settings; other versions or languages can require completing the change in the opened settings pane. An app's own icon preference may also need to be enabled in that app; an OS allow switch cannot override that preference. Recovery keeps these items listed and provides the next step instead of inventing an icon.

Follow-up verification on 2026-09-11:

- 64 automated tests passed, including no intermediate group expansion during Show/Hide/reorder, a new Now Playing window while another item is temporarily visible, movement failure, catalog persistence, restored Hidden selection, recovery feedback surviving refresh, and refusing ambiguous overflow recovery candidates.
- The installed signed app restored Sound and Now Playing from unchecked macOS settings. Both settings became checked with Always Show, and actual status windows appeared in the organizer.
- Now Playing moved from visible to hidden and back. The other eight hidden windows remained at negative x coordinates. Diagnostics recorded zero group reveal transitions during this launch.
- Reordering Wooting left within the collapsed hidden section worked; moving it right restored its original position.
- Sound was hidden, disabled in macOS, and still listed under Missing or Removed after a normal quit/relaunch. Restore returned the real icon to its saved Hidden section. Opening it from the tray displayed the native Sound volume slider and output-device controls; it returned to the hidden section after dismissal and timeout. The group reveal counter remained zero.
- Repeated signed follow-up updates and normal relaunches retained effective Accessibility and icon-capture access without another privacy prompt. Existing notes remained intact.
- Final third-party check: disabling Wooting's Allow in the Menu Bar switch removed its tray entry while retaining Restore. Restore re-enabled that exact switch, verified recreated window 107076 against source PID 1601, and returned it to its original hidden position between CopyClip and the input source. The other hidden icons stayed off-screen and the group reveal counter remained zero. Sound and Now Playing were left available in the main menu bar; the original eight hidden selections were retained.
