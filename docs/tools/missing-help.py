#!/usr/bin/env python3
"""Lists controls in the app's SwiftUI views that have no .help() tag before the next control.

Rough check (text based): run it after adding controls, then decide case by case.
Usage: python3 docs/tools/missing-help.py
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2] / "App" / "Recorte"
CONTROL = re.compile(r"\b(Button|Toggle|Picker|Stepper|Slider|TextField|Menu)\s*[({]")
# Buttons whose meaning is obvious from the standard macOS wording.
OBVIOUS = re.compile(r'Button\("(Cancel|OK|Done|Close|Apply|Start)"')

def main() -> None:
    missing = 0
    for path in sorted(ROOT.rglob("*.swift")):
        lines = path.read_text(encoding="utf-8").splitlines()
        # Menu commands can't show help tags: skip `Commands` types.
        in_commands = False
        starts = []
        for i, line in enumerate(lines):
            if line.startswith("struct "):
                in_commands = ": Commands" in line
            if not in_commands and CONTROL.search(line) and not line.strip().startswith("//"):
                starts.append(i)
        for n, start in enumerate(starts):
            end = starts[n + 1] if n + 1 < len(starts) else len(lines)
            block = "\n".join(lines[start:end])
            if ".help(" in block or OBVIOUS.search(lines[start]):
                continue
            missing += 1
            print(f"{path.relative_to(ROOT.parent.parent)}:{start + 1}: {lines[start].strip()[:100]}")
    print(f"{missing} controls without a help tag")

if __name__ == "__main__":
    main()
