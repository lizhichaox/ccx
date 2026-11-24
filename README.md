# CCX

**Control · Command · X** (`⌃⌘X`) — A fast, native Swift 6 macOS menu bar utility focused strictly on three core workflows: **Capture**, **Pin**, and **Record**.

- **100% Native macOS**: Built with Swift 6, AppKit, SwiftUI, ScreenCaptureKit, Metal/CoreImage, AVFoundation/VideoToolbox, and Apple Vision — zero Electron, zero third-party runtime dependencies.
- **Local Captures & OCR · Zero Telemetry**: All screenshots, OCR text recognition, and recordings stay on your Mac. No accounts, no cloud uploads, no analytics or telemetry; optional in-app update checks connect only to GitHub Releases and can be disabled anytime in Settings.
- **Universal Binary**: Supports macOS 15.0 Sequoia and later on both Apple Silicon (`arm64`) and Intel (`x86_64`) Macs.
- **Automatic English & Simplified Chinese**: Follows macOS **System Settings → Language & Region** automatically (`en` and `zh-Hans`), falling back to English for other languages.

---

## Core Features

### 1. Capture (Smart Snip, Scroll Capture & Annotations)
- **Instant Smart Auto-Detection (`⌃⌘X`, customizable in Settings)**: Freezes all displays via ScreenCaptureKit and automatically highlights windows and UI elements with non-blocking Accessibility queries. Customize your global Snip shortcut anytime in **Settings** with real-time macOS system, reserved-shortcut, and running-app conflict detection plus one-click reset.
- **GPU Pixel Magnifier & Color Picker**: 120Hz GPU-composited pixel loupe with Retina HiDPI / Display P3 support and one-key color copy (`HEX`, `RGB`, `HSL`).
- **Non-Destructive Annotations**: Rectangle, ellipse, arrow, freehand pen, highlighter, inline text, auto-incrementing step counters, and live GPU mosaic/blur with continuous stroke sizing and undo/redo.
- **Scrolling Capture (`L`)**: Captures tall pages and documents with live preview, sticky header/sidebar detection, manual or auto-scroll, and memory-bounded stitching.
- **Local OCR (`T`)**: On-device Apple Vision text recognition supporting Simplified Chinese, Traditional Chinese, and English.

### 2. Pin (Always-on-Top Floating Windows)
- **Float Across Spaces & Full-Screen Apps**: Pin snips, clipboard images, HEX color swatches, or text snippets as crisp floating `NSPanel`s.
- **Interactive Controls**: Smooth GPU-accelerated zoom, 90° rotation, horizontal/vertical flip, opacity adjustment, thumbnail collapse, click-through mode (unlockable from the menu bar or context menu), and inline re-editable annotations on image pins.
- **Recent Snips History**: Instant access to recent captures from the menu bar popover, persisted locally in a private user-only cache (`0700`/`0600`) with bounded memory usage and one-click clear.

### 3. Record (Screen Recording — MP4, MOV & GIF)
- **Hardware-Accelerated Video & GIF**: Record any region or full display to `MP4` (H.264), `MOV` (HEVC), or memory-bounded `GIF` with adjustable recording border and live menu bar timer.
- **Dual Audio & Pause/Resume**: Optional system audio and microphone narration with real-time mixing, true pause/resume timeline offsetting, graceful microphone fallback, and stream-interruption salvage.
- **Dedicated Recordings Folder**: Saves recordings by default to `~/Movies/CCX` (configurable in **Settings** and independent from PNG save locations), with quick-open access from the menu bar popover's **Record** tile and Settings.
- **Non-Destructive Output**: Atomic Copy, Save, Quick Save, and Reveal in Finder actions that preserve your recording if a destination write fails.

---

## Installation

1. Download the latest `CCX-0.8.0-macOS-universal.dmg` (or `.zip`).
2. Open the disk image and drag **CCX.app** into **Applications**.
3. Launch **CCX** from `/Applications` or Spotlight.

> **Menu Bar App**: CCX runs in the macOS menu bar with no Dock icon. If CCX is already running, opening `CCX.app` again from `/Applications` or Spotlight brings up the Setup Guide (if permissions are still needed) or opens the menu bar popover.

### Verified In-App Updates

- **Seamless Background Updates**: CCX includes a built-in, zero-dependency updater that checks GitHub Releases automatically once per day (toggleable anytime in **Settings → Updates**, with an on-demand **Check** button). When automatic updates are enabled, new releases are pre-downloaded and verified quietly in the background, then installed seamlessly once CCX is completely idle (zero active Pins, captures, recordings, OCR tasks, save dialogs, or windows) or cleanly on disk when you quit — plus an instant zero-wait **Restart** button whenever you want to apply immediately.
- **Cryptographic Verification**: Every downloaded archive is verified against `SHA256SUMS.txt` using streaming SHA-256 and cryptographically validated with Apple's `Security` framework (`SecStaticCodeCheckValidity`) — including a fresh signature re-verification immediately before staging and atomic replacement — to confirm an Apple Developer ID signature, matching Bundle ID and Team ID, and Hardened Runtime.

---

## Permissions & Privacy

CCX requests only the macOS permissions required for its three core features:

| Permission | Required? | Purpose |
| --- | --- | --- |
| **Screen & System Audio Recording** | Required | Capturing screenshots, scrolling captures, screen recordings, and optional system audio. Relaunch CCX after granting for the first time. |
| **Accessibility** | Optional | Fine-grained UI element auto-detection during Smart Snip and automatic scrolling during Scroll Capture. |
| **Microphone** | Optional | Voice narration when microphone recording is enabled. |

