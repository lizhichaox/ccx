@testable import CCXCore
import Darwin
import Foundation
import XCTest

final class AtomicFileWriterTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccx-atomic-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    func testMoveFileExclusivelySuffixesUUIDFallbackAndRejectsUnsafeInputs() throws {
        let dir = try makeTempDir()
        let srcDir = try makeTempDir()

        // First move claims CCX-Test.mp4, second move gets CCX-Test-2.mp4.
        let src1 = srcDir.appendingPathComponent("rec1.mp4")
        let src2 = srcDir.appendingPathComponent("rec2.mp4")
        try Data("video-1".utf8).write(to: src1)
        try Data("video-2".utf8).write(to: src2)

        let out1 = try AtomicFileWriter.moveFileExclusively(from: src1, in: dir, stem: "CCX-Test", fileExtension: "mp4")
        XCTAssertEqual(out1.lastPathComponent, "CCX-Test.mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: src1.path))
        XCTAssertEqual(try Data(contentsOf: out1), Data("video-1".utf8))

        let out2 = try AtomicFileWriter.moveFileExclusively(from: src2, in: dir, stem: "CCX-Test", fileExtension: "mp4")
        XCTAssertEqual(out2.lastPathComponent, "CCX-Test-2.mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: src2.path))
        XCTAssertEqual(try Data(contentsOf: out2), Data("video-2".utf8))

        // Exhausting maxSuffixAttempts = 2 falls back to a UUID-suffixed filename.
        let src3 = srcDir.appendingPathComponent("rec3.mp4")
        try Data("video-3".utf8).write(to: src3)
        let out3 = try AtomicFileWriter.moveFileExclusively(
            from: src3,
            in: dir,
            stem: "CCX-Test",
            fileExtension: "mp4",
            maxSuffixAttempts: 2
        )
        XCTAssertTrue(out3.lastPathComponent.hasPrefix("CCX-Test-"))
        XCTAssertTrue(out3.lastPathComponent.hasSuffix(".mp4"))
        XCTAssertNotEqual(out3.lastPathComponent, "CCX-Test-3.mp4")
        XCTAssertEqual(try Data(contentsOf: out3), Data("video-3".utf8))

        // Rejects symlink source, directory source, and unsafe stem/extension components.
        let realTarget = srcDir.appendingPathComponent("real.mp4")
        try Data("real".utf8).write(to: realTarget)
        let symlinkSource = srcDir.appendingPathComponent("link.mp4")
        try FileManager.default.createSymbolicLink(at: symlinkSource, withDestinationURL: realTarget)
        XCTAssertThrowsError(try AtomicFileWriter.moveFileExclusively(from: symlinkSource, in: dir, stem: "Safe", fileExtension: "mp4"))

        let subdirSource = srcDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdirSource, withIntermediateDirectories: true)
        XCTAssertThrowsError(try AtomicFileWriter.moveFileExclusively(from: subdirSource, in: dir, stem: "Safe", fileExtension: "mp4"))

        let preserved = srcDir.appendingPathComponent("preserved.mp4")
        try Data("keep".utf8).write(to: preserved)
        for badStem in ["", ".", "..", "a/b", "a\\b", "a\0b"] {
            XCTAssertThrowsError(try AtomicFileWriter.moveFileExclusively(from: preserved, in: dir, stem: badStem, fileExtension: "mp4"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path))
    }

    func testMoveFileAtomicallyReplacesAndPreservesSourceOnFailure() throws {
        let dir = try makeTempDir()
        let srcDir = try makeTempDir()

        // Move into vacant destination.
        let src1 = srcDir.appendingPathComponent("s1.mov")
        try Data("first".utf8).write(to: src1)
        let dest1 = dir.appendingPathComponent("Final.mov")
        try AtomicFileWriter.moveFileAtomically(from: src1, to: dest1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src1.path))
        XCTAssertEqual(try Data(contentsOf: dest1), Data("first".utf8))

        // Atomically replace existing regular file.
        let src2 = srcDir.appendingPathComponent("s2.mov")
        try Data("second".utf8).write(to: src2)
        try AtomicFileWriter.moveFileAtomically(from: src2, to: dest1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src2.path))
        XCTAssertEqual(try Data(contentsOf: dest1), Data("second".utf8))

