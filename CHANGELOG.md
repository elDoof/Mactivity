# Changelog

## Unreleased

- In-app updater: checks GitHub Releases daily, and installs a new version in
  place after verifying its Developer ID signature, bundle identifier and
  notarization. Downgrades are refused and a failed replacement rolls back.
- Removed Purge Memory. `purge` is of debatable value on current macOS and was
  the only feature needing an administrator password.
- Build numbers now stay monotonic past a two-digit version component; 1.0.10
  previously outranked 1.1.0, which macOS reads as a downgrade.

## 1.0.0

First release.

- Menu bar readout for CPU, memory, network and battery.
- Panel with CPU, GPU, memory and disk rings, each with a 60-second history.
- Per-core load bars, memory pressure and an app/wired/compressed breakdown.
- Top five CPU processes, with graceful quit and Option-click force quit.
- Detachable floating widget, compact mode, six accent colours.
- Launch at Login, and `purge` for reclaiming inactive memory.
- Universal binary for Apple Silicon and Intel, signed and notarized.
