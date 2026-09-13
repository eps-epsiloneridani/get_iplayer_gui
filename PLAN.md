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

## Section 1 — Critical correctness fixes ⏳ IN PROGRESS (this session)

1. [ ] **Refuse invalid PID/URL** — `record(pids:)` logged a warning but still
   appended `--get` and ran, mass-downloading the whole cache. Add
   `guard !args.isEmpty` before `--get`, with log + VoiceOver announcement.
2. [ ] **Serialise Help** — `showHelp()` ignored `isBusy`, so Help could run
   during a download, overwrite the runner's single `runningProcess`, and break
   the Stop button. Fix: busy guard + go through `setBusy`; disable the Help
   menu item while busy via `validate(_:)`. (Also folds in old Section 5.6:
   move `setupMainMenu()` after VC creation so the Help item gets a real
   target instead of a nil target that only worked via responder-chain luck.)
3. [ ] **Honest status reporting** — completions ignored `terminationStatus`,
   so failures announced "Cache refreshed."/"Recording finished." and Stop
   still said "finished". Fix: check status everywhere; new `stopRequested`
   flag (set in `stopTapped`, cleared when a new operation sets busy) so
   completions report "stopped by user" / "failed (exit N)" / success.

## Section 2 — Process runner robustness

1. [ ] **Launch-failure cleanup** — in `GetIPlayerRunner.run`, the `catch`
   returns without clearing `runningProcess`, leaking a never-launched
   Process that `stop()` would later try to interrupt (raises an exception).
   Clear it in the error path.
2. [ ] **Remove the `readDataToEndOfFile()` drain after `waitUntilExit`** —
   get_iplayer spawns children (ffmpeg etc.) that inherit the pipe write end;
   if they outlive the parent, EOF never arrives and the drain blocks
   forever: completion never fires, UI stuck "busy". The `readabilityHandler`
   has already delivered the output; drop the drain.
3. [ ] **Call `LineBuffer.flush`** — defined but never called; the final
   partial line of a download (no trailing newline) is lost. Flush in the
   record completion handler.

## Section 3 — Layout & UX

1. [ ] **Window resize breaks layout** — table height pinned to 300 with all
   other rows fixed, so shrinking the window makes Auto Layout unsatisfiable.
   Set `window.contentMinSize` and/or lower the height constraint's priority
   so it can compress.
2. [ ] **Dead code in `updateProgress`** — the "INFO: Downloading" reset
   branch is unreachable (those lines fail `isProgressLine` and go to the
   log). Move the per-programme bar reset into `onOutput`'s non-progress
   branch so multi-programme downloads visibly restart at 0%.
3. [ ] **Verify log text-view configuration** — standard
   NSScrollView/NSTextView setup (`isVerticallyResizable`, container width
   tracking) so long lines wrap and scroll rather than clip.

## Section 4 — Performance

1. [ ] **Precompile the progress regex** — `updateProgress` builds an
   `NSRegularExpression` per line and `isProgressLine` re-parses per line;
   parse each line once with one cached regex.
2. [ ] **Cap log growth** — log text storage grows unboundedly over a long
   session; trim to the last N KB when appending.

## Section 5 — Accessibility compliance

Existing: labels on key controls, announcements on completion, initial focus,
Return-key scoping, tooltips on Stop/recursive. Gaps to close:

1. [x] (was: fix Help menu nil target — folded into Section 1.2)
2. [ ] **Selection feedback** — implement `tableViewSelectionDidChange` so
   VoiceOver announces the selected programme title/count.
3. [ ] **In-progress announcements** — announce each "INFO: Downloading
   <name>" line and milestone percentages (e.g. every 25%), plus
   search/refresh *start*, not only completion.
4. [ ] **Keyboard access to Stop** — add a "Stop" menu item with ⌘.
   (system interrupt convention) calling `stopTapped`, so keyboard-only
   users don't have to tab through the UI to stop a download.
5. [ ] **Group the flags bar** — six bare checkboxes read as an unanchored
   stream in VoiceOver; make the `NSStackView` an accessibility element
   labelled "Recording flags".
6. [ ] **Label remaining controls** — log console ("Log console"), spinner
   ("Working"); add `setAccessibilityHelp` on Stop/recursive/quality/type.
7. [ ] **Table verification** — confirm rows/columns read correctly in
   VoiceOver; set the table's `accessibilityValue` to the result count.

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