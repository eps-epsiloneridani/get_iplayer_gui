# HANDOFF — get_iplayer GUI

Purpose: bring a fresh pi session up to speed fast. Read this first, then
`README.md` and `GetIPlayerGUI.swift` as needed.

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
├── GetIPlayerGUI.swift        # the entire app (single file, ~800 lines)
├── build.sh                   # builds the .app bundle (swiftc + Info.plist + codesign)
├── scripts/security_scan.py   # static security scan (backdoor indicators)
├── .github/workflows/build.yml    # CI: build + upload artifact
├── .github/workflows/security.yml # CI: run security scan
├── README.md                  # user-facing docs
├── LICENSE                    # GPL-3.0
└── .gitignore                 # ignores build/, .DS_Store
```

## Architecture (GetIPlayerGUI.swift)

Single file, three main types:

1. **`Programme`** (struct) — one search result; fields parsed from
   get_iplayer's `--listformat` pipe-delimited output.

2. **`GetIPlayerRunner`** — runs the binary via `Process` on a background
   queue. Two modes:
   - `run(arguments:completion:)` — returns full output at end (search/refresh/help).
   - `run(arguments:onOutput:completion:)` — streams output chunks to a callback
     in real time (used for downloads, to drive the progress bar).
   - Uses `Process` with an **arguments array** (no shell) → no shell injection.
   - Tracks the running `Process` and exposes `stop()` (sends SIGINT) for a
     graceful Stop button.

3. **`LineBuffer`** — splits a streamed chunk into complete lines.

4. **`ViewController`** — builds the UI and handles all actions.

5. **`AppDelegate`** — window + main menu (App / Edit / Help).

### UI layout (top → bottom)

- **Top bar**: Search field, type popup (`tv`/`radio`/`all`), Search, Refresh Cache, spinner.
- **Results table**: columns Idx / Programme / Channel / Duration / PID / Type.
- **Bottom bar**: Output dir field + Browse, Quality popup, "Download Selected" button.
- **Flags bar**: `Flags:` label, then checkboxes Force / Audio-only / Raw /
  No-resume / Verbose / Subtitles, then `Custom:` free-text field.
- **PID bar**: "Record by PID/URL:" field + "Download" button + "Record whole
  series (PID recursive)" checkbox. When ticked, `--pid-recursive` is added so a
  series/brand PID downloads every episode (only applies to PIDs, not URLs).
- **Progress row**: `Progress:` label + determinate progress bar + % label.
- **Log console**: read-only `NSTextView` (all get_iplayer output streams here).
- **Status label** at bottom + a blue **Download** button on the PID bar and a
  **Stop** button at the bottom right (enabled while busy, sends SIGINT via
  `GetIPlayerRunner.stop()` to gracefully interrupt the running process).

### How commands are built

- **Search**: `get_iplayer --type=<type> --listformat="<index>|<pid>|...|<guidance>" <regex>`
  → parsed into `Programme` rows. `--listformat` uses sanitize_mode 2 (raw values),
  so `|` is a safe delimiter.
- **Download selected**: `get_iplayer <index>... --get --output=<dir> [--quality=<q>] [flags] --log-progress`
- **Download by PID/URL**: `get_iplayer --pid=<pid>|--url=<url> --get ...`
  (adds `--pid-recursive` when the whole-series checkbox is ticked and a PID is used)
- **Refresh**: `get_iplayer --refresh --type=<type>`
- **Help**: `get_iplayer --help` (menu: Help → "Print Get_iPlayer Help")

### Progress bar

`--log-progress` forces get_iplayer to emit progress lines even though output is
piped (not a terminal). Lines match `^\s*(\d+(?:\.\d+)?)% of ~`; the bar resets
to 0 on a new `INFO: Downloading ...` line. Non-progress lines go to the log.

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
  - PID/URL field only accepts alphanumeric PIDs or well-formed http(s) URLs.
- **Static scan**: `python3 scripts/security_scan.py` (exit 0 = pass). Runs in
  CI via `.github/workflows/security.yml`. If a scan flags a false positive, add
  it to `ALLOWED` in the script.

## Git state

- Local repo initialized in `gui/`; branch `main`.
- Commits (newest first):
  - `576ac80` Update GetIPlayerGUI.swift (Help menu + label renames)
  - `7137703` Add security scan, CI workflow, and input validation
  - `a1657e1` This is the initial commit
  - `dff8070` Initial commit
- **Not yet pushed to GitHub.** The `origin` remote was removed earlier because
  the repo didn't exist on GitHub yet. To publish: create the empty repo on
  GitHub, then `git remote add origin https://github.com/eps-epsiloneridani/get_iplayer_gui.git && git push -u origin main`.
  (Or use GitHub Desktop → "Publish repository".)
- Local git identity: `eps-epsiloneridani` / `eps-epsiloneridani@users.noreply.github.com`.

## Feature history / decisions

- **Deployment target** pinned to `arm64-apple-macosx13.0` in `build.sh` — the
  toolchain defaulted to `macosx28.0` which broke launching on macOS 27.
- **Edit menu** added because without it, Cut/Copy/Paste didn't work in text fields.
- **Flags bar** added so users can pass flags like `--force`; the `Flags:` label
  must be added to the stack **before** the checkboxes to appear on the left.
- **Progress bar** added for downloads; `--log-progress` is always appended.
- Button labels: "Download Selected" (record selected), "Download" (record by PID).
- **Help menu** item "Print Get_iPlayer Help" runs `get_iplayer --help` into the log.

## Common tasks / where to edit

- **Add a UI control**: declare a property near the other `private let` fields
  (~line 130-160), build it in `buildUI()`, add to the relevant `NSStackView`,
  and wire an action.
- **Add a flag checkbox**: add a property, add it to the `for cb in [...]` loop
  in the flags bar, and add `if cb.state == .on { args.append("--flag") }` in
  `appendCommonRecordArgs`.
- **Change binary path**: `viewDidLoad`.
- **Change menu items**: `setupMainMenu()` in `AppDelegate`.
- **Change progress parsing**: `isProgressLine` / `updateProgress`.

## Gotchas

- `build/` is gitignored; the `.app` is rebuilt by CI and downloadable as an
  artifact.
- The programme cache is empty until you click **Refresh Cache** (needs BBC
  network access).
- Recordings default to the Movies folder.
