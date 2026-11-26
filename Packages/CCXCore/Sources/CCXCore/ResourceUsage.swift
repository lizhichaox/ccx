import Darwin
import Darwin.Mach
import Foundation

/// Structured entry in Settings' expandable Resource Usage guide.
public struct ResourceUsageGuideItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case idle
        case memory
        case capture
        case storage
    }

    public let kind: Kind
    public let symbol: String
    public let title: String
    public let badge: String
    public let detail: String

    public var id: Kind { kind }

    public init(kind: Kind, symbol: String, title: String, badge: String, detail: String) {
        self.kind = kind
        self.symbol = symbol
        self.title = title
        self.badge = badge
        self.detail = detail
    }
}

/// Live snapshot of CCX's process memory, retained history/pins, and local disk cache,
/// paired with localized single-line explanations for the Settings window.
public struct ResourceUsageSnapshot: Equatable, Sendable {
    public let physicalMemoryBytes: UInt64?
    public let historyCount: Int
    public let maxHistoryCount: Int
    public let activePinCount: Int
    public let diskCacheBytes: UInt64

    public init(
        physicalMemoryBytes: UInt64? = nil,
        historyCount: Int = 0,
        maxHistoryCount: Int = 20,
        activePinCount: Int = 0,
        diskCacheBytes: UInt64 = 0
    ) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.historyCount = max(0, historyCount)
        self.maxHistoryCount = max(0, maxHistoryCount)
        self.activePinCount = max(0, activePinCount)
        self.diskCacheBytes = diskCacheBytes
    }

    /// Compact memory footprint matching macOS Activity Monitor's binary units (e.g. `42 MB`).
    public var formattedMemory: String {
        guard let physicalMemoryBytes else { return "—" }
        return Self.formatMemoryBytes(physicalMemoryBytes)
    }

    /// Compact disk cache size using decimal macOS Finder units (e.g. `2.4 MB`, `0 KB`).
    public var formattedDiskCache: String {
        Self.formatDiskBytes(diskCacheBytes)
    }

    public static var headerTitle: String {
        CCXL10n.text("Resource Usage", zh: "资源占用")
    }

    public static var headerSubtitle: String {
        CCXL10n.text("~0% idle CPU · Bounded cache", zh: "待机近 0% CPU · 缓存有上限")
    }

    public static func headerTooltip(isExpanded: Bool) -> String {
        if isExpanded {
            return CCXL10n.text("Hide resource usage details", zh: "收起资源占用说明")
        }
        return CCXL10n.text("Show resource usage details", zh: "展开资源占用说明")
    }

    public func guideItems(automaticallyChecksForUpdates: Bool) -> [ResourceUsageGuideItem] {
        let memoryBadge = CCXL10n.text(
            "\(historyCount)/\(maxHistoryCount) snips · \(activePinCount) \(activePinCount == 1 ? "pin" : "pins")",
            zh: "历史 \(historyCount)/\(maxHistoryCount) · 贴图 \(activePinCount)"
        )
        let cacheBadge = CCXL10n.text("\(formattedDiskCache) cache", zh: "缓存 \(formattedDiskCache)")
        let storageDetail = automaticallyChecksForUpdates
            ? CCXL10n.text(
                "Private local cache; update checks run once daily.",
                zh: "私有本地缓存可随时清空；更新检查每日仅一次。"
            )
            : CCXL10n.text(
                "Private local cache; zero background network traffic.",
                zh: "私有本地缓存可随时清空；当前无后台网络请求。"
            )

        return [
            ResourceUsageGuideItem(
                kind: .idle,
                symbol: "bolt.fill",
                title: CCXL10n.text("Idle & Background", zh: "后台待机"),
                badge: CCXL10n.text("~0% CPU", zh: "近 0% CPU"),
                detail: CCXL10n.text(
                    "No background capture or polling; runs on demand.",
                    zh: "无后台录屏与轮询，仅在截屏、贴图或录屏时运行。"
                )
            ),
            ResourceUsageGuideItem(
                kind: .memory,
                symbol: "memorychip",
                title: CCXL10n.text("Memory & Pins", zh: "内存与贴图"),
                badge: memoryBadge,
                detail: CCXL10n.text(
                    "History caps at 20 snips (160 MB); pins free on close.",
                    zh: "历史上限 20 张 / 160 MB；关闭贴图或清空即释放。"
                )
            ),
            ResourceUsageGuideItem(
                kind: .capture,
                symbol: "video.fill",
                title: CCXL10n.text("Capture & Record", zh: "截屏与录屏"),
                badge: CCXL10n.text("Hardware GPU", zh: "硬件加速"),
                detail: CCXL10n.text(
                    "Metal & VideoToolbox encode; buffers free on finish.",
                    zh: "Metal 与 VideoToolbox 硬件编码，结束后即释放缓存。"
                )
            ),
            ResourceUsageGuideItem(
                kind: .storage,
                symbol: "internaldrive.fill",
                title: CCXL10n.text("Cache & Network", zh: "缓存与网络"),
                badge: cacheBadge,
                detail: storageDetail
            ),
        ]
    }

    // MARK: - Formatting

    /// Formats RAM bytes in binary units (`KB` / `MB` / `GB`, base 1024) matching Activity Monitor.
    public static func formatMemoryBytes(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "0 KB" }
        let kib = 1_024.0
        let mib = 1_048_576.0
        let gib = 1_073_741_824.0
        let value = Double(bytes)

        if value < mib {
            let kb = max(1, Int((value / kib).rounded()))
            if kb >= 1_024 {
                return "1 MB"
            }
            return "\(kb) KB"
        }

        let mb = value / mib
        if mb < 1_023.5 {
            return "\(max(1, Int(mb.rounded()))) MB"
        }

        let gb = value / gib
        return String(format: "%.1f GB", gb)
    }

    /// Formats disk bytes in decimal units (`KB` / `MB` / `GB`, base 1000) matching macOS Finder.
    public static func formatDiskBytes(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "0 KB" }
        if bytes < 1_000 {
            return "< 1 KB"
        }

        let kb = Double(bytes) / 1_000.0
        if kb < 999.5 {
            return "\(max(1, Int(kb.rounded()))) KB"
        }

        let mb = Double(bytes) / 1_000_000.0
        if mb < 9.95 {
            return String(format: "%.1f MB", mb)
        }
        if mb < 999.5 {
            return "\(Int(mb.rounded())) MB"
        }

        let gb = Double(bytes) / 1_000_000_000.0
        return String(format: "%.1f GB", gb)
    }
}

