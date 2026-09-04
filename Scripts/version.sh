#!/bin/bash
#
# Print the version fancontrol reports, read from the source that defines it.
#
#   Scripts/version.sh          # 0.1.0
#
# The version lives in exactly one place -- the `version:` field of the
# CommandConfiguration in Sources/fancontrol/FanControl.swift -- so
# `fancontrol --version`, the release tag, and the zip name cannot disagree.
# Every other script reads it from here rather than parsing the file again.
#
# Exits 1 if the field is missing or does not look like a version. A release
# that cannot name itself must not proceed.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="${FANCONTROL_VERSION_SOURCE:-$root/Sources/fancontrol/FanControl.swift}"

[ -f "$source_file" ] || {
    echo "error: no version source at $source_file" >&2
    exit 1
}

version="$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*/\1/p' "$source_file" | head -1)"

[ -n "$version" ] || {
    echo "error: no 'version:' field in $source_file" >&2
    exit 1
}

# Semver, and nothing else. A stray quote or an edit that leaves the field
# empty must fail here, not become a tag named v or a zip named
# fancontrol--macos-arm64.zip.
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
    echo "error: version '$version' in $source_file is not a semver string" >&2
    exit 1
fi

echo "$version"
