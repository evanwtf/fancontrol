#!/bin/bash
#
# Build the release binary and, optionally, install it.
#
# fancontrol is a CLI, so there is no .app bundle to assemble -- the binary is
# the whole product. This script exists so a rebuild + sign + install is one
# command instead of three, and so the signing rule is the same one the notary
# service will want later. Modelled on ~/git/monitor/Scripts/make-app.sh.
#
# Usage:
#   Scripts/build.sh                       # build into .build/release/fancontrol
#   Scripts/build.sh /usr/local/bin        # and install it there (needs sudo)
#
# Signing:
#   FANCONTROL_SIGN_IDENTITY   codesign identity. Set it and signing must
#                              succeed; the script fails rather than quietly
#                              shipping an ad-hoc binary.
#   unset                      a "Developer ID Application" identity in the
#                              keychain is used if one is there, and an ad-hoc
#                              signature if not.
#
# An ad-hoc signature is fine for local use: the binary runs and Gatekeeper
# does not prompt for a CLI launched from a terminal. It is not enough to
# distribute -- for that, sign with a Developer ID and notarise.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# One version, and it lives in the source so `fancontrol --version` and the
# installed binary cannot disagree.
VERSION="$(sed -n 's/.*version: "\(.*\)".*/\1/p' \
    Sources/fancontrol/FanControl.swift | head -1)"
[ -n "$VERSION" ] || { echo "no version in Sources/fancontrol/FanControl.swift" >&2; exit 1; }
readonly VERSION

destination="${1:-}"

echo "Building release ${VERSION}…"
swift build -c release --product fancontrol

binary="$(swift build -c release --product fancontrol --show-bin-path)/fancontrol"
[ -x "$binary" ] || { echo "no binary at $binary" >&2; exit 1; }

# The identity to sign with: whatever was asked for, or a Developer ID in the
# keychain, or nothing.
identity="${FANCONTROL_SIGN_IDENTITY:-}"
required=1
if [ -z "$identity" ]; then
    required=0
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi

if [ -n "$identity" ]; then
    # --options runtime and a secure timestamp are not optional extras: the
    # notary service rejects a binary without either, and both are impossible
    # to add afterwards without signing again.
    echo "Signing as ${identity}…"
    if ! codesign --force --options runtime --timestamp \
            --sign "$identity" "$binary"; then
        echo "error: could not sign $binary as $identity" >&2
        exit 1
    fi
    codesign --verify --strict --verbose=2 "$binary" 2>&1 | sed 's/^/  /'
elif [ "$required" -eq 1 ]; then
    echo "error: FANCONTROL_SIGN_IDENTITY is set but empty" >&2
    exit 1
else
    # Ad-hoc. Fine for local use on this machine.
    codesign --force --sign - --timestamp=none "$binary" >/dev/null 2>&1 \
        || echo "warning: could not sign $binary; it will still run" >&2
    echo "Signed ad-hoc — fine locally, not installable on another Mac."
fi

echo "Built $binary (fancontrol ${VERSION})"

if [ -n "$destination" ]; then
    mkdir -p "$destination"
    target="${destination%/}/fancontrol"
    if ! cp "$binary" "$target" 2>/dev/null; then
        echo "error: could not copy to $target — try: sudo Scripts/build.sh $destination" >&2
        exit 1
    fi
    chmod 755 "$target"
    echo "Installed $target"
else
    echo "Install it with: sudo Scripts/build.sh /usr/local/bin"
fi
