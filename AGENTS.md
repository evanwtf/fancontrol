# AGENTS.md — fancontrol

Notes for coding agents and scripts working inside this repository, and for
scripts calling the built binary.

## What this repository is

A Swift CLI that talks to the AppleSMC user-client and exposes fan reading,
maximum override, per-fan target RPM, and auto restoration. Its only reason to
exist is to be driven from a benchmarking harness, so every command emits JSON
when asked and every failure has a stable exit code.

## Target hardware

Only built and tested on one machine: **MacBook Pro M5 Max, 128 GB, macOS 26.6.2**. Every reported behaviour and every version-specific note (macOS version, `kIOReturnNotPrivileged` semantics, HID sensor page contents) is on that machine. Do not generalise a claim you have not observed on a second host; either add the second host to this file and to the README, or scope the claim.

## Ground rules for changes

1. **The JSON schema is a contract.** Field names (`fans[]`, `index`,
   `actual_rpm`, `target_rpm`, `min_rpm`, `max_rpm`, `mode`, and the
   `action` / `results` / `error` envelopes) are consumed by scripts. Do not
   rename them; add new fields, keep the old ones. If a rename is truly
   necessary, bump the major version and note it in the release.
2. **Exit codes are a contract.** `0` success, `1` runtime error, `2` needs
   root, `64` usage error. New failure classes get new codes; do not overload
   `1`.
3. **All SMC calls need root on Apple Silicon; only writes need root on Intel.** Every code path
   `SMC.write` must be gated by `requireRoot(json:)` in a subcommand entry
   point, not deeper.
4. **AppleSMC key IDs are load-bearing.** `FNum`, `F<n>Ac`, `F<n>Mn`,
   `F<n>Mx`, `F<n>Tg`, `F<n>md`. The mode key is lowercase `md` on Apple
   Silicon; smcFanControl's Intel-era spelling `F<n>Md` is not in the key
   table there, and keyInfo on it answers 0x84 (key not found) — verified by
   enumerating the live key table on Mac17,3 (M5 Max, macOS 26.6.2). The
   spelling list is pinned by `testModeKeyCandidates`; read and write paths
   must share it. If a key is added or changed, cite the source in a comment
   (smcFanControl, an Apple header, or a live key-table probe) — not a blog
   post.
5. **The `SMCParamStruct` layout must match the driver's C struct byte for
   byte.** It is a plain Swift struct passed straight to
   `IOConnectCallStructMethod` — no manual encode/decode — and Swift's
   natural alignment is what makes the offsets line up. The whole struct is
   80 bytes (`MemoryLayout<SMCParamStruct>.stride`), verified by
   `testParamStructSizeIs80`, which must stay green. Fields are stored in
   **native byte order**; do not byte-swap `key`, `keyInfo.dataSize`,
   `keyInfo.dataType`, or `data32`. Earlier versions of this file mandated a
   hand-packed layout with different offsets and big-endian byte-swapping;
   that layout produced `kIOReturnNotPrivileged` from the driver even under
   sudo, and was replaced with the sibling `~/git/monitor` project's
   proven-correct layout in PR #2.
6. **Fans are discovered by probing `F<n>Ac` and stopping at the first gap.**
   Do not read `FNum` — it is missing on some machines that do have fans
   (M-series Macs among them), so trusting it silently under-reports.
   Auxiliary keys (`F<n>Mn`, `F<n>Mx`, `F<n>md`, `F<n>Tg`) are best-effort;
   a machine that publishes the tach but not the write side gets a row with
   min/max/target as zero and mode as auto.
7. **fpe2 is 14 bits integer + 2 bits fraction, big-endian.** Divide by 4.0
   to decode, multiply by 4.0 to encode, and clamp the encoded value to
   `UInt16.max`.

## Ground rules for callers

1. **Prefer `--json` in every scripted call.** The plain text is for humans;
   the columns may drift.
