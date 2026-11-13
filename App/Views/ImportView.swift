import DICOMImporterCore
import SwiftUI

struct ImportView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.isStaging {
                StagingView()
            } else if model.isScanning || model.isExtracting {
                ScanningView()
            } else if !model.drafts.isEmpty {
                StudyReviewView()
            } else {
                EmptyImportView()
            }
        }
        .navigationTitle("CD / Ordner")
    }
}

private struct EmptyImportView: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                Image(systemName: "opticaldisc")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.secondary)
                Text("CD einlegen oder Ordner / ZIP hierher ziehen")
                    .font(.title3.weight(.medium))
                Text("Eingelegte DICOM-CDs werden automatisch erkannt und eingelesen.")
                    .foregroundStyle(.secondary)
                Button("Ordner oder ZIP auswählen …") { model.presentOpenPanel() }
                    .controlSize(.large)
                    .keyboardShortcut("o")
            }
            .frame(maxWidth: .infinity, minHeight: 260)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
            )
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                model.open(url)
                return true
            } isTargeted: { isTargeted = $0 }

            if !model.detectedMedia.isEmpty {
                GroupBox("Erkannte Datenträger") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.detectedMedia, id: \.self) { volume in
                            HStack {
                                Image(systemName: "opticaldisc")
                                Text(volume.lastPathComponent)
                                Spacer()
                                Button("Einlesen") { model.scan(volume, volume: volume) }
                            }
                        }
                    }
                    .padding(4)
                }
            }

            if let info = model.infoMessage {
                Label(info, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .onTapGesture { model.infoMessage = nil }
            }
            Spacer()
        }
        .padding(24)
        .onAppear { model.refreshDetectedMedia() }
    }
}

private struct ScanningView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(model.isExtracting ? "Download wird entpackt …" : "Daten werden eingelesen …")
                .font(.title3)
            Text(model.scanStatus)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let source = model.sourceURL {
                Text(source.path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button("Abbrechen", role: .cancel) { model.cancelScan() }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StagingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            ProgressView(value: model.stagingFraction) {
                Text("Daten werden lokal gesichert …")
            } currentValueLabel: {
                Text(model.stagingStatus).lineLimit(1)
            }
            .frame(maxWidth: 420)
            Text("Danach kann die CD entnommen werden. Die Übertragung ins Archiv erfolgt im Hintergrund.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StudyReviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    if model.drafts.count > 1 {
                        Label("Auf dem Datenträger befinden sich \(model.drafts.count) Untersuchungen. Jede wird in einem eigenen Ordner archiviert.",
                              systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach($model.drafts) { $draft in
                        StudyCard(draft: $draft)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.sourceURL?.path ?? "")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let result = model.scanResult {
                        Text("\(result.dicomFileCount) DICOM-Dateien · \(result.skippedFileCount) sonstige Dateien ignoriert")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Verwerfen") { model.discard() }
                Button(importTitle) { model.importSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedCount == 0)
            }
            .padding(14)
        }
    }

    private var selectedCount: Int { model.drafts.filter(\.selected).count }

    private var importTitle: String {
        let size = model.drafts.filter(\.selected).reduce(Int64(0)) { $0 + $1.study.totalBytes }
        return selectedCount == 1 ? "Importieren (\(Format.bytes(size)))" : "\(selectedCount) importieren (\(Format.bytes(size)))"
    }
}

private struct StudyCard: View {
    @Binding var draft: StudyDraft

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Toggle("", isOn: $draft.selected)
                        .labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.study.studyDescription ?? "Untersuchung")
                            .font(.headline)
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Format.bytes(draft.study.totalBytes))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        field("Nachname", text: $draft.lastName)
                        field("Vorname", text: $draft.firstName)
                    }
                    GridRow {
                        field("Geburtsdatum", text: $draft.birthDate, prompt: "TT.MM.JJJJ", hint: dateHint(draft.normalizedBirthDate))
                        field("Untersuchung", text: $draft.studyDate, prompt: "TT.MM.JJJJ", hint: dateHint(draft.normalizedStudyDate))
                    }
                    GridRow {
                        field("Untersuchungsart", text: $draft.modality, prompt: "z. B. CT, MR")
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
                .disabled(!draft.selected)

                HStack(spacing: 6) {
                    if let message = draft.validationMessage {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(message).foregroundStyle(.orange)
                    } else {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(draft.folderName)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .font(.callout)
            }
            .padding(6)
        }
        .opacity(draft.selected ? 1 : 0.55)
    }

    private var details: String {
        var parts: [String] = []
        if let institution = draft.study.institutionName { parts.append(institution) }
        parts.append("\(draft.study.seriesCount) Serie(n)")
        parts.append("\(draft.study.files.count) Dateien")
        if let id = draft.study.patientID { parts.append("Pat.-ID \(id)") }
        return parts.joined(separator: " · ")
    }

    private func dateHint(_ normalized: String?) -> String? {
        normalized.map { ArchiveNaming.displayDate($0) }
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, prompt: String = "", hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            if let hint {
                Text(hint).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
