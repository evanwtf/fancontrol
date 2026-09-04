#!/bin/bash
#
# Test the release helper scripts, negative cases first.
#
#   Scripts/test-helpers.sh
#
# version.sh and release-notes.sh run unattended in the release workflow, and
# refusing correctly is their whole job: a version.sh that returns an empty
# string produces a tag named "v", and a release-notes.sh that returns nothing
# publishes a release with no notes. Neither failure is visible until someone
# reads the published release, so the refusals are what these tests cover.
#
# Plain bash -- the Swift test target tests the binary, not the shell.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

failures=0
tmpdir="$(mktemp -d /tmp/fancontrol-helper-tests.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

# check <name> <expected-status> <command...>
check() {
    local name="$1" want="$2"
    shift 2
    local output status
    output="$("$@" 2>&1)"
    status=$?
    if [ "$status" -eq "$want" ]; then
        echo "ok   $name"
    else
        echo "FAIL $name: expected exit $want, got $status"
        printf '%s\n' "$output" | sed 's/^/       /'
        failures=$((failures + 1))
    fi
}

# check_output <name> <expected-stdout> <command...>
check_output() {
    local name="$1" want="$2"
    shift 2
    local got
    got="$("$@" 2>/dev/null)"
    if [ "$got" = "$want" ]; then
        echo "ok   $name"
    else
        echo "FAIL $name: expected '$want', got '$got'"
        failures=$((failures + 1))
    fi
}

echo "version.sh"
check_output "reads the real version" \
    "$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*/\1/p' \
        Sources/fancontrol/FanControl.swift | head -1)" \
    Scripts/version.sh

: > "$tmpdir/no-version.swift"
check "refuses a source with no version field" 1 \
    env FANCONTROL_VERSION_SOURCE="$tmpdir/no-version.swift" Scripts/version.sh

echo '        version: "",' > "$tmpdir/empty-version.swift"
check "refuses an empty version" 1 \
    env FANCONTROL_VERSION_SOURCE="$tmpdir/empty-version.swift" Scripts/version.sh

echo '        version: "not-a-version",' > "$tmpdir/bad-version.swift"
check "refuses a non-semver version" 1 \
    env FANCONTROL_VERSION_SOURCE="$tmpdir/bad-version.swift" Scripts/version.sh

check "refuses a missing source file" 1 \
    env FANCONTROL_VERSION_SOURCE="$tmpdir/absent.swift" Scripts/version.sh

echo
echo "release-notes.sh"
check "refuses no argument" 1 Scripts/release-notes.sh

check "finds the current version's notes" 0 \
    Scripts/release-notes.sh "$(Scripts/version.sh)"

check "refuses a version with no section" 1 Scripts/release-notes.sh 99.99.99

printf '# Changelog\n\n## 1.0.0\n\n## 2.0.0\n\nreal notes\n' > "$tmpdir/changelog.md"
check "refuses a section that is present but empty" 1 \
    env FANCONTROL_CHANGELOG="$tmpdir/changelog.md" Scripts/release-notes.sh 1.0.0

check_output "reads a later section" "real notes" \
    env FANCONTROL_CHANGELOG="$tmpdir/changelog.md" Scripts/release-notes.sh 2.0.0

# "## 1.0.0" must not answer for "1.0" or "1.0.0-rc1": a prefix match here
# would publish one version's notes under another version's tag.
check "does not match a version prefix" 1 \
    env FANCONTROL_CHANGELOG="$tmpdir/changelog.md" Scripts/release-notes.sh 2.0
check "does not match a version suffix" 1 \
    env FANCONTROL_CHANGELOG="$tmpdir/changelog.md" Scripts/release-notes.sh 2.0.0-rc1

check "refuses a missing changelog" 1 \
    env FANCONTROL_CHANGELOG="$tmpdir/absent.md" Scripts/release-notes.sh 1.0.0

echo
echo "script hygiene"

# macOS ships bash 3.2 and every script here has a #!/bin/bash shebang, so the
# syntax that matters is 3.2's, not the newer bash a developer may have on
# PATH.
for script in Scripts/*.sh; do
    check "$(basename "$script") parses under bash 3.2" 0 /bin/bash -n "$script"
done

# An ellipsis written straight after an unbraced variable is fine in zsh and
# an unbound-variable error under `set -u` in bash -- where these scripts
# actually run, on the bash 3.2 macOS ships. Tested interactively it looks
# correct; both install.sh messages shipped with the bug. Brace it instead.
#
# BSD grep has no -P, and the first version of this check used it: grep exited
# 2, the error was swallowed, the output was empty, and the check reported ok
# on a file that did have the bug. So match bytes in the C locale, where
# [^ -~] is anything outside printable ASCII, and treat grep's own failure as
# a failed check rather than a pass.
offenders="$(LC_ALL=C grep -n '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' Scripts/*.sh)"
grep_status=$?
if [ "$grep_status" -gt 1 ]; then
    echo "FAIL the hygiene grep failed (exit $grep_status); the check proved nothing"
    failures=$((failures + 1))
elif [ -z "$offenders" ]; then
    echo "ok   no unbraced variable is followed by a non-ASCII character"
else
    echo "FAIL an unbraced variable is followed by a non-ASCII character:"
    printf '%s\n' "$offenders" | sed 's/^/       /'
    echo "       brace it: write the \${name} form there"
    failures=$((failures + 1))
fi

echo
if [ "$failures" -eq 0 ]; then
    echo "all helper tests passed"
else
    echo "$failures helper test(s) failed"
    exit 1
fi
