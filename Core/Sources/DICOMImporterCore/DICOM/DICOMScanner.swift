import Foundation

/// One DICOM file belonging to a study, path relative to the scan root.
public struct StudyFile: Sendable, Hashable, Codable {
    public var relativePath: String
    public var size: Int64

    public init(relativePath: String, size: Int64) {
        self.relativePath = relativePath
        self.size = size
    }
}

/// All files of one study (grouped by Study Instance UID).
public struct Study: Identifiable, Sendable {
    public var id: String
    public var studyInstanceUID: String?
    public var patientName: PersonName
    public var patientID: String?
    public var birthDate: String?
    public var sex: String?
    public var studyDate: String?
    public var studyDescription: String?
    public var institutionName: String?
    public var accessionNumber: String?
    /// Modalities ordered by number of series, image modalities first.
    public var modalities: [String]
    public var seriesCount: Int
    public var files: [StudyFile]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Suggested modality label for the folder name, e.g. `CT` or `PT+CT`.
    public var primaryModality: String {
        modalities.isEmpty ? "NA" : modalities.joined(separator: "+")
    }
}

public struct ScanProgress: Sendable {
    public var filesVisited: Int
    public var dicomFiles: Int
    public var currentPath: String
}

public struct ScanResult: Sendable {
    public var root: URL
    public var studies: [Study]
    /// Relative path of a DICOMDIR, if present.
    public var dicomdirPath: String?
    public var dicomFileCount: Int
    public var skippedFileCount: Int
}

public enum DICOMScanner {
    /// Modalities that never describe the examination itself.
    static let secondaryModalities: Set<String> = ["SR", "PR", "KO", "DOC", "REG", "SEG", "OT", "RWV", "AU", "PLAN", "FID"]

    /// File extensions that are certainly not DICOM (viewer software on CDs etc.).
    static let skippedExtensions: Set<String> = [
        "exe", "dll", "inf", "ini", "htm", "html", "js", "css", "txt", "pdf", "xml", "xsl", "jar", "ico",
        "png", "jpg", "jpeg", "gif", "bmp", "chm", "cab", "msi", "sys", "ocx", "lnk", "ttf", "otf", "zip",
        "json", "plist", "dylib", "app", "bat", "cmd", "sh", "md", "rtf", "doc", "docx", "manifest", "config",
        "mp4", "avi", "mov", "wav", "log", "bin", "dmg", "pkg", "so", "class", "properties", "cfg", "svg",
    ]

    public static func scan(
        root: URL,
        progress: (@Sendable (ScanProgress) -> Void)? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> ScanResult {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isPackageKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        struct Builder {
            var uid: String?
            var header: DICOMHeader
            var files: [StudyFile] = []
            var seriesByModality: [String: Set<String>] = [:]
            var series: Set<String> = []
        }

        var builders: [String: Builder] = [:]
        var order: [String] = []
        var dicomdirPath: String?
        var visited = 0
        var dicomCount = 0
        var skipped = 0
        let rootPaths = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().path]

        for case let url as URL in enumerator {
            if isCancelled() { throw CancellationError() }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isPackage == true { enumerator.skipDescendants(); continue }
            guard values?.isRegularFile == true else { continue }
            visited += 1

            let name = url.lastPathComponent
            if name.hasPrefix("._") || name == ".DS_Store" || skippedExtensions.contains(url.pathExtension.lowercased()) {
                skipped += 1
                continue
            }
            let size = Int64(values?.fileSize ?? 0)
            guard size >= 8 else { skipped += 1; continue }

            guard let header = try? DICOMParser.parseHeader(at: url) else {
                skipped += 1
                continue
            }
            let relativePath = relative(url, toRootPaths: rootPaths)
            if header.isDICOMDIR {
                if dicomdirPath == nil { dicomdirPath = relativePath }
                continue
            }
            dicomCount += 1
            if visited % 25 == 0 {
                progress?(ScanProgress(filesVisited: visited, dicomFiles: dicomCount, currentPath: relativePath))
            }

            let key = header.studyInstanceUID
                ?? "nouid:\(header.patientName?.family ?? "")|\(header.patientBirthDate ?? "")|\(header.studyDate ?? "")"
            if builders[key] == nil {
                builders[key] = Builder(uid: header.studyInstanceUID, header: header)
                order.append(key)
            }
            builders[key]!.files.append(StudyFile(relativePath: relativePath, size: size))
            // Fill in attributes missing in the first file of the study.
            builders[key]!.header.merge(missingFrom: header)
            let seriesKey = header.seriesInstanceUID ?? "noseries:\(header.modality ?? "")"
            builders[key]!.series.insert(seriesKey)
            if let modality = header.modality, !modality.isEmpty {
                builders[key]!.seriesByModality[modality, default: []].insert(seriesKey)
            }
        }
        progress?(ScanProgress(filesVisited: visited, dicomFiles: dicomCount, currentPath: ""))

        let studies: [Study] = order.enumerated().map { index, key in
            let b = builders[key]!
            return Study(
                id: b.uid ?? "study-\(index)",
                studyInstanceUID: b.uid,
                patientName: b.header.patientName ?? PersonName(family: "", given: ""),
                patientID: b.header.patientID,
                birthDate: b.header.patientBirthDate,
                sex: b.header.patientSex,
                studyDate: b.header.studyDate,
                studyDescription: b.header.studyDescription,
                institutionName: b.header.institutionName,
                accessionNumber: b.header.accessionNumber,
                modalities: orderedModalities(b.seriesByModality),
                seriesCount: b.series.count,
                files: b.files.sorted { $0.relativePath < $1.relativePath }
            )
        }
        .sorted { ($0.studyDate ?? "", $0.id) < ($1.studyDate ?? "", $1.id) }

        return ScanResult(root: root, studies: studies, dicomdirPath: dicomdirPath, dicomFileCount: dicomCount, skippedFileCount: skipped)
    }

    static func orderedModalities(_ seriesByModality: [String: Set<String>]) -> [String] {
        let sorted = seriesByModality
            .sorted { lhs, rhs in
                lhs.value.count != rhs.value.count ? lhs.value.count > rhs.value.count : lhs.key < rhs.key
            }
            .map(\.key)
        let primary = sorted.filter { !secondaryModalities.contains($0) }
        return primary.isEmpty ? sorted : primary
    }

    static func relative(_ url: URL, toRootPaths rootPaths: [String]) -> String {
        for path in [url.standardizedFileURL.path, url.resolvingSymlinksInPath().path] {
            for rootPath in rootPaths where path.hasPrefix(rootPath + "/") {
                return String(path.dropFirst(rootPath.count + 1))
            }
        }
        return url.lastPathComponent
    }

    /// Heuristic: does this directory (e.g. a mounted CD) contain DICOM data at its top levels?
    public static func looksLikeDICOMMedium(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: url.path) else { return false }
        for entry in entries {
            let upper = entry.uppercased()
            if upper == "DICOMDIR" || upper == "DICOM" { return true }
        }
        return false
    }
}

extension DICOMHeader {
    mutating func merge(missingFrom other: DICOMHeader) {
        if patientName == nil || patientName?.isEmpty == true { patientName = other.patientName }
        if patientID == nil { patientID = other.patientID }
        if patientBirthDate == nil { patientBirthDate = other.patientBirthDate }
        if patientSex == nil { patientSex = other.patientSex }
        if studyDate == nil { studyDate = other.studyDate }
        if studyDescription == nil { studyDescription = other.studyDescription }
        if institutionName == nil { institutionName = other.institutionName }
        if accessionNumber == nil { accessionNumber = other.accessionNumber }
    }
}
