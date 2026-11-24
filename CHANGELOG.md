# Changelog

All notable changes to **CCX (Control · Command · X)** are documented in this file.

## [0.8.2] - 2026-11-24

### Security
- **In-App Updater Archive & Path Hardening (`CCXCore`)**: Added ZIP archive pre-inspection before `ditto` extraction (blocking excessive entry counts, oversized uncompressed payloads, path traversal, and unsafe symlinks), scoped atomic-updater staging and cleanup path guards to CCX-owned paths, and enforced a strict exact-host GitHub allowlist with repository release path validation.
- **Symlink & File-Safety Defenses (`App`)**: Hardened PNG save-directory validation (`preferredSaveDirectoryURL`) to strip trailing slashes before `lstat`, updated Quick Save collision detection (`nextUniqueURL`) to treat dangling symlinks as occupied, enforced regular-file source and non-symlink destination `lstat` verification in `moveRecordingAtomically`, and restricted pasteboard recording cleanup (`prunePasteboardRecordings`, `clearPasteboardRecordings`, `cleanupPasteboardRecordings`) to `lstat`-verified user-owned regular files and symlinks before `unlink`.
- **Release Script & Repository Hygiene**: Hardened `scripts/package-release.sh` to reject symlinked `.p8` App Store Connect API keys, warn when key file permissions are broader than `600`/`400`, and warn when Apple ID notarization passes `--password` on the command line; added explicit private-key, certificate, and `.env.*` ignore rules in `.gitignore`; and added `SECURITY.md` documenting supported versions, security architecture, and private vulnerability disclosure.

## [0.8.1] - 2026-11-24

### Improved
- **Vibrant Visual Palette Polish (`App`)**: Refreshed the Menu Bar Popover, Settings, and Setup Guide with luminous Apple-calibrated gradient icon badges (`CCXIconBadge` / `CCXBadgePalette`), soft top surface tint washes, and crisp tinted hover/accent surfaces while preserving exact window dimensions and single-line English & Simplified Chinese layouts.
- **Menu Bar Popover Contrast & Accents**: Upgraded the **Snip** / **Pin** / **Record** hero tiles (including vibrant circular tinted hover accessories for **Record**'s folder shortcut and **Pin**'s clipboard clear action, plus vivid orange conflict badges), brightened the **Recent Snips** header row with a crisp blue count capsule and tinted red **Clear** pill, lifted **Floating Pins** control accents, and refreshed the bottom **Ready / Guide · Settings · Quit** utility dock with filled tinted icons and crisper labels.
- **Settings & Setup Guide Cohesion**: Upgraded all Settings row icons, Setup Guide bento cards, permission rows, and shortcut rows to the shared gradient icon badges, and added subtle vibrant symbol accents to the **Setup Guide** and **Clear Snip History** buttons in Settings.
- **Pin Annotation Toolbar Summoning & Double-Click Reliability (`CCXPin`)**: Promoted **Show Toolbar** (**显示工具栏**, `E`) to the first item of every image pin's right-click context menu (including restoring from thumbnail mode), eliminated eager `performDrag` double-click swallowing with a 3pt drag threshold and resilient double-click detection, added an unobtrusive hover toolbar button in the bottom-right corner of image pins, and added direct `E` / `Space` / `1`–`8` / `T` shortcuts on focused image pins.

## [0.8.0] - 2026-11-24

### Added
- **Seamless Background Pre-Download & Silent Idle/Quit Auto-Update (`CCXCore`, `App`)**: Upgraded CCX's native in-app updater to automatically pre-download and cryptographically verify eligible GitHub Releases in the background into a new `.readyToInstall` state, then apply them seamlessly after a short idle debounce once no floating Pins, captures, recordings, OCR tasks, save dialogs, or CCX windows are open — or silently on disk without relaunching when you explicitly quit CCX.
- **Zero-Wait Manual Restart & TOCTOU Signature Re-Verification**: Clicking **Restart** (**立即更新**) in **Settings** or the menu bar popover skips re-downloading, re-verifies the staged bundle's Apple Developer ID signature immediately before staging (falling back cleanly to a fresh download if the temporary payload was purged), and restarts immediately; added periodic 24-hour background update checks for long-running sessions.

