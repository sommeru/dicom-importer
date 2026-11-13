import AppKit
import DICOMImporterCore
import Network
import Observation
import OSLog

let appLog = Logger(subsystem: "de.sommeru.DICOMImporter", category: "app")

enum SidebarItem: Hashable {
    case importer
    case qrCode
    case queue
    case cleanup
}

enum DestinationHealth: Equatable {
    case unknown
    case notConfigured
    case online(DestinationStatus)
    case offline(String)
}

/// Editable metadata of one study before import.
struct StudyDraft: Identifiable {
    let study: Study
    var selected = true
    var lastName: String
    var firstName: String
    var birthDate: String
    var studyDate: String
    var modality: String

    var id: String { study.id }

    init(study: Study, capitalizeNames: Bool) {
        self.study = study
        let name = study.patientName
        lastName = capitalizeNames ? ArchiveNaming.capitalizeIfUppercase(name.family) : name.family
        firstName = capitalizeNames ? ArchiveNaming.capitalizeIfUppercase(name.given) : name.given
        birthDate = study.birthDate ?? ""
        studyDate = study.studyDate ?? ""
        modality = study.primaryModality
    }

    var normalizedBirthDate: String? { ArchiveNaming.normalizeDateInput(birthDate) }
    var normalizedStudyDate: String? { ArchiveNaming.normalizeDateInput(studyDate) }

    var validationMessage: String? {
        if lastName.trimmingCharacters(in: .whitespaces).isEmpty { return "Nachname fehlt" }
        if normalizedBirthDate == nil { return "Geburtsdatum ungültig (TT.MM.JJJJ oder JJJJMMTT)" }
        if normalizedStudyDate == nil { return "Untersuchungsdatum ungültig (TT.MM.JJJJ oder JJJJMMTT)" }
        if modality.trimmingCharacters(in: .whitespaces).isEmpty { return "Untersuchungsart fehlt" }
        return nil
    }

    var folderName: String {
        ArchiveNaming.folderName(
            studyDate: normalizedStudyDate ?? studyDate,
            birthDate: normalizedBirthDate ?? birthDate,
            lastName: lastName,
            firstName: firstName,
            modality: modality
        )
    }

