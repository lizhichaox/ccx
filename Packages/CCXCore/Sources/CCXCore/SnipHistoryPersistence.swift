import CoreGraphics
import Darwin
import Foundation
import ImageIO

/// Codable metadata record persisted alongside each cached PNG in `RecentSnips`.
struct SnipHistoryManifestRecord: Codable, Sendable {
    let id: UUID
    let timestamp: Date
    let scale: CGFloat
    let screenRect: CGRect
}

/// Private, user-only disk store backing `ClipboardStore.history` across app restarts.
final class SnipHistoryDiskStore: Sendable {
    static let maxIndexFileBytes = 2 * 1024 * 1024 // 2 MB

    let directoryURL: URL
    private let ioQueue = DispatchQueue(label: "com.lizhichaox.ccx.snip-history-io", qos: .utility)

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    static func defaultDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("com.lizhichaox.ccx", isDirectory: true)
            .appendingPathComponent("RecentSnips", isDirectory: true)
    }

    func save(entry: SnipHistoryEntry, manifest: [SnipHistoryManifestRecord]) {
        ioQueue.async { [directoryURL] in
            guard Self.ensureSecureDirectory(at: directoryURL) else { return }

            let pngName = "\(entry.id.uuidString).png"
            let pngURL = directoryURL.appendingPathComponent(pngName)
            if !Self.isExistingRegularUserFile(at: pngURL),
               let pngData = ClipboardStore.encode(entry.image, type: .png, scale: entry.scale) {
                _ = Self.writePrivateFileAtomically(pngData, to: pngURL)
            }

            let indexURL = directoryURL.appendingPathComponent("index.json")
            if let indexData = try? JSONEncoder().encode(manifest) {
                _ = Self.writePrivateFileAtomically(indexData, to: indexURL)
            }

            Self.pruneUnreferencedFiles(in: directoryURL, keepingPNGNames: Set(manifest.map { "\($0.id.uuidString).png" }))
        }
    }

    func clearAll() {
        ioQueue.async { [directoryURL] in
            guard Self.verifyExistingSecureDirectory(at: directoryURL) else { return }
            Self.removeAllChildren(in: directoryURL)
        }
    }

    func loadAll(
        maxCount: Int,
        maxTotalMemoryBytes: Int = ClipboardStore.defaultMaxHistoryMemoryBytes,
        completion: @escaping @Sendable ([SnipHistoryEntry]) -> Void
    ) {
        ioQueue.async { [directoryURL] in
            guard maxCount > 0,
                  Self.verifyExistingSecureDirectory(at: directoryURL)
            else {
                completion([])
                return
            }

            // Harden existing directory permissions to 0o700 if loosened externally.
            _ = Self.enforcePrivateDirectoryPermissions(at: directoryURL)

            let indexURL = directoryURL.appendingPathComponent("index.json")
            guard Self.entryExists(at: indexURL) else {
                completion([])
                return
            }

            guard let data = Self.readPrivateRegularFile(at: indexURL, maxBytes: Self.maxIndexFileBytes),
                  let records = try? JSONDecoder().decode([SnipHistoryManifestRecord].self, from: data)
            else {
                // Self-heal corrupt, oversized, or symlinked index.json and orphaned files.
                Self.removeAllChildren(in: directoryURL)
                completion([])
                return
            }

            var entries: [SnipHistoryEntry] = []
            var validRecords: [SnipHistoryManifestRecord] = []
            var seenIDs: Set<UUID> = []
            var totalMemoryBytes = 0
            var needsCleanup = records.count > maxCount

            for record in records.prefix(maxCount) {
                guard seenIDs.insert(record.id).inserted else {
                    needsCleanup = true
                    continue
                }

                let pngURL = directoryURL.appendingPathComponent("\(record.id.uuidString).png")
                guard let pngData = Self.readPrivateRegularFile(at: pngURL, maxBytes: ClipboardStore.maxDecodeFileBytes),
                      let (image, _) = ClipboardStore.decode(pngData)
                else {
                    needsCleanup = true
                    continue
                }

                let imageBytes = ClipboardStore.estimatedMemoryBytes(for: image)
                if !entries.isEmpty, maxTotalMemoryBytes > 0, totalMemoryBytes + imageBytes > maxTotalMemoryBytes {
                    needsCleanup = true
                    break
                }

                let sanitizedScale = Self.sanitizeScale(record.scale)
                let sanitizedRect = Self.sanitizeRect(record.screenRect)
                if sanitizedScale != record.scale || sanitizedRect != record.screenRect {
                    needsCleanup = true
                }

                entries.append(SnipHistoryEntry(
                    id: record.id,
                    timestamp: record.timestamp,
                    image: image,
                    scale: sanitizedScale,
                    screenRect: sanitizedRect
                ))
                validRecords.append(SnipHistoryManifestRecord(
                    id: record.id,
                    timestamp: record.timestamp,
                    scale: sanitizedScale,
                    screenRect: sanitizedRect
                ))
                totalMemoryBytes += imageBytes
            }

            if needsCleanup {
                if validRecords.isEmpty {
                    Self.removeAllChildren(in: directoryURL)
                } else {
                    if let indexData = try? JSONEncoder().encode(validRecords) {
                        _ = Self.writePrivateFileAtomically(indexData, to: indexURL)
                    }
                    Self.pruneUnreferencedFiles(
                        in: directoryURL,
                        keepingPNGNames: Set(validRecords.map { "\($0.id.uuidString).png" })
                    )
                }
            }

            completion(entries)
        }
    }

    func flush() {
        ioQueue.sync {}
    }

    // MARK: - Private Security Helpers

    private static func sanitizeScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite, scale > 0 else { return 1 }
        return min(max(scale, 0.5), 8)
    }

    private static func sanitizeRect(_ rect: CGRect) -> CGRect {
        guard !rect.isNull, !rect.isInfinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite,
              rect.size.width >= 0, rect.size.height >= 0
        else { return .zero }
        return rect
    }

    private static func ensureSecureDirectory(at directoryURL: URL) -> Bool {
        let parentURL = directoryURL.deletingLastPathComponent()
        if parentURL.lastPathComponent == "com.lizhichaox.ccx" {
            guard ensureSinglePrivateDirectory(at: parentURL) else { return false }
        }
        return ensureSinglePrivateDirectory(at: directoryURL)
    }

    private static func ensureSinglePrivateDirectory(at url: URL) -> Bool {
        let path = url.path
        var st = stat()
        if Darwin.lstat(path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == Darwin.getuid() else {
                return false
            }
            return enforcePrivateDirectoryPermissions(at: url)
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

        if Darwin.lstat(path, &st) != 0 { return false }
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == Darwin.getuid() else { return false }
        return enforcePrivateDirectoryPermissions(at: url)
    }

    private static func verifyExistingSecureDirectory(at directoryURL: URL) -> Bool {
        let parentURL = directoryURL.deletingLastPathComponent()
        if parentURL.lastPathComponent == "com.lizhichaox.ccx" {
            var parentStat = stat()
            guard Darwin.lstat(parentURL.path, &parentStat) == 0,
                  (parentStat.st_mode & S_IFMT) == S_IFDIR,
                  parentStat.st_uid == Darwin.getuid()
            else { return false }
        }
        var st = stat()
        guard Darwin.lstat(directoryURL.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == Darwin.getuid()
    }

    private static func enforcePrivateDirectoryPermissions(at url: URL) -> Bool {
        Darwin.chmod(url.path, 0o700) == 0
    }

    private static func entryExists(at url: URL) -> Bool {
        var st = stat()
        return Darwin.lstat(url.path, &st) == 0
    }

    private static func isExistingRegularUserFile(at url: URL) -> Bool {
        var st = stat()
        guard Darwin.lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG
            && st.st_uid == Darwin.getuid()
            && (st.st_mode & 0o777) == 0o600
            && st.st_size > 0
    }

    private static func writePrivateFileAtomically(_ data: Data, to destinationURL: URL) -> Bool {
        let destPath = destinationURL.path
        var destStat = stat()
        if Darwin.lstat(destPath, &destStat) == 0 {
            // Refuse to overwrite symlinks, directories, or files owned by another user.
            guard (destStat.st_mode & S_IFMT) == S_IFREG, destStat.st_uid == Darwin.getuid() else {
                return false
            }
        } else if errno != ENOENT {
            return false
        }

        let directoryURL = destinationURL.deletingLastPathComponent()
        let tempName = ".tmp-\(UUID().uuidString)"
        let tempURL = directoryURL.appendingPathComponent(tempName)
        let tempPath = tempURL.path

        let fd = Darwin.open(tempPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }

        var succeeded = false
        defer {
            if !succeeded {
                _ = Darwin.unlink(tempPath)
            }
        }

        guard Darwin.fchmod(fd, 0o600) == 0 else {
            _ = Darwin.close(fd)
            return false
        }

        let writeOK: Bool = data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return true }
            var remaining = rawBuffer.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(fd, base.advanced(by: offset), remaining)
                if written > 0 {
                    offset += written
                    remaining -= written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }

        let closeOK = Darwin.close(fd) == 0
        guard writeOK, closeOK else { return false }

        // Re-check destination isn't a symlink right before atomic rename.
        if Darwin.lstat(destPath, &destStat) == 0 {
            guard (destStat.st_mode & S_IFMT) == S_IFREG, destStat.st_uid == Darwin.getuid() else {
                return false
            }
        } else if errno != ENOENT {
            return false
        }

        guard Darwin.rename(tempPath, destPath) == 0 else { return false }
        succeeded = true
        return true
    }

    private static func readPrivateRegularFile(at url: URL, maxBytes: Int) -> Data? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { _ = Darwin.close(fd) }

        var st = stat()
        guard Darwin.fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == Darwin.getuid(),
              st.st_size >= 0,
              st.st_size <= Int64(maxBytes)
        else { return nil }

        let expectedSize = Int(st.st_size)
        var data = Data()
        data.reserveCapacity(expectedSize)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            let bytesRead = chunk.withUnsafeMutableBytes { buf in
                Darwin.read(fd, buf.baseAddress, buf.count)
            }
            if bytesRead > 0 {
                if data.count + bytesRead > maxBytes {
                    return nil
                }
                data.append(contentsOf: chunk[0..<bytesRead])
            } else if bytesRead == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return data
    }

    private static func pruneUnreferencedFiles(in directoryURL: URL, keepingPNGNames validNames: Set<String>) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            return
        }
        for fileURL in contents {
            let name = fileURL.lastPathComponent
            if name == "index.json" || validNames.contains(name) {
                continue
            }
            if name.hasSuffix(".png") || name.hasPrefix(".tmp-") {
                _ = Darwin.unlink(fileURL.path)
            }
        }
    }

    private static func removeAllChildren(in directoryURL: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            return
        }
        for fileURL in contents {
            var st = stat()
            guard Darwin.lstat(fileURL.path, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                try? fm.removeItem(at: fileURL)
            } else {
                _ = Darwin.unlink(fileURL.path)
            }
        }
    }
}
