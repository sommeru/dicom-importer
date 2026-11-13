import Foundation

enum SettingsKey {
    static let destinationKind = "destinationKind"
    static let webDAVURL = "webDAVURL"
    static let webDAVUser = "webDAVUser"
    static let webDAVFingerprint = "webDAVFingerprint"
    static let folderPath = "folderPath"
    static let autoScanMedia = "autoScanMedia"
    static let ejectAfterImport = "ejectAfterImport"
    static let capitalizeNames = "capitalizeNames"
    /// Pseudo key (the password lives in the keychain); used to mark it as managed by the config file.
    static let webDAVPassword = "webDAVPassword"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            destinationKind: DestinationKind.webDAV.rawValue,
            autoScanMedia: true,
            ejectAfterImport: true,
            capitalizeNames: false,
        ])
    }
}

enum DestinationKind: String, CaseIterable, Identifiable {
    case webDAV = "webdav"
    case folder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .webDAV: return "WebDAV (empfohlen)"
        case .folder: return "Ordner / gemountete Freigabe"
        }
    }
}

/// Keeps long-running work at full speed while the app is in the background
/// (no App Nap throttling) and prevents idle system sleep until it is finished.
enum BackgroundActivity {
    static func begin(_ reason: String) -> NSObjectProtocol {
        ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
    }

    static func end(_ token: NSObjectProtocol) {
        ProcessInfo.processInfo.endActivity(token)
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
