//
//  EpubMetadata.swift
//  md
//
//  An EPUB's metadata and cover from the document's front matter — the same
//  file, byte for byte, in md and md.macOS, as SmartTyping.swift is.
//
//  The package document used to carry a title, an identifier and a language
//  fixed at "en", and nothing else: a book exported from md reached a reader's
//  library with no author, no date and no cover. From 1.6 every md EPUB writer
//  — iPhone and iPad, Mac, Android, Windows and VS Code — reads these
//  front-matter keys, with the same rules, into the same lines in the same
//  order:
//
//    author        → <dc:creator>
//    language      → <dc:language>, when it is a language tag; otherwise "en"
//    date          → <dc:date>, when it is a real W3C date; otherwise left out
//    description   → <dc:description>
//    series        → a belongs-to-collection of collection-type "series",
//    series_index    with its group-position when the index is a number
//    cover         → a cover-image item, when the image can be read
//
//  A key is matched as `title:` already is (`documentTitle`): case-
//  insensitively, the first non-empty value winning, trimmed of whitespace and
//  newlines. Every test is spelled over ASCII units here rather than asked of
//  a regex or a Character class, so "a digit" means 0–9 in every port.
//
//  The cover is the one key that needs reading. It is used when its bytes can
//  be had — a `data:` image, an `https:` image, or a file beside the document
//  that md can already reach — and are a PNG, JPEG, GIF or WebP by their own
//  magic numbers; anything else is skipped silently and the book is written
//  without a cover. The reading is the caller's; this file only classifies
//  the reference and the bytes.
//
//  Single-document EPUBs only: a book's package document keeps the defaults
//  (book metadata is a later release's work). With no front matter the lines
//  are exactly the `<dc:language>en</dc:language>` every md EPUB has always
//  carried, so the package document is byte-identical to 1.5.
//

import Foundation

/// What a document's front matter adds to its package document.
struct EpubMetadata: Equatable {
    var creator: String?
    /// Always set: the front matter's tag, or "en".
    var language: String = "en"
    var date: String?
    var description: String?
    var series: String?
    var seriesIndex: String?

    /// The package document as it always was.
    static let defaults = EpubMetadata()
}

/// A cover image, recognised by its bytes.
struct EpubCover: Equatable {
    /// `png`, `jpg`, `gif` or `webp` — the archive name is `images/cover.<extension>`.
    let fileExtension: String
    let mediaType: String
    let data: Data

    /// The cover's path inside OEBPS/.
    var href: String { "images/cover.\(fileExtension)" }
}

/// Where a `cover:` value says the image is.
enum EpubCoverReference: Equatable {
    case data(Data)
    case https(URL)
    case local(String)
}

enum EpubMetadataReader {

    /// A cover larger than this is skipped: a reader shows a thumbnail, not a poster.
    static let maxCoverBytes = 20 * 1024 * 1024

    /// An `https:` cover is given this long to arrive.
    static let coverTimeout: TimeInterval = 15

    // MARK: Front matter

    /// The first non-empty value of `key`, matched case-insensitively —
    /// `documentTitle`'s rule.
    static func fieldValue(_ fields: [MetadataField], _ key: String) -> String? {
        for field in fields where field.key.caseInsensitiveCompare(key) == .orderedSame {
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// The package document's metadata from a document's front matter.
    static func metadata(from fields: [MetadataField]) -> EpubMetadata {
        var metadata = EpubMetadata()
        metadata.creator = fieldValue(fields, "author")
        if let language = fieldValue(fields, "language"), isLanguageTag(language) {
            metadata.language = language
        }
        if let date = fieldValue(fields, "date"), isW3CDate(date) {
            metadata.date = date
        }
        metadata.description = fieldValue(fields, "description")
        metadata.series = fieldValue(fields, "series")
        if metadata.series != nil, let index = fieldValue(fields, "series_index"), isSeriesIndex(index) {
            metadata.seriesIndex = index
        }
        return metadata
    }

    // MARK: Validation, over ASCII units

    private static func units(_ s: String) -> [UInt16] { Array(s.utf16) }
    private static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func isLetter(_ c: UInt16) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }

    /// A BCP 47-shaped tag: `^[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8})*$` — `en`, `pt-BR`, `zh-Hant-TW`.
    static func isLanguageTag(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false).map { units(String($0)) }
        guard let first = parts.first, (2...3).contains(first.count), first.allSatisfy(isLetter) else { return false }
        for part in parts.dropFirst() {
            guard (1...8).contains(part.count), part.allSatisfy({ isLetter($0) || isDigit($0) }) else { return false }
        }
        return true
    }

