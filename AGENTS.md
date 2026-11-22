# AGENTS.md

Instructions for agents working in this repository.

## Project

**CPX (Capture + Paste + X)** is a native macOS screenshot, floating pin, and screen recording utility.

- **Capture (Snip)**: Full Snipaste parity — instant area/window/UI-element auto-detection, Retina HiDPI / Display P3 / HDR pixel magnifier and color picker (HEX / RGB / HSL), and a re-editable annotation canvas (shapes, arrows, freehand pen, highlighter, inline text, step counters, live GPU blur/mosaic, undo/redo).
- **Paste (Pin)**: Always-on-top floating `NSPanel` windows across Spaces and full-screen apps with zoom, rotation/flip, opacity control, click-through mode, thumbnail collapse, pin groups, clipboard/snip history, and native `VisionKit` Live Text OCR / QR extraction.
- **X (Screen Recording & Extended Workflows)**: Hardware-accelerated region/window/display screen recording (MP4/MOV via VideoToolbox, high-quality GIF, animated WebP) with system audio and microphone capture, pause/resume, live screen region PiP pins, pinned video/GIF loops, macOS 27 Instant Replay / quick trim, and Vision Smart Redact.

## Target Environment & Toolchain

- **Primary Local Host**: Apple Silicon (M1 Max, Metal 4, 14" Liquid Retina XDR display with Notch) running **macOS 27.3**.
- **Toolchain**: Full **Xcode 27.2**, **Swift 6.4.2**, **`MacOSX27.2.sdk`**, **XcodeGen 2.48.0**, `swiftlint`, `swiftformat`.
- **Deployment Target**: **`macOS 15.0` (Sequoia)** baseline, compiled against `MacOSX27.2.sdk` with progressive `#available(macOS 26.0, *)` (HDR `SCScreenshotConfiguration`, Liquid Glass `NSGlassEffectView` / `.glassEffect()`) and `#available(macOS 27.0, *)` (`SCClipBufferingOutput`, `SCRecordingEditor`, `SCRecordingOutputConfiguration.mixesAudioWithMicrophone`) enhancements.
- **Stack**: Pure native Swift 6 (`AppKit` + `SwiftUI` + `ScreenCaptureKit` + `Metal 4` / `CoreImage` + `AVFoundation` / `VideoToolbox` + `Vision` / `VisionKit`), organized as an XcodeGen (`project.yml`) `.app` target backed by local modular SwiftPM packages.

## Build, Signing, and Launch

### Sandboxed Shell Rule (`DEVELOPER_DIR`)

In sandboxed shells, `swift`, `xcodebuild`, and `xcrun` fail with `EPERM` reading `/var/db/xcode_select_link` unless `DEVELOPER_DIR` is set explicitly. Always prefix CLI toolchain commands in sandboxed shells:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

### Local `.app` Build, Code Signing & Launch (Host / Unsandboxed)

Full `.app` generation, `MetalToolchain` shader compilation (`~/Library/Developer/DVTDownloads`), Keychain signing, and LaunchServices launch require host (unsandboxed) execution:

1. **Resolve the exact `DEVELOPMENT_TEAM` (`OU`) from the installed certificate** (do **not** assume the parenthesized per-certificate identifier in `Apple Development: <Name> (<CERT_ID>)` is the Team ID):

   ```bash
   security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
   ```

2. **Configure signing explicitly in `project.yml`** (XcodeGen defaults to Automatic signing, where passing only `CODE_SIGN_IDENTITY` fails with `"Signing for CPX requires a development team"`). Manual signing requires no provisioning profile on macOS since CPX is non-sandboxed and uses no restricted entitlements:

   ```yaml
   settings:
     base:
       MACOSX_DEPLOYMENT_TARGET: "15.0"
       CODE_SIGN_STYLE: Manual
       DEVELOPMENT_TEAM: "<OU from openssl subject>"
       CODE_SIGN_IDENTITY: "Apple Development"
       PROVISIONING_PROFILE_SPECIFIER: ""
   ```

   *(Alternative: `CODE_SIGN_STYLE: Automatic` with `DEVELOPMENT_TEAM` set and without overriding `CODE_SIGN_IDENTITY`. Never commit a personal `DEVELOPMENT_TEAM` into `project.yml`; pass it via `DEVELOPMENT_TEAM`, untracked `Config/LocalSigning.xcconfig`, or `scripts/build-and-run.sh` auto-detection. For external release distribution, sign with a `Developer ID Application` certificate + Hardened Runtime + `com.apple.security.device.audio-input`.)*

3. **Generate, build, install to `/Applications/CPX.app`, and launch via LaunchServices** (launch as a real `.app` bundle in `/Applications` so macOS tracks TCC grants by `CFBundleIdentifier` and displays CPX in System Settings):

   ```bash
   ./scripts/build-and-run.sh
   # Optional flags: --build-only (compile without replacing/launching), --no-install (run from .build/xcode), --release
   ```

   Under the hood, `scripts/build-and-run.sh` runs `xcodegen generate`, builds with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, replaces `/Applications/CPX.app` atomically, registers it with LaunchServices, and launches `/Applications/CPX.app`.

4. **TCC & Bundle Requirements**:
   - **Non-App-Sandbox** (`com.apple.security.app-sandbox` omitted or `false`) — required for cross-app `AXUIElement` inspection and optional `CGEventTap`.
   - Fixed `CFBundleIdentifier` (`com.lizhichaox.cpx`), `LSUIElement = true`, `NSApp.setActivationPolicy(.accessory)` (required for floating `NSPanel`s above other apps' full-screen Spaces), and `NSHighResolutionCapable = true`.
   - Include `NSScreenCaptureUsageDescription`, `NSAudioCaptureUsageDescription`, and `NSMicrophoneUsageDescription` in `Info.plist`.
   - Signing with the installed `Apple Development` identity keeps a stable Designated Requirement so **Screen Recording** and **Accessibility** TCC grants persist across rebuilds (never use ad-hoc `-` signing for local TCC testing).
   - After the initial Screen & System Audio Recording grant, **quit and relaunch `CPX.app`** (macOS loads Screen Recording TCC only at process start). Reset during onboarding tests with `tccutil reset ScreenCapture com.lizhichaox.cpx`.
   - Keep a runtime `MTLDevice.makeLibrary(source:)` fallback so shader tests run in headless/sandboxed environments without `MetalToolchain` access.

## Planned Architecture

```text
project.yml            XcodeGen project manifest
App/                   CPXApp target (Info.plist, entitlements, Assets, AppDelegate, MenuBar, TCC onboarding, Settings)
Packages/
  CPXCore/             HiDPI/Notch/multi-display coordinate transforms (Quartz <-> AppKit), color math, Carbon hotkeys, history store
  CPXCapture/          ScreenCaptureKit snapshot engine (15.0 + 26.0 HDR), CGWindowList + async AXUIElement detector, OverlayPanel, GPU magnifier
  CPXAnnotate/         Non-destructive annotation scene graph, Metal/CoreImage live blur & mosaic, inline text, step counters, UndoManager, Smart Redact
  CPXPin/              Floating PinPanel (.nonactivatingPanel, multi-Space/fullscreen), zoom/rotate/opacity/click-through/groups, VisionKit Live Text, Live PiP mirror
  CPXRecord/           SCStream + CVMetalTextureCache compositor + AVAssetWriter/VideoToolbox (pause/resume, dual audio), macOS 27 Instant Replay & trim, GIF/WebP export
```

## Engineering & Verification Guardrails

- **ScreenCaptureKit only for pixel capture**: Never call `CGWindowListCreateImage*` or `CGDisplayCreateImage` (marked `SCREEN_CAPTURE_OBSOLETE(..., 15.0)` in `MacOSX27.2.sdk`). `CGWindowListCopyWindowInfo` remains valid for Z-order window metadata and `CGWindowID` -> `SCWindow` matching.
- **No iOS-only ScreenCaptureKit APIs**: Do not reference `SCVideoEffectOutput` (unavailable on macOS).
- **Zero-copy GPU pipelines**: Route `SCStream` `IOSurface`-backed `CVPixelBuffer` frames through `CVMetalTextureCache` to Metal 4 / `AVAssetWriter` (VideoToolbox) and use `AVSampleBufferDisplayLayer` for Live Region PiP pins. Avoid CPU frame readbacks on hot paths.
- **Primary recording engine**: Use `SCStream` + `AVAssetWriter` (VideoToolbox) for true pause/resume (PTS offset shifting) and GPU presenter compositing; optionally use macOS 27 `SCRecordingOutput` (`mixesAudioWithMicrophone`) as a fast path alongside `SCClipBufferingOutput` and `SCRecordingEditor`.
- **Export encoder constraints**: `ImageIO` (`CGImageDestination`) is read-only for WebP on macOS — use `libwebp` for animated WebP export. Prefer `libgifski` for high-quality GIF export (with `ImageIO` / `ffmpeg` fallback).
- **Non-blocking UI element detection**: Always run `AXUIElementCopyElementAtPosition` on a throttled/debounced background queue with timeout fallback to window bounds so 120Hz overlay tracking never stalls on Chromium/Electron apps.
- **Global hotkeys without TCC friction**: Use Carbon `RegisterEventHotKey` for core shortcuts (Snip/Pin/Record/Toggle Pins); keep `CGEventTap` optional and gated on Accessibility trust.
- **Language & repository discipline**:
  - Keep all code comments, repository documentation, and commit messages in English (localized UI strings belong only in localization resources).
  - Do not add GitHub Actions workflows unless explicitly requested; run tests, linting, and builds locally.
  - Make clean, atomic commits (one logical change per commit) and never modify sibling repositories.
  - Before handing off changes, run `git diff --check`, applicable `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` / build checks, and report any sandbox vs. code failures explicitly.
