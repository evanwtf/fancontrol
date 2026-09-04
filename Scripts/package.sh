#!/bin/bash
#
# Build the release zip: binary, install script, README.
#
#   Scripts/package.sh                  # build, sign, zip
#   Scripts/package.sh --notarize       # and submit it to Apple
#
# Output: dist/fancontrol-<version>-macos-arm64.zip
#
# The release workflow calls this script and nothing else, so a release can be
# reproduced on a laptop exactly as CI cut it. Signing is Scripts/build.sh's
# job; this script requires that it used a real identity.
#
# Notarization needs a notarytool credential profile in the keychain of the
# Mac that runs this, named by:
#   FANCONTROL_NOTARY_PROFILE     e.g. monitor-notary
#
# The profile holds an app-specific password and authenticates you to the
# team, not to a product, so one profile notarizes every app this team signs.
# Create one with:
#   xcrun notarytool store-credentials <name> \
#       --apple-id <you> --team-id <TEAMID> --password <app-specific>
#
# A ticket cannot be stapled to a bare CLI binary -- `stapler` handles .app,
# .dmg, and .pkg only. So the zip is notarized and shipped as-is: Apple
# registers the ticket against the binary's cdhash and Gatekeeper checks it
# online at first launch. A Mac with no network cannot verify it.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

fail() { echo "error: $*" >&2; exit 1; }

notarize=0
case "${1:-}" in
    --notarize) notarize=1 ;;
    "") ;;
    *) fail "unknown argument '$1'; usage: $(basename "$0") [--notarize]" ;;
esac

VERSION="$(Scripts/version.sh)"
readonly VERSION

# Refuse before building rather than after notarizing: the notes are the one
# release input a human has to write, and finding them missing at the end
# wastes a signing round trip.
Scripts/release-notes.sh "$VERSION" > /dev/null \
    || fail "no release notes for $VERSION; see the message above"

arch="$(uname -m)"
stage="dist/fancontrol-${VERSION}-macos-${arch}"
zip="${stage}.zip"

rm -rf "$stage" "$zip"
mkdir -p "$stage"

Scripts/build.sh

binary="$(swift build -c release --product fancontrol --show-bin-path)/fancontrol"
[ -x "$binary" ] || fail "no binary at $binary"

# A zip that leaves here is going to other machines. An ad-hoc signature runs
# only where it was built, and notarization would reject it, so check what
# build.sh actually produced instead of trusting that it had an identity.
if ! codesign --verify --strict "$binary" 2>/dev/null; then
    fail "$binary is not validly signed"
fi
if codesign --display --verbose=2 "$binary" 2>&1 | grep -q '^Signature=adhoc'; then
    fail "$binary is ad-hoc signed; set FANCONTROL_SIGN_IDENTITY to a Developer ID Application identity"
fi

cp "$binary" "$stage/fancontrol"
cp Scripts/install.sh "$stage/install.sh"
cp README.md "$stage/README.md"
chmod 755 "$stage/fancontrol" "$stage/install.sh"

# ditto, not zip: it handles a signed Mach-O without mangling it.
#
# The metadata flags are not optional. ditto stores filesystem metadata as
# AppleDouble "._" sidecars inside the archive -- invisible in Finder, three
# junk files to anyone who runs `unzip`. A local build produces none, so this
# only appears in CI: files under the runner's work directory inherit an ACL.
# Clearing extended attributes with `xattr -cr` does not help, because an ACL
# is not an extended attribute and survives it. Telling ditto to copy no
# metadata at all is what works.
#
# None of it is needed downstream: a Mach-O signature lives inside the binary,
# so the copy that reaches Apple and the user is byte-for-byte the signed one
# (the check below proves it).
ditto -c -k --keepParent --noextattr --noacl --norsrc --noqtn "$stage" "$zip"

# Check what actually landed in the zip. The three files are the whole
# product, and a recipient who unzips it and finds no install.sh has no way
# to proceed -- a missing file must fail the release, not reach a user.
listing="$(unzip -Z1 "$zip")"
for required in fancontrol install.sh README.md; do
    printf '%s\n' "$listing" \
        | grep -qx "$(basename "$stage")/${required}" \
        || fail "$zip does not contain ${required}"
done
# And nothing else: an AppleDouble sidecar means the xattr strip above did
# not take, and the zip would hand the user files they did not ask for.
if printf '%s\n' "$listing" | grep -q '/\._\|^__MACOSX'; then
    printf '%s\n' "$listing" | sed 's/^/  /' >&2
    fail "$zip contains AppleDouble entries"
fi

# The signature has to survive the xattr strip and the round trip through
# ditto -- this is the copy that goes to Apple and to users.
codesign --verify --strict "$stage/fancontrol" \
    || fail "the staged binary lost its signature during packaging"
echo "Packaged $zip"
printf '%s\n' "$listing" | sed 's/^/  /'

if [ "$notarize" -eq 1 ]; then
    profile="${FANCONTROL_NOTARY_PROFILE:-}"
    [ -n "$profile" ] || fail "FANCONTROL_NOTARY_PROFILE is not set"

    echo "Notarizing ${zip}…"
    # --wait blocks until Apple accepts or rejects. Without it the command
    # returns immediately and the release publishes a zip nobody has checked.
    if ! xcrun notarytool submit "$zip" \
            --keychain-profile "$profile" \
            --wait; then
        fail "notarization failed; run 'xcrun notarytool log <submission-id>' for the reason"
    fi

    # No spctl check here. `spctl --assess --type exec` assesses app bundles;
    # on a bare Mach-O executable it answers "rejected (the code is valid but
    # does not seem to be an app)" however good the signature is, which is a
    # false negative that failed a release whose zip Apple had just accepted.
    # notarytool --wait already exits non-zero unless Apple returned Accepted,
    # so the check above this is the one that means something.
    echo "Notarized $zip"
else
    echo "Not notarized. A Mac that downloads this zip will refuse to run it."
    echo "Run with --notarize to submit it."
fi
