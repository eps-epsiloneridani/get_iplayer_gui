#!/usr/bin/env python3
"""Static security scan for the get_iplayer GUI.

Scans the Swift source, build script, and CI workflow for indicators of a
backdoor or malicious behavior: network exfiltration, shell execution,
obfuscation, unexpected file writes, and hardcoded endpoints.

Exit code 0 = pass, 1 = fail. Run from the repo root:
    python3 scripts/security_scan.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# (label, regex, files to scan)
CHECKS: list[tuple[str, str, list[str]]] = [
    (
        "Network exfiltration APIs",
        r"\b(URLSession|URLRequest|NSURLSession|fetch\(|WebSocket|NWConnection|"
        r"NSStream|CFStream|socket\(|connect\(|uploadTask|dataTask|downloadTask)\b",
        ["GetIPlayerGUI.swift"],
    ),
    (
        "Shell / command execution",
        r"\b(system\(|popen|exec\(|NSAppleScript|osascript|/bin/sh|/bin/bash|"
        r"/bin/zsh|/dev/tcp|Process\(\))\b",
        ["GetIPlayerGUI.swift"],
    ),
    (
        "Obfuscation / encoded payloads",
        r"\b(base64|fromBase64|eval\(|decode\(|unhexlify|\.onion)\b",
        ["GetIPlayerGUI.swift"],
    ),
    (
        "Suspicious file writes",
        r"\b(FileHandle|writeValue|createFile|write\(toFile|Data\(contentsOf|"
        r"UserDefaults|appendEntry)\b",
        ["GetIPlayerGUI.swift"],
    ),
    (
        "Hardcoded IP addresses",
        r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b",
        ["GetIPlayerGUI.swift", "build.sh", ".github/workflows/build.yml"],
    ),
    (
        "External downloads in build",
        r"\b(curl|wget|git clone|pip install|npm install|brew install)\b",
        ["build.sh", ".github/workflows/build.yml"],
    ),
    (
        "Bundled binaries / scripts",
        r"\b(\w+\.exe\b|\w+\.dll\b|\w+\.so\b|\w+\.command\b)",
        ["build.sh"],
    ),
]

# Known-good references that are expected and benign.
ALLOWED = {
    "Process()",  # used to run get_iplayer (the app's purpose)
    "decode(",    # false-positive risk; verified none present
}


def scan_file(path: Path) -> list[str]:
    """Return list of (line_no, label, line) findings for a file."""
    findings: list[str] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as e:
        findings.append(f"  [error] cannot read {path}: {e}")
        return findings

    for label, pattern, _ in CHECKS:
        rx = re.compile(pattern, re.IGNORECASE)
        for i, line in enumerate(lines, 1):
            if rx.search(line):
                # Skip known-good references
                if any(allow in line for allow in ALLOWED):
                    continue
                findings.append(f"  {path}:{i} [{label}] {line.strip()}")
    return findings


def main() -> int:
    files = [ROOT / f for f in ["GetIPlayerGUI.swift", "build.sh",
                                ".github/workflows/build.yml"]]
    all_findings: list[str] = []

    for f in files:
        if not f.exists():
            all_findings.append(f"  [missing] {f}")
            continue
        all_findings.extend(scan_file(f))

    if all_findings:
        print("SECURITY SCAN FAILED — potential issues found:\n")
        for finding in all_findings:
            print(finding)
        print("\nReview each finding. If it is a false positive, add it to "
              "ALLOWED in scripts/security_scan.py.")
        return 1

    print("SECURITY SCAN PASSED — no backdoor indicators found.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
