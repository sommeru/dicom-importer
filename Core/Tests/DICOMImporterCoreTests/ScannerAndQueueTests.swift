import XCTest
@testable import DICOMImporterCore

final class ScannerAndQueueTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("dicom-importer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Simulated CD: two studies, a DICOMDIR, viewer software and an AppleDouble file.
    private func makeCD() throws -> URL {
        let cd = tempDir.appendingPathComponent("CD")
        for i in 0..<3 {
            try DICOMTestFile.standard(studyUID: "1.1", seriesUID: "1.1.1").write(to: cd.appendingPathComponent("DICOM/S1/IM\(i)"))
        }
        try DICOMTestFile.standard(studyUID: "1.1", seriesUID: "1.1.2", modality: "SR").write(to: cd.appendingPathComponent("DICOM/S1/SR0"))
        try DICOMTestFile.standard(studyUID: "2.2", seriesUID: "2.2.1", modality: "MR").write(to: cd.appendingPathComponent("DICOM/S2/IM0"))
        var dicomdir = DICOMTestFile()
        dicomdir.add(0x0008, 0x0016, "UI", DICOMHeader.dicomdirSOPClassUID)
        try dicomdir.write(to: cd.appendingPathComponent("DICOMDIR"))
        try Data("MZ viewer".utf8).write(to: cd.appendingPathComponent("viewer.exe"))
        try Data("random".utf8).write(to: cd.appendingPathComponent("README"))
        try Data("x".utf8).write(to: cd.appendingPathComponent("DICOM/._IM0"))
        return cd
    }

    func testScannerGroupsStudies() throws {
        let cd = try makeCD()
        XCTAssertTrue(DICOMScanner.looksLikeDICOMMedium(cd))
        let result = try DICOMScanner.scan(root: cd)
        XCTAssertEqual(result.studies.count, 2)
        XCTAssertEqual(result.dicomdirPath, "DICOMDIR")
        XCTAssertEqual(result.dicomFileCount, 5)

        let ct = try XCTUnwrap(result.studies.first { $0.studyInstanceUID == "1.1" })
        XCTAssertEqual(ct.files.count, 4)
        XCTAssertEqual(ct.seriesCount, 2)
        XCTAssertEqual(ct.modalities, ["CT"], "SR is secondary and must not appear in the folder name")
        XCTAssertEqual(ct.primaryModality, "CT")
        XCTAssertEqual(ct.files.first?.relativePath, "DICOM/S1/IM0")
    }

    func testQueueUploadsToLocalFolderAndAvoidsNameClash() async throws {
        let cd = try makeCD()
        let study = try XCTUnwrap(try DICOMScanner.scan(root: cd).studies.first { $0.studyInstanceUID == "1.1" })
        let archive = tempDir.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: archive.appendingPathComponent("20240621-19800101-Mustermann, Max-CT"), withIntermediateDirectories: true)

        let queue = TransferQueue(directory: tempDir.appendingPathComponent("Outbox"))
        await queue.load()
        let job = TransferJob(folderName: "20240621-19800101-Mustermann, Max-CT", summary: "Test", files: study.files)
        await queue.add(job)
        let staging = await queue.stagingDirectory(for: job.id)
        try Stager.stage(files: study.files, from: cd, to: staging)
        await queue.markStaged(job.id)

        await queue.processPending(destination: LocalFolderDestination(root: archive))

        let jobs = await queue.jobs
        let finished = try XCTUnwrap(jobs.first)
        XCTAssertEqual(finished.state, .completed, finished.lastError ?? "")
        XCTAssertEqual(finished.finalFolderName, "20240621-19800101-Mustermann, Max-CT (2)")
        let uploaded = archive.appendingPathComponent("20240621-19800101-Mustermann, Max-CT (2)/DICOM/S1/IM2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: uploaded.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.appendingPathComponent(job.partialFolderName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "staging must be cleaned up")

        // Persistence round trip
        let reloaded = TransferQueue(directory: tempDir.appendingPathComponent("Outbox"))
        await reloaded.load()
        let reloadedJobs = await reloaded.jobs
        XCTAssertEqual(reloadedJobs.first?.state, .completed)
    }

    func testUnreachableDestinationKeepsJobForRetry() async throws {
        let cd = try makeCD()
        let study = try XCTUnwrap(try DICOMScanner.scan(root: cd).studies.first)
        let queue = TransferQueue(directory: tempDir.appendingPathComponent("Outbox"))
        await queue.load()
        let job = TransferJob(folderName: "X", summary: "Test", files: study.files)
        await queue.add(job)
        let staging = await queue.stagingDirectory(for: job.id)
        try Stager.stage(files: study.files, from: cd, to: staging)
        await queue.markStaged(job.id)

        let missing = LocalFolderDestination(root: URL(fileURLWithPath: "/Volumes/does-not-exist-\(UUID().uuidString)"))
        await queue.processPending(destination: missing)

        let jobs = await queue.jobs
        let failed = try XCTUnwrap(jobs.first)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertNotNil(failed.nextAttemptAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path), "staged data must survive a failed upload")
    }

    func testWebDAVQuotaParsing() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:"><d:response><d:href>/DICOM/</d:href><d:propstat><d:prop>
        <d:quota-available-bytes>1000</d:quota-available-bytes><d:quota-used-bytes>500</d:quota-used-bytes>
        </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>
        """
        let quota = WebDAVQuotaParser.parse(Data(xml.utf8))
        XCTAssertEqual(quota.available, 1000)
        XCTAssertEqual(quota.used, 500)
    }

    func testWebDAVURLBuilding() {
        let dav = WebDAVDestination(configuration: WebDAVConfiguration(baseURL: URL(string: "https://nas.local:5006/DICOM")!, username: "", password: ""))
        XCTAssertEqual(dav.url(for: "20240621-19800101-Müller, Max-CT", isDirectory: true).absoluteString,
                       "https://nas.local:5006/DICOM/20240621-19800101-M%C3%BCller,%20Max-CT/")
        XCTAssertEqual(dav.url(for: "a b/IM0", isDirectory: false).absoluteString, "https://nas.local:5006/DICOM/a%20b/IM0")
    }

    func testFingerprintNormalization() {
        XCTAssertEqual(CertificateFingerprint.normalize("ab cd:ef01"), "AB:CD:EF:01")
    }
}