/// Lightweight, symlink-safe process memory and local cache size sampler.
public enum AppResourceMonitor {
    private struct DirectoryIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private static let minPhysFootprintCount: mach_msg_type_number_t = {
        let offset = MemoryLayout<task_vm_info_data_t>.offset(of: \.phys_footprint) ?? MemoryLayout<task_vm_info_data_t>.stride
        let requiredBytes = offset + MemoryLayout<mach_vm_size_t>.size
        let stride = MemoryLayout<integer_t>.stride
        return mach_msg_type_number_t((requiredBytes + stride - 1) / stride)
    }()

    /// Returns the current process's physical memory footprint (`task_vm_info.phys_footprint`),
    /// matching the Memory column in macOS Activity Monitor.
    public static func currentPhysicalMemoryBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS, count >= minPhysFootprintCount else { return nil }
        return UInt64(info.phys_footprint)
    }

    /// Returns the total byte size of regular, user-owned files directly inside `directoryURL`
    /// without following symbolic links. Returns `0` when the directory does not exist or is invalid.
    public static func regularFilesByteSize(in directoryURL: URL) -> UInt64 {
        var seenDirectories: Set<DirectoryIdentity> = []
        return regularFilesByteSize(in: directoryURL, seenDirectories: &seenDirectories)
    }

    /// Sums `regularFilesByteSize(in:)` across multiple cache directories with overflow saturation
    /// and `(st_dev, st_ino)` deduplication so duplicate or aliased directories are never double-counted.
    public static func totalRegularFilesByteSize(in directories: [URL]) -> UInt64 {
        var seenDirectories: Set<DirectoryIdentity> = []
        seenDirectories.reserveCapacity(directories.count)
        var total: UInt64 = 0
        for url in directories {
            let (next, overflow) = total.addingReportingOverflow(
                regularFilesByteSize(in: url, seenDirectories: &seenDirectories)
            )
            total = overflow ? UInt64.max : next
        }
        return total
    }

    private static func regularFilesByteSize(
        in directoryURL: URL,
        seenDirectories: inout Set<DirectoryIdentity>
    ) -> UInt64 {
        guard directoryURL.isFileURL else { return 0 }
        let dirPath = normalizedPath(directoryURL.path)
        guard !dirPath.isEmpty else { return 0 }

        let dirFD = Darwin.open(dirPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dirFD >= 0 else { return 0 }

        let uid = Darwin.getuid()
        var dirStat = stat()
        guard Darwin.fstat(dirFD, &dirStat) == 0,
              (dirStat.st_mode & S_IFMT) == S_IFDIR,
              dirStat.st_uid == uid
        else {
            _ = Darwin.close(dirFD)
            return 0
        }

        let identity = DirectoryIdentity(device: dirStat.st_dev, inode: dirStat.st_ino)
        guard seenDirectories.insert(identity).inserted else {
            _ = Darwin.close(dirFD)
            return 0
        }

        guard let dirStream = Darwin.fdopendir(dirFD) else {
            _ = Darwin.close(dirFD)
            return 0
        }
        defer { _ = Darwin.closedir(dirStream) }

        let streamFD = Darwin.dirfd(dirStream)
        var total: UInt64 = 0
        while let entryPtr = Darwin.readdir(dirStream) {
            let entrySize: UInt64 = withUnsafePointer(to: &entryPtr.pointee.d_name) { nameTuplePtr in
                let namePtr = UnsafeRawPointer(nameTuplePtr).assumingMemoryBound(to: CChar.self)
                // Skip "." and ".." without allocating Swift strings.
                if namePtr[0] == 46 && (namePtr[1] == 0 || (namePtr[1] == 46 && namePtr[2] == 0)) {
                    return 0
                }
                var st = stat()
                guard Darwin.fstatat(streamFD, namePtr, &st, AT_SYMLINK_NOFOLLOW) == 0,
                      (st.st_mode & S_IFMT) == S_IFREG,
                      st.st_uid == uid,
                      st.st_size > 0
                else {
                    return 0
                }
                return UInt64(st.st_size)
            }
            if entrySize > 0 {
                let (next, overflow) = total.addingReportingOverflow(entrySize)
                total = overflow ? UInt64.max : next
            }
        }
        return total
    }

    private static func normalizedPath(_ path: String) -> String {
        var normalized = path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