### Improved
- **Bilingual Ready-to-Install Update UI**: Added single-line English (`en`) and Simplified Chinese (`zh-Hans`) `.readyToInstall` controls and hints across **Settings → Updates** and the menu bar popover banner, backed by automated `NSFont` pixel-width and updater state-machine regression tests.
- **Capture Toolbar Button Order**: Swapped the **Save** and **Copy** buttons across the Smart Snip, Pin Annotation, and Scroll Capture toolbars so **Copy** sits in the more ergonomic trailing primary action slot.

## [0.7.0] - 2026-11-24

### Added
- **Automatic Simplified Chinese & English Localization (`zh-Hans` / `en`)**: Added native bilingual localization across the entire app — Settings, Menu Bar Popover, Setup Guide, floating pins, Smart Snip & Scroll Capture overlays, Screen Recording HUDs, toasts, dialogs, error notices, and macOS permission prompt `InfoPlist.strings` (`en.lproj` & `zh-Hans.lproj`). Language resolves automatically from macOS **System Settings → Language & Region** via `CCXL10n`, falling back to English for unmatched languages.

### Improved
- **Single-Line Prompt & Microcopy Hardening**: Tightened all prompts, hints, conflict messages, error notices, badges, and buttons across both English and Simplified Chinese so every line renders crisply on a single line without wrapping, clipping, or ellipsis truncation inside the compact Settings (`368pt`), Menu Bar Popover (`316pt`), Setup Guide (`464 × 344`), and floating HUD layouts.

## [0.6.0] - 2026-11-24

### Added
- **Customizable Global Snip Shortcut with Conflict Detection**: Click the **Snip Shortcut** keycaps in **Settings** to record any custom global shortcut (`UserDefaults`-persisted with one-click reset to `⌃⌘X` and live sync across **Settings**, the **Menu Bar Popover**, and the **Setup Guide**). Includes comprehensive validation and inline conflict prompts covering shortcut structure, reserved macOS/app shortcuts, active macOS system shortcuts via Carbon `CopySymbolicHotKeys`, internal duplicates, and live `kEventHotKeyExclusive` conflict detection against other running apps while preserving your previous working binding on conflict.

### Improved
- **Two-Card Settings Layout**: Reorganized the **Settings** window into two clean Liquid Glass cards — **Preferences** grouped cleanly by control type (**Updates**, **Launch at Login**, **Recordings**, and **Snip Shortcut**) and **Permissions** (**Screen Recording**, **Accessibility**, and **Microphone**) — so toggles align cleanly and shortcut recording or conflict hints expand smoothly without shifting neighboring controls.

## [0.5.0] - 2026-11-24

### Added
- **Verified Native In-App Updater (`CCXCore`)**: Added a zero-dependency macOS in-app updater backed by GitHub Releases with strict HTTPS host allowlisting across redirects, streaming SHA-256 verification against `SHA256SUMS.txt`, dynamic Apple Developer ID code-signature and Hardened Runtime validation (`SecStaticCodeCheckValidity`), install-location eligibility checks, pre-quit sibling staging, and rollback-safe atomic app replacement and relaunch.
- **Settings & Menu Bar Popover Update UI**: Added an **Updates** row in **Settings** (automatic daily check toggle, manual **Check** / **Update** / **Cancel** / **Retry** controls, download progress bar, release notes & GitHub fallback links) and a compact, dismissible update banner in the menu bar popover (with a subtle badge dot on **Settings** when dismissed) that safely defers installation while a screen recording or save dialog is active.

