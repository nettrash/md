//
//  DocumentExport.swift
//  md
//
//  Created by nettrash on 28/06/2026.
//
//  Print, "share rendered PDF", "export as PDF" and "share source" — the
//  document's output paths — plus the book navigator's whole-book EPUB
//  export (see the EPUB section below).
//
//  Rendering goes through an offscreen `WKWebView` rather than
//  `UIMarkupTextPrintFormatter`, so WebKit lays the page out with the full
//  document CSS. Print and PDF both come out as real A4 pages — the print
//  pipeline paginates line-aware (nothing sliced at a fold) and honors
//  `break-after: page`, so the author's `\newpage` markers cut pages. The
//  pages are plain white with the light ink regardless of the app's
//  appearance: paper tint and dark mode are screen themes (see
//  `MarkdownHTML.css`).
//
//  Presentation is done imperatively against the active scene's window:
//  share sheets and the print panel need correct popover anchoring on iPad,
//  which is fiddly to thread through a SwiftUI `ShareLink`/`fileExporter`
//  when the artifact (a freshly rendered PDF) has to be produced on demand
//  first.
//

import UIKit
import WebKit
import os

/// Trace for the in-app rename, so a rename failure is visible in Console
/// (filter by subsystem `me.nettrash.md`, category `rename`).
private let renameLog = Logger(subsystem: "me.nettrash.md", category: "rename")

/// The print-pipeline pagination did not produce any pages.
private struct PDFAssemblyError: LocalizedError {
    var errorDescription: String? { "The PDF pages could not be assembled." }
}

// MARK: - EPUB (book → .epub)

/// A rich block's snapshot could not be captured for the EPUB.
private struct SnapshotError: LocalizedError {
    var errorDescription: String? { "A rich block's image could not be captured." }
}

/// One article of a book, already read from disk — the navigator reads
/// inside the book's security scope and hands the strings over; nothing
/// in the EPUB pipeline touches the folder again.
struct EpubArticle {
    let title: String
    let source: String
}

struct EpubChapter {
    let title: String
    let articles: [EpubArticle]
}

/// The whole book in reading order — root articles first, then the
/// chapters; the same order the PDF compile uses.
struct EpubBook {
    let title: String
    let rootArticles: [EpubArticle]
    let chapters: [EpubChapter]
}

/// A minimal zip writer: every entry STORED (no compression), correct
/// CRC-32, local headers + central directory + end record. Stored-only is
/// a valid EPUB container — and it keeps the writer a page of code with
/// no dependencies. The one format rule that matters is honored by the
/// *caller*: the `mimetype` entry must come first.
enum StoredZip {

    /// Standard CRC-32 (the zip/PNG polynomial), table-driven.
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func archive(_ entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(out.count)

            // Local file header + payload. A fixed 1980-01-01 timestamp:
            // the OPF carries the real `dcterms:modified`, and a stable
            // archive is easier to test.
            append(&out, UInt32(0x0403_4B50))
            append(&out, UInt16(20))            // version needed
            append(&out, UInt16(0))             // flags
            append(&out, UInt16(0))             // method: stored
            append(&out, UInt16(0))             // DOS time
            append(&out, UInt16(0x21))          // DOS date (1980-01-01)
            append(&out, crc)
            append(&out, size)                  // compressed == uncompressed
            append(&out, size)
            append(&out, UInt16(name.count))
            append(&out, UInt16(0))             // extra length
            out += name
            out += entry.data

            // The matching central-directory record.
            append(&directory, UInt32(0x0201_4B50))
            append(&directory, UInt16(20))      // version made by
            append(&directory, UInt16(20))      // version needed
            append(&directory, UInt16(0))       // flags
            append(&directory, UInt16(0))       // method: stored
            append(&directory, UInt16(0))       // DOS time
            append(&directory, UInt16(0x21))    // DOS date
            append(&directory, crc)
            append(&directory, size)
            append(&directory, size)
            append(&directory, UInt16(name.count))
            append(&directory, UInt16(0))       // extra
            append(&directory, UInt16(0))       // comment
            append(&directory, UInt16(0))       // disk number
            append(&directory, UInt16(0))       // internal attributes
            append(&directory, UInt32(0))       // external attributes
            append(&directory, offset)
            directory += name
        }

