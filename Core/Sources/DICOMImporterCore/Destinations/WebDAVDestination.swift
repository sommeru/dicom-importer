import CryptoKit
import Foundation
import Security

public struct WebDAVConfiguration: Sendable, Equatable {
    /// Collection that receives the study folders, e.g. `https://nas.local:5006/DICOM/`.
    public var baseURL: URL
    public var username: String
    public var password: String
    /// SHA-256 fingerprint of a self-signed server certificate that should be trusted.
    public var pinnedCertificateSHA256: String?

    public init(baseURL: URL, username: String, password: String, pinnedCertificateSHA256: String? = nil) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.pinnedCertificateSHA256 = pinnedCertificateSHA256
    }
}

public enum WebDAVError: LocalizedError, Equatable {
    case http(status: Int, method: String, path: String)
    case authenticationFailed
    case untrustedCertificate(host: String, fingerprint: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .http(let status, let method, let path):
            let reason = HTTPURLResponse.localizedString(forStatusCode: status)
            return "WebDAV \(method) \(path.isEmpty ? "/" : path) fehlgeschlagen: HTTP \(status) (\(reason))"
        case .authenticationFailed:
            return "Anmeldung am WebDAV-Server fehlgeschlagen (Benutzer/Passwort prüfen)."
        case .untrustedCertificate(let host, _):
            return "Das Zertifikat von \(host) ist nicht vertrauenswürdig (selbstsigniert?)."
        case .invalidResponse:
            return "Ungültige Antwort vom WebDAV-Server."
        }
    }
}

/// WebDAV client (RFC 4918) for NAS systems such as Synology, QNAP or Nextcloud.
public final class WebDAVDestination: ArchiveDestination, @unchecked Sendable {
    public let configuration: WebDAVConfiguration
    private let session: URLSession
    private let delegate: SessionDelegate

