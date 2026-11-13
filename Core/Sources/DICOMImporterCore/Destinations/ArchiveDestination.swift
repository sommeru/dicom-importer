import Foundation

public struct DestinationStatus: Sendable, Equatable {
    public var freeBytes: Int64?
    public var totalBytes: Int64?

    public init(freeBytes: Int64? = nil, totalBytes: Int64? = nil) {
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
    }
}

public enum DestinationError: LocalizedError, Equatable {
    case notReachable(String)
    case notWritable(String)
    case alreadyExists(String)
    case insufficientSpace(needed: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .notReachable(let what): return "Ziel nicht erreichbar: \(what)"
        case .notWritable(let what): return "Ziel nicht beschreibbar: \(what)"
        case .alreadyExists(let what): return "Existiert bereits: \(what)"
        case .insufficientSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "Zu wenig Speicherplatz am Ziel (benötigt \(f.string(fromByteCount: needed)), frei \(f.string(fromByteCount: available)))"
        }
    }
}

/// Where imported studies end up. Paths are `/`-separated and relative to the destination root.
public protocol ArchiveDestination: Sendable {
    var displayName: String { get }
    /// Checks reachability (and authentication) and reports free space if known.
    func status() async throws -> DestinationStatus
    func exists(_ path: String) async throws -> Bool
    /// Creates a directory; succeeds if it already exists.
    func createDirectory(_ path: String) async throws
    /// Uploads a file, replacing an existing file at `path`.
    func upload(fileAt localURL: URL, to path: String) async throws
    /// Renames/moves an item; fails with `DestinationError.alreadyExists` if the target exists.
    func move(_ source: String, to destination: String) async throws
    func remove(_ path: String) async throws
}

/// A local or already mounted folder (e.g. an SMB share mounted by Finder).
public struct LocalFolderDestination: ArchiveDestination {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var displayName: String { root.path }

    private func url(_ path: String) -> URL {
        path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    public func status() async throws -> DestinationStatus {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            let hint = root.path.hasPrefix("/Volumes/") ? " (Netzlaufwerk nicht verbunden?)" : ""
            throw DestinationError.notReachable(root.path + hint)
        }
        guard FileManager.default.isWritableFile(atPath: root.path) else {
            throw DestinationError.notWritable(root.path)
        }
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        return DestinationStatus(
            freeBytes: values?.volumeAvailableCapacity.map(Int64.init),
            totalBytes: values?.volumeTotalCapacity.map(Int64.init)
        )
    }

    public func exists(_ path: String) async throws -> Bool {
        FileManager.default.fileExists(atPath: url(path).path)
    }

    public func createDirectory(_ path: String) async throws {
        try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true)
    }

    public func upload(fileAt localURL: URL, to path: String) async throws {
        let target = url(path)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: localURL, to: target)
    }

    public func move(_ source: String, to destination: String) async throws {
        let target = url(destination)
        if FileManager.default.fileExists(atPath: target.path) { throw DestinationError.alreadyExists(destination) }
        try FileManager.default.moveItem(at: url(source), to: target)
    }

    public func remove(_ path: String) async throws {
        let target = url(path)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }
}
