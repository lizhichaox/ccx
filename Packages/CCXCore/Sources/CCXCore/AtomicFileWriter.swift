import Darwin
import Foundation

/// Shared POSIX-hardened atomic and exclusive file-writing helpers used across capture, pin, and recording exports.
public enum AtomicFileWriter {
    public static let defaultMaxSuffixAttempts = 9_999

    /// Strips trailing path separators while preserving `"/"`.
    public static func normalizedPath(_ path: String) -> String {
        var normalized = path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    /// Returns `true` when `path` exists as a real directory (not a symlink) via `lstat`.
    public static func isRealDirectory(atPath path: String) -> Bool {
        let normalized = normalizedPath(path)
        guard !normalized.isEmpty else { return false }
        var st = stat()
        return Darwin.lstat(normalized, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Returns `true` when `path` is a writable real directory (not a symlink).
    public static func isWritableRealDirectory(atPath path: String) -> Bool {
        let normalized = normalizedPath(path)
        return isRealDirectory(atPath: normalized) && FileManager.default.isWritableFile(atPath: normalized)
    }

    /// Returns `true` when any directory entry (including a dangling symlink) exists at `path`.
    public static func entryExistsOrSymlink(atPath path: String) -> Bool {
        let normalized = normalizedPath(path)
        guard !normalized.isEmpty else { return false }
        var st = stat()
        return Darwin.lstat(normalized, &st) == 0 || FileManager.default.fileExists(atPath: normalized)
    }

    /// Ensures `url` exists as a non-symlink directory owned by the current user with `0o700` permissions.
    public static func ensurePrivateDirectory(at url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let path = normalizedPath(url.path)
        guard !path.isEmpty else { return false }
        var st = stat()
        if Darwin.lstat(path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == Darwin.getuid() else { return false }
            return Darwin.chmod(path, 0o700) == 0
        }
        guard errno == ENOENT else { return false }
        if Darwin.mkdir(path, 0o700) != 0 && errno != EEXIST {
            guard errno == ENOENT else { return false }
            do {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: path, isDirectory: true),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                return false
            }
        }
        guard Darwin.lstat(path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == Darwin.getuid()
        else { return false }
        return Darwin.chmod(path, 0o700) == 0
    }

    /// Returns `true` when `url` is an existing non-symlink directory owned by the current user.
    public static func isPrivateExistingDirectory(at url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let path = normalizedPath(url.path)
        guard !path.isEmpty else { return false }
        var st = stat()
        return Darwin.lstat(path, &st) == 0
            && (st.st_mode & S_IFMT) == S_IFDIR
            && st.st_uid == Darwin.getuid()
    }

    /// Atomically writes `data` to `url`, refusing symlinks and non-regular existing destinations
    /// while preserving any existing file if writing fails.
    public static func writeDataAtomically(_ data: Data, to url: URL) throws {
        guard url.isFileURL else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let path = normalizedPath(url.path)
        guard !path.isEmpty else {
            throw CocoaError(.fileWriteNoPermission)
        }
        var st = stat()
        if Darwin.lstat(path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFREG else {
                throw CocoaError(.fileWriteNoPermission)
            }
        } else if errno != ENOENT {
            throw mapPOSIXWriteError(errno)
        }
        let normalizedURL = URL(fileURLWithPath: path, isDirectory: false)
        try data.write(to: normalizedURL, options: .atomic)
    }

    /// Atomically creates a new unique file inside `directory` without ever overwriting existing files
    /// or following symlinks, even under concurrent quick saves in the same second.
    public static func writeDataExclusively(
        _ data: Data,
        in directory: URL,
        stem: String,
        fileExtension: String,
        maxSuffixAttempts: Int = defaultMaxSuffixAttempts
    ) throws -> URL {
        guard directory.isFileURL,
              isValidPathComponent(stem),
              isValidPathComponent(fileExtension)
        else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let dirPath = normalizedPath(directory.path)
        guard !dirPath.isEmpty else {
            throw CocoaError(.fileWriteNoPermission)
        }
        var dirStat = stat()
        guard Darwin.lstat(dirPath, &dirStat) == 0,
              (dirStat.st_mode & S_IFMT) == S_IFDIR
        else {
            throw CocoaError(.fileWriteNoPermission)
        }

        let dirURL = URL(fileURLWithPath: dirPath, isDirectory: true)
        let tempURL = dirURL.appendingPathComponent(".ccx-save-\(UUID().uuidString).tmp", isDirectory: false)
        let tempPath = tempURL.path
        let fd = Darwin.open(tempPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard fd >= 0 else {
            throw mapPOSIXWriteError(errno)
        }

        var movedTemp = false
        defer {
            if !movedTemp {
                _ = Darwin.unlink(tempPath)
            }
        }

        let writeResult = writeAllBytes(data, to: fd)
        let closeResult = Darwin.close(fd)
        let closeErrno = errno
        guard writeResult.succeeded else {
            throw mapPOSIXWriteError(writeResult.errorCode)
        }
        guard closeResult == 0 else {
            throw mapPOSIXWriteError(closeErrno)
        }

        let clampedMaxAttempts = max(1, maxSuffixAttempts)
        var suffix = 1
        var usedUUIDFallback = false
        while true {
            let candidateName: String
            if suffix == 1 {
                candidateName = "\(stem).\(fileExtension)"
            } else if suffix <= clampedMaxAttempts {
                candidateName = "\(stem)-\(suffix).\(fileExtension)"
            } else if !usedUUIDFallback {
                usedUUIDFallback = true
                candidateName = "\(stem)-\(UUID().uuidString.prefix(8)).\(fileExtension)"
            } else {
                throw CocoaError(.fileWriteNoPermission)
            }

            let candidateURL = dirURL.appendingPathComponent(candidateName, isDirectory: false)
            let candidatePath = candidateURL.path

            if Darwin.renamex_np(tempPath, candidatePath, UInt32(RENAME_EXCL)) == 0 {
                movedTemp = true
                return candidateURL
            }
            let err = errno
            if err == EEXIST {
                suffix += 1
                continue
            }
            if err == ENOTSUP || err == EOPNOTSUPP || err == EINVAL {
                if Darwin.link(tempPath, candidatePath) == 0 {
                    _ = Darwin.unlink(tempPath)
                    movedTemp = true
                    return candidateURL
                }
                if errno == EEXIST {
                    suffix += 1
                    continue
                }
                // Volumes without hard-link support (e.g. FAT32/exFAT): exclusive create directly.
                let directFD = Darwin.open(candidatePath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
                if directFD >= 0 {
                    let directWrite = writeAllBytes(data, to: directFD)
                    let directClose = Darwin.close(directFD)
                    let directCloseErrno = errno
                    if directWrite.succeeded && directClose == 0 {
                        return candidateURL
                    }
                    _ = Darwin.unlink(candidatePath)
                    throw mapPOSIXWriteError(directWrite.succeeded ? directCloseErrno : directWrite.errorCode)
                }
                if errno == EEXIST {
                    suffix += 1
                    continue
                }
                throw mapPOSIXWriteError(errno)
            }
            throw mapPOSIXWriteError(err)
        }
    }

    /// Atomically moves `sourceURL` into a new unique file inside `directory` without ever overwriting
    /// existing files or following symlinks, even across concurrent saves or separate volumes.
    public static func moveFileExclusively(
        from sourceURL: URL,
        in directory: URL,
        stem: String,
        fileExtension: String,
        maxSuffixAttempts: Int = defaultMaxSuffixAttempts
    ) throws -> URL {
        guard sourceURL.isFileURL,
              directory.isFileURL,
              isValidPathComponent(stem),
              isValidPathComponent(fileExtension)
        else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let normalizedSourcePath = normalizedPath(sourceURL.path)
        let normalizedDirPath = normalizedPath(directory.path)
        guard !normalizedSourcePath.isEmpty, !normalizedDirPath.isEmpty else {
            throw CocoaError(.fileWriteNoPermission)
        }

        var sourceStat = stat()
        if Darwin.lstat(normalizedSourcePath, &sourceStat) != 0 {
            throw errno == ENOENT ? CocoaError(.fileNoSuchFile) : CocoaError(.fileWriteNoPermission)
        }
        guard (sourceStat.st_mode & S_IFMT) == S_IFREG else {
            throw CocoaError(.fileWriteNoPermission)
        }

        var dirStat = stat()
        guard Darwin.lstat(normalizedDirPath, &dirStat) == 0,
              (dirStat.st_mode & S_IFMT) == S_IFDIR
        else {
            throw CocoaError(.fileWriteNoPermission)
        }

        let dirURL = URL(fileURLWithPath: normalizedDirPath, isDirectory: true)
        let normalizedSourceURL = URL(fileURLWithPath: normalizedSourcePath, isDirectory: false)
        let fm = FileManager.default
        var stagedSourceURL = normalizedSourceURL
        var stagedSourcePath = normalizedSourcePath
        var didCopyToDestVolume = false

        defer {
            if didCopyToDestVolume {
                try? fm.removeItem(at: stagedSourceURL)
            }
        }

        let clampedMaxAttempts = max(1, maxSuffixAttempts)
        var suffix = 1
        var usedUUIDFallback = false
        while true {
            let candidateName: String
            if suffix == 1 {
                candidateName = "\(stem).\(fileExtension)"
            } else if suffix <= clampedMaxAttempts {
                candidateName = "\(stem)-\(suffix).\(fileExtension)"
            } else if !usedUUIDFallback {
                usedUUIDFallback = true
                candidateName = "\(stem)-\(UUID().uuidString.prefix(8)).\(fileExtension)"
            } else {
                throw CocoaError(.fileWriteNoPermission)
            }

            let candidateURL = dirURL.appendingPathComponent(candidateName, isDirectory: false)
            let candidatePath = candidateURL.path

            if Darwin.renamex_np(stagedSourcePath, candidatePath, UInt32(RENAME_EXCL)) == 0 {
                if didCopyToDestVolume {
                    didCopyToDestVolume = false
                    try? fm.removeItem(at: normalizedSourceURL)
                }
                return candidateURL
            }

            let err = errno
            if err == EEXIST {
                suffix += 1
                continue
            }
            if err == EXDEV && !didCopyToDestVolume {
                let siblingTemp = dirURL.appendingPathComponent(".ccx-save-\(UUID().uuidString).tmp", isDirectory: false)
                try fm.copyItem(at: normalizedSourceURL, to: siblingTemp)
                stagedSourceURL = siblingTemp
                stagedSourcePath = siblingTemp.path
                didCopyToDestVolume = true
                continue
            }
            if err == ENOTSUP || err == EOPNOTSUPP || err == EINVAL {
                if Darwin.link(stagedSourcePath, candidatePath) == 0 {
                    _ = Darwin.unlink(stagedSourcePath)
                    if didCopyToDestVolume {
                        didCopyToDestVolume = false
                        try? fm.removeItem(at: normalizedSourceURL)
                    }
                    return candidateURL
                }
                if errno == EEXIST {
                    suffix += 1
                    continue
                }
                // Volumes without hard-link support (e.g. FAT32/exFAT): check lstat and move if vacant.
                if entryExistsOrSymlink(atPath: candidatePath) {
                    suffix += 1
                    continue
                }
                try fm.moveItem(at: stagedSourceURL, to: candidateURL)
                if didCopyToDestVolume {
                    didCopyToDestVolume = false
                    try? fm.removeItem(at: normalizedSourceURL)
                }
                return candidateURL
            }
            throw mapPOSIXWriteError(err)
        }
    }

    /// Moves `sourceURL` to `destinationURL` without deleting an existing file before replacement
    /// and without losing `sourceURL` if the copy or move fails (including across volumes).
    public static func moveFileAtomically(from sourceURL: URL, to destinationURL: URL) throws {
        guard sourceURL.isFileURL, destinationURL.isFileURL else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let normalizedSourcePath = normalizedPath(sourceURL.path)
        let normalizedDestPath = normalizedPath(destinationURL.path)
        guard !normalizedSourcePath.isEmpty, !normalizedDestPath.isEmpty else {
            throw CocoaError(.fileWriteNoPermission)
        }

        var sourceStat = stat()
        if Darwin.lstat(normalizedSourcePath, &sourceStat) != 0 {
            throw errno == ENOENT ? CocoaError(.fileNoSuchFile) : CocoaError(.fileWriteNoPermission)
        }
        guard (sourceStat.st_mode & S_IFMT) == S_IFREG else {
            throw CocoaError(.fileWriteNoPermission)
        }

        let fm = FileManager.default
        let destStat = try existingRegularDestinationStat(atPath: normalizedDestPath)
        if let destStat,
           sourceStat.st_dev == destStat.st_dev,
           sourceStat.st_ino == destStat.st_ino {
            return
        }
        let destinationExists = destStat != nil
        let normalizedSourceURL = URL(fileURLWithPath: normalizedSourcePath, isDirectory: false)
        let normalizedDestURL = URL(fileURLWithPath: normalizedDestPath, isDirectory: false)

        if destinationExists {
            do {
                _ = try fm.replaceItemAt(normalizedDestURL, withItemAt: normalizedSourceURL)
                return
            } catch {
                // Cross-volume replace falls back to staging a sibling temp file in the
                // destination directory and swapping atomically on the destination volume.
            }
        } else if Darwin.rename(normalizedSourcePath, normalizedDestPath) == 0 {
            return
        }

        let siblingTemp = normalizedDestURL
            .deletingLastPathComponent()
            .appendingPathComponent(".ccx-save-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: normalizedSourceURL, to: siblingTemp)
            if try existingRegularDestinationStat(atPath: normalizedDestPath) != nil {
                _ = try fm.replaceItemAt(normalizedDestURL, withItemAt: siblingTemp)
            } else {
                try fm.moveItem(at: siblingTemp, to: normalizedDestURL)
            }
            try? fm.removeItem(at: normalizedSourceURL)
        } catch {
            try? fm.removeItem(at: siblingTemp)
            throw error
        }
    }

    /// Prunes older entries in a private directory owned by the current user, keeping the newest `maxKeep`.
    public static func prunePrivateEntries(in directory: URL, keepingLatest maxKeep: Int) {
        guard isPrivateExistingDirectory(at: directory) else { return }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: []
        ) else { return }

        let sorted = urls.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return lDate > rDate
        }
        for url in sorted.dropFirst(max(0, maxKeep)) {
            unlinkOwnedEntry(at: url)
        }
    }

    /// Removes all owned regular/symlink entries in a private directory.
    public static func clearPrivateEntries(in directory: URL) {
        guard isPrivateExistingDirectory(at: directory) else { return }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for url in urls {
            unlinkOwnedEntry(at: url)
        }
    }

    /// Removes owned regular/symlink entries older than `maxAge` in a private directory.
    public static func cleanupPrivateEntries(
        in directory: URL,
        olderThan maxAge: TimeInterval,
        now: Date = Date()
    ) {
        guard isPrivateExistingDirectory(at: directory) else { return }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: []
        ) else { return }
        let cutoff = now.addingTimeInterval(-maxAge)
        for url in urls {
            if let created = symlinkSafeCreationDate(at: url), created < cutoff {
                unlinkOwnedEntry(at: url)
            }
        }
    }

    // MARK: - Private Helpers

    private static func isValidPathComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("\0")
    }

    private static func symlinkSafeCreationDate(at url: URL) -> Date? {
        let path = normalizedPath(url.path)
        guard !path.isEmpty else { return nil }
        var st = stat()
        guard Darwin.lstat(path, &st) == 0 else { return nil }
        let ts = st.st_birthtimespec.tv_sec > 0 ? st.st_birthtimespec : st.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000)
    }

