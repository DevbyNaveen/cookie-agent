#!/usr/bin/env python3
"""Run native interaction checks with Command Line Tools, without XCTest or xcodebuild."""
from pathlib import Path
import subprocess
import sys

project_directory = Path(__file__).resolve().parent.parent
output_directory = project_directory / ".build" / "interaction-checks"
output_directory.mkdir(parents=True, exist_ok=True)
source_files = sorted(
    source for source in (project_directory / "Cookie").glob("*.swift")
    if source.name != "CookieApp.swift"
)
executable = output_directory / "cookie-interaction-checks"
subprocess.run([
    "swiftc", "-sdk", "/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk",
    "-target", "arm64-apple-macosx15.0", "-swift-version", "5",
    "-module-cache-path", str(output_directory / "module-cache"),
    *map(str, source_files),
    *map(str, sorted((project_directory / "Tests" / "CookieInteractionTests").glob("*.swift"))),
    "-o", str(executable),
], check=True)
result = subprocess.run([str(executable), *sys.argv[1:]], cwd=project_directory, text=True, capture_output=True)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
result.check_returncode()
if any(message not in result.stdout for message in ["31 interaction checks passed.", "7 setup checks passed.", "3 work presentation checks passed.", "4 peek presentation checks passed.", "8 voice flow checks passed.", "5 Cookie creation checks passed.", "10 feature checks passed.", "7 dock presentation checks passed.", "3 permission checks passed.", " speed checks passed.", "helper checks:"]):
    raise SystemExit("Native checks did not finish. Run with access to the macOS graphical session; an empty exit is not a pass.")
