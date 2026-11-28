# AGENTS.md

Instructions for agents working in this repository.

## Project

**CCX (Control · Command · X)** is a native Swift 6 macOS menu bar utility focused strictly on three core workflows, plus a verified in-app updater and automatic `en`/`zh-Hans` localization:

- **Capture**: Smart Snip (`⌃⌘X` + optional Quick OCR, Pin from Clipboard, Start/Stop Recording, Toggle All Pins, and Unlock Click-Through global hotkeys in Settings with conflict detection), Scroll Capture (`L`) with live preview, sticky header/sidebar detection, and memory-bounded stitching, non-destructive annotations (rectangle, ellipse, arrow, freehand pen, highlighter, inline text, auto-incrementing step counters, active-ROI live GPU blur/mosaic, undo/redo, cached zoom-scaled brush cursors, modal `?` Liquid Glass cheat sheet), 120Hz GPU pixel magnifier & color picker (`HEX` / `RGB` / `HSL`, Retina HiDPI / Display P3), and on-device Apple Vision OCR (`T`) with spatial layout reconstruction and QR/2D barcode fallback.
- **Pin**: Always-on-top floating `NSPanel` windows across Spaces and full-screen apps with GPU-accelerated zoom, 90° rotation, horizontal/vertical flip, opacity control (`⌥+Scroll`), click-through mode, thumbnail collapse, inline re-editable annotation toolbar (entered via bottom-right hover button, double-click, right-click menu, `E`, `Space`, or `1`–`8`), read-only selectable text copy mode on text pins (`E`/`T`/menu), modal `?` cheat sheet, 5-item FIFO recently-closed pin reopen (`⇧⌘T`/menu/popover), display-disconnect rescue, on-device OCR, lazy-loaded `RecentSnips` history (`0700`/`0600` user-only cache) with configurable retention policy (`keep20`/`clearAfter24Hours`/`clearOnQuit`/`disabled`), and optional `org.nspasteboard.TransientType` clipboard concealment.
- **Record**: Hardware-accelerated region and full-display screen recording (`MP4` H.264 / `MOV` HEVC via VideoToolbox, `0600` disk-spooled memory-bounded `GIF`) with optional 3-second countdown, live microphone RMS level meter (`Accelerate`/`vDSP_rmsqv`), optional system audio and microphone mixing, true pause/resume timeline offsetting, mid-recording display-disconnect salvage, a dedicated recordings folder (`~/Movies/CCX`, configurable independently from PNG save paths), and non-destructive output actions.
- **Verified In-App Updater & Localization**: Zero-dependency updater checking GitHub Releases over HTTPS with streaming SHA-256 verification against `SHA256SUMS.txt`, pre-extraction ZIP validation, and Apple `Security` framework code-signature validation (`SecStaticCodeCheckValidity`) before idle auto-install or quit-time replacement; automatic `en`/`zh-Hans` localization following macOS Language & Region (English default/fallback).

## Target Environment & Toolchain