### Changed
- Updated privacy copy in Settings, Setup Guide, and README to accurately note that captures and OCR remain completely local with zero telemetry while optional update checks connect only to GitHub Releases.

## [0.4.4] - 2026-11-24

### Added
- **Dedicated Recordings Folder**: Screen recordings (`MP4`, `MOV`, and `GIF`) now save by default to `~/Movies/CCX`, kept cleanly independent from the PNG screenshot save directory and customizable anytime in **Settings → Recordings** (`Choose…` / `Open`).
- **Quick-Open from Menu Bar Popover**: Added a hover-revealed folder accessory button and right-click context menu item (`Open Recordings Folder`) directly on the **Record** tile in the menu bar popover to jump straight to your recordings in Finder.

## [0.4.3] - 2026-11-24

### Fixed
- **Recent Snips Thumbnail Hit-Testing**: Bounded each recent snip thumbnail inside a fixed `60.5 × 38` hit-test and accessibility container (with `.contentShape` and `.allowsHitTesting(false)` on the `.fill`-scaled image overlay) so ultra-wide or tall snips can no longer overflow their hit-test bounds and swallow hover or click events on neighboring thumbnails.

## [0.4.2] - 2026-11-24

### Improved
- **Scrollable Recent Snips Strip**: Synced the full bounded recent snip history (up to 20 snips) into the menu bar popover instead of truncating at 4 entries, keeping `RECENT SNIPS` consistent with the Pin tile's ready count and adding a compact count pill badge beside the section header.
- **Fluid Horizontal Navigation**: Kept the centered static row for `≤ 4` snips and upgraded `> 4` snips to a smooth horizontal `ScrollView` with a natural 5th-thumbnail right-edge peek, dynamic horizontal edge-fade masking, hover-revealed translucent circular quick-step buttons for both trackpad and mouse users, and automatic scroll-to-leading reset when a new snip arrives.

## [0.4.1] - 2026-11-24

### Fixed
- **Settings Window Bottom Clipping**: Disabled AppKit titlebar safe-area injection (`safeAreaRegions = []`) on `NSHostingController` so the window's intrinsic height matches the rendered SwiftUI layout without clipping the bottom footer, added explicit top/bottom padding (`28pt` top, `16pt` bottom), widened the window (`344pt` → `368pt`) to prevent row truncation in worst-case states, and ensured dynamic banners resize the window cleanly.
- **Setup Guide (Onboarding) Layout & Spacing**: Disabled titlebar safe-area deduction in `OnboardingWindowController`, expanded the window from `440 × 300` to `464 × 344`, and increased per-step top/bottom padding (`28pt` top, `12pt` bottom) so all three steps have generous breathing room with zero cramping or text truncation.
- **Menu Bar Popover Sizing**: Disabled safe-area injection defensively on `NSHostingView` and widened the popover (`304pt` → `316pt`, recent snip thumbnails `57.5pt` → `60.5pt`) so Quick Action tile badges always have ample horizontal breathing room.
- **Multi-Display Window Placement**: Fixed opening the Setup Guide from Settings or the menu bar popover drifting onto a different external display by centering the Setup Guide over Settings when opened from Settings, resolving displays by center-point and largest intersection area (with active-cursor fallback), validating the menu bar popover's display anchor, and repositioning open Settings/Guide windows when triggered from another monitor.
- **Capturable Menu Bar Popover**: Restored the ability to capture CCX's own menu bar popover via the global `⌃⌘X` shortcut by removing `sharingType = .none` from `MenuBarPanel` and keeping the popover open until the snip overlay takes focus (while still auto-hiding when launching Snip or Record from inside the popover).

## [0.4.0] - 2026-11-24

