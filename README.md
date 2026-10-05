# Mac Tools

Mac Tools is a private, local-first macOS menu-bar utility designed to grow into a collection of small desktop tools. Each tool can be switched on or off from **Mac Tools Settings**. The tools are **Desktop Stickies**, **AI Usage**, **Text Assistant**, and **Shortcuts**; more will follow.

## Desktop Stickies

- Creates editable notes from the menu bar or with `Control–Option–N`.
- Keeps notes at the desktop window level, behind normal application windows.
- Restores note text, color, size, position, and display across launches.
- Includes five adaptive colors and follows the macOS light/dark appearance.
- New notes default to graphite. Drag the top strip to reposition a note; the area below it is for editing text. The grip, color menu, and close button appear only while hovering that note. Only the bottom-right resize indicator stays visible when the pointer leaves. All palettes use a solid rounded surface without a contrasting border.
- Moves closed notes to Recently Deleted; expired notes are removed at launch, hourly while running, and when opening the manager.
- Stores data only in `~/Library/Application Support/Mac Tools/notes.json`.

## AI Usage

- Adds its own gauge icon to the menu bar. Click it to see how much of your **Claude** and **Codex** limits is left: each window (5-hour session, weekly, per-model weekly) with a bar, the percentage left, and when it resets. Plan and extra usage or credits appear when the service reports them.
- Refreshes every 5 minutes (configurable), when the popup opens, and after wake. If a refresh fails, the last good numbers stay visible with a warning.
- **Settings → AI Usage**: show or hide the menu bar icon (on by default), optionally show the lowest percentage left next to it, choose which services to show, and set the refresh interval. With the icon hidden, the same summary is in the Mac Tools menu.
- **Claude** reads Claude Code's sign-in from the Keychain (`Claude Code-credentials`) and asks Anthropic for the numbers `/usage` shows; Claude apps and Claude Code share these limits. That sign-in belongs to the Terminal `claude` command and is renewed only when it runs; the desktop app keeps its own.
- **Codex** reads `~/.codex/auth.json` and asks OpenAI for the numbers `/status` shows. If that fails, it shows the limits Codex last recorded in `~/.codex/sessions`.
- Sign-ins are only read, never stored or changed, and are sent only to the service they belong to. These usage endpoints are not public APIs and may change.

## Text Assistant

