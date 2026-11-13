import Foundation

/// Builds the archive folder name, compatible with the previous Python importer:
/// `YYYYMMDD-YYYYMMDD-Last, First-MOD` (study date, birth date, name, modality).
public enum ArchiveNaming {
    public static func folderName(studyDate: String, birthDate: String, lastName: String, firstName: String, modality: String) -> String {
        let last = clean(lastName)
        let first = clean(firstName)
        let name: String
        switch (last.isEmpty, first.isEmpty) {
        case (false, false): name = "\(last), \(first)"
        case (false, true): name = last
        case (true, false): name = first
        case (true, true): name = "Unbekannt"
        }
        let parts = [clean(studyDate), clean(birthDate), name, clean(modality).replacingOccurrences(of: "-", with: "+")]
        return sanitize(parts.map { $0.isEmpty ? "NA" : $0 }.joined(separator: "-"))
    }

    /// Makes a string safe as a single path component on macOS, SMB and WebDAV shares.
    public static func sanitize(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var result = String(value.unicodeScalars.map { forbidden.contains($0) ? "_" : Character($0) })
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix(".") { result.removeFirst() }
        while result.hasSuffix(".") { result.removeLast() }
        return result.isEmpty ? "Import" : result
    }

    /// `MUSTERMANN` → `Mustermann`, `MÜLLER-LÜDENSCHEIDT` → `Müller-Lüdenscheidt`.
    /// Mixed-case input is left untouched.
    public static func capitalizeIfUppercase(_ value: String) -> String {
        guard value == value.uppercased(), value != value.lowercased() else { return value }
        return value.lowercased().capitalized(with: Locale(identifier: "de_DE"))
    }

    /// `19800101` → `01.01.1980` for display; other values are returned unchanged.
    public static func displayDate(_ value: String?) -> String {
        guard let value, value.count == 8, value.allSatisfy(\.isNumber) else { return value ?? "–" }
        let y = value.prefix(4), m = value.dropFirst(4).prefix(2), d = value.suffix(2)
        return "\(d).\(m).\(y)"
    }

    /// Accepts `YYYYMMDD` or `DD.MM.YYYY` and returns `YYYYMMDD`, or nil if invalid.
    public static func normalizeDateInput(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.count == 8, trimmed.allSatisfy(\.isNumber) { return trimmed }
        let parts = trimmed.split(separator: ".")
        if parts.count == 3, parts[2].count == 4, let d = Int(parts[0]), let m = Int(parts[1]), Int(parts[2]) != nil,
           (1...31).contains(d), (1...12).contains(m) {
            return "\(parts[2])\(String(format: "%02d", m))\(String(format: "%02d", d))"
        }
        return nil
    }
}
