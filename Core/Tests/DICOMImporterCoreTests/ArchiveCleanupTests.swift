import XCTest
@testable import DICOMImporterCore

final class ArchiveCleanupTests: XCTestCase {
    var archive: URL!

    override func setUpWithError() throws {
        archive = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: archive)
    }

    private func dicom(uid: String, name: String, date: String, dob: String = "19800101", modality: String, series: String) -> DICOMTestFile {
        var f = DICOMTestFile()
        f.add(0x0008, 0x0016, "UI", "1.2.840.10008.5.1.4.1.1.2")
        f.add(0x0008, 0x0020, "DA", date)
        f.add(0x0008, 0x0060, "CS", modality)
        f.add(0x0010, 0x0010, "PN", name)
        f.add(0x0010, 0x0030, "DA", dob)
        f.add(0x0020, 0x000D, "UI", uid)
        f.add(0x0020, 0x000E, "UI", series)
        return f
    }

    private func write(_ file: DICOMTestFile, _ path: String) throws {
        try file.write(to: archive.appendingPathComponent(path))
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: archive.appendingPathComponent(path).path)
    }

    private func buildArchive() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: archive.appendingPathComponent("Leer/Unterordner"), withIntermediateDirectories: true)
        try fm.createDirectory(at: archive.appendingPathComponent("Nur DS"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: archive.appendingPathComponent("Nur DS/.DS_Store"))
        try fm.createDirectory(at: archive.appendingPathComponent("@Recycle"), withIntermediateDirectories: true)
        try fm.createDirectory(at: archive.appendingPathComponent("Viewer"), withIntermediateDirectories: true)
        try Data("MZ viewer binary".utf8).write(to: archive.appendingPathComponent("Viewer/setup.exe"))
        try Data("Lies mich bitte".utf8).write(to: archive.appendingPathComponent("Viewer/LIESMICH"))

        let max = "MUSTERMANN^MAX"
        try write(dicom(uid: "9.9", name: max, date: "20240621", modality: "CT", series: "9.9.1"),
                  "20240621-19800101-Mustermann, Max-CT.upload-abcdef12/IM0")
        // No naming scheme at all
        try write(dicom(uid: "1.1", name: max, date: "20240621", modality: "CT", series: "1.1.1"), "falsch/DICOM/IM0")
        try write(dicom(uid: "1.1", name: max, date: "20240621", modality: "CT", series: "1.1.1"), "falsch/DICOM/IM1")
        // Identical duplicates
        for folder in ["20240101-19700101-DOE, JANE-MR", "Kopie"] {
            for i in 0..<2 {
                try write(dicom(uid: "2.2", name: "DOE^JANE", date: "20240101", dob: "19700101", modality: "MR", series: "2.2.1"), "\(folder)/IM\(i)")
            }
        }
        // Two studies in one folder
        try write(dicom(uid: "3.3", name: "DOE^JOHN", date: "20240621", modality: "CT", series: "3.3.1"), "Gemischt/S1/IM0")
        try write(dicom(uid: "3.3", name: "DOE^JOHN", date: "20240621", modality: "CT", series: "3.3.1"), "Gemischt/S1/IM1")
        try write(dicom(uid: "4.4", name: "DOE^JOHN", date: "20240621", modality: "MR", series: "4.4.1"), "Gemischt/S2/IM0")
        // Wrong modality in name (old importer used the first file, e.g. SR)
        try write(dicom(uid: "5.5", name: max, date: "20230505", modality: "CT", series: "5.5.1"), "20230505-19800101-MUSTERMANN, MAX-SR/IM0")
        // Only the patient name differs (possibly corrected by hand)
        try write(dicom(uid: "6.6", name: max, date: "20220202", modality: "CT", series: "6.6.1"), "20220202-19800101-Musterman, Max-CT/IM0")
        // Correct (case differs only)
        try write(dicom(uid: "7.7", name: max, date: "20200101", modality: "CT", series: "7.7.1"), "20200101-19800101-Mustermann, Max-CT/IM0")
    }

    func testAnalysisAndExecution() async throws {
        try buildArchive()
        let destination = LocalFolderDestination(root: archive)
        let plan = try await ArchiveAnalyzer(destination: destination).analyze()

        XCTAssertEqual(plan.folderCount, 11, "@Recycle must be skipped")
        XCTAssertTrue(plan.errors.isEmpty, "\(plan.errors)")
        func action(_ folder: String) -> CleanupAction? { plan.actions.first { $0.folder == folder } }

        XCTAssertEqual(action("Leer")?.kind, .deleteEmpty)
        XCTAssertEqual(action("Nur DS")?.kind, .deleteEmpty)
        XCTAssertEqual(action("20240621-19800101-Mustermann, Max-CT.upload-abcdef12")?.kind, .deleteIncompleteUpload)
        XCTAssertEqual(action("Viewer")?.kind, .deleteNoDICOM)
        XCTAssertEqual(action("Viewer")?.recommended, false)
        XCTAssertEqual(action("Kopie")?.kind, .deleteDuplicate)
        XCTAssertEqual(action("Kopie")?.targetName, "20240101-19700101-DOE, JANE-MR")
        XCTAssertNil(action("20240101-19700101-DOE, JANE-MR"))

        let split = try XCTUnwrap(action("Gemischt"))
        XCTAssertEqual(split.kind, .split)
        XCTAssertEqual(split.targetName, "20240621-19800101-DOE, JOHN-CT")
        XCTAssertEqual(split.splitGroups.map(\.targetName), ["20240621-19800101-DOE, JOHN-MR"])
        XCTAssertEqual(split.splitGroups.first?.files, ["S2/IM0"])

        XCTAssertEqual(action("falsch")?.kind, .rename)
        XCTAssertEqual(action("falsch")?.targetName, "20240621-19800101-MUSTERMANN, MAX-CT")
        XCTAssertEqual(action("falsch")?.recommended, true)
        XCTAssertEqual(action("20230505-19800101-MUSTERMANN, MAX-SR")?.targetName, "20230505-19800101-MUSTERMANN, MAX-CT")
        XCTAssertEqual(action("20230505-19800101-MUSTERMANN, MAX-SR")?.recommended, true)
        XCTAssertEqual(action("20220202-19800101-Musterman, Max-CT")?.recommended, false)
        XCTAssertNil(action("20200101-19800101-Mustermann, Max-CT"))

        // Execute the pre-selected actions only.
        let results = await CleanupExecutor(destination: destination).perform(plan.actions.filter(\.recommended))
        XCTAssertTrue(results.allSatisfy { !$0.failed }, results.filter(\.failed).map(\.message).joined(separator: "\n"))

        XCTAssertFalse(exists("Leer"))
        XCTAssertFalse(exists("Nur DS"))
        XCTAssertFalse(exists("20240621-19800101-Mustermann, Max-CT.upload-abcdef12"))
        XCTAssertTrue(exists("Viewer"), "not pre-selected")
        XCTAssertFalse(exists("Kopie"))
        XCTAssertTrue(exists("20240101-19700101-DOE, JANE-MR/IM1"))
        XCTAssertFalse(exists("Gemischt"))
        XCTAssertTrue(exists("20240621-19800101-DOE, JOHN-CT/S1/IM1"))
        XCTAssertTrue(exists("20240621-19800101-DOE, JOHN-MR/S2/IM0"))
        XCTAssertTrue(exists("20240621-19800101-MUSTERMANN, MAX-CT/DICOM/IM0"))
        XCTAssertTrue(exists("20230505-19800101-MUSTERMANN, MAX-CT/IM0"))
        XCTAssertTrue(exists("20220202-19800101-Musterman, Max-CT/IM0"), "not pre-selected")
        XCTAssertTrue(exists("@Recycle"))

        // A second analysis finds nothing pre-selected anymore.
        let second = try await ArchiveAnalyzer(destination: destination).analyze()
        XCTAssertEqual(second.actions.filter(\.recommended).map(\.folder), [])
    }

    func testRunningUploadIsProtected() {
        let report = FolderReport(name: "X.upload-0123abcd", fileCount: 3, totalBytes: 10, studies: [])
        XCTAssertTrue(ArchiveAnalyzer.makePlan([report], protectedNames: ["X.upload-0123abcd"]).isEmpty)
        XCTAssertEqual(ArchiveAnalyzer.makePlan([report]).first?.kind, .deleteIncompleteUpload)
    }

    func testRenameRecommendations() {
        let expected = "20250312-19961206-KREUZER, NIKOLAUS-CT"
        // Formatting only → pre-selected
        XCTAssertEqual(ArchiveAnalyzer.renameRecommendation(current: "20250312-19961206-Kreuzer Nikolaus-CT", expected: expected), true)
        XCTAssertEqual(ArchiveAnalyzer.renameRecommendation(current: "20250312-19961206-Nikolaus- Kreuzer-CT", expected: expected), true)
        // Different spelling → not pre-selected
        XCTAssertEqual(ArchiveAnalyzer.renameRecommendation(current: "20250312-19961206-Kreutzer, Nikolaus-CT", expected: expected), false)
        // Order of modalities is irrelevant
        XCTAssertNil(ArchiveAnalyzer.renameRecommendation(current: "20260420-19490307-Leitner, Ludwig-CT+PT",
                                                          expected: "20260420-19490307-Leitner, Ludwig-PT+CT"))
    }

    func testSplitDoesNotCreateDuplicates() async throws {
        // Study 1.1 exists on its own and additionally inside a mixed folder.
        for path in ["20240621-19800101-DOE, JOHN-CT/IM0", "Gemischt/A/IM0"] {
            try write(dicom(uid: "1.1", name: "DOE^JOHN", date: "20240621", modality: "CT", series: "1.1.1"), path)
        }
        try write(dicom(uid: "2.2", name: "DOE^JOHN", date: "20240622", modality: "MR", series: "2.2.1"), "Gemischt/B/IM0")
        try write(dicom(uid: "2.2", name: "DOE^JOHN", date: "20240622", modality: "MR", series: "2.2.1"), "Gemischt/B/IM1")

        let destination = LocalFolderDestination(root: archive)
        let plan = try await ArchiveAnalyzer(destination: destination).analyze()
        let split = try XCTUnwrap(plan.actions.first { $0.kind == .split })
        XCTAssertEqual(split.splitGroups.first?.duplicateOf, "20240621-19800101-DOE, JOHN-CT")

        let results = await CleanupExecutor(destination: destination).perform(plan.actions.filter(\.recommended))
        XCTAssertTrue(results.allSatisfy { !$0.failed }, results.map(\.message).joined(separator: "\n"))
        XCTAssertTrue(exists("20240622-19800101-DOE, JOHN-MR/B/IM1"))
        XCTAssertFalse(exists("20240621-19800101-DOE, JOHN-CT (2)"), "no new duplicate")

        let second = try await ArchiveAnalyzer(destination: destination).analyze()
        XCTAssertTrue(second.actions.isEmpty, "\(second.actions.map { "\($0.kind) \($0.folder)" })")
    }

    func testFolderNameParsing() {
        let parsed = ArchiveNaming.parseFolderName("20240621-19800101-Müller-Lüdenscheidt, Max-PT+CT (2)")
        XCTAssertEqual(parsed?.name, "Müller-Lüdenscheidt, Max")
        XCTAssertEqual(parsed?.modality, "PT+CT")
        XCTAssertNil(ArchiveNaming.parseFolderName("CD Mustermann"))
        XCTAssertTrue(ArchiveNaming.equivalent("20240621-19800101-Smith, John-CT (3)", "20240621-19800101-SMITH, JOHN-CT"))
    }
}
