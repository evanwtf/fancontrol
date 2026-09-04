---
name: fancontrol
description: Use when reading or overriding Mac fan speeds on this machine - checking fan RPM, pinning fans to maximum before a benchmark, thermal test, or long compile, or returning fans to macOS thermal control. Also when a run left the fans loud and they need restoring.
---

# fancontrol

Reads and overrides fan speeds via AppleSMC on Apple Silicon Macs. Installed
at `/usr/local/bin/fancontrol`. Every subcommand takes `--json`.

## Only three commands are yours to run

| Goal | Command | sudo |
|---|---|---|
| Read fan RPM and mode | `fancontrol status --json` | no |
| Pin every fan to maximum | `sudo -n fancontrol max --json` | passwordless |
| Return fans to macOS control | `sudo -n fancontrol auto --json` | passwordless |

`reset` is a synonym for `auto`. Exit codes: `0` ok, `1` runtime error,
`2` needs root, `64` usage error.

## Never run `set`

`fancontrol set <rpm>` is out of scope. Do not run it, suggest it as a step,
or put it in a script you write.

`max` and `auto` are safe in one direction only: they add cooling, or hand
control back to macOS. `set` is the one command that can hold fans *below*
what thermal policy is asking for, which is how a machine overheats or
throttles under load. That call needs a human who can see the machine.

The sudoers grant covers `max`, `auto`, and `reset` alone, so `set` also
fails without an interactive password. This is deliberate. Do not work around
it.

**Red flags — stop:**
- "A specific RPM would be quieter than max here"
- "Just to test the code path"
- "The user probably wants a fan curve"
- Reaching for `sudo -S`, a password prompt, or an edit to `/etc/sudoers.d/`

If a specific RPM is genuinely wanted, say so and let the user run it.

## Always use `sudo -n`

`sudo -n` refuses instead of prompting. A plain `sudo` waits on a password
prompt that is invisible in a non-interactive session, so the command hangs
until it times out. Use `-n` on every write, including the passwordless ones
— a reinstalled machine may not have the grant yet, and failing in a second
beats hanging.

## Restore the fans

`max` holds until something sets it back. Nothing expires it; only `auto` or
a reboot does. Fans left at maximum are loud and stay that way.

Pair every `max` with a trap in the same shell, so the restore survives a
failing command or a Ctrl-C:

```sh
sudo -n fancontrol max
trap 'sudo -n fancontrol auto' EXIT
./run-benchmark.sh
```

Never run `max` as the last thing in a session. Check `status` afterwards and
confirm `mode` came back to `auto`.

## Output shapes

```jsonc
// status
{"fans":[{"index":0,"mode":"auto","actual_rpm":0,"target_rpm":0,
          "min_rpm":1350,"max_rpm":5349}]}
// max / auto / reset
{"action":"auto","results":[{"fan":0,"mode":"auto","target_rpm":0,
                             "min_rpm":1350,"max_rpm":5349}]}
// any error, on stderr, with --json set
{"error":"this action needs root; re-run under sudo"}
```

`mode` is `auto` or `forced`. `actual_rpm` reads `0` when a fan is stopped,
which is normal on an idle Apple Silicon Mac and not a failure.

## Common mistakes

| Mistake | What happens |
|---|---|
| Running `set` | Out of scope, and can hold fans below what cooling needs |
| Plain `sudo` instead of `sudo -n` | Hangs on an invisible password prompt |
| `max` with no restore | Fans stay at maximum indefinitely |
| Restoring on the next line | A failing command skips it; use `trap` |
| Reading `actual_rpm: 0` as broken | Idle fans genuinely stop |
| Assuming a fan count | Probe `status`; fan indices vary by machine |
