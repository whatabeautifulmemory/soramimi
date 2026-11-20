# Soramimi

A tiny macOS menu bar utility that does two things:

1. **Bluetooth keep-alive** (e.g. a Marshall Bluetooth speaker) — plays a continuous inaudible signal plus a periodic 16 kHz wake ping so the speaker does not enter standby or disconnect.
2. **Apple Music / iTunes blocker** (the same functionality [noTunes](https://github.com/tombonez/noTunes) provides) — stops unwanted auto-launches of Apple Music/iTunes and can open a replacement app or URL instead.

Menu bar only. No network, no telemetry, no administrator rights, no Accessibility permissions, and no interference with other players or the Now Playing / media-key session. All features are **OFF by default**.

## Quick start

### Download

Download `Soramimi-1.0.0.zip` from the GitHub Releases page, move `Soramimi.app` to `/Applications`, and open it.

### Homebrew

```bash
brew update
brew tap whatabeautifulmemory/soramimi https://github.com/whatabeautifulmemory/soramimi
brew install --cask soramimi
```

### From source

```bash
make build
make install
```

1. Click the menu bar icon and enable **Bluetooth Keep-Alive**.
2. Check that `Output Device` is the Bluetooth speaker and the system volume is not muted.
3. **Wake Ping** is on by default (every 5 min, −18 dBFS); adjust if needed.
4. Optionally enable **Block Apple Music**, choose Always/Smart and a replacement app or URL, and **Launch at Login**.

## Features

### Bluetooth Keep-Alive (e.g. Marshall Bluetooth speaker)
- Continuous 440 Hz, seamless 0.1 s loop at −100 dBFS (configurable −100…−60).
- 16 kHz, 0.5 s wake ping every 5 minutes by default (Off/1/2/5/10 min; −30…−6 dBFS).
- Follows default-device changes, Bluetooth reconnects and system sleep/wake; never changes the output device or volume.

### Apple Music / iTunes Blocker (same functionality as [noTunes](https://github.com/tombonez/noTunes))
- **Always Block** or **Smart Block**; blocks before the app window appears.
- Optional replacement app or `http(s)` URL.
- iTunes entries are hidden when iTunes is not installed.

### Menu
On/off switches for both features, signal/ping settings, blocking policy, last blocked launch, output device, replacement target, login item, About (build time) and quit.

## Requirements

- macOS 13 or newer.
- Xcode Command Line Tools to build.
- No administrator rights for build, install or run.

## License

MIT — see [LICENSE](LICENSE).
