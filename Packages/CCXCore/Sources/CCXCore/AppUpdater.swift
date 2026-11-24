import Combine
import CryptoKit
import Darwin
import Foundation
import os
import Security

// MARK: - Semantic Version

/// Strict two- or three-component semantic version (`major.minor[.patch]`) used for CCX releases.
///
/// Prerelease (`-`) and build metadata (`+`) suffixes are intentionally rejected so the updater
/// only promotes stable public releases.
public struct AppSemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses a version string such as `"0.5.0"`, `"v0.5.0"`, or `"V1.2"`.
    ///
    /// Returns `nil` for empty strings, prerelease/build tags (`-`, `+`), non-ASCII digits,
    /// negative components, or fewer than 2 / more than 3 dot-separated numeric segments.
    public init?(parsing raw: String) {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.first == "v" || trimmed.first == "V" {
            trimmed.removeFirst()
        }
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("-"), !trimmed.contains("+") else { return nil }

        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }

        var numbers: [Int] = []
        numbers.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty,
                  part.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
                  let value = Int(part),
                  value >= 0
            else {
                return nil
            }
            numbers.append(value)
        }

        self.major = numbers[0]
        self.minor = numbers[1]
        self.patch = numbers.count == 3 ? numbers[2] : 0
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: AppSemanticVersion, rhs: AppSemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

// MARK: - Release Models & Errors

/// Verified metadata for a downloadable GitHub Release of CCX.
public struct AppReleaseInfo: Equatable, Sendable {
    public static let maxReleaseNotesLength = 4096

    public let version: AppSemanticVersion
    public let tagName: String
    public let releaseURL: URL
    public let zipAssetName: String
    public let zipDownloadURL: URL
    public let zipAssetSize: Int64
    public let checksumsDownloadURL: URL
    public let dmgDownloadURL: URL?
    public let releaseNotes: String
    public let publishedAt: Date?

    public init(
        version: AppSemanticVersion,
        tagName: String,
        releaseURL: URL,
        zipAssetName: String,
        zipDownloadURL: URL,
        zipAssetSize: Int64,
        checksumsDownloadURL: URL,
        dmgDownloadURL: URL?,
        releaseNotes: String,
        publishedAt: Date?
    ) {
        self.version = version
        self.tagName = tagName
        self.releaseURL = releaseURL
        self.zipAssetName = zipAssetName
        self.zipDownloadURL = zipDownloadURL
        self.zipAssetSize = zipAssetSize
        self.checksumsDownloadURL = checksumsDownloadURL
        self.dmgDownloadURL = dmgDownloadURL
        let trimmedNotes = releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedNotes.count > Self.maxReleaseNotesLength {
            self.releaseNotes = String(trimmedNotes.prefix(Self.maxReleaseNotesLength))
        } else {
            self.releaseNotes = trimmedNotes
        }
        self.publishedAt = publishedAt
    }
}

/// User-facing errors raised during update discovery, verification, or installation.
public enum AppUpdateError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case untrustedURL
    case responseTooLarge
    case rateLimited
    case httpStatus(Int)
    case networkUnavailable
    case missingReleaseAssets
    case missingChecksumEntry
    case checksumMismatch
    case extractionFailed
    case invalidBundleMetadata
    case unsignedCurrentApp
    case signatureVerificationFailed(Int32)
    case installLocationNotWritable(String)
    case installFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return CCXL10n.text("Unexpected response from GitHub.", zh: "GitHub 返回了异常响应")
        case .untrustedURL:
            return CCXL10n.text("Blocked untrusted download URL.", zh: "已拦截不受信任的下载地址")
        case .responseTooLarge:
            return CCXL10n.text("Update exceeds size limit.", zh: "更新包超出允许大小限制")
        case .rateLimited:
            return CCXL10n.text("GitHub rate limit. Try later.", zh: "GitHub 请求受限，请稍后重试")
        case .httpStatus(let code):
            return CCXL10n.text("GitHub error (HTTP \(code)).", zh: "GitHub 请求失败（HTTP \(code)）")
        case .networkUnavailable:
            return CCXL10n.text("Can't reach GitHub. Check network.", zh: "无法连接 GitHub，请检查网络")
        case .missingReleaseAssets:
            return CCXL10n.text("Release assets or checksum missing.", zh: "该版本缺少安装包或校验文件")
        case .missingChecksumEntry:
            return CCXL10n.text("SHA-256 checksum missing.", zh: "未找到 SHA-256 校验值")
        case .checksumMismatch:
            return CCXL10n.text("SHA-256 check failed.", zh: "SHA-256 完整性校验失败")
        case .extractionFailed:
            return CCXL10n.text("Couldn't extract update archive.", zh: "更新包解压失败")
        case .invalidBundleMetadata:
            return CCXL10n.text("Downloaded app bundle is invalid.", zh: "下载的应用包无效或不完整")
        case .unsignedCurrentApp:
            return CCXL10n.text("Requires Developer ID build.", zh: "自动更新需 Developer ID 签名版")
        case .signatureVerificationFailed:
            return CCXL10n.text("Developer ID signature check failed.", zh: "Developer ID 签名校验失败")
        case .installLocationNotWritable(let reason):
            return Self.sanitizeReason(
                reason,
                fallback: CCXL10n.text("Can't update this app folder.", zh: "当前安装位置无法自动更新")
            )
        case .installFailed(let reason):
            return Self.sanitizeReason(
                reason,
                fallback: CCXL10n.text("Couldn't install update.", zh: "安装更新失败")
            )
        case .cancelled:
            return CCXL10n.text("Update cancelled.", zh: "已取消更新")
        }
    }

    private static func sanitizeReason(_ reason: String, fallback: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("Error Domain="),
              !trimmed.contains("NSCocoaErrorDomain"),
              !trimmed.contains("NSPOSIXErrorDomain"),
              !trimmed.contains("NSURLErrorDomain"),
              !trimmed.contains("NSOSStatusErrorDomain")
        else {
            return fallback
        }
        return trimmed
    }
}

// MARK: - URL Allowlist Policy

/// Enforces strict HTTPS host allowlisting for GitHub Releases metadata and downloads.
public enum AppUpdateURLPolicy {
    public static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/lizhichaox/ccx/releases/latest")!
    public static let releasesPageURL = URL(string: "https://github.com/lizhichaox/ccx/releases/latest")!

    private static let allowedExactHosts: Set<String> = [
        "github.com",
        "api.github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
        "github-releases.githubusercontent.com",
    ]

    private static let githubUserContentSuffix = ".githubusercontent.com"

    /// Returns `true` only for credential-free `https://` URLs targeting official GitHub hosts.
    public static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              url.user == nil,
              url.password == nil
        else {
            return false
        }

        if let port = components.port, port != 443 {
            return false
        }

        guard let rawHost = components.host, !rawHost.isEmpty else {
            return false
        }
        let host = rawHost.lowercased()

        if allowedExactHosts.contains(host) {
            return true
        }

        guard host.hasSuffix(githubUserContentSuffix) else {
            return false
        }

        let subdomain = String(host.dropLast(githubUserContentSuffix.count))
        guard !subdomain.isEmpty else { return false }

        let labels = subdomain.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard !label.isEmpty,
                  label.first != "-",
                  label.last != "-",
                  label.unicodeScalars.allSatisfy({ scalar in
                      let v = scalar.value
                      return (v >= 97 && v <= 122) || (v >= 48 && v <= 57) || v == 45
                  })
            else {
                return false
            }
        }
        return true
    }
}

// MARK: - GitHub Release Parser

/// Outcome of comparing the latest GitHub Release against the currently installed version.
public enum GitHubReleaseCheckResult: Equatable, Sendable {
    case upToDate(latestVersion: AppSemanticVersion?)
    case updateAvailable(AppReleaseInfo)
}

/// Parses and validates GitHub's `/releases/latest` JSON payload.
public enum GitHubReleaseParser {
    public static let maxMetadataBytes = 1 * 1024 * 1024
    public static let maxArchiveBytes: Int64 = 100 * 1024 * 1024

    private struct ReleasePayload: Decodable {
        struct AssetPayload: Decodable {
            let name: String
            let browserDownloadURL: String
            let size: Int64

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
                case size
            }
        }

