import XCTest
@testable import DICOMImporterCore

final class ConfigFileTests: XCTestCase {
    func testFullConfig() {
        let config = ImporterConfig.parse("""
        # Praxis-Voreinstellungen
        [archive]
        type = webdav
        url = https://192.168.2.40:5001/Dicom   ; QNAP
        user = team
        password = "geheim ; mit Semikolon"
        certificate_sha256 = AB:CD:EF

        [general]
        auto_scan = ja
        eject = false
        capitalize_names = 1
        """)
        XCTAssertEqual(config.archiveType, .webDAV)
        XCTAssertEqual(config.webDAVURL, "https://192.168.2.40:5001/Dicom")
        XCTAssertEqual(config.webDAVUser, "team")
        XCTAssertEqual(config.webDAVPassword, "geheim ; mit Semikolon")
        XCTAssertEqual(config.certificateSHA256, "AB:CD:EF")
        XCTAssertEqual(config.autoScanMedia, true)
        XCTAssertEqual(config.ejectAfterImport, false)
        XCTAssertEqual(config.capitalizeNames, true)
        XCTAssertTrue(config.warnings.isEmpty, "\(config.warnings)")
    }

    func testLegacyPythonConfig() {
        let config = ImporterConfig.parse("""
        [settings]
        destination_path = /Volumes/Dicom
        smb_share = 192.168.2.40/DICOM
        smb_user = team
        """)
        XCTAssertEqual(config.archiveType, .folder)
        XCTAssertEqual(config.folderPath, "/Volumes/Dicom")
        XCTAssertTrue(config.warnings.isEmpty, "\(config.warnings)")
    }

    func testUnknownKeysProduceWarnings() {
        let config = ImporterConfig.parse("[archive]\ntype = ftp\nfoo = bar\n")
        XCTAssertNil(config.archiveType)
        XCTAssertEqual(config.warnings.count, 2)
        XCTAssertTrue(ImporterConfig.parse("").isEmpty)
    }

    func testMergeLaterWins() {
        let system = ImporterConfig.parse("[archive]\nurl = https://a/x\nuser = alice\n")
        let user = ImporterConfig.parse("[archive]\nuser = bob\n")
        let merged = system.merged(with: user)
        XCTAssertEqual(merged.webDAVURL, "https://a/x")
        XCTAssertEqual(merged.webDAVUser, "bob")
    }
}