    var summary: String {
        let name = [lastName, firstName].filter { !$0.isEmpty }.joined(separator: ", ")
        let what = study.studyDescription.map { "\(modality) – \($0)" } ?? modality
        return "\(name) · \(what) · \(ArchiveNaming.displayDate(normalizedStudyDate ?? studyDate))"
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

@MainActor
@Observable
final class AppModel {
    var selection: SidebarItem? = .importer

    // Source & scan
    private(set) var sourceURL: URL?
    private(set) var sourceVolume: URL?
    private(set) var temporaryContainer: URL?
    private(set) var isScanning = false
    private(set) var isExtracting = false
    private(set) var scanStatus = ""
    private(set) var scanResult: ScanResult?
    var drafts: [StudyDraft] = []
    private(set) var detectedMedia: [URL] = []
    var errorMessage: String?
    var infoMessage: String?

    // Staging into the local outbox
    private(set) var isStaging = false
    private(set) var stagingFraction = 0.0
    private(set) var stagingStatus = ""

    // Transfer queue
    private(set) var jobs: [TransferJob] = []
    private(set) var destinationHealth: DestinationHealth = .unknown

    // Presets from the configuration file(s)
    private(set) var configFiles: [URL] = []
    private(set) var managedSettings: Set<String> = []
    private(set) var configWarnings: [String] = []
    var pendingJobCount: Int { jobs.filter { $0.state != .completed }.count }

    let queue: TransferQueue
    let cleanup = CleanupModel()
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var loopTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private var workspaceObservers: [NSObjectProtocol] = []

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DICOM-Importer", isDirectory: true)
    }

    static var downloadsDirectory: URL { supportDirectory.appendingPathComponent("Downloads", isDirectory: true) }

    init() {
        SettingsKey.registerDefaults()
        queue = TransferQueue(directory: Self.supportDirectory.appendingPathComponent("Outbox", isDirectory: true))
        loadConfigFile()
        // Portal downloads contain patient data and are only kept until they are staged.
        try? FileManager.default.removeItem(at: Self.downloadsDirectory)

        Task {
            await queue.load()
            await queue.setObserver { [weak self] jobs in
                Task { @MainActor in self?.jobs = jobs }
            }
            startQueueLoop()
        }
        observeVolumes()
        refreshDetectedMedia()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.kickQueue() }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    // MARK: - Configuration file

    /// System-wide file first, the user's file overrides it.
    static var configURLs: [URL] {
        [
            URL(fileURLWithPath: "/Library/Application Support/DICOM-Importer/dicom-importer.conf"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dicom-importer"),
        ]
    }

    /// Applies presets from the configuration file(s) to the settings. Settings defined
    /// there are locked in the settings window.
    func loadConfigFile() {
        let (config, loaded) = ImporterConfig.load(from: Self.configURLs)
        let defaults = UserDefaults.standard
        var managed = Set<String>()
        var warnings = config.warnings

        func preset(_ value: Any?, _ key: String) {
            guard let value else { return }
            defaults.set(value, forKey: key)
            managed.insert(key)
        }
        preset(config.archiveType.map { $0 == .webDAV ? DestinationKind.webDAV.rawValue : DestinationKind.folder.rawValue },
               SettingsKey.destinationKind)
        preset(config.webDAVURL, SettingsKey.webDAVURL)
        preset(config.webDAVUser, SettingsKey.webDAVUser)
        preset(config.certificateSHA256.map(CertificateFingerprint.normalize), SettingsKey.webDAVFingerprint)
        preset(config.folderPath, SettingsKey.folderPath)
        preset(config.autoScanMedia, SettingsKey.autoScanMedia)
        preset(config.ejectAfterImport, SettingsKey.ejectAfterImport)
        preset(config.capitalizeNames, SettingsKey.capitalizeNames)

        if let password = config.webDAVPassword {
            let user = defaults.string(forKey: SettingsKey.webDAVUser) ?? ""
            if user.isEmpty {
                warnings.append("Passwort in der Konfiguration ohne Benutzer (user = …) wird ignoriert.")
            } else {
                if Keychain.password(account: user) != password {
                    Keychain.setPassword(password, account: user)
                }
                managed.insert(SettingsKey.webDAVPassword)
            }
            // A plain-text password should only be readable by the owner.
            for url in loaded {
                let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0
                if permissions & 0o077 != 0, (try? String(contentsOf: url, encoding: .utf8))?.contains("password") == true {
                    warnings.append("\(url.path) enthält ein Passwort und ist für andere lesbar – empfohlen: chmod 600 \(url.path)")
                }
            }
        }

        configFiles = loaded
        managedSettings = managed
        configWarnings = warnings
        for url in loaded { appLog.info("Loaded configuration \(url.path, privacy: .public)") }
        for warning in warnings { appLog.warning("Config: \(warning, privacy: .public)") }
    }

    func reloadConfigFile() {
        loadConfigFile()
        kickQueue()
    }

    // MARK: - Opening sources

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "DICOM-Daten auswählen"
        panel.message = "Ordner (z. B. CD), ZIP-Archiv oder einzelne DICOM-Datei auswählen"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    /// Opens a folder, volume, archive or single file.
    func open(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            let isVolume = (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) ?? false
            scan(url, volume: isVolume ? url : nil)
        } else if ArchiveExtractor.isArchive(url) {
            Task { await importArchive(url) }
        } else {
            scan(url.deletingLastPathComponent())
        }
    }

    private func importArchive(_ archive: URL) async {
        let container = Self.downloadsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let content = container.appendingPathComponent("content", isDirectory: true)
        selection = .importer
        isExtracting = true
        defer { isExtracting = false }
        do {
            try await ArchiveExtractor.extract(archive, to: content)
        } catch {
            errorMessage = error.localizedDescription
            try? FileManager.default.removeItem(at: container)
            return
        }
        isExtracting = false
        scan(content, temporaryContainer: container)
    }

    /// Called by the portal browser for each finished download.
    func portalDownloadFinished(_ file: URL, container: URL) async {
        let content = container.appendingPathComponent("content", isDirectory: true)
        let target = content.appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        selection = .importer
        isExtracting = true
        do {
            if ArchiveExtractor.isArchive(file) {
                try await ArchiveExtractor.extract(file, to: target)
                try? FileManager.default.removeItem(at: file)
            } else {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: file, to: target.appendingPathComponent(file.lastPathComponent))
            }
        } catch {
            isExtracting = false
            errorMessage = "Download konnte nicht verarbeitet werden: \(error.localizedDescription)"
            return
        }
        isExtracting = false
        scan(content, temporaryContainer: container)
    }

