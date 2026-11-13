import Foundation

/// A DICOM data element tag (group, element).
public struct DICOMTag: Hashable, Sendable, CustomStringConvertible {
    public let group: UInt16
    public let element: UInt16

    public init(_ group: UInt16, _ element: UInt16) {
        self.group = group
        self.element = element
    }

    public var description: String { String(format: "(%04X,%04X)", group, element) }

    // File meta information
    static let mediaStorageSOPClassUID = DICOMTag(0x0002, 0x0002)
    static let transferSyntaxUID = DICOMTag(0x0002, 0x0010)
    // Data set
    static let specificCharacterSet = DICOMTag(0x0008, 0x0005)
    static let sopClassUID = DICOMTag(0x0008, 0x0016)
    static let studyDate = DICOMTag(0x0008, 0x0020)
    static let accessionNumber = DICOMTag(0x0008, 0x0050)
    static let modality = DICOMTag(0x0008, 0x0060)
    static let institutionName = DICOMTag(0x0008, 0x0080)
    static let studyDescription = DICOMTag(0x0008, 0x1030)
    static let seriesDescription = DICOMTag(0x0008, 0x103E)
    static let patientName = DICOMTag(0x0010, 0x0010)
    static let patientID = DICOMTag(0x0010, 0x0020)
    static let patientBirthDate = DICOMTag(0x0010, 0x0030)
    static let patientSex = DICOMTag(0x0010, 0x0040)
    static let studyInstanceUID = DICOMTag(0x0020, 0x000D)
    static let seriesInstanceUID = DICOMTag(0x0020, 0x000E)

    static let wanted: Set<DICOMTag> = [
        specificCharacterSet, sopClassUID, studyDate, accessionNumber, modality, institutionName,
        studyDescription, seriesDescription, patientName, patientID, patientBirthDate, patientSex,
        studyInstanceUID, seriesInstanceUID,
    ]
}

/// The subset of DICOM header attributes the importer cares about.
public struct DICOMHeader: Sendable, Equatable {
    public var transferSyntaxUID: String?
    public var mediaStorageSOPClassUID: String?
    public var sopClassUID: String?
    public var patientName: PersonName?
    public var patientID: String?
    public var patientBirthDate: String?
    public var patientSex: String?
    public var studyDate: String?
    public var accessionNumber: String?
    public var modality: String?
    public var institutionName: String?
    public var studyDescription: String?
    public var seriesDescription: String?
    public var studyInstanceUID: String?
    public var seriesInstanceUID: String?

    public init() {}

    public static let dicomdirSOPClassUID = "1.2.840.10008.1.3.10"

    /// True for DICOMDIR (media directory) files, which do not belong to a single study.
    public var isDICOMDIR: Bool {
        mediaStorageSOPClassUID == Self.dicomdirSOPClassUID || sopClassUID == Self.dicomdirSOPClassUID
    }

    /// True if at least one attribute identifying an image/document was found.
    var hasContent: Bool {
        studyInstanceUID != nil || sopClassUID != nil || patientName != nil || modality != nil || isDICOMDIR
    }
}

/// DICOM person name (PN), e.g. `MUSTERMANN^MAX^^DR.`.
public struct PersonName: Sendable, Equatable, Hashable {
    public var family: String
    public var given: String
    public var middle: String
    public var prefix: String
    public var suffix: String

    public init(family: String, given: String, middle: String = "", prefix: String = "", suffix: String = "") {
        self.family = family
        self.given = given
        self.middle = middle
        self.prefix = prefix
        self.suffix = suffix
    }

