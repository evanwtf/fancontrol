#!/bin/bash
#
# One command from a clean checkout to passwordless fan control:
#
#   Scripts/install.sh
#
# What it does, in order:
#   1. Builds and signs the release binary (as you, not root -- building under
#      sudo would leave root-owned build artifacts).
#   2. Installs it to /usr/local/bin/fancontrol. The sudoers grant below trusts
#      whatever sits at that path, so it must be root-owned: a binary in a
#      user-writable directory would let any process running as you swap it
#      and self-elevate to root without a password.
#   3. Writes /etc/sudoers.d/fancontrol with NOPASSWD for exactly the
#      fan-write subcommands: max, auto, reset. Both the bare form and the
#      wildcard form are granted, so `sudo fancontrol max --json` also runs
#      without a prompt. `set` stays outside the grant on purpose -- slowing
#      the fans keeps the password prompt -- and `status` never needed sudo.
#   4. Verifies the sudoers policy still parses and smoke-tests the installed
#      binary with an unprivileged read.
#
# Idempotent: re-running rebuilds, reinstalls, and rewrites the sudoers file
# only when its content differs. Delete /etc/sudoers.d/fancontrol to revoke.
#
# Needs sudo for steps 2 and 3; one password total, everything else runs as
# the invoking user.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

fail() { echo "error: $*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] \
    || fail "run as yourself, not under sudo; the script elevates only where it must"

user="$(id -un)"
# macOS ships bash 3.2, which parses a heredoc body inside $( ) as code, so
# the sudoers content is staged in a temp file and installed from there.
# sudoers.d is read by every sudo invocation: a file that fails to parse
# breaks sudo for the whole machine. The username is the one thing here that
# comes from outside the script, so refuse anything the sudoers grammar
# cannot express plainly and leave no half-written file behind.
re='^[a-zA-Z_][a-zA-Z0-9_.-]*$'
[[ "$user" =~ $re ]] \
    || fail "username '$user' does not fit a sudoers user spec; add the entry yourself with 'sudo visudo -f /etc/sudoers.d/fancontrol'"

echo "Building…"
Scripts/build.sh

bin="$(swift build -c release --product fancontrol --show-bin-path)/fancontrol"
[ -x "$bin" ] || fail "no binary at $bin; fix the build first"

sudo mkdir -p /usr/local/bin
echo "Installing /usr/local/bin/fancontrol…"
sudo /usr/bin/install -m 0755 "$bin" /usr/local/bin/fancontrol

sudoers=/etc/sudoers.d/fancontrol
tmp="$(mktemp /tmp/fancontrol-sudoers.XXXXXX)"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<EOF
# Managed by fancontrol's Scripts/install.sh; delete this file to revoke.
# Grants passwordless sudo for the fan-write subcommands only. The bare form
# plus the wildcard form cover the --json flag; set and status are not
# covered: set still prompts, and status never needed sudo.
$user ALL=(root) NOPASSWD: /usr/local/bin/fancontrol max, /usr/local/bin/fancontrol max *
$user ALL=(root) NOPASSWD: /usr/local/bin/fancontrol auto, /usr/local/bin/fancontrol auto *
$user ALL=(root) NOPASSWD: /usr/local/bin/fancontrol reset, /usr/local/bin/fancontrol reset *
EOF

if sudo cmp -s "$tmp" "$sudoers" 2>/dev/null; then
    echo "Sudoers entry unchanged: $sudoers"
else
    echo "Writing $sudoers…"
    sudo /usr/bin/install -m 0440 "$tmp" "$sudoers"
fi

# Check the policy the moment our file lands. If it does not parse, sudo may
# already be broken for every command, so remove our file at once: the worst
# outcome is a failed install, never a broken machine.
if ! sudo visudo -c >/dev/null; then
    sudo rm -f "$sudoers"
    fail "$sudoers did not parse and was removed; add the entry by hand with 'sudo visudo -f $sudoers'"
fi

echo "Smoke test (unprivileged read):"
/usr/local/bin/fancontrol status

echo
echo "Passwordless: sudo fancontrol max | auto | reset"
echo "Still asks:   sudo fancontrol set <rpm>  (and any other subcommand)"