    func scan(_ url: URL, volume: URL? = nil, temporaryContainer container: URL? = nil) {
        guard !isStaging else { return }
        if let old = temporaryContainer, old != container {
            try? FileManager.default.removeItem(at: old)
        }
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration

        sourceURL = url
        sourceVolume = volume
        temporaryContainer = container
        drafts = []
        scanResult = nil
        isScanning = true
        scanStatus = "Suche DICOM-Dateien …"
        selection = .importer
        let capitalize = UserDefaults.standard.bool(forKey: SettingsKey.capitalizeNames)

        scanTask = Task {
            let flag = CancelFlag()
            do {
                let result = try await withTaskCancellationHandler {
                    try await Task.detached(priority: .userInitiated) {
                        try DICOMScanner.scan(
                            root: url,
                            progress: { progress in
                                Task { @MainActor [weak self] in
                                    guard let self, self.scanGeneration == generation else { return }
                                    self.scanStatus = "\(progress.dicomFiles) DICOM-Dateien gefunden (\(progress.filesVisited) Dateien geprüft)"
                                }
                            },
                            isCancelled: { flag.isSet }
                        )
                    }.value
                } onCancel: {
                    flag.set()
                }
                guard generation == scanGeneration else { return }
                scanResult = result
                drafts = result.studies.map { StudyDraft(study: $0, capitalizeNames: capitalize) }
                if result.studies.isEmpty {
                    errorMessage = "In „\(url.lastPathComponent)“ wurden keine DICOM-Daten gefunden."
                }
                appLog.info("Scan finished: \(result.studies.count) studies, \(result.dicomFileCount) files")
            } catch is CancellationError {
                return
            } catch {
                guard generation == scanGeneration else { return }
                errorMessage = "Fehler beim Einlesen: \(error.localizedDescription)"
            }
            if generation == scanGeneration { isScanning = false }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanGeneration += 1
        isScanning = false
        resetSource(eject: false)
    }

    /// Discards the current source without importing.
    func discard() {
        resetSource(eject: false)
    }

    private func resetSource(eject: Bool) {
        if let container = temporaryContainer {
            try? FileManager.default.removeItem(at: container)
        }
        if eject, let volume = sourceVolume, UserDefaults.standard.bool(forKey: SettingsKey.ejectAfterImport) {
            DispatchQueue.global(qos: .utility).async {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
                } catch {
                    appLog.error("Eject failed: \(error.localizedDescription)")
                }
            }
        }
        temporaryContainer = nil
        sourceURL = nil
        sourceVolume = nil
        scanResult = nil
        drafts = []
    }

    // MARK: - Import (staging)