    /// A position in a series: `^[0-9]+(\.[0-9]+)?$` — `3`, `2.5`.
    static func isSeriesIndex(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { units(String($0)) }
        guard (1...2).contains(parts.count) else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(isDigit) }
    }

    /// W3CDTF, which is what EPUB asks of dc:date — `YYYY`, `YYYY-MM`,
    /// `YYYY-MM-DD`, or `YYYY-MM-DDThh:mm[:ss](Z|±hh:mm)` — and a real one:
    /// month 01–12, a day that month has (Gregorian leap years), hour 00–23,
    /// minute and second 00–59, a zone offset of 00–23 hours and 00–59 minutes.
    static func isW3CDate(_ s: String) -> Bool {
        let u = units(s)
        func number(_ from: Int, _ count: Int) -> Int? {
            guard from + count <= u.count else { return nil }
            var value = 0
            for c in u[from..<(from + count)] {
                guard isDigit(c) else { return nil }
                value = value * 10 + Int(c - 0x30)
            }
            return value
        }
        func at(_ i: Int, _ c: Character) -> Bool { i < u.count && u[i] == c.utf16.first! }

        guard let year = number(0, 4) else { return false }
        if u.count == 4 { return true }
        guard at(4, "-"), let month = number(5, 2), (1...12).contains(month) else { return false }
        if u.count == 7 { return true }
        guard at(7, "-"), let day = number(8, 2) else { return false }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        guard (1...days).contains(day) else { return false }
        if u.count == 10 { return true }
        guard at(10, "T"), let hour = number(11, 2), hour <= 23,
              at(13, ":"), let minute = number(14, 2), minute <= 59 else { return false }
        var i = 16
        if at(i, ":") {
            guard let second = number(i + 1, 2), second <= 59 else { return false }
            i += 3
        }
        if at(i, "Z") { return i + 1 == u.count }
        guard at(i, "+") || at(i, "-"), let zoneHour = number(i + 1, 2), zoneHour <= 23,
              at(i + 3, ":"), let zoneMinute = number(i + 4, 2), zoneMinute <= 59 else { return false }
        return i + 6 == u.count
    }

    // MARK: The cover

    private static func hasASCIIPrefixIgnoringCase(_ s: String, _ prefix: String) -> Bool {
        let a = units(s), b = units(prefix)
        guard a.count >= b.count else { return false }
        for k in 0..<b.count {
            var c = a[k]
            if c >= 0x41 && c <= 0x5A { c += 32 }
            if c != b[k] { return false }
        }
        return true
    }

    /// Classify a `cover:` value, or nil when it can never be read: a `data:`
    /// URI that is not strict base64, an `http:` or any other scheme, an
    /// absolute path, a fragment. A `data:` image is decoded here.
    static func coverReference(_ value: String?) -> EpubCoverReference? {
        guard let value, !value.isEmpty else { return nil }
        let u = units(value)
        if hasASCIIPrefixIgnoringCase(value, "data:") {
            guard let comma = u.firstIndex(of: 0x2C) else { return nil }
            // The header must end in `;base64`, in any case.
            let marker = units(";base64")
            guard comma - 5 >= marker.count else { return nil }
            for k in 0..<marker.count {
                var c = u[comma - marker.count + k]
                if c >= 0x41 && c <= 0x5A { c += 32 }
                guard c == marker[k] else { return nil }
            }
            // Strict base64: `^[A-Za-z0-9+/]*={0,2}$`, a whole number of quads.
            let length = u.count - comma - 1
            guard length > 0, length % 4 == 0 else { return nil }
            // Past the cover cap once decoded: refused before the payload is
            // copied or a byte of it decoded.
            guard length / 4 * 3 <= maxCoverBytes + 2 else { return nil }
            let payload = Array(u[(comma + 1)...])
            var padding = 0
            for c in payload {
                if c == 0x3D { padding += 1; continue }
                guard padding == 0, isLetter(c) || isDigit(c) || c == 0x2B || c == 0x2F else { return nil }
            }
            guard padding <= 2, let data = Data(base64Encoded: String(decoding: payload, as: UTF16.self)) else { return nil }
            return .data(data)
        }
        if hasASCIIPrefixIgnoringCase(value, "https://") {
            guard let url = URL(string: value) else { return nil }
            return .https(url)
        }
        if value.contains("://") { return nil }
        // A scheme: `^[A-Za-z][A-Za-z0-9+.-]*:` — which also catches a drive letter.
        if let first = u.first, isLetter(first) {
            var k = 1
            while k < u.count, isLetter(u[k]) || isDigit(u[k]) || u[k] == 0x2B || u[k] == 0x2E || u[k] == 0x2D { k += 1 }
            if k < u.count, u[k] == 0x3A { return nil }
        }
        if let first = u.first, first == 0x2F || first == 0x5C || first == 0x23 { return nil }
        return .local(value)
    }

    /// A cover from its bytes: PNG, JPEG, GIF or WebP by magic number, no larger than the cap.
    static func recogniseCover(_ data: Data?) -> EpubCover? {
        guard let data, !data.isEmpty, data.count <= maxCoverBytes else { return nil }
        let bytes = [UInt8](data.prefix(12))
        func at(_ offset: Int, _ magic: [UInt8]) -> Bool {
            bytes.count >= offset + magic.count && Array(bytes[offset..<(offset + magic.count)]) == magic
        }
        if at(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return EpubCover(fileExtension: "png", mediaType: "image/png", data: data)
        }
        if at(0, [0xFF, 0xD8, 0xFF]) {
            return EpubCover(fileExtension: "jpg", mediaType: "image/jpeg", data: data)
        }
        if at(0, Array("GIF87a".utf8)) || at(0, Array("GIF89a".utf8)) {
            return EpubCover(fileExtension: "gif", mediaType: "image/gif", data: data)
        }
        if at(0, Array("RIFF".utf8)) && at(8, Array("WEBP".utf8)) {
            return EpubCover(fileExtension: "webp", mediaType: "image/webp", data: data)
        }
        return nil
    }

    /// The most redirects an `https:` cover may take.
    static let maxCoverRedirects = 5

    /// Fetch an `https:` cover: 15 seconds in all, 20 MB at most, and at most
    /// five redirects, each refused before it is requested unless it stays on
    /// https (`CoverRedirects`). Any failure is nil — the book goes out
    /// without a cover.
    static func fetchCover(_ url: URL) async -> EpubCover? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = coverTimeout
        configuration.timeoutIntervalForResource = coverTimeout
        let redirects = CoverRedirects()
        let session = URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let (bytes, response) = try? await session.bytes(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url?.scheme?.lowercased() == "https",
              http.expectedContentLength <= Int64(maxCoverBytes) else { return nil }
        // Read no more than one byte past the cap, so a huge body is refused
        // without being held.
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxCoverBytes { return nil }
            }
        } catch {
            return nil
        }
        return recogniseCover(data)
    }

    /// Follows a redirect only while it stays on https and only five times:
    /// the new request is refused — `nil` — before it is made, so the session
    /// hands back the redirect response itself, which is not a 2xx and so no
    /// cover. A relative `Location` has already been resolved against the
    /// current URL by the time the delegate sees it.
    final class CoverRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var hops = 0

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            lock.lock()
            hops += 1
            let allowed = hops <= EpubMetadataReader.maxCoverRedirects
            lock.unlock()
            completionHandler(allowed && request.url?.scheme?.lowercased() == "https" ? request : nil)
        }
    }

    // MARK: The package document's lines

    /// The family's XML escape — `&`, `<`, `>`, `"`; never `'`.
    static func escape(_ s: String) -> String {
        ScalarText.escapingMarkup(s)
    }

    /// The metadata lines between `<dc:title>` and `dcterms:modified` —
    /// identical text in all five md EPUB writers.
    static func metadataLines(_ metadata: EpubMetadata, cover: EpubCover?) -> [String] {
        var lines: [String] = []
        if let creator = metadata.creator { lines.append("<dc:creator>\(escape(creator))</dc:creator>") }
        lines.append("<dc:language>\(escape(metadata.language))</dc:language>")
        if let date = metadata.date { lines.append("<dc:date>\(escape(date))</dc:date>") }
        if let description = metadata.description {
            lines.append("<dc:description>\(escape(description))</dc:description>")
        }
        if let series = metadata.series {
            lines.append("<meta property=\"belongs-to-collection\" id=\"series\">\(escape(series))</meta>")
            lines.append("<meta refines=\"#series\" property=\"collection-type\">series</meta>")
            if let index = metadata.seriesIndex {
                lines.append("<meta refines=\"#series\" property=\"group-position\">\(escape(index))</meta>")
            }
        }
        // EPUB 3 finds the cover by the manifest property; this EPUB 2 meta is
        // for the readers — Kindle's converter among them — that still look for it.
        if cover != nil { lines.append("<meta name=\"cover\" content=\"cover-image\"/>") }
        return lines
    }

    /// The cover's manifest item, the last item of every md EPUB that has one.
    static func coverItem(_ cover: EpubCover) -> String {
        "<item id=\"cover-image\" href=\"\(cover.href)\" media-type=\"\(cover.mediaType)\" properties=\"cover-image\"/>"
    }
}
