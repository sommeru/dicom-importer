import DICOMImporterCore
import SwiftUI
import WebKit

/// Embedded browser for patient image portals. Downloads (ZIP/DICOM) are captured
/// and handed to the importer instead of landing in the user's Downloads folder.
struct PortalBrowserView: View {
    let startURL: URL

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var browser = PortalBrowser()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!browser.canGoBack)
                Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                Image(systemName: browser.isSecure ? "lock.fill" : "lock.open.fill")
                    .foregroundStyle(browser.isSecure ? Color.secondary : Color.orange)
                Text(browser.currentURL?.absoluteString ?? startURL.absoluteString)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                Spacer()
                if browser.isLoading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            WebView(webView: browser.webView)

            Divider()
            footer
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .navigationTitle(browser.title.isEmpty ? (startURL.host ?? "Bildportal") : browser.title)
        .onAppear {
            browser.onDownloadFinished = { file, container in
                Task { await model.portalDownloadFinished(file, container: container) }
            }
            if browser.currentURL == nil { browser.load(startURL) }
            browser.beginBackgroundActivity()
        }
        .onDisappear { browser.endBackgroundActivity() }
    }

    @ViewBuilder
    private var footer: some View {
        if browser.downloads.isEmpty {
            Label("Nach der Anmeldung die Bilddaten (DICOM/ZIP) herunterladen – sie werden automatisch übernommen.",
                  systemImage: "arrow.down.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(browser.downloads) { item in
                    HStack {
                        Image(systemName: item.icon)
                            .foregroundStyle(item.color)
                        Text(item.filename).lineLimit(1)
                        Spacer()
                        switch item.state {
                        case .running:
                            ProgressView(item.progress).frame(width: 180)
                        case .finished:
                            Text("übernommen").foregroundStyle(.secondary)
                        case .failed(let message):
                            Text(message).foregroundStyle(.red).lineLimit(1)
                        }
                    }
                    .font(.callout)
                }
                if browser.downloads.contains(where: { $0.state == .finished }) {
                    HStack {
                        Spacer()
                        Button("Zum Import wechseln") {
                            model.selection = .importer
                            openWindow(id: "main")
                            dismissWindow()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
    }
}

private struct WebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

@MainActor
final class PortalBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    struct DownloadItem: Identifiable {
        enum State: Equatable { case running, finished, failed(String) }
        let id = UUID()
        var filename: String
        var progress: Progress
        var state: State = .running

        var icon: String {
            switch state {
            case .running: return "arrow.down.circle"
            case .finished: return "checkmark.circle.fill"
            case .failed: return "xmark.octagon.fill"
            }
        }

        var color: Color {
            switch state {
            case .running: return .accentColor
            case .finished: return .green
            case .failed: return .red
            }
        }
    }

    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var currentURL: URL?
    @Published private(set) var title = ""
    @Published private(set) var downloads: [DownloadItem] = []

    let webView: WKWebView
    /// Per-window folder for downloads; removed once the data is staged or discarded.
    let container: URL
    var onDownloadFinished: ((URL, URL) -> Void)?

    private var pending: [ObjectIdentifier: (id: UUID, file: URL)] = [:]
    private var activity: NSObjectProtocol?

    /// While the portal window is open the app is exempt from App Nap and idle sleep.
    func beginBackgroundActivity() {
        if activity == nil { activity = BackgroundActivity.begin("Bildportal / Download") }
    }

    func endBackgroundActivity() {
        if let activity { BackgroundActivity.end(activity) }
        activity = nil
    }
    private var observations: [NSKeyValueObservation] = []

    var isSecure: Bool { (currentURL?.scheme ?? "https") == "https" }

    override init() {
        container = AppModel.downloadsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configuration = WKWebViewConfiguration()
        // No cookies/cache survive the window: patient data stays ephemeral.
        configuration.websiteDataStore = .nonPersistent()
        // Some portals reject unknown browsers.
        configuration.applicationNameForUserAgent = "Version/17.0 Safari/605.1.15"
        // Do not throttle JavaScript/timers when the window is in the background or hidden:
        // many portals prepare the ZIP download in the page and would stall otherwise.
        configuration.preferences.inactiveSchedulingPolicy = .none
        // Some portals pause their download preparation while the page is hidden
        // (Page Visibility API). Always report the page as visible.
        let alwaysVisible = """
        Object.defineProperty(document, 'hidden', { get: () => false, configurable: true });
        Object.defineProperty(document, 'visibilityState', { get: () => 'visible', configurable: true });
        document.addEventListener('visibilitychange', e => e.stopImmediatePropagation(), true);
        """
        configuration.userContentController.addUserScript(
            WKUserScript(source: alwaysVisible, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.isLoading) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.url) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.title) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
        ]
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    private func syncState() {
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        currentURL = webView.url
        title = webView.title ?? ""
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.shouldPerformDownload ? .download : .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if !navigationResponse.canShowMIMEType { return .download }
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().contains("attachment") {
            return .download
        }
        let mime = navigationResponse.response.mimeType?.lowercased() ?? ""
        if ["application/zip", "application/x-zip-compressed", "application/dicom", "application/octet-stream"].contains(mime) {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: WKUIDelegate

    /// Links with target="_blank" open in the same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Abbrechen")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let directory = container.appendingPathComponent("downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let filename = ArchiveNaming.sanitize(suggestedFilename.isEmpty ? "download" : suggestedFilename)
        let file = directory.appendingPathComponent(filename)
        let item = DownloadItem(filename: filename, progress: download.progress)
        downloads.append(item)
        pending[ObjectIdentifier(download)] = (item.id, file)
        return file
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let entry = pending.removeValue(forKey: ObjectIdentifier(download)) else { return }
        setState(.finished, for: entry.id)
        onDownloadFinished?(entry.file, container)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let entry = pending.removeValue(forKey: ObjectIdentifier(download)) else { return }
        setState(.failed(error.localizedDescription), for: entry.id)
    }

    private func setState(_ state: DownloadItem.State, for id: UUID) {
        if let index = downloads.firstIndex(where: { $0.id == id }) {
            downloads[index].state = state
        }
    }
}