- CCX collects **no analytics, crash reports, or telemetry** and never uploads your captures, OCR text, or recordings.
- The only network traffic CCX makes is HTTPS requests to GitHub Releases (`api.github.com`, `github.com`, `*.githubusercontent.com`) when checking for or downloading app updates — automatic checks can be turned off completely in **Settings → Updates**.
- Recent snip history is stored exclusively in `~/Library/Caches/com.lizhichaox.ccx/RecentSnips` with user-only permissions (`0700` directory, `0600` files) and can be cleared anytime from the popover or Settings.

---

## Keyboard Shortcuts

### Global & Menu Bar
| Shortcut | Action |
| --- | --- |
| `⌃⌘X` | Start Smart Snip (customizable in **Settings → Snip Shortcut** with conflict detection) |
| Click menu bar icon | Open / close CCX popover (left or right click) |
| `⌘,` | Open Settings (when popover is open) |
| `Esc` / `⌘W` | Dismiss popover, Settings, or Setup Guide |
| `⌘Q` | Quit CCX (from popover; confirms if recording is active) |

### Smart Snip Overlay
| Shortcut | Action |
| --- | --- |
| `Shift` (while hovering) | Cycle magnifier color format (`HEX` → `RGB` → `HSL`) |
| `C` (while hovering) | Copy pixel color under cursor |
| `R` (while hovering) | Recall previous selection on this display |
| Drag (`Shift` / hold `Space`) | Select region (constrain square / move origin) |
| `← ↑ → ↓` (`Shift` = 10pt) | Nudge selection or selected annotation |
| `⌥` + `← ↑ → ↓` (`Shift` = 10pt) | Resize selection edges |
| `⌘A` | Select entire display |
| `1`–`8` / `V` | Select annotation tool / select-move tool |
| `⌘Z` / `⇧⌘Z` | Undo / redo annotation |
| `⌘D` / `Delete` | Duplicate / delete selected annotation |
| `Return` | Finish and Pin |
| `⌘C` | Copy to clipboard |
| `⌘S` / `⇧⌘S` | Save PNG dialog / Quick Save PNG |
| `T` | Extract and copy text (OCR) |
| `L` | Start Scrolling Capture for selected region |
| `R` (with selection) | Start Screen Recording for selected region |
| `Esc` / `⌘W` | Cancel (or cancel inline text edit first) |

### Scrolling Capture
| Shortcut | Action |
| --- | --- |
| `Space` | Start / pause Auto-Scroll |
| `Return` | Finish and Pin |
| `⌘C` | Finish and Copy |
| `⌘S` / `⇧⌘S` | Save PNG dialog / Quick Save PNG |
| `T` | Extract and copy text (OCR) |
| `Esc` / `⌘W` | Cancel scrolling capture (when HUD is focused) |

### Floating Pins
| Shortcut | Action |
| --- | --- |
| Scroll wheel / trackpad | Zoom in / out (`⌥` + Scroll adjusts opacity) |
| `+` / `-` (`⌘+` / `⌘-`) | Zoom in / out |
| `0` / `⌘0` | Reset zoom to 100% |
| `⇧0` / `⇧⌘0` | Reset all transforms (zoom, rotation, flip, opacity) |
| `R` / `⇧R` | Rotate 90° clockwise / counter-clockwise |
| `H` / `V` | Flip horizontal / vertical |
| `← ↑ → ↓` (`Shift` = 10pt) | Nudge floating pin |
| `⌘C` | Copy pin content |
| `⌘D` | Duplicate pin (or duplicate selected annotation while annotating) |
| `⌘S` / `⇧⌘S` | Save PNG dialog / Quick Save PNG |
| `Esc` | Cancel inline text → cancel annotation session → close pin |
| `⌘W` | Close pin |

### Screen Recording
| Phase | Shortcuts |
| --- | --- |
| **Ready** | `Return` or `Space`: Start · `← ↑ → ↓` / `⌥` + Arrows: Nudge / resize · `⌘A`: Full display · `Esc` / `⌘W`: Cancel |
| **Recording / Paused** | `Space`: Pause / resume · `Return`: Stop & finalize · `Esc` / `⌘W`: Discard (when HUD is focused) |
| **Completed** | `Return` or `⇧⌘S`: Quick Save · `⌘C`: Copy file · `⌘S`: Save dialog · `Esc` / `⌘W`: Discard |

---

## Building from Source

### Requirements
- macOS 15.0+ with Xcode 16+ (Swift 6.0) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

### Local Development Build & Launch
```bash
# Auto-detects your Apple Development signing identity (or copy Config/LocalSigning.xcconfig.example),
# builds CCX.app, installs to /Applications/CCX.app, and launches via LaunchServices:
./scripts/build-and-run.sh

# Optional flags:
./scripts/build-and-run.sh --build-only --no-bump
```

### Running Unit Tests
```bash
for pkg in CCXCore CCXAnnotate CCXCapture CCXPin CCXRecord; do
  swift test --package-path "Packages/$pkg"
done
```

### Public Release Packaging (Universal Binary + Hardened Runtime)
```bash
# Bump version in project.yml when preparing a release:
./scripts/bump-version.sh 0.8.0

# Build signed Universal Binary (arm64 + x86_64), verify dylibs/codesign/entitlements,
# and emit dist/CCX-<version>-macOS-universal.{dmg,zip} + dist/SHA256SUMS.txt:
./scripts/package-release.sh

# Optional: notarize and staple with an Apple notarytool keychain profile:
./scripts/package-release.sh --notarize "CCX-Notary"

# Optional: notarize and staple using gitignored .env (APPLE_API_KEY_PATH, APPLE_API_KEY_ID, APPLE_API_ISSUER_ID):
./scripts/package-release.sh --notarize-env
```

---

## License

Copyright © 2026 Zhichao Li. All rights reserved.
