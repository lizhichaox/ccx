import CCXCore
import Darwin
import Foundation

/// Filesystem security helpers for recording staging directories and output files.
///
/// Enforces restrictive `0700` directory permissions, `0600` output file permissions,
/// `lstat`-based symlink/ownership validation, and scoped temporary-file cleanup.
enum RecordingFileSecurity {
    static let stagedFilePrefix = "CCX-Rec-"

    /// Strips trailing slashes (except root `/`) so `lstat` inspects symlinks themselves rather than following them.
    private static func lstatPath(for url: URL) -> String {
        var path = url.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// Ensures `url` exists as a user-owned, non-symlink directory with `0700` permissions.
    /// Uses `open(..., O_DIRECTORY | O_NOFOLLOW)` + `fstat`/`fchmod` to eliminate symlink TOCTOU races.
    static func ensureSecureStagingDirectory(at url: URL) throws {
        guard url.isFileURL else {
            throw RecordingError.writerInitializationFailed(
                CCXL10n.text("Invalid staging directory URL.", zh: "暂存目录路径无效。")
            )
        }
        let path = lstatPath(for: url)
        let existingFD = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if existingFD >= 0 {
            defer { Darwin.close(existingFD) }
            try verifyAndSecureDirectoryFD(existingFD)
            return
        }

        let openErr = errno
        if openErr == ELOOP || openErr == ENOTDIR {
            throw RecordingError.writerInitializationFailed(
                CCXL10n.text("Recording staging path is not a directory.", zh: "录屏暂存路径不是目录。")
            )
        }
        guard openErr == ENOENT else {
            throw RecordingError.writerInitializationFailed(
                CCXL10n.text("Could not access the temporary recordings folder.", zh: "无法访问临时录屏文件夹。")
            )
        }

        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw RecordingError.writerInitializationFailed(
                CCXL10n.text(
                    "Could not create recording staging directory: \(error.localizedDescription)",
                    zh: "无法创建录屏暂存目录：\(error.localizedDescription)"
                )
            )
        }

        let createdFD = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard createdFD >= 0 else {
            throw RecordingError.writerInitializationFailed(
                CCXL10n.text("Created recording staging directory failed security verification.", zh: "录屏暂存目录安全校验失败。")
            )
        }
        defer { Darwin.close(createdFD) }
        try verifyAndSecureDirectoryFD(createdFD)
    }