    func importSelected() {
        guard let result = scanResult, !isStaging else { return }
        let selected = drafts.filter(\.selected)
        guard !selected.isEmpty else { return }
        if let invalid = selected.first(where: { $0.validationMessage != nil }) {
            errorMessage = "Bitte Angaben prüfen: \(invalid.validationMessage ?? "")"
            return
        }

        let root = result.root
        // A DICOMDIR is only valid for the complete medium.
        var dicomdir: StudyFile?
        if result.studies.count == 1, selected.count == 1, let path = result.dicomdirPath {
            let size = (try? root.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            dicomdir = StudyFile(relativePath: path, size: Int64(size))
        }
        let totalBytes = max(1, selected.reduce(Int64(0)) { $0 + $1.study.totalBytes })

        isStaging = true
        stagingFraction = 0
        Task {
            var copied: Int64 = 0
            for draft in selected {
                var files = draft.study.files
                if let dicomdir { files.append(dicomdir) }
                let job = TransferJob(folderName: draft.folderName, summary: draft.summary, files: files)
                await queue.add(job)
                let staging = await queue.stagingDirectory(for: job.id)
                stagingStatus = "Kopiere \(draft.summary) …"
                let base = copied
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try Stager.stage(files: files, from: root, to: staging, progress: { bytes in
                            Task { @MainActor [weak self] in
                                self?.stagingFraction = Double(base + bytes) / Double(totalBytes)
                            }
                        })
                    }.value
                    await queue.markStaged(job.id)
                } catch {
                    await queue.markStagingFailed(job.id, error: error.localizedDescription)
                    errorMessage = "Kopieren fehlgeschlagen: \(error.localizedDescription)"
                    isStaging = false
                    return
                }
                copied += files.reduce(Int64(0)) { $0 + $1.size }
            }
            isStaging = false
            infoMessage = selected.count == 1
                ? "Untersuchung wurde übernommen und wird übertragen."
                : "\(selected.count) Untersuchungen wurden übernommen und werden übertragen."
            resetSource(eject: true)
            selection = .queue
            kickQueue()
        }
    }

    // MARK: - Removable media

    private func observeVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { self?.volumeMounted(url) }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDetectedMedia() }
        })
    }

    func refreshDetectedMedia() {
        Task {
            let media = await Task.detached(priority: .utility) { () -> [URL] in
                let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsRootFileSystemKey]
                let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
                return volumes.filter { url in
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    guard values?.volumeIsLocal == true, values?.volumeIsRootFileSystem != true else { return false }
                    return DICOMScanner.looksLikeDICOMMedium(url)
                }
            }.value
            detectedMedia = media
        }
    }

    private func volumeMounted(_ url: URL?) {
        refreshDetectedMedia()
        guard let url, UserDefaults.standard.bool(forKey: SettingsKey.autoScanMedia),
              !isScanning, !isStaging, drafts.isEmpty, DICOMScanner.looksLikeDICOMMedium(url) else { return }
        appLog.info("DICOM medium mounted: \(url.path)")
        NSApp.activate()
        scan(url, volume: url)
    }

    // MARK: - Transfer queue

    func makeDestination() -> ArchiveDestination? {
        let defaults = UserDefaults.standard
        switch DestinationKind(rawValue: defaults.string(forKey: SettingsKey.destinationKind) ?? "") ?? .webDAV {
        case .webDAV:
            let raw = (defaults.string(forKey: SettingsKey.webDAVURL) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else {
                return nil
            }
            let user = defaults.string(forKey: SettingsKey.webDAVUser) ?? ""
            let fingerprint = defaults.string(forKey: SettingsKey.webDAVFingerprint).flatMap { $0.isEmpty ? nil : $0 }
            return WebDAVDestination(configuration: WebDAVConfiguration(
                baseURL: url,
                username: user,
                password: Keychain.password(account: user) ?? "",
                pinnedCertificateSHA256: fingerprint
            ))
        case .folder:
            guard let path = defaults.string(forKey: SettingsKey.folderPath), !path.isEmpty else { return nil }
            return LocalFolderDestination(root: URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    func kickQueue() {
        Task { await processQueue() }
    }

    func processQueue() async {
        guard let destination = makeDestination() else {
            destinationHealth = .notConfigured
            return
        }
        do {
            let status = try await destination.status()
            destinationHealth = .online(status)
        } catch {
            destinationHealth = .offline(Self.describe(error))
            return
        }
        await queue.processPending(destination: destination)
        if let status = try? await destination.status() {
            destinationHealth = .online(status)
        }
    }

    /// Used by the settings window.
    func testDestination() async -> Result<DestinationStatus, Error> {
        guard let destination = makeDestination() else {
            return .failure(DestinationError.notReachable("Kein Ziel konfiguriert"))
        }
        do {
            let status = try await destination.status()
            destinationHealth = .online(status)
            kickQueue()
            return .success(status)
        } catch {
            destinationHealth = .offline(Self.describe(error))
            return .failure(error)
        }
    }

    private func startQueueLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.processQueue()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func retry(_ job: TransferJob) {
        Task {
            await queue.retry(job.id)
            await processQueue()
        }
    }

    func retryAll() {
        Task {
            await queue.retry()
            await processQueue()
        }
    }

    func remove(_ job: TransferJob) {
        Task { await queue.remove(job.id) }
    }

    func removeCompleted() {
        Task { await queue.removeCompleted() }
    }

    func revealStaging(_ job: TransferJob) {
        Task {
            let url = await queue.stagingDirectory(for: job.id)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