        // Refuses symlink destination while preserving both source and symlink.
        let victim = dir.appendingPathComponent("victim.mov")
        try Data("victim".utf8).write(to: victim)
        let symlinkDest = dir.appendingPathComponent("link.mov")
        try FileManager.default.createSymbolicLink(at: symlinkDest, withDestinationURL: victim)
        let src3 = srcDir.appendingPathComponent("s3.mov")
        try Data("payload".utf8).write(to: src3)
        XCTAssertThrowsError(try AtomicFileWriter.moveFileAtomically(from: src3, to: symlinkDest))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src3.path))
        XCTAssertEqual(try Data(contentsOf: victim), Data("victim".utf8))

        // Missing destination parent preserves source file.
        let missingParentDest = dir.appendingPathComponent("nonexistent/out.mov")
        XCTAssertThrowsError(try AtomicFileWriter.moveFileAtomically(from: src3, to: missingParentDest))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src3.path))

        // Same-file move is a safe no-op that never deletes the file.
        try AtomicFileWriter.moveFileAtomically(from: dest1, to: dest1)
        XCTAssertEqual(try Data(contentsOf: dest1), Data("second".utf8))

        // Refuses existing directory destination while preserving source and directory.
        let existingSubdir = dir.appendingPathComponent("ExistingFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: existingSubdir, withIntermediateDirectories: true)
        XCTAssertThrowsError(try AtomicFileWriter.moveFileAtomically(from: src3, to: existingSubdir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src3.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingSubdir.path))
    }

    func testWriteDataExclusivelyAtomicallyAndPrivateDirectoryCleanup() throws {
        let root = try makeTempDir()
        let privateDir = root.appendingPathComponent("private", isDirectory: true)
        XCTAssertTrue(AtomicFileWriter.ensurePrivateDirectory(at: privateDir))
        XCTAssertTrue(AtomicFileWriter.isPrivateExistingDirectory(at: privateDir))

        var st = stat()
        XCTAssertEqual(Darwin.lstat(privateDir.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)

        let f1 = try AtomicFileWriter.writeDataExclusively(Data("1".utf8), in: privateDir, stem: "Shot", fileExtension: "png")
        let f2 = try AtomicFileWriter.writeDataExclusively(Data("2".utf8), in: privateDir, stem: "Shot", fileExtension: "png")
        let f3 = try AtomicFileWriter.writeDataExclusively(Data("3".utf8), in: privateDir, stem: "Shot", fileExtension: "png")
        XCTAssertEqual(f1.lastPathComponent, "Shot.png")
        XCTAssertEqual(f2.lastPathComponent, "Shot-2.png")
        XCTAssertEqual(f3.lastPathComponent, "Shot-3.png")

        try AtomicFileWriter.writeDataAtomically(Data("updated".utf8), to: f2)
        XCTAssertEqual(try Data(contentsOf: f2), Data("updated".utf8))

        // Assign creation dates after atomic replacement so ordering is deterministic.
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: f1.path)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: f2.path)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 3_000)], ofItemAtPath: f3.path)

        // Prune keeping latest 2 removes f1.
        AtomicFileWriter.prunePrivateEntries(in: privateDir, keepingLatest: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f2.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f3.path))

        // Age-based cleanup at t=2600 with maxAge=100 removes f2 (t=2000), keeps f3 (t=3000).
        AtomicFileWriter.cleanupPrivateEntries(
            in: privateDir,
            olderThan: 100,
            now: Date(timeIntervalSince1970: 2_600)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: f2.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f3.path))

        AtomicFileWriter.clearPrivateEntries(in: privateDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f3.path))
    }
}
