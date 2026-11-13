import AVFoundation
import DICOMImporterCore
import SwiftUI
import UniformTypeIdentifiers

struct QRCodeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    @State private var scanner = CameraScanner()
    @State private var cameraState = CameraState.idle
    @State private var devices: [AVCaptureDevice] = []
    @State private var deviceID = ""
    @State private var lastPayload: String?
    @State private var manualAddress = ""
    @State private var isTargeted = false

    enum CameraState { case idle, running, denied, unavailable }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            cameraPanel
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            optionsPanel
                .frame(width: 300)
        }
        .padding(20)
        .navigationTitle("QR-Code / Bildportal")
        .task { await startCamera() }
        .onDisappear { scanner.stop() }
        .onChange(of: deviceID) { scanner.start(deviceID: deviceID.isEmpty ? nil : deviceID) }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            if url.isFileURL { handle(QRCodeDetector.detect(inFile: url), source: "Datei") } else { handle([url.absoluteString], source: "Link") }
            return true
        } isTargeted: { isTargeted = $0 }
    }

    // MARK: - Camera

    private var cameraPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.85))
            switch cameraState {
            case .running:
                CameraPreview(session: scanner.session)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(.white.opacity(0.8), style: StrokeStyle(lineWidth: 3, dash: [24, 12]))
                    .frame(width: 220, height: 220)
            case .idle:
                ProgressView().tint(.white)
            case .denied:
                VStack(spacing: 10) {
                    Image(systemName: "video.slash").font(.largeTitle)
                    Text("Kein Kamerazugriff").font(.headline)
                    Text("Bitte in den Systemeinstellungen unter Datenschutz & Sicherheit → Kamera erlauben.")
                        .multilineTextAlignment(.center)
                        .font(.callout)
                    Button("Systemeinstellungen öffnen") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding()
            case .unavailable:
                VStack(spacing: 10) {
                    Image(systemName: "video.slash").font(.largeTitle)
                    Text("Keine Kamera gefunden").font(.headline)
                    Text("Tipp: Ein iPhone in der Nähe kann als Kamera (Continuity Camera) dienen. Alternativ Foto/PDF des Briefs hierher ziehen.")
                        .multilineTextAlignment(.center)
                        .font(.callout)
                }
                .foregroundStyle(.white)
                .padding()
            }
        }
        .overlay(alignment: .bottom) {
            if cameraState == .running {
                Text("QR-Code des Befundbriefs vor die Kamera halten")
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(12)
            }
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, lineWidth: 4)
            }
        }
    }

    private func startCamera() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { cameraState = .denied; return }
        default:
            cameraState = .denied
            return
        }
        devices = CameraScanner.availableDevices()
        guard !devices.isEmpty else { cameraState = .unavailable; return }
        scanner.onCode = { payload in
            Task { @MainActor in handle([payload], source: "Kamera") }
        }
        scanner.start(deviceID: deviceID.isEmpty ? nil : deviceID)
        cameraState = .running
    }

    // MARK: - Alternatives

    private var optionsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            if devices.count > 1 {
                Picker("Kamera", selection: $deviceID) {
                    Text("Standard").tag("")
                    ForEach(devices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
            }

            GroupBox("Andere Wege") {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        chooseFile()
                    } label: {
                        Label("Foto oder PDF des Briefs …", systemImage: "doc.viewfinder")
                    }
                    Button {
                        handle(QRCodeDetector.detectInPasteboard(), source: "Zwischenablage")
                    } label: {
                        Label("Aus Zwischenablage einfügen", systemImage: "doc.on.clipboard")
                    }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    Divider()
                    Text("Portal-Adresse manuell").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("https://…", text: $manualAddress)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { handle([manualAddress], source: "Eingabe") }
                        Button("Öffnen") { handle([manualAddress], source: "Eingabe") }
                            .disabled(manualAddress.isEmpty)
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let lastPayload {
                GroupBox("Erkannt") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(lastPayload)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(4)
                        if let url = QRPayload.portalURL(from: lastPayload) {
                            Button("Portal erneut öffnen") { openWindow(id: "portal", value: url) }
                        } else {
                            Text("Der QR-Code enthält keine Web-Adresse. Evtl. ist es ein Zugangscode – bitte im Portal eingeben.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Text("Das Portal öffnet sich in einem eigenen Fenster. Nach Anmeldung (meist Geburtsdatum/Zugangscode) die Bilddaten als DICOM bzw. ZIP herunterladen – der Download wird automatisch übernommen.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            handle(QRCodeDetector.detect(inFile: url), source: "Datei")
        }
    }

    private func handle(_ payloads: [String], source: String) {
        let payloads = payloads.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !payloads.isEmpty else {
            model.errorMessage = "Kein QR-Code gefunden (\(source))."
            return
        }
        // Prefer a payload that contains a portal link.
        let payload = payloads.first { QRPayload.portalURL(from: $0) != nil } ?? payloads[0]
        let isRepeat = payload == lastPayload && source == "Kamera"
        lastPayload = payload
        guard !isRepeat, let url = QRPayload.portalURL(from: payload) else { return }
        appLog.info("Opening portal \(url.host ?? "", privacy: .public)")
        openWindow(id: "portal", value: url)
    }
}