    private static func existingRegularDestinationStat(atPath path: String) throws -> stat? {
        var destStat = stat()
        if Darwin.lstat(path, &destStat) == 0 {
            guard (destStat.st_mode & S_IFMT) == S_IFREG else {
                throw CocoaError(.fileWriteNoPermission)
            }
            return destStat
        }
        if errno == ENOENT {
            return nil
        }
        throw mapPOSIXWriteError(errno)
    }

    private static func unlinkOwnedEntry(at url: URL) {
        let path = normalizedPath(url.path)
        guard !path.isEmpty else { return }
        var st = stat()
        guard Darwin.lstat(path, &st) == 0,
              st.st_uid == Darwin.getuid(),
              (st.st_mode & S_IFMT) == S_IFREG || (st.st_mode & S_IFMT) == S_IFLNK
        else { return }
        _ = Darwin.unlink(path)
    }

    private static func writeAllBytes(_ data: Data, to fd: Int32) -> (succeeded: Bool, errorCode: Int32) {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return (true, 0) }
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
                    return (false, errno)
                }
            }
            return (true, 0)
        }
    }

    private static func mapPOSIXWriteError(_ errnoValue: Int32) -> Error {
        switch errnoValue {
        case ENOSPC:
            CocoaError(.fileWriteOutOfSpace)
        case EROFS:
            CocoaError(.fileWriteVolumeReadOnly)
        case ENOENT:
            CocoaError(.fileNoSuchFile)
        default:
            CocoaError(.fileWriteNoPermission)
        }
    }
}
