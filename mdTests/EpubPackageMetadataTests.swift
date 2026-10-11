//
//  EpubPackageMetadataTests.swift
//  mdTests
//
//  The iOS package document with front-matter metadata and a cover (1.6): the
//  shared lines land between `dc:title` and `dcterms:modified`, the cover is
//  the manifest's last item and the archive's last entry, and a document with
//  no front matter still writes the 1.5 package document byte for byte.
//

import XCTest
@testable import md

final class EpubPackageMetadataTests: XCTestCase {

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])

    private func opf(metadata: EpubMetadata = .defaults, cover: EpubCover? = nil) -> String {
        EpubBuilder.contentOPF(title: "T", identifier: "urn:uuid:x", modified: "2026-10-10T00:00:00Z",
                               units: [(id: "content", href: "content.xhtml", svg: false)],
                               images: ["images/content-01.png"],
                               metadata: metadata, cover: cover)
    }

    func testWithoutFrontMatterThePackageDocumentIsThe15One() {
        XCTAssertEqual(opf(), """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="book-id">urn:uuid:x</dc:identifier>
        <dc:title>T</dc:title>
        <dc:language>en</dc:language>
        <meta property="dcterms:modified">2026-10-10T00:00:00Z</meta>
        </metadata>
        <manifest>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="css" href="style.css" media-type="text/css"/>
        <item id="content" href="content.xhtml" media-type="application/xhtml+xml"/>
        <item id="img1" href="images/content-01.png" media-type="image/png"/>
        </manifest>
        <spine>
        <itemref idref="content"/>
        </spine>
        </package>
        """)
    }

    func testCoverIsTheLastManifestItemAndNotInTheSpine() {
        let jpeg = EpubMetadataReader.recogniseCover(Data([0xFF, 0xD8, 0xFF, 0xE0]))
        let text = opf(cover: jpeg)
        XCTAssertTrue(text.contains("""
        <item id="img1" href="images/content-01.png" media-type="image/png"/>
        <item id="cover-image" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
        </manifest>
        """))
        XCTAssertTrue(text.contains("""
        <dc:language>en</dc:language>
        <meta name="cover" content="cover-image"/>
        <meta property="dcterms:modified">
        """))
        XCTAssertFalse(text.contains("<itemref idref=\"cover-image\"/>"))
    }

    @MainActor
    func testDocumentEntriesCarryMetadataAndPackTheCoverLast() {
        let fields = MarkdownParser.frontMatter(of: "---\nauthor: A\nlanguage: de\n---\n")
        let entries = DocumentExport.documentEpubEntries(
            title: "T", body: "<h1 id=\"body\">Body</h1>",
            images: [(href: "images/content-01.png", data: png)], outline: [],
            modified: "2026-10-10T00:00:00Z",
            metadata: EpubMetadataReader.metadata(from: fields),
            cover: EpubMetadataReader.recogniseCover(png))
        XCTAssertEqual(entries.suffix(2).map(\.name), ["OEBPS/images/content-01.png", "OEBPS/images/cover.png"])
        XCTAssertEqual(entries.last?.data, png)
        let opf = String(decoding: entries.first { $0.name == "OEBPS/content.opf" }!.data, as: UTF8.self)
        XCTAssertTrue(opf.contains("<dc:creator>A</dc:creator>\n<dc:language>de</dc:language>\n<meta name=\"cover\" content=\"cover-image\"/>"))
    }

    func testReadCoverFromBesideTheDocumentButNeverOutsideIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let docs = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = docs.appendingPathComponent("notes.md")
        try Data("# n\n".utf8).write(to: document)
        try png.write(to: docs.appendingPathComponent("cover.png"))
        try png.write(to: root.appendingPathComponent("outside.png"))
        try Data("not an image".utf8).write(to: docs.appendingPathComponent("text.png"))

        let found = await DocumentExport.readCover("cover.png", besideDocumentAt: document)
        XCTAssertEqual(found?.href, "images/cover.png")
        let outside = await DocumentExport.readCover("../outside.png", besideDocumentAt: document)
        XCTAssertNil(outside)
        let notImage = await DocumentExport.readCover("text.png", besideDocumentAt: document)
        XCTAssertNil(notImage)
        let untitled = await DocumentExport.readCover("cover.png", besideDocumentAt: nil)
        XCTAssertNil(untitled)
        let data = await DocumentExport.readCover("data:image/png;base64,\(png.base64EncodedString())",
                                                  besideDocumentAt: nil)
        XCTAssertEqual(data?.data, png)
    }

    func testReadCoverRefusesAFilePastTheCap() async throws {
        let docs = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: docs) }
        let document = docs.appendingPathComponent("notes.md")
        try Data("# n\n".utf8).write(to: document)
        let big = docs.appendingPathComponent("big.png")
        try png.write(to: big)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(EpubMetadataReader.maxCoverBytes))
        try handle.close()

        let atTheCap = await DocumentExport.readCover("big.png", besideDocumentAt: document)
        XCTAssertEqual(atTheCap?.data.count, EpubMetadataReader.maxCoverBytes)
        let past = try FileHandle(forWritingTo: big)
        try past.truncate(atOffset: UInt64(EpubMetadataReader.maxCoverBytes) + 1)
        try past.close()
        let pastTheCap = await DocumentExport.readCover("big.png", besideDocumentAt: document)
        XCTAssertNil(pastTheCap)
    }
}
