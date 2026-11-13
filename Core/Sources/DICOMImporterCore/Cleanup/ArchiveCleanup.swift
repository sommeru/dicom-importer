import Foundation

// MARK: - Model

public enum CleanupKind: String, Sendable, CaseIterable, Comparable {
    case deleteEmpty
    case deleteIncompleteUpload
    case deleteNoDICOM
    case deleteDuplicate
    case mergeDuplicate
    case split
    case rename

    public var title: String {
        switch self {
        case .deleteEmpty: return "Leere Ordner löschen"
        case .deleteIncompleteUpload: return "Abgebrochene Übertragungen löschen"
        case .deleteNoDICOM: return "Ordner ohne DICOM-Daten löschen"
        case .deleteDuplicate: return "Doppelte Untersuchungen löschen"
        case .mergeDuplicate: return "Doppelte Untersuchungen zusammenführen"
        case .split: return "Gemischte Ordner aufteilen"
        case .rename: return "Falsch benannte Ordner umbenennen"
        }
    }

    public var isDeletion: Bool {
        switch self {
        case .deleteEmpty, .deleteIncompleteUpload, .deleteNoDICOM, .deleteDuplicate: return true
        default: return false
        }
    }

    /// Execution order: deletions first, renames last (they may depend on freed names).
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public static func < (lhs: CleanupKind, rhs: CleanupKind) -> Bool { lhs.order < rhs.order }
}

/// Files of one study that are moved out of a mixed folder into a new folder.
public struct SplitGroup: Sendable, Hashable {
    public var targetName: String
    public var files: [String]
    public var summary: String
}

public struct CleanupAction: Identifiable, Sendable, Hashable {
    public let id: UUID
    public var kind: CleanupKind
    /// Folder (directly below the archive root) the action applies to.
    public var folder: String
    /// Rename target; for duplicates the folder that is kept; for splits the new name of the remaining folder.
    public var targetName: String?
    public var detail: String
    /// Pre-selected in the list.
    public var recommended: Bool
    public var splitGroups: [SplitGroup]

    public init(kind: CleanupKind, folder: String, targetName: String? = nil, detail: String,
                recommended: Bool, splitGroups: [SplitGroup] = []) {
        self.id = UUID()
        self.kind = kind
        self.folder = folder
        self.targetName = targetName
        self.detail = detail
        self.recommended = recommended
        self.splitGroups = splitGroups
    }
}

/// One study found inside an archive folder.
public struct StudySummary: Sendable, Hashable {
    public var uid: String?
    public var patientName: PersonName
    public var birthDate: String?
    public var studyDate: String?
    public var modalities: [String]
    public var studyDescription: String?
    /// Paths relative to the folder.
    public var files: [String]
    public var bytes: Int64

    var label: String {
        let name = [patientName.family, patientName.given].filter { !$0.isEmpty }.joined(separator: ", ")
        let mods = modalities.joined(separator: "+")
        return "\(name.isEmpty ? "Unbekannt" : name), \(mods.isEmpty ? "?" : mods), \(ArchiveNaming.displayDate(studyDate)) – \(files.count) Dateien"
    }
}

public struct FolderReport: Sendable {
    public var name: String
    /// Files that are not system junk (.DS_Store, ._*, Thumbs.db …).
    public var fileCount: Int
    public var totalBytes: Int64
    public var studies: [StudySummary]

    public init(name: String, fileCount: Int, totalBytes: Int64, studies: [StudySummary]) {
        self.name = name
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.studies = studies
    }
}

public struct CleanupPlan: Sendable {
    public var folderCount: Int
    public var actions: [CleanupAction]
    /// Folders that could not be analysed.
    public var errors: [String]
}

public struct CleanupProgress: Sendable {
    public var done: Int
    public var total: Int
    public var current: String

    public init(done: Int, total: Int, current: String) {
        self.done = done
        self.total = total
        self.current = current
    }
}

public struct CleanupResult: Sendable, Identifiable {
    public var id: UUID { action.id }
    public var action: CleanupAction
    public var message: String
    public var failed: Bool
}

// MARK: - Analysis

/// Scans the archive (WebDAV or folder) and proposes clean-up actions.
///
/// To keep this fast over the network only the first 64 KB of a few files per
/// directory are read. Folders where the sample reveals more than one study are
/// read completely so every file can be assigned to its study.
public final class ArchiveAnalyzer: @unchecked Sendable {
    let destination: ArchiveDestination
    let protectedNames: Set<String>
    let capitalizeNames: Bool
    let concurrency: Int
    static let headerBytes = 64 * 1024
    static let junkFiles: Set<String> = [".ds_store", "thumbs.db", "desktop.ini", ".localized"]

