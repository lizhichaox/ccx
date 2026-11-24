import AppKit
import CryptoKit
import Darwin
import Foundation
@testable import CCXCore
import XCTest

// MARK: - Mock Transport

private final class MockAppUpdateTransport: AppUpdateTransport, @unchecked Sendable {
    enum FetchOutcome: Sendable {
        case data(Data)
        case error(Error)
    }

    enum DownloadOutcome: Sendable {
        case data(Data, progressSteps: [Double])
        case error(Error)
    }

    private let lock = NSLock()
    private var fetchRoutes: [URL: FetchOutcome] = [:]
    private var downloadRoutes: [URL: DownloadOutcome] = [:]
    private(set) var fetchedURLs: [URL] = []
    private(set) var downloadedURLs: [URL] = []

    func stubFetch(url: URL, outcome: FetchOutcome) {
        lock.withLock {
            fetchRoutes[url] = outcome
        }
    }

    func stubDownload(url: URL, outcome: DownloadOutcome) {
        lock.withLock {
            downloadRoutes[url] = outcome
        }
    }

    var fetchCount: Int {
        lock.withLock { fetchedURLs.count }
    }

    func fetchData(from url: URL, maxBytes: Int, userAgent: String) async throws -> Data {
        let outcome: FetchOutcome? = lock.withLock {
            fetchedURLs.append(url)
            return fetchRoutes[url]
        }
        guard let outcome else {
            throw AppUpdateError.networkUnavailable
        }
        switch outcome {
        case .data(let data):
            guard data.count <= maxBytes else { throw AppUpdateError.responseTooLarge }
            return data
        case .error(let error):
            throw error
        }
    }

    func downloadFile(
        from url: URL,
        to destinationURL: URL,
        maxBytes: Int64,
        userAgent: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let outcome: DownloadOutcome? = lock.withLock {
            downloadedURLs.append(url)
            return downloadRoutes[url]
        }
        guard let outcome else {
            throw AppUpdateError.networkUnavailable
        }
        switch outcome {
        case .data(let data, let progressSteps):
            guard Int64(data.count) <= maxBytes else { throw AppUpdateError.responseTooLarge }
            for step in progressSteps {
                onProgress(step)
            }
            try data.write(to: destinationURL, options: .atomic)
            onProgress(1.0)
        case .error(let error):
            throw error
        }
    }
}

private final class AtomicBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

// MARK: - Unit Tests

final class AppUpdaterTests: XCTestCase {
    private var tempDirectories: [URL] = []
    private var createdSuites: [String] = []