    public init(dicom raw: String) {
        // Only the alphabetic representation (before the first "=") is used.
        let alphabetic = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        var parts = alphabetic.split(separator: "^", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 1, parts[0].contains(",") {
            // Non-conformant "Family, Given" written into a single component.
            parts = parts[0].split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func part(_ i: Int) -> String { i < parts.count ? parts[i] : "" }
        self.init(family: part(0), given: part(1), middle: part(2), prefix: part(3), suffix: part(4))
    }

    public var isEmpty: Bool { family.isEmpty && given.isEmpty }
}

public enum DICOMParseError: Error, Equatable {
    case notDICOM
    case truncated
}

/// Minimal, dependency-free DICOM header reader.
///
/// It only reads top-level attributes up to group 0x0020 and never touches pixel data,
/// so it is fast enough to scan thousands of files on a CD.
public enum DICOMParser {
    private static let undefinedLength: UInt32 = 0xFFFF_FFFF
    private static let longVRs: Set<String> = ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "SV", "UC", "UN", "UR", "UT", "UV"]
    private static let allVRs: Set<String> = [
        "AE", "AS", "AT", "CS", "DA", "DS", "DT", "FD", "FL", "IS", "LO", "LT", "OB", "OD", "OF", "OL", "OV",
        "OW", "PN", "SH", "SL", "SQ", "SS", "ST", "SV", "TM", "UC", "UI", "UL", "UN", "UR", "US", "UT", "UV",
    ]

    public static func parseHeader(at url: URL) throws -> DICOMHeader {
        let data = try Data(contentsOf: url, options: [.alwaysMapped])
        return try parseHeader(data: data)
    }

    public static func parseHeader(data: Data) throws -> DICOMHeader {
        var reader = ByteReader(data: data)
        var header = DICOMHeader()
        var explicitVR = true
        let hasPreamble = data.count >= 132 && reader.ascii(at: 128, count: 4) == "DICM"

        if hasPreamble {
            reader.position = 132
        } else {
            // Files without preamble (old CDs): plausibility check of the first tag.
            guard data.count >= 8 else { throw DICOMParseError.notDICOM }
            let group = reader.peekUInt16LE(at: 0)
            guard [0x0002, 0x0008, 0x0010].contains(group) else { throw DICOMParseError.notDICOM }
            explicitVR = allVRs.contains(reader.ascii(at: 4, count: 2) ?? "")
        }

        // File meta information (group 0002) is always explicit VR little endian.
        if reader.remaining >= 8, reader.peekUInt16LE(at: reader.position) == 0x0002 {
            while reader.remaining >= 8, reader.peekUInt16LE(at: reader.position) == 0x0002 {
                let element = try readElementHeader(&reader, explicitVR: true)
                guard element.length != undefinedLength else { throw DICOMParseError.notDICOM }
                let value = try reader.bytes(Int(element.length))
                switch element.tag {
                case DICOMTag.transferSyntaxUID: header.transferSyntaxUID = decodeASCII(value)
                case DICOMTag.mediaStorageSOPClassUID: header.mediaStorageSOPClassUID = decodeASCII(value)
                default: break
                }
            }
            switch header.transferSyntaxUID {
            case "1.2.840.10008.1.2": explicitVR = false
            case "1.2.840.10008.1.2.2": reader.bigEndian = true; explicitVR = true
            case "1.2.840.10008.1.2.1.99":
                // Deflated data set: we can still identify the file but not read its content.
                return header
            default: explicitVR = true
            }
        } else if hasPreamble, reader.remaining >= 6 {
            explicitVR = allVRs.contains(reader.ascii(at: reader.position + 4, count: 2) ?? "")
        }

        var raw: [DICOMTag: Data] = [:]
        do {
            while reader.remaining >= 8 {
                let group = reader.bigEndian ? reader.peekUInt16BE(at: reader.position) : reader.peekUInt16LE(at: reader.position)
                if group > 0x0020 { break }
                let element = try readElementHeader(&reader, explicitVR: explicitVR)
                if element.length == undefinedLength {
                    try skipUndefinedLengthSequence(&reader, explicitVR: explicitVR && element.vr != "UN")
                    continue
                }
                if DICOMTag.wanted.contains(element.tag) {
                    raw[element.tag] = try reader.bytes(Int(element.length))
                } else {
                    try reader.skip(Int(element.length))
                }
            }
        } catch {
            // Truncated or malformed tail: keep what we have, but a file without
            // preamble and without any recognised content is not DICOM.
            if !hasPreamble && raw.isEmpty { throw DICOMParseError.notDICOM }
        }

        let encoding = StringDecoding.encoding(forSpecificCharacterSet: raw[DICOMTag.specificCharacterSet].flatMap(decodeASCII))
        func text(_ tag: DICOMTag) -> String? {
            guard let value = raw[tag] else { return nil }
            let s = StringDecoding.decode(value, encoding: encoding)
            return s.isEmpty ? nil : s
        }

        header.sopClassUID = raw[DICOMTag.sopClassUID].flatMap(decodeASCII)
        header.studyInstanceUID = raw[DICOMTag.studyInstanceUID].flatMap(decodeASCII)
        header.seriesInstanceUID = raw[DICOMTag.seriesInstanceUID].flatMap(decodeASCII)
        header.studyDate = text(DICOMTag.studyDate).map(normalizeDate)
        header.patientBirthDate = text(DICOMTag.patientBirthDate).map(normalizeDate)
        header.modality = text(DICOMTag.modality)?.uppercased()
        header.accessionNumber = text(DICOMTag.accessionNumber)
        header.institutionName = text(DICOMTag.institutionName)
        header.studyDescription = text(DICOMTag.studyDescription)
        header.seriesDescription = text(DICOMTag.seriesDescription)
        header.patientID = text(DICOMTag.patientID)
        header.patientSex = text(DICOMTag.patientSex)
        if let name = text(DICOMTag.patientName) {
            header.patientName = PersonName(dicom: name)
        }

        if !hasPreamble && !header.hasContent { throw DICOMParseError.notDICOM }
        return header
    }

    // MARK: - Element parsing

    private struct ElementHeader {
        var tag: DICOMTag
        var vr: String?
        var length: UInt32
    }

    private static func readElementHeader(_ r: inout ByteReader, explicitVR: Bool) throws -> ElementHeader {
        let group = try r.uint16()
        let element = try r.uint16()
        let tag = DICOMTag(group, element)
        if group == 0xFFFE {
            // Item / delimitation tags never carry a VR.
            return ElementHeader(tag: tag, vr: nil, length: try r.uint32())
        }
        if explicitVR {
            guard let vr = r.ascii(at: r.position, count: 2), allVRs.contains(vr) else {
                throw DICOMParseError.notDICOM
            }
            try r.skip(2)
            if longVRs.contains(vr) {
                try r.skip(2)
                return ElementHeader(tag: tag, vr: vr, length: try r.uint32())
            }
            return ElementHeader(tag: tag, vr: vr, length: UInt32(try r.uint16()))
        }
        return ElementHeader(tag: tag, vr: nil, length: try r.uint32())
    }

    /// Skips a sequence of undefined length, i.e. items up to the sequence delimitation item.
    private static func skipUndefinedLengthSequence(_ r: inout ByteReader, explicitVR: Bool) throws {
        while true {
            let group = try r.uint16()
            let element = try r.uint16()
            let length = try r.uint32()
            guard group == 0xFFFE else { throw DICOMParseError.notDICOM }
            switch element {
            case 0xE0DD: return // sequence delimitation
            case 0xE000:
                if length == undefinedLength {
                    try skipUndefinedLengthItem(&r, explicitVR: explicitVR)
                } else {
                    try r.skip(Int(length))
                }
            default:
                throw DICOMParseError.notDICOM
            }
        }
    }

    private static func skipUndefinedLengthItem(_ r: inout ByteReader, explicitVR: Bool) throws {
        while true {
            let element = try readElementHeader(&r, explicitVR: explicitVR)
            if element.tag == DICOMTag(0xFFFE, 0xE00D) { return } // item delimitation
            if element.length == undefinedLength {
                try skipUndefinedLengthSequence(&r, explicitVR: explicitVR && element.vr != "UN")
            } else {
                try r.skip(Int(element.length))
            }
        }
    }

    // MARK: - Value helpers

    static func decodeASCII(_ data: Data) -> String? {
        let s = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\0")))
        return s.isEmpty ? nil : s
    }

    /// Normalises dates like `1980.01.01` (ACR-NEMA) to `19800101`.
    static func normalizeDate(_ value: String) -> String {
        let digits = value.filter(\.isNumber)
        return digits.count >= 8 ? String(digits.prefix(8)) : value
    }
}

enum StringDecoding {
    static func encoding(forSpecificCharacterSet value: String?) -> String.Encoding? {
        guard let value else { return nil }
        // Multi-valued: the last non-empty term describes the extended character set.
        let term = value.split(separator: "\\").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
        switch term.uppercased() {
        case "ISO_IR 192": return .utf8
        case "ISO_IR 100", "ISO 2022 IR 100": return .isoLatin1
        case "ISO_IR 101", "ISO 2022 IR 101": return .isoLatin2
        case "", "ISO_IR 6", "ISO 2022 IR 6": return nil
        default: return nil
        }
    }

