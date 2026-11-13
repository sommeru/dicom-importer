import DICOMImporterCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            DestinationSettingsView()
                .tabItem { Label("Archiv", systemImage: "externaldrive.connected.to.line.below") }
            GeneralSettingsView()
                .tabItem { Label("Allgemein", systemImage: "gearshape") }
        }
        .frame(width: 580)
    }
}

private struct DestinationSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.destinationKind) private var kind = DestinationKind.webDAV
    @AppStorage(SettingsKey.webDAVURL) private var webDAVURL = ""
    @AppStorage(SettingsKey.webDAVUser) private var webDAVUser = ""
    @AppStorage(SettingsKey.webDAVFingerprint) private var fingerprint = ""
    @AppStorage(SettingsKey.folderPath) private var folderPath = ""

    @State private var password = ""
    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var testSucceeded = false
    @State private var untrustedFingerprint: String?

    var body: some View {
        Form {
            ConfigFileSection()

            Picker("Ziel", selection: $kind) {
                ForEach(DestinationKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .disabled(isManaged(SettingsKey.destinationKind))

            switch kind {
            case .webDAV:
                Section {
                    TextField("Adresse", text: $webDAVURL, prompt: Text("https://nas.local:5006/DICOM"))
                        .disabled(isManaged(SettingsKey.webDAVURL))
                    TextField("Benutzer", text: $webDAVUser)
                        .disabled(isManaged(SettingsKey.webDAVUser))
                    SecureField("Passwort", text: $password)
                        .disabled(isManaged(SettingsKey.webDAVPassword))
                    if !fingerprint.isEmpty {
                        LabeledContent("Vertrautes Zertifikat") {
                            HStack {
                                Text(String(fingerprint.prefix(23)) + "…").font(.caption.monospaced())
                                Button("Vergessen") { fingerprint = "" }
                                    .controlSize(.small)
                                    .disabled(isManaged(SettingsKey.webDAVFingerprint))
                            }
                        }
                    }
                } footer: {
                    Text("Synology: Paket „WebDAV Server“ installieren, HTTPS-Port ist standardmäßig 5006. Der Ordner muss bereits existieren und für den Benutzer beschreibbar sein. Das Passwort wird im macOS-Schlüsselbund gespeichert.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .folder:
                Section {
                    LabeledContent("Ordner") {
                        HStack {
                            Text(folderPath.isEmpty ? "Nicht gewählt" : folderPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(folderPath.isEmpty ? .secondary : .primary)
                            Button("Wählen …") { chooseFolder() }
                                .disabled(isManaged(SettingsKey.folderPath))
                        }
                    }
                } footer: {
                    Text("Für SMB-Freigaben: im Finder mit ⌘K verbinden und in den Systemeinstellungen als Anmeldeobjekt hinterlegen. Ist die Freigabe nicht verbunden, bleiben die Daten in der Warteschlange und werden später übertragen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Button("Verbindung testen") { test() }
                        .disabled(isTesting)
                    if isTesting { ProgressView().controlSize(.small) }
                    if let testMessage {
                        Label(testMessage, systemImage: testSucceeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(testSucceeded ? .green : .red)
                            .lineLimit(3)
                    }
                }
                if let untrustedFingerprint {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Selbstsigniertes Zertifikat. Fingerabdruck (SHA-256) mit dem Zertifikat des NAS vergleichen:")
                            .font(.caption)
                        Text(untrustedFingerprint)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button("Diesem Zertifikat vertrauen") {
                            fingerprint = untrustedFingerprint
                            self.untrustedFingerprint = nil
                            test()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { password = Keychain.password(account: webDAVUser) ?? "" }
        .onChange(of: webDAVUser) { password = Keychain.password(account: webDAVUser) ?? "" }
        .onChange(of: password) { Keychain.setPassword(password, account: webDAVUser) }
    }

    private func isManaged(_ key: String) -> Bool { model.managedSettings.contains(key) }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Als Ziel verwenden"
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
        }
    }

    private func test() {
        isTesting = true
        testMessage = nil
        Task {
            let result = await model.testDestination()
            isTesting = false
            switch result {
            case .success(let status):
                testSucceeded = true
                untrustedFingerprint = nil
                testMessage = status.freeBytes.map { "Verbunden – \(Format.bytes($0)) frei" } ?? "Verbunden"
            case .failure(let error):
                testSucceeded = false
                if case WebDAVError.untrustedCertificate(_, let fp)? = error as? WebDAVError {
                    untrustedFingerprint = fp
                }
                testMessage = AppModel.describe(error)
            }
        }
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.autoScanMedia) private var autoScan = true
    @AppStorage(SettingsKey.ejectAfterImport) private var eject = true
    @AppStorage(SettingsKey.capitalizeNames) private var capitalize = false

    var body: some View {
        Form {
            ConfigFileSection()
            Toggle("Eingelegte DICOM-CDs automatisch einlesen", isOn: $autoScan)
                .disabled(model.managedSettings.contains(SettingsKey.autoScanMedia))
            Toggle("CD nach dem Sichern automatisch auswerfen", isOn: $eject)
                .disabled(model.managedSettings.contains(SettingsKey.ejectAfterImport))
            Toggle("Namen in GROSSBUCHSTABEN umwandeln (MUSTERMANN → Mustermann)", isOn: $capitalize)
                .disabled(model.managedSettings.contains(SettingsKey.capitalizeNames))
            LabeledContent("Lokaler Zwischenspeicher") {
                Button("Im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppModel.supportDirectory])
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Shows which configuration file presets the settings, plus parse warnings.
private struct ConfigFileSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.configFiles.isEmpty || !model.configWarnings.isEmpty {
            Section {
                ForEach(model.configFiles, id: \.self) { url in
                    Label {
                        Text("Voreinstellungen aus \(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                    } icon: {
                        Image(systemName: "lock.doc")
                    }
                }
                if !model.configFiles.isEmpty {
                    Text("Gesperrte Felder werden durch die Datei vorgegeben und können nur dort geändert werden.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.configWarnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("Neu laden") { model.reloadConfigFile() }
                    if let url = model.configFiles.last {
                        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
            }
        }
    }
}
