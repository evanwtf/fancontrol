# fancontrol

A small Swift CLI that reads and overrides Mac fan speeds through AppleSMC.
It exists so a script or an agent can pin the fans at maximum for a benchmark
run and hand control back to macOS when the run ends.

Only ever built and run on **one machine**: a MacBook Pro (M5 Max, 128 GB, macOS 26.6.2). Other Apple Silicon Macs use the same AppleSMC key IDs and should work; Intel Macs share the same interface and read without sudo. Neither is exercised. Reports from other hardware are welcome; nothing here is claimed for machines this repo has not seen.

## Install

```sh
git clone https://github.com/evanwtf/fancontrol.git
cd fancontrol
swift build -c release
sudo cp .build/release/fancontrol /usr/local/bin/
```

## Use

On Apple Silicon every SMC call needs root (verified on macOS 26 / M5 Max: `IOConnectCallStructMethod` returns `kIOReturnNotPrivileged` to non-root callers, and `powermetrics --samplers smc` refuses too). On Intel Macs reads work without sudo.

```sh
sudo fancontrol status            # print every fan, mode and RPMs
sudo fancontrol max               # force every fan to its max RPM
sudo fancontrol set 4500          # force every fan to 4500 RPM (clamped)
sudo fancontrol set 4500 --fan 0  # one fan only
sudo fancontrol auto              # hand control back to macOS
```

Every subcommand accepts `--json`, which is the intended path for scripted use.

```sh
sudo fancontrol status --json
{"fans":[{"actual_rpm":1230,"index":0,"max_rpm":6800,"min_rpm":1200,"mode":"auto","target_rpm":1230}]}

sudo fancontrol max --json
{"action":"max","results":[{"fan":0,"max_rpm":6800,"min_rpm":1200,"mode":"forced","target_rpm":6800}]}
```

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

`fancontrol auto` sets `F<n>Md` back to `0`; macOS's own thermal policy resumes
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
  `SMCParamStruct` layout, selector `2`, key IDs (`F<n>Md`, `F<n>Tg`, `FNum`)
  and the fpe2 encoding all descend.
- [`beltex/SMCKit`](https://github.com/beltex/SMCKit) — a modern Swift port of
  the same interface.

## Development

```sh
swift build
swift test
```

CI runs on the `evanwtf` self-hosted macOS ARM64 runner
(`.github/workflows/ci.yml`).