        let tagName: String
        let htmlURL: String
        let draft: Bool?
        let prerelease: Bool?
        let body: String?
        let publishedAt: String?
        let assets: [AssetPayload]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
            case body
            case publishedAt = "published_at"
            case assets
        }
    }

    /// Validates a GitHub Release JSON payload and returns an update candidate if strictly newer.
    public static func parseLatestRelease(
        data: Data,
        currentVersion: AppSemanticVersion
    ) throws -> GitHubReleaseCheckResult {
        guard data.count <= maxMetadataBytes else {
            throw AppUpdateError.responseTooLarge
        }

        let payload: ReleasePayload
        do {
            payload = try JSONDecoder().decode(ReleasePayload.self, from: data)
        } catch {
            throw AppUpdateError.invalidResponse
        }

        if payload.draft == true || payload.prerelease == true {
            return .upToDate(latestVersion: nil)
        }

        guard let version = AppSemanticVersion(parsing: payload.tagName) else {
            throw AppUpdateError.invalidResponse
        }

        if version <= currentVersion {
            return .upToDate(latestVersion: version)
        }

        guard let releaseURL = URL(string: payload.htmlURL),
              AppUpdateURLPolicy.isAllowedDownloadURL(releaseURL),
              releaseURL.host?.lowercased() == "github.com"
        else {
            throw AppUpdateError.untrustedURL
        }

        let assets = payload.assets ?? []
        let expectedZipName = "CCX-\(version.description)-macOS-universal.zip"
        let expectedChecksumsName = "SHA256SUMS.txt"
        let expectedDMGName = "CCX-\(version.description)-macOS-universal.dmg"

        guard let zipAsset = assets.first(where: { $0.name == expectedZipName }),
              let checksumsAsset = assets.first(where: { $0.name == expectedChecksumsName })
        else {
            throw AppUpdateError.missingReleaseAssets
        }

        guard zipAsset.size > 0 else {
            throw AppUpdateError.invalidResponse
        }
        guard zipAsset.size <= maxArchiveBytes else {
            throw AppUpdateError.responseTooLarge
        }
        if checksumsAsset.size < 0 {
            throw AppUpdateError.invalidResponse
        }
        if checksumsAsset.size > Int64(maxMetadataBytes) {
            throw AppUpdateError.responseTooLarge
        }

        guard let zipDownloadURL = URL(string: zipAsset.browserDownloadURL),
              AppUpdateURLPolicy.isAllowedDownloadURL(zipDownloadURL),
              let checksumsDownloadURL = URL(string: checksumsAsset.browserDownloadURL),
              AppUpdateURLPolicy.isAllowedDownloadURL(checksumsDownloadURL)
        else {
            throw AppUpdateError.untrustedURL
        }

        let dmgDownloadURL: URL?
        if let dmgAsset = assets.first(where: { $0.name == expectedDMGName }) {
            guard let url = URL(string: dmgAsset.browserDownloadURL),
                  AppUpdateURLPolicy.isAllowedDownloadURL(url)
            else {
                throw AppUpdateError.untrustedURL
            }
            dmgDownloadURL = url
        } else {
            dmgDownloadURL = nil
        }

        let publishedAt = payload.publishedAt.flatMap(parseISO8601Date)
        let info = AppReleaseInfo(
            version: version,
            tagName: payload.tagName,
            releaseURL: releaseURL,
            zipAssetName: zipAsset.name,
            zipDownloadURL: zipDownloadURL,
            zipAssetSize: zipAsset.size,
            checksumsDownloadURL: checksumsDownloadURL,
            dmgDownloadURL: dmgDownloadURL,
            releaseNotes: payload.body ?? "",
            publishedAt: publishedAt
        )
        return .updateAvailable(info)
    }

    private static func parseISO8601Date(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: raw)
    }
}

// MARK: - SHA-256 Checksum Verifier

/// Parses `SHA256SUMS.txt` manifests and verifies downloaded files in bounded streaming chunks.
public enum AppUpdateChecksumVerifier {
    private static let readChunkSize = 64 * 1024

    /// Returns `true` if `hex` consists of exactly 64 ASCII hexadecimal characters.
    public static func isValidSHA256Hex(_ hex: String) -> Bool {
        guard hex.utf8.count == 64 else { return false }
        return hex.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (v >= 48 && v <= 57) || (v >= 65 && v <= 70) || (v >= 97 && v <= 102)
        }
    }

    /// Extracts the expected lowercase 64-character SHA-256 hex digest for `assetName`
    /// from a `shasum -a 256` formatted checksum file.
    public static func parseExpectedSHA256(forAssetName assetName: String, from checksumsText: String) -> String? {
        guard !assetName.isEmpty else { return nil }

        for rawLine in checksumsText.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            guard let separatorIndex = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                continue
            }
            let hashToken = String(line[..<separatorIndex])
            guard isValidSHA256Hex(hashToken) else { continue }

            var remainder = String(line[separatorIndex...]).trimmingCharacters(in: .whitespaces)
            if remainder.hasPrefix("*") {
                remainder.removeFirst()
            }
            if remainder.hasPrefix("./") {
                remainder.removeFirst(2)
            }
            if remainder == assetName {
                return hashToken.lowercased()
            }
        }
        return nil
    }

    /// Computes the lowercase SHA-256 hex digest of a regular, non-symlink file in 64 KB chunks.
    public static func sha256Hex(ofFileAt fileURL: URL) throws -> String {
        let fd = Darwin.open(fileURL.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw AppUpdateError.checksumMismatch
        }
        defer { _ = Darwin.close(fd) }

        var st = stat()
        guard Darwin.fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            throw AppUpdateError.checksumMismatch
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: readChunkSize)

        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }
            if bytesRead > 0 {
                buffer.withUnsafeBytes { rawBuffer in
                    let slice = UnsafeRawBufferPointer(rebasing: rawBuffer.prefix(bytesRead))
                    hasher.update(bufferPointer: slice)
                }
            } else if bytesRead == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw AppUpdateError.checksumMismatch
            }
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Verifies that the file at `fileURL` matches `expectedHex`, throwing `.checksumMismatch` otherwise.
    public static func verifyFile(at fileURL: URL, expectedHex: String) throws {
        let normalizedExpected = expectedHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValidSHA256Hex(normalizedExpected) else {
            throw AppUpdateError.checksumMismatch
        }

        let actualHex = try sha256Hex(ofFileAt: fileURL)
        guard constantTimeEqual(actualHex, normalizedExpected) else {
            throw AppUpdateError.checksumMismatch
        }
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        var diff: UInt8 = 0
        for index in lhsBytes.indices {
            diff |= lhsBytes[index] ^ rhsBytes[index]
        }
        return diff == 0
    }
}

// MARK: - Code Signature Verification

/// Bundle identifier and Apple Team ID extracted dynamically from a signed code object.
public struct AppSigningIdentity: Equatable, Sendable {
    public let bundleID: String
    public let teamID: String

    public init(bundleID: String, teamID: String) {
        self.bundleID = bundleID
        self.teamID = teamID
    }
}

