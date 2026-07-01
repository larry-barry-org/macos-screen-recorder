# macOS Screen Recorder

A lightweight native **SwiftUI menu bar app** for macOS that records a region of
your screen with system audio, built on **ScreenCaptureKit**. A no-frills
alternative to the built-in screenshot/recording tool.

## Features

- **Menu bar only** — no dock icon, no windows.
- **Region recording** — drag to select a region. The last region is saved
  automatically and persists across launches.
- **Global shortcuts:**
  - Start / Stop Recording — `⌘⌥P`
  - Pause / Resume Recording — `⌘⌥[` (only while recording)
- **Live dotted border** drawn around the region while recording — the screen is
  **not** dimmed, and the border itself is **excluded from the recording**.
- **Animated icon** — a pulsing red bubble while recording; a film icon when idle.
- **System audio** captured; **no microphone**, **no cursor**.
- **60 fps**, saved to `~/Downloads/ScreenRecording_<timestamp>.mov`.

## Install (prebuilt)

Download `ScreenRecorder.dmg` from the
[latest release](../../releases/latest), open it, and drag **Screen Recorder**
to Applications. On first recording macOS will ask for **Screen Recording**
permission — grant it in **System Settings → Privacy & Security → Screen
Recording**, then relaunch.

## Build from source

Requires macOS 13+ and the Swift toolchain (Xcode Command Line Tools).

```bash
./setup.sh     # one-time: creates a stable signing identity (see below)
./build.sh     # compile + assemble + sign ScreenRecorder.app
open build/ScreenRecorder.app
```

To produce a distributable disk image:

```bash
./package-dmg.sh    # -> build/ScreenRecorder.dmg
```

### Signing & the permission prompt

macOS ties Screen Recording permission to the app's code signature. An **ad-hoc**
signature changes on every rebuild, so macOS treats each build as a new app and
**re-prompts** for permission every time.

`./setup.sh` fixes this by creating a **self-signed code-signing certificate**
(`ScreenRecorder Dev`) in your login keychain. `build.sh` then signs with that
stable identity, so you grant permission **once** and it sticks across rebuilds.

- The script is **idempotent**: if the identity already exists it does nothing,
  so re-running it (e.g. after erasing your Mac) never creates duplicate keychain
  items.
- The certificate/private key is **generated locally** and never leaves your
  machine — it is intentionally not committed to the repo.
- If you skip `setup.sh`, `build.sh` falls back to ad-hoc signing (works fine,
  but you'll be re-prompted after each rebuild).

## Usage

1. Click the menu bar icon → **Select Region…**, then drag out a region
   (Esc cancels).
2. **Start Recording** (`⌘⌥P`). The icon becomes a pulsing red bubble and a
   dotted border appears around the region.
3. **Pause / Resume** (`⌘⌥[`) as needed — paused time is removed from the file.
4. **Stop Recording** (`⌘⌥P`). The `.mov` is saved to `~/Downloads`.

## Project layout

| File | Purpose |
|------|---------|
| `ScreenRecorderApp.swift` | SwiftUI `App` entry; hosts the AppDelegate. |
| `AppDelegate.swift` | Status item, menu, hotkeys, state → UI wiring. |
| `RecordingManager.swift` | ScreenCaptureKit capture + AVAssetWriter, pause/resume. |
| `RegionSelectorController.swift` | Drag-to-select overlay (no dimming). |
| `RegionBorderController.swift` | Click-through dotted region border (excluded from capture). |
| `RegionStore.swift` | Persists the last region in UserDefaults. |
| `HotKeyCenter.swift` | Global Carbon hotkeys. |
| `OverlayWindow.swift` | Borderless key-capable window subclass. |
| `setup.sh` | Creates the stable self-signed signing identity (idempotent). |
| `build.sh` | Compiles, bundles, and signs the app. |
| `package-dmg.sh` | Packages the app into a DMG. |
| `icon/make-icon.sh` | Regenerates `Resources/AppIcon.icns` (the app icon). |
