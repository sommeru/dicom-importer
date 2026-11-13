import Foundation

/// Presets from an INI-style configuration file, e.g. `~/.dicom-importer`:
///
/// ```ini
/// [archive]
/// type = webdav                      ; webdav | folder
/// url = https://192.168.2.40:5001/Dicom
/// user = team
/// password = geheim                  ; optional, wird in den Schlüsselbund übernommen
/// certificate_sha256 = AB:CD:…       ; optional, selbstsigniertes Zertifikat
/// folder = /Volumes/Dicom            ; nur bei type = folder
///
/// [general]
/// auto_scan = true
/// eject = true
/// capitalize_names = false
/// ```
///
/// The `[settings] destination_path` key of the old Python version is understood as well.
public struct ImporterConfig: Equatable, Sendable {
    public enum ArchiveType: String, Sendable { case webDAV = "webdav", folder }

    public var archiveType: ArchiveType?
    public var webDAVURL: String?
    public var webDAVUser: String?
    public var webDAVPassword: String?
    public var certificateSHA256: String?
    public var folderPath: String?
    public var autoScanMedia: Bool?
    public var ejectAfterImport: Bool?
    public var capitalizeNames: Bool?
    /// Problems found while parsing (unknown keys, invalid values) for logging/UI.
    public var warnings: [String] = []

    public init() {}

    public var isEmpty: Bool {
        archiveType == nil && webDAVURL == nil && webDAVUser == nil && webDAVPassword == nil && certificateSHA256 == nil
            && folderPath == nil && autoScanMedia == nil && ejectAfterImport == nil && capitalizeNames == nil
    }

    /// Values of `other` win over values of `self`.
    public func merged(with other: ImporterConfig) -> ImporterConfig {
        var result = self
        result.archiveType = other.archiveType ?? archiveType
        result.webDAVURL = other.webDAVURL ?? webDAVURL
        result.webDAVUser = other.webDAVUser ?? webDAVUser
        result.webDAVPassword = other.webDAVPassword ?? webDAVPassword
        result.certificateSHA256 = other.certificateSHA256 ?? certificateSHA256
        result.folderPath = other.folderPath ?? folderPath
        result.autoScanMedia = other.autoScanMedia ?? autoScanMedia
        result.ejectAfterImport = other.ejectAfterImport ?? ejectAfterImport
        result.capitalizeNames = other.capitalizeNames ?? capitalizeNames
        result.warnings = warnings + other.warnings
        return result
    }

    // MARK: - Parsing

    public static func parse(_ text: String, source: String = "config") -> ImporterConfig {
        var config = ImporterConfig()
        var section = ""
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            guard let equals = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else {
                config.warnings.append("\(source):\(index + 1): Zeile ohne '=' ignoriert")
                continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = cleanValue(String(line[line.index(after: equals)...]))
            config.apply(section: section, key: key, value: value, location: "\(source):\(index + 1)")
        }
        return config
    }

    public static func load(from url: URL) throws -> ImporterConfig {
        let text = try String(contentsOf: url, encoding: .utf8)
        return parse(text, source: url.lastPathComponent)
    }

    /// Loads and merges all existing files; later files override earlier ones.
    public static func load(from urls: [URL]) -> (config: ImporterConfig, loaded: [URL]) {
        var result = ImporterConfig()
        var loaded: [URL] = []
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            do {
                result = result.merged(with: try load(from: url))
                loaded.append(url)
            } catch {
                result.warnings.append("\(url.path): \(error.localizedDescription)")
            }
        }
        return (result, loaded)
    }

    private static func cleanValue(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        // Inline comments (" ;" or " #") – not inside quoted values.
        if !(value.hasPrefix("\"") || value.hasPrefix("'")) {
            for marker in [" ;", " #"] {
                if let range = value.range(of: marker) { value = String(value[..<range.lowerBound]) }
            }
            value = value.trimmingCharacters(in: .whitespaces)
        }
        if value.count >= 2, let first = value.first, let last = value.last, first == last, first == "\"" || first == "'" {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func bool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "1", "true", "yes", "ja", "on": return true
        case "0", "false", "no", "nein", "off": return false
        default: return nil
        }
    }

    private mutating func apply(section: String, key: String, value: String, location: String) {
        func setBool(_ keyPath: WritableKeyPath<ImporterConfig, Bool?>) {
            if let b = Self.bool(value) { self[keyPath: keyPath] = b } else { warnings.append("\(location): '\(value)' ist kein Ja/Nein-Wert") }
        }
        let optionalValue: String? = value.isEmpty ? nil : value
        switch (section, key) {
        case ("archive", "type"):
            if let type = ArchiveType(rawValue: value.lowercased()) { archiveType = type }
            else { warnings.append("\(location): unbekannter Archivtyp '\(value)' (webdav oder folder)") }
        case ("archive", "url"): webDAVURL = optionalValue
        case ("archive", "user"), ("archive", "username"): webDAVUser = optionalValue
        case ("archive", "password"): webDAVPassword = optionalValue
        case ("archive", "certificate_sha256"), ("archive", "fingerprint"):
            // Accept the raw openssl output "sha256 Fingerprint=AA:BB:…" as well.
            let fingerprint = optionalValue.map { $0.components(separatedBy: "=").last ?? $0 }
            if let fingerprint, CertificateFingerprint.normalize(fingerprint).filter(\.isHexDigit).count != 64 {
                warnings.append("\(location): SHA-256-Fingerabdruck muss 32 Bytes (64 Hex-Zeichen) haben – unvollständig kopiert?")
            } else {
                certificateSHA256 = fingerprint
            }
        case ("archive", "folder"), ("archive", "path"): folderPath = optionalValue.map(Self.expandTilde)
        case ("general", "auto_scan"): setBool(\.autoScanMedia)
        case ("general", "eject"): setBool(\.ejectAfterImport)
        case ("general", "capitalize_names"): setBool(\.capitalizeNames)
        // Legacy Python version
        case ("settings", "destination_path"):
            if let path = optionalValue {
                folderPath = Self.expandTilde(path)
                if archiveType == nil { archiveType = .folder }
            }
        case ("settings", "smb_mount_point"), ("settings", "smb_share"), ("settings", "smb_user"), ("settings", "smb_password"):
            break // no longer used: the app does not mount shares anymore
        default:
            warnings.append("\(location): unbekannter Schlüssel '\(key)' in [\(section)]")
        }
    }

    private static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
