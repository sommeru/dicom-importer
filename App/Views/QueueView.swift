import DICOMImporterCore
import SwiftUI

struct QueueView: View {
    @Environment(AppModel.self) private var model
    @State private var jobToRemove: TransferJob?

    var body: some View {
        Group {
            if model.jobs.isEmpty {
                ContentUnavailableView(
                    "Keine Übertragungen",
                    systemImage: "tray",
                    description: Text("Importierte Untersuchungen werden lokal gesichert und von hier ins Archiv übertragen.")
                )
            } else {
                List {
                    if let info = model.infoMessage {
                        Label(info, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    ForEach(Array(model.jobs.reversed())) { job in
                        JobRow(job: job)
                            .contextMenu {
                                if job.state == .failed { Button("Erneut versuchen") { model.retry(job) } }
                                if job.state != .completed { Button("Zwischenspeicher im Finder zeigen") { model.revealStaging(job) } }
                                Divider()
                                Button("Entfernen …", role: .destructive) { jobToRemove = job }
                                    .disabled(job.state == .uploading)
                            }
                    }
                }
            }
        }
        .navigationTitle("Warteschlange")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.retryAll()
                } label: {
                    Label("Jetzt übertragen", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Ausstehende und fehlgeschlagene Übertragungen sofort starten")
                Button {
                    model.removeCompleted()
                } label: {
                    Label("Erledigte entfernen", systemImage: "checkmark.circle.badge.xmark")
                }
                .disabled(!model.jobs.contains { $0.state == .completed })
            }
        }
        .onDisappear { model.infoMessage = nil }
        .confirmationDialog(
            "Übertragung entfernen?",
            isPresented: Binding(get: { jobToRemove != nil }, set: { if !$0 { jobToRemove = nil } }),
            presenting: jobToRemove
        ) { job in
            Button("Entfernen", role: .destructive) { model.remove(job) }
        } message: { job in
            if job.state == .completed {
                Text("Der Eintrag wird aus der Liste entfernt. Die Daten im Archiv bleiben erhalten.")
            } else {
                Text("Die Untersuchung wurde noch NICHT vollständig übertragen. Die lokal gesicherten Daten werden gelöscht.")
            }
        }
    }
}

private struct JobRow: View {
    let job: TransferJob

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.summary).font(.headline)
                Text(job.finalFolderName ?? job.folderName)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if job.state != .completed {
                    ProgressView(value: job.progress)
                }
                HStack {
                    Text(statusText)
                    Spacer()
                    Text("\(Format.bytes(job.uploadedBytes)) / \(Format.bytes(job.totalBytes))")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let error = job.lastError, job.state == .failed {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var icon: String {
        switch job.state {
        case .staging: return "externaldrive.badge.plus"
        case .waiting: return "clock"
        case .uploading: return "arrow.up.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch job.state {
        case .completed: return .green
        case .failed: return .orange
        case .uploading: return .accentColor
        default: return .secondary
        }
    }

    private var statusText: String {
        switch job.state {
        case .staging: return "Wird lokal gesichert …"
        case .waiting: return "Wartet auf Archiv"
        case .uploading: return "Wird übertragen …"
        case .completed:
            let date = job.completedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
            return "Archiviert \(date)"
        case .failed:
            if let next = job.nextAttemptAt, next != .distantFuture {
                return "Nächster Versuch \(next.formatted(date: .omitted, time: .shortened)) (Versuch \(job.attempts))"
            }
            return "Fehlgeschlagen"
        }
    }
}
