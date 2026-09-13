# HANDOFF — get_iplayer GUI

Purpose: bring a fresh pi session up to speed fast. Read this first, then
`README.md`, `PLAN.md`, and `GetIPlayerGUI.swift` as needed.

## What this is

A **native macOS GUI** (AppKit + Swift, no storyboards, fully programmatic UI)
that wraps the `get_iplayer` command-line tool for downloading BBC iPlayer /
BBC Sounds programmes. It shells out to the system `get_iplayer` binary and
parses its output.

- **100% vibe coded** (written by the pi coding agent under human direction).
- License: **GPL-3.0**.
- GitHub repo: `eps-epsiloneridani/get_iplayer_gui` (see Git state below).

## Quick start

```sh
cd gui
./build.sh                 # compiles GetIPlayerGUI.swift → build/get_iplayer_gui.app
open build/get_iplayer_gui.app
```

Requires: Swift toolchain (`swiftc`), macOS 13+, and `get_iplayer` installed at
`/usr/local/bin/get_iplayer`.

## Repository layout

```
gui/
├── GetIPlayerGUI.swift        # the entire app (single file, ~1130 lines)
├── PLAN.md                    # optimisation plan: review findings, per-section
│                              # fixes + status (all six sections DONE)
├── build.sh                   # builds the .app bundle (swiftc + Info.plist + codesign)
├── scripts/security_scan.py   # static security scan (backdoor indicators)
├── .github/workflows/build.yml    # CI: build + upload artifact
├── .github/workflows/security.yml # CI: run security scan
├── README.md                  # user-facing docs
├── LICENSE                    # GPL-3.0
└── .gitignore                 # ignores build/, .DS_Store
```

## Architecture (GetIPlayerGUI.swift)

Single file, six main types:

1. **`Programme`** (struct) — one search result; fields parsed from
   get_iplayer's `--listformat` pipe-delimited output.

2. **`GetIPlayerRunner`** — runs the binary via `Process` on a background
   queue. Two modes:
   - `run(arguments:completion:)` — returns full output at end (search/refresh/help).
   - `run(arguments:onOutput:completion:)` — streams output chunks to a callback
     in real time (used for downloads, to drive the progress bar).
   - Uses `Process` with an **arguments array** (no shell) → no shell injection.
   - Tracks the running `Process` and exposes `stop()` (SIGINT; guarded by
     `isRunning`) for a graceful Stop button.
   - Runner robustness (PLAN.md S2 — do not regress):
     - **No `readDataToEndOfFile()` after `waitUntilExit`** — a lingering child
       of get_iplayer (ffmpeg etc.) inheriting the pipe would block that
       call forever and leave the UI stuck "busy". Output is delivered by the
       `readabilityHandler`; completion fires from the exit path.
     - The parent closes its own copy of the pipe's write end after launch.
     - Launch failure clears `runningProcess` (identity-checked, under lock)
       so `stop()` can never hit a dead process.

3. **`LineBuffer`** — splits a streamed chunk into complete lines; `flush(_:)`
   is called in the record completion so the final partial line isn't lost.

4. **`GroupedStackView`** — NSStackView subclass whose `isAccessibilityElement()`
   returns true (AppKit has no runtime setter for element-ness — see AppKit
   gotchas). Used to expose the flags bar as a VoiceOver group.

5. **`ViewController`** — builds the UI and handles all actions.

6. **`AppDelegate`** — window + main menu (App / Edit / Controls / Window / Help).

### UI layout (top → bottom)

- **Top bar**: Search field, type popup (`tv`/`radio`/`all`), Search,
  Refresh Cache, spinner.
- **Results table**: columns Idx / Programme / Channel / Duration / PID / Type.
- **Bottom bar**: Output dir field + Browse, Quality popup,
  "Download Selected" button.
- **Flags bar**: a `GroupedStackView` (VoiceOver group "Recording flags"):
  `Flags:` label, checkboxes Force / Audio-only / Raw / No-resume / Verbose /
  Subtitles, then `Custom:` free-text field.
