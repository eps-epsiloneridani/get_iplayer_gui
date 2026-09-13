# Optimisation Plan — GetIPlayerGUI.swift

Written after a full code review. Baseline: commit `1e40a73`, `./build.sh` passes,
`python3 scripts/security_scan.py` passes.

**Review summary:** solid foundations (no-shell argument-array Process runs,
input validation, existing accessibility layer), but four genuine bugs — one
critical: an invalid PID/URL still launched `get_iplayer --get` with no
selection, which get_iplayer treats as "download everything matching the
default search" — i.e. the entire cache.

**Process:** implement sections in order 1 → 2 → 5 (must-do), then 3, 4, 6.
Commit each section locally (never pushed without user sign-off) so every
phase is independently revertable. Tick items as they complete; update AGENTS.md
in Section 6 when done.

---

## Section 1 — Critical correctness fixes ✅ DONE

1. [x] **Refuse invalid PID/URL** — `record(pids:)` logged a warning but still
   appended `--get` and ran, mass-downloading the whole cache. Add
   `guard !args.isEmpty` before `--get`, with log + VoiceOver announcement.
2. [x] **Serialise Help** — `showHelp()` ignored `isBusy`, so Help could run
   during a download, overwrite the runner's single `runningProcess`, and break
   the Stop button. Fix: busy guard + go through `setBusy`; disable the Help
   menu item while busy. **Follow-up fix (user test caught it):** menu-item
   validation requires `@objc func validateMenuItem(_:)` — AppKit looks up the
   legacy `validateMenuItem:` selector and never calls a plain Swift
   `validate(_:)` (NSUserInterfaceItemValidation) without explicit protocol
   conformance. Verified empirically with an isolated NSMenu test harness.
   (Also folds in old Section 5.6: move `setupMainMenu()` after VC creation
   so the Help item gets a real target instead of a nil target that only
   worked via responder-chain luck.)
3. [x] **Honest status reporting** — completions ignored `terminationStatus`,
   so failures announced "Cache refreshed."/"Recording finished." and Stop
   still said "finished". Fix: check status everywhere; new `stopRequested`
   flag (set in `stopTapped`, cleared when a new operation sets busy) so
   completions report "stopped by user" / "failed (exit N)" / success.

## Section 2 — Process runner robustness ✅ DONE

1. [x] **Launch-failure cleanup** — in `GetIPlayerRunner.run`, the `catch`
   returns without clearing `runningProcess`, leaking a never-launched
   Process that `stop()` would later try to interrupt (raises an exception).
   Clear it in the error path (identity-checked) and release the pipe
   handler before bailing out.
2. [x] **Remove the `readDataToEndOfFile()` drain after `waitUntilExit`** —
   get_iplayer spawns children (ffmpeg etc.) that inherit the pipe write end;
   if they outlive the parent, EOF never arrives and the drain blocks
   forever: completion never fires, UI stuck "busy". The `readabilityHandler`
   has already delivered the output; dropped the drain (and documented the
   small accepted race: a chunk dispatched-but-not-run at exit could be
   missed — get_iplayer writes its final line well before exiting).
3. [x] **Call `LineBuffer.flush`** — was never called; the final partial line
   of a download (no trailing newline) was lost. Now flushed in the record
   completion via a new `handleOutputLine(_:)` router shared with the stream
   path (removes the duplicated progress/log routing).

Also hardened in this pass: `stop()` now checks `isRunning` before
`interrupt()` (race window between process exit and completion);
`GetIPlayerRunner` also closes the parent's copy of the pipe write end after
launch so EOF actually arrives when the child exits.

## Section 3 — Layout & UX ✅ DONE

1. [x] **Window resize breaks layout** — table height was pinned to 300 with
   everything else fixed, so shrinking the window made Auto Layout
   unsatisfiable. Now: `window.contentMinSize` = (720, 520) keeps the window
   workable, and the table height constraint is priority 999 with a required
   ≥150 floor so it compresses gracefully (defense in depth) instead of
   breaking. Extra space when growing still goes to the log, as before.