    override func tearDown() {
        for dir in tempDirectories {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirectories.removeAll()
        for suite in createdSuites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        createdSuites.removeAll()
        super.tearDown()
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CCXAppUpdaterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirectories.append(dir)
        return dir
    }

    private func makeTestUserDefaults() -> UserDefaults {
        let suite = "com.lizhichaox.ccx.tests.\(UUID().uuidString)"
        createdSuites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeReleaseJSON(
        tagName: String = "v0.5.0",
        htmlURL: String = "https://github.com/lizhichaox/ccx/releases/tag/v0.5.0",
        draft: Bool = false,
        prerelease: Bool = false,
        body: String = "  Added native in-app updater.  ",
        publishedAt: String = "2026-11-24T05:00:00Z",
        assets: [[String: Any]]? = nil
    ) throws -> Data {
        let defaultAssets: [[String: Any]] = [
            [
                "name": "CCX-0.5.0-macOS-universal.zip",
                "browser_download_url": "https://github.com/lizhichaox/ccx/releases/download/v0.5.0/CCX-0.5.0-macOS-universal.zip",
                "size": 12_345_678,
            ],
            [
                "name": "CCX-0.5.0-macOS-universal.dmg",
                "browser_download_url": "https://github.com/lizhichaox/ccx/releases/download/v0.5.0/CCX-0.5.0-macOS-universal.dmg",
                "size": 14_000_000,
            ],
            [
                "name": "SHA256SUMS.txt",
                "browser_download_url": "https://github.com/lizhichaox/ccx/releases/download/v0.5.0/SHA256SUMS.txt",
                "size": 256,
            ],
        ]
        let payload: [String: Any] = [
            "tag_name": tagName,
            "html_url": htmlURL,
            "draft": draft,
            "prerelease": prerelease,
            "body": body,
            "published_at": publishedAt,
            "assets": assets ?? defaultAssets,
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    // MARK: 1. AppSemanticVersion

    func testSemanticVersionParsingAndOrdering() {
        XCTAssertEqual(AppSemanticVersion(parsing: "0.4.4"), AppSemanticVersion(major: 0, minor: 4, patch: 4))
        XCTAssertEqual(AppSemanticVersion(parsing: "v0.5.0"), AppSemanticVersion(major: 0, minor: 5, patch: 0))
        XCTAssertEqual(AppSemanticVersion(parsing: "  V1.2 \n"), AppSemanticVersion(major: 1, minor: 2, patch: 0))
        XCTAssertEqual(AppSemanticVersion(parsing: "v0.5.0")?.description, "0.5.0")

        // Rejected formats
        XCTAssertNil(AppSemanticVersion(parsing: ""))
        XCTAssertNil(AppSemanticVersion(parsing: "v"))
        XCTAssertNil(AppSemanticVersion(parsing: "vv0.5.0"))
        XCTAssertNil(AppSemanticVersion(parsing: "0.5.0-beta.1"))
        XCTAssertNil(AppSemanticVersion(parsing: "1.2.3+build.4"))
        XCTAssertNil(AppSemanticVersion(parsing: "abc"))
        XCTAssertNil(AppSemanticVersion(parsing: "1"))
        XCTAssertNil(AppSemanticVersion(parsing: "1.2.3.4"))
        XCTAssertNil(AppSemanticVersion(parsing: "1..2"))
        XCTAssertNil(AppSemanticVersion(parsing: ".1.2"))
        XCTAssertNil(AppSemanticVersion(parsing: "1.2."))
        XCTAssertNil(AppSemanticVersion(parsing: "-1.2.3"))

        // Ordering
        XCTAssertLessThan(AppSemanticVersion(major: 0, minor: 4, patch: 4), AppSemanticVersion(major: 0, minor: 5, patch: 0))
        XCTAssertLessThan(AppSemanticVersion(major: 0, minor: 9, patch: 9), AppSemanticVersion(major: 0, minor: 10, patch: 0))
        XCTAssertLessThan(AppSemanticVersion(major: 0, minor: 5, patch: 0), AppSemanticVersion(major: 1, minor: 0, patch: 0))
    }

    // MARK: 2. AppUpdateURLPolicy

    func testURLPolicyAllowlistAndRejections() {
        let allowed = [
            "https://api.github.com/repos/lizhichaox/ccx/releases/latest",
            "https://github.com/lizhichaox/ccx/releases/download/v0.5.0/CCX-0.5.0-macOS-universal.zip",
            "https://objects.githubusercontent.com/github-production-release-asset-2e65be/test.zip",
            "https://release-assets.githubusercontent.com/assets/test.zip",
            "https://github-releases.githubusercontent.com/12345/test.zip",
            "https://cdn-1.githubusercontent.com/asset.zip",
        ]
        for raw in allowed {
            XCTAssertTrue(AppUpdateURLPolicy.isAllowedDownloadURL(URL(string: raw)!), "Expected allowed: \(raw)")
        }

        let rejected = [
            "http://github.com/lizhichaox/ccx/releases/latest",
            "http://objects.githubusercontent.com/test.zip",
            "https://evilgithub.com/lizhichaox/ccx/releases/latest",
            "https://github.com.evil.example/test.zip",
            "https://evilgithubusercontent.com/test.zip",
            "https://example.com/CCX.zip",
            "https://user:pass@github.com/lizhichaox/ccx/releases/latest",
            "https://user@objects.githubusercontent.com/test.zip",
            "https://.githubusercontent.com/test.zip",
            "https://githubusercontent.com/test.zip",
            "https://github.com:8443/lizhichaox/ccx/releases/latest",
            "file:///Applications/CCX.app",
        ]
        for raw in rejected {
            if let url = URL(string: raw) {
                XCTAssertFalse(AppUpdateURLPolicy.isAllowedDownloadURL(url), "Expected rejected: \(raw)")
            }
        }
    }

    // MARK: 3. GitHubReleaseParser

    func testReleaseParserNewerReleaseSuccess() throws {
        let data = try makeReleaseJSON()
        let result = try GitHubReleaseParser.parseLatestRelease(
            data: data,
            currentVersion: AppSemanticVersion(major: 0, minor: 4, patch: 4)
        )

        guard case .updateAvailable(let info) = result else {
            return XCTFail("Expected .updateAvailable, got \(result)")
        }
        XCTAssertEqual(info.version, AppSemanticVersion(major: 0, minor: 5, patch: 0))
        XCTAssertEqual(info.tagName, "v0.5.0")
        XCTAssertEqual(info.zipAssetName, "CCX-0.5.0-macOS-universal.zip")
        XCTAssertEqual(info.zipAssetSize, 12_345_678)
        XCTAssertNotNil(info.dmgDownloadURL)
        XCTAssertEqual(info.releaseNotes, "Added native in-app updater.")
        XCTAssertNotNil(info.publishedAt)
    }

    func testReleaseParserEqualOlderDraftAndPrerelease() throws {
        let data = try makeReleaseJSON(tagName: "v0.5.0")

        let equalResult = try GitHubReleaseParser.parseLatestRelease(
            data: data,
            currentVersion: AppSemanticVersion(major: 0, minor: 5, patch: 0)
        )
        XCTAssertEqual(equalResult, .upToDate(latestVersion: AppSemanticVersion(major: 0, minor: 5, patch: 0)))

        let olderResult = try GitHubReleaseParser.parseLatestRelease(
            data: data,
            currentVersion: AppSemanticVersion(major: 0, minor: 6, patch: 0)
        )
        XCTAssertEqual(olderResult, .upToDate(latestVersion: AppSemanticVersion(major: 0, minor: 5, patch: 0)))

        let draftData = try makeReleaseJSON(draft: true)
        XCTAssertEqual(
            try GitHubReleaseParser.parseLatestRelease(data: draftData, currentVersion: AppSemanticVersion(major: 0, minor: 4, patch: 4)),
            .upToDate(latestVersion: nil)
        )

        let prereleaseData = try makeReleaseJSON(prerelease: true)
        XCTAssertEqual(
            try GitHubReleaseParser.parseLatestRelease(data: prereleaseData, currentVersion: AppSemanticVersion(major: 0, minor: 4, patch: 4)),
            .upToDate(latestVersion: nil)
        )
    }

    func testReleaseParserFailsClosedOnMissingAssetsUntrustedURLAndOversizedAsset() throws {
        let current = AppSemanticVersion(major: 0, minor: 4, patch: 4)

        // Missing SHA256SUMS.txt
        let missingChecksums = try makeReleaseJSON(assets: [
            [
                "name": "CCX-0.5.0-macOS-universal.zip",
                "browser_download_url": "https://github.com/lizhichaox/ccx/releases/download/v0.5.0/CCX-0.5.0-macOS-universal.zip",
                "size": 1024,
            ],
        ])
        XCTAssertThrowsError(try GitHubReleaseParser.parseLatestRelease(data: missingChecksums, currentVersion: current)) { error in
            XCTAssertEqual(error as? AppUpdateError, .missingReleaseAssets)
        }

        // Missing zip
        let missingZip = try makeReleaseJSON(assets: [
            [
                "name": "SHA256SUMS.txt",
                "browser_download_url": "https://github.com/lizhichaox/ccx/releases/download/v0.5.0/SHA256SUMS.txt",
                "size": 128,
            ],
        ])
        XCTAssertThrowsError(try GitHubReleaseParser.parseLatestRelease(data: missingZip, currentVersion: current)) { error in
            XCTAssertEqual(error as? AppUpdateError, .missingReleaseAssets)
        }

        // Untrusted download URL
        let untrustedAsset = try makeReleaseJSON(assets: [
            [
                "name": "CCX-0.5.0-macOS-universal.zip",
                "browser_download_url": "https://evil.example.com/CCX-0.5.0-macOS-universal.zip",
                "size": 1024,
            ],
            [
                "name": "SHA256SUMS.txt",
                "browser_download_url": "https://github.com/lizhichaox/ccx/releases/download/v0.5.0/SHA256SUMS.txt",
                "size": 128,
            ],
        ])
        XCTAssertThrowsError(try GitHubReleaseParser.parseLatestRelease(data: untrustedAsset, currentVersion: current)) { error in
            XCTAssertEqual(error as? AppUpdateError, .untrustedURL)
        }

        // Oversized asset
        let oversizedAsset = try makeReleaseJSON(assets: [
            [
                "name": "CCX-0.5.0-macOS-universal.zip",
                "browser_download_url": "https://github.com/lizhichaox/ccx/releases/download/v0.5.0/CCX-0.5.0-macOS-universal.zip",
                "size": GitHubReleaseParser.maxArchiveBytes + 1,
            ],
            [
                "name": "SHA256SUMS.txt",
                "browser_download_url": "https://github.com/lizhichaox/ccx/releases/download/v0.5.0/SHA256SUMS.txt",
                "size": 128,
            ],
        ])
        XCTAssertThrowsError(try GitHubReleaseParser.parseLatestRelease(data: oversizedAsset, currentVersion: current)) { error in
            XCTAssertEqual(error as? AppUpdateError, .responseTooLarge)
        }
    }

    // MARK: 4. AppUpdateChecksumVerifier

    func testChecksumParsingAndFileVerification() throws {
        let dir = try makeTempDirectory()
        let fileURL = dir.appendingPathComponent("CCX-0.5.0-macOS-universal.zip")
        let payload = Data("CCX verified release archive bytes".utf8)
        try payload.write(to: fileURL)

        let expectedHash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let computed = try AppUpdateChecksumVerifier.sha256Hex(ofFileAt: fileURL)
        XCTAssertEqual(computed, expectedHash)

        // Two-space, asterisk, and ./ prefix formats
        let manifestStandard = "\(expectedHash.uppercased())  CCX-0.5.0-macOS-universal.zip\n"
        XCTAssertEqual(
            AppUpdateChecksumVerifier.parseExpectedSHA256(forAssetName: "CCX-0.5.0-macOS-universal.zip", from: manifestStandard),
            expectedHash
        )

        let manifestAsterisk = "\(expectedHash) *CCX-0.5.0-macOS-universal.zip\n"
        XCTAssertEqual(
            AppUpdateChecksumVerifier.parseExpectedSHA256(forAssetName: "CCX-0.5.0-macOS-universal.zip", from: manifestAsterisk),
            expectedHash
        )

        let manifestDotSlash = "\(expectedHash)  ./CCX-0.5.0-macOS-universal.zip\n"
        XCTAssertEqual(
            AppUpdateChecksumVerifier.parseExpectedSHA256(forAssetName: "CCX-0.5.0-macOS-universal.zip", from: manifestDotSlash),
            expectedHash
        )

        XCTAssertNil(
            AppUpdateChecksumVerifier.parseExpectedSHA256(forAssetName: "Other.zip", from: manifestStandard)
        )

        // Verify exact match succeeds
        XCTAssertNoThrow(try AppUpdateChecksumVerifier.verifyFile(at: fileURL, expectedHex: expectedHash))

        // Tampered byte fails with .checksumMismatch
        var tampered = payload
        tampered[0] ^= 0xFF
        try tampered.write(to: fileURL)
        XCTAssertThrowsError(try AppUpdateChecksumVerifier.verifyFile(at: fileURL, expectedHex: expectedHash)) { error in
            XCTAssertEqual(error as? AppUpdateError, .checksumMismatch)
        }
    }

    // MARK: 5. AppCodeSignatureVerifier Requirement Builder

    func testBuildDeveloperIDRequirementString() {
        let valid = AppCodeSignatureVerifier.buildDeveloperIDRequirementString(
            bundleID: "com.lizhichaox.ccx",
            teamID: "AB12CD34EF"
        )
        XCTAssertEqual(
            valid,
            "anchor apple generic and identifier \"com.lizhichaox.ccx\" and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = \"AB12CD34EF\""
        )

        // Reject invalid team IDs and bundle IDs
        XCTAssertNil(AppCodeSignatureVerifier.buildDeveloperIDRequirementString(bundleID: "com.lizhichaox.ccx", teamID: "SHORT"))
        XCTAssertNil(AppCodeSignatureVerifier.buildDeveloperIDRequirementString(bundleID: "com.lizhichaox.ccx", teamID: "ab12cd34ef"))
        XCTAssertNil(AppCodeSignatureVerifier.buildDeveloperIDRequirementString(bundleID: "com.lizhichaox.ccx", teamID: "AB12\"D34EF"))
        XCTAssertNil(AppCodeSignatureVerifier.buildDeveloperIDRequirementString(bundleID: "com.lizhichaox.ccx\" or true", teamID: "AB12CD34EF"))
        XCTAssertNil(AppCodeSignatureVerifier.buildDeveloperIDRequirementString(bundleID: "com.lizhichaox ccx", teamID: "AB12CD34EF"))
        XCTAssertNil(AppCodeSignatureVerifier.buildDeveloperIDRequirementString(bundleID: "", teamID: "AB12CD34EF"))
    }

    // MARK: 6. AppUpdateInstaller.installEligibility

    func testInstallEligibilityChecks() throws {
        let dir = try makeTempDirectory()
        let realApp = dir.appendingPathComponent("CCX.app", isDirectory: true)
        try FileManager.default.createDirectory(at: realApp, withIntermediateDirectories: true)

        // Writable real .app directory
        let eligible = AppUpdateInstaller.installEligibility(for: realApp)
        XCTAssertEqual(eligible, .canInstallInPlace(targetAppURL: realApp))

        // Symlink .app rejected
        let symlinkApp = dir.appendingPathComponent("LinkedCCX.app")
        try FileManager.default.createSymbolicLink(at: symlinkApp, withDestinationURL: realApp)
        if case .manualRequired = AppUpdateInstaller.installEligibility(for: symlinkApp) {
            // expected
        } else {
            XCTFail("Expected symlink .app to require manual update")
        }

        // AppTranslocation path rejected
        let translocated = URL(fileURLWithPath: "/private/var/folders/xx/AppTranslocation/1234/d/CCX.app")
        if case .manualRequired = AppUpdateInstaller.installEligibility(for: translocated) {
            // expected
        } else {
            XCTFail("Expected AppTranslocation path to require manual update")
        }

        // /Volumes/ mounted DMG path rejected
        let volumeApp = URL(fileURLWithPath: "/Volumes/CCX/CCX.app")
        if case .manualRequired = AppUpdateInstaller.installEligibility(for: volumeApp) {
            // expected
        } else {
            XCTFail("Expected /Volumes/ path to require manual update")
        }

        // Non-writable parent rejected
        let readOnly = AppUpdateInstaller.installEligibility(for: realApp) { path in
            path == realApp.path // parent returns false
        }
        if case .manualRequired = readOnly {
            // expected
        } else {
            XCTFail("Expected non-writable parent to require manual update")
        }
    }

    // MARK: 7. AppUpdateManager State Machine

    @MainActor
    func testAutoCheckRespectsThrottleAndToggle() async throws {
        let defaults = makeTestUserDefaults()
        let transport = MockAppUpdateTransport()
        transport.stubFetch(url: AppUpdateURLPolicy.latestReleaseAPIURL, outcome: .data(try makeReleaseJSON()))

        let manager = AppUpdateManager(
            userDefaults: defaults,
            currentVersion: AppSemanticVersion(major: 0, minor: 4, patch: 4),
            transport: transport,
            checkInterval: 86_400
        )

        // Disabled auto-check skips network
        manager.automaticallyChecksForUpdates = false
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        manager.checkForUpdatesInBackgroundIfDue(now: t0)
        await manager.waitForActiveTask()
        XCTAssertEqual(transport.fetchCount, 0)
        XCTAssertEqual(manager.state, .idle)

        // Re-enable -> first check runs
        manager.automaticallyChecksForUpdates = true
        manager.checkForUpdatesInBackgroundIfDue(now: t0)
        await manager.waitForActiveTask()
        XCTAssertEqual(transport.fetchCount, 1)
        XCTAssertEqual(manager.lastCheckDate, t0)

        // Within 24h -> throttled
        manager.checkForUpdatesInBackgroundIfDue(now: t0.addingTimeInterval(3600))
        await manager.waitForActiveTask()
        XCTAssertEqual(transport.fetchCount, 1)

        // After 24h -> checks again
        manager.checkForUpdatesInBackgroundIfDue(now: t0.addingTimeInterval(86_401))
        await manager.waitForActiveTask()
        XCTAssertEqual(transport.fetchCount, 2)
    }

    @MainActor
    func testBackgroundNetworkErrorIsSilentAndManualErrorShowsFailure() async {
        let defaults = makeTestUserDefaults()
        let transport = MockAppUpdateTransport()
        transport.stubFetch(
            url: AppUpdateURLPolicy.latestReleaseAPIURL,
            outcome: .error(AppUpdateError.networkUnavailable)
        )

        let reportedErrors = AtomicBox<[String]>([])
        let manager = AppUpdateManager(
            userDefaults: defaults,
            currentVersion: AppSemanticVersion(major: 0, minor: 4, patch: 4),
            transport: transport,
            onUserFacingError: { message in
                reportedErrors.value.append(message)
            }
        )

        // Background check fails silently to .idle and never invokes onUserFacingError
        manager.checkForUpdatesInBackgroundIfDue(now: Date())
        await manager.waitForActiveTask()
        XCTAssertEqual(manager.state, .idle)
        XCTAssertTrue(reportedErrors.value.isEmpty)

        // Manual check transitions to .failed with friendly message
        manager.checkForUpdates(userInitiated: true)
        await manager.waitForActiveTask()
        guard case .failed(let message, let release) = manager.state else {
            return XCTFail("Expected .failed, got \(manager.state)")
        }
        XCTAssertNil(release)
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(message.contains("Error Domain="))
    }

    @MainActor
    func testManualCheckAndDismissPopoverBanner() async throws {
        let defaults = makeTestUserDefaults()
        let transport = MockAppUpdateTransport()
        transport.stubFetch(
            url: AppUpdateURLPolicy.latestReleaseAPIURL,
            outcome: .data(try makeReleaseJSON(tagName: "v0.5.0"))
        )

        let manager = AppUpdateManager(
            userDefaults: defaults,
            currentVersion: AppSemanticVersion(major: 0, minor: 4, patch: 4),
            transport: transport
        )

        manager.checkForUpdates(userInitiated: true)
        await manager.waitForActiveTask()

        XCTAssertNotNil(manager.availableRelease)
        XCTAssertEqual(manager.availableRelease?.version, AppSemanticVersion(major: 0, minor: 5, patch: 0))
        XCTAssertTrue(manager.shouldShowPopoverBanner)

        // Dismiss hides popover banner while keeping availableRelease for Settings
        manager.dismissPopoverBanner()
        XCTAssertFalse(manager.shouldShowPopoverBanner)
        XCTAssertNotNil(manager.availableRelease)

        // Manual re-check clears dismissed banner so user sees the update again
        manager.checkForUpdates(userInitiated: true)
        await manager.waitForActiveTask()
        XCTAssertTrue(manager.shouldShowPopoverBanner)
    }

    @MainActor
    func testEndToEndDownloadVerifyInstallAndActiveSessionBlocking() async throws {
        let dir = try makeTempDirectory()
        let fakeInstalledApp = dir.appendingPathComponent("CCX.app", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeInstalledApp, withIntermediateDirectories: true)

        let zipBytes = Data("mock-ccx-0.5.0-universal-archive".utf8)
        let zipSHA256 = SHA256.hash(data: zipBytes).map { String(format: "%02x", $0) }.joined()
        let checksumsData = Data("\(zipSHA256)  CCX-0.5.0-macOS-universal.zip\n".utf8)

        let transport = MockAppUpdateTransport()
        transport.stubFetch(
            url: AppUpdateURLPolicy.latestReleaseAPIURL,
            outcome: .data(try makeReleaseJSON(tagName: "v0.5.0"))
        )
        transport.stubFetch(
            url: URL(string: "https://github.com/lizhichaox/ccx/releases/download/v0.5.0/SHA256SUMS.txt")!,
            outcome: .data(checksumsData)
        )
        transport.stubDownload(
            url: URL(string: "https://github.com/lizhichaox/ccx/releases/download/v0.5.0/CCX-0.5.0-macOS-universal.zip")!,
            outcome: .data(zipBytes, progressSteps: [0.25, 0.75])
        )

        let verifiedBox = AtomicBox<Bool>(false)
        let installedBox = AtomicBox<Bool>(false)
        let canTerminateBox = AtomicBox<Bool>(false)
        let blockedCountBox = AtomicBox<Int>(0)
        let terminatedCountBox = AtomicBox<Int>(0)

        let manager = AppUpdateManager(
            userDefaults: makeTestUserDefaults(),
            currentVersion: AppSemanticVersion(major: 0, minor: 4, patch: 4),
            currentBundleID: "com.lizhichaox.ccx",
            currentBundleURL: fakeInstalledApp,
            currentTeamIDProvider: { "TESTTEAM01" },
            transport: transport,
            extractHandler: { _, destinationDir in
                let extracted = destinationDir.appendingPathComponent("CCX.app", isDirectory: true)
                try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
                return extracted
            },
            verifyHandler: { _, bundleID, version, teamID in
                XCTAssertEqual(bundleID, "com.lizhichaox.ccx")
                XCTAssertEqual(version, AppSemanticVersion(major: 0, minor: 5, patch: 0))
                XCTAssertEqual(teamID, "TESTTEAM01")
                verifiedBox.value = true
            },
            installHandler: { _, targetURL, _ in
                XCTAssertEqual(targetURL.path, fakeInstalledApp.path)
                installedBox.value = true
            },
            canTerminateNow: { canTerminateBox.value },
            onBlockedByActiveSession: { blockedCountBox.value += 1 },
            terminateHandler: { terminatedCountBox.value += 1 }
        )

        manager.checkForUpdates(userInitiated: true)
        await manager.waitForActiveTask()
        guard case .available = manager.state else {
            return XCTFail("Expected .available")
        }

        // Blocked cleanly when recording/save panel is active
        manager.installAvailableUpdate()
        XCTAssertEqual(blockedCountBox.value, 1)
        XCTAssertEqual(terminatedCountBox.value, 0)
        XCTAssertFalse(installedBox.value)
        if case .available = manager.state {
            // expected
        } else {
            XCTFail("Expected state to remain .available when blocked")
        }

        // Allow termination -> full download + real SHA-256 verify + mock extract/signature/install + terminate
        canTerminateBox.value = true
        manager.installAvailableUpdate()
        await manager.waitForActiveTask()

        XCTAssertTrue(verifiedBox.value)
        XCTAssertTrue(installedBox.value)
        XCTAssertEqual(terminatedCountBox.value, 1)
    }

    func testVerifyDownloadedAppMetadataAndUnsignedFailClosed() throws {
        let dir = try makeTempDirectory()
        let appURL = dir.appendingPathComponent("CCX.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)

        let execURL = macOSURL.appendingPathComponent("CCX")
        try Data("#!/bin/sh\n".utf8).write(to: execURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execURL.path)

        let plistURL = contentsURL.appendingPathComponent("Info.plist")

        // Path traversal in CFBundleExecutable must be rejected
        let traversalPlist: [String: Any] = [
            "CFBundleIdentifier": "com.lizhichaox.ccx",
            "CFBundleShortVersionString": "0.5.0",
            "CFBundleExecutable": "../MacOS/CCX",
        ]
        try PropertyListSerialization.data(fromPropertyList: traversalPlist, format: .xml, options: 0).write(to: plistURL)
        XCTAssertThrowsError(
            try AppCodeSignatureVerifier.verifyDownloadedApp(
                at: appURL,
                expectedBundleID: "com.lizhichaox.ccx",
                expectedVersion: AppSemanticVersion(major: 0, minor: 5, patch: 0),
                expectedTeamID: "TESTTEAM01"
            )
        ) { error in
            XCTAssertEqual(error as? AppUpdateError, .invalidBundleMetadata)
        }

        // Valid metadata with nil Team ID must fail closed with .unsignedCurrentApp
        let validPlist: [String: Any] = [
            "CFBundleIdentifier": "com.lizhichaox.ccx",
            "CFBundleShortVersionString": "0.5.0",
            "CFBundleExecutable": "CCX",
        ]
        try PropertyListSerialization.data(fromPropertyList: validPlist, format: .xml, options: 0).write(to: plistURL)
        XCTAssertThrowsError(
            try AppCodeSignatureVerifier.verifyDownloadedApp(
                at: appURL,
                expectedBundleID: "com.lizhichaox.ccx",
                expectedVersion: AppSemanticVersion(major: 0, minor: 5, patch: 0),
                expectedTeamID: nil
            )
        ) { error in
            XCTAssertEqual(error as? AppUpdateError, .unsignedCurrentApp)
        }
    }

    @MainActor
    func testChecksumMismatchFailsCleanlyAndPreservesReleaseForRetry() async throws {
        let dir = try makeTempDirectory()
        let fakeInstalledApp = dir.appendingPathComponent("CCX.app", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeInstalledApp, withIntermediateDirectories: true)

        let zipBytes = Data("corrupted-zip-payload".utf8)
        let wrongHash = String(repeating: "a", count: 64)
        let checksumsData = Data("\(wrongHash)  CCX-0.5.0-macOS-universal.zip\n".utf8)

        let transport = MockAppUpdateTransport()
        transport.stubFetch(
            url: AppUpdateURLPolicy.latestReleaseAPIURL,
            outcome: .data(try makeReleaseJSON(tagName: "v0.5.0"))
        )
        transport.stubFetch(
            url: URL(string: "https://github.com/lizhichaox/ccx/releases/download/v0.5.0/SHA256SUMS.txt")!,
            outcome: .data(checksumsData)
        )
        transport.stubDownload(
            url: URL(string: "https://github.com/lizhichaox/ccx/releases/download/v0.5.0/CCX-0.5.0-macOS-universal.zip")!,
            outcome: .data(zipBytes, progressSteps: [0.5])
        )

        let reportedErrors = AtomicBox<[String]>([])
        let manager = AppUpdateManager(
            userDefaults: makeTestUserDefaults(),
            currentVersion: AppSemanticVersion(major: 0, minor: 4, patch: 4),
            currentBundleID: "com.lizhichaox.ccx",
            currentBundleURL: fakeInstalledApp,
            transport: transport,
            onUserFacingError: { message in
                reportedErrors.value.append(message)
            }
        )

        manager.checkForUpdates(userInitiated: true)
        await manager.waitForActiveTask()
        manager.installAvailableUpdate()
        await manager.waitForActiveTask()

        guard case .failed(let message, let preservedRelease) = manager.state else {
            return XCTFail("Expected .failed after checksum mismatch, got \(manager.state)")
        }
        XCTAssertEqual(message, AppUpdateError.checksumMismatch.errorDescription)
        XCTAssertEqual(preservedRelease?.version, AppSemanticVersion(major: 0, minor: 5, patch: 0))
        XCTAssertNotNil(manager.availableRelease)
        XCTAssertTrue(manager.shouldShowPopoverBanner)
        XCTAssertEqual(reportedErrors.value, [AppUpdateError.checksumMismatch.errorDescription!])

        // Dismissing the failed popover banner resets state to .available for Settings
        manager.dismissPopoverBanner()
        XCTAssertFalse(manager.shouldShowPopoverBanner)
        XCTAssertEqual(manager.dismissedBannerVersion, "0.5.0")
        XCTAssertEqual(manager.state, .available(preservedRelease!))
    }

    @MainActor
    func testManualRequiredEligibilityShowsPopoverBannerAndNotifiesErrorCallback() async throws {
        let transport = MockAppUpdateTransport()
        transport.stubFetch(
            url: AppUpdateURLPolicy.latestReleaseAPIURL,
            outcome: .data(try makeReleaseJSON(tagName: "v0.5.0"))
        )

        let reportedErrors = AtomicBox<[String]>([])
        let manager = AppUpdateManager(
            userDefaults: makeTestUserDefaults(),
            currentVersion: AppSemanticVersion(major: 0, minor: 4, patch: 4),
            currentBundleID: "com.lizhichaox.ccx",
            currentBundleURL: URL(fileURLWithPath: "/Volumes/CCX/CCX.app"),
            transport: transport,
            onUserFacingError: { message in
                reportedErrors.value.append(message)
            }
        )

        manager.checkForUpdates(userInitiated: true)
        await manager.waitForActiveTask()
        manager.installAvailableUpdate()

        guard case .failed(let message, let release) = manager.state else {
            return XCTFail("Expected .failed for /Volumes install location, got \(manager.state)")
        }
        XCTAssertEqual(release?.version, AppSemanticVersion(major: 0, minor: 5, patch: 0))
        XCTAssertTrue(manager.shouldShowPopoverBanner)
        XCTAssertEqual(reportedErrors.value, [message])
    }

    // MARK: 8. Single-Line Pixel-Width Budget Regression Tests

    @MainActor
    func testAllUpdateErrorAndEligibilityMessagesFitSingleLine() throws {
        let popoverFont = NSFont.systemFont(ofSize: 10.0)
        let settingsFont = NSFont.systemFont(ofSize: 10.5)
        let maxPopoverWidth: CGFloat = 264.0
        let maxSettingsWidth: CGFloat = 278.0

        let errors: [AppUpdateError] = [
            .invalidResponse,
            .untrustedURL,
            .responseTooLarge,
            .rateLimited,
            .httpStatus(503),
            .networkUnavailable,
            .missingReleaseAssets,
            .missingChecksumEntry,
            .checksumMismatch,
            .extractionFailed,
            .invalidBundleMetadata,
            .unsignedCurrentApp,
            .signatureVerificationFailed(-67061),
            .installLocationNotWritable(""),
            .installFailed(""),
            .cancelled,
        ]

        let dir = try makeTempDirectory()
        let realApp = dir.appendingPathComponent("CCX.app", isDirectory: true)
        try FileManager.default.createDirectory(at: realApp, withIntermediateDirectories: true)
        let symlinkApp = dir.appendingPathComponent("LinkedCCX.app")
        try FileManager.default.createSymbolicLink(at: symlinkApp, withDestinationURL: realApp)

        func collectAllMessages() throws -> [String] {
            var messages: [String] = try errors.map { error in
                try XCTUnwrap(error.errorDescription, "Missing errorDescription for \(error)")
            }

            let eligibilityChecks: [AppInstallEligibility] = [
                AppUpdateInstaller.installEligibility(for: dir.appendingPathComponent("NotAnApp")),
                AppUpdateInstaller.installEligibility(for: URL(fileURLWithPath: "/private/var/folders/xx/AppTranslocation/1234/d/CCX.app")),
                AppUpdateInstaller.installEligibility(for: URL(fileURLWithPath: "/Volumes/CCX/CCX.app")),
                AppUpdateInstaller.installEligibility(for: symlinkApp),
                AppUpdateInstaller.installEligibility(for: realApp) { path in path == realApp.path },
            ]
            for eligibility in eligibilityChecks {
                guard case .manualRequired(let reason) = eligibility else {
                    XCTFail("Expected .manualRequired, got \(eligibility)")
                    return []
                }
                messages.append(reason)
            }

            messages.append(contentsOf: AppUpdateInstaller.Messages.allAuxiliaryMessages)
            return messages
        }

        var messagesByLanguage: [CCXLanguage: [String]] = [:]

        for language in CCXLanguage.allCases {
            let messages = try CCXL10n.withLanguageForTesting(language) {
                try collectAllMessages()
            }
            XCTAssertFalse(messages.isEmpty, "[\(language.rawValue)] Expected update messages to verify")
            messagesByLanguage[language] = messages

            for message in messages {
                XCTAssertFalse(message.isEmpty, "[\(language.rawValue)] Update error prompt must not be empty")
                XCTAssertFalse(message.contains("\n"), "[\(language.rawValue)] Update error prompt must be single-line: \(message)")

                let popoverWidth = ceil(NSAttributedString(string: message, attributes: [.font: popoverFont]).size().width)
                XCTAssertLessThanOrEqual(
                    popoverWidth,
                    maxPopoverWidth,
                    "[\(language.rawValue)] Update prompt '\(message)' measured \(popoverWidth)pt at 10pt, exceeding Popover \(maxPopoverWidth)pt budget"
                )

                let settingsWidth = ceil(NSAttributedString(string: message, attributes: [.font: settingsFont]).size().width)
                XCTAssertLessThanOrEqual(
                    settingsWidth,
                    maxSettingsWidth,
                    "[\(language.rawValue)] Update prompt '\(message)' measured \(settingsWidth)pt at 10.5pt, exceeding Settings \(maxSettingsWidth)pt budget"
                )
            }
        }

        // Verify every update prompt is actually localized between English and Simplified Chinese.
        let enMessages = try XCTUnwrap(messagesByLanguage[.en])
        let zhMessages = try XCTUnwrap(messagesByLanguage[.zhHans])
        XCTAssertEqual(enMessages.count, zhMessages.count)
        for (en, zh) in zip(enMessages, zhMessages) {
            XCTAssertNotEqual(en, zh, "Expected Simplified Chinese localization distinct from English for '\(en)'")
        }
    }
}