- **PID bar**: "Record by PID/URL:" field + "Download" button + "Record whole
  series (PID recursive)" checkbox. **Invalid PIDs/URLs abort the recording
  entirely** — a bare `--get` with no selection would download the ENTIRE
  cache. `--pid-recursive` is appended once, only when a PID (not a URL) was
  collected.
- **Progress row**: `Progress:` label + determinate progress bar + % label.
- **Log console**: read-only `NSTextView` — wraps long lines (container width
  tracking) and is capped at ~200k characters so long sessions don't grow it
  without bound.
- **Status label** + **Stop** button (bottom right; enabled while busy). **⌘.**
  also triggers Stop via the Controls menu. The "Download" button on the PID
  bar is the window's default button (`keyEquivalent = "\r"`).

### How commands are built

- **Search**: `get_iplayer --type=<type> --listformat="<index>|<pid>|...|<guidance>" <regex>`
  → parsed into `Programme` rows. Search terms starting with `--` are rejected
  (get_iplayer would read them as options).
- **Download selected**: `get_iplayer <index>... --get --output=<dir> [--quality=<q>] [flags] --log-progress`
- **Download by PID/URL**: `get_iplayer --pid=<pid>|--url=<url> --get ...`
  (adds `--pid-recursive` once when the whole-series checkbox is ticked AND a
  PID was collected)
- **Refresh**: `get_iplayer --refresh --type=<type>`
- **Help**: `get_iplayer --help` (menu: Help → "Print Get_iPlayer Help"; the
  item is disabled while busy)

### Progress bar

- `--log-progress` forces progress lines even though output is piped; one
  precompiled regex (`ViewController.progressRegex` via `parseProgressLine`)
  matches `^\s*(\d+(?:\.\d+)?)% of ~`.
