# Changelog

All notable changes to **CCX (Control · Command · X)** are documented in this file.

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
