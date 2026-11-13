import Foundation

/// Extracts portal downloads (ZIP, ISO, TAR, 7z …) with the system's bsdtar (libarchive).
enum ArchiveExtractor {
    enum ExtractionError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let message):
                return "Archiv konnte nicht entpackt werden. \(message)".trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private static let archiveExtensions: Set<String> = ["zip", "iso", "tar", "tgz", "gz", "bz2", "xz", "7z", "rar", "cpio"]

    static func isArchive(_ url: URL) -> Bool {
        if archiveExtensions.contains(url.pathExtension.lowercased()) { return true }
        // ZIP without extension (some portals send "download" without suffix).
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 4)) ?? Data()
        return magic == Data([0x50, 0x4B, 0x03, 0x04])
    }

    static func extract(_ archive: URL, to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
            process.arguments = ["-xf", archive.path, "-C", directory.path]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw ExtractionError.failed(String(decoding: errorData, as: UTF8.self))
            }
        }.value
    }
}
