import DICOMImporterCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Quelle") {
                    Label("CD / Ordner", systemImage: "opticaldiscdrive")
                        .tag(SidebarItem.importer)
                    Label("QR-Code / Portal", systemImage: "qrcode.viewfinder")
                        .tag(SidebarItem.qrCode)
                }
                Section("Übertragung") {
                    Label("Warteschlange", systemImage: "tray.and.arrow.up")
                        .badge(model.pendingJobCount)
                        .tag(SidebarItem.queue)
                }
                Section("Archiv") {
                    Label("Archiv aufräumen", systemImage: "wand.and.stars")
                        .tag(SidebarItem.cleanup)
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
            .safeAreaInset(edge: .bottom) {
                DestinationStatusView()
                    .padding(12)
            }
        } detail: {
            switch model.selection ?? .importer {
            case .importer: ImportView()
            case .qrCode: QRCodeView()
            case .queue: QueueView()
            case .cleanup: CleanupView()
            }
        }
        .alert("Hinweis", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct DestinationStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).font(.callout.weight(.medium))
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if case .notConfigured = model.destinationHealth {
                SettingsLink { Text("Einstellungen …") }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .help(helpText)
    }

    private var color: Color {
        switch model.destinationHealth {
        case .online: return .green
        case .offline: return .red
        case .notConfigured: return .orange
        case .unknown: return .gray
        }
    }

    private var title: String {
        switch model.destinationHealth {
        case .online: return "Archiv verbunden"
        case .offline: return "Archiv nicht erreichbar"
        case .notConfigured: return "Archiv nicht eingerichtet"
        case .unknown: return "Prüfe Archiv …"
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if case .online(let status) = model.destinationHealth, let free = status.freeBytes {
            parts.append("\(Format.bytes(free)) frei")
        }
        if case .offline = model.destinationHealth {
            parts.append("Daten bleiben lokal gesichert und werden automatisch übertragen.")
        }
        if model.pendingJobCount > 0 {
            parts.append("\(model.pendingJobCount) in Warteschlange")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var helpText: String {
        if case .offline(let message) = model.destinationHealth { return message }
        return model.makeDestination()?.displayName ?? ""
    }
}
