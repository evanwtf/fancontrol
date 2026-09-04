# fancontrol

A small Swift CLI that reads and overrides Mac fan speeds through AppleSMC.
It exists so a script or an agent can pin the fans at maximum for a benchmark
run and hand control back to macOS when the run ends.

Only ever built and run on **one machine**: a MacBook Pro (M5 Max, 128 GB, macOS 26.6.2). Other Apple Silicon Macs use the same AppleSMC key IDs and should work; Intel Macs share the same interface and read without sudo. Neither is exercised. Reports from other hardware are welcome; nothing here is claimed for machines this repo has not seen.

## Install

Requires macOS 13 or newer and a Swift 5.9+ toolchain (Xcode 15 or a
matching swift.org toolchain).

```sh
git clone https://github.com/evanwtf/fancontrol.git
cd fancontrol
Scripts/install.sh
```

That builds and signs the binary, installs it to `/usr/local/bin/fancontrol`
(root-owned), and writes `/etc/sudoers.d/fancontrol` granting passwordless
sudo for the fan-write subcommands only: `max`, `auto` and `reset`, with or
without flags. `set` stays outside the grant — slowing the fans keeps the
password prompt — and `status` never needed sudo. Re-running the script is
idempotent; delete `/etc/sudoers.d/fancontrol` to revoke passwordless sudo.

To install without the sudoers entry, build and copy by hand:

```sh
swift build -c release
sudo cp .build/release/fancontrol /usr/local/bin/
```

## Use

Reads work as any user. Writes (`max`, `set`, `auto`) need root because the
AppleSMC driver enforces it on the write commands, not on the transport.

```sh
fancontrol status                 # print every fan, mode and RPMs
sudo fancontrol max               # force every fan to its max RPM
sudo fancontrol set 4500          # force every fan to 4500 RPM (clamped)
sudo fancontrol set 4500 --fan 0  # one fan only
sudo fancontrol auto              # hand control back to macOS
sudo fancontrol reset             # synonym for auto
```

After `Scripts/install.sh`, `max`, `auto` and `reset` run under sudo without
a password prompt.

On a fanless Mac (all Apple Silicon MacBook Airs, for example) `status`
prints a "no fans found" message with a search URL for that model, and
the write subcommands refuse rather than pretending to succeed.

Every subcommand accepts `--json`, which is the intended path for scripted use.

```sh
fancontrol status --json
{"fans":[{"actual_rpm":1230,"index":0,"max_rpm":6800,"min_rpm":1200,"mode":"auto","target_rpm":1230}]}

sudo fancontrol max --json
{"action":"max","results":[{"fan":0,"max_rpm":6800,"min_rpm":1200,"mode":"forced","target_rpm":6800}]}
```

On a fanless Mac, `fancontrol status --json` returns `{"fans":[]}`.

Errors are also JSON when `--json` is set, on stderr:

```sh
fancontrol max --json
{"detail":null,"error":"this action needs root; re-run under sudo"}
```

Exit codes:

| code | meaning |
|---|---|
| 0 | success |
| 1 | runtime error (SMC I/O, bad key, unexpected size) |
| 2 | needs root |
| 64 | usage error (argument parsing) |

## Typical benchmarking wrap

```sh
sudo fancontrol max
trap 'sudo fancontrol auto' EXIT
./run-my-benchmark.sh
```

`fancontrol auto` (or `reset`) sets `F<n>md` back to `0`; macOS's own thermal policy resumes
immediately. If the process dies without running `auto`, a reboot also restores
default behaviour — the mode override is not persisted across boots.

## Safety

Forcing fans changes airflow, not thermal capacity. The Mac's own overtemp
protection stays in place; you can burn out fan bearings faster by pinning them
at max for long stretches, but the SoC does not lose its thermal cutout. Do not
use `set` to run fans *slower* than macOS wants — that is what the Mac already
does when it can.

## References

- [`hholtmann/smcFanControl`](https://github.com/hholtmann/smcFanControl) — the
  original reverse-engineering of the AppleSMC user-client, from which the
  `SMCParamStruct` layout, selector `2`, key IDs (`FNum`, `F<n>Ac`, `F<n>Mn`,
  `F<n>Mx`, `F<n>Tg`) and the fpe2 encoding all descend. The mode key's
  lowercase `md` spelling was verified against the live SMC key table, where
  smcFanControl's `F<n>Md` does not exist.
- [`beltex/SMCKit`](https://github.com/beltex/SMCKit) — a modern Swift port of
  the same interface.

## Development

```sh
swift build
swift test
```

Source layout: `Sources/fancontrol/SMC.swift` wraps the AppleSMC user-client
(`SMCParamStruct`, fpe2 codec, key I/O); `Sources/fancontrol/FanControl.swift`
defines the `ArgumentParser` subcommands and JSON envelopes.
`Tests/fancontrolTests` covers the wire format (no hardware needed).

CI runs on the `evanwtf` self-hosted macOS ARM64 runner
(`.github/workflows/ci.yml`): `swift build -c release`, `swift test`, and a
`fancontrol --help` smoke run.

Notes for agents and scripts calling the binary — including the JSON schema
and exit-code contract, sudo patterns, and what is deliberately out of scope
— live in [AGENTS.md](AGENTS.md).