    public init(configuration: WebDAVConfiguration, timeout: TimeInterval = 60) {
        self.configuration = configuration
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = 60 * 60
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        delegate = SessionDelegate(
            pinnedFingerprint: configuration.pinnedCertificateSHA256,
            username: configuration.username,
            password: configuration.password
        )
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    public var displayName: String { configuration.baseURL.absoluteString }

    // MARK: - ArchiveDestination

    public func status() async throws -> DestinationStatus {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:"><D:prop><D:quota-available-bytes/><D:quota-used-bytes/><D:resourcetype/></D:prop></D:propfind>
        """
        let (data, response) = try await send("PROPFIND", path: "", isDirectory: true, headers: ["Depth": "0"], body: Data(body.utf8))
        guard response.statusCode == 207 || response.statusCode == 200 else {
            throw WebDAVError.http(status: response.statusCode, method: "PROPFIND", path: "")
        }
        let quota = WebDAVQuotaParser.parse(data)
        let total = quota.available.flatMap { available in quota.used.map { available + $0 } }
        return DestinationStatus(freeBytes: quota.available, totalBytes: total)
    }

    public func exists(_ path: String) async throws -> Bool {
        let (_, response) = try await send("PROPFIND", path: path, isDirectory: false, headers: ["Depth": "0"], body: nil)
        switch response.statusCode {
        case 200, 207: return true
        case 404: return false
        default: throw WebDAVError.http(status: response.statusCode, method: "PROPFIND", path: path)
        }
    }

    public func createDirectory(_ path: String) async throws {
        let (_, response) = try await send("MKCOL", path: path, isDirectory: true, headers: [:], body: nil)
        switch response.statusCode {
        case 200, 201, 204: return
        case 405:
            // 405 Method Not Allowed: the collection already exists.
            return
        default: throw WebDAVError.http(status: response.statusCode, method: "MKCOL", path: path)
        }
    }

    public func upload(fileAt localURL: URL, to path: String) async throws {
        var request = makeRequest("PUT", path: path, isDirectory: false)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let response: HTTPURLResponse
        do {
            let (_, r) = try await session.upload(for: request, fromFile: localURL)
            guard let http = r as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
            response = http
        } catch {
            throw mapError(error)
        }
        if response.statusCode == 401 { throw WebDAVError.authenticationFailed }
        guard (200...299).contains(response.statusCode) else {
            throw WebDAVError.http(status: response.statusCode, method: "PUT", path: path)
        }
    }

    public func move(_ source: String, to destination: String) async throws {
        let target = url(for: destination, isDirectory: true)
        let (_, response) = try await send(
            "MOVE", path: source, isDirectory: true,
            headers: ["Destination": target.absoluteString, "Overwrite": "F"], body: nil
        )
        switch response.statusCode {
        case 201, 204: return
        case 412: throw DestinationError.alreadyExists(destination)
        default: throw WebDAVError.http(status: response.statusCode, method: "MOVE", path: source)
        }
    }

    public func remove(_ path: String) async throws {
        let (_, response) = try await send("DELETE", path: path, isDirectory: false, headers: [:], body: nil)
        guard (200...299).contains(response.statusCode) || response.statusCode == 404 else {
            throw WebDAVError.http(status: response.statusCode, method: "DELETE", path: path)
        }
    }

    /// Fingerprint of the last certificate that failed validation (to offer "trust this certificate").
    public var lastUntrustedFingerprint: String? { delegate.lastUntrustedFingerprint }

    // MARK: - HTTP

    func url(for path: String, isDirectory: Bool) -> URL {
        var url = configuration.baseURL
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        if isDirectory, !url.absoluteString.hasSuffix("/"), let withSlash = URL(string: url.absoluteString + "/") {
            return withSlash
        }
        return url
    }

    private func makeRequest(_ method: String, path: String, isDirectory: Bool) -> URLRequest {
        var request = URLRequest(url: url(for: path, isDirectory: isDirectory))
        request.httpMethod = method
        if !configuration.username.isEmpty {
            let token = Data("\(configuration.username):\(configuration.password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ method: String, path: String, isDirectory: Bool, headers: [String: String], body: Data?) async throws -> (Data, HTTPURLResponse) {
        var request = makeRequest(method, path: path, isDirectory: isDirectory)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.httpBody = body
            request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
            if http.statusCode == 401 { throw WebDAVError.authenticationFailed }
            return (data, http)
        } catch {
            throw mapError(error)
        }
    }

    private func mapError(_ error: Error) -> Error {
        if error is WebDAVError { return error }
        if let fingerprint = delegate.lastUntrustedFingerprint,
           let urlError = error as? URLError,
           [.cancelled, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .secureConnectionFailed].contains(urlError.code) {
            return WebDAVError.untrustedCertificate(host: configuration.baseURL.host ?? "", fingerprint: fingerprint)
        }
        return error
    }
}

// MARK: - Certificate pinning / authentication

private final class SessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let pinnedFingerprint: String?
    private let username: String
    private let password: String
    private let lock = NSLock()
    private var _lastUntrusted: String?

    init(pinnedFingerprint: String?, username: String, password: String) {
        self.pinnedFingerprint = pinnedFingerprint.map(CertificateFingerprint.normalize)
        self.username = username
        self.password = password
    }

    var lastUntrustedFingerprint: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastUntrusted
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = handle(challenge)
        completionHandler(disposition, credential)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = handle(challenge)
        completionHandler(disposition, credential)
    }

    private func handle(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust {
            if SecTrustEvaluateWithError(trust, nil) {
                return (.performDefaultHandling, nil)
            }
            guard let fingerprint = CertificateFingerprint.leafSHA256(of: trust) else {
                return (.cancelAuthenticationChallenge, nil)
            }
            if let pinnedFingerprint, pinnedFingerprint == fingerprint {
                return (.useCredential, URLCredential(trust: trust))
            }
            lock.lock(); _lastUntrusted = fingerprint; lock.unlock()
            return (.cancelAuthenticationChallenge, nil)
        }
        if method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest {
            guard !username.isEmpty, challenge.previousFailureCount == 0 else {
                return (.rejectProtectionSpace, nil)
            }
            return (.useCredential, URLCredential(user: username, password: password, persistence: .none))
        }
        return (.performDefaultHandling, nil)
    }
}

public enum CertificateFingerprint {
    public static func normalize(_ value: String) -> String {
        value.uppercased().filter { $0.isHexDigit }
            .enumerated()
            .map { $0.offset > 0 && $0.offset % 2 == 0 ? ":\($0.element)" : String($0.element) }
            .joined()
    }

    static func leafSHA256(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

// MARK: - PROPFIND quota parsing

enum WebDAVQuotaParser {
    struct Quota { var available: Int64?; var used: Int64? }

    static func parse(_ data: Data) -> Quota {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return Quota(available: delegate.available, used: delegate.used)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var available: Int64?
        var used: Int64?
        private var current: String?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            current = elementName
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let value = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines))
            // Only the first propstat (the requested collection itself) is relevant.
            if elementName == "quota-available-bytes", available == nil { available = value }
            if elementName == "quota-used-bytes", used == nil { used = value }
            current = nil
            text = ""
        }
    }
}
