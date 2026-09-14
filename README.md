# Mactivity

A lightweight system monitor that lives in the macOS menu bar.

Mactivity keeps the numbers you actually watch — CPU, GPU, memory, disk and
network — one click away, and can show them inline in the menu bar itself. It
is a single ~2 MB universal binary with no dependencies, no background daemon
and no network access.

## Features

- **Menu bar readout** — show CPU, memory, network or battery next to the
  clock, in a monospaced font that doesn't jitter as the digits change.
- **At-a-glance panel** — CPU, GPU, memory and disk as usage rings, with a
  60-second history graph for each.
- **Per-core load** — a live bar for every performance and efficiency core.
- **Memory detail** — app, wired and compressed breakdown, live memory
  pressure.
- **Top processes** — the five heaviest CPU consumers, with the option to quit
  one from the list.
- **Detachable widget** — float the panel above other windows on any Space.
- **Compact mode**, six accent colours, and Launch at Login.
- **In-app updates** — Mactivity checks for new versions once a day and can
  install one in place. Nothing is downloaded or replaced without asking.

Idle cost is about 1% of one core. With the floating widget visible and every
graph updating once a second, it settles around 8%.

## Requirements

macOS 14 (Sonoma) or later, on Apple Silicon or Intel.

## Install

Download the latest `Mactivity-x.y.z.dmg` from the
[Releases](https://github.com/elDoof/Mactivity/releases) page, open it, and drag
Mactivity to your Applications folder.

The app is signed with a Developer ID and notarized by Apple, so it opens
normally on first launch. Verify the download if you like:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

Mactivity has no window of its own — after launching, look for the waveform
icon in the menu bar.

## Updates

Mactivity checks GitHub for a new release once a day and offers it in the
settings pane; automatic checking can be turned off there, and **Check for
Updates** is always available. Finding, downloading and installing an update
are three separate, explicit steps — nothing is replaced behind your back.

An update is installed only if it is signed by the same Developer ID team as
the copy you are running, carries the expected bundle identifier, passes
Apple's notarization assessment, and is strictly newer than the installed
version. A build failing any of those checks is discarded. If the replacement
itself fails, the previous version is moved back into place.

Updating requires write access to wherever Mactivity is installed.

## Usage notes

- **Launch at Login** only works for a copy in `/Applications`. macOS registers
  the login item by its location, so a build run from elsewhere cannot be
  registered.
- **Quitting a process** sends `SIGTERM`, letting it shut down and save. Hold
  **Option** while clicking to send `SIGKILL` instead, which is immediate but
  discards unsaved work.
- **Quit Mactivity** from the gear menu, or press <kbd>Q</kbd> while the panel
  is open.

## Build from source

```sh
git clone https://github.com/elDoof/Mactivity.git
cd Mactivity
./build_app.sh --install
```

That produces `MactivityMonitor.app`, installs it to `/Applications` and
launches it. Omit `--install` to leave the bundle in the working directory.

Building only the executable works with the Command Line Tools alone:

```sh
swift build -c release
```

A universal binary additionally needs a full Xcode install, since the two-
architecture build goes through `xcbuild`:

```sh
UNIVERSAL=1 ./build_app.sh
```

### Cutting a release

`release.sh` builds a universal, hardened, Developer ID-signed bundle, submits
it for notarization, staples the ticket, and writes a `.dmg`, a `.zip` and
`SHA256SUMS.txt` into `dist/`. It expects a Developer ID Application
certificate in the keychain and a stored notarytool profile:

```sh
xcrun notarytool store-credentials "mactivity-notary" \
    --apple-id "you@example.com" --team-id "TEAMID" \
    --password "app-specific-password"

./release.sh
```

Set `SKIP_NOTARIZE=1` to sign and package without submitting to Apple.

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/main.swift` | AppKit entry point |
| `Sources/AppDelegate.swift` | Status item, popover, menu bar label |
| `Sources/ActivityMonitor.swift` | Statistics collection |
| `Sources/ContentView.swift` | Panel, floating widget, settings |
| `build_app.sh` | Bundle assembly and signing |
| `release.sh` | Signed, notarized release artifacts |

Statistics come from the system directly — `host_statistics`, `sysctl`,
IOKit registry properties, `getifaddrs` and IOPowerSources — rather than by
shelling out, with the single exception of `ps` for the process list.

## License

[MIT](LICENSE)
