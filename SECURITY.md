# Security Policy

## Supported Versions

Security updates are provided for the latest release in the current minor series:

| Version | Supported | Platform Requirement |
| --- | --- | --- |
| `0.8.x` (latest) | Yes | macOS 15.0 Sequoia or later (`arm64` / `x86_64`) |
| `< 0.8.0` | No | — |

## Security & Privacy Architecture

CCX is designed with a minimal attack surface and local-first privacy:

- **100% Native Apple Frameworks**: Built exclusively with Swift 6 and system Apple frameworks (AppKit, SwiftUI, ScreenCaptureKit, Metal/CoreImage, AVFoundation/VideoToolbox, Apple Vision, and Security) with **zero third-party runtime dependencies**.
- **Local-Only Captures, OCR & Recordings**: Screenshots, on-device Vision OCR, and screen recordings stay entirely on your Mac. CCX collects **zero analytics, crash reports, or telemetry** and never uploads user content.
- **Private Local Storage & Symlink Defenses**: Recent snip history (`~/Library/Caches/com.lizhichaox.ccx/RecentSnips`), temporary recordings, and pasteboard recording caches are restricted to user-only POSIX permissions (`0700` directories, `0600` files) with `lstat`/`O_NOFOLLOW` symlink defenses and atomic file replacement.
- **Cryptographically Verified In-App Updates**: Optional update checks connect only over HTTPS to a strict allowlist of GitHub Releases hosts (with repository release path validation) and can be disabled anytime in **Settings → Updates**. Every update archive undergoes:
  - Streaming SHA-256 verification against `SHA256SUMS.txt`
  - Pre-extraction ZIP validation (entry count, uncompressed size, path traversal, and symlink checks) before `ditto` extraction
  - Apple `Security` framework code-signature verification (`SecStaticCodeCheckValidity`) confirming an Apple Developer ID signature, matching Bundle ID and Team ID, and Hardened Runtime
  - Fresh TOCTOU signature re-verification immediately before staging and rollback-safe atomic app replacement

## Local Development Guardrails

Enable the repository's built-in `pre-commit` and `pre-push` secret/local-config checks once per clone with `git config core.hooksPath .githooks`. These hooks run `scripts/check-secrets.sh` to block local env/signing files, hardcoded credentials or local home paths, and exact values from untracked `.env` or `Config/LocalSigning.xcconfig` files from being committed or pushed. You can also run `./scripts/check-secrets.sh --all` anytime to audit all tracked files.

## Reporting a Vulnerability

If you discover a security vulnerability in CCX, **please do not open a public GitHub issue**.

Instead, please disclose it privately through GitHub Security Advisories:

- **GitHub Security Advisories**: https://github.com/lizhichaox/ccx/security/advisories/new

Please include as much detail as possible to help reproduce and assess the report (affected CCX version, macOS version, reproduction steps, and potential impact). Reports will be acknowledged promptly and addressed in an upcoming patch release.
