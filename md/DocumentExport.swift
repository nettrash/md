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

import CryptoKit
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

    /// A stable identifier for a book, derived from its title — an RFC 4122
    /// version 5 (name-based) UUID in the standard URL namespace.
    ///
    /// EPUB's `dc:identifier` is what a reader uses to decide whether two
    /// files are the same publication. A fresh random UUID on every export
    /// means every export is a *different* book: re-exporting after fixing a
    /// typo stacks up beside the old one in Apple Books instead of replacing
    /// it, and a store that expects a stable identifier across releases —
    /// KDP, Kobo — cannot accept the file at all. Deriving it from the title
    /// makes the same book export to the same identifier every time, on every
    /// platform, with nothing to store alongside the folder.
    ///
    /// Renaming the book does change it, which is the right answer: to a
    /// reader's library that is a different publication.
    static func stableIdentifier(forTitle title: String) -> String {
        // The URL namespace from RFC 4122 §Appendix C.
        let namespace: [UInt8] = [0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1,
                                  0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8]
        var input = Data(namespace)
        input.append(Data(title.utf8))

        var bytes = Array(Insecure.SHA1.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant

        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let groups = [hex.prefix(8),
                      hex.dropFirst(8).prefix(4),
                      hex.dropFirst(12).prefix(4),
                      hex.dropFirst(16).prefix(4),
                      hex.dropFirst(20)]
        return "urn:uuid:" + groups.joined(separator: "-")
    }

    /// The EPUB title for a single document: the front-matter `title:` field
    /// if the author gave a non-empty one, else the file name.
    ///
    /// A book takes its title from its folder name; a lone document has no
    /// folder, so the file name is the closest thing to a title it has — and
    /// the title is also what `stableIdentifier` hashes, so two exports of the
    /// same document (same front matter, same file name) reach the same
    /// identifier. The key match is case-insensitive because generators write
    /// `title:` and `Title:` alike; the first non-empty one wins, matching how
    /// a duplicate key is otherwise resolved.
    static func documentTitle(frontMatter: [MetadataField], fileName: String) -> String {
        for field in frontMatter
        where field.key.caseInsensitiveCompare("title") == .orderedSame {
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return fileName
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

    // MARK: Rich blocks (math / Mermaid / Graphviz / PlantUML)

    enum RichKind { case formula, diagram }

    /// The rich containers exactly as MarkdownHTML emits them. Their
    /// content is fully escaped text (no `<` survives escaping), so the
    /// next matching close tag really is the element's own.
    ///
    /// The Graphviz opener is deliberately the tag *prefix*, without its
    /// `>`: MarkdownHTML writes the layout program into the tag
    /// (`<div class="graphviz" data-engine="dot">`, `…"neato">`, …), so a
    /// whole-tag literal would match only one of the nine engines and the
    /// rest would ship to the reader as raw DOT source. Everything after
    /// the prefix is still inside the element, so the close-tag search
    /// below is unaffected.
    private static let richContainers: [(open: String, close: String, kind: RichKind)] = [
        ("<span class=\"md-mathi\">", "</span>", .formula),
        ("<span class=\"md-mathd\">", "</span>", .formula),
        ("<div class=\"md-mathd\">", "</div>", .formula),
        ("<pre class=\"mermaid\">", "</pre>", .diagram),
        ("<div class=\"plantuml\">", "</div>", .diagram),
        ("<div class=\"graphviz\"", "</div>", .diagram),
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

// MARK: - Diagram → standalone SVG (Feature 1)

/// The pure pieces of "export one diagram as a real vector `.svg` file":
/// which blocks a document offers, and the fix-up that turns a diagram's
/// rendered root `<svg>` (read out of the offscreen DOM as outerHTML) into a
/// self-standing SVG document. No WebKit and no I/O here — all of it is
/// unit-testable.
///
/// Only the three *diagram* engines qualify — Mermaid, Graphviz and PlantUML
/// each render to an inline `<svg>`. Math does **not**: KaTeX lays a formula
/// out as HTML + CSS, never SVG, so a formula has no vector to export and is
/// deliberately never offered.
enum DiagramSVG {

    /// One diagram the document offers for SVG export, in document order.
    struct Diagram: Equatable {
        /// 0-based position among the document's diagrams — the same order
        /// `querySelectorAll('pre.mermaid, div.plantuml, div.graphviz')`
        /// reports the rendered containers in, so the capture step pulls the
        /// matching `<svg>` back out by this index. (The DOM query and this
        /// list both walk the document in order and both see only diagrams,
        /// so they pair up index-for-index — the same pairing the EPUB path
        /// relies on between `richElementRanges` and `richElementFrames`,
        /// minus the formulas neither of us can export.)
        let ordinal: Int
        let kind: Kind
        /// The Graphviz layout program (`dot` / `neato` / …) for a
        /// `.graphviz` diagram; nil for the others. Only for the menu label.
        let engine: String?
        /// A short label lifted from the diagram's source — its first
        /// non-empty line — so a reader can tell two diagrams apart in the
        /// menu. Empty when the source has no non-blank line.
        let label: String

        enum Kind: String { case mermaid, plantuml, graphviz }

        /// The engine's display name, naming the Graphviz layout when it is
        /// not the default `dot` (a `neato` graph reads quite differently).
        var typeName: String {
            switch kind {
            case .mermaid: return "Mermaid"
            case .plantuml: return "PlantUML"
            case .graphviz:
                if let engine, engine != "dot" { return "Graphviz (\(engine))" }
                return "Graphviz"
            }
        }

        /// The menu row: the type, plus the source label when there is one.
        var menuTitle: String {
            label.isEmpty ? typeName : "\(typeName): \(label)"
        }
    }

    /// The diagrams a document offers, in document order.
    ///
    /// Mirrors exactly how `MarkdownHTML` decides what becomes a diagram, so
    /// this list pairs index-for-index with the rendered DOM's diagram
    /// containers:
    ///  • a raw `.puml` / `.gv` document is one diagram — the whole file (see
    ///    `MarkdownHTML.document`, which renders it without parsing Markdown);
    ///  • otherwise every fenced block whose info string names Mermaid,
    ///    PlantUML or a Graphviz layout — including one nested in a block
    ///    quote, which `MarkdownHTML` renders by recursing into the quote, so
    ///    the walk recurses too and the quoted diagram keeps its place.
    /// Math fences and every other code block are skipped: a formula is not
    /// SVG, and ordinary code is not a diagram.
    static func diagrams(inSource source: String) -> [Diagram] {
        if MarkdownHTML.isRawPlantUML(source) {
            return [Diagram(ordinal: 0, kind: .plantuml, engine: nil,
                            label: firstLine(of: source))]
        }
        if MarkdownHTML.isRawGraphviz(source) {
            return [Diagram(ordinal: 0, kind: .graphviz, engine: "dot",
                            label: firstLine(of: source))]
        }
        var diagrams: [Diagram] = []
        appendDiagrams(in: MarkdownParser.parse(source), into: &diagrams)
        return diagrams
    }

    /// Walk a block list in render order, appending each diagram; recurse into
    /// block quotes so a quoted diagram lands in its document-order place
    /// (MarkdownHTML renders quoted blocks in line).
    private static func appendDiagrams(in blocks: [MarkdownBlock], into out: inout [Diagram]) {
        for block in blocks {
            switch block.kind {
            case let .codeBlock(language, code):
                guard let classified = classify(language) else { continue }
                out.append(Diagram(ordinal: out.count, kind: classified.kind,
                                   engine: classified.engine, label: firstLine(of: code)))
            case let .quote(inner):
                appendDiagrams(in: inner, into: &out)
            default:
                continue
            }
        }
    }

    /// Classify a fence info string the way `MarkdownHTML.renderBlock` does —
    /// lower-cased, the same three families, the same Graphviz alias table —
    /// or nil for anything that is not a diagram (math, csv, plain code).
    /// Reusing `MarkdownHTML.graphvizEngines` keeps the two in lockstep: a
    /// layout added there is offered here without a second edit.
    private static func classify(_ language: String?) -> (kind: Diagram.Kind, engine: String?)? {
        switch (language ?? "").lowercased() {
        case "mermaid":
            return (.mermaid, nil)
        case "plantuml", "puml", "plant-uml":
            return (.plantuml, nil)
        case let lang where MarkdownHTML.graphvizEngines[lang] != nil:
            return (.graphviz, MarkdownHTML.graphvizEngines[lang])
        default:
            return nil
        }
    }

    /// The first non-empty line of `source`, trimmed and capped so one long
    /// line can't dwarf the menu. Purely cosmetic — a human reads it, nothing
    /// re-parses it — so ordinary `String` line splitting is fine here.
    private static func firstLine(of source: String) -> String {
        for line in source.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return trimmed.count > 40
                    ? trimmed.prefix(40).trimmingCharacters(in: .whitespaces) + "…"
                    : trimmed
            }
        }
        return ""
    }

    // MARK: SVG fix-up

    /// Turn a diagram's rendered root `<svg …>…</svg>` (read from the DOM as
    /// outerHTML) into a standalone `.svg` document: guarantee the SVG
    /// namespace, give an unsized root real pixel dimensions from its
    /// `viewBox`, and prepend the XML prolog so the file is a well-formed
    /// standalone document any browser or vector editor opens.
    ///
    /// Mermaid emits `width="100%"` and no `height` — fine inside a flowing
    /// page (the page CSS caps it), useless in a file, where it renders at
    /// zero or full-viewport height. Graphviz and PlantUML already write
    /// absolute `width`/`height`, so those are left exactly as the engine drew
    /// them.
    ///
    /// String scanning (not `ScalarText`) throughout, matching how the sibling
    /// `EpubBuilder` reads this same engine-generated markup: the input is a
    /// serializer's ASCII tag syntax, never author prose, so there is no
    /// combining-mark hazard to guard against.
    static func standaloneDocument(fromSVG svg: String) -> String {
        let fixed = withResolvedSize(inNamespaced(svg))
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + fixed
    }

    /// The root `<svg …>` opening tag's range (from `<svg` to the first `>`),
    /// or nil if there isn't one. Engine outerHTML never puts a `>` inside the
    /// root tag's attribute values, so the first `>` really does close it.
    private static func openingTagRange(of svg: String) -> Range<String.Index>? {
        guard let open = svg.range(of: "<svg"),
              let close = svg.range(of: ">", range: open.upperBound..<svg.endIndex) else { return nil }
        return open.lowerBound..<close.upperBound
    }

    /// Ensure the root carries the default SVG namespace so the standalone
    /// file is well-formed. Both engines already declare it, but a file must
    /// not lean on that.
    private static func inNamespaced(_ svg: String) -> String {
        guard let tagRange = openingTagRange(of: svg) else { return svg }
        if attribute("xmlns", in: String(svg[tagRange])) != nil { return svg }
        var result = svg
        // Right after `<svg`, before the other attributes.
        result.insert(contentsOf: " xmlns=\"http://www.w3.org/2000/svg\"",
                      at: svg.index(tagRange.lowerBound, offsetBy: 4))
        return result
    }

    /// Give the root real dimensions when it lacks them. If both `width` and
    /// `height` are already absolute lengths the engine sized it (Graphviz,
    /// PlantUML) — leave it untouched. Otherwise, when a 4-number `viewBox` is
    /// present, set `width`/`height` to the viewBox's own width and height,
    /// which is what makes a Mermaid `width="100%"` file open at its true size.
    private static func withResolvedSize(_ svg: String) -> String {
        guard let tagRange = openingTagRange(of: svg) else { return svg }
        let tag = String(svg[tagRange])
        if isAbsoluteLength(attribute("width", in: tag)),
           isAbsoluteLength(attribute("height", in: tag)) { return svg }
        guard let box = viewBox(in: tag), box.count == 4 else { return svg }
        var newTag = setAttribute("width", to: box[2], in: tag)
        newTag = setAttribute("height", to: box[3], in: newTag)
        return svg.replacingCharacters(in: tagRange, with: newTag)
    }

    /// The value range of a whole attribute `name="…"` (or `name='…'`) inside
    /// an opening tag. The leading space is load-bearing: it matches only a
    /// whole attribute, so `width` never captures `stroke-width`.
    private static func attributeValueRange(_ name: String, in tag: String)
        -> Range<String.Index>? {
        for quote in ["\"", "'"] {
            if let key = tag.range(of: " \(name)=\(quote)"),
               let close = tag.range(of: quote, range: key.upperBound..<tag.endIndex) {
                return key.upperBound..<close.lowerBound
            }
        }
        return nil
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        attributeValueRange(name, in: tag).map { String(tag[$0]) }
    }

    /// Set `name`'s value, or add `name="value"` after `<svg` when absent.
    private static func setAttribute(_ name: String, to value: String, in tag: String) -> String {
        if let range = attributeValueRange(name, in: tag) {
            return tag.replacingCharacters(in: range, with: value)
        }
        var result = tag
        result.insert(contentsOf: " \(name)=\"\(value)\"",
                      at: result.index(result.startIndex, offsetBy: 4))  // past "<svg"
        return result
    }

    /// Whether an attribute value is an absolute SVG length: present, and a
    /// number (optionally with a unit like `pt`/`px`), but not a percentage.
    /// A missing value and `width="100%"` are both "not absolute", which is
    /// exactly what makes a Mermaid root get resized and a Graphviz root not.
    private static func isAbsoluteLength(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty, !value.hasSuffix("%") else { return false }
        return value.first.map { $0 == "." || $0.isNumber } ?? false
    }

    /// The `viewBox`'s space/comma-separated tokens, or nil.
    private static func viewBox(in tag: String) -> [String]? {
        attribute("viewBox", in: tag)?
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init)
    }
}

// MARK: - PDF page size (trim sizes)

/// A named PDF page ("trim") size in PostScript points — 1 inch = 72 pt.
///
/// This small table is the *single source of truth* the three platforms copy
/// verbatim (iOS feeds it to `paperRect`/`printableRect`, macOS to
/// `NSPrintInfo.paperSize`, Android builds a custom `MediaSize` from it), so the
/// numbers must live in exactly one place per platform and never be typed twice
/// — a drift here would paginate the same document differently on iOS than on
/// Android.
///
/// A4 keeps the historical `595.2 × 841.8` (210 × 297 mm rounded to a tenth of a
/// point — the value the app paginated to before trim sizes existed), so
/// choosing A4, the default, reproduces the old output exactly. The imperial
/// sizes are exact (6 × 9" = 432 × 648 pt); A5 is 148 × 210 mm converted the
/// same way A4 was.
struct PageSize: Identifiable, Equatable {
    let id: String       // stable key for @AppStorage / cross-platform parity — never localized
    let label: String    // the menu title
    let width: CGFloat   // points, portrait
    let height: CGFloat

    var size: CGSize { CGSize(width: width, height: height) }

    static let a4           = PageSize(id: "a4",      label: "A4",           width: 595.2, height: 841.8)
    static let a5           = PageSize(id: "a5",      label: "A5",           width: 419.5, height: 595.3)
    static let usLetter     = PageSize(id: "letter",  label: "US Letter",    width: 612,   height: 792)
    static let usLegal      = PageSize(id: "legal",   label: "US Legal",     width: 612,   height: 1008)
    static let sixByNine    = PageSize(id: "6x9",     label: "6 × 9\"",      width: 432,   height: 648)
    static let fiveByEight  = PageSize(id: "5x8",     label: "5 × 8\"",      width: 360,   height: 576)
    static let digest       = PageSize(id: "5.5x8.5", label: "5.5 × 8.5\"",  width: 396,   height: 612)

    /// Every offered size, in menu order — A4 first, since it is the default.
    static let all: [PageSize] = [.a4, .a5, .usLetter, .usLegal, .sixByNine, .fiveByEight, .digest]

    /// The size stored under `id`, falling back to A4 for an empty or unknown
    /// key — so a first launch, or a preference written by some future version
    /// that offered a size this build doesn't, still lands on the default.
    static func named(_ id: String) -> PageSize {
        all.first { $0.id == id } ?? .a4
    }

    /// The body margin (CSS `padding`) for this trim size, scaled down from
    /// A4's `48px 56px` so a small page doesn't wear A4-sized margins — a 6 × 9"
    /// booklet with A4 margins wastes a quarter of its width. Each axis scales
    /// with its own dimension, so A4 reproduces `48px 56px` to the pixel (the
    /// historical value, hence an A4 export is byte-for-byte what it always was)
    /// and every smaller page gets a proportionate frame. Rounded to whole
    /// pixels: sub-pixel margins are invisible, and the integer string is what
    /// keeps the A4 case identical.
    var cssPadding: String {
        let vertical = Int((48 * height / PageSize.a4.height).rounded())
        let horizontal = Int((56 * width / PageSize.a4.width).rounded())
        return "\(vertical)px \(horizontal)px"
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

    /// Real A4 in points (210 × 297 mm at 72 dpi) — the default page a shared
    /// / exported PDF paginates to, and the value `PageSize.a4` carries (see
    /// `makePDF(pageSize:)`, which takes any trim size).
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

    /// Capture the rendered document as real pages of `pageSize` — the print
    /// pipeline pointed at a PDF context, so a shared / exported PDF is
    /// exactly what printing produces. `UIPrintPageRenderer` drives the
    /// web view's print formatter — the same engine the Print… action
    /// uses — so the breaks are line-aware (no line sliced at a fold) and
    /// the export CSS's `break-after: page` (the author's `\newpage`) is
    /// honored; each page is then drawn into a PDF graphics context.
    ///
    /// The formatter reflows the web content to the printable width it is
    /// given, so a narrower trim size lays the text out narrower — the caller
    /// pairs this with the matching scaled CSS margin (see `PageSize.cssPadding`
    /// / `styledForExport`). `pageSize` defaults to A4 for callers that don't
    /// offer a choice.
    func makePDF(pageSize: CGSize = WebRenderer.a4PageSize) throws -> Data {
        let page = CGRect(origin: .zero, size: pageSize)
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
    /// Graphviz / PlantUML) for the EPUB's snapshots, in document order and
    /// unscaled points, after growing the view to its full content height
    /// so no element sits outside the snapshot-able area. The selector
    /// matches exactly the containers `EpubBuilder.richElementRanges` finds
    /// in the source HTML, so the two lists pair up index-for-index — a
    /// class this query missed would shift every later snapshot onto the
    /// wrong element, so the two must be changed together.
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
                "Array.from(document.querySelectorAll(" +
                "'.md-mathi, .md-mathd, pre.mermaid, div.plantuml, div.graphviz'))" +
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

    /// The rendered document as one self-contained HTML file.
    ///
    /// Taken from the live DOM *after* `data-md-render-complete`, so what is
    /// captured is the finished page: Mermaid, Graphviz and PlantUML have
    /// already become inline `<svg>`, and KaTeX has already expanded its
    /// formulas into markup. Nothing is left to run, so every `<script>` and
    /// every stylesheet `<link>` into `rich/` is removed — the exported file
    /// must not reach for an engine that will not be there.
    ///
    /// `outerHTML` does not include the doctype, and without one every
    /// browser renders the page in quirks mode, so it is put back by hand.
    func selfContainedHTML() async throws -> String {
        let capture = """
        (function () {
          document.querySelectorAll('script, link[rel="stylesheet"]').forEach(function (el) {
            el.remove();
          });
          // A stale completion flag would be misleading in a file that has
          // nothing left to complete.
          document.documentElement.removeAttribute('data-md-render-complete');
          return document.documentElement.outerHTML;
        })()
        """
        let captured = try await webView.evaluateJavaScript(capture)
        guard let markup = captured as? String, !markup.isEmpty else {
            throw PDFAssemblyError()
        }
        return "<!DOCTYPE html>\n" + markup
    }

    func printFormatter() -> UIPrintFormatter { webView.viewPrintFormatter() }

    /// Read the rendered root `<svg>` of the diagram at `index` (0-based, in
    /// document order among `pre.mermaid`, `div.plantuml`, `div.graphviz` —
    /// the diagram half of the selector `richElementFrames` uses) straight out
    /// of the finished DOM as outerHTML. That is the real vector, not a
    /// rasterised snapshot.
    ///
    /// Nil when that diagram has no `<svg>`: a block whose engine threw or
    /// timed out is left showing its source text (see md-init.js), and there
    /// is nothing vector to export.
    func diagramSVG(at index: Int) async -> String? {
        let script = """
        (function () {
          var nodes = document.querySelectorAll('pre.mermaid, div.plantuml, div.graphviz');
          var el = nodes[\(index)];
          if (!el) return null;
          var svg = el.querySelector('svg');
          return svg ? svg.outerHTML : null;
        })()
        """
        let value = try? await webView.evaluateJavaScript(script)
        return value as? String
    }

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

    /// Rewrite the export HTML's body margin to `pageSize`'s scaled padding, so
    /// a small trim size doesn't carry A4-sized margins. Only the *first*
    /// `padding: 48px 56px;` is touched — that is the body rule inside the
    /// head's `<style>`, which always precedes any user content, so a document
    /// that happens to quote that exact CSS in a code block is left untouched.
    /// For A4 the replacement equals the original (see `PageSize.cssPadding`),
    /// so an A4 export is byte-for-byte what it was before trim sizes existed.
    private static func styledForExport(_ html: String, pageSize: PageSize) -> String {
        guard let range = html.range(of: "padding: 48px 56px;") else { return html }
        return html.replacingCharacters(in: range, with: "padding: \(pageSize.cssPadding);")
    }

    /// Render the document to a PDF and offer it through the share sheet.
    static func sharePDF(source: String, title: String, dark: Bool,
                         pageSize: PageSize = .a4) async {
        let html = styledForExport(
            MarkdownHTML.document(source, title: title, dark: dark, export: true),
            pageSize: pageSize)
        let renderer = WebRenderer()
        do {
            try await renderer.load(html: html)
            let data = try renderer.makePDF(pageSize: pageSize.size)
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
    static func exportPDF(source: String, title: String, dark: Bool,
                          pageSize: PageSize = .a4) async {
        let html = styledForExport(
            MarkdownHTML.document(source, title: title, dark: dark, export: true),
            pageSize: pageSize)
        let renderer = WebRenderer()
        do {
            try await renderer.load(html: html)
            let data = try renderer.makePDF(pageSize: pageSize.size)
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

    // MARK: - Self-contained HTML

    /// KaTeX's stylesheet with its web fonts embedded, ready to be dropped
    /// into an exported page — or nil if the bundle is missing it.
    ///
    /// A formula is not glyphs alone: `katex.min.css` positions every piece of
    /// it, so an export that dropped the stylesheet would show the right
    /// characters in the wrong places. It cannot be linked either, since the
    /// file has to stand on its own — so it is inlined, and each `@font-face`
    /// keeps only its **woff2** source, rewritten as a `data:` URI. woff2 is
    /// the one format every browser that matters reads; carrying the `woff`
    /// and `ttf` alternates as well would quadruple the payload for nothing,
    /// and leaving them as relative paths would leave dead links in the file.
    /// Twenty faces, about 300 KB before encoding.
    static func embeddedKatexCSS() -> String? {
        guard let root = Bundle.main.resourceURL,
              var css = try? String(contentsOf: root.appendingPathComponent("rich/katex.min.css"),
                                    encoding: .utf8) else { return nil }

        let fonts = root.appendingPathComponent("rich/fonts")
        let pattern = #"src:url\(fonts/([A-Za-z0-9_-]+)\.woff2\) format\("woff2"\)[^;}]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        // Back-to-front, so each replacement leaves the earlier ranges valid.
        let ns = css as NSString
        for match in regex.matches(in: css, range: NSRange(location: 0, length: ns.length)).reversed() {
            let face = ns.substring(with: match.range(at: 1))
            guard let data = try? Data(contentsOf: fonts.appendingPathComponent("\(face).woff2")) else {
                continue  // leave the rule alone rather than emit a broken src
            }
            let src = "src:url(data:font/woff2;base64,\(data.base64EncodedString())) format(\"woff2\")"
            css = (css as NSString).replacingCharacters(in: match.range, with: src)
        }
        return css
    }

    /// The notice that has to travel with an exported page carrying KaTeX's
    /// stylesheet and fonts. The code is MIT; the faces are **not** — they are
    /// SIL Open Font License 1.1 with reserved names, and the OFL requires its
    /// notice to accompany the fonts wherever they go. Exporting is the first
    /// thing md does that hands those files to somebody else, so this is the
    /// first place the obligation actually bites.
    private static let katexNotice = """
    <!--
      Mathematics rendered with KaTeX (https://katex.org) — MIT License,
      Copyright (c) 2013-2020 Khan Academy and other contributors.
      The embedded KaTeX_* fonts are licensed under the SIL Open Font
      License 1.1 (https://scripts.sil.org/OFL); "KaTeX" is a Reserved Font
      Name. The fonts are embedded unmodified.
    -->
    """

    /// Mermaid writes its own theme CSS into every diagram it draws, so an
    /// exported page carrying a Mermaid diagram is carrying several kilobytes
    /// of Mermaid's source text — not just generated geometry, the way
    /// Graphviz and PlantUML output is. MIT asks for its notice to go with
    /// that, so it does.
    private static let mermaidNotice = """
    <!--
      Diagrams rendered with Mermaid (https://mermaid.js.org) — MIT License,
      Copyright (c) 2014-2022 Knut Sveidqvist. The diagram SVG carries
      Mermaid's own theme stylesheet.
    -->
    """

    /// Export the rendered document as a single HTML file the reader can open
    /// anywhere — no engines, no folder of assets, no network.
    ///
    /// The diagrams are already inline SVG and the formulas already expanded
    /// by the time the page is captured (see `selfContainedHTML`), so the only
    /// thing that has to be carried across by hand is KaTeX's stylesheet, and
    /// only for a document that actually has math in it.
    static func exportHTML(source: String, title: String, dark: Bool) async {
        // `export: true` gives the page its paper styling. The `\newpage`
        // rule is the one thing not wanted here: in export CSS it becomes
        // `break-after: page`, which is invisible on screen and only means
        // anything on paper, so a reader scrolling the file would see the
        // author's page breaks silently vanish. The screen styling keeps them
        // as the dashed rule they look like in the preview.
        let html = MarkdownHTML.document(source, title: title, dark: dark, export: true)
            .replacingOccurrences(of: ".md-pagebreak { height: 0; margin: 0; break-after: page; }",
                                  with: ".md-pagebreak { border-top: 2px dashed rgba(43,38,32,0.16); margin: 1.6em 0; }")
        let renderer = WebRenderer()
        do {
            try await renderer.load(html: html)
            var page = try await renderer.selfContainedHTML()
            // Only a document with math pulled KaTeX in, and only that
            // document needs to carry the stylesheet and its fonts.
            if html.contains("rich/katex.min.css"), let css = embeddedKatexCSS() {
                page = page.replacingOccurrences(
                    of: "</head>", with: "<style>\(css)</style>\n\(katexNotice)\n</head>")
            }
            // Mermaid's own stylesheet travels inside every diagram it drew.
            if page.contains("<pre class=\"mermaid\"") || page.contains("class=\"mermaid\"") {
                page = page.replacingOccurrences(of: "</head>", with: "\(mermaidNotice)\n</head>")
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(sanitized(title)).html")
            try Data(page.utf8).write(to: url, options: .atomic)
            presentExport(url: url)
        } catch {
            presentMessage(title: "Couldn't Export HTML", message: error.localizedDescription)
        }
        withExtendedLifetime(renderer) {}
    }

    // MARK: - LaTeX export

    /// Export the document as LaTeX source and save it where the user
    /// chooses, via the Files export picker.
    ///
    /// Alone among the exports this one needs neither WebKit nor a theme:
    /// `LaTeXExport` is pure string work on the same parsed blocks, and a
    /// `.tex` file has no light or dark. It is also the only export that
    /// keeps the author's mathematics as mathematics — everything else
    /// either rasterises it or re-typesets it as KaTeX.
    static func exportLaTeX(source: String, title: String) {
        writeTeX(LaTeXExport.document(source), title: title)
    }

    /// The whole book as one `book`-class .tex, through the same picker —
    /// the book navigator's "Export as LaTeX…".
    static func exportBookLaTeX(book: EpubBook) {
        writeTeX(LaTeXExport.book(book), title: book.title)
    }

    /// Write the generated source to a temporary `.tex` and hand it to the
    /// export picker, alerting rather than dying quietly if the write fails.
    private static func writeTeX(_ text: String, title: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sanitized(title)).tex")
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            presentExport(url: url)
        } catch {
            presentMessage(title: "Couldn't Export LaTeX", message: error.localizedDescription)
        }
    }

    // MARK: - Diagram → SVG export

    /// A diagram produced no vector — its engine hit a syntax error or timed
    /// out, so md-init.js left the block as source text with no `<svg>`.
    private struct DiagramCaptureError: LocalizedError {
        var errorDescription: String? {
            "This diagram couldn't be captured — it may have failed to render."
        }
    }

    /// Render the document offscreen (engines and all, waiting for
    /// render-complete like the PDF / EPUB paths), pull the chosen diagram's
    /// rendered `<svg>` out of the finished DOM, wrap it as a standalone
    /// `.svg`, and save it where the user picks. `diagram` came from
    /// `DiagramSVG.diagrams(inSource:)`, so its `ordinal` is the diagram's
    /// document-order position — the same order the DOM reports the containers.
    ///
    /// `dark: false`: a `.svg` file carries no screen theme, so it is captured
    /// from the light render (Mermaid bakes its own colours into the SVG;
    /// Graphviz/PlantUML draw explicit ink). `export: true` only to keep the
    /// same page the other captures use — it changes nothing in the vector.
    static func exportDiagramSVG(source: String, title: String,
                                 diagram: DiagramSVG.Diagram) async {
        let html = MarkdownHTML.document(source, title: title, dark: false, export: true)
        let renderer = WebRenderer()
        do {
            try await renderer.load(html: html)
            guard let svg = await renderer.diagramSVG(at: diagram.ordinal) else {
                throw DiagramCaptureError()
            }
            let document = DiagramSVG.standaloneDocument(fromSVG: svg)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(sanitized(title))-\(diagram.ordinal + 1).svg")
            try Data(document.utf8).write(to: url, options: .atomic)
            presentExport(url: url)
        } catch {
            presentMessage(title: "Couldn't Export SVG", message: error.localizedDescription)
        }
        withExtendedLifetime(renderer) {}
    }

    // MARK: - TextBundle export

    /// Export the document as a `.textbundle` and save it where the user
    /// picks. Local images the Markdown references by relative path are copied
    /// into `assets/` and their refs rewritten (see `TextBundle.exportRewriting`);
    /// refs that can't be found next to the source are left exactly as written.
    ///
    /// Assets resolve relative to the *saved* document's folder — an unsaved,
    /// never-written document has no such folder, so it simply exports with an
    /// empty `assets/` and every ref left untouched. Synchronous like the
    /// LaTeX export: no WebKit and only a handful of small file reads.
    static func exportTextBundle(source: String, fileURL: URL?, title: String) {
        let rewrite = TextBundle.exportRewriting(source: source) { relativePath in
            readAsset(relativePath, besideDocumentAt: fileURL)
        }
        let wrapper = TextBundle.bundleWrapper(text: rewrite.text, assets: rewrite.assets)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sanitized(title)).textbundle")
        do {
            // Replace any stale temp bundle of the same name from a prior export.
            try? FileManager.default.removeItem(at: url)
            try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
            presentExport(url: url)
        } catch {
            presentMessage(title: "Couldn't Export TextBundle",
                           message: error.localizedDescription)
        }
    }

    /// Read an image the document references by relative path, if it sits
    /// beside the (saved) document. The resolved path is constrained to the
    /// document's own folder — a `../…` ref that would climb out is treated as
    /// not found (and so left untouched), the same containment the preview's
    /// asset scheme handler enforces, so an export never reaches for a file
    /// outside the document's directory.
    ///
    /// Symlinks are resolved before the containment check, not just `..`:
    /// `standardizedFileURL` collapses `..` but follows no links, so a symlink
    /// sitting beside the document and named to match an image ref could
    /// otherwise point anywhere on disk and pass the prefix test. Resolving
    /// both sides first means the check compares the real locations.
    private static func readAsset(_ relativePath: String, besideDocumentAt fileURL: URL?) -> Data? {
        guard let folder = fileURL?.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL else { return nil }
        let candidate = folder.appendingPathComponent(relativePath)
            .resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(folder.path + "/") else { return nil }

        // The document's own folder may be security-scoped (opened in place).
        let scoped = fileURL!.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL!.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: candidate)
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
            identifier: EpubBuilder.stableIdentifier(forTitle: book.title),
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

    // MARK: - EPUB export (single document)

    /// Build an EPUB 3 of the single open document and save it where the user
    /// chooses, via the Files export picker — the document share menu's
    /// "Export as EPUB…", beside Export as HTML / PDF / LaTeX.
    ///
    /// It reuses the book pipeline whole: the same stored-zip container, the
    /// same package document, the same rich-block snapshotting, and the same
    /// title-derived `dc:identifier` (so two exports of the same document land
    /// on the same identifier in a reader's library). What a lone document is
    /// *not* is a book — so there is no title-page unit, and the nav is the
    /// document's own headings rather than a chapter / article tree.
    static func exportDocumentEPUB(source: String, fileName: String) async {
        let title = EpubBuilder.documentTitle(
            frontMatter: MarkdownParser.frontMatter(of: source), fileName: fileName)
        do {
            let data = try await documentEpubData(source: source, title: title)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(sanitized(title)).epub")
            try data.write(to: url, options: .atomic)
            presentExport(url: url)
        } catch {
            presentMessage(title: "Couldn't Export EPUB", message: error.localizedDescription)
        }
    }

    /// Render the document's one content unit — the book path's very same
    /// per-article rendering, engines and all, under a fixed `content` unit id
    /// — then pack it with `documentEpubEntries`. Split from the presentation
    /// so the packing is testable without WebKit.
    private static func documentEpubData(source: String, title: String) async throws -> Data {
        let rendered = try await renderArticleBody(
            EpubArticle(title: title, source: source), unitID: "content")
        return StoredZip.archive(documentEpubEntries(
            title: title, body: rendered.body, images: rendered.images,
            outline: MarkdownParser.outline(source),
            modified: ISO8601DateFormatter().string(from: Date())))
    }

    /// The EPUB package entries for a single document, `mimetype` first:
    /// container, package document, nav, the shared stylesheet, the one
    /// content file (its already-rendered, rich-blocks-snapshotted body), and
    /// the snapshot images.
    ///
    /// Pure — no WebKit, no I/O — so the container shape and, above all, the
    /// nav / spine cursor stay unit-testable. The subtlety a book export
    /// carries and a document must *not*: the book path makes unit `u001` a
    /// title page and starts its nav cursor past it, so naively reusing that
    /// path with the title page removed would leave the nav pointing one file
    /// short. Here there is exactly one unit — `content.xhtml` — the spine
    /// names it, and every nav entry is a heading anchor *into* it. The nav
    /// links use the slug `MarkdownParser.outline` assigns each heading, which
    /// is the same id `MarkdownHTML` gives that heading, so a nav tap lands on
    /// the right section rather than on nothing.
    static func documentEpubEntries(title: String, body: String,
                                    images: [(href: String, data: Data)],
                                    outline: [OutlineEntry],
                                    modified: String) -> [(name: String, data: Data)] {
        let contentHref = "content.xhtml"
        let opf = EpubBuilder.contentOPF(
            title: title,
            identifier: EpubBuilder.stableIdentifier(forTitle: title),
            modified: modified,
            units: [(id: "content", href: contentHref)],
            images: images.map(\.href))
        // The document's outline as the nav TOC: a flat list of heading links,
        // the way the Contents menu itself lists them, each pointing at its
        // anchor inside the single content file. Reuses the book nav builder —
        // root articles, no chapters — so a heading is one `<li><a>` and there
        // is no book-tree nesting to fork.
        //
        // A document with no headings has an empty outline, and a toc `<nav>`
        // whose `<ol>` holds no `<li>` is not valid EPUB 3. So a headingless
        // document gets a single entry — the whole document, under its title,
        // linking to the content file itself — which is both spec-valid and
        // the sensible thing for a reader to see. (Android already guarded
        // this; the two Apple copies did not.)
        let navEntries = outline.isEmpty
            ? [(title: title, href: contentHref)]
            : outline.map { (title: $0.text, href: "\(contentHref)#\($0.slug)") }
        let nav = EpubBuilder.navXHTML(
            bookTitle: title,
            rootArticles: navEntries,
            chapters: [])

        var entries: [(name: String, data: Data)] = [
            (name: "mimetype", data: Data("application/epub+zip".utf8)),
            (name: "META-INF/container.xml", data: Data(EpubBuilder.containerXML.utf8)),
            (name: "OEBPS/content.opf", data: Data(opf.utf8)),
            (name: "OEBPS/nav.xhtml", data: Data(nav.utf8)),
            (name: "OEBPS/style.css", data: Data(epubStyle().utf8)),
            (name: "OEBPS/\(contentHref)",
             data: Data(EpubBuilder.page(title: title, body: body).utf8)),
        ]
        entries += images.map { (name: "OEBPS/\($0.href)", data: $0.data) }
        return entries
    }

    /// The XHTML body for one article: the shared per-block rendering,
    /// with every rich block (math / Mermaid / Graphviz / PlantUML) rendered by the
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