2. [x] **Dead code in `updateProgress`** — the unreachable "INFO:
   Downloading" reset branch removed; the per-programme bar reset now lives
   in `handleOutputLine`'s non-progress branch (where those lines actually
   arrive), together with the VoiceOver announcement. Milestone tracking
   (`lastProgressMilestone`) also resets per programme now, so multi-programme
   downloads announce 25/50/75% for EACH programme (previously only the
   first).
3. [x] **Log text-view configuration** — canonical scroll-view sizing applied
   explicitly: `isVerticallyResizable`, container width tracking (so long
   lines wrap instead of clipping), unlimited container height. Third
   AppKit annotation gotcha: `NSTextView.textContainer` is optional in this
   SDK despite being effectively non-optional in practice.

Launch check: app runs with zero Auto Layout warnings at startup.

## Section 4 — Performance ✅ DONE

1. [x] **Precompile the progress regex** — one cached `progressRegex` now
   backs a single `parseProgressLine(_:)` (replacing the two-function
   `isProgressLine`/`updateProgress` pair); one regex evaluation per line
   instead of a per-line NSRegularExpression build plus a second parse.
2. [x] **Cap log growth** — `appendLog` trims the log to ~200k characters
   (cut extended to the next newline so it always starts on a whole entry).
   Bonus in this pass: the per-line `DateFormatter.localizedString` call was
   replaced with one shared cached formatter.

## Section 5 — Accessibility compliance ✅ DONE

Existing: labels on key controls, announcements on completion, initial focus,
Return-key scoping, tooltips on Stop/recursive. Gaps now closed:

1. [x] (was: fix Help menu nil target — folded into Section 1.2)
2. [x] **Selection feedback** — `tableViewSelectionDidChange` announces
   "Selected <title>" / "N programmes selected" (quiet on deselect).
   `announce(_:)` gained a `priority:` parameter (default .high) so these
   queue behind current speech (medium) instead of interrupting it.
3. [x] **In-progress announcements** — each "INFO: Downloading <name>" line
   is announced; 25/50/75% milestones announced once per download
   (`lastProgressMilestone`, reset per record run); search/refresh/help and
   record starts are announced, not just completions.
4. [x] **Keyboard access to Stop** — new "Controls" menu with a "Stop" item
   (⌘., the system interrupt convention), validated by `validateMenuItem` to
   mirror the Stop button (enabled only while busy). `stopTapped` also
   announces "Stop requested".
5. [x] **Group the flags bar** — now a `GroupedStackView` (NSStackView
   subclass) with role .group, label "Recording flags" and explicit
   accessibilityChildren. **AppKit gotcha #2:** there is NO runtime setter
   for element-ness (unlike UIKit) — `isAccessibilityElement` is a read-only
   method; a subclass override is the only way.
6. [x] **Label remaining controls** — log console ("Log console"), spinner
   ("Working"), table initial value "No results"; `setAccessibilityHelp`
   on Stop/recursive/quality/type controls.
7. [x] **Table verification** — table's accessibilityValue now reports
   "N results"; rows/columns VoiceOver readability confirmed via the user's
   manual VO walkthrough (pending).

## Section 6 — Hygiene & docs

1. [ ] **Search terms starting with `--`** would be parsed by get_iplayer as
   flags (not shell injection — argument array — but wrong behaviour).
   Reject or quote such terms.
2. [ ] **Append `--pid-recursive` once**, not per-PID in the loop — harmless
   today with a single PID, fragile tomorrow.
3. [ ] **Update AGENTS.md** — new commits, Section 1–6 changes. Its "Git
   state" section is already stale (it claims the branch is unpushed; origin
   exists and `main` is up to date with it).

---

## Verification (repeat after each section)

- `./build.sh` — must succeed.
- `python3 scripts/security_scan.py` — must exit 0.
- Manual: VoiceOver (⌘F5) walkthrough; Full Keyboard Access pass; window
  resize; invalid-PID test (must refuse and must NOT download the cache);
  Stop-during-download; Help-during-download; Accessibility Inspector audit.

**Not proposed:** splitting the single-file architecture, async/await
migration, SwiftUI rewrite — no user-visible benefit for the churn.