    public init(destination: ArchiveDestination, protectedNames: Set<String> = [], capitalizeNames: Bool = false, concurrency: Int = 6) {
        self.destination = destination
        self.protectedNames = protectedNames
        self.capitalizeNames = capitalizeNames
        self.concurrency = max(1, concurrency)
    }

    /// NAS system folders and our own hidden folders are never touched.
    public static func isSystemFolder(_ name: String) -> Bool {
        if let first = name.first, ".@#$_~".contains(first) { return true }
        return ["lost+found", "Network Trash Folder", "Temporary Items", "System Volume Information"].contains(name)
    }

    static func isJunk(_ name: String) -> Bool {
        name.hasPrefix("._") || junkFiles.contains(name.lowercased())
    }

    public func analyze(progress: (@Sendable (CleanupProgress) -> Void)? = nil) async throws -> CleanupPlan {
        let root = try await destination.list("")
        let folders = root.filter { $0.isDirectory && !Self.isSystemFolder($0.name) }.map(\.name).sorted()
        var reports: [FolderReport] = []
        var errors: [String] = []
        var done = 0
        progress?(CleanupProgress(done: 0, total: folders.count, current: ""))

        try await withThrowingTaskGroup(of: (String, FolderReport?, String?).self) { group in
            var iterator = folders.makeIterator()
            var inFlight = 0
            while true {
                while inFlight < concurrency, let name = iterator.next() {
                    group.addTask { [self] in
                        do {
                            return (name, try await analyzeFolder(name), nil)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            return (name, nil, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                        }
                    }
                    inFlight += 1
                }
                guard let result = try await group.next() else { break }
                let (name, report, error) = result
                inFlight -= 1
                done += 1
                if let report { reports.append(report) }
                if let error { errors.append("\(name): \(error)") }
                progress?(CleanupProgress(done: done, total: folders.count, current: name))
                try Task.checkCancellation()
            }
        }

        reports.sort { $0.name < $1.name }
        let actions = Self.makePlan(reports, protectedNames: protectedNames, capitalizeNames: capitalizeNames)
        return CleanupPlan(folderCount: folders.count, actions: actions, errors: errors)
    }

    func analyzeFolder(_ folder: String) async throws -> FolderReport {
        // 1. List all files recursively.
        var files: [(path: String, size: Int64)] = []
        var pending = [""]
        while let dir = pending.popLast() {
            try Task.checkCancellation()
            let items = try await destination.list(dir.isEmpty ? folder : "\(folder)/\(dir)")
            for item in items {
                let path = dir.isEmpty ? item.name : "\(dir)/\(item.name)"
                if item.isDirectory {
                    pending.append(path)
                } else if !Self.isJunk(item.name) {
                    files.append((path, item.size))
                }
            }
        }
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        let candidates = files.filter { file in
            let ext = (file.path as NSString).pathExtension.lowercased()
            return file.size >= 8 && !DICOMScanner.skippedExtensions.contains(ext)
        }.sorted { $0.path < $1.path }

        // 2. Sample first/middle/last file of every directory.
        var headers: [String: DICOMHeader] = [:]
        func read(_ path: String) async throws {
            try Task.checkCancellation()
            guard let data = try? await destination.readPrefix("\(folder)/\(path)", maxBytes: Self.headerBytes),
                  let header = try? DICOMParser.parseHeader(data: data), !header.isDICOMDIR,
                  header.studyInstanceUID != nil || header.patientName != nil || header.modality != nil else { return }
            headers[path] = header
        }
        let byDirectory = Dictionary(grouping: candidates) { ($0.path as NSString).deletingLastPathComponent }
        for (_, dirFiles) in byDirectory.sorted(by: { $0.key < $1.key }) {
            let indices = Set([0, dirFiles.count / 2, dirFiles.count - 1])
            for index in indices.sorted() { try await read(dirFiles[index].path) }
        }

        // 3. More than one study in the sample: read every file.
        var keys = Set(headers.values.map(Self.studyKey))
        if keys.count > 1 {
            for file in candidates where headers[file.path] == nil { try await read(file.path) }
            keys = Set(headers.values.map(Self.studyKey))
        }

        // 4. Assign files to studies.
        var assignment: [String: [(path: String, size: Int64)]] = [:]
        if keys.count == 1, let key = keys.first {
            // Single study: every DICOM candidate belongs to it (only a sample was read).
            assignment[key] = candidates.filter { file in
                // Exclude files that were read and turned out not to be DICOM.
                headers[file.path] != nil || !sampledNonDICOM(file.path, in: byDirectory, headers: headers)
            }
        } else {
            for file in candidates {
                if let header = headers[file.path] { assignment[Self.studyKey(header), default: []].append(file) }
            }
        }

        var studies: [StudySummary] = []
        for (key, studyFiles) in assignment {
            let studyHeaders = headers.filter { Self.studyKey($0.value) == key }.sorted { $0.key < $1.key }.map { $0.value }
            guard var merged = studyHeaders.first else { continue }
            var seriesByModality: [String: Set<String>] = [:]
            for header in studyHeaders {
                merged.merge(missingFrom: header)
                if let modality = header.modality, !modality.isEmpty {
                    seriesByModality[modality, default: []].insert(header.seriesInstanceUID ?? modality)
                }
            }
            studies.append(StudySummary(
                uid: merged.studyInstanceUID,
                patientName: merged.patientName ?? PersonName(family: "", given: ""),
                birthDate: merged.patientBirthDate,
                studyDate: merged.studyDate,
                modalities: DICOMScanner.orderedModalities(seriesByModality),
                studyDescription: merged.studyDescription,
                files: studyFiles.map(\.path),
                bytes: studyFiles.reduce(Int64(0)) { $0 + $1.size }
            ))
        }
        studies.sort { $0.files.count > $1.files.count }
        return FolderReport(name: folder, fileCount: files.count, totalBytes: totalBytes, studies: studies)
    }

    /// True if the file was in the sample but is not DICOM (e.g. a viewer binary without extension).
    private func sampledNonDICOM(_ path: String, in byDirectory: [String: [(path: String, size: Int64)]], headers: [String: DICOMHeader]) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        guard let dirFiles = byDirectory[dir] else { return false }
        let sampled = Set([0, dirFiles.count / 2, dirFiles.count - 1].map { dirFiles[$0].path })
        // A directory whose sampled files are all non-DICOM is treated as non-DICOM.
        return sampled.allSatisfy { headers[$0] == nil }
    }