- **Primary Local Host**: Apple Silicon (M1 Max, Metal 4, 14" Liquid Retina XDR display with Notch) running **macOS 27.3**.
- **Toolchain**: Full **Xcode 27.2**, **Swift 6.4.2**, **`MacOSX27.2.sdk`**, **XcodeGen 2.48.0**, `swiftlint`, `swiftformat`.
- **Deployment Target**: **`macOS 15.0` (Sequoia)** baseline (Universal Binary `arm64` + `x86_64`), compiled against `MacOSX27.2.sdk` with progressive `#available(macOS 26.0, *)` enhancements (HDR `SCScreenshotConfiguration`, Liquid Glass `NSGlassEffectView` / `.glassEffect()`).
- **Stack**: Pure native Swift 6 (`AppKit` + `SwiftUI` + `ScreenCaptureKit` + `Metal` / `CoreImage` + `AVFoundation` / `VideoToolbox` + `Vision` + `ImageIO` + `Security`) with zero third-party runtime dependencies, organized as an XcodeGen (`project.yml`) `.app` target backed by local modular SwiftPM packages.

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

2. **Configure signing explicitly in `project.yml`** (XcodeGen defaults to Automatic signing, where passing only `CODE_SIGN_IDENTITY` fails with `"Signing for CCX requires a development team"`). Manual signing requires no provisioning profile on macOS since CCX is non-sandboxed and uses no restricted entitlements:

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

3. **Generate, build, install to `/Applications/CCX.app`, and launch via LaunchServices** (launch as a real `.app` bundle in `/Applications` so macOS tracks TCC grants by `CFBundleIdentifier` and displays CCX in System Settings):

   ```bash
   ./scripts/build-and-run.sh
   # Optional flags: --build-only (compile without replacing/launching), --no-install (run from .build/xcode), --no-bump, --release
   ```

   Under the hood, `scripts/build-and-run.sh` runs `xcodegen generate`, builds with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, replaces `/Applications/CCX.app` atomically, registers it with LaunchServices, and launches `/Applications/CCX.app`.

4. **TCC & Bundle Requirements**:
   - **Non-App-Sandbox** (`com.apple.security.app-sandbox` omitted or `false`) — required for cross-app `AXUIElement` inspection and optional `CGEventTap`.
   - Fixed `CFBundleIdentifier` (`com.lizhichaox.ccx`), `LSUIElement = true`, `NSApp.setActivationPolicy(.accessory)` (required for floating `NSPanel`s above other apps' full-screen Spaces), and `NSHighResolutionCapable = true`.
   - Include `NSScreenCaptureUsageDescription`, `NSAudioCaptureUsageDescription`, and `NSMicrophoneUsageDescription` in `Info.plist`.
   - Signing with the installed `Apple Development` identity keeps a stable Designated Requirement so **Screen Recording** and **Accessibility** TCC grants persist across rebuilds (never use ad-hoc `-` signing for local TCC testing).
   - After the initial Screen & System Audio Recording grant, **quit and relaunch `CCX.app`** (macOS loads Screen Recording TCC only at process start). Reset during onboarding tests with `tccutil reset ScreenCapture com.lizhichaox.ccx`.
   - Keep a runtime `MTLDevice.makeLibrary(source:)` fallback so shader tests run in headless/sandboxed environments without `MetalToolchain` access.

### Versioning & Build Management

- `project.yml` is the single source of truth for `MARKETING_VERSION` (`MAJOR.MINOR.PATCH`) and `CURRENT_PROJECT_VERSION` (integer build number), injected into `App/Info.plist` via `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`.
- Bump `MARKETING_VERSION` according to change size using `./scripts/bump-version.sh <patch|minor|major|X.Y.Z>`:
  - Use **`./scripts/bump-version.sh patch`** (`0.10.x`) for small fixes, UI polish, performance tweaks, and security hardening.
  - Reserve **`minor`** for new user-facing features or capability expansions, and **`major`** for major milestones or breaking changes.
- `./scripts/build-and-run.sh` automatically increments `CURRENT_PROJECT_VERSION` by `+1` on every build (pass `--no-bump` only for dry rebuilds that should not advance the build number).

## Architecture

```text
project.yml            XcodeGen project manifest (version, build number, targets, build settings)
SECURITY.md            Security policy, local-first privacy architecture, and vulnerability reporting
App/                   CCXApp target (Info.plist, CCX.entitlements, Assets.xcassets, Resources,
                       AppDelegate, MenuBarController, MenuBarPopoverView, SettingsWindowController,
                       OnboardingWindowController, PermissionStatusModel, DismissibleWindow, ToastHUD)
Packages/
  CCXCore/             CoordinateConverter (Quartz <-> AppKit, HiDPI/Notch/multi-display), ColorSample,
                       HotKeys (Carbon multi-action + conflict detection), Localization (CCXL10n), PermissionManager,
                       ClipboardStore (retention policies + transient concealment), SnipHistoryPersistence (0700/0600,
                       lazy thumbnail startup), ImageFingerprint, TextRecognizer (Vision spatial OCR + QR fallback),
                       ActivityArbiter, AtomicFileWriter, AppUpdater (verified GitHub Releases updater)
  CCXAnnotate/         Non-destructive AnnotationDocument & AnnotationModels, AnnotationRenderer,
                       MosaicImageCache (active-ROI GPU blur/mosaic), BrushCursorCache,
                       ShortcutCheatSheetView (modal '?' Liquid Glass panel), shared AnnotationActionToolbar
  CCXCapture/          ScreenSnapshotEngine (ScreenCaptureKit 15.0 + 26.0 HDR), SmartElementDetector
                       (CGWindowList + async AXUIElement), WindowCornerMaskExtractor,
                       SelectionStateMachine, SnipCoordinator, SnipOverlayController/View (Snip + OCR modes),
                       AnnotationCanvasView, PixelMagnifierView, SnipActionToolbar,
                       ScrollCaptureEngine/Controller & ScrollImageStitcher
  CCXPin/              Floating PinPanel (.nonactivatingPanel, multi-Space/full-screen, selectable text mode,
                       '?' cheat sheet), PinManager (screen rescue + 5-item closed-pin FIFO history),
                       PinModel, PinLayout, PinAnnotationController (inline re-editable annotations)
  CCXRecord/           ScreenRecordingEngine (SCStream), VideoRecordingWriter (AVAssetWriter/VideoToolbox),
                       GifRecordingEncoder (0600 disk-spooled ImageIO), AudioSampleMixer (system audio + mic +
                       vDSP RMS meter), RecordingTimeline (true pause/resume PTS shifting),
                       RecordingFrameAdjuster, RecordingHUDPanels (3s countdown + live mic meter),
                       RecordingCoordinator (display-disconnect salvage), RecordingFileSecurity
scripts/
  build-and-run.sh     Generates CCX.xcodeproj, signs, builds, installs /Applications/CCX.app, launches
  bump-version.sh      Updates MARKETING_VERSION (patch|minor|major|X.Y.Z) in project.yml (0644)
  package-release.sh   Builds signed Universal Binary with Hardened Runtime, verifies bundle, emits DMG/ZIP + SHA256SUMS.txt
  check-secrets.sh     Audits tracked files (--all), staged changes (--staged), or pushed commits (--push) for secrets/local config
  verify-all.sh        One-command local check: secrets audit, shell lint, git diff --check, 5-package tests, optional --build
  generate-icons.py    Generates app icon assets into App/Assets.xcassets
.githooks/
  pre-commit           Runs scripts/check-secrets.sh --staged
  pre-push             Runs scripts/check-secrets.sh --push
```

## Engineering & Verification Guardrails

- **ScreenCaptureKit only for pixel capture**: Never call `CGWindowListCreateImage*` or `CGDisplayCreateImage` (marked `SCREEN_CAPTURE_OBSOLETE(..., 15.0)` in `MacOSX27.2.sdk`). `CGWindowListCopyWindowInfo` remains valid for Z-order window metadata and `CGWindowID` -> `SCWindow` matching.
- **No iOS-only ScreenCaptureKit APIs**: Do not reference `SCVideoEffectOutput` (unavailable on macOS).
- **Zero-copy GPU pipelines & hardware recording**: Route `SCStream` `IOSurface`-backed `CVPixelBuffer` frames directly into `AVAssetWriter` (VideoToolbox) with `RecordingTimeline` PTS offset shifting for true pause/resume, avoiding CPU frame readbacks on hot paths. Keep GIF export memory-bounded via native `ImageIO` (`GifRecordingEncoder`) with zero third-party runtime dependencies.
- **Non-blocking UI element detection**: Always run `AXUIElementCopyElementAtPosition` on a throttled/debounced background queue with timeout fallback to window bounds so 120Hz overlay tracking never stalls on Chromium/Electron apps.
- **Global hotkeys without TCC friction**: Use Carbon `RegisterEventHotKey` for core shortcuts; keep `CGEventTap` optional and gated on Accessibility trust.
- **UI & Localization Guardrails**:
  - Support automatic `en` and `zh-Hans` localization via `CCXL10n` (following macOS System Settings → Language & Region, with English as the default and fallback for all other languages).
  - Enforce **no wrapped, truncated, or folded prompts** across Settings (`368pt`), Menu Bar Popover (`316pt`), Setup Guide (`464 × 344`), and floating HUDs in both `en` and `zh-Hans` (verified by `NSFont` pixel-width unit tests).
- **Security & Secret Hygiene Guardrails**:
  - Enable local hooks once per clone via `git config core.hooksPath .githooks` so `pre-commit` and `pre-push` automatically run `scripts/check-secrets.sh`.
  - Never commit `.env`, `Config/LocalSigning.xcconfig`, signing keys/certificates, hardcoded credentials, or local macOS home paths; audit anytime with `./scripts/check-secrets.sh --all`.
  - Run `./scripts/verify-all.sh` (or `./scripts/verify-all.sh --build` for full Release compilation) before handing off changes.
- **Language & repository discipline**:
  - Keep all code comments, repository documentation, and commit messages in English (localized UI strings belong only in localization resources).
  - Do not add GitHub Actions workflows unless explicitly requested; run tests, linting, and builds locally.
  - Make clean, atomic commits (one logical change per commit) and never modify sibling repositories.
  - Before handing off changes, run `./scripts/verify-all.sh` (or `git diff --check` and applicable `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` / build checks), and report any sandbox vs. code failures explicitly.
