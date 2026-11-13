import Foundation
@testable import DICOMImporterCore

/// Builds small synthetic DICOM files for tests.
struct DICOMTestFile {
    enum Syntax { case explicitLE, implicitLE, explicitBE }

    var syntax: Syntax = .explicitLE
    var preamble = true
    var elements: [(UInt16, UInt16, String, Data)] = []

    mutating func add(_ group: UInt16, _ element: UInt16, _ vr: String, _ value: String, encoding: String.Encoding = .ascii) {
        var data = value.data(using: encoding)!
        if data.count % 2 == 1 { data.append(vr == "UI" ? 0 : 0x20) }
        elements.append((group, element, vr, data))
    }

    /// Adds an undefined-length sequence with one undefined-length item containing a string.
    mutating func addUndefinedSequence(_ group: UInt16, _ element: UInt16) {
        elements.append((group, element, "SQ", Data()))
    }

    static func standard(
        studyUID: String = "1.2.3.4",
        seriesUID: String = "1.2.3.4.1",
        name: String = "MUSTERMANN^MAX",
        modality: String = "CT",
        syntax: Syntax = .explicitLE
    ) -> DICOMTestFile {
        var f = DICOMTestFile(syntax: syntax)
        f.add(0x0008, 0x0016, "UI", "1.2.840.10008.5.1.4.1.1.2")
        f.add(0x0008, 0x0020, "DA", "20240621")
        f.add(0x0008, 0x0060, "CS", modality)
        f.add(0x0008, 0x1030, "LO", "CT Thorax")
        f.add(0x0010, 0x0010, "PN", name)
        f.add(0x0010, 0x0030, "DA", "19800101")
        f.add(0x0020, 0x000D, "UI", studyUID)
        f.add(0x0020, 0x000E, "UI", seriesUID)
        return f
    }

    func data() -> Data {
        var out = Data()
        if preamble {
            out.append(Data(count: 128))
            out.append(Data("DICM".utf8))
        }
        let tsUID: String
        switch syntax {
        case .explicitLE: tsUID = "1.2.840.10008.1.2.1"
        case .implicitLE: tsUID = "1.2.840.10008.1.2"
        case .explicitBE: tsUID = "1.2.840.10008.1.2.2"
        }
        if preamble {
            var ts = Data(tsUID.utf8)
            if ts.count % 2 == 1 { ts.append(0) }
            out.append(Self.element(0x0002, 0x0010, "UI", ts, explicit: true, bigEndian: false))
        }
        let explicit = syntax != .implicitLE
        let big = syntax == .explicitBE
        for (group, element, vr, value) in elements {
            if vr == "SQ" && value.isEmpty {
                out.append(Self.u16(group, big)); out.append(Self.u16(element, big))
                if explicit { out.append(Data("SQ".utf8)); out.append(Data([0, 0])) }
                out.append(Self.u32(0xFFFF_FFFF, big))
                // Item, undefined length
                out.append(Self.u16(0xFFFE, big)); out.append(Self.u16(0xE000, big)); out.append(Self.u32(0xFFFF_FFFF, big))
                out.append(Self.element(0x0008, 0x1150, "UI", Data("1.2.840.10008.5.1.4.1.1.2\0".utf8), explicit: explicit, bigEndian: big))
                // Item delimitation, sequence delimitation
                out.append(Self.u16(0xFFFE, big)); out.append(Self.u16(0xE00D, big)); out.append(Self.u32(0, big))
                out.append(Self.u16(0xFFFE, big)); out.append(Self.u16(0xE0DD, big)); out.append(Self.u32(0, big))
                continue
            }
            out.append(Self.element(group, element, vr, value, explicit: explicit, bigEndian: big))
        }
        // Pixel data stub (group 7FE0) must be ignored.
        out.append(Self.element(0x7FE0, 0x0010, "OW", Data(count: 16), explicit: explicit, bigEndian: big))
        return out
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data().write(to: url)
    }

    static func element(_ group: UInt16, _ element: UInt16, _ vr: String, _ value: Data, explicit: Bool, bigEndian: Bool) -> Data {
        var out = Data()
        out.append(u16(group, bigEndian)); out.append(u16(element, bigEndian))
        if explicit {
            out.append(Data(vr.utf8))
            if ["OB", "OW", "SQ", "UN", "UT", "UC", "UR"].contains(vr) {
                out.append(Data([0, 0])); out.append(u32(UInt32(value.count), bigEndian))
            } else {
                out.append(u16(UInt16(value.count), bigEndian))
            }
        } else {
            out.append(u32(UInt32(value.count), bigEndian))
        }
        out.append(value)
        return out
    }

    static func u16(_ v: UInt16, _ big: Bool) -> Data {
        big ? Data([UInt8(v >> 8), UInt8(v & 0xFF)]) : Data([UInt8(v & 0xFF), UInt8(v >> 8)])
    }

    static func u32(_ v: UInt32, _ big: Bool) -> Data {
        let bytes = [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
        return Data(big ? bytes.reversed() : bytes)
    }
}
