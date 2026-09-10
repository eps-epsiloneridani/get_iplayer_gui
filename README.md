# get_iplayer GUI

[![Build](https://github.com/eps-epsiloneridani/get_iplayer_gui/actions/workflows/build.yml/badge.svg)](https://github.com/eps-epsiloneridani/get_iplayer_gui/actions/workflows/build.yml)

A native macOS GUI (AppKit / Swift) that provides a graphical interface for the
[get_iplayer](https://github.com/get-iplayer/get_iplayer) command-line tool.

## Features

- **Search** BBC iPlayer TV / radio programmes by name or regex
- **Type filter** — search `tv`, `radio`, or `all`
- **Results table** — index, programme, channel, duration, PID, type
- **Record selected** — download one or more selected programmes
- **Record by PID/URL** — download a programme directly from a PID or iPlayer URL
- **Recording flags** — tick boxes for common flags (`--force`, `--audio-only`, `--raw`, `--no-resume`, `--verbose`, `--subtitles`) plus a free-text field for any custom flags
- **Download progress bar** — live percentage bar while recording
- **Refresh cache** — update the get_iplayer programme cache
- **Output directory** — choose where recordings are saved
- **Quality** — pick TV/radio quality (fhd, hd, sd, web, mobile, high, std, med, low)
- **Subtitles** — optionally download subtitles
- **Live log console** — shows all get_iplayer output

## Requirements

- macOS 13 or later (Apple Silicon)
- The Swift toolchain (`swiftc`)
- [get_iplayer](https://github.com/get-iplayer/get_iplayer) installed at
  `/usr/local/bin/get_iplayer`

## Build

From this directory:

```sh
./build.sh
```

This produces `build/get_iplayer_gui.app`. The app references the installed
`get_iplayer` binary at `/usr/local/bin/get_iplayer` (the `/Applications/get_iplayer/`
folder only contains wrapper scripts).

## Run

```sh
open build/get_iplayer_gui.app
```

or launch the executable directly:

```sh
./build/get_iplayer_gui.app/Contents/MacOS/get_iplayer_gui
```

## How it works

The GUI shells out to the `get_iplayer` binary at `/usr/local/bin/get_iplayer`:

- **Search** runs `get_iplayer --type=<type> --listformat="<index>|<pid>|..." <regex>`
  and parses the pipe-delimited output into the results table.
- **Record** runs `get_iplayer <index> --get --output=<dir> [--quality=<q>] [flags] --log-progress`.
  The `--log-progress` flag forces get_iplayer to emit progress lines even though
  output is piped (not a terminal); the GUI parses those lines to drive the progress bar.
- **Refresh** runs `get_iplayer --refresh --type=<type>`.

All output is streamed into the log console at the bottom of the window.

## Notes

- The first time you search, the programme cache may be empty. Click
  **Refresh Cache** to populate it (requires network access to the BBC).
- Recordings are saved to your Movies folder by default; change it with the
  **Output** field.

## Security

This app makes **no outbound network connections of its own** and executes only
the system `get_iplayer` binary via `Process` (no shell, so no shell injection).
It writes no files and contains no obfuscated code.

A static security scan is included and runs in CI on every push/PR:

```sh
python3 scripts/security_scan.py
```

It checks the source, build script, and workflow for backdoor indicators
(network exfiltration, shell execution, obfuscation, unexpected file writes,
hardcoded endpoints, external downloads). Defense-in-depth input validation is
also applied at runtime: the custom-flags field only accepts `-`-prefixed tokens
of safe characters, and the PID/URL field only accepts alphanumeric PIDs or
well-formed http(s) URLs.

## License

[GPL-3.0](LICENSE)

## Credits

This project was **100% vibe coded** — the entire codebase was written by an AI
coding agent ([pi](https://github.com/earendil-works/pi-coding-agent)) under the
direction of a human. No hand-written code was involved. It wraps the
[get_iplayer](https://github.com/get-iplayer/get_iplayer) command-line tool, which
is a separate project by its own contributors.
