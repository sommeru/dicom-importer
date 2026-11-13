import DICOMImporterCore
import SwiftUI

/// State of the archive clean-up (kept in the AppModel so it survives switching panes).
@MainActor
@Observable
final class CleanupModel {
    enum Phase { case idle, analyzing, review, executing, finished }

    private(set) var phase = Phase.idle
    private(set) var progress = CleanupProgress(done: 0, total: 0, current: "")
    private(set) var plan: CleanupPlan?
    private(set) var results: [CleanupResult] = []
    var selected = Set<UUID>()
    var errorMessage: String?
    private var task: Task<Void, Never>?

    var selectedActions: [CleanupAction] { plan?.actions.filter { selected.contains($0.id) } ?? [] }

    func analyze(destination: ArchiveDestination?, protectedNames: Set<String>, capitalizeNames: Bool) {
        guard let destination else {
            errorMessage = "Es ist kein Archiv eingerichtet (Einstellungen → Archiv)."
            return
        }
        phase = .analyzing
        plan = nil
        results = []
        selected = []
        progress = CleanupProgress(done: 0, total: 0, current: "")
        let analyzer = ArchiveAnalyzer(destination: destination, protectedNames: protectedNames, capitalizeNames: capitalizeNames)
        task = Task {
            let activity = BackgroundActivity.begin("Archiv analysieren")
            defer { BackgroundActivity.end(activity) }
            do {
                let plan = try await analyzer.analyze(progress: { progress in
                    Task { @MainActor [weak self] in self?.progress = progress }
                })
                self.plan = plan
                selected = Set(plan.actions.filter(\.recommended).map(\.id))
                phase = .review
            } catch is CancellationError {
                phase = .idle
            } catch {
                errorMessage = AppModel.describe(error)
                phase = .idle
            }
        }
    }

    func execute(destination: ArchiveDestination?) {
        guard let destination else { return }
        let actions = selectedActions
        guard !actions.isEmpty else { return }
        phase = .executing
        progress = CleanupProgress(done: 0, total: actions.count, current: "")
        let executor = CleanupExecutor(destination: destination)
        task = Task {
            let activity = BackgroundActivity.begin("Archiv aufräumen")
            defer { BackgroundActivity.end(activity) }
            let results = await executor.perform(actions, progress: { progress in
                Task { @MainActor [weak self] in self?.progress = progress }
            })
            self.results = results
            phase = .finished
        }
    }

    func cancel() { task?.cancel() }

    func reset() {
        task?.cancel()
        phase = .idle
        plan = nil
        results = []
        selected = []
    }

    func setAll(_ kind: CleanupKind, selected isSelected: Bool) {
        for action in plan?.actions ?? [] where action.kind == kind {
            if isSelected { selected.insert(action.id) } else { selected.remove(action.id) }
        }
    }
}

struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmExecution = false

    private var cleanup: CleanupModel { model.cleanup }

    var body: some View {
        Group {
            switch cleanup.phase {
            case .idle: start
            case .analyzing: progressView(title: "Archiv wird analysiert …", unit: "Ordner")
            case .review: review
            case .executing: progressView(title: "Änderungen werden ausgeführt …", unit: "Aktionen")
            case .finished: finished
            }
        }
        .navigationTitle("Archiv aufräumen")
        .alert("Hinweis", isPresented: Binding(
            get: { cleanup.errorMessage != nil },
            set: { if !$0 { cleanup.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cleanup.errorMessage ?? "")
        }
    }

    private func startAnalysis() {
        let protected = Set(model.jobs.filter { $0.state != .completed }.map(\.partialFolderName))
        cleanup.analyze(
            destination: model.makeDestination(),
            protectedNames: protected,
            capitalizeNames: UserDefaults.standard.bool(forKey: SettingsKey.capitalizeNames)
        )
    }

    // MARK: Start

    private var start: some View {
        VStack(spacing: 18) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("Archiv prüfen und aufräumen").font(.title2.weight(.medium))
            VStack(alignment: .leading, spacing: 6) {
                Label("leere Ordner und abgebrochene Übertragungen", systemImage: "folder.badge.minus")
                Label("Ordner ohne DICOM-Daten", systemImage: "questionmark.folder")
                Label("doppelt archivierte Untersuchungen", systemImage: "doc.on.doc")
                Label("Ordner mit mehreren Untersuchungen", systemImage: "square.split.2x1")
                Label("falsch benannte Ordner (Name aus den DICOM-Daten)", systemImage: "character.cursor.ibeam")
            }
            .foregroundStyle(.secondary)
            Text("Zuerst wird nur analysiert. Geändert wird erst, wenn du die Vorschläge in der Liste bestätigst.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let name = model.makeDestination()?.displayName {
                Text(name).font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            Button("Analyse starten") { startAnalysis() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.makeDestination() == nil)
        }
        .padding(40)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func progressView(title: String, unit: String) -> some View {
        VStack(spacing: 14) {
            Text(title).font(.title3)
            if cleanup.progress.total > 0 {
                ProgressView(value: Double(cleanup.progress.done), total: Double(cleanup.progress.total))
                    .frame(maxWidth: 420)
                Text("\(cleanup.progress.done) von \(cleanup.progress.total) \(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            Text(cleanup.progress.current)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Abbrechen", role: .cancel) { cleanup.cancel() }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Review

    private var review: some View {
        let plan = cleanup.plan
        let actions = plan?.actions ?? []
        return VStack(spacing: 0) {
            if actions.isEmpty {
                ContentUnavailableView("Alles in Ordnung", systemImage: "checkmark.seal",
                                       description: Text("\(plan?.folderCount ?? 0) Ordner geprüft – keine Probleme gefunden."))
            } else {
                List {
                    if let errors = plan?.errors, !errors.isEmpty {
                        Section("Nicht prüfbar (\(errors.count))") {
                            ForEach(errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                        }
                    }
                    ForEach(CleanupKind.allCases, id: \.self) { kind in
                        let items = actions.filter { $0.kind == kind }
                        if !items.isEmpty {
                            Section {
                                ForEach(items) { action in
                                    ActionRow(action: action, isSelected: binding(for: action.id))
                                }
                            } header: {
                                HStack {
                                    Text("\(kind.title) (\(items.count))")
                                    Spacer()
                                    Button("Alle") { cleanup.setAll(kind, selected: true) }
                                    Button("Keine") { cleanup.setAll(kind, selected: false) }
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("\(plan?.folderCount ?? 0) Ordner geprüft · \(actions.count) Vorschläge · \(cleanup.selected.count) ausgewählt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Verwerfen") { cleanup.reset() }
                Button("Neu analysieren") { startAnalysis() }
                Button("Ausgewählte ausführen …") { confirmExecution = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleanup.selected.isEmpty)
            }
            .padding(14)
        }
        .confirmationDialog("Änderungen am Archiv ausführen?", isPresented: $confirmExecution) {
            Button("\(cleanup.selected.count) Aktionen ausführen", role: .destructive) {
                cleanup.execute(destination: model.makeDestination())
            }
        } message: {
            let deletions = cleanup.selectedActions.filter(\.kind.isDeletion).count
            Text(deletions > 0
                 ? "\(deletions) Ordner werden ENDGÜLTIG gelöscht. Dies kann nicht rückgängig gemacht werden."
                 : "Ordner werden umbenannt bzw. verschoben.")
        }
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { cleanup.selected.contains(id) },
            set: { if $0 { cleanup.selected.insert(id) } else { cleanup.selected.remove(id) } }
        )
    }

    // MARK: Finished

    private var finished: some View {
        let failed = cleanup.results.filter(\.failed)
        return VStack(spacing: 0) {
            List {
                Section {
                    Label("\(cleanup.results.count - failed.count) erfolgreich, \(failed.count) fehlgeschlagen",
                          systemImage: failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(failed.isEmpty ? .green : .orange)
                }
                Section("Protokoll") {
                    ForEach(cleanup.results) { result in
                        HStack(alignment: .top) {
                            Image(systemName: result.failed ? "xmark.octagon.fill" : "checkmark.circle")
                                .foregroundStyle(result.failed ? .red : .green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.action.folder).font(.callout.monospaced())
                                Text(result.message)
                                    .font(.caption)
                                    .foregroundStyle(result.failed ? .red : .secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Fertig") { cleanup.reset() }
                Button("Neu analysieren") { startAnalysis() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
    }
}

private struct ActionRow: View {
    let action: CleanupAction
    @Binding var isSelected: Bool

    var body: some View {
        Toggle(isOn: $isSelected) {
            VStack(alignment: .leading, spacing: 3) {
                Text(action.folder)
                    .font(.callout.monospaced())
                    .strikethrough(action.kind.isDeletion && isSelected, color: .red)
                if let target = action.targetName {
                    switch action.kind {
                    case .rename, .split:
                        Text("→ \(target)").font(.callout.monospaced()).foregroundStyle(.blue)
                    default:
                        EmptyView()
                    }
                }
                ForEach(action.splitGroups, id: \.self) { group in
                    Text("+ \(group.targetName)  (\(group.summary))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.blue)
                }
                Text(action.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 2)
    }
}