- Improves, translates, or rewrites the text you've selected in any app (Slack, Telegram, Notes, browsers…) and pastes the result over the selection.
- **The popup**: **Open Text Assistant…** in the Mac Tools menu (or your own shortcut) opens a panel next to the pointer with every mode and tone. Pick with ↑↓, switch lists with ←→ or Tab, or press a number or the first letter; Return runs, Esc or a click elsewhere cancels. The selection is read before the panel takes the keyboard, and the app you're editing stays frontmost, so the result is pasted back in place. The mode starts on the last one used and the tone on My style; both are adjustable in Settings. OpenCode starts while you choose, so the run doesn't wait for it.
- **Quick actions** are mode + tone pairs in the Mac Tools menu: by default **Improve · My style**, **Translate · My style**, **Fix Grammar · Original tone**, and **Shorten · My style**. Add, change, or remove them in **Settings → Text Assistant → Quick Actions**, where each can get its own shortcut. No shortcut is set by default. The popup and the quick actions can each be switched off. A small bubble next to the pointer shows progress and errors.
- **Modes** say what to do (Improve, Fix Grammar, Translate, Shorten); **tones** say how it should sound (My style, Original tone, Formal, Professional, Casual, Friendly, Funny). Any mode works with any tone. Translate detects the language: Russian becomes English, English becomes Russian, anything else English; a fixed target can be set per mode.
- Modes, tones, and the prompts live in `~/Library/Application Support/Mac Tools/Text Assistant/config.json`, created with these defaults on first run and reloaded as soon as you save it. Add your own modes (for example "Reply" or "Explain simply") and tones there; a mode can also choose its own model. If the file has a mistake, Settings shows it and the last working version stays in use; **Restore Default Modes and Tones** keeps the old file as a backup.
- **My style** uses `my-style.md` in the same folder: a short style guide (rules plus a few before/after examples) or samples of your own writing, in English and Russian. The model follows its rules and matches your vocabulary, capitalization, punctuation, and formality, without copying the examples' content or adding details. Everything in it is sent with each My style request, so a short guide keeps runs cheap: a ~2,300-character guide adds about 800 tokens, roughly $0.0008 per run with Claude Haiku 4.5. Without it, My style keeps the voice of the text itself.
- **Output**: **Replace** (default) pastes the result over the selection right away. **Preview first** streams the result into a panel next to the pointer: Return replaces the selection, ⌘C copies the result, Esc or a click elsewhere cancels. In Replace mode, a selection that can't be edited (text on a web page) opens in the preview with Copy, instead of a paste that would do nothing.
- The selection is read through Accessibility when the app exposes it, otherwise by sending ⌘C. The result is pasted with ⌘V. Your clipboard, with every format on it, is put back afterwards, including after errors and cancellations. Pressing the shortcut again while a request is running cancels it and starts over.
- If the result can't be pasted (you switched apps meanwhile), it stays on the clipboard and the bubble says so. **Copy Last Result** in the menu brings back the most recent result; it is kept in memory only.
- **Models come from OpenCode by default**, using the providers you already signed in to with [OpenCode](https://opencode.ai) (OpenCode Zen, OpenRouter, Anthropic, GitHub Copilot, DeepSeek…), so there is no extra API key. **Sign In…** opens Terminal with `opencode auth login` to add a provider; the refresh button picks it up. Choose the model from a searchable list grouped by provider, with prices and free models marked; Automatic picks a fast, inexpensive model you are signed in to (Claude Haiku 4.5 when available).
- Text Assistant runs its own `opencode serve` on 127.0.0.1, behind a password made fresh for each launch, with a minimal agent that has no tools and none of OpenCode's coding prompt. It starts on first use (about a second), stops after 10 idle minutes and when Mac Tools quits, and keeps its throwaway sessions in its own database (`~/Library/Application Support/Mac Tools/Text Assistant/OpenCode/`), out of your OpenCode history.
- **Claude Code** (optional, off unless chosen): runs `claude -p` with your Claude Code sign-in and plan, without tools, MCP servers, or saved sessions, in an empty folder; Haiku, Sonnet, or Opus. The prompt goes through a private temporary file and the text through standard input, so neither appears in the process list. Each run starts Claude Code, which adds a few seconds. The Claude desktop app's sign-in is separate; **Sign In…** opens Terminal with `claude auth login`.
- Alternatively, use an **OpenRouter API key** stored only in the login Keychain (`com.local.MacTools.TextAssistant`), with a model chosen from OpenRouter's public list (default `anthropic/claude-haiku-4.5`).
- Transient failures (network, rate limit, server errors) are retried once. Errors appear in the bubble with an **Open Settings** button.
- **Check Setup** in Settings verifies, step by step, Accessibility, the model source (OpenCode installed and signed in, or an OpenRouter key), config.json, and runs a short sample sentence through your model, showing the answer and how long it took. It doesn't touch the clipboard or any app.
- Needs **Accessibility** access: allow **Mac Tools** in System Settings → Privacy & Security → Accessibility. The first run without it opens the system prompt and the settings page.
- Selected text is sent to the chosen model provider only when you run it, and is never logged. Secure (password) fields are refused.

## Shortcuts

- Shows every keyboard shortcut on this Mac in one window (**Show Shortcuts…** in the Mac Tools menu), in two parts:
  - **Global**: shortcuts that work whichever app is in front, grouped by source: macOS (System Settings → Keyboard → Keyboard Shortcuts, including ones you turned off, plus fixed ones like ⌘Tab and ⌥⌘Esc), Mac Tools' own, and each app that saves global shortcuts in its settings (Rectangle, ChatGPT, VMware Fusion…). **Conflicts** lists combinations that two global shortcuts share.
  - **In-App**: the shortcuts in each app's menus (File ▸ Save ⇧⌘S…), the **Standard** ones nearly every app uses, and your App Shortcuts from System Settings.
- **Check a Shortcut** (also in the menu): press a combination, or build one with the ⌃ ⌥ ⇧ ⌘ buttons and a key, to see whether it's free as a new global shortcut: taken (and by what), a standard shortcut, not usable, used only inside some apps, or free. It also suggests the same key with other modifiers that are free. While it records, Mac Tools' own hotkeys are paused so they reach the checker.
- Search matches actions, apps, menu paths, and keys ("⌃⌥N" or "ctrl opt n").
- App menus are read through Accessibility (the same permission Text Assistant uses) when the window opens, on **Rescan**, and when an app launches (**Settings → Shortcuts**, on by default). They are saved in `~/Library/Application Support/Mac Tools/Shortcuts/menu-shortcuts.json`, so apps that aren't running still show; **Forget Captured Menus** deletes the file.
- Read-only: it never changes another app's settings. macOS has no way to list other apps' global hotkeys, so they are found in apps' saved settings. Apps that read keys at a lower level (Karabiner-Elements, BetterTouchTool, Keyboard Maestro), shortcuts saved in an app's own format, and App Store apps' sandboxed settings aren't seen, so "free" means free among the shortcuts Mac Tools can see. Settings files left behind by apps that are no longer installed are ignored.
- An optional shortcut to open the window can be recorded in **Settings → Shortcuts**; none is set by default.

## Settings

**Mac Tools Settings…** (in the menu bar menu, `Command–comma`) is the home for the whole toolbox:

- **General**: version, Launch at Login, and the privacy statement that applies to every tool.
- **All Tools**: the tool inventory. Each tool can be switched on or off; a tool that is off stops running, closes its windows, and leaves the menu bar menu. Its data stays on this Mac, and the choice is remembered across launches.
- **One page per tool**, listed in the sidebar, with the tool's own on/off switch and settings. Desktop Stickies' page covers the New Note shortcut, workspaces, Show Desktop, and where notes are stored; AI Usage's page covers its menu bar icon, services, and refresh interval. Text Assistant's page covers its shortcut, OpenCode sign-in or OpenRouter key, model, Accessibility status, and limits. Shortcuts' page covers the window shortcut, reading app menus, Accessibility, and what it can and can't see.

## Build and test

The project requires macOS 14 or newer and the Swift 6 command-line toolchain.

```sh
./scripts/test.sh
./scripts/build-app.sh
```

The scripts use the SDK selected by `xcode-select` (your installed Xcode). For a deliberate SDK override, set `MAC_TOOLS_SDKROOT`. A complete Xcode installation supplies the test frameworks. The package also supports `swift test` and `swift build -c release` directly.

The app bundle is written to `.build/app/Mac Tools.app` and signed with a persistent local certificate stored in the login Keychain. Rebuilds retain the same app identity. You can set `MAC_TOOLS_SIGNING_IDENTITY` to an existing developer identity instead.

To install it in Applications (quit Mac Tools first):

```sh
./scripts/install-app.sh
```

This copies the app to `/Applications/Mac Tools.app`, preserving any previous installation under `.build/install-backup.*`. Launch at Login is intentionally off by default and can be enabled from Mac Tools Settings after installation.

## Run it (no Swift knowledge needed)

Open Terminal, paste the following, and press Return:

```sh
cd /Users/rootadmin/side-projects/mac-tools
./scripts/install-app.sh
open "/Applications/Mac Tools.app"
```

Look for the stacked-squares icon in the menu bar at the top of the screen. Choose **New Note**, or press **Control–Option–N**. Mac Tools intentionally has no Dock icon. Click inside a note to type, drag its top strip to move it, and drag its edges to resize it. Hover over the top-right corner to change color or close the note. **Manage Notes** lets you restore deleted notes. Notes stay behind regular app windows.

Notes pin automatically: Mission Control is detected from the system's own overlay windows (the Dock's before macOS 27, WindowManager's from macOS 27), so notes disappear on the first animation frame while Command–F3 Show Desktop keeps them in place. No special permission is required for this, and there is no per-launch synchronization step.

Optionally, **Settings → Desktop Stickies → Show Desktop → Enable Accessibility…** adds a fallback Dock observer. Allow **Mac Tools** under System Settings → Privacy & Security → Accessibility, press **Recheck**, then enter and exit Show Desktop once to synchronize it. The old **Mac Tools Desktop Test** permission is separate and does not cover this app. The fallback uses undocumented Dock notification names, which may change with macOS updates. When moving from the older ad-hoc build to the stable signed build, remove and re-add the installed `/Applications/Mac Tools.app` entry once. Normal rebuilds reuse the same certificate; permission checks on startup are silent. Notes keep pinning and hiding in Mission Control even with the fallback off.

If you cannot find the menu-bar icon, open Mac Tools again while it is already running; this opens Mac Tools Settings.

After future code changes, quit Mac Tools from its menu and run the same commands again to rebuild and install it. You can open `Package.swift` in Xcode to browse and edit the source, but building the signed `.app` with the script is the easiest way to run it normally.

## Desktop behavior and recovery

By default, the same notes appear on **all desktop workspaces (Spaces)** on their chosen display; edits are shared because each is still a single note. Open **Settings → Desktop Stickies → Workspaces** (also accessible using the gear in Manage Notes) to choose **One workspace per note** instead. The preference is saved and updates existing notes immediately. In either mode, notes stay behind ordinary app windows, are hidden in Mission Control, and do not join other apps' full-screen windows.

In individual-workspace mode, new notes belong to the workspace where they are created. Exact Space assignments cannot be saved through public macOS APIs; after relaunch notes return to their saved displays in the active Space. Switching from all workspaces to individual workspaces lets macOS assign each existing window to one Space; use Manage Notes to locate it. Display changes and wake events recheck placement. A missing monitor moves its notes onto the primary display.

If a notes file cannot be decoded, Mac Tools makes a uniquely named recovery copy alongside it before permitting new saves. If the copy fails, it leaves the original untouched and keeps edits in memory. Keep the app open, resolve the storage problem, and use **Try Saving Again** in Manage Notes. Never treat in-memory changes as saved when that warning is present.

## Verification

The test suite covers storage and recovery failures, deletion/restore, expiration, disconnected and resized displays, shortcut presentation and live menu updates, multiple tool registration, switching tools on and off (lifecycle, menu, persistence), closing note windows when Desktop Stickies is off, and native window levels/flags. Physical multi-monitor changes, full-screen transitions, and desktop presentation still require separate hands-on checks; unit tests cannot prove those interactions.

For desktop presentation changes, check both workspace modes:

- **Show Desktop** (Command–F3 or a configured hot corner): notes remain editable at the saved position.
- **Mission Control** (three-finger swipe up): notes disappear on the first animation frame.
- Return to the desktop and verify typing, dragging, resizing, and normal windows covering the notes.

Pinning needs only the window probe, not Accessibility. The synchronized configuration uses desktop-icon level + 1 with `stationary`, plus two Mission Control signals: a probe of the Dock's own windows (30 Hz) and, when allowed, the AX mode observer as fallback. The probe hides notes when a full-screen Dock layer-18 window appears together with a new full-screen layer-20 window; Show Desktop creates the layer-18 window without that companion, so notes stay visible. On macOS 27, WindowManager owns these overlays instead: Mission Control and App Exposé add a full-screen layer-19 `ExposeShieldWindow`, while Show Desktop adds a layer-18 `ShowDesktopOverlay`, so the probe hides notes while the layer-19 shield is on screen (traced 2026-10-01). A live trace on 2026-09-10 confirmed the Dock signature, and the probe hides notes roughly 30 ms after the pair appears and restores them roughly 30 ms after it disappears. The AX observer still hides notes if the probe sees no matching transition. Two earlier approaches were rejected: wallpaper level + 1 with `stationary` prevented hover/editing; the exact desktop-icon level with `stationary` also prevented editing and showed notes in Mission Control. Do not ship either combination again. Unit tests cannot prove desktop interaction or timing. See `docs/show-desktop-prototype.md` for the evidence and outstanding checks.

## Architecture

`MacToolsCore` owns the persisted model, repository, hot-key presets, and display-independent geometry. The `MacTools` executable owns AppKit windows and SwiftUI views.

### Adding a tool

1. Implement `ToolModule` (`Sources/MacTools/ToolModule.swift`): a `ToolDescriptor` (id, name, one-line summary, SF Symbol, tint), `start()`/`stop()`, the tool's menu items, and `makeSettingsView()` returning form `Section`s for its settings page.
2. `stop()` must fully undo `start()`; the tool can be switched off while Mac Tools keeps running.
3. Add the module to the `ToolRegistry` in `AppDelegate`. It then appears in the menu bar menu, the All Tools inventory, and the Settings sidebar automatically. Call `openSettings?()` to bring up its own page.

Tools are compiled into Mac Tools; v1 intentionally has no dynamic plugin loader, accounts, analytics, or cloud synchronization. Only AI Usage makes network requests, and only to Anthropic and OpenAI.
