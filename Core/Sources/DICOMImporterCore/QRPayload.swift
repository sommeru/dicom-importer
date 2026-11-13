import Foundation

/// Interprets the content of QR codes printed on radiology letters.
/// Usually this is a link to a patient image portal (often including an access token).
public enum QRPayload {
    /// Returns the portal URL contained in a QR payload, if any (only http/https).
    public static func portalURL(from payload: String) -> URL? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = webURL(trimmed) { return url }
        if trimmed.lowercased().hasPrefix("www."), let url = webURL("https://" + trimmed) { return url }

        // URL embedded in a longer text, e.g. "Ihre Bilder: https://… Code: 1234".
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        for match in detector.matches(in: trimmed, options: [], range: range) {
            if let url = match.url, let web = webURL(url.absoluteString) { return web }
        }
        return nil
    }

    private static func webURL(_ string: String) -> URL? {
        guard !string.contains(" "), let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