    /// Decodes a DICOM string value. Without a declared character set, valid UTF-8 is
    /// preferred (common in practice) and ISO 8859-1 is used as lenient fallback.
    static func decode(_ data: Data, encoding: String.Encoding?) -> String {
        let trimSet = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\0"))
        if let encoding, let s = String(data: data, encoding: encoding) {
            return s.trimmingCharacters(in: trimSet)
        }
        if let s = String(data: data, encoding: .utf8) {
            return s.trimmingCharacters(in: trimSet)
        }
        return (String(data: data, encoding: .isoLatin1) ?? "").trimmingCharacters(in: trimSet)
    }
}

struct ByteReader {
    let data: Data
    var position = 0
    var bigEndian = false

    init(data: Data) { self.data = data }

    var remaining: Int { data.count - position }

    private func byte(_ offset: Int) -> UInt8 { data[data.startIndex + offset] }

    func peekUInt16LE(at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(byte(offset)) | UInt16(byte(offset + 1)) << 8
    }

    func peekUInt16BE(at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(byte(offset)) << 8 | UInt16(byte(offset + 1))
    }

    func ascii(at offset: Int, count: Int) -> String? {
        guard offset >= 0, offset + count <= data.count else { return nil }
        let bytes = (0..<count).map { byte(offset + $0) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func uint16() throws -> UInt16 {
        guard remaining >= 2 else { throw DICOMParseError.truncated }
        let value = bigEndian ? peekUInt16BE(at: position) : peekUInt16LE(at: position)
        position += 2
        return value
    }

    mutating func uint32() throws -> UInt32 {
        guard remaining >= 4 else { throw DICOMParseError.truncated }
        let b = (0..<4).map { UInt32(byte(position + $0)) }
        position += 4
        return bigEndian ? (b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]) : (b[3] << 24 | b[2] << 16 | b[1] << 8 | b[0])
    }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw DICOMParseError.truncated }
        let start = data.startIndex + position
        position += count
        return data.subdata(in: start..<(start + count))
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, remaining >= count else { throw DICOMParseError.truncated }
        position += count
    }
}