### Added
- **Screen Recording (`CCXRecord`)**: Hardware-accelerated region and full-display recording via ScreenCaptureKit and VideoToolbox supporting `MP4` (H.264), `MOV` (HEVC), and memory-bounded `GIF`, with optional system audio and microphone dual-audio mixing, true pause/resume, adjustable capture border, live menu bar timer, and atomic Copy / Save / Quick Save / Reveal in Finder actions.
- **Persistent Recent Snips & Deduplication**: Private user-only disk cache (`0700`/`0600`) for recent snips with visual fingerprinting to prevent duplicate floating pins.
- **Inline Pin Annotation**: Re-editable annotation canvas directly inside floating image pins (shapes, arrows, freehand pen, highlighter, inline text, step counters, mosaic/blur, undo/redo).
- **Public Release Packaging**: Universal Binary (`arm64` + `x86_64`) `Release` build configuration with Hardened Runtime, microphone entitlement (`com.apple.security.device.audio-input`), secure timestamping, and reusable `scripts/package-release.sh` verification & DMG/ZIP/SHA-256 packaging pipeline.
- **Reopen & First-Run Polish**: Re-opening `CCX.app` while already running now opens the Setup Guide (if permissions are needed), the menu bar popover, or Settings (when the status icon is occluded); added Setup Guide & Clear Snip History controls, hotkey conflict detection/retry, and Screen Recording live verification in Settings.

### Improved
- **Usability & Ergonomics**:
  - Fixed revoked Screen Recording TCC detection via tri-state live verification override.
  - Scoped all global/local keyboard monitors across recording and scroll capture so typing `Esc` or shortcuts in other apps or CCX windows never aborts an active session.
  - Fixed `Esc` precedence in floating pins (cancels inline text → cancels annotation session → closes pin), `⌘D` annotation duplication, slider undo coalescing, and non-destructive atomic file replacement on save.
  - Excluded `ToastHUD` and `MenuBarPanel` from captures/recordings (`sharingType = .none`), added quit confirmation while recording, and fixed popover context-menu dismissal and vertical clamping.
- **Performance & Memory**:
  - Upgraded `PixelMagnifierView` and floating image pins to GPU `CALayer` compositing; eliminated whole-framebuffer copies in `CCXColorSample.samplePixel` and O(N) allocations in `parseHex`.
  - Added explicit memory budgets and backpressure queues across `ClipboardStore`, `MosaicImageCache`, `ScrollImageStitcher`, `ScrollCaptureEngine`, `VideoRecordingWriter`, and `GifRecordingEncoder`.
  - Paused periodic TCC polling once permissions are granted and eliminated redundant 1Hz popover layout passes during recording.
- **Security & Robustness**:
  - Enforced `lstat`/`O_NOFOLLOW` non-symlink, user-owned `0700`/`0600` file security across snip history, recording staging, and pasteboard temp directories.
  - Added decompression-bomb pixel/byte caps, FIFO/non-regular file rejection, corrupt JSON/PNG self-healing, non-finite/overflow geometry guards, HDR color-space fallbacks, and Swift 6 strict-concurrency teardown safety across all 5 packages.

## [0.3.3] - 2026-11-22
- Improved region detection, direct annotation box editing, mosaic clarity, and continuous stroke sizing.

## [0.3.2] - 2026-11-22
- Fixed scrolling capture dimension sync, sidebar detection, and small-scroll stitching accuracy; toggled popover consistently on menu bar left and right click.

## [0.3.1] - 2026-11-22
- Added fixed-sidebar detection and window corner masking during scrolling capture stitching.

## [0.3.0] - 2026-11-22
- Added native ScreenCaptureKit scrolling screenshot capture with sticky-bar stitching, live preview, and auto-scroll.
- Optimized 120Hz magnifier/hover/Accessibility IPC and added square drag, Space-move, and Option-arrow resize.

## [0.2.0] - 2026-11-22
- Added repeat-last-region snip, quick-save PNG, native Vision OCR, pin flip/border/shadow/HUD controls, zero-decode clipboard peek, cached thumbnails, lazy TIFF copy, draggable annotation toolbar, and trackpad-swipeable onboarding.