    static func studyKey(_ header: DICOMHeader) -> String {
        header.studyInstanceUID
            ?? "nouid:\(header.patientName?.family ?? "")|\(header.patientBirthDate ?? "")|\(header.studyDate ?? "")"
    }

    // MARK: - Planning

    static func expectedName(_ study: StudySummary, capitalizeNames: Bool) -> String {
        let family = capitalizeNames ? ArchiveNaming.capitalizeIfUppercase(study.patientName.family) : study.patientName.family
        let given = capitalizeNames ? ArchiveNaming.capitalizeIfUppercase(study.patientName.given) : study.patientName.given
        return ArchiveNaming.folderName(
            studyDate: study.studyDate ?? "",
            birthDate: study.birthDate ?? "",
            lastName: family,
            firstName: given,
            modality: study.modalities.joined(separator: "+")
        )
    }

    /// nil: name is fine. true/false: rename proposed, pre-selected or not.
    static func renameRecommendation(current: String, expected: String) -> Bool? {
        if ArchiveNaming.equivalent(current, expected) { return nil }
        let expectedParts = ArchiveNaming.parseFolderName(expected)
        let incompleteData = expectedParts.map { $0.studyDate == "NA" || $0.birthDate == "NA" || $0.modality == "NA" } ?? true
        guard let currentParts = ArchiveNaming.parseFolderName(current) else {
            // Does not follow the scheme at all.
            return !incompleteData
        }
        if incompleteData { return false }
        guard let expectedParts else { return false }
        if currentParts.studyDate != expectedParts.studyDate || currentParts.birthDate != expectedParts.birthDate
            || currentParts.modality.uppercased() != expectedParts.modality.uppercased() {
            return true
        }
        // Only the patient name differs: possibly a deliberate manual correction.
        return false
    }

