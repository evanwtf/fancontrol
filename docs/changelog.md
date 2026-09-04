# Changelog

Release notes come from this file. `Scripts/release-notes.sh <version>` reads
the section whose heading matches the version, and the release workflow
publishes exactly that text. A version with no section here does not get
released -- write the notes first.

Add the new section at the top, above the previous one, before you bump the
version in `Sources/fancontrol/FanControl.swift`.

## 0.1.0

First release.

- `fancontrol status` reports every fan: current RPM, minimum, maximum, and
  whether the fan is under manual control. No root needed.
- `fancontrol max` pins every fan to its maximum RPM.
- `fancontrol auto` (and its synonym `reset`) returns the fans to firmware
  control.
- `fancontrol set <rpm>` holds a chosen speed.
- Every subcommand takes `--json` and writes structured output to stdout;
  with `--json` set, errors go to stderr as JSON.
- `Scripts/install.sh` installs the binary to `/usr/local/bin` and grants
  passwordless sudo for `max`, `auto`, and `reset` only.

Built and tested on a MacBook Pro M5 Max running macOS 26.6.2. Apple Silicon
only.
