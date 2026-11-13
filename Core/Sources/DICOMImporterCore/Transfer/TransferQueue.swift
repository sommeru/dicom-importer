import Foundation

public enum TransferState: String, Codable, Sendable {
    /// Files are being copied from the source (CD, download) into the local outbox.
    case staging
    /// Staged locally, waiting for the destination.
    case waiting
    case uploading
    case completed
    /// Last attempt failed; will be retried automatically.
    case failed
}

/// A study that was copied into the local outbox and is transferred to the archive.
public struct TransferJob: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var folderName: String
    public var finalFolderName: String?
    public var summary: String
    public var createdAt: Date
    public var files: [StudyFile]
    public var uploadedFiles: Set<String>
    public var state: TransferState
    public var lastError: String?
    public var attempts: Int
    public var nextAttemptAt: Date?
    public var completedAt: Date?

    public init(id: UUID = UUID(), folderName: String, summary: String, files: [StudyFile]) {
        self.id = id
        self.folderName = folderName
        self.summary = summary
        self.createdAt = Date()
        self.files = files
        self.uploadedFiles = []
        self.state = .staging
        self.attempts = 0
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    public var uploadedBytes: Int64 {
        files.reduce(0) { uploadedFiles.contains($1.relativePath) ? $0 + $1.size : $0 }
    }

    public var progress: Double {
        let total = totalBytes
        return total > 0 ? Double(uploadedBytes) / Double(total) : (state == .completed ? 1 : 0)
    }

    /// Name of the temporary folder at the destination while the upload is incomplete.
    public var partialFolderName: String {
        "\(folderName).upload-\(id.uuidString.prefix(8).lowercased())"
    }
}

