import XCTest
@testable import DICOMImporterCore

final class DICOMParserTests: XCTestCase {
    func testExplicitLittleEndian() throws {
        let header = try DICOMParser.parseHeader(data: DICOMTestFile.standard().data())
        XCTAssertEqual(header.patientName, PersonName(family: "MUSTERMANN", given: "MAX"))
        XCTAssertEqual(header.patientBirthDate, "19800101")
        XCTAssertEqual(header.studyDate, "20240621")
        XCTAssertEqual(header.modality, "CT")
        XCTAssertEqual(header.studyDescription, "CT Thorax")
        XCTAssertEqual(header.studyInstanceUID, "1.2.3.4")
        XCTAssertEqual(header.seriesInstanceUID, "1.2.3.4.1")
        XCTAssertEqual(header.transferSyntaxUID, "1.2.840.10008.1.2.1")
    }

    func testImplicitLittleEndian() throws {
        let header = try DICOMParser.parseHeader(data: DICOMTestFile.standard(syntax: .implicitLE).data())
        XCTAssertEqual(header.patientName?.family, "MUSTERMANN")
        XCTAssertEqual(header.studyInstanceUID, "1.2.3.4")
    }

    func testExplicitBigEndian() throws {
        let header = try DICOMParser.parseHeader(data: DICOMTestFile.standard(syntax: .explicitBE).data())
        XCTAssertEqual(header.patientName?.given, "MAX")
        XCTAssertEqual(header.modality, "CT")
    }

    func testWithoutPreambleImplicit() throws {
        var file = DICOMTestFile.standard(syntax: .implicitLE)
        file.preamble = false
        let header = try DICOMParser.parseHeader(data: file.data())
        XCTAssertEqual(header.patientName?.family, "MUSTERMANN")
        XCTAssertEqual(header.studyDate, "20240621")
    }

    func testUndefinedLengthSequenceIsSkipped() throws {
        for syntax in [DICOMTestFile.Syntax.explicitLE, .implicitLE] {
            var file = DICOMTestFile(syntax: syntax)
            file.add(0x0008, 0x0020, "DA", "20240101")
            file.addUndefinedSequence(0x0008, 0x1115)
            file.add(0x0010, 0x0010, "PN", "DOE^JANE")
            file.add(0x0020, 0x000D, "UI", "9.8.7")
            let header = try DICOMParser.parseHeader(data: file.data())
            XCTAssertEqual(header.patientName?.family, "DOE", "\(syntax)")
            XCTAssertEqual(header.studyInstanceUID, "9.8.7", "\(syntax)")
        }
    }

    func testLatin1CharacterSet() throws {
        var file = DICOMTestFile()
        file.add(0x0008, 0x0005, "CS", "ISO_IR 100")
        file.add(0x0010, 0x0010, "PN", "MÜLLER^JÜRGEN", encoding: .isoLatin1)
        let header = try DICOMParser.parseHeader(data: file.data())
        XCTAssertEqual(header.patientName?.family, "MÜLLER")
        XCTAssertEqual(header.patientName?.given, "JÜRGEN")
    }

    func testUTF8CharacterSet() throws {
        var file = DICOMTestFile()
        file.add(0x0008, 0x0005, "CS", "ISO_IR 192")
        file.add(0x0010, 0x0010, "PN", "Weiß^Zoë", encoding: .utf8)
        let header = try DICOMParser.parseHeader(data: file.data())
        XCTAssertEqual(header.patientName, PersonName(family: "Weiß", given: "Zoë"))
    }

    func testUndeclaredUmlautsFallBackToLatin1() throws {
        var file = DICOMTestFile()
        file.add(0x0010, 0x0010, "PN", "BÄR^ANNA", encoding: .isoLatin1)
        let header = try DICOMParser.parseHeader(data: file.data())
        XCTAssertEqual(header.patientName?.family, "BÄR")
    }

    func testNonDICOMIsRejected() {
        XCTAssertThrowsError(try DICOMParser.parseHeader(data: Data("MZ This is an executable".utf8)))
        XCTAssertThrowsError(try DICOMParser.parseHeader(data: Data("<html><body>Viewer</body></html>".utf8)))
    }

    func testPersonNameVariants() {
        XCTAssertEqual(PersonName(dicom: "Mustermann^Max^^Dr.").prefix, "Dr.")
        XCTAssertEqual(PersonName(dicom: "Mustermann, Max"), PersonName(family: "Mustermann", given: "Max"))
        XCTAssertEqual(PersonName(dicom: "Yamada^Tarou=山田^太郎").family, "Yamada")
    }

    func testDICOMDIRDetection() throws {
        var file = DICOMTestFile()
        file.add(0x0008, 0x0016, "UI", DICOMHeader.dicomdirSOPClassUID)
        XCTAssertTrue(try DICOMParser.parseHeader(data: file.data()).isDICOMDIR)
    }
}

final class ArchiveNamingTests: XCTestCase {
    func testLegacyCompatibleFolderName() {
        XCTAssertEqual(
            ArchiveNaming.folderName(studyDate: "20240621", birthDate: "19800101", lastName: "Smith", firstName: "John", modality: "CT"),
            "20240621-19800101-Smith, John-CT"
        )
    }

    func testSanitizing() {
        XCTAssertEqual(
            ArchiveNaming.folderName(studyDate: "20240621", birthDate: "", lastName: "A/B:C", firstName: "", modality: "PT-CT"),
            "20240621-NA-A_B_C-PT+CT"
        )
        XCTAssertEqual(ArchiveNaming.sanitize("..hidden.."), "hidden")
    }

    func testCapitalize() {
        XCTAssertEqual(ArchiveNaming.capitalizeIfUppercase("MÜLLER-LÜDENSCHEIDT"), "Müller-Lüdenscheidt")
        XCTAssertEqual(ArchiveNaming.capitalizeIfUppercase("McDonald"), "McDonald")
    }

    func testDates() {
        XCTAssertEqual(ArchiveNaming.normalizeDateInput("01.02.1980"), "19800201")
        XCTAssertEqual(ArchiveNaming.normalizeDateInput("19800201"), "19800201")
        XCTAssertNil(ArchiveNaming.normalizeDateInput("1980-02"))
        XCTAssertEqual(ArchiveNaming.displayDate("19800201"), "01.02.1980")
    }
}

final class QRPayloadTests: XCTestCase {
    func testPlainURL() {
        XCTAssertEqual(QRPayload.portalURL(from: "https://portal.example.de/s/AbC123?pin=1")?.host, "portal.example.de")
    }

    func testWWWWithoutScheme() {
        XCTAssertEqual(QRPayload.portalURL(from: "www.example.de/abc")?.absoluteString, "https://www.example.de/abc")
    }

    func testEmbeddedURL() {
        XCTAssertEqual(QRPayload.portalURL(from: "Ihre Bilder: https://bilder.example.de/x Code 4711")?.absoluteString, "https://bilder.example.de/x")
    }

    func testRejectsNonWeb() {
        XCTAssertNil(QRPayload.portalURL(from: "file:///etc/passwd"))
        XCTAssertNil(QRPayload.portalURL(from: "javascript:alert(1)"))
        XCTAssertNil(QRPayload.portalURL(from: "Zugangscode 123456"))
    }
}