- The bar resets to 0% whenever an `INFO: Downloading` line arrives — the reset
  lives in `handleOutputLine`'s non-progress branch, NOT in `updateProgress`
  (an old dead branch there was removed; don't put it back).
- Completions are honest: `stopRequested` → "stopped by user";
  `terminationStatus != 0` → failure with exit code; otherwise success. The
  bar only reaches 100% on a real finish.
- VoiceOver: 25/50/75% milestones are announced once per programme
  (`lastProgressMilestone`, reset per programme in `handleOutputLine`).

### Binary path

Hardcoded to `/usr/local/bin/get_iplayer` in `viewDidLoad`. The
`/Applications/get_iplayer/` folder only contains wrapper scripts — the real
binary is at `/usr/local/bin/get_iplayer`. If the path ever changes, edit the
`binaryPath` line in `viewDidLoad`.

## Security posture

- **No outbound network** of its own; only get_iplayer talks to the BBC.
- **No shell** — `Process` argument array, so no shell injection.
- **No file writes**, no obfuscation, no bundled/downloaded binaries.
- **Runtime input validation** (defense in depth):
  - Custom flags field only accepts `-`-prefixed tokens of safe chars
    (`[A-Za-z0-9-_=./]`); unsafe tokens are dropped + logged.
  - PID/URL field only accepts alphanumeric PIDs or well-formed http(s) URLs,
    and a recording with nothing valid aborts instead of running `--get`.
  - Search terms starting with `--` are rejected (would be read as options).
- **Static scan**: `python3 scripts/security_scan.py` (exit 0 = pass). Runs in
  CI via `.github/workflows/security.yml`. If a scan flags a false positive, add
  it to `ALLOWED` in the script.

## Git state

- Local repo in `gui/`, branch `main`; remote `origin` =
  `https://github.com/eps-epsiloneridani/get_iplayer_gui.git`.
- **Local main is ahead of origin/main** — the optimisation-pass commits below
  are NOT pushed. Push only after the user signs off.
- Local git identity: `eps-epsiloneridani` / `eps-epsiloneridani@users.noreply.github.com`.
- Commits (newest first):
  - (current) Section 6: hygiene + AGENTS.md refresh
  - `0c16ca7` Section 6: reject "--" search terms, append --pid-recursive once
  - `065d895` Section 4: precompiled progress regex, cached log formatter, log cap
  - `23835e5` Section 3: contentMinSize + compressible table height, live progress reset, canonical log text sizing
  - `fcf2939` Section 5: accessibility — selection/in-progress announcements, Cmd-. Stop, flags-bar group, remaining labels
  - `a015f83` Section 2: runner robustness — launch cleanup, no pipe-drain hang, flush tail line, isRunning guard on stop
  - `4e7a67d` Section 1 fix: Help greying needs @objc validateMenuItem (AppKit ignores plain Swift validate(_:))
  - `21c6688` Section 1: refuse invalid PID/URL, serialise Help, honest exit-status reporting
  - `394474d` Add optimisation plan with per-section tracking
  - `1e40a73` Update GetIPlayerGUI.swift
  - `90e0643` Update AGENTS.md to reflect latest accessibility, keyboard, and git state
  - `ba2e528` Revert PID tab override; keep natural tab to Download button
  - `a7ee85f` Fix accessibility API usage (setAccessibilityLabel / announcement keys)
  - `0d749a8` Add accessibility labels, Window/Hide menus, Return-key scoping, VoiceOver announcements
  - `9e74b49` Make Download the Return-key default button; Download Selected no longer is
  - `8ee0a7c` Fix Download button colour: use bezelColor (later reverted)
  - `f511649` Add blue Download button accent and graceful Stop button
  - `34d536c` Add whole-series (--pid-recursive) checkbox to PID download
  - `c3f112f` Rename HANDOFF.md to AGENTS.md
  - `00d8660` Add HANDOFF.md
  - `576ac80` Update GetIPlayerGUI.swift (Help menu + label renames)
  - `7137703` Add security scan, CI workflow, and input validation
  - `a1657e1` This is the initial commit
  - `dff8070` Initial commit

## The optimisation pass (PLAN.md)

A full review + optimisation pass tracked in `PLAN.md` — all six sections DONE.
Highlights (details and rationale in PLAN.md):

- **S1 — Critical**: invalid PID/URL aborts before `--get` (previously a typo
  could download the ENTIRE cache); Help serialised with the busy protocol;
  completions report exit codes and "stopped by user" instead of always
  "finished".
- **S2 — Runner**: no pipe-drain hang, launch-failure cleanup, tail-line
  flush, `isRunning` guard on `stop()`.
- **S5 — Accessibility**: start/in-progress/completion announcements,
  selection feedback, 25/50/75% milestones, ⌘. Stop menu item, flags-bar
  VoiceOver group, labels/help on all controls.
- **S3 — Layout**: `window.contentMinSize` (720×520), compressible table
  height (999 priority, ≥150 floor), canonical log text sizing (wraps, scrolls).
- **S4 — Performance**: one precompiled progress regex (`parseProgressLine`),
  shared log timestamp formatter, log capped at ~200k characters.
- **S6 — Hygiene**: `--` search terms rejected; `--pid-recursive` appended once.

## AppKit gotchas (verified empirically — do not relearn these)

1. `accessibilityLabel` is a read-only method in AppKit, not a settable
   property — use `setAccessibilityLabel(_:)`.
2. **Menu-item validation requires `@objc func validateMenuItem(_:)`.** A
   plain Swift `validate(_:)` (NSUserInterfaceItemValidation) is never
   consulted by AppKit menu validation — it isn't even visible at the
   `validateUserInterfaceItem:` selector without explicit protocol
   conformance. (Discovered when the Help item refused to grey out.)
3. **There is no runtime setter for accessibility element-ness** (unlike
   UIKit): `isAccessibilityElement` is a read-only method. Subclass a view to
   make it an element/group (see `GroupedStackView`).
4. `NSTextView.textContainer` is annotated `NSTextContainer?` in this SDK —
   bind it in an `if let` rather than dotting through it.

## Feature history / decisions

- **Deployment target** pinned to `arm64-apple-macosx13.0` in `build.sh` — the
  toolchain defaulted to `macosx28.0` which broke launching on macOS 27.
- **Edit menu** added because without it, Cut/Copy/Paste didn't work in text fields.
- **Controls menu** added (Stop, ⌘.) so keyboard-only users can interrupt a
  run without tabbing to the Stop button.
- **Flags bar** added so users can pass flags like `--force`; the `Flags:` label
  must be added to the stack **before** the checkboxes to appear on the left.
- **Progress bar** added for downloads; `--log-progress` is always appended.
- Button labels: "Download Selected" (record selected), "Download" (record by
  PID). The "Download" button is the window's default button
  (`keyEquivalent = "\r"`) so it activates on Return and appears blue. Do NOT
  use `bezelColor`/`contentTintColor` to colour it — that was tried then
  reverted.
- **Help menu** item "Print Get_iPlayer Help" runs `get_iplayer --help` into
  the log; disabled while busy. Help/Stop menu availability is validated in the
  view controller's `validateMenuItem(_:)` (must be `@objc`, see gotcha 2).
- **Window sizing**: `contentMinSize` 720×520. The table height constraint
  (300pt) runs at priority 999 with a required ≥150 floor so it compresses
  gracefully instead of breaking Auto Layout. Extra space when the window
  grows goes to the log. `setupMainMenu()` is called AFTER the view controller
  is created so menu items get real targets (nil targets only work by
  responder-chain luck).

## Accessibility & keyboard

- **Menus**: App menu (Hide ⌘H / Hide Others ⌥⌘H / Show All), Edit menu,
  **Controls** menu (Stop ⌘.), Window menu (Minimize ⌘M / Zoom), Help menu.
- **Return key**: the "Download" button is the default button. Return in the
  Search field triggers Search; Return in Output/Custom-flags fields is consumed
  (so it doesn't fire Download); Return in the PID field fires Download.
- **VoiceOver labels** (`setAccessibilityLabel(_:)`): search/output/custom/
  PID fields, both popups, progress bar, progress label, status label, log
  console ("Log console"), spinner ("Working"), table ("Search results").
  Help text (`setAccessibilityHelp`) on Stop, recursive checkbox, quality and
  type popups.
- **Table**: label "Search results" plus `accessibilityValue` "N results"
  (updated in `parseResults`).
- **Announcements**: `announce(_:priority:)` posts VoiceOver announcements —
  `.high` (interrupts speech) for completions and guard errors, `.medium`
  (queues) for in-progress and selection feedback. Coverage: search/refresh/
  help/record starts AND completions, row selection (title or count),
  per-programme "Downloading <name>", 25/50/75% milestones, stop requests.
- **Flags bar grouping**: `GroupedStackView` with role `.group`, label
  "Recording flags", `accessibilityChildren` = arrangedSubviews (gotcha 3).
- **Initial focus**: the search field becomes first responder at launch
  (`ViewController.focusSearch()`).
- **Tab order**: left-to-right natural order. Tab from the PID field goes to
  the **Download** button (default). The recursive checkbox follows it. Do NOT
  override `nextKeyView` to skip Download — that was tried and reverted.

## Common tasks / where to edit

- **Add a UI control**: declare a property near the other `private let` fields,
  build it in `buildUI()`, add to the relevant `NSStackView`, and wire an action.
- **Add a flag checkbox**: add a property, add it to the `for cb in [...]` loop
  in the flags bar, and add `if cb.state == .on { args.append("--flag") }` in
  `appendCommonRecordArgs`.
- **Change binary path**: `viewDidLoad`.
- **Change menu items**: `setupMainMenu()` in `AppDelegate` (note: called after
  the view controller exists — keep it that way).
- **Change progress parsing**: `parseProgressLine` / `updateProgress` (the
  regex lives in the cached `ViewController.progressRegex`).
- **Change announcements**: `announce(_:priority:)` and its call sites.
- **Change the log cap**: `ViewController.logCharacterLimit`.

## Gotchas

- `build/` is gitignored; the `.app` is rebuilt by CI and downloadable as an
  artifact.
- The programme cache is empty until you click **Refresh Cache** (needs BBC
  network access).
- Recordings default to the Movies folder.
- Long-running sessions: the log caps itself (~200k chars) — trimming is
  expected, not a bug.