/// Cryptographically verifies extracted `.app` bundles against Apple's Developer ID chain,
/// dynamically matching the currently running app's Bundle ID and Team ID.
public enum AppCodeSignatureVerifier {
    /// Returns `true` when `bundleID` contains only `[A-Za-z0-9.-]` with valid dot placement.
    public static func isValidBundleID(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty,
              bundleID.count <= 255,
              !bundleID.hasPrefix("."),
              !bundleID.hasSuffix("."),
              !bundleID.contains("..")
        else {
            return false
        }
        return bundleID.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (v >= 65 && v <= 90)
                || (v >= 97 && v <= 122)
                || (v >= 48 && v <= 57)
                || v == 45
                || v == 46
        }
    }

    /// Returns `true` when `teamID` is a strict 10-character uppercase alphanumeric Apple Team ID.
    public static func isValidTeamID(_ teamID: String) -> Bool {
        guard teamID.utf8.count == 10 else { return false }
        return teamID.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (v >= 65 && v <= 90) || (v >= 48 && v <= 57)
        }
    }

    /// Dynamically inspects the currently running application's code signature to read its
    /// Bundle ID and Team ID without hardcoding any identity values in source.
    public static func currentAppSigningIdentity() -> AppSigningIdentity? {
        var selfCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &selfCode) == errSecSuccess,
              let selfCode
        else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }

        var infoCF: CFDictionary?
        let infoFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, infoFlags, &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any],
              let bundleID = info[kSecCodeInfoIdentifier as String] as? String,
              let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String,
              isValidBundleID(bundleID),
              isValidTeamID(teamID)
        else {
            return nil
        }

        return AppSigningIdentity(bundleID: bundleID, teamID: teamID)
    }

    /// Builds a strict Apple Developer ID designated requirement string for `bundleID` and `teamID`.
    public static func buildDeveloperIDRequirementString(bundleID: String, teamID: String) -> String? {
        guard isValidBundleID(bundleID), isValidTeamID(teamID) else {
            return nil
        }
        return "anchor apple generic and identifier \"\(bundleID)\" and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// Verifies bundle structure, `Info.plist` metadata, Developer ID code signature across all
    /// architectures, Team ID match, and Hardened Runtime flag for an extracted `.app` bundle.
    public static func verifyDownloadedApp(
        at appURL: URL,
        expectedBundleID: String,
        expectedVersion: AppSemanticVersion,
        expectedTeamID: String?
    ) throws {
        let uid = Darwin.getuid()
        guard isOwnedRealDirectory(at: appURL, uid: uid) else {
            throw AppUpdateError.invalidBundleMetadata
        }

        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist", isDirectory: false)
        guard isOwnedRealDirectory(at: contentsURL, uid: uid),
              isOwnedRegularFile(at: infoPlistURL, uid: uid)
        else {
            throw AppUpdateError.invalidBundleMetadata
        }

        let infoPlistData: Data
        do {
            infoPlistData = try readOwnedRegularFile(at: infoPlistURL, uid: uid, maxBytes: 1024 * 1024)
        } catch {
            throw AppUpdateError.invalidBundleMetadata
        }

        guard let plistObject = try? PropertyListSerialization.propertyList(from: infoPlistData, format: nil),
              let plist = plistObject as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String,
              bundleID == expectedBundleID,
              let shortVersion = plist["CFBundleShortVersionString"] as? String,
              shortVersion == expectedVersion.description,
              let executableName = plist["CFBundleExecutable"] as? String,
              isSafeSinglePathComponent(executableName)
        else {
            throw AppUpdateError.invalidBundleMetadata
        }

        let macOSDirURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let executableURL = macOSDirURL.appendingPathComponent(executableName, isDirectory: false)
        guard isOwnedRealDirectory(at: macOSDirURL, uid: uid),
              isOwnedExecutableRegularFile(at: executableURL, uid: uid)
        else {
            throw AppUpdateError.invalidBundleMetadata
        }

        guard let expectedTeamID, isValidTeamID(expectedTeamID) else {
            throw AppUpdateError.unsignedCurrentApp
        }

        guard let requirementString = buildDeveloperIDRequirementString(
            bundleID: expectedBundleID,
            teamID: expectedTeamID
        ) else {
            throw AppUpdateError.invalidBundleMetadata
        }

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw AppUpdateError.signatureVerificationFailed(createStatus)
        }

        var requirement: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(requirementString as CFString, SecCSFlags(), &requirement)
        guard reqStatus == errSecSuccess, let requirement else {
            throw AppUpdateError.signatureVerificationFailed(reqStatus)
        }

        let checkFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        let validityStatus = SecStaticCodeCheckValidity(staticCode, checkFlags, requirement)
        guard validityStatus == errSecSuccess else {
            throw AppUpdateError.signatureVerificationFailed(validityStatus)
        }

        var infoCF: CFDictionary?
        let infoFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
        let infoStatus = SecCodeCopySigningInformation(staticCode, infoFlags, &infoCF)
        guard infoStatus == errSecSuccess,
              let signingInfo = infoCF as? [String: Any],
              let signedIdentifier = signingInfo[kSecCodeInfoIdentifier as String] as? String,
              signedIdentifier == expectedBundleID,
              let signedTeamID = signingInfo[kSecCodeInfoTeamIdentifier as String] as? String,
              signedTeamID == expectedTeamID,
              let rawFlags = (signingInfo[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value,
              (rawFlags & SecCodeSignatureFlags.runtime.rawValue) != 0
        else {
            throw AppUpdateError.signatureVerificationFailed(infoStatus == errSecSuccess ? errSecCSReqFailed : infoStatus)
        }
    }

    private static func isSafeSinglePathComponent(_ component: String) -> Bool {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("/"),
              !component.contains("\\"),
              !component.contains("\0")
        else {
            return false
        }
        return true
    }

    private static func isOwnedRealDirectory(at url: URL, uid: uid_t) -> Bool {
        let path = normalizedPath(url.path)
        var st = stat()
        return Darwin.lstat(path, &st) == 0
            && (st.st_mode & S_IFMT) == S_IFDIR
            && st.st_uid == uid
    }

    private static func isOwnedRegularFile(at url: URL, uid: uid_t) -> Bool {
        let path = normalizedPath(url.path)
        var st = stat()
        return Darwin.lstat(path, &st) == 0
            && (st.st_mode & S_IFMT) == S_IFREG
            && st.st_uid == uid
    }

    private static func isOwnedExecutableRegularFile(at url: URL, uid: uid_t) -> Bool {
        let path = normalizedPath(url.path)
        var st = stat()
        guard Darwin.lstat(path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == uid
        else {
            return false
        }
        return (st.st_mode & 0o111) != 0
    }

    private static func readOwnedRegularFile(at url: URL, uid: uid_t, maxBytes: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw AppUpdateError.invalidBundleMetadata }
        defer { _ = Darwin.close(fd) }

        var st = stat()
        guard Darwin.fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == uid,
              st.st_size >= 0,
              st.st_size <= Int64(maxBytes)
        else {
            throw AppUpdateError.invalidBundleMetadata
        }

        var result = Data()
        result.reserveCapacity(Int(st.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                if result.count + n > maxBytes {
                    throw AppUpdateError.invalidBundleMetadata
                }
                result.append(buffer, count: n)
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw AppUpdateError.invalidBundleMetadata
            }
        }
        return result
    }

    private static func normalizedPath(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}

// MARK: - Install Eligibility & Atomic Installer

/// Whether the running `.app` bundle can be atomically replaced in place or requires manual update.
public enum AppInstallEligibility: Equatable, Sendable {
    case canInstallInPlace(targetAppURL: URL)
    case manualRequired(reason: String)
}

/// Manages private staging directories, archive extraction, sibling staging, and detached
/// atomic swap-and-relaunch execution.
public enum AppUpdateInstaller {
    internal enum Messages {
        static var moveToApplicationsFirst: String {
            CCXL10n.text("Move CCX.app to Applications first.", zh: "请先将 CCX.app 移至「应用程序」")
        }

        static var appFolderNotWritable: String {
            CCXL10n.text("App folder not writable. Use GitHub.", zh: "应用目录无写入权限，请去 GitHub 下载")
        }

        static var prepareUpdateFolderFailed: String {
            CCXL10n.text("Couldn't prepare update folder.", zh: "无法创建更新临时目录")
        }

        static var validateAppBundleFailed: String {
            CCXL10n.text("Couldn't validate app bundle.", zh: "无法校验目标应用包")
        }

        static var writeUpdateToFolderFailed: String {
            CCXL10n.text("Couldn't write update to folder.", zh: "无法写入更新到目标目录")
        }

        static var verifyStagedBundleFailed: String {
            CCXL10n.text("Couldn't verify staged bundle.", zh: "无法校验暂存更新包")
        }

        static var verifyUpdateBundleFailed: String {
            CCXL10n.text("Couldn't verify update bundle.", zh: "重启前应用包校验失败")
        }

        static var startUpdaterHelperFailed: String {
            CCXL10n.text("Couldn't start updater helper.", zh: "无法启动更新辅助进程")
        }

        static var createTempDownloadFileFailed: String {
            CCXL10n.text("Couldn't create temp download file.", zh: "无法创建临时下载文件")
        }

        static var writeDownloadedUpdateFailed: String {
            CCXL10n.text("Couldn't write downloaded update.", zh: "写入更新文件失败")
        }

        static var genericUpdateFailed: String {
            CCXL10n.text("Update failed. Try again or GitHub.", zh: "更新失败，请重试或前往 GitHub")
        }

        static var allAuxiliaryMessages: [String] {
            [
                prepareUpdateFolderFailed,
                validateAppBundleFailed,
                writeUpdateToFolderFailed,
                verifyStagedBundleFailed,
                verifyUpdateBundleFailed,
                startUpdaterHelperFailed,
                createTempDownloadFileFailed,
                writeDownloadedUpdateFailed,
                genericUpdateFailed,
            ]
        }
    }

    public static func updatesRootDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CCXUpdates", isDirectory: true)
    }

    /// Evaluates whether `bundleURL` is a real, writable, non-translocated `.app` bundle suitable
    /// for in-place atomic replacement.
    public static func installEligibility(
        for bundleURL: URL,
        isWritable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) }
    ) -> AppInstallEligibility {
        let normalizedBundlePath = normalizedPath(bundleURL.path)
        let normalizedBundleURL = URL(fileURLWithPath: normalizedBundlePath, isDirectory: true)

        guard normalizedBundleURL.pathExtension == "app" else {
            return .manualRequired(reason: Messages.moveToApplicationsFirst)
        }

        if normalizedBundlePath.contains("/AppTranslocation/") || normalizedBundlePath.hasPrefix("/Volumes/") {
            return .manualRequired(reason: Messages.moveToApplicationsFirst)
        }

        var st = stat()
        guard Darwin.lstat(normalizedBundlePath, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR
        else {
            return .manualRequired(reason: Messages.moveToApplicationsFirst)
        }

        let parentPath = normalizedPath(normalizedBundleURL.deletingLastPathComponent().path)
        guard isWritable(parentPath), isWritable(normalizedBundlePath) else {
            return .manualRequired(reason: Messages.appFolderNotWritable)
        }

        return .canInstallInPlace(targetAppURL: normalizedBundleURL)
    }

    /// Creates a new user-private (`0700`) staging directory inside `<tmp>/CCXUpdates`.
    public static func createPrivateStagingDirectory() throws -> URL {
        let rootURL = updatesRootDirectoryURL()
        guard ensurePrivateDirectory(at: rootURL) else {
            throw AppUpdateError.installFailed(Messages.prepareUpdateFolderFailed)
        }
        let stagingURL = rootURL.appendingPathComponent("update-\(UUID().uuidString)", isDirectory: true)
        guard ensurePrivateDirectory(at: stagingURL) else {
            throw AppUpdateError.installFailed(Messages.prepareUpdateFolderFailed)
        }
        return stagingURL
    }

    /// Removes stale temporary update directories from `<tmp>/CCXUpdates` safely without following symlinks.
    public static func cleanupStaleStagingDirectories(olderThan maxAge: TimeInterval = 86_400) {
        let rootURL = updatesRootDirectoryURL()
        let uid = Darwin.getuid()
        guard isOwnedRealDirectory(at: rootURL, uid: uid) else { return }

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: []
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-maxAge)
        for entry in entries {
            let entryPath = normalizedPath(entry.path)
            var st = stat()
            guard Darwin.lstat(entryPath, &st) == 0, st.st_uid == uid else { continue }

            let shouldRemove: Bool
            if maxAge <= 0 {
                shouldRemove = true
            } else {
                let values = try? entry.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let timestamp = values?.contentModificationDate ?? values?.creationDate ?? .distantPast
                shouldRemove = timestamp < cutoff
            }

            guard shouldRemove else { continue }
            if (st.st_mode & S_IFMT) == S_IFLNK {
                _ = Darwin.unlink(entryPath)
            } else {
                try? fm.removeItem(at: entry)
            }
        }
    }

    /// Extracts a downloaded `.zip` archive using `/usr/bin/ditto` and validates that `CCX.app`
    /// is present as a real, non-symlink directory owned by the current user.
    public static func extractZip(at zipURL: URL, to destinationDir: URL) throws -> URL {
        let uid = Darwin.getuid()
        let zipPath = normalizedPath(zipURL.path)
        var zipStat = stat()
        guard Darwin.lstat(zipPath, &zipStat) == 0,
              (zipStat.st_mode & S_IFMT) == S_IFREG,
              zipStat.st_uid == uid,
              isOwnedRealDirectory(at: destinationDir, uid: uid)
        else {
            throw AppUpdateError.extractionFailed
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipPath, normalizedPath(destinationDir.path)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw AppUpdateError.extractionFailed
        }

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw AppUpdateError.extractionFailed
        }

        let extractedAppURL = destinationDir.appendingPathComponent("CCX.app", isDirectory: true)
        guard isOwnedRealDirectory(at: extractedAppURL, uid: uid) else {
            throw AppUpdateError.extractionFailed
        }
        return extractedAppURL
    }

    /// Stages the verified `.app` bundle next to `targetAppURL` (on the same volume) BEFORE quitting
    /// so permission or disk-space errors are caught safely while CCX is still running.
    public static func stageSiblingApp(from verifiedAppURL: URL, nextTo targetAppURL: URL) throws -> URL {
        let uid = Darwin.getuid()
        let normalizedTargetPath = normalizedPath(targetAppURL.path)
        var targetStat = stat()
        guard isOwnedRealDirectory(at: verifiedAppURL, uid: uid),
              Darwin.lstat(normalizedTargetPath, &targetStat) == 0,
              (targetStat.st_mode & S_IFMT) == S_IFDIR
        else {
            throw AppUpdateError.installFailed(Messages.validateAppBundleFailed)
        }

        let parentDir = URL(fileURLWithPath: normalizedTargetPath, isDirectory: true).deletingLastPathComponent()
        let stagedURL = parentDir.appendingPathComponent(".CCX-update-\(UUID().uuidString).app", isDirectory: true)
        let fm = FileManager.default

        do {
            try fm.moveItem(at: verifiedAppURL, to: stagedURL)
        } catch {
            do {
                try fm.copyItem(at: verifiedAppURL, to: stagedURL)
            } catch {
                try? fm.removeItem(at: stagedURL)
                throw AppUpdateError.installFailed(Messages.writeUpdateToFolderFailed)
            }
        }

        guard isOwnedRealDirectory(at: stagedURL, uid: uid) else {
            try? fm.removeItem(at: stagedURL)
            throw AppUpdateError.installFailed(Messages.verifyStagedBundleFailed)
        }

        return stagedURL
    }

    /// Spawns a detached `/bin/sh` helper using positional arguments (zero shell interpolation)
    /// that waits for `currentPID` to exit, atomically swaps the staged bundle into place with
    /// rollback protection, refreshes LaunchServices, and optionally relaunches the updated app.
    public static func launchAtomicReplaceAndRelaunch(
        stagedSiblingAppURL: URL,
        targetAppURL: URL,
        cleanupDirectoryURL: URL,
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        relaunch: Bool = true
    ) throws {
        let stagedPath = normalizedPath(stagedSiblingAppURL.path)
        let targetPath = normalizedPath(targetAppURL.path)
        let cleanupPath = normalizedPath(cleanupDirectoryURL.path)

        var stagedStat = stat()
        var targetStat = stat()
        guard Darwin.lstat(stagedPath, &stagedStat) == 0,
              (stagedStat.st_mode & S_IFMT) == S_IFDIR,
              Darwin.lstat(targetPath, &targetStat) == 0,
              (targetStat.st_mode & S_IFMT) == S_IFDIR
        else {
            throw AppUpdateError.installFailed(Messages.verifyUpdateBundleFailed)
        }

        let parentDir = URL(fileURLWithPath: targetPath, isDirectory: true).deletingLastPathComponent()
        let backupPath = normalizedPath(
            parentDir.appendingPathComponent(".CCX-backup-\(UUID().uuidString).app", isDirectory: true).path
        )

        let script = """
        pid=$1
        staged=$2
        target=$3
        backup=$4
        cleanup=$5
        relaunch=$6
        i=0
        while /bin/kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
          /bin/sleep 0.1
          i=$((i + 1))
        done
        if /bin/kill -0 "$pid" 2>/dev/null; then
          /bin/rm -rf -- "$staged" "$cleanup"
          exit 0
        fi
        if ! /bin/mv -- "$target" "$backup"; then
          /bin/rm -rf -- "$staged" "$cleanup"
          exit 1
        fi
        if ! /bin/mv -- "$staged" "$target"; then
          /bin/mv -- "$backup" "$target" 2>/dev/null || true
          /bin/rm -rf -- "$staged" "$cleanup"
          exit 1
        fi
        /bin/rm -rf -- "$backup" "$cleanup"
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -- "$target" >/dev/null 2>&1 || true
        if [ "$relaunch" = "1" ]; then
          exec /usr/bin/open -- "$target"
        fi
        exit 0
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            script,
            "ccx-updater",
            String(currentPID),
            stagedPath,
            targetPath,
            backupPath,
            cleanupPath,
            relaunch ? "1" : "0",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw AppUpdateError.installFailed(Messages.startUpdaterHelperFailed)
        }
    }

    private static func ensurePrivateDirectory(at url: URL) -> Bool {
        let path = normalizedPath(url.path)
        let uid = Darwin.getuid()
        var st = stat()
        if Darwin.lstat(path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == uid else { return false }
            return Darwin.chmod(path, 0o700) == 0
        }
        guard errno == ENOENT else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return false
        }
        guard Darwin.lstat(path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == uid
        else {
            return false
        }
        return Darwin.chmod(path, 0o700) == 0
    }

    private static func isOwnedRealDirectory(at url: URL, uid: uid_t) -> Bool {
        let path = normalizedPath(url.path)
        var st = stat()
        return Darwin.lstat(path, &st) == 0
            && (st.st_mode & S_IFMT) == S_IFDIR
            && st.st_uid == uid
    }

    private static func normalizedPath(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}

// MARK: - Network Transport

/// Abstraction over HTTPS metadata fetches and streaming file downloads for testability.
public protocol AppUpdateTransport: Sendable {
    func fetchData(from url: URL, maxBytes: Int, userAgent: String) async throws -> Data
    func downloadFile(
        from url: URL,
        to destinationURL: URL,
        maxBytes: Int64,
        userAgent: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws
    func downloadFile(
        from url: URL,
        to destinationURL: URL,
        maxBytes: Int64,
        expectedBytesHint: Int64?,
        userAgent: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws
}

public extension AppUpdateTransport {
    func downloadFile(
        from url: URL,
        to destinationURL: URL,
        maxBytes: Int64,
        expectedBytesHint: Int64?,
        userAgent: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await downloadFile(
            from: url,
            to: destinationURL,
            maxBytes: maxBytes,
            userAgent: userAgent,
            onProgress: onProgress
        )
    }
}

/// Ephemeral `URLSession`-backed transport enforcing HTTPS host allowlisting across redirects,
/// strict byte limits, rate-limit classification, and streaming progress delivery.
public final class URLSessionAppUpdateTransport: AppUpdateTransport {
    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval

    public init(requestTimeout: TimeInterval = 20, resourceTimeout: TimeInterval = 300) {
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
    }

    public func fetchData(from url: URL, maxBytes: Int, userAgent: String) async throws -> Data {
        guard AppUpdateURLPolicy.isAllowedDownloadURL(url) else {
            throw AppUpdateError.untrustedURL
        }
        guard maxBytes > 0 else {
            throw AppUpdateError.responseTooLarge
        }

        let request = makeRequest(url: url, userAgent: userAgent)
        return try await runStreamingRequest(
            request: request,
            destinationURL: nil,
            maxBytes: Int64(maxBytes),
            expectedBytesHint: nil,
            onProgress: nil
        )
    }

    public func downloadFile(
        from url: URL,
        to destinationURL: URL,
        maxBytes: Int64,
        userAgent: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await downloadFile(
            from: url,
            to: destinationURL,
            maxBytes: maxBytes,
            expectedBytesHint: nil,
            userAgent: userAgent,
            onProgress: onProgress
        )
    }

    public func downloadFile(
        from url: URL,
        to destinationURL: URL,
        maxBytes: Int64,
        expectedBytesHint: Int64?,
        userAgent: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard AppUpdateURLPolicy.isAllowedDownloadURL(url) else {
            throw AppUpdateError.untrustedURL
        }
        guard maxBytes > 0 else {
            throw AppUpdateError.responseTooLarge
        }

        let request = makeRequest(url: url, userAgent: userAgent)
        _ = try await runStreamingRequest(
            request: request,
            destinationURL: destinationURL,
            maxBytes: maxBytes,
            expectedBytesHint: expectedBytesHint,
            onProgress: onProgress
        )
    }

    private func makeRequest(url: URL, userAgent: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.timeoutInterval = requestTimeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if url.host?.lowercased() == "api.github.com" {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        }
        return request
    }

    private func runStreamingRequest(
        request: URLRequest,
        destinationURL: URL?,
        maxBytes: Int64,
        expectedBytesHint: Int64?,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> Data {
        let taskBox = OSAllocatedUnfairLock<URLSessionDataTask?>(initialState: nil)
        let cancelledFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let delegate = StreamingUpdateSessionDelegate(
                    destinationURL: destinationURL,
                    maxBytes: maxBytes,
                    expectedBytesHint: expectedBytesHint,
                    onProgress: onProgress,
                    continuation: continuation
                )
                let config = URLSessionConfiguration.ephemeral
                config.httpShouldSetCookies = false
                config.httpCookieAcceptPolicy = .never
                config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.urlCache = nil
                config.timeoutIntervalForRequest = requestTimeout
                config.timeoutIntervalForResource = resourceTimeout

                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                let task = session.dataTask(with: request)
                let alreadyCancelled = cancelledFlag.withLock { $0 }
                if alreadyCancelled {
                    session.invalidateAndCancel()
                    delegate.finishWithError(AppUpdateError.cancelled)
                    return
                }
                taskBox.withLock { $0 = task }
                task.resume()
                session.finishTasksAndInvalidate()
            }
        } onCancel: {
            cancelledFlag.withLock { $0 = true }
            let task = taskBox.withLock { $0 }
            task?.cancel()
        }
    }
}

private final class StreamingUpdateSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        var buffer = Data()
        var fileDescriptor: Int32 = -1
        var receivedBytes: Int64 = 0
        var expectedBytes: Int64 = -1
        var lastReportedProgress: Double = -1
        var overrideError: AppUpdateError?
        var continuation: CheckedContinuation<Data, Error>?
    }

    private let destinationURL: URL?
    private let maxBytes: Int64
    private let expectedBytesHint: Int64?
    private let onProgress: (@Sendable (Double) -> Void)?
    private let state: OSAllocatedUnfairLock<State>

    init(
        destinationURL: URL?,
        maxBytes: Int64,
        expectedBytesHint: Int64?,
        onProgress: (@Sendable (Double) -> Void)?,
        continuation: CheckedContinuation<Data, Error>
    ) {
        self.destinationURL = destinationURL
        self.maxBytes = maxBytes
        self.expectedBytesHint = expectedBytesHint
        self.onProgress = onProgress
        self.state = OSAllocatedUnfairLock(initialState: State(continuation: continuation))
        super.init()
    }

    func finishWithError(_ error: AppUpdateError) {
        let continuation = state.withLock { state -> CheckedContinuation<Data, Error>? in
            closeAndCleanupOnFailure(&state)
            let cont = state.continuation
            state.continuation = nil
            return cont
        }
        continuation?.resume(throwing: error)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let targetURL = request.url, AppUpdateURLPolicy.isAllowedDownloadURL(targetURL) else {
            state.withLock { $0.overrideError = .untrustedURL }
            task.cancel()
            completionHandler(nil)
            return
        }
        var sanitizedRequest = request
        sanitizedRequest.httpShouldHandleCookies = false
        completionHandler(sanitizedRequest)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            fail(task: dataTask, error: .invalidResponse, completionHandler: completionHandler)
            return
        }

        if let finalURL = http.url, !AppUpdateURLPolicy.isAllowedDownloadURL(finalURL) {
            fail(task: dataTask, error: .untrustedURL, completionHandler: completionHandler)
            return
        }

        if http.statusCode == 429 {
            fail(task: dataTask, error: .rateLimited, completionHandler: completionHandler)
            return
        }
        if http.statusCode == 403 {
            let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining")
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
            if remaining == "0" || retryAfter != nil {
                fail(task: dataTask, error: .rateLimited, completionHandler: completionHandler)
                return
            }
        }
        guard (200...299).contains(http.statusCode) else {
            fail(task: dataTask, error: .httpStatus(http.statusCode), completionHandler: completionHandler)
            return
        }

        let expectedLength = http.expectedContentLength
        if expectedLength > maxBytes {
            fail(task: dataTask, error: .responseTooLarge, completionHandler: completionHandler)
            return
        }

        let effectiveExpectedBytes: Int64
        if expectedLength > 0 {
            effectiveExpectedBytes = expectedLength
        } else if let hint = expectedBytesHint, hint > 0 {
            effectiveExpectedBytes = min(hint, maxBytes)
        } else {
            effectiveExpectedBytes = -1
        }

        let openSucceeded: Bool = state.withLock { state in
            state.expectedBytes = effectiveExpectedBytes
            if let destinationURL {
                let fd = Darwin.open(destinationURL.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
                guard fd >= 0 else {
                    state.overrideError = .installFailed(AppUpdateInstaller.Messages.createTempDownloadFileFailed)
                    return false
                }
                state.fileDescriptor = fd
            }
            return true
        }

        guard openSucceeded else {
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let progressToEmit: Double? = state.withLock { state in
            guard state.overrideError == nil else { return nil }

            let nextTotal = state.receivedBytes + Int64(data.count)
            if nextTotal > maxBytes {
                state.overrideError = .responseTooLarge
                return nil
            }

            if destinationURL != nil {
                guard state.fileDescriptor >= 0, writeAll(data, to: state.fileDescriptor) else {
                    state.overrideError = .installFailed(AppUpdateInstaller.Messages.writeDownloadedUpdateFailed)
                    return nil
                }
            } else {
                state.buffer.append(data)
            }

            state.receivedBytes = nextTotal
            guard onProgress != nil, state.expectedBytes > 0 else { return nil }
            let ratio = min(max(Double(nextTotal) / Double(state.expectedBytes), 0), 1)
            if state.lastReportedProgress < 0 || ratio - state.lastReportedProgress >= 0.01 || ratio >= 1.0 {
                state.lastReportedProgress = ratio
                return ratio
            }
            return nil
        }

        let shouldCancel = state.withLock { $0.overrideError != nil }
        if shouldCancel {
            dataTask.cancel()
            return
        }

        if let progressToEmit, let onProgress {
            onProgress(progressToEmit)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome: (CheckedContinuation<Data, Error>?, Result<Data, Error>, Bool) = state.withLock { state in
            guard let continuation = state.continuation else {
                closeFileDescriptor(&state)
                return (nil, .failure(AppUpdateError.cancelled), false)
            }
            state.continuation = nil

            if let overrideError = state.overrideError {
                closeAndCleanupOnFailure(&state)
                return (continuation, .failure(overrideError), false)
            }

            if let error {
                closeAndCleanupOnFailure(&state)
                return (continuation, .failure(Self.mapError(error)), false)
            }

            closeFileDescriptor(&state)
            let emitFinalProgress = onProgress != nil && state.lastReportedProgress < 1.0
            if emitFinalProgress {
                state.lastReportedProgress = 1.0
            }
            return (continuation, .success(state.buffer), emitFinalProgress)
        }

        if outcome.2, let onProgress {
            onProgress(1.0)
        }
        if let continuation = outcome.0 {
            continuation.resume(with: outcome.1)
        }
    }

    private func fail(
        task: URLSessionDataTask,
        error: AppUpdateError,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        state.withLock { $0.overrideError = error }
        completionHandler(.cancel)
    }

    private func closeFileDescriptor(_ state: inout State) {
        if state.fileDescriptor >= 0 {
            _ = Darwin.close(state.fileDescriptor)
            state.fileDescriptor = -1
        }
    }

    private func closeAndCleanupOnFailure(_ state: inout State) {
        closeFileDescriptor(&state)
        if let destinationURL {
            _ = Darwin.unlink(destinationURL.path)
        }
    }

    private func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return true }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static func mapError(_ error: Error) -> AppUpdateError {
        if let updateError = error as? AppUpdateError {
            return updateError
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .notConnectedToInternet,
                 .networkConnectionLost,
                 .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed,
                 .dataNotAllowed,
                 .internationalRoamingOff:
                return .networkUnavailable
            default:
                return .networkUnavailable
            }
        }
        return .networkUnavailable
    }
}

// MARK: - Update Manager State Machine

/// Live lifecycle state of the native CCX in-app updater.
public enum AppUpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    case available(AppReleaseInfo)
    case downloading(AppReleaseInfo, progress: Double)
    case verifying(AppReleaseInfo)
    case readyToInstall(AppReleaseInfo)
    case installing(AppReleaseInfo)
    case failed(message: String, release: AppReleaseInfo?)
}

/// Coordinates background and manual update checks, verified pre-downloads,
/// silent idle/quit installation, and zero-wait manual atomic restarts.
@MainActor
public final class AppUpdateManager: ObservableObject {
    public static let autoCheckKey = "CCXAutoCheckUpdates"
    public static let lastCheckDateKey = "CCXLastUpdateCheckDate"
    public static let dismissedBannerVersionKey = "CCXDismissedUpdateBannerVersion"

    public typealias ExtractZipHandler = @Sendable (
        _ zipURL: URL,
        _ destinationDir: URL
    ) throws -> URL

    public typealias VerifyDownloadedAppHandler = @Sendable (
        _ appURL: URL,
        _ expectedBundleID: String,
        _ expectedVersion: AppSemanticVersion,
        _ expectedTeamID: String?
    ) throws -> Void

    public typealias InstallPreparedAppHandler = @Sendable (
        _ verifiedAppURL: URL,
        _ targetAppURL: URL,
        _ cleanupDirectoryURL: URL,
        _ relaunch: Bool
    ) throws -> Void

    private struct PreparedUpdate: Sendable {
        let release: AppReleaseInfo
        let verifiedAppURL: URL
        let stagingDirURL: URL
        let targetAppURL: URL
    }

    @Published public private(set) var state: AppUpdateState = .idle
    @Published public var automaticallyChecksForUpdates: Bool {
        didSet {
            userDefaults.set(automaticallyChecksForUpdates, forKey: Self.autoCheckKey)
            if !automaticallyChecksForUpdates {
                cancelIdleInstallTask()
                return
            }
            switch state {
            case .readyToInstall:
                scheduleSilentInstallIfIdle()
            case .available(let release):
                if let prepared = preparedUpdate, prepared.release.version == release.version {
                    state = .readyToInstall(release)
                    scheduleSilentInstallIfIdle()
                } else if case .canInstallInPlace(let targetAppURL) = installEligibilityProvider(currentBundleURL) {
                    startDownloadAndVerify(
                        release: release,
                        targetAppURL: targetAppURL,
                        autoInstallImmediately: false,
                        silentFailure: true
                    )
                }
            case .idle, .checking, .upToDate, .downloading, .verifying, .installing, .failed:
                break
            }
        }
    }
    @Published public private(set) var lastCheckDate: Date?
    @Published public private(set) var dismissedBannerVersion: String?

    /// Closure checked before installing and again before terminating to prevent interrupting
    /// an active recording or save dialog.
    public var canTerminateNow: () -> Bool
    /// Closure checked before performing an automatic silent restart while idle.
    /// Defaults to `{ false }` so callers opt in explicitly when no Pins, captures, recordings,
    /// OCR jobs, save dialogs, or app windows are active.
    public var canInstallSilentlyNow: () -> Bool
    /// Called when installation is deferred because `canTerminateNow()` returned `false`.
    public var onBlockedByActiveSession: () -> Void
    /// Called when user-initiated installation encounters a non-cancellation error or an
    /// ineligible install location (never invoked for silent background checks or pre-downloads).
    public var onUserFacingError: ((String) -> Void)?
    /// Called after the detached swap-and-relaunch helper is running to terminate the current app.
    public var terminateHandler: () -> Void

    private let userDefaults: UserDefaults
    private let currentVersion: AppSemanticVersion
    private let currentBundleID: String
    private let currentBundleURL: URL
    private let currentTeamIDProvider: @Sendable () -> String?
    private let transport: any AppUpdateTransport
    private let checkInterval: TimeInterval
    private let idleInstallDebounceInterval: TimeInterval
    private let installEligibilityProvider: @Sendable (URL) -> AppInstallEligibility
    private let extractHandler: ExtractZipHandler
    private let verifyHandler: VerifyDownloadedAppHandler
    private let installHandler: InstallPreparedAppHandler

    nonisolated(unsafe) private var activeTask: Task<Void, Never>?
    private var activeTaskID = UUID()
    nonisolated(unsafe) private var activeStagingDirURL: URL?
    nonisolated(unsafe) private var preparedUpdate: PreparedUpdate?
    nonisolated(unsafe) private var idleInstallTask: Task<Void, Never>?
    private var idleInstallTaskID = UUID()
    private var attemptedSilentInstallVersion: String?

    public init(
        userDefaults: UserDefaults = .standard,
        currentVersion: AppSemanticVersion? = nil,
        currentBundleID: String? = nil,
        currentBundleURL: URL? = nil,
        currentTeamIDProvider: @escaping @Sendable () -> String? = {
            AppCodeSignatureVerifier.currentAppSigningIdentity()?.teamID
        },
        transport: any AppUpdateTransport = URLSessionAppUpdateTransport(),
        checkInterval: TimeInterval = 86_400,
        idleInstallDebounceInterval: TimeInterval = 3.0,
        installEligibilityProvider: @escaping @Sendable (URL) -> AppInstallEligibility = {
            AppUpdateInstaller.installEligibility(for: $0)
        },
        extractHandler: @escaping ExtractZipHandler = { zipURL, destinationDir in
            try AppUpdateInstaller.extractZip(at: zipURL, to: destinationDir)
        },
        verifyHandler: @escaping VerifyDownloadedAppHandler = { appURL, bundleID, version, teamID in
            try AppCodeSignatureVerifier.verifyDownloadedApp(
                at: appURL,
                expectedBundleID: bundleID,
                expectedVersion: version,
                expectedTeamID: teamID
            )
        },
        installHandler: @escaping InstallPreparedAppHandler = { verifiedAppURL, targetAppURL, cleanupDirectoryURL, relaunch in
            let stagedURL = try AppUpdateInstaller.stageSiblingApp(
                from: verifiedAppURL,
                nextTo: targetAppURL
            )
            do {
                try AppUpdateInstaller.launchAtomicReplaceAndRelaunch(
                    stagedSiblingAppURL: stagedURL,
                    targetAppURL: targetAppURL,
                    cleanupDirectoryURL: cleanupDirectoryURL,
                    relaunch: relaunch
                )
            } catch {
                try? FileManager.default.removeItem(at: stagedURL)
                throw error
            }
        },
        canTerminateNow: @escaping @MainActor () -> Bool = { true },
        canInstallSilentlyNow: @escaping @MainActor () -> Bool = { false },
        onBlockedByActiveSession: @escaping @MainActor () -> Void = {},
        onUserFacingError: (@MainActor (String) -> Void)? = nil,
        terminateHandler: @escaping @MainActor () -> Void = {}
    ) {
        self.userDefaults = userDefaults

        if let currentVersion {
            self.currentVersion = currentVersion
        } else if let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                  let parsed = AppSemanticVersion(parsing: raw) {
            self.currentVersion = parsed
        } else {
            self.currentVersion = AppSemanticVersion(major: 0, minor: 0, patch: 0)
        }

        self.currentBundleID = currentBundleID ?? Bundle.main.bundleIdentifier ?? "com.lizhichaox.ccx"
        self.currentBundleURL = currentBundleURL ?? Bundle.main.bundleURL
        self.currentTeamIDProvider = currentTeamIDProvider
        self.transport = transport
        self.checkInterval = checkInterval
        self.idleInstallDebounceInterval = max(0, idleInstallDebounceInterval)
        self.installEligibilityProvider = installEligibilityProvider
        self.extractHandler = extractHandler
        self.verifyHandler = verifyHandler
        self.installHandler = installHandler
        self.canTerminateNow = canTerminateNow
        self.canInstallSilentlyNow = canInstallSilentlyNow
        self.onBlockedByActiveSession = onBlockedByActiveSession
        self.onUserFacingError = onUserFacingError
        self.terminateHandler = terminateHandler

        if userDefaults.object(forKey: Self.autoCheckKey) == nil {
            self.automaticallyChecksForUpdates = true
        } else {
            self.automaticallyChecksForUpdates = userDefaults.bool(forKey: Self.autoCheckKey)
        }
        self.lastCheckDate = userDefaults.object(forKey: Self.lastCheckDateKey) as? Date
        self.dismissedBannerVersion = userDefaults.string(forKey: Self.dismissedBannerVersionKey)
    }

    deinit {
        idleInstallTask?.cancel()
        activeTask?.cancel()
        if let stagingDir = activeStagingDirURL {
            try? FileManager.default.removeItem(at: stagingDir)
        }
        if let preparedStagingDir = preparedUpdate?.stagingDirURL {
            try? FileManager.default.removeItem(at: preparedStagingDir)
        }
    }

    /// The latest discovered release when available, in progress, ready, or retained after a retryable failure.
    public var availableRelease: AppReleaseInfo? {
        switch state {
        case .available(let release),
             .downloading(let release, _),
             .verifying(let release),
             .readyToInstall(let release),
             .installing(let release):
            return release
        case .failed(_, let release):
            return release
        case .idle, .checking, .upToDate:
            return nil
        }
    }

    /// Whether the menu bar popover should show the compact update banner.
    public var shouldShowPopoverBanner: Bool {
        switch state {
        case .available(let release), .readyToInstall(let release):
            return dismissedBannerVersion != release.version.description
        case .downloading, .verifying, .installing:
            return true
        case .failed(_, let release):
            return release != nil
        case .idle, .checking, .upToDate:
            return false
        }
    }

    /// Whether a check, download, verification, or installation task is currently running.
    public var isBusy: Bool {
        switch state {
        case .checking, .downloading, .verifying, .installing:
            return true
        case .idle, .upToDate, .available, .readyToInstall, .failed:
            return false
        }
    }

    /// Runs a silent background check if automatic checks are enabled, no update is already
    /// prepared or in progress, and `checkInterval` has elapsed.
    public func checkForUpdatesInBackgroundIfDue(now: Date = Date()) {
        guard automaticallyChecksForUpdates else { return }
        guard !isBusy, preparedUpdate == nil else { return }
        if let lastCheckDate, now.timeIntervalSince(lastCheckDate) < checkInterval {
            return
        }
        performCheckForUpdates(userInitiated: false, now: now)
    }

    /// Checks GitHub Releases for a newer version of CCX.
    public func checkForUpdates(userInitiated: Bool) {
        performCheckForUpdates(userInitiated: userInitiated, now: Date())
    }

    /// Installs `availableRelease`. When the update is already downloaded and verified
    /// (`.readyToInstall`), skips downloading, re-verifies the bundle signature off the main thread
    /// to prevent TOCTOU tampering, and relaunches immediately.
    public func installAvailableUpdate() {
        guard !isBusy, let release = availableRelease else { return }

        guard canTerminateNow() else {
            onBlockedByActiveSession()
            return
        }

        let targetAppURL: URL
        switch installEligibilityProvider(currentBundleURL) {
        case .canInstallInPlace(let url):
            targetAppURL = url
        case .manualRequired(let reason):
            let message = AppUpdateError.installLocationNotWritable(reason).errorDescription ?? reason
            state = .failed(message: message, release: release)
            onUserFacingError?(message)
            return
        }

        cancelIdleInstallTask()

        if let prepared = preparedUpdate, prepared.release.version == release.version {
            let taskID = UUID()
            activeTaskID = taskID
            state = .verifying(release)

            let currentBundleID = self.currentBundleID
            let currentTeamIDProvider = self.currentTeamIDProvider
            let verifyHandler = self.verifyHandler
            let installHandler = self.installHandler

            activeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.activeTaskID == taskID {
                        self.activeTask = nil
                    }
                }

                let reverifySucceeded: Bool
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        let expectedTeamID = currentTeamIDProvider()
                        try verifyHandler(prepared.verifiedAppURL, currentBundleID, release.version, expectedTeamID)
                    }.value
                    reverifySucceeded = true
                } catch is CancellationError {
                    if self.activeTaskID == taskID {
                        self.state = self.preparedUpdate?.release.version == release.version
                            ? .readyToInstall(release)
                            : .available(release)
                    }
                    return
                } catch let error as AppUpdateError where error == .cancelled {
                    if self.activeTaskID == taskID {
                        self.state = self.preparedUpdate?.release.version == release.version
                            ? .readyToInstall(release)
                            : .available(release)
                    }
                    return
                } catch {
                    reverifySucceeded = false
                }

                guard !Task.isCancelled, self.activeTaskID == taskID else { return }

                if !reverifySucceeded {
                    self.clearPreparedUpdate()
                    await self.runDownloadAndVerify(
                        release: release,
                        targetAppURL: targetAppURL,
                        taskID: taskID,
                        autoInstallImmediately: true,
                        silentFailure: false
                    )
                    return
                }

                guard self.canTerminateNow() else {
                    self.onBlockedByActiveSession()
                    self.state = .readyToInstall(release)
                    return
                }

                self.state = .installing(release)

                do {
                    try await Task.detached(priority: .userInitiated) {
                        try installHandler(prepared.verifiedAppURL, targetAppURL, prepared.stagingDirURL, true)
                    }.value
                    self.preparedUpdate = nil
                    self.terminateHandler()
                } catch is CancellationError {
                    if self.activeTaskID == taskID {
                        if FileManager.default.fileExists(atPath: prepared.verifiedAppURL.path) {
                            self.state = .readyToInstall(release)
                        } else {
                            self.clearPreparedUpdate()
                            self.state = .available(release)
                        }
                    }
                } catch {
                    if self.activeTaskID == taskID {
                        self.clearPreparedUpdate()
                        let message = Self.friendlyErrorMessage(for: error)
                        self.state = .failed(message: message, release: release)
                        self.onUserFacingError?(message)
                    }
                }
            }
            return
        }

        startDownloadAndVerify(
            release: release,
            targetAppURL: targetAppURL,
            autoInstallImmediately: true,
            silentFailure: false
        )
    }

    /// Re-evaluates whether a prepared `.readyToInstall` update can be installed silently while
    /// CCX is completely idle, starting or cancelling the debounce timer accordingly.
    public func notifyActivityStateChanged() {
        scheduleSilentInstallIfIdle()
    }

    /// Synchronously applies a prepared `.readyToInstall` update during application termination
    /// without relaunching CCX, so the user starts on the new version on their next launch.
    @discardableResult
    public func applyPreparedUpdateOnQuitIfReady() -> Bool {
        guard automaticallyChecksForUpdates,
              case .readyToInstall(let release) = state,
              let prepared = preparedUpdate,
              prepared.release.version == release.version
        else {
            return false
        }

        cancelIdleInstallTask()
        activeTask?.cancel()
        activeTask = nil
        activeTaskID = UUID()

        let targetAppURL: URL
        switch installEligibilityProvider(currentBundleURL) {
        case .canInstallInPlace(let url):
            targetAppURL = url
        case .manualRequired:
            return false
        }

        do {
            let expectedTeamID = currentTeamIDProvider()
            try verifyHandler(prepared.verifiedAppURL, currentBundleID, release.version, expectedTeamID)
            try installHandler(prepared.verifiedAppURL, targetAppURL, prepared.stagingDirURL, false)
            preparedUpdate = nil
            state = .installing(release)
            return true
        } catch {
            if !FileManager.default.fileExists(atPath: prepared.verifiedAppURL.path) {
                clearPreparedUpdate()
            }
            return false
        }
    }

    /// Cancels any active download, verification, or pending idle-install timer, cleans up
    /// temporary in-flight staging files, and preserves `.readyToInstall` if already prepared
    /// or restores `.available(release)`.
    public func cancelDownload() {
        let release = availableRelease
        cancelIdleInstallTask()
        activeTask?.cancel()
        activeTask = nil
        activeTaskID = UUID()

        if let stagingDir = activeStagingDirURL {
            try? FileManager.default.removeItem(at: stagingDir)
            activeStagingDirURL = nil
        }

        if let prepared = preparedUpdate {
            state = .readyToInstall(prepared.release)
        } else if let release {
            state = .available(release)
        } else if case .checking = state {
            state = .idle
        }
    }

    /// Hides the menu bar popover update banner for the currently available version while keeping
    /// the update visible in Settings.
    public func dismissPopoverBanner() {
        guard let release = availableRelease else { return }
        let versionString = release.version.description
        dismissedBannerVersion = versionString
        userDefaults.set(versionString, forKey: Self.dismissedBannerVersionKey)
        if case .failed = state {
            if preparedUpdate?.release.version == release.version {
                state = .readyToInstall(release)
            } else {
                state = .available(release)
            }
        }
    }

    /// Awaits completion of any currently running check/download/install task (for deterministic tests).
    internal func waitForActiveTask() async {
        while let task = activeTask {
            await task.value
        }
    }

    /// Awaits completion of any currently scheduled silent idle-install task (for deterministic tests).
    internal func waitForIdleInstallTask() async {
        while let task = idleInstallTask {
            await task.value
        }
    }

    private var userAgent: String {
        "CCX/\(currentVersion.description) (macOS)"
    }

    private func cancelIdleInstallTask() {
        idleInstallTask?.cancel()
        idleInstallTask = nil
        idleInstallTaskID = UUID()
    }

    private func clearPreparedUpdate() {
        if let prepared = preparedUpdate {
            try? FileManager.default.removeItem(at: prepared.stagingDirURL)
            preparedUpdate = nil
        }
    }

    private func scheduleSilentInstallIfIdle() {
        guard automaticallyChecksForUpdates,
              case .readyToInstall(let release) = state,
              let prepared = preparedUpdate,
              prepared.release.version == release.version,
              attemptedSilentInstallVersion != release.version.description
        else {
            cancelIdleInstallTask()
            return
        }

        guard canInstallSilentlyNow() else {
            cancelIdleInstallTask()
            return
        }

        guard idleInstallTask == nil else { return }

        let versionString = release.version.description
        let timerID = UUID()
        idleInstallTaskID = timerID
        let debounceInterval = idleInstallDebounceInterval

        idleInstallTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.idleInstallTaskID == timerID {
                    self.idleInstallTask = nil
                }
            }

            if debounceInterval > 0 {
                do {
                    try await Task.sleep(for: .seconds(debounceInterval))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled,
                  self.idleInstallTaskID == timerID,
                  self.automaticallyChecksForUpdates,
                  case .readyToInstall(let currentRelease) = self.state,
                  currentRelease.version == release.version,
                  let currentPrepared = self.preparedUpdate,
                  currentPrepared.release.version == release.version,
                  self.attemptedSilentInstallVersion != versionString,
                  self.canInstallSilentlyNow(),
                  self.canTerminateNow()
            else {
                return
            }

            await self.performSilentIdleInstall(prepared: currentPrepared, timerID: timerID)
        }
    }

    private func performSilentIdleInstall(prepared: PreparedUpdate, timerID: UUID) async {
        let release = prepared.release
        let versionString = release.version.description

        let targetAppURL: URL
        switch installEligibilityProvider(currentBundleURL) {
        case .canInstallInPlace(let url):
            targetAppURL = url
        case .manualRequired:
            attemptedSilentInstallVersion = versionString
            return
        }

        let currentBundleID = self.currentBundleID
        let currentTeamIDProvider = self.currentTeamIDProvider
        let verifyHandler = self.verifyHandler
        let installHandler = self.installHandler

        do {
            try await Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let expectedTeamID = currentTeamIDProvider()
                try verifyHandler(prepared.verifiedAppURL, currentBundleID, release.version, expectedTeamID)
            }.value
        } catch is CancellationError {
            return
        } catch let error as AppUpdateError where error == .cancelled {
            return
        } catch {
            guard !Task.isCancelled, idleInstallTaskID == timerID else { return }
            attemptedSilentInstallVersion = versionString
            clearPreparedUpdate()
            if case .readyToInstall = state {
                state = .available(release)
            }
            return
        }

        guard !Task.isCancelled,
              idleInstallTaskID == timerID,
              automaticallyChecksForUpdates,
              case .readyToInstall(let currentRelease) = state,
              currentRelease.version == release.version,
              preparedUpdate?.release.version == release.version,
              canInstallSilentlyNow(),
              canTerminateNow()
        else {
            return
        }

        state = .installing(release)

        do {
            try await Task.detached(priority: .userInitiated) {
                try installHandler(prepared.verifiedAppURL, targetAppURL, prepared.stagingDirURL, true)
            }.value
            preparedUpdate = nil
            terminateHandler()
        } catch {
            attemptedSilentInstallVersion = versionString
            if FileManager.default.fileExists(atPath: prepared.verifiedAppURL.path) {
                state = .readyToInstall(release)
            } else {
                clearPreparedUpdate()
                state = .available(release)
            }
        }
    }

    private func startDownloadAndVerify(
        release: AppReleaseInfo,
        targetAppURL: URL,
        autoInstallImmediately: Bool,
        silentFailure: Bool
    ) {
        cancelIdleInstallTask()
        let taskID = UUID()
        activeTaskID = taskID
        state = .downloading(release, progress: 0)

        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.activeTaskID == taskID {
                    self.activeTask = nil
                }
            }
            await self.runDownloadAndVerify(
                release: release,
                targetAppURL: targetAppURL,
                taskID: taskID,
                autoInstallImmediately: autoInstallImmediately,
                silentFailure: silentFailure
            )
        }
    }

    private func runDownloadAndVerify(
        release: AppReleaseInfo,
        targetAppURL: URL,
        taskID: UUID,
        autoInstallImmediately: Bool,
        silentFailure: Bool
    ) async {
        guard !Task.isCancelled, activeTaskID == taskID else { return }
        state = .downloading(release, progress: 0)

        let transport = self.transport
        let userAgent = self.userAgent
        let currentBundleID = self.currentBundleID
        let currentTeamIDProvider = self.currentTeamIDProvider
        let extractHandler = self.extractHandler
        let verifyHandler = self.verifyHandler
        let installHandler = self.installHandler

        var stagingDirURL: URL?
        var retainedStagingDir = false
        defer {
            if !retainedStagingDir, let stagingDirURL {
                try? FileManager.default.removeItem(at: stagingDirURL)
            }
            if self.activeTaskID == taskID {
                self.activeStagingDirURL = nil
            }
        }

        do {
            let stagingDir = try AppUpdateInstaller.createPrivateStagingDirectory()
            stagingDirURL = stagingDir
            self.activeStagingDirURL = stagingDir

            try Task.checkCancellation()

            let checksumsData = try await transport.fetchData(
                from: release.checksumsDownloadURL,
                maxBytes: GitHubReleaseParser.maxMetadataBytes,
                userAgent: userAgent
            )
            try Task.checkCancellation()

            guard let checksumsText = String(data: checksumsData, encoding: .utf8),
                  let expectedSHA256 = AppUpdateChecksumVerifier.parseExpectedSHA256(
                      forAssetName: release.zipAssetName,
                      from: checksumsText
                  )
            else {
                throw AppUpdateError.missingChecksumEntry
            }

            let zipFileURL = stagingDir.appendingPathComponent(release.zipAssetName, isDirectory: false)
            try await transport.downloadFile(
                from: release.zipDownloadURL,
                to: zipFileURL,
                maxBytes: GitHubReleaseParser.maxArchiveBytes,
                expectedBytesHint: release.zipAssetSize,
                userAgent: userAgent
            ) { [weak self] progress in
                let clamped = min(max(progress, 0), 1)
                Task { @MainActor [weak self] in
                    guard let self, self.activeTaskID == taskID else { return }
                    if case .downloading = self.state {
                        self.state = .downloading(release, progress: clamped)
                    }
                }
            }
            try Task.checkCancellation()

            guard self.activeTaskID == taskID else { return }
            self.state = .verifying(release)

            let extractDirURL = stagingDir.appendingPathComponent("extracted", isDirectory: true)
            let priority: TaskPriority = autoInstallImmediately ? .userInitiated : .utility
            let verifiedAppURL = try await Task.detached(priority: priority) { () throws -> URL in
                try Task.checkCancellation()
                try AppUpdateChecksumVerifier.verifyFile(at: zipFileURL, expectedHex: expectedSHA256)
                try Task.checkCancellation()

                try FileManager.default.createDirectory(
                    at: extractDirURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let extractedAppURL = try extractHandler(zipFileURL, extractDirURL)
                try Task.checkCancellation()

                let expectedTeamID = currentTeamIDProvider()
                try verifyHandler(extractedAppURL, currentBundleID, release.version, expectedTeamID)
                try? FileManager.default.removeItem(at: zipFileURL)
                return extractedAppURL
            }.value

            try Task.checkCancellation()
            guard self.activeTaskID == taskID else { return }

            if !autoInstallImmediately {
                self.clearPreparedUpdate()
                self.preparedUpdate = PreparedUpdate(
                    release: release,
                    verifiedAppURL: verifiedAppURL,
                    stagingDirURL: stagingDir,
                    targetAppURL: targetAppURL
                )
                retainedStagingDir = true
                self.activeStagingDirURL = nil
                self.state = .readyToInstall(release)
                self.scheduleSilentInstallIfIdle()
                return
            }

            guard self.canTerminateNow() else {
                self.clearPreparedUpdate()
                self.preparedUpdate = PreparedUpdate(
                    release: release,
                    verifiedAppURL: verifiedAppURL,
                    stagingDirURL: stagingDir,
                    targetAppURL: targetAppURL
                )
                retainedStagingDir = true
                self.activeStagingDirURL = nil
                self.state = .readyToInstall(release)
                self.onBlockedByActiveSession()
                return
            }

            self.state = .installing(release)

            try await Task.detached(priority: .userInitiated) {
                try installHandler(verifiedAppURL, targetAppURL, stagingDir, true)
            }.value

            retainedStagingDir = true
            self.activeStagingDirURL = nil
            self.terminateHandler()
        } catch is CancellationError {
            if self.activeTaskID == taskID {
                if let prepared = self.preparedUpdate, prepared.release.version == release.version {
                    self.state = .readyToInstall(release)
                } else {
                    self.state = .available(release)
                }
            }
        } catch let error as AppUpdateError where error == .cancelled {
            if self.activeTaskID == taskID {
                if let prepared = self.preparedUpdate, prepared.release.version == release.version {
                    self.state = .readyToInstall(release)
                } else {
                    self.state = .available(release)
                }
            }
        } catch {
            if self.activeTaskID == taskID {
                if silentFailure {
                    self.state = .available(release)
                } else {
                    let message = Self.friendlyErrorMessage(for: error)
                    self.state = .failed(message: message, release: release)
                    self.onUserFacingError?(message)
                }
            }
        }
    }

    private func performCheckForUpdates(userInitiated: Bool, now: Date) {
        switch state {
        case .downloading, .verifying, .installing:
            return
        case .checking:
            guard userInitiated else { return }
            activeTask?.cancel()
            activeTask = nil
        case .idle, .upToDate, .available, .readyToInstall, .failed:
            break
        }

        cancelIdleInstallTask()
        let previousRelease = availableRelease
        let taskID = UUID()
        activeTaskID = taskID
        state = .checking

        let transport = self.transport
        let userAgent = self.userAgent
        let currentVersion = self.currentVersion

        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.activeTaskID == taskID {
                    self.activeTask = nil
                }
            }

            do {
                let data = try await transport.fetchData(
                    from: AppUpdateURLPolicy.latestReleaseAPIURL,
                    maxBytes: GitHubReleaseParser.maxMetadataBytes,
                    userAgent: userAgent
                )
                try Task.checkCancellation()
                guard self.activeTaskID == taskID else { return }

                let result = try GitHubReleaseParser.parseLatestRelease(
                    data: data,
                    currentVersion: currentVersion
                )

                self.lastCheckDate = now
                self.userDefaults.set(now, forKey: Self.lastCheckDateKey)

                switch result {
                case .upToDate:
                    self.clearPreparedUpdate()
                    self.state = .upToDate(checkedAt: now)
                case .updateAvailable(let release):
                    if userInitiated {
                        self.dismissedBannerVersion = nil
                        self.userDefaults.removeObject(forKey: Self.dismissedBannerVersionKey)
                    }

                    if let prepared = self.preparedUpdate, prepared.release.version == release.version {
                        self.preparedUpdate = PreparedUpdate(
                            release: release,
                            verifiedAppURL: prepared.verifiedAppURL,
                            stagingDirURL: prepared.stagingDirURL,
                            targetAppURL: prepared.targetAppURL
                        )
                        self.state = .readyToInstall(release)
                        self.scheduleSilentInstallIfIdle()
                        return
                    }

                    self.clearPreparedUpdate()
                    if self.attemptedSilentInstallVersion != release.version.description {
                        self.attemptedSilentInstallVersion = nil
                    }

                    if self.automaticallyChecksForUpdates,
                       case .canInstallInPlace(let targetAppURL) = self.installEligibilityProvider(self.currentBundleURL) {
                        await self.runDownloadAndVerify(
                            release: release,
                            targetAppURL: targetAppURL,
                            taskID: taskID,
                            autoInstallImmediately: false,
                            silentFailure: !userInitiated
                        )
                    } else {
                        self.state = .available(release)
                    }
                }
            } catch is CancellationError {
                guard self.activeTaskID == taskID else { return }
                if let prepared = self.preparedUpdate {
                    self.state = .readyToInstall(prepared.release)
                } else if let previousRelease {
                    self.state = .available(previousRelease)
                } else {
                    self.state = .idle
                }
            } catch let error as AppUpdateError where error == .cancelled {
                guard self.activeTaskID == taskID else { return }
                if let prepared = self.preparedUpdate {
                    self.state = .readyToInstall(prepared.release)
                } else if let previousRelease {
                    self.state = .available(previousRelease)
                } else {
                    self.state = .idle
                }
            } catch {
                guard self.activeTaskID == taskID else { return }
                if userInitiated {
                    self.state = .failed(
                        message: Self.friendlyErrorMessage(for: error),
                        release: previousRelease
                    )
                } else if let prepared = self.preparedUpdate {
                    self.state = .readyToInstall(prepared.release)
                } else {
                    self.state = .idle
                }
            }
        }
    }

    private static func friendlyErrorMessage(for error: Error) -> String {
        if let updateError = error as? AppUpdateError, let description = updateError.errorDescription {
            return description
        }
        if error is CancellationError {
            return AppUpdateError.cancelled.errorDescription
                ?? CCXL10n.text("Update cancelled.", zh: "已取消更新")
        }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled {
                return AppUpdateError.cancelled.errorDescription
                    ?? CCXL10n.text("Update cancelled.", zh: "已取消更新")
            }
            return AppUpdateError.networkUnavailable.errorDescription
                ?? CCXL10n.text("Can't reach GitHub. Check network.", zh: "无法连接 GitHub，请检查网络")
        }
        return AppUpdateInstaller.Messages.genericUpdateFailed
    }
}