    public static func makePlan(_ reports: [FolderReport], protectedNames: Set<String> = [], capitalizeNames: Bool = false) -> [CleanupAction] {
        var actions: [CleanupAction] = []
        var handled = Set<String>()
        let size = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

        // Empty, incomplete and non-DICOM folders
        for report in reports {
            if report.name.range(of: #"\.upload-[0-9a-f]{8}$"#, options: .regularExpression) != nil {
                handled.insert(report.name)
                if protectedNames.contains(report.name) { continue } // upload still in progress
                actions.append(CleanupAction(kind: .deleteIncompleteUpload, folder: report.name,
                                             detail: "Unvollständige Übertragung, \(report.fileCount) Dateien (\(size(report.totalBytes)))",
                                             recommended: true))
            } else if report.fileCount == 0 {
                handled.insert(report.name)
                actions.append(CleanupAction(kind: .deleteEmpty, folder: report.name, detail: "Enthält keine Dateien", recommended: true))
            } else if report.studies.isEmpty {
                handled.insert(report.name)
                actions.append(CleanupAction(kind: .deleteNoDICOM, folder: report.name,
                                             detail: "\(report.fileCount) Dateien (\(size(report.totalBytes))), keine DICOM-Daten erkannt",
                                             recommended: false))
            }
        }

        // Duplicates: same Study Instance UID in several single-study folders
        let singleStudy = reports.filter { !handled.contains($0.name) && $0.studies.count == 1 && $0.studies[0].uid != nil }
        let byUID = Dictionary(grouping: singleStudy) { $0.studies[0].uid! }
        for (_, group) in byUID.sorted(by: { $0.key < $1.key }) where group.count > 1 {
            let keeper = group.max { lhs, rhs in
                let lhsOK = ArchiveNaming.equivalent(lhs.name, expectedName(lhs.studies[0], capitalizeNames: capitalizeNames))
                let rhsOK = ArchiveNaming.equivalent(rhs.name, expectedName(rhs.studies[0], capitalizeNames: capitalizeNames))
                if lhsOK != rhsOK { return rhsOK }
                if lhs.studies[0].files.count != rhs.studies[0].files.count { return lhs.studies[0].files.count < rhs.studies[0].files.count }
                return lhs.name.count > rhs.name.count
            }!
            for duplicate in group where duplicate.name != keeper.name {
                handled.insert(duplicate.name)
                let a = duplicate.studies[0], b = keeper.studies[0]
                if a.files.count == b.files.count && a.bytes == b.bytes {
                    actions.append(CleanupAction(kind: .deleteDuplicate, folder: duplicate.name, targetName: keeper.name,
                                                 detail: "Identisch mit „\(keeper.name)“ (\(a.files.count) Dateien, \(size(a.bytes)))",
                                                 recommended: true))
                } else {
                    actions.append(CleanupAction(kind: .mergeDuplicate, folder: duplicate.name, targetName: keeper.name,
                                                 detail: "Gleiche Untersuchung wie „\(keeper.name)“, aber anderer Inhalt (\(a.files.count) statt \(b.files.count) Dateien). Wird als Unterordner dorthin verschoben.",
                                                 recommended: false))
                }
            }
        }

        // Mixed folders
        for report in reports where !handled.contains(report.name) && report.studies.count > 1 {
            handled.insert(report.name)
            let stay = report.studies[0]
            let stayName = expectedName(stay, capitalizeNames: capitalizeNames)
            let groups = report.studies.dropFirst().map {
                SplitGroup(targetName: expectedName($0, capitalizeNames: capitalizeNames), files: $0.files, summary: $0.label)
            }
            let detail = "\(report.studies.count) Untersuchungen in einem Ordner. Bleibt: \(stay.label)"
            actions.append(CleanupAction(kind: .split, folder: report.name,
                                         targetName: ArchiveNaming.equivalent(report.name, stayName) ? nil : stayName,
                                         detail: detail, recommended: true, splitGroups: groups))
        }

        // Wrong names
        for report in reports where !handled.contains(report.name) && report.studies.count == 1 {
            let expected = expectedName(report.studies[0], capitalizeNames: capitalizeNames)
            guard let recommended = renameRecommendation(current: report.name, expected: expected) else { continue }
            actions.append(CleanupAction(kind: .rename, folder: report.name, targetName: expected,
                                         detail: report.studies[0].label, recommended: recommended))
        }

        return actions.sorted { ($0.kind, $0.folder) < ($1.kind, $1.folder) }
    }
}

// MARK: - Execution

public final class CleanupExecutor: @unchecked Sendable {
    let destination: ArchiveDestination

