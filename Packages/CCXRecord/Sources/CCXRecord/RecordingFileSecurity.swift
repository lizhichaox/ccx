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
    static func ensureSecureStagingDirectory(at url: URL) throws {
        guard url.isFileURL else {
            throw RecordingError.writerInitializationFailed(
                CCXL10n.text("Invalid staging directory URL.", zh: "暂存目录路径无效。")
            )
        }
        let fm = FileManager.default
        let path = lstatPath(for: url)
        var st = stat()
        if lstat(path, &st) == 0 {
            let fileType = st.st_mode & S_IFMT
            guard fileType == S_IFDIR else {
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
                guard chmod(path, 0o700) == 0 else {
                    throw RecordingError.writerInitializationFailed(
                        CCXL10n.text("Could not secure recording staging directory permissions.", zh: "无法设置录屏暂存目录权限。")
                    )
                }
            }
            return
        }

        guard errno == ENOENT else {
            throw RecordingError.writerInitializationFailed(
                CCXL10n.text("Could not access the temporary recordings folder.", zh: "无法访问临时录屏文件夹。")
            )
        }

        do {
            try fm.createDirectory(
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

        guard lstat(path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == getuid()
        else {
            throw RecordingError.writerInitializationFailed(
                CCXL10n.text("Created recording staging directory failed security verification.", zh: "录屏暂存目录安全校验失败。")
            )
        }
        _ = chmod(path, 0o700)
    }

    /// Validates an output file URL before creating a writer/encoder, rejecting symlinks,
    /// directories, traversal segments, or foreign-owned files, and safely removing an existing regular file.
    static func validateOutputURLForWriting(_ url: URL) throws {
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

        let path = lstatPath(for: url)
        var st = stat()
        if lstat(path, &st) == 0 {
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
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw RecordingError.writerInitializationFailed(
                    CCXL10n.text(
                        "Could not replace existing output file: \(error.localizedDescription)",
                        zh: "无法覆盖现有输出文件：\(error.localizedDescription)"
                    )
                )
            }
        } else if errno != ENOENT {
            throw RecordingError.writerInitializationFailed(
                CCXL10n.text("Could not access the recording output location.", zh: "无法访问录屏输出位置。")
            )
        }
    }

    /// Tightens permissions on a regular output file to `0600` (owner read/write only),
    /// refusing to follow symlinks.
    static func restrictFilePermissions(at url: URL) {
        guard url.isFileURL else { return }
        let path = lstatPath(for: url)
        var st = stat()
        guard lstat(path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid()
        else {
            return
        }
        _ = chmod(path, 0o600)
    }

    /// Removes `url` only if it is an existing user-owned regular file (never follows symlinks or removes dirs).
    static func removeRegularFileIfPresent(at url: URL) {
        guard url.isFileURL else { return }
        let path = lstatPath(for: url)
        var st = stat()
        guard lstat(path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid()
        else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// Safely removes stale `CCX-Rec-*` regular files in `dir`, rejecting symlinked directories,
    /// symlinked children, foreign-owned entries, and currently active recording files.
    static func cleanupStagingDirectory(
        at dir: URL,
        olderThan maxAgeSeconds: TimeInterval,
        activeFileURLs: Set<URL> = []
    ) {
        guard dir.isFileURL else { return }
        let safeAge: TimeInterval = maxAgeSeconds.isFinite ? max(0, maxAgeSeconds) : 3600

        var dirStat = stat()
        guard lstat(lstatPath(for: dir), &dirStat) == 0,
              (dirStat.st_mode & S_IFMT) == S_IFDIR,
              dirStat.st_uid == getuid()
        else {
            return
        }

        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let activePaths = Set(activeFileURLs.map { $0.standardizedFileURL.path })
        let cutoff = Date().addingTimeInterval(-safeAge)
        for url in urls {
            guard url.lastPathComponent.hasPrefix(stagedFilePrefix) else { continue }
            guard !activePaths.contains(url.standardizedFileURL.path) else { continue }

            var itemStat = stat()
            guard lstat(lstatPath(for: url), &itemStat) == 0,
                  (itemStat.st_mode & S_IFMT) == S_IFREG,
                  itemStat.st_uid == getuid()
            else {
                continue
            }

            if safeAge == 0 {
                try? fm.removeItem(at: url)
            } else if let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                      created < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}
