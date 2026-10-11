//
//  EpubMetadataTests.swift
//  mdTests
//
//  EPUB metadata and cover from front matter (1.6) — the family's vectors.
//  md for VS Code carries the same ones in `test/epub-metadata.test.ts`, and
//  Android and Windows carry them too, so the five package documents agree on
//  which keys count, which values are accepted, and the exact lines they
//  become. This file is the same in md and md.macOS; each repo's own package
//  document is pinned in its EPUB tests.
//

import XCTest
@testable import md

final class EpubMetadataTests: XCTestCase {

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 16])
    private let gif = Data("GIF89a\u{01}\u{00}".utf8)
    private let webp = Data("RIFF\u{24}\u{00}\u{00}\u{00}WEBPVP8 ".utf8)

    private func metadata(_ matter: String) -> EpubMetadata {
        EpubMetadataReader.metadata(from: MarkdownParser.frontMatter(of: "---\n\(matter)\n---\n\n# Body\n"))
    }

    private func lines(_ matter: String, cover: EpubCover? = nil) -> [String] {
        EpubMetadataReader.metadataLines(metadata(matter), cover: cover)
    }

    // MARK: Metadata lines

    func testNoFrontMatterIsTheOneLanguageLineEveryEpubCarried() {
        XCTAssertEqual(EpubMetadataReader.metadataLines(EpubMetadataReader.metadata(from: []), cover: nil),
                       ["<dc:language>en</dc:language>"])
        XCTAssertEqual(EpubMetadataReader.metadataLines(.defaults, cover: nil), ["<dc:language>en</dc:language>"])
        XCTAssertEqual(lines("title: Only a title"), ["<dc:language>en</dc:language>"])
    }

    func testWritesEveryKeyInTheFamilyOrder() {
        let matter = [
            "title: The Book",
            "author: Ada Lovelace",
            "language: ru",
            "date: 2026-10-10",
            "description: Notes on the \"Engine\" & more",
            "series: Analytical",
            "series_index: 2",
        ].joined(separator: "\n")
        XCTAssertEqual(lines(matter, cover: EpubMetadataReader.recogniseCover(png)), [
            "<dc:creator>Ada Lovelace</dc:creator>",
            "<dc:language>ru</dc:language>",
            "<dc:date>2026-10-10</dc:date>",
            "<dc:description>Notes on the &quot;Engine&quot; &amp; more</dc:description>",
            "<meta property=\"belongs-to-collection\" id=\"series\">Analytical</meta>",
            "<meta refines=\"#series\" property=\"collection-type\">series</meta>",
            "<meta refines=\"#series\" property=\"group-position\">2</meta>",
            "<meta name=\"cover\" content=\"cover-image\"/>",
        ])
    }

    func testKeysMatchCaseInsensitivelyFirstNonEmptyWinsQuotesStripped() {
        XCTAssertEqual(lines("Author:\nAUTHOR: \"Grace Hopper\"\nauthor: Someone Else"), [
            "<dc:creator>Grace Hopper</dc:creator>",
            "<dc:language>en</dc:language>",
        ])
    }

    func testLanguageTagElseEnglish() {
        let cases: [(String, String)] = [
            ("en", "en"), ("pt-BR", "pt-BR"), ("zh-Hant-TW", "zh-Hant-TW"), ("ast", "ast"),
            ("English", "en"), ("e", "en"), ("en_US", "en"), ("en-", "en"), ("ру", "en"),
            ("en-toolongsubtag", "en"),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(metadata("language: \(value)").language, expected, value)
        }
    }

    func testW3CDateKeptOtherwiseLeftOut() {
        for value in ["2026", "2026-10", "2026-10-10", "2026-10-10T09:30Z", "2026-10-10T09:30:15+03:00",
                      "2024-02-29", "2000-02-29", "2026-12-31T23:59:59-11:30"] {
            XCTAssertEqual(metadata("date: \(value)").date, value, value)
        }
        for value in ["10/10/2026", "October 2026", "2026-10-10 09:30", "2026-10-10T09:30", "26-10-10", "２０２６",
                      "2026-13", "2026-00", "2026-10-00", "2026-02-29", "1900-02-29", "2026-04-31",
                      "2026-10-10T24:00Z", "2026-10-10T23:60Z", "2026-10-10T23:59:60Z",
                      "2026-10-10T10:00+24:00", "2026-10-10T10:00+05:60"] {
            XCTAssertNil(metadata("date: \(value)").date, value)
        }
    }

    func testSeriesPositionOnlyForANumberAndOnlyWithASeries() {
        XCTAssertTrue(lines("series: S\nseries_index: 2.5")
            .contains("<meta refines=\"#series\" property=\"group-position\">2.5</meta>"))
        XCTAssertEqual(lines("series: S\nseries_index: two").count, 3)
        XCTAssertEqual(lines("series_index: 3"), ["<dc:language>en</dc:language>"])
    }

    func testEscapesScalarByScalarACombiningMarkHidesNoDelimiter() {
        XCTAssertEqual(lines("author: A &\u{0301} B <\u{0301}\"\u{0301}>").first,
                       "<dc:creator>A &amp;\u{0301} B &lt;\u{0301}&quot;\u{0301}&gt;</dc:creator>")
    }

    func testEscapesAsThePackageDocumentDoesApostropheLeftAlone() {
        XCTAssertEqual(lines("author: O'Brien <ob@example.com>").first,
                       "<dc:creator>O'Brien &lt;ob@example.com&gt;</dc:creator>")
    }

    // MARK: The cover reference

    func testDataImageDecodedOnlyWhenStrictBase64() {
        let b64 = png.base64EncodedString()
        XCTAssertEqual(EpubMetadataReader.coverReference("data:image/png;base64,\(b64)"), .data(png))
        XCTAssertEqual(EpubMetadataReader.coverReference("DATA:image/png;BASE64,\(b64)"), .data(png))
        XCTAssertNil(EpubMetadataReader.coverReference("data:image/svg+xml,<svg/>"))
        XCTAssertNil(EpubMetadataReader.coverReference("data:image/png;base64,"))
        XCTAssertNil(EpubMetadataReader.coverReference("data:image/png;base64,abc"))
        XCTAssertNil(EpubMetadataReader.coverReference("data:image/png;base64,ab!d"))
    }

    func testDataImagePastTheCapIsRefusedBeforeDecoding() {
        var image = Data(count: EpubMetadataReader.maxCoverBytes)
        image.replaceSubrange(0..<png.count, with: png)
        XCTAssertEqual(EpubMetadataReader.coverReference("data:image/png;base64,\(image.base64EncodedString())"),
                       .data(image))
        image.append(contentsOf: [0, 0, 0])
        XCTAssertNil(EpubMetadataReader.coverReference("data:image/png;base64,\(image.base64EncodedString())"))
    }

    func testHttpsOnly() {
        XCTAssertEqual(EpubMetadataReader.coverReference("https://example.com/c.png"),
                       .https(URL(string: "https://example.com/c.png")!))
        XCTAssertEqual(EpubMetadataReader.coverReference("HTTPS://example.com/c.png"),
                       .https(URL(string: "HTTPS://example.com/c.png")!))
        XCTAssertNil(EpubMetadataReader.coverReference("http://example.com/c.png"))
        XCTAssertNil(EpubMetadataReader.coverReference("ftp://example.com/c.png"))
        XCTAssertNil(EpubMetadataReader.coverReference("file:///tmp/c.png"))
    }

    func testRelativePathReadBesideTheDocumentNothingAbsolute() {
        XCTAssertEqual(EpubMetadataReader.coverReference("cover.png"), .local("cover.png"))
        XCTAssertEqual(EpubMetadataReader.coverReference("images/cover.jpg"), .local("images/cover.jpg"))
        XCTAssertEqual(EpubMetadataReader.coverReference("../cover.png"), .local("../cover.png"))
        for value in ["/tmp/cover.png", "\\\\server\\c.png", "C:\\c.png", "c:/c.png", "#cover", "mailto:x", ""] {
            XCTAssertNil(EpubMetadataReader.coverReference(value), value)
        }
        XCTAssertNil(EpubMetadataReader.coverReference(nil))
    }

    // MARK: Recognising a cover by its bytes

    func testKnowsPngJpegGifWebp() {
        XCTAssertEqual(EpubMetadataReader.recogniseCover(png)?.mediaType, "image/png")
        XCTAssertEqual(EpubMetadataReader.recogniseCover(png)?.href, "images/cover.png")
        XCTAssertEqual(EpubMetadataReader.recogniseCover(jpeg)?.href, "images/cover.jpg")
        XCTAssertEqual(EpubMetadataReader.recogniseCover(jpeg)?.mediaType, "image/jpeg")
        XCTAssertEqual(EpubMetadataReader.recogniseCover(gif)?.mediaType, "image/gif")
        XCTAssertEqual(EpubMetadataReader.recogniseCover(webp)?.mediaType, "image/webp")
        XCTAssertEqual(EpubMetadataReader.recogniseCover(webp)?.href, "images/cover.webp")
    }

    func testSkipsAnythingElseEmptyAndOversized() {
        XCTAssertNil(EpubMetadataReader.recogniseCover(Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)))
        XCTAssertNil(EpubMetadataReader.recogniseCover(Data("RIFF\u{24}\u{00}\u{00}\u{00}WAVE".utf8)))
        XCTAssertNil(EpubMetadataReader.recogniseCover(Data([0x89, 0x50, 0x4E, 0x47])))
        XCTAssertNil(EpubMetadataReader.recogniseCover(Data()))
        XCTAssertNil(EpubMetadataReader.recogniseCover(nil))
        var big = Data(count: EpubMetadataReader.maxCoverBytes + 1)
        big.replaceSubrange(0..<png.count, with: png)
        XCTAssertNil(EpubMetadataReader.recogniseCover(big))
    }

    func testCoverRedirectsStayOnHttpsAndStopAfterFive() {
        let delegate = EpubMetadataReader.CoverRedirects()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://example.com/a")!)
        let response = HTTPURLResponse(url: URL(string: "https://example.com/a")!, statusCode: 302,
                                       httpVersion: nil, headerFields: nil)!
        func follow(_ to: String) -> URL? {
            var result: URL?
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                newRequest: URLRequest(url: URL(string: to)!)) { result = $0?.url }
            return result
        }
        XCTAssertNil(follow("http://example.com/b"), "a downgrade is refused before it is requested")
        for hop in 2...5 { XCTAssertNotNil(follow("https://example.com/\(hop)"), "hop \(hop)") }
        XCTAssertNil(follow("https://example.com/6"), "a sixth redirect is refused")
        session.invalidateAndCancel()
    }

    func testCoverItem() {
        XCTAssertEqual(EpubMetadataReader.coverItem(EpubMetadataReader.recogniseCover(jpeg)!),
                       "<item id=\"cover-image\" href=\"images/cover.jpg\" media-type=\"image/jpeg\" properties=\"cover-image\"/>")
    }
}