    private static func verifyAndSecureDirectoryFD(_ fd: Int32) throws {
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            throw RecordingError.writerInitializationFailed(
                CCXL10n.text("Recording staging path is not a directory.", zh: "录屏暂存路径不是目录。")
            )
        }
        guard st.st_uid == getuid() else {
            throw RecordingError.writerInitializationFailed(
                CCXL10n.text("Recording staging directory is not owned by the current user.", zh: "录屏暂存目录不属于当前用户。")
            )
        }
        if (st.st_mode & 0o777) != 0o700 {
            guard fchmod(fd, 0o700) == 0 else {
                throw RecordingError.writerInitializationFailed(
                    CCXL10n.text("Could not secure recording staging directory permissions.", zh: "无法设置录屏暂存目录权限。")
                )
            }
        }
    }

    /// Opens the parent directory of `url` and extracts its validated leaf filename, rejecting
    /// symlinks along the leaf path.
    private static func openParentDirectory(for url: URL) throws -> (parentFD: Int32, fileName: String) {
        guard url.isFileURL, !url.path.isEmpty else {
            throw RecordingError.writerInitializationFailed(
                CCXL10n.text("Invalid recording output URL.", zh: "录屏输出路径无效。")
            )
        }
        guard !url.pathComponents.contains("..") else {
            throw RecordingError.writerInitializationFailed(
                CCXL10n.text("Output path must not contain traversal segments.", zh: "输出路径不能包含上级目录跳转。")
            )
        }

        let cleanPath = lstatPath(for: url)
        guard cleanPath != "/" else {
            throw RecordingError.writerInitializationFailed(
                CCXL10n.text("Recording output path is not a regular file.", zh: "录屏输出路径不是常规文件。")
            )
        }
        let cleanURL = URL(fileURLWithPath: cleanPath)
        let fileName = cleanURL.lastPathComponent
        guard !fileName.isEmpty, fileName != ".", fileName != "..", fileName != "/" else {
            throw RecordingError.writerInitializationFailed(
                CCXL10n.text("Recording output path is not a regular file.", zh: "录屏输出路径不是常规文件。")
            )
        }

        let parentPath = lstatPath(for: cleanURL.deletingLastPathComponent())
        let parentFD = Darwin.open(parentPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else {
            throw RecordingError.writerInitializationFailed(
                CCXL10n.text("Could not access the recording output location.", zh: "无法访问录屏输出位置。")
            )
        }
        return (parentFD, fileName)
    }

    /// Validates an output file URL before creating a writer/encoder, rejecting symlinks,
    /// directories, traversal segments, or foreign-owned files, and safely unlinking an existing regular file.
    static func validateOutputURLForWriting(_ url: URL) throws {
        let (parentFD, fileName) = try openParentDirectory(for: url)
        defer { Darwin.close(parentFD) }

        var st = stat()
        if fstatat(parentFD, fileName, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            let fileType = st.st_mode & S_IFMT
            if fileType == S_IFLNK {
                throw RecordingError.writerInitializationFailed(
                    CCXL10n.text("Refusing to write recording to a symbolic link.", zh: "无法将录屏写入符号链接。")
                )
            }
            guard fileType == S_IFREG else {
                throw RecordingError.writerInitializationFailed(
                    CCXL10n.text("Recording output path is not a regular file.", zh: "录屏输出路径不是常规文件。")
                )
            }
            guard st.st_uid == getuid() else {
                throw RecordingError.writerInitializationFailed(
                    CCXL10n.text("Recording output file is not owned by the current user.", zh: "录屏输出文件不属于当前用户。")
                )
            }
            // `unlinkat(..., 0)` refuses to delete directories and never follows leaf symlinks.
            if unlinkat(parentFD, fileName, 0) != 0 && errno != ENOENT {
                let reason = String(cString: strerror(errno))
                throw RecordingError.writerInitializationFailed(
                    CCXL10n.text(
                        "Could not replace existing output file: \(reason)",
                        zh: "无法覆盖现有输出文件：\(reason)"
                    )
                )
            }
        } else if errno != ENOENT {
            throw RecordingError.writerInitializationFailed(
                CCXL10n.text("Could not access the recording output location.", zh: "无法访问录屏输出位置。")
            )
        }
    }

    /// Atomically creates an empty `0600` regular file at `url` without following symlinks
    /// (used by encoders like ImageIO that overwrite an existing path on finalize).
    static func createRestrictedEmptyFile(at url: URL) throws {
        let (parentFD, fileName) = try openParentDirectory(for: url)
        defer { Darwin.close(parentFD) }

        let fd = openat(parentFD, fileName, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let reason = String(cString: strerror(errno))
            throw RecordingError.writerInitializationFailed(
                CCXL10n.text(
                    "Could not create recording output file: \(reason)",
                    zh: "无法创建录屏输出文件：\(reason)"
                )
            )
        }
        defer { Darwin.close(fd) }
        _ = fchmod(fd, 0o600)
    }

    /// Atomically creates a private `0600` read/write spool file at `url` (replacing any stale
    /// regular file at that path) and returns the open descriptor.
    static func createRestrictedSpoolFile(at url: URL) throws -> Int32 {
        try validateOutputURLForWriting(url)
        let (parentFD, fileName) = try openParentDirectory(for: url)
        defer { Darwin.close(parentFD) }

        let fd = openat(parentFD, fileName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let reason = String(cString: strerror(errno))
            throw RecordingError.writerInitializationFailed(
                CCXL10n.text(
                    "Could not create recording spool file: \(reason)",
                    zh: "无法创建录屏缓存文件：\(reason)"
                )
            )
        }
        _ = fchmod(fd, 0o600)
        return fd
    }

    /// Re-validates `url` immediately before encoder finalization so a symlink or foreign file
    /// planted during a long recording session cannot be written through.
    static func verifyOutputURLForFinalize(_ url: URL) throws {
        let (parentFD, fileName) = try openParentDirectory(for: url)
        defer { Darwin.close(parentFD) }

        var st = stat()
        if fstatat(parentFD, fileName, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            let fileType = st.st_mode & S_IFMT
            if fileType == S_IFLNK {
                throw RecordingError.writerInitializationFailed(
                    CCXL10n.text("Refusing to write recording to a symbolic link.", zh: "无法将录屏写入符号链接。")
                )
            }
            guard fileType == S_IFREG else {
                throw RecordingError.writerInitializationFailed(
                    CCXL10n.text("Recording output path is not a regular file.", zh: "录屏输出路径不是常规文件。")
                )
            }
            guard st.st_uid == getuid() else {
                throw RecordingError.writerInitializationFailed(
                    CCXL10n.text("Recording output file is not owned by the current user.", zh: "录屏输出文件不属于当前用户。")
                )
            }
            guard st.st_nlink == 1 else {
                throw RecordingError.writerInitializationFailed(
                    CCXL10n.text("Refusing to write recording to a hard-linked file.", zh: "无法将录屏写入硬链接文件。")
                )
            }
        } else if errno != ENOENT {
            throw RecordingError.writerInitializationFailed(
                CCXL10n.text("Could not access the recording output location.", zh: "无法访问录屏输出位置。")
            )
        }
    }

    /// Tightens permissions on a regular output file to `0600` (owner read/write only),
    /// using `open(..., O_NOFOLLOW | O_NONBLOCK)` + `fstat`/`fchmod` to prevent symlink TOCTOU.
    static func restrictFilePermissions(at url: URL) {
        guard url.isFileURL else { return }
        let path = lstatPath(for: url)
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              st.st_nlink == 1
        else {
            return
        }
        _ = fchmod(fd, 0o600)
    }

    /// Removes `url` only if it is an existing user-owned regular file (never follows leaf symlinks
    /// or recursively removes directories).
    static func removeRegularFileIfPresent(at url: URL) {
        guard let (parentFD, fileName) = try? openParentDirectory(for: url) else { return }
        defer { Darwin.close(parentFD) }

        var st = stat()
        guard fstatat(parentFD, fileName, &st, AT_SYMLINK_NOFOLLOW) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid()
        else {
            return
        }
        _ = unlinkat(parentFD, fileName, 0)
    }

    /// Safely removes stale `CCX-Rec-*` regular files in `dir`, using fd-anchored `fdopendir` +
    /// `fstatat(AT_SYMLINK_NOFOLLOW)` + `unlinkat` and inode-matched active-file protection
    /// (immune to `/var` vs `/private/var` path aliasing and symlink swap TOCTOU).
    static func cleanupStagingDirectory(
        at dir: URL,
        olderThan maxAgeSeconds: TimeInterval,
        activeFileURLs: Set<URL> = []
    ) {
        guard dir.isFileURL else { return }
        let safeAge: TimeInterval = maxAgeSeconds.isFinite ? max(0, maxAgeSeconds) : 3600

        let dirFD = Darwin.open(lstatPath(for: dir), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dirFD >= 0 else { return }

        var dirStat = stat()
        guard fstat(dirFD, &dirStat) == 0,
              (dirStat.st_mode & S_IFMT) == S_IFDIR,
              dirStat.st_uid == getuid()
        else {
            Darwin.close(dirFD)
            return
        }

        // Resolve active files belonging to this exact directory inode to prevent `/var` vs `/private/var` mismatches.
        let resolvedDirPath = dir.resolvingSymlinksInPath().standardizedFileURL.path
        var activeNames: Set<String> = []
        activeNames.reserveCapacity(activeFileURLs.count)
        for activeURL in activeFileURLs where activeURL.isFileURL {
            let cleanActive = URL(fileURLWithPath: lstatPath(for: activeURL))
            let parentPath = lstatPath(for: cleanActive.deletingLastPathComponent())
            var parentStat = stat()
            if stat(parentPath, &parentStat) == 0 {
                if parentStat.st_dev == dirStat.st_dev && parentStat.st_ino == dirStat.st_ino {
                    activeNames.insert(cleanActive.lastPathComponent)
                }
            } else if cleanActive.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == resolvedDirPath {
                activeNames.insert(cleanActive.lastPathComponent)
            }
        }

        guard let dirStream = fdopendir(dirFD) else {
            Darwin.close(dirFD)
            return
        }
        defer { closedir(dirStream) }

        let cutoffEpoch = Date().timeIntervalSince1970 - safeAge
        while let entryPtr = readdir(dirStream) {
            let name: String = withUnsafeBytes(of: &entryPtr.pointee.d_name) { raw in
                let bound = raw.bindMemory(to: CChar.self)
                guard let base = bound.baseAddress else { return "" }
                return String(cString: base)
            }
            let activeLookupName: String
            if name.hasPrefix(stagedFilePrefix) {
                activeLookupName = name
            } else if name.hasPrefix(".\(stagedFilePrefix)"), name.hasSuffix(".spool") {
                activeLookupName = String(name.dropFirst().dropLast(".spool".count))
            } else {
                continue
            }
            guard !activeNames.contains(activeLookupName) else { continue }

            var itemStat = stat()
            guard fstatat(dirFD, name, &itemStat, AT_SYMLINK_NOFOLLOW) == 0,
                  (itemStat.st_mode & S_IFMT) == S_IFREG,
                  itemStat.st_uid == getuid()
            else {
                continue
            }

            if safeAge == 0 {
                _ = unlinkat(dirFD, name, 0)
            } else {
                let birth = TimeInterval(itemStat.st_birthtimespec.tv_sec)
                    + TimeInterval(itemStat.st_birthtimespec.tv_nsec) / 1_000_000_000
                let mtime = TimeInterval(itemStat.st_mtimespec.tv_sec)
                    + TimeInterval(itemStat.st_mtimespec.tv_nsec) / 1_000_000_000
                let effectiveTimestamp = birth > 0 ? max(birth, mtime) : mtime
                if effectiveTimestamp < cutoffEpoch {
                    _ = unlinkat(dirFD, name, 0)
                }
            }
        }
    }
}
