#!/bin/bash
#
# Print the docs/changelog.md section for one version.
#
#   Scripts/release-notes.sh 0.1.0
#
# The release workflow pipes this into `gh release create --notes-file`. Notes
# are never written into the tag message: a backtick in `git tag -m` is
# expanded by the shell and silently deletes text, and the damage is invisible
# until someone reads the published release.
#
# Exits 1 when the version has no section. That is the point of the script --
# a release with no notes is refused rather than published empty.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
changelog="${FANCONTROL_CHANGELOG:-$root/docs/changelog.md}"

version="${1:-}"
[ -n "$version" ] || {
    echo "usage: $(basename "$0") <version>" >&2
    exit 1
}

[ -f "$changelog" ] || {
    echo "error: no changelog at $changelog" >&2
    exit 1
}

# Print the lines after "## <version>" up to the next "## " heading. The
# version is matched literally: awk's index() rather than a regex, so a dot in
# 0.1.0 cannot match 0x1y0 and pull the wrong section.
notes="$(awk -v want="## $version" '
    substr($0, 1, 3) == "## " {
        found = (index($0, want) == 1 && length($0) == length(want))
        next
    }
    found { print }
' "$changelog")"

# Strip the blank lines the section is padded with, top and bottom.
notes="$(printf '%s' "$notes" | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"

[ -n "$notes" ] || {
    echo "error: no notes for version $version in $changelog" >&2
    echo "       add a '## $version' section before releasing" >&2
    exit 1
}

printf '%s\n' "$notes"
