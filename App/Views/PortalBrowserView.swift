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
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            if browser.hasPopup {
                HStack {
                    Image(systemName: "macwindow.on.rectangle")
                    Text("Vom Portal geöffnetes Fenster").font(.callout.weight(.medium))
                    Spacer()
                    Button("Fenster schließen") { browser.closePopup() }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12))
            }
            HStack(spacing: 8) {
                Button { browser.activeWebView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!browser.canGoBack)
                Button { browser.activeWebView.reload() } label: { Image(systemName: "arrow.clockwise") }
                Image(systemName: browser.isSecure ? "lock.fill" : "lock.open.fill")
                    .foregroundStyle(browser.isSecure ? Color.secondary : Color.orange)
                Text(browser.currentURL?.absoluteString ?? startURL.absoluteString)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                Spacer()
                if browser.isLoading { ProgressView().controlSize(.small) }
                Button {
                    if let url = browser.currentURL { NSWorkspace.shared.open(url) }
                } label: { Image(systemName: "safari") }
                .help("Aktuelle Seite in Safari öffnen (zum Vergleich; Anmeldung muss dort neu erfolgen)")
                Toggle(isOn: $showLog) { Image(systemName: "list.bullet.rectangle") }
                    .toggleStyle(.button)
                    .help("Protokoll anzeigen (für die Fehlersuche)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            WebView(webView: browser.activeWebView)
                .id(ObjectIdentifier(browser.activeWebView))

            if showLog {
                Divider()
                PortalLogView(entries: browser.log)
                    .frame(height: 200)
            }

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
        .alert("Externe Anwendung angefordert", isPresented: Binding(
            get: { browser.externalRequest != nil },
            set: { if !$0 { browser.externalRequest = nil } }
        ), presenting: browser.externalRequest) { url in
            Button("Mit externer App öffnen") { NSWorkspace.shared.open(url) }
            Button("Adresse kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { url in
            Text("Das Portal möchte den Viewer als eigene Anwendung starten (\(url.scheme ?? "")://…). Das kann der eingebaute Browser nicht. Bitte die Adresse kopieren und mir (bzw. dem Entwickler) schicken – darüber lassen sich die Bilddaten evtl. direkt laden.")
        }
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

private struct PortalLogView: View {
    let entries: [PortalBrowser.LogEntry]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Protokoll (\(entries.count))").font(.caption.weight(.semibold))
                Spacer()
                Button("Kopieren") {
                    let text = entries.map { "\($0.time.formatted(date: .omitted, time: .standard))  \($0.text)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            ScrollViewReader { proxy in
                List(entries) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.time.formatted(date: .omitted, time: .standard))
                            .foregroundStyle(.tertiary)
                        Text(entry.text)
                            .foregroundStyle(entry.isProblem ? .red : .primary)
                            .textSelection(.enabled)
                    }
                    .font(.caption.monospaced())
                    .id(entry.id)
                }
                .listStyle(.plain)
                .onChange(of: entries.count) {
                    if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
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
    struct LogEntry: Identifiable {
        let id = UUID()
        let time = Date()
        let text: String
        let isProblem: Bool
    }

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
    @Published private(set) var log: [LogEntry] = []
    /// Windows opened by the portal (window.open / target=_blank), shown on top of the main page.
    @Published private(set) var popups: [WKWebView] = []
    /// A link to a non-web scheme (e.g. weasis://) the portal tried to open.
    @Published var externalRequest: URL?

    var activeWebView: WKWebView { popups.last ?? webView }
    var hasPopup: Bool { !popups.isEmpty }

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
        // Viewers are often opened with window.open() after an asynchronous step (not a direct
        // click). WebKit blocks that silently unless explicitly allowed.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Debugging: forward JavaScript errors, console errors and window.open calls to the log.
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.debugScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        let messageProxy = MessageProxy()
        configuration.userContentController.add(messageProxy, name: "portalLog")
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        messageProxy.browser = self
        setUp(webView)
    }

    /// Delegates, Web Inspector and state observation for the main view and pop-ups.
    private func setUp(_ view: WKWebView) {
        view.navigationDelegate = self
        view.uiDelegate = self
        // Allows Safari ▸ Entwickler ▸ <Mac> ▸ DICOM-Importer to inspect the page (console, network).
        view.isInspectable = true
        observations += [
            view.observe(\.isLoading) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            view.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            view.observe(\.url) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            view.observe(\.title) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
        ]
    }

    func record(_ text: String, problem: Bool = false) {
        log.append(LogEntry(text: text, isProblem: problem))
        if log.count > 1000 { log.removeFirst(log.count - 1000) }
        if problem { appLog.warning("Portal: \(text, privacy: .private)") }
    }

    func closePopup() {
        guard let popup = popups.popLast() else { return }
        record("Pop-up geschlossen")
        popup.stopLoading()
        syncState()
    }

    private static let debugScript = """
    (function () {
      if (window.__dicomImporterDebug) { return; }
      window.__dicomImporterDebug = true;
      function send(kind, parts) {
        try {
          var text = Array.prototype.map.call(parts, function (a) {
            if (typeof a === 'string') { return a; }
            try { return JSON.stringify(a); } catch (e) { return String(a); }
          }).join(' ');
          window.webkit.messageHandlers.portalLog.postMessage(kind + ': ' + text.slice(0, 500));
        } catch (e) {}
      }
      var origError = console.error, origWarn = console.warn;
      console.error = function () { send('console.error', arguments); return origError.apply(console, arguments); };
      console.warn = function () { send('console.warn', arguments); return origWarn.apply(console, arguments); };
      window.addEventListener('error', function (e) {
        send('JS-Fehler', [e.message + ' (' + (e.filename || '') + ':' + (e.lineno || '') + ')']);
      });
      window.addEventListener('unhandledrejection', function (e) { send('Promise-Fehler', [String(e.reason)]); });
      var origOpen = window.open;
      window.open = function (url, name, features) {
        send('window.open', [String(url), String(name || ''), String(features || '')]);
        var result = origOpen.apply(window, arguments);
        if (!result) { send('window.open', ['→ blockiert/fehlgeschlagen']); }
        return result;
      };
    })();
    """

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    private func syncState() {
        let view = activeWebView
        isLoading = view.isLoading
        canGoBack = view.canGoBack
        currentURL = view.url
        title = view.title ?? ""
    }

    // MARK: WKNavigationDelegate

    private static let webSchemes: Set<String> = ["http", "https", "about", "blob", "data", "javascript"]

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url
        let scheme = url?.scheme?.lowercased() ?? ""
        if let url, !scheme.isEmpty, !Self.webSchemes.contains(scheme) {
            record("Externe Anwendung angefordert: \(url.absoluteString)", problem: true)
            externalRequest = url
            return .cancel
        }
        if navigationAction.targetFrame?.isMainFrame ?? true {
            record("Navigation → \(url?.absoluteString ?? "?")\(navigationAction.shouldPerformDownload ? " (Download)" : "")")
        }
        return navigationAction.shouldPerformDownload ? .download : .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse, navigationResponse.isForMainFrame || http.statusCode >= 400 {
            record("Antwort HTTP \(http.statusCode) \(navigationResponse.response.mimeType ?? "") \(http.url?.absoluteString ?? "")",
                   problem: http.statusCode >= 400)
        }
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        record("Geladen: \(webView.url?.absoluteString ?? "?")")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        logNavigationError(error, webView: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        logNavigationError(error, webView: webView)
    }

    private func logNavigationError(_ error: Error, webView: WKWebView) {
        let nsError = error as NSError
        // -999 = cancelled (e.g. replaced by a new navigation or turned into a download), 102 = frame load interrupted by download
        if nsError.code == NSURLErrorCancelled || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102) { return }
        let failing = (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? webView.url?.absoluteString ?? "?"
        record("Ladefehler \(nsError.domain) \(nsError.code): \(nsError.localizedDescription) – \(failing)", problem: true)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        record("Webseiten-Prozess abgestürzt (zu wenig Speicher / Viewer zu groß?) – lade neu", problem: true)
        webView.reload()
    }

    // MARK: WKUIDelegate

    /// window.open / target="_blank": shown as pop-up on top of the main page. The pop-up keeps
    /// its connection to the opening page (window.opener), which many viewers need.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        record("Neues Fenster angefordert: \(navigationAction.request.url?.absoluteString ?? "(leer)")")
        let popup = WKWebView(frame: .zero, configuration: configuration)
        setUp(popup)
        popups.append(popup)
        syncState()
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let index = popups.firstIndex(of: webView) {
            popups.remove(at: index)
            record("Pop-up hat sich selbst geschlossen")
            syncState()
        }
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
        record("Download: \(filename) (\(response.mimeType ?? "?"), \(response.expectedContentLength > 0 ? Format.bytes(response.expectedContentLength) : "Größe unbekannt"))")
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
        record("Download fehlgeschlagen: \(error.localizedDescription)", problem: true)
    }

    private func setState(_ state: DownloadItem.State, for id: UUID) {
        if let index = downloads.firstIndex(where: { $0.id == id }) {
            downloads[index].state = state
        }
    }
}

/// Receives messages from the debug script without creating a retain cycle
/// (WKUserContentController keeps its handlers strongly).
@MainActor
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var browser: PortalBrowser?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        let problem = !text.hasPrefix("window.open:") || text.contains("blockiert")
        browser?.record("JS \(text)", problem: problem)
    }
}