2. **Always pair `max` (or `set`) with `auto` in a trap.** A process that
   exits with fans forced leaves them forced until reboot or another `auto`.

   ```sh
   sudo fancontrol max
   trap 'sudo fancontrol auto' EXIT INT TERM
   ```

3. **Do not poll `status` faster than about 1 Hz.** Every read opens the SMC
   user client; the SMC is a slow microcontroller and long tight loops have
   made older Macs report zero-RPM samples.
4. **Clamp on the caller if you care about the exact value you got.** `set`
   clamps to `[min_rpm, max_rpm]` and reports the clamped value in
   `results[].target_rpm`. Do not assume the RPM you asked for is the RPM
   that was written.
5. **The `mode` field is what macOS actually reports; do not infer.** After
   a `max`, `mode` is `forced`. After a hardware thermal event the machine
   can revert to `auto` on its own — read `status` between phases if that
   matters to you.

## Sudo, in a script

There are three usable patterns; pick one per environment and stick with it:

- **NOPASSWD for `fancontrol` only.** Add `evanhoffman ALL=(root) NOPASSWD:
  /usr/local/bin/fancontrol` to `sudoers.d/fancontrol`. Best for a laptop
  running the benchmark.
- **A LaunchDaemon that owns the SMC.** Wrap the binary in a daemon and talk
  to it over a Unix socket. Not yet built.
- **Ask once at the start.** `sudo -v` before the trap, then rely on the
  timestamp.

## Development

```sh
swift build            # debug
swift build -c release # ships as /usr/local/bin/fancontrol
swift test
```

The wire-format tests do not need hardware. To exercise the SMC path locally,
run the binary against your own Mac; there is no simulator for AppleSMC.

## CI

CI runs on the `evanwtf` self-hosted macOS ARM64 runner
(`runs-on: [self-hosted, macOS, ARM64]`). The workflow builds, tests, and
runs `fancontrol status --json` on the runner as a smoke test — it will
exercise the whole read path against real hardware on every push.

## What is deliberately out of scope

- **A daemon or GUI.** This tool is called from a shell; a daemon is a
  separate project.
- **Per-fan curves or hysteresis.** macOS does that. The point of this tool
  is to switch it off for the duration of a benchmark, not to replace it.
- **Intel Mac testing.** The keys are the same, but nobody has run it on
  Intel yet. If you do, add a note here.

## Housekeeping for agents editing this file

- Keep sections **short**. AGENTS.md is read as context on every session.
- When you learn a caller-visible fact (a new field, a new exit code, a
  gotcha), record it here rather than in a commit message alone.
- When you remove a feature, remove its entry rather than crossing it out.

## Investigation: what is available on Apple Silicon without root

Re-verified 2026-09-03 on macOS 26.6.2, MacBook Air Mac17,3 (MDH74LL/A):

- **Reads are unprivileged** on Apple Silicon. Once the struct layout
  matches the driver's, `IOConnectCallStructMethod` on AppleSMC succeeds as
  any user; the same `SMC` type reads fan tachometers, temperatures and
  power in the sibling `~/git/monitor` project without root or a helper.
- **Writes need root.** Setting `F<n>md` or `F<n>Tg` is the part the driver
  gates, and it returns `kIOReturnNotPrivileged` (0xe00002c2) to a non-root
  caller.
- Earlier notes here claimed reads also needed root under macOS 26; that
  was a symptom of a malformed `SMCParamStruct` (packed offsets, big-endian
  byte-swaps) being rejected by the driver in a way that mapped onto the
  same `NotPrivileged` code. Fixed in the wire-format PR.
- `powermetrics --samplers smc` is unrecognised on Apple Silicon regardless
  of privilege, so it is not an alternative.

Conclusion: `fancontrol status` needs no sudo. `fancontrol max`, `set` and
`auto` still do, because they write. A `sudoers.d` NOPASSWD entry for
`/usr/local/bin/fancontrol` remains the simplest agent-driven setup; a
LaunchDaemon that owns the SMC handle and answers over a Unix socket is the
other option, and neither is needed for read-only status.