    public init(destination: ArchiveDestination) {
        self.destination = destination
    }

    public func perform(_ actions: [CleanupAction], progress: (@Sendable (CleanupProgress) -> Void)? = nil) async -> [CleanupResult] {
        let ordered = actions.sorted { ($0.kind, $0.folder) < ($1.kind, $1.folder) }
        var reserved = Set<String>()
        var results: [CleanupResult] = []
        for (index, action) in ordered.enumerated() {
            if Task.isCancelled { break }
            progress?(CleanupProgress(done: index, total: ordered.count, current: action.folder))
            do {
                let message = try await run(action, reserved: &reserved)
                results.append(CleanupResult(action: action, message: message, failed: false))
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                results.append(CleanupResult(action: action, message: text, failed: true))
            }
        }
        progress?(CleanupProgress(done: ordered.count, total: ordered.count, current: ""))
        return results
    }

    private func run(_ action: CleanupAction, reserved: inout Set<String>) async throws -> String {
        let folder = action.folder
        switch action.kind {
        case .deleteEmpty:
            guard !(try await containsFiles(folder)) else { throw CleanupError.changed("„\(folder)“ ist nicht mehr leer") }
            try await destination.removeDirectory(folder)
            return "Gelöscht"

        case .deleteIncompleteUpload, .deleteNoDICOM:
            try await destination.removeDirectory(folder)
            return "Gelöscht"

        case .deleteDuplicate:
            guard let keeper = action.targetName, try await destination.exists(keeper) else {
                throw CleanupError.changed("Vergleichsordner „\(action.targetName ?? "")“ fehlt – nichts gelöscht")
            }
            try await destination.removeDirectory(folder)
            return "Gelöscht (Original: \(keeper))"

        case .mergeDuplicate:
            guard let keeper = action.targetName, try await destination.exists(keeper) else {
                throw CleanupError.changed("Zielordner „\(action.targetName ?? "")“ fehlt")
            }
            var target = "\(keeper)/\(folder)"
            var counter = 2
            while try await destination.exists(target) {
                target = "\(keeper)/\(folder) (\(counter))"
                counter += 1
            }
            try await destination.move(folder, to: target)
            return "Verschoben nach \(target)"

        case .split:
            var created: [String] = []
            for group in action.splitGroups {
                let name = try await uniqueName(group.targetName, reserved: &reserved)
                try await destination.createDirectory(name)
                var directories = Set<String>()
                for file in group.files {
                    var parents: [String] = []
                    var components = file.split(separator: "/").dropLast()
                    while !components.isEmpty {
                        parents.insert(components.joined(separator: "/"), at: 0)
                        components = components.dropLast()
                    }
                    for parent in parents where !directories.contains(parent) {
                        try await destination.createDirectory("\(name)/\(parent)")
                        directories.insert(parent)
                    }
                    try await destination.moveFile("\(folder)/\(file)", to: "\(name)/\(file)")
                }
                created.append(name)
            }
            var message = "Neu: " + created.joined(separator: ", ")
            if let target = action.targetName {
                let name = try await uniqueName(target, reserved: &reserved)
                try await destination.move(folder, to: name)
                message += "; umbenannt in \(name)"
            }
            return message

        case .rename:
            guard let target = action.targetName, target != folder else { return "Unverändert" }
            let name = try await uniqueName(target, reserved: &reserved)
            try await destination.move(folder, to: name)
            return "Umbenannt in \(name)"
        }
    }

    private func uniqueName(_ base: String, reserved: inout Set<String>) async throws -> String {
        var candidate = base
        var counter = 2
        while reserved.contains(candidate) {
            candidate = "\(base) (\(counter))"
            counter += 1
        }
        while try await destination.exists(candidate) || reserved.contains(candidate) {
            candidate = "\(base) (\(counter))"
            counter += 1
        }
        reserved.insert(candidate)
        return candidate
    }

    private func containsFiles(_ path: String) async throws -> Bool {
        for item in try await destination.list(path) {
            if item.isDirectory {
                if try await containsFiles("\(path)/\(item.name)") { return true }
            } else if !ArchiveAnalyzer.isJunk(item.name) {
                return true
            }
        }
        return false
    }
}

public enum CleanupError: LocalizedError {
    case changed(String)

    public var errorDescription: String? {
        switch self {
        case .changed(let message): return "Übersprungen: \(message)"
        }
    }
}