        // End of central directory.
        let directoryOffset = UInt32(out.count)
        out += directory
        append(&out, UInt32(0x0605_4B50))
        append(&out, UInt16(0))                 // this disk
        append(&out, UInt16(0))                 // directory disk
        append(&out, UInt16(entries.count))
        append(&out, UInt16(entries.count))
        append(&out, UInt32(directory.count))
        append(&out, directoryOffset)
        append(&out, UInt16(0))                 // comment length
        return out
    }

    private static func append<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

/// The pure string pieces of the EPUB package: container / OPF / nav
/// documents, the per-unit XHTML skeleton, and the HTML→XHTML fixer.
/// No I/O and no WebKit here — all of it is unit-testable.
enum EpubBuilder {

    static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
    </rootfiles>
    </container>
    """

    /// Minimal XML escape for text and attribute content.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The package document: metadata, manifest (nav + stylesheet + every
    /// unit and image), and the spine in reading order.
    static func contentOPF(title: String, identifier: String, modified: String,
                           units: [(id: String, href: String)],
                           images: [String]) -> String {
        let manifest = units.map {
            "<item id=\"\($0.id)\" href=\"\($0.href)\" media-type=\"application/xhtml+xml\"/>"
        } + images.enumerated().map { index, href in
            "<item id=\"img\(index + 1)\" href=\"\(href)\" media-type=\"image/png\"/>"
        }
        let spine = units.map { "<itemref idref=\"\($0.id)\"/>" }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="book-id">\(escape(identifier))</dc:identifier>
        <dc:title>\(escape(title))</dc:title>
        <dc:language>en</dc:language>
        <meta property="dcterms:modified">\(modified)</meta>
        </metadata>
        <manifest>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="css" href="style.css" media-type="text/css"/>
        \(manifest.joined(separator: "\n"))
        </manifest>
        <spine>
        \(spine.joined(separator: "\n"))
        </spine>
        </package>
        """
    }

    /// The EPUB 3 navigation document: root articles first, then each
    /// chapter with its articles as a nested list — display names, same
    /// reading order as the spine.
    static func navXHTML(bookTitle: String,
                         rootArticles: [(title: String, href: String)],
                         chapters: [(title: String, href: String,
                                     articles: [(title: String, href: String)])]) -> String {
        var items = rootArticles.map {
            "<li><a href=\"\($0.href)\">\(escape($0.title))</a></li>"
        }
        for chapter in chapters {
            let link = "<a href=\"\(chapter.href)\">\(escape(chapter.title))</a>"
            if chapter.articles.isEmpty {
                items.append("<li>\(link)</li>")
            } else {
                let nested = chapter.articles
                    .map { "<li><a href=\"\($0.href)\">\(escape($0.title))</a></li>" }
                    .joined(separator: "\n")
                items.append("<li>\(link)\n<ol>\n\(nested)\n</ol>\n</li>")
            }
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head>
        <title>\(escape(bookTitle))</title>
        <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body>
        <nav epub:type="toc">
        <h1>\(escape(bookTitle))</h1>
        <ol>
        \(items.joined(separator: "\n"))
        </ol>
        </nav>
        </body>
        </html>
        """
    }

    /// One content page: the XHTML5 skeleton around an already-fixed body.
    static func page(title: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
        <title>\(escape(title))</title>
        <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    /// Post-process the renderer's HTML into well-formed XHTML: drop
    /// script tags and engine stylesheet links (readers run no scripts —
    /// rich blocks have already been replaced by images), self-close the
    /// void elements, and turn XML-undefined named entities into numeric
    /// references (XHTML has no HTML DTD; only `&amp;`-family names exist).
    static func xhtml(_ html: String) -> String {
        var result = removing(pattern: "<script[^>]*>[\\s\\S]*?</script>", from: html)
        result = removing(pattern: "<link[^>]*>", from: result)
        if let regex = try? NSRegularExpression(
            pattern: "<(br|hr|img|input|meta|source|col|area|base|embed|track|wbr)((?:[^>])*?)\\s*/?>") {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: "<$1$2/>")
        }
        result = result.replacingOccurrences(of: "&bull;", with: "&#8226;")
        result = result.replacingOccurrences(of: "&nbsp;", with: "&#160;")
        return result
    }

    private static func removing(pattern: String, from text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// The inner HTML of a MarkdownHTML document's `<body>`.
    static func bodyContent(ofDocument html: String) -> String {
        guard let open = html.range(of: "<body"),
              let openEnd = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let close = html.range(of: "</body>", options: .backwards) else { return html }
        return String(html[openEnd.upperBound..<close.lowerBound])
    }

    /// The contents of a MarkdownHTML document's `<style>` block.
    static func styleContent(ofDocument html: String) -> String {
        guard let open = html.range(of: "<style>"),
              let close = html.range(of: "</style>") else { return "" }
        return String(html[open.upperBound..<close.lowerBound])
    }

    // MARK: Rich blocks (math / Mermaid / PlantUML)

    enum RichKind { case formula, diagram }

    /// The rich containers exactly as MarkdownHTML emits them. Their
    /// content is fully escaped text (no `<` survives escaping), so the
    /// next matching close tag really is the element's own.
    private static let richContainers: [(open: String, close: String, kind: RichKind)] = [
        ("<span class=\"md-mathi\">", "</span>", .formula),
        ("<span class=\"md-mathd\">", "</span>", .formula),
        ("<div class=\"md-mathd\">", "</div>", .formula),
        ("<pre class=\"mermaid\">", "</pre>", .diagram),
        ("<div class=\"plantuml\">", "</div>", .diagram),
    ]

    /// Every rich element's full range in `html`, in document order —
    /// the same order `querySelectorAll` reports in the rendered DOM, so
    /// the two sides pair up index-for-index.
    static func richElementRanges(in html: String) -> [(range: Range<String.Index>, kind: RichKind)] {
        var results: [(range: Range<String.Index>, kind: RichKind)] = []
        var cursor = html.startIndex
        while cursor < html.endIndex {
            var earliest: (open: Range<String.Index>, close: String, kind: RichKind)?
            for candidate in richContainers {
                if let found = html.range(of: candidate.open, range: cursor..<html.endIndex),
                   earliest == nil || found.lowerBound < earliest!.open.lowerBound {
                    earliest = (found, candidate.close, candidate.kind)
                }
            }
            guard let hit = earliest,
                  let close = html.range(of: hit.close,
                                         range: hit.open.upperBound..<html.endIndex) else { break }
            results.append((hit.open.lowerBound..<close.upperBound, hit.kind))
            cursor = close.upperBound
        }
        return results
    }
}

/// Loads themed HTML into an offscreen web view, then yields a PDF or a
/// print formatter once layout has settled. Hold a strong reference for the
/// duration of the operation — the print formatter keeps using the web view.
@MainActor
final class WebRenderer: NSObject, WKNavigationDelegate {
    /// A4 at 72 dpi (rounded), in points — the width the renderer's web
    /// view lays content out against, and the geometry the EPUB snapshots
    /// measure in.
    static let pageSize = CGSize(width: 595, height: 842)

    /// Real A4 in points (210 × 297 mm at 72 dpi) — the page every shared
    /// / exported PDF paginates to (see `makeA4PDF`).
    static let a4PageSize = CGSize(width: 595.2, height: 841.8)

    private let webView: WKWebView
    private let assets: MdAssetSchemeHandler
    private var onReady: ((Result<Void, Error>) -> Void)?

    override init() {
        let handler = MdAssetSchemeHandler()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: MdAssetSchemeHandler.scheme)
        webView = WKWebView(frame: CGRect(origin: .zero, size: WebRenderer.pageSize),
                            configuration: configuration)
        assets = handler
        super.init()
        webView.navigationDelegate = self
    }

    /// Load `html` and resume once the rich renderers (math / diagrams) have
    /// finished — signalled by `data-md-render-complete` from md-init.js — so
    /// the captured PDF / print output includes them rather than the raw source.
    /// Served through the asset scheme handler so those bundled engines resolve.
    func load(html: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            onReady = { continuation.resume(with: $0) }
            assets.html = html
            webView.load(URLRequest(url: MdAssetSchemeHandler.indexURL))
        }
    }

    /// Capture the rendered document as real A4 pages — the print
    /// pipeline pointed at a PDF context, so a shared / exported PDF is
    /// exactly what printing produces. `UIPrintPageRenderer` drives the
    /// web view's print formatter — the same engine the Print… action
    /// uses — so the breaks are line-aware (no line sliced at a fold) and
    /// the export CSS's `break-after: page` (the author's `\newpage`) is
    /// honored; each page is then drawn into a PDF graphics context.
    func makeA4PDF() throws -> Data {
        let page = CGRect(origin: .zero, size: WebRenderer.a4PageSize)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        // `paperRect` / `printableRect` are read-only properties; KVC is
        // the long-sanctioned way to feed a standalone renderer its page
        // geometry. The printable area is the full page — the export
        // CSS's body padding is the margin, exactly as in the
        // content-tall capture.
        renderer.setValue(NSValue(cgRect: page), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: page), forKey: "printableRect")

        guard renderer.numberOfPages > 0 else { throw PDFAssemblyError() }
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, nil)
        for index in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: index, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    /// The frames of the rich rendered elements (math / Mermaid /
    /// PlantUML) for the EPUB's snapshots, in document order and unscaled
    /// points, after growing the view to its full content height so no
    /// element sits outside the snapshot-able area. The selector matches
    /// exactly the containers `EpubBuilder.richElementRanges` finds in
    /// the source HTML, so the two lists pair up index-for-index.
    func richElementFrames() async -> [CGRect] {
        let height = max(WebRenderer.pageSize.height, await contentHeight())
        webView.frame = CGRect(x: 0, y: 0,
                               width: WebRenderer.pageSize.width, height: height)
        webView.layoutIfNeeded()
        // Same repaint grace as makePDF — snapshotting straight after the
        // resize can capture blank regions.
        try? await Task.sleep(nanoseconds: 300_000_000)
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(
                "Array.from(document.querySelectorAll('.md-mathi, .md-mathd, pre.mermaid, div.plantuml'))" +
                ".map(e => { const r = e.getBoundingClientRect();" +
                " return [r.left + window.scrollX, r.top + window.scrollY, r.width, r.height]; })") { value, _ in
                let rows = value as? [[NSNumber]] ?? []
                continuation.resume(returning: rows.compactMap { row in
                    guard row.count == 4 else { return nil }
                    return CGRect(x: CGFloat(truncating: row[0]),
                                  y: CGFloat(truncating: row[1]),
                                  width: CGFloat(truncating: row[2]),
                                  height: CGFloat(truncating: row[3]))
                })
            }
        }
    }

    /// Snapshot one element's frame, `scale`× its layout size for
    /// crispness (the EPUB's CSS caps display at the layout width).
    func snapshot(rect: CGRect, scale: CGFloat) async throws -> UIImage {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.snapshotWidth = NSNumber(value: Double(rect.width * scale))
        return try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? SnapshotError())
                }
            }
        }
    }

    /// The full height of the laid-out document, in points. Falls back to 0
    /// if the script can't run for some reason.
    private func contentHeight() async -> CGFloat {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { value, _ in
                continuation.resume(returning: (value as? NSNumber).map { CGFloat(truncating: $0) } ?? 0)
            }
        }
    }

    func printFormatter() -> UIPrintFormatter { webView.viewPrintFormatter() }

    // WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        waitForRenderComplete()
    }

    /// Poll until md-init.js flags the document fully rendered (or give up after
    /// a generous cap — Graphviz-backed PlantUML diagrams are slow). Plain docs
    /// and math/Mermaid settle almost immediately.
    private func waitForRenderComplete(attempt: Int = 0) {
        // PlantUML renders sequentially, up to ~20s per Graphviz diagram, so a
        // document with several slow diagrams needs a generous cap.
        let maxAttempts = 480 // ~120s at 0.25s each
        webView.evaluateJavaScript("document.documentElement.getAttribute('data-md-render-complete')") { [weak self] value, _ in
            guard let self else { return }
            if (value as? String) == "1" || attempt >= maxAttempts {
                self.onReady?(.success(())); self.onReady = nil
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.waitForRenderComplete(attempt: attempt + 1)
                }
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onReady?(.failure(error)); onReady = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onReady?(.failure(error)); onReady = nil
    }
}

/// The document output actions, presented against the active window.
@MainActor
enum DocumentExport {

    /// Print the rendered document, themed to match the current appearance.
    static func print(source: String, title: String, dark: Bool) async {
        let html = MarkdownHTML.document(source, title: title, dark: dark, export: true)
        let renderer = WebRenderer()
        do {
            try await renderer.load(html: html)
            let controller = UIPrintInteractionController.shared
            let info = UIPrintInfo.printInfo()
            info.outputType = .general
            info.jobName = title
            controller.printInfo = info
            controller.printFormatter = renderer.printFormatter()
            // Awaiting the presentation keeps `renderer` (and its web view,
            // which the formatter is still reading) alive until printing ends.
            await presentPrint(controller)
        } catch {
            // Rendering failed (malformed HTML is essentially impossible here);
            // nothing actionable to surface to the user.
        }
        withExtendedLifetime(renderer) {}
    }

    /// Render the document to a PDF and offer it through the share sheet.
    static func sharePDF(source: String, title: String, dark: Bool) async {
        let html = MarkdownHTML.document(source, title: title, dark: dark, export: true)
        let renderer = WebRenderer()
        do {
            try await renderer.load(html: html)
            let data = try renderer.makeA4PDF()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(sanitized(title)).pdf")
            try data.write(to: url, options: .atomic)
            presentShare(items: [url])
        } catch {
            // Surface the failure — a silently dead share button after a long
            // render reads as a broken app. (The macOS sibling alerts too.)
            presentMessage(title: "Couldn't Create PDF", message: error.localizedDescription)
        }
        withExtendedLifetime(renderer) {}
    }

    /// Render the document to a PDF and save it where the user chooses, via
    /// the Files export picker. Same rendering as `sharePDF` — only the
    /// destination differs.
    static func exportPDF(source: String, title: String, dark: Bool) async {
        let html = MarkdownHTML.document(source, title: title, dark: dark, export: true)
        let renderer = WebRenderer()
        do {
            try await renderer.load(html: html)
            let data = try renderer.makeA4PDF()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(sanitized(title)).pdf")
            try data.write(to: url, options: .atomic)
            presentExport(url: url)
        } catch {
            // Surface the failure — a silently dead export button after a
            // long render reads as a broken app.
            presentMessage(title: "Couldn't Export PDF", message: error.localizedDescription)
        }
        withExtendedLifetime(renderer) {}
    }

    // MARK: - EPUB export

    /// Build an EPUB 3 of the whole book and save it where the user
    /// chooses, via the Files export picker — the book navigator's
    /// "Export as EPUB…".
    static func exportEPUB(book: EpubBook) async {
        do {
            let data = try await epubData(for: book)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(sanitized(book.title)).epub")
            try data.write(to: url, options: .atomic)
            presentExport(url: url)
        } catch {
            presentMessage(title: "Couldn't Export EPUB", message: error.localizedDescription)
        }
    }

    /// Assemble the EPUB bytes: one XHTML file per unit in reading order
    /// (title page, root articles, then each chapter as a heading page
    /// plus its articles — exactly the PDF compile's order), rich blocks
    /// snapshotted to PNGs, everything packed into a stored zip with the
    /// `mimetype` entry first.
    private static func epubData(for book: EpubBook) async throws -> Data {
        enum Pending {
            case heading(String)
            case article(EpubArticle)
        }
        var pending: [Pending] = [.heading(book.title)]
        pending += book.rootArticles.map(Pending.article)
        for chapter in book.chapters {
            pending.append(.heading(chapter.title))
            pending += chapter.articles.map(Pending.article)
        }

        var units: [(id: String, href: String, title: String, body: String)] = []
        var images: [(href: String, data: Data)] = []
        for item in pending {
            let id = String(format: "u%03d", units.count + 1)
            switch item {
            case .heading(let title):
                units.append((id, "\(id).xhtml", title,
                              "<h1>\(EpubBuilder.escape(title))</h1>"))
            case .article(let article):
                let rendered = try await renderArticleBody(article, unitID: id)
                images += rendered.images
                units.append((id, "\(id).xhtml", article.title, rendered.body))
            }
        }

        // Map the book tree onto the unit files for the nav TOC (the title
        // page is deliberately not a TOC entry).
        var cursor = 1
        let rootNav = book.rootArticles.map { article -> (title: String, href: String) in
            defer { cursor += 1 }
            return (article.title, units[cursor].href)
        }
        let chapterNav = book.chapters.map {
            chapter -> (title: String, href: String, articles: [(title: String, href: String)]) in
            let headingHref = units[cursor].href
            cursor += 1
            let articles = chapter.articles.map { article -> (title: String, href: String) in
                defer { cursor += 1 }
                return (article.title, units[cursor].href)
            }
            return (chapter.title, headingHref, articles)
        }

        let opf = EpubBuilder.contentOPF(
            title: book.title,
            identifier: "urn:uuid:\(UUID().uuidString)",
            modified: ISO8601DateFormatter().string(from: Date()),
            units: units.map { (id: $0.id, href: $0.href) },
            images: images.map(\.href))
        let nav = EpubBuilder.navXHTML(bookTitle: book.title,
                                       rootArticles: rootNav, chapters: chapterNav)

        // The mimetype must be the archive's first, uncompressed entry —
        // it's the magic number readers sniff before unzipping anything.
        var entries: [(name: String, data: Data)] = [
            (name: "mimetype", data: Data("application/epub+zip".utf8)),
            (name: "META-INF/container.xml", data: Data(EpubBuilder.containerXML.utf8)),
            (name: "OEBPS/content.opf", data: Data(opf.utf8)),
            (name: "OEBPS/nav.xhtml", data: Data(nav.utf8)),
            (name: "OEBPS/style.css", data: Data(epubStyle().utf8)),
        ]
        entries += units.map {
            (name: "OEBPS/\($0.href)",
             data: Data(EpubBuilder.page(title: $0.title, body: $0.body).utf8))
        }
        entries += images.map { (name: "OEBPS/\($0.href)", data: $0.data) }
        return StoredZip.archive(entries)
    }

    /// The XHTML body for one article: the shared per-block rendering,
    /// with every rich block (math / Mermaid / PlantUML) rendered by the
    /// offscreen web view — engines and all, waiting for render-complete
    /// like the PDF path — snapshotted, and replaced by a PNG (readers
    /// run no scripts). Articles without rich blocks never touch WebKit.
    private static func renderArticleBody(_ article: EpubArticle, unitID: String)
        async throws -> (body: String, images: [(href: String, data: Data)]) {
        let html = MarkdownHTML.document(article.source, title: article.title,
                                         dark: false, export: true)
        var body = EpubBuilder.bodyContent(ofDocument: html)
        let ranges = EpubBuilder.richElementRanges(in: body)
        var images: [(href: String, data: Data)] = []
        if !ranges.isEmpty {
            let renderer = WebRenderer()
            try await renderer.load(html: html)
            let frames = await renderer.richElementFrames()
            // Snapshot in document order; the string scan and the DOM
            // query find the same containers in the same order, so they
            // pair up index-for-index. A count mismatch or a zero-sized
            // frame leaves that element as its readable source text.
            var replacements: [String?] = Array(repeating: nil, count: ranges.count)
            for (index, entry) in ranges.enumerated() where index < frames.count {
                let frame = frames[index]
                guard frame.width >= 1, frame.height >= 1 else { continue }
                let image = try await renderer.snapshot(rect: frame, scale: 2)
                guard let png = image.pngData() else { continue }
                let href = String(format: "images/%@-%02d.png", unitID, images.count + 1)
                images.append((href, png))
                let alt = entry.kind == .formula ? "formula" : "diagram"
                replacements[index] = "<img src=\"\(href)\" alt=\"\(alt)\" "
                    + "style=\"width:\(Int(frame.width.rounded()))px;max-width:100%\"/>"
            }
            for (index, entry) in ranges.enumerated().reversed() {
                if let tag = replacements[index] {
                    body.replaceSubrange(entry.range, with: tag)
                }
            }
            withExtendedLifetime(renderer) {}
        }
        return (EpubBuilder.xhtml(body), images)
    }

    /// The stylesheet every page links: the export CSS pulled from the
    /// shared document renderer (light theme — readers own dark mode),
    /// minus paper chrome (page-break rules mean nothing to a reflowing
    /// book), plus a cap so the 2× snapshots scale down on narrow screens.
    private static func epubStyle() -> String {
        let document = MarkdownHTML.document("", title: "style", dark: false, export: true)
        return EpubBuilder.styleContent(ofDocument: document)
            + "\n.md-pagebreak { display: none; }\nimg { max-width: 100%; height: auto; }"
    }

    /// Rename the document's file *in place*, keeping it in its real folder.
    /// This is the app's own rename: `DocumentGroup` gives no in-editor rename
    /// on iOS / iPadOS (you'd otherwise have to leave the editor and rename in
    /// the document browser / Files), so we offer one from the toolbar menu.
    ///
    /// Two layers so the UI never stalls and the result is never silent:
    ///  • `renameInPlace` is the synchronous core (validation + coordinated
    ///    move + verification) — this is what the unit tests exercise.
    ///  • `rename(…)` is what the UI awaits: it runs the core *off* the main
    ///    actor and returns the result back on the main actor.
    ///
    /// The coordination runs off the main thread on purpose. The open document
    /// behind `DocumentGroup` is itself an `NSFilePresenter` in *this* process;
    /// an `NSFileCoordinator` `.forMoving` invoked synchronously on the main
    /// thread waits for that presenter to relinquish the file, but the
    /// presenter's own bookkeeping also wants the main thread — so the move can
    /// stall and quietly never happen. Coordinating on a background thread lets
    /// the presenter respond, the move completes, and `item(at:didMoveTo:)`
    /// makes the live `UIDocument` follow the move so `DocumentGroup` re-titles
    /// the window. Returns `nil` on success or a user-facing message on failure.
    static func rename(fileURL: URL, to newBaseName: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            renameInPlace(fileURL: fileURL, to: newBaseName)
        }.value
    }

    /// The synchronous rename core. `nonisolated` so the async wrapper can run
    /// it off the main actor; it only touches thread-safe file APIs and holds
    /// no main-actor state. Safe to call directly (the tests do).
    nonisolated static func renameInPlace(fileURL: URL, to newBaseName: String) -> String? {
        let trimmed = newBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "The name can’t be empty." }
        // Don't let the user type a path; a rename stays in the same folder.
        guard !trimmed.contains("/"), !trimmed.contains(":") else {
            return "A name can’t contain “/” or “:”."
        }

        let ext = fileURL.pathExtension
        var newURL = fileURL.deletingLastPathComponent().appendingPathComponent(trimmed)
        if !ext.isEmpty, newURL.pathExtension.caseInsensitiveCompare(ext) != .orderedSame {
            newURL.appendPathExtension(ext)
        }
        guard newURL != fileURL else { return nil }          // no-op rename
        if FileManager.default.fileExists(atPath: newURL.path) {
            return "“\(newURL.lastPathComponent)” already exists in this folder."
        }

        // The in-place file may be security-scoped; hold the scope across the move.
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        renameLog.log("rename start: \(fileURL.path, privacy: .public) -> \(newURL.path, privacy: .public) scoped=\(scoped)")

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var moveError: Error?
        coordinator.coordinate(writingItemAt: fileURL, options: .forMoving,
                               writingItemAt: newURL, options: .forReplacing,
                               error: &coordinationError) { from, to in
            do {
                try FileManager.default.moveItem(at: from, to: to)
                // Tell the open document's file presenter it moved, so the
                // editor keeps pointing at the renamed file.
                coordinator.item(at: from, didMoveTo: to)
            } catch {
                moveError = error
            }
        }
        if let error = (moveError ?? coordinationError) as NSError? {
            renameLog.error("rename failed: \(error.domain, privacy: .public) \(error.code) \(error.localizedDescription, privacy: .public)")
            // Surface the domain/code too — it pinpoints the cause (e.g. a
            // sandbox denial is NSCocoaErrorDomain 513 / 257).
            return "\(error.localizedDescription)\n[\(error.domain) \(error.code)]"
        }
        // Verify the move actually took effect. A coordinated move can report
        // *no error* yet not happen — e.g. the open document is holding the
        // file — so we check rather than trust a nil error.
        let newExists = FileManager.default.fileExists(atPath: newURL.path)
        let oldExists = FileManager.default.fileExists(atPath: fileURL.path)
        renameLog.log("post-move newExists=\(newExists) oldExists=\(oldExists) new=\(newURL.path, privacy: .public)")
        if !newExists {
            return "No error was reported, but “\(newURL.lastPathComponent)” is not on disk — the move didn’t take effect (the open document may be holding the file)."
        }
        if oldExists {
            return "“\(newURL.lastPathComponent)” was created, but the old “\(fileURL.lastPathComponent)” is still there too — the open document keeps rewriting it."
        }
        return nil
    }

    /// Prompt for a new name and perform the rename. Uses a UIKit
    /// `UIAlertController` text field, reading `textField.text` in the action
    /// handler — reliable across iPhone and iPad.
    static func promptRename(fileURL: URL, currentBaseName: String) {
        guard let presenter = topViewController() else {
            renameLog.error("promptRename: no presenter")
            return
        }
        let alert = UIAlertController(
            title: "Rename Document",
            message: "Enter a new name. The file keeps its place and extension.",
            preferredStyle: .alert)
        // Capture the text field strongly so the action handler reads the
        // current typed value directly.
        var nameField: UITextField!
        alert.addTextField { field in
            field.text = currentBaseName
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.returnKeyType = .done
            nameField = field
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { _ in
            let typed = nameField.text ?? ""
            renameLog.log("Rename tapped: typed=\(typed, privacy: .public)")
            // Await the off-main rename, then report on the main actor. By the
            // time this resumes the rename alert has fully dismissed, so the
            // result alert presents reliably (no fragile fixed delay).
            Task { @MainActor in
                let result = await rename(fileURL: fileURL, to: typed)
                let title = result == nil ? "Renamed" : "Couldn’t Rename"
                let message = result ?? "Renamed to “\(typed)”."
                presentMessage(title: title, message: message)
            }
        })
        presenter.present(alert, animated: true)
    }

    private static func presentMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presentAlert(alert)
    }

    /// Present a modal alert against the active window, retrying once if no
    /// window is key/foreground for a beat (a scene transition can momentarily
    /// leave no presenter, which would otherwise silently drop the result).
    private static func presentAlert(_ alert: UIAlertController, retry: Bool = true) {
        guard let presenter = topViewController() else {
            if retry {
                // Stay on the main actor (no Sendable crossing of the UIKit
                // alert) and try once more after the transition settles.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    presentAlert(alert, retry: false)
                }
            } else {
                renameLog.error("presentAlert: no presenter")
            }
            return
        }
        presenter.present(alert, animated: true)
    }

    /// Share the raw Markdown source. Shares the real file when it has been
    /// saved (so the filename and location are preserved); otherwise writes
    /// the current text to a temporary `.md` and shares that.
    static func shareSource(fileURL: URL?, text: String, title: String) {
        if let fileURL {
            presentShare(items: [fileURL])
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sanitized(title)).md")
        try? Data(text.utf8).write(to: url, options: .atomic)
        presentShare(items: [url])
    }

    // MARK: - Presentation

    /// Hand a freshly written temp file to the Files export picker.
    /// `forExporting` *moves* it to wherever the user picks; no delegate is
    /// needed — cancelling just leaves the temp copy for the system to clean.
    private static func presentExport(url: URL) {
        guard let presenter = topViewController() else { return }
        let picker = UIDocumentPickerViewController(forExporting: [url])
        presenter.present(picker, animated: true)
    }

    private static func presentShare(items: [Any]) {
        guard let presenter = topViewController(), let anchor = presenter.view else { return }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = anchor
            popover.sourceRect = CGRect(x: anchor.bounds.maxX - 60,
                                        y: anchor.safeAreaInsets.top + 8, width: 1, height: 1)
            popover.permittedArrowDirections = [.up]
        }
        presenter.present(activity, animated: true)
    }

    private static func presentPrint(_ controller: UIPrintInteractionController) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard let anchor = topViewController()?.view else {
                continuation.resume(); return
            }
            // `present(from:in:…)` anchors the popover on iPad and is ignored
            // on iPhone, where the panel is modal.
            controller.present(from: CGRect(x: anchor.bounds.maxX - 60,
                                            y: anchor.safeAreaInsets.top + 8, width: 1, height: 1),
                               in: anchor, animated: true) { _, _, _ in
                continuation.resume()
            }
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    /// Make a string safe to use as a file name.
    private static func sanitized(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Document" : cleaned
    }
}