/// Persistent outbox: studies are first staged locally (so the CD can be ejected and
/// the NAS may be offline) and then uploaded with automatic retries.
///
/// Uploads go into a temporary folder that is renamed when complete, so the archive
/// never contains half-copied studies.
public actor TransferQueue {
    public let directory: URL
    public private(set) var jobs: [TransferJob] = []
    private var observer: (@Sendable ([TransferJob]) -> Void)?
    private var isProcessing = false
    private var lastSave = Date.distantPast
    public var maxConcurrentUploads = 4

    public init(directory: URL) {
        self.directory = directory
    }

    private var manifestURL: URL { directory.appendingPathComponent("queue.json") }

    public func stagingDirectory(for id: UUID) -> URL {
        directory.appendingPathComponent("staging", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func setObserver(_ observer: @escaping @Sendable ([TransferJob]) -> Void) {
        self.observer = observer
        observer(jobs)
    }

    public func load() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        jobs = (try? decoder.decode([TransferJob].self, from: data)) ?? []
        for index in jobs.indices {
            switch jobs[index].state {
            case .staging:
                jobs[index].state = .failed
                jobs[index].lastError = "Zwischenspeicherung wurde unterbrochen – bitte Untersuchung erneut einlesen."
                jobs[index].nextAttemptAt = .distantFuture
            case .uploading:
                jobs[index].state = .waiting
            default:
                break
            }
        }
        save(force: true)
    }

    // MARK: - Job management

    public func add(_ job: TransferJob) {
        jobs.append(job)
        save(force: true)
    }

    public func markStaged(_ id: UUID) {
        update(id) { $0.state = .waiting; $0.lastError = nil }
        save(force: true)
    }

    public func markStagingFailed(_ id: UUID, error: String) {
        update(id) {
            $0.state = .failed
            $0.lastError = error
            $0.nextAttemptAt = .distantFuture
        }
        save(force: true)
    }

    /// Makes failed jobs eligible for the next processing run.
    public func retry(_ id: UUID? = nil) {
        for index in jobs.indices where id == nil || jobs[index].id == id {
            if jobs[index].state == .failed, jobs[index].nextAttemptAt != .distantFuture {
                jobs[index].nextAttemptAt = nil
            }
        }
        save(force: true)
    }

    /// Removes a job and its staged files.
    public func remove(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.state != .uploading else { return }
        try? FileManager.default.removeItem(at: stagingDirectory(for: id))
        jobs.removeAll { $0.id == id }
        save(force: true)
    }

    public func removeCompleted() {
        jobs.removeAll { $0.state == .completed }
        save(force: true)
    }

    public var pendingCount: Int { jobs.filter { $0.state != .completed }.count }

    // MARK: - Processing

    /// Uploads all due jobs sequentially. Concurrent calls return immediately.
    public func processPending(destination: ArchiveDestination, now: Date = Date()) async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        let due = jobs.filter { job in
            switch job.state {
            case .waiting: return true
            case .failed: return (job.nextAttemptAt ?? .distantPast) <= now
            default: return false
            }
        }.map(\.id)

        for id in due {
            guard let job = jobs.first(where: { $0.id == id }) else { continue }
            do {
                try await upload(job, to: destination)
            } catch {
                update(id) {
                    $0.state = .failed
                    $0.attempts += 1
                    $0.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    // Back-off: 1, 2, 4, … minutes, at most 30 minutes.
                    let delay = min(60 * pow(2, Double(max(0, $0.attempts - 1))), 1800)
                    $0.nextAttemptAt = Date().addingTimeInterval(delay)
                }
                save(force: true)
                if isConnectivityError(error) { break }
            }
        }
    }

    private func upload(_ job: TransferJob, to destination: ArchiveDestination) async throws {
        let id = job.id
        update(id) { $0.state = .uploading; $0.lastError = nil }
        save(force: true)

        let status = try await destination.status()
        let remaining = job.totalBytes - job.uploadedBytes
        if let free = status.freeBytes, free < remaining {
            throw DestinationError.insufficientSpace(needed: remaining, available: free)
        }

        let staging = stagingDirectory(for: id)
        let partial = job.partialFolderName
        try await destination.createDirectory(partial)

        // Create all sub directories, parents first.
        var directories = Set<String>()
        for file in job.files {
            var components = file.relativePath.split(separator: "/").dropLast()
            while !components.isEmpty {
                directories.insert(components.joined(separator: "/"))
                components = components.dropLast()
            }
        }
        for dir in directories.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count || ($0.split(separator: "/").count == $1.split(separator: "/").count && $0 < $1) }) {
            try await destination.createDirectory("\(partial)/\(dir)")
        }

        // Upload files with bounded concurrency; already uploaded files are skipped (resume).
        let pending = job.files.filter { !job.uploadedFiles.contains($0.relativePath) }
        let limit = max(1, maxConcurrentUploads)
        try await withThrowingTaskGroup(of: String.self) { group in
            var iterator = pending.makeIterator()
            var inFlight = 0
            while true {
                while inFlight < limit, let file = iterator.next() {
                    let local = staging.appendingPathComponent(file.relativePath)
                    let remote = "\(partial)/\(file.relativePath)"
                    group.addTask {
                        try await destination.upload(fileAt: local, to: remote)
                        return file.relativePath
                    }
                    inFlight += 1
                }
                guard let done = try await group.next() else { break }
                inFlight -= 1
                update(id) { $0.uploadedFiles.insert(done) }
                save(force: false)
            }
        }

        // Pick a free final name and atomically rename the folder.
        var finalName = job.folderName
        var counter = 2
        while try await destination.exists(finalName) {
            finalName = "\(job.folderName) (\(counter))"
            counter += 1
        }
        try await destination.move(partial, to: finalName)

        update(id) {
            $0.state = .completed
            $0.finalFolderName = finalName
            $0.completedAt = Date()
            $0.lastError = nil
            $0.nextAttemptAt = nil
        }
        save(force: true)
        try? FileManager.default.removeItem(at: staging)
    }

    private func isConnectivityError(_ error: Error) -> Bool {
        if let destinationError = error as? DestinationError, case .notReachable = destinationError { return true }
        if let webDAVError = error as? WebDAVError {
            if case .http = webDAVError { return false }
            return true
        }
        if let urlError = error as? URLError {
            return [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .dnsLookupFailed]
                .contains(urlError.code)
        }
        return false
    }

    // MARK: - Persistence

    private func update(_ id: UUID, _ change: (inout TransferJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    private func save(force: Bool) {
        let now = Date()
        if !force, now.timeIntervalSince(lastSave) < 1 { observer?(jobs); return }
        lastSave = now
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(jobs) {
            try? data.write(to: manifestURL, options: .atomic)
        }
        observer?(jobs)
    }
}

/// Copies the files of a study from the source into the outbox.
public enum Stager {
    public static func stage(
        files: [StudyFile],
        from root: URL,
        to directory: URL,
        progress: (@Sendable (Int64) -> Void)? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var copied: Int64 = 0
        for file in files {
            if isCancelled() { throw CancellationError() }
            let source = root.appendingPathComponent(file.relativePath)
            let target = directory.appendingPathComponent(file.relativePath)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: source, to: target)
            copied += file.size
            progress?(copied)
        }
    }
}
