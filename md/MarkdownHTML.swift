//
//  MarkdownHTML.swift
//  md
//
//  Created by nettrash on 28/06/2026.
//
//  Serializes the parsed block model to a self-contained, themed HTML
//  document. This is the print / PDF / "share rendered" path: it reuses
//  the same `MarkdownParser` the on-screen preview uses, then emits HTML
//  with embedded typewriter CSS (American Typewriter prose, Courier New
//  code) and the paper-and-ink palette in a light or dark variant.
//
//  Block structure is rendered here; inline spans (**bold**, *italic*,
//  `code`, [links](url), ~~strike~~) are converted by a small inline pass
//  rather than going through Foundation's `AttributedString` — HTML needs
//  tags, and a focused converter on the same subset the app supports keeps
//  the output clean and predictable for printing.
//

import Foundation

enum MarkdownHTML {

    /// Fenced-block info strings that select the bundled Graphviz engine,
    /// mapped to the Graphviz layout program that lays the graph out. ```dot
    /// is the everyday one; the rest name a layout directly, which is how
    /// Graphviz itself is invoked (`neato -Tsvg`, `circo -Tsvg`, …). Every
    /// value must be one of `Viz.engines` — an unknown name makes the render
    /// throw and the block falls back to its source text.
    static let graphvizEngines: [String: String] = [
        "dot": "dot", "graphviz": "dot", "gv": "dot",
        "neato": "neato", "circo": "circo", "fdp": "fdp", "sfdp": "sfdp",
        "twopi": "twopi", "osage": "osage", "patchwork": "patchwork",
    ]

    /// A full HTML document for `source`, themed light or dark. `title`
    /// becomes the document `<title>` (and the print / PDF job name).
    /// `export` styles the document for paper / PDF instead of the live
    /// preview: a smaller, print-typical body size (everything else is
    /// em-based and scales with it), code blocks wrap long lines — paper
    /// can't scroll, so an overflowing line would be clipped at the
    /// block's edge — and the page is plain white in the light palette
    /// regardless of `dark`: the tinted paper and cream-on-carbon ink are
    /// screen themes, not something to fix into a printout.
    static func document(_ source: String, title: String, dark: Bool, export: Bool = false) -> String {
        let dark = dark && !export

        // A raw diagram document — an opened `.puml` or `.gv`: bare diagram
        // source with no fence (see `isRawPlantUML` / `isRawGraphviz`). Render
        // the whole file as one diagram rather than parsing it as Markdown,
        // which would only show the `@startuml…` / `digraph…` text. Everything
        // else — a `.md` / `.txt` file — is parsed as Markdown as before.
        let body: String
        let needsMath: Bool
        let needsMermaid: Bool
        let needsPlantuml: Bool
        let needsGraphviz: Bool
        let needsHighlight: Bool

        if isRawPlantUML(source) {
            // md-init.js turns the `.plantuml` container into an SVG offline;
            // on failure it restores the source, so an invalid diagram still
            // shows its text. No Markdown here, so no math / Mermaid.
            body = "<div class=\"plantuml\">\(escape(source))</div>"
            needsMath = false
            needsMermaid = false
            needsPlantuml = true
            needsGraphviz = false
            needsHighlight = false
        } else if isRawGraphviz(source) {
            // An opened `.gv`: bare DOT source, rendered as one diagram the
            // same way a raw `.puml` is (see `isRawGraphviz`).
            body = "<div class=\"graphviz\" data-engine=\"dot\">\(escape(source))</div>"
            needsMath = false
            needsMermaid = false
            needsPlantuml = false
            needsGraphviz = true
            needsHighlight = false
        } else {
            let blocks = MarkdownParser.parse(source)
            // Top-level headings carry a GitHub-style anchor id, so `[…](#slug)`
            // links navigate and the table of contents can scroll the preview.
            // The slugs come from the same `MarkdownParser.slug` the TOC uses,
            // so the two always agree.
            var slugs: [String: Int] = [:]
            let rendered = blocks.map { block -> String in
                if case let .heading(level, text) = block.kind {
                    let id = MarkdownParser.slug(for: text, used: &slugs)
                    return "<h\(level) id=\"\(id)\">\(inline(text))</h\(level)>"
                }
                return renderBlock(block)
            }.joined(separator: "\n")

            // Footnotes are a whole-document affair: the references are
            // numbered by where the reader meets them, and the notes are
            // gathered at the foot of the page rather than left where they
            // were written. Both need the finished body, so they happen here.
            body = withFootnotes(rendered, definitions: blocks.compactMap { block in
                if case let .footnoteDefinition(id, text) = block.kind { return (id, text) }
                return nil
            })

            // Every engine is needed iff the render actually emitted its
            // container. Keying off the produced markup — rather than scanning
            // the block list for fence languages — is what makes this correct
            // for a diagram nested inside a block quote: `renderBlock` recurses
            // into quoted blocks, so a scan of the top-level blocks alone would
            // emit the container and then never include the engine, leaving the
            // diagram stuck as its own source text. It is also what has always
            // kept KaTeX out of prose with stray dollar signs in it: `inline()`
            // emits a math span only for a real formula, never for "$5".
            //
            // A code block that merely *quotes* one of these strings can't
            // trigger a false positive: its content is HTML-escaped, so the
            // quotes and angle brackets no longer match.
            needsMermaid = body.contains("<pre class=\"mermaid\">")
            needsPlantuml = body.contains("<div class=\"plantuml\">")
            needsGraphviz = body.contains("<div class=\"graphviz\"")
            needsMath = body.contains("md-mathi") || body.contains("md-mathd")
            // A fenced block that named a real code language rendered as
            // `<pre><code class="language-…">` (see `renderBlock`). Keyed off the
            // produced markup like the others, so a highlighted block nested in a
            // block quote still counts, and a code block that merely quotes the
            // string can't trigger it (its content is escaped).
            needsHighlight = body.contains("<pre><code class=\"language-")
        }

        // Rich renderers (KaTeX math, Mermaid, Graphviz, PlantUML) load from
        // bundled assets under `rich/` — no network. Each heavy engine is
        // pulled in only when the document uses it, so a plain document stays
        // light (PlantUML alone is 7 MB): the KaTeX / Mermaid / Viz scripts are
        // included conditionally here, and `md-init.js` dynamically imports the
        // PlantUML engine only when a `.plantuml` block exists. `md-init.js`
        // itself is tiny and always runs; when it finishes it flags
        // `data-md-render-complete` (which the print / PDF path waits on).
        //
        // The WebView must load this with a base URL whose origin serves
        // `rich/` (a WKURLSchemeHandler on Apple, WebViewAssetLoader on
        // Android) so the ES-module import in `md-init.js` resolves.

        var head = ""
        if needsMath {
            // mhchem (KaTeX's chemistry extension: `\ce{…}`, `\pu{…}`) rides the
            // same `needsMath` gate — `\ce{}` only ever appears inside the math
            // delimiters that produce `.md-mathi` / `.md-mathd`, so it needs no
            // signal of its own. It must load right after KaTeX and share its
            // `defer`: deferred classic scripts run in document order, so KaTeX
            // defines the global `katex`, then mhchem registers its macros onto
            // it, before md-init.js (a deferred module, last) calls
            // katex.render(). Both are the same KaTeX 0.17.0 build (MIT) —
            // mhchem silently no-ops against a mismatched KaTeX, so the two
            // files must always be replaced together.
            head += """
            <link rel="stylesheet" href="rich/katex.min.css">
            <script defer src="rich/katex.min.js"></script>
            <script defer src="rich/mhchem.min.js"></script>
            """
        }
        if needsMermaid { head += "\n<script src=\"rich/mermaid.min.js\"></script>" }
        // Viz.js is Graphviz. PlantUML needs it for its own Graphviz-backed
        // layouts (class, activity, …), and a ```dot block is that same engine
        // addressed directly — so the two share one script include.
        if needsPlantuml || needsGraphviz { head += "\n<script src=\"rich/viz-global.js\"></script>" }
        // highlight.js syntax-highlights fenced code blocks that named a real
        // language (```swift, ```js, …); md-init.js runs it over each
        // `code[class^="language-"]`. It shares no global with KaTeX, so it only
        // has to have defined `hljs` before the deferred md-init.js module runs:
        // `defer` puts it in the same run-after-parse, in-document-order queue as
        // that module, and it sits ahead of it in the document. Pulled in only
        // when a highlightable block exists — the ~124 KB "common" build
        // (highlight.js 11.11.1, BSD-3-Clause). It reaches everything built from
        // the live DOM (preview, print, A4 PDF, HTML export) but NOT EPUB, which
        // snapshots this HTML before any script runs, so EPUB code stays plain.
        if needsHighlight { head += "\n<script defer src=\"rich/highlight.min.js\"></script>" }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>\(css(dark: dark, export: export))</style>\(head)
        </head>
        <body data-md-dark="\(dark ? "1" : "0")">
        \(body)
        <script type="module" src="rich/md-init.js"></script>
        </body>
        </html>
        """
    }

    /// True when `source` is a raw PlantUML document rather than Markdown —
    /// its first non-blank, non-comment line opens a PlantUML diagram
    /// (`@startuml`, `@startmindmap`, `@startgantt`, `@startjson`, …). That is
    /// exactly what an opened `.puml` file is: bare diagram source with no
    /// ```plantuml fence. Such a document is rendered as a single diagram
    /// (see `document`) instead of being parsed as Markdown, which would only
    /// show the source text. PlantUML line comments (`'…`) and blank lines
    /// before the opener are skipped, so a commented header doesn't hide it.
    static func isRawPlantUML(_ source: String) -> Bool {
        for rawLine in lines(of: source) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("'") { continue }
            return line.hasPrefix("@start")
        }
        return false
    }

    /// Split `source` into lines, whatever it uses to end them.
    ///
    /// Not `split(separator: "\n")`: a Swift `Character` is a grapheme
    /// cluster, and CRLF is *one* of them — so splitting a Windows-line-ended
    /// file on "\n" matches nothing and hands back the whole file as a single
    /// line. A raw `.puml` or `.gv` saved on Windows would then be recognized
    /// only when its diagram opener happened to be the very first thing in the
    /// file, and any leading blank line or comment would hide it. Splitting on
    /// the newline character *set* also takes care of a lone CR.
    private static func lines(of source: String) -> [String] {
        source.components(separatedBy: .newlines)
    }

    /// True when `source` is a raw Graphviz DOT document rather than Markdown —
    /// its first non-blank, non-comment line opens a graph (`digraph {`,
    /// `graph G {`, `strict digraph {`). That is exactly what an opened `.gv`
    /// file is: bare DOT source with no ```dot fence, so it renders as a single
    /// diagram (see `document`) instead of being parsed as Markdown, which
    /// would only show the source text. DOT's `//` and `/*` comments and blank
    /// lines before the opener are skipped, and its keywords are
    /// case-insensitive.
    ///
    /// Unlike PlantUML's `@start…`, `graph` is an ordinary English word, so the
    /// opener is matched against DOT's actual grammar — `[strict] (graph |
    /// digraph) [ID] '{'` — and not merely by prefix. A document that begins
    /// "graph theory is a branch of…" has three words where DOT allows at most
    /// one name and then a brace, so it stays Markdown. (A stray `{` somewhere
    /// in the file is no help either: a KaTeX formula or a JSON sample supplies
    /// one in plenty of perfectly ordinary documents.)
    ///
    /// DOT's third comment form, a `#` line, is deliberately *not* skipped:
    /// every Markdown heading starts with `#`, and skipping those would let the
    /// check see straight past the title of an ordinary document to whatever
    /// prose follows. The cost is only that a `.gv` file opening with a `#`
    /// line renders as Markdown — it is a C-preprocessor artifact, vanishingly
    /// rare in hand-written DOT — and the file's text is still shown either way.
    static func isRawGraphviz(_ source: String) -> Bool {
        guard source.contains("{") else { return false }
        for rawLine in lines(of: source) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("//") || line.hasPrefix("/*") {
                continue
            }
            var head = line.lowercased()
            if head.hasPrefix("strict ") {
                head = String(head.dropFirst("strict ".count)).trimmingCharacters(in: .whitespaces)
            }
            // `digraph` is tested first: it also has `graph` inside it, and a
            // prefix match on the shorter word would misread the longer one.
            for keyword in ["digraph", "graph"] where head.hasPrefix(keyword) {
                return isGraphHeader(head.dropFirst(keyword.count))
            }
            return false
        }
        return false
    }

    /// Whether what follows a `graph` / `digraph` keyword is the rest of a DOT
    /// graph header: an optional name, then the opening brace. The name may be
    /// a bare identifier or a quoted string; the brace may be on a later line,
    /// in which case nothing at all follows here.
    private static func isGraphHeader(_ tail: Substring) -> Bool {
        var rest = tail.drop { $0 == " " || $0 == "\t" }
        // `digraph` / `digraph {` — no name.
        if rest.isEmpty || rest.hasPrefix("{") { return true }
        // A name must have been separated from the keyword by space or brace;
        // otherwise this is just a longer word ("digraphs", "graphviz").
        guard tail.first == " " || tail.first == "\t" else { return false }
        if rest.hasPrefix("\"") {
            guard let close = rest.dropFirst().firstIndex(of: "\"") else { return false }
            rest = rest[rest.index(after: close)...]
        } else {
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if name.isEmpty { return false }
            rest = rest[name.endIndex...]
        }
        rest = rest.drop { $0 == " " || $0 == "\t" }
        return rest.isEmpty || rest.hasPrefix("{")
    }

    // MARK: - Blocks

    private static func renderBlock(_ block: MarkdownBlock) -> String {
        switch block.kind {
        case let .heading(level, text):
            return "<h\(level)>\(inline(text))</h\(level)>"

        case let .paragraph(text):
            // Preserve soft line breaks the way the editor shows them. The
            // break conversion happens inside `inline` (before protected math /
            // code spans are restored) so a multi-line display-math span keeps
            // its own internal newlines instead of getting `<br>`s injected.
            return "<p>\(inline(text, softBreaks: true))</p>"

        case let .list(ordered, items):
            return renderList(items, ordered: ordered)

        case let .codeBlock(language, code):
            // A fenced block's info string selects a rich renderer; md-init.js
            // turns these containers into diagrams/formulas in the WebView.
            switch (language ?? "").lowercased() {
            case "mermaid":
                return "<pre class=\"mermaid\">\(escape(code))</pre>"
            case "plantuml", "puml", "plant-uml":
                return "<div class=\"plantuml\">\(escape(code))</div>"
            case let lang where graphvizEngines[lang] != nil:
                // ```dot (and the layout-named aliases) — Viz.js renders the
                // DOT source with the engine named by the info string.
                return "<div class=\"graphviz\" data-engine=\"\(graphvizEngines[lang]!)\">\(escape(code))</div>"
            case let delimited where delimited == "csv" || delimited == "tsv":
                // Data pasted straight out of a spreadsheet, drawn as a table
                // while the source stays the data — so it can be re-pasted and
                // re-sorted without hand-editing a grid of pipes.
                return renderDelimited(code, separator: delimited == "tsv" ? "\t" : ",")
            case "math", "latex", "tex":
                // A whole-block display formula: md-init.js typesets the .md-mathd
                // element's text with KaTeX (displayMode).
                return "<div class=\"md-mathd\">\(escape(code))</div>"
            case "plot":
                // The one rich block with no engine behind it. `Plot.renderPlot`
                // is pure and synchronous and lives in this same layer, so the
                // finished `<svg>` is already in the string every surface
                // receives: the preview, the self-contained HTML, print, PDF,
                // EPUB and the SVG export all work with no script, no asset and
                // no rasterisation step — and because the class is exactly
                // `plot`, a plot-only document trips none of the engine probes
                // below and loads no engine at all.
                //
                // The container is emitted whatever happens — a good plot, an
                // empty block and a broken one alike — because the SVG export
                // pairs a figure with its source block by counting `div.plot`
                // containers in document order.
                return Plot.renderPlot(code)
            case let lang where !lang.isEmpty:
                // A real code language (```swift, ```js, …). The diagram / math /
                // data languages were handled above, so anything left with a
                // non-empty hint is code: tag it `language-<lang>` for
                // highlight.js, which md-init.js runs in the WebView. An unknown
                // hint the "common" build doesn't carry just isn't highlighted —
                // the block stays plain, never breaks. The class is the escaped
                // info string; a bare fence (empty hint) falls through to plain,
                // unhighlighted code below.
                return "<pre><code class=\"language-\(escape(lang))\">\(escape(code))</code></pre>"
            default:
                return "<pre><code>\(escape(code))</code></pre>"
            }

        case let .quote(blocks):
            return "<blockquote>\n\(blocks.map(renderBlock).joined(separator: "\n"))\n</blockquote>"

        case let .table(header, alignments, rows):
            return renderTable(header: header, alignments: alignments, rows: rows)

        case .thematicBreak:
            return "<hr>"

        case .pageBreak:
            // In the preview a subtle dashed rule; in export / print it
            // becomes a real page boundary (see the CSS).
            return "<div class=\"md-pagebreak\"></div>"

        case .note:
            // Private author notes never reach the rendered document —
            // they live in the editor and the notes panel only.
            return ""

        case .frontMatter:
            // Metadata about the document, not part of it. It is parsed so
            // the fields are available (and so the opening `---` stops being
            // read as a horizontal rule), but nothing is drawn — which is
            // what every tool that understands front matter does.
            return ""

        case .footnoteDefinition:
            // Nothing is drawn where the definition was written; `document`
            // collects them all and prints them at the foot of the page.
            return ""
        }
    }

    /// Render the flat, level-tagged item list with explicit markers and
    /// indentation — mirroring the on-screen preview rather than relying on
    /// nested `<ul>`/`<ol>` reconstruction from a non-tree model.
    private static func renderList(_ items: [ListItem], ordered: Bool) -> String {
        var rows = ""
        for item in items {
            let indent = String(format: "%.2f", Double(item.level) * 1.6)
            let marker: String
            if let done = item.task {
                marker = done ? "&#9745;" : "&#9744;"   // ☑ / ☐
            } else if ordered, let ordinal = item.ordinal {
                marker = "\(ordinal)."
            } else {
                marker = "&bull;"
            }
            let done = item.task == true ? " done" : ""
            rows += """
            <div class="md-item\(done)" style="padding-left:\(indent)em">\
            <span class="md-marker">\(marker)</span>\
            <span>\(inline(item.text))</span></div>
            """
        }
        return "<div class=\"md-list\">\(rows)</div>"
    }

    /// Render a ```csv / ```tsv block as a table: first row the header, the
    /// rest the body. A block that parses to nothing stays a code block, so
    /// nothing the author wrote disappears.
    private static func renderDelimited(_ code: String, separator: Character) -> String {
        guard let table = delimitedTable(code, separator: separator) else {
            return "<pre><code>\(escape(code))</code></pre>"
        }
        return renderTable(header: table.header, alignments: table.alignments, rows: table.rows)
    }

    /// The table a ```csv / ```tsv block describes — header row, inferred
    /// alignments, body rows — or nil when the block parses to nothing.
    ///
    /// Split out from `renderDelimited` because the LaTeX export owes the
    /// same spreadsheet the same table: the number rule below is subtle
    /// enough (see `isDecimalNumber`) that a second copy of it would drift,
    /// and a column that is right-aligned in the PDF and left-aligned in
    /// the `.tex` is exactly the kind of difference nobody would look for.
    static func delimitedTable(_ code: String, separator: Character)
        -> (header: [String], alignments: [ColumnAlignment], rows: [[String]])? {
        let rows = parseDelimited(code, separator: separator)
        guard let header = rows.first, !header.isEmpty else { return nil }
        let body = Array(rows.dropFirst())
        // A column whose every filled cell is a number is right-aligned, the
        // way a spreadsheet would show it — decimal points then line up, which
        // is most of what makes a table of figures readable.
        let columns = max(header.count, body.map(\.count).max() ?? 0)
        let alignments: [ColumnAlignment] = (0..<columns).map { column in
            let cells = body.compactMap { row -> String? in
                guard column < row.count else { return nil }
                // Only ASCII padding is stripped, and deliberately: Foundation's
                // `.whitespaces` also contains U+200B, which Java's Zs-based
                // trim does not, so the two platforms would align the same
                // spreadsheet differently over an invisible character.
                let cell = row[column].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                return cell.isEmpty ? nil : cell
            }
            return !cells.isEmpty && cells.allSatisfy(isDecimalNumber) ? .trailing : .leading
        }
        return (header, alignments, body)
    }

    /// Whether `cell` is a plain decimal number — the only thing worth
    /// right-aligning in a column of figures.
    ///
    /// Deliberately **not** `Double(_:)`. Swift's initialiser also accepts hex
    /// (`Double("0x10") == 16`) and `inf` / `nan` in any casing, none of which
    /// Java's `Double.parseDouble` takes — so a column of `0x10` right-aligned
    /// on Apple and left-aligned on Android, over a difference in two standard
    /// libraries that has nothing to do with what the author wrote. Spelling
    /// the grammar out — optional sign, digits with an optional decimal point,
    /// optional exponent — is the same rule everywhere, and it is also the
    /// honest one: a hex literal is not a figure whose decimal point can line
    /// up with anything.
    ///
    /// Hand-written rather than a regular expression on purpose: `\d` and `\s`
    /// mean different things on the desktop JVM and on Android's ICU engine,
    /// which this project has already been bitten by.
    static func isDecimalNumber(_ cell: String) -> Bool {
        var rest = Substring(cell)
        func takeDigits() -> Int {
            var count = 0
            while let character = rest.first, character.isASCII, character.isNumber {
                count += 1
                rest = rest.dropFirst()
            }
            return count
        }

        if let sign = rest.first, sign == "+" || sign == "-" { rest = rest.dropFirst() }
        var digits = takeDigits()
        if rest.first == "." {
            rest = rest.dropFirst()
            digits += takeDigits()
        }
        guard digits > 0 else { return false }

        if let exponent = rest.first, exponent == "e" || exponent == "E" {
            rest = rest.dropFirst()
            if let sign = rest.first, sign == "+" || sign == "-" { rest = rest.dropFirst() }
            guard takeDigits() > 0 else { return false }
        }
        return rest.isEmpty
    }

    /// Split delimiter-separated text into rows of fields, per RFC 4180: a
    /// field may be quoted, a quoted field may contain the separator and line
    /// breaks, and a doubled quote inside one is a literal quote.
    ///
    /// Line endings are normalised first rather than matched: a Swift
    /// `Character` is a grapheme cluster and CRLF is a single one of them, so
    /// a comparison against "\n" silently never fires on a file saved on
    /// Windows — which is exactly where spreadsheet exports come from.
    static func parseDelimited(_ text: String, separator: Character) -> [[String]] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let characters = Array(normalized)
        var i = 0

        while i < characters.count {
            let character = characters[i]
            if quoted {
                if character == "\"" {
                    // A doubled quote is one literal quote; a single one ends
                    // the quoted run.
                    if i + 1 < characters.count, characters[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                        continue
                    }
                    quoted = false
                } else {
                    field.append(character)
                }
                i += 1
                continue
            }
            switch character {
            case "\"" where field.isEmpty:
                quoted = true
            case separator:
                row.append(field)
                field = ""
            case "\n":
                row.append(field)
                field = ""
                rows.append(row)
                row = []
            default:
                field.append(character)
            }
            i += 1
        }
        // A file that does not end in a newline still has a last row.
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private static func renderTable(header: [String],
                                    alignments: [ColumnAlignment],
                                    rows: [[String]]) -> String {
        func align(_ i: Int) -> String {
            guard i < alignments.count else { return "left" }
            switch alignments[i] {
            case .leading: return "left"
            case .center: return "center"
            case .trailing: return "right"
            }
        }
        var html = "<table><thead><tr>"
        for (i, cell) in header.enumerated() {
            html += "<th style=\"text-align:\(align(i))\">\(inline(cell))</th>"
        }
        html += "</tr></thead><tbody>"
        for row in rows {
            html += "<tr>"
            for (i, cell) in row.enumerated() {
                html += "<td style=\"text-align:\(align(i))\">\(inline(cell))</td>"
            }
            html += "</tr>"
        }
        html += "</tbody></table>"
        return html
    }

    // MARK: - Footnotes

    /// Turn the placeholder references `inline()` left in `body` into numbered
    /// links, and append the footnotes themselves.
    ///
    /// Numbering is by order of first reference, which is the order a reader
    /// meets them — not the order the definitions happen to be written in.
    /// Two cases are deliberate rather than incidental:
    ///
    /// - A reference with **no definition** is not a footnote at all, so it
    ///   goes back to being the text the author typed. Linking it to nothing
    ///   would be worse than leaving it alone.
    /// - A definition that is **never referenced** is still printed, after the
    ///   referenced ones. Dropping it would silently discard something the
    ///   author wrote; it simply gets no back-link, having nowhere to go back
    ///   to.
    private static func withFootnotes(_ body: String,
                                      definitions: [(id: String, text: String)]) -> String {
        let marker = #"<sup class="md-fnref" data-fn="([A-Za-z0-9_-]+)"></sup>"#
        guard let regex = try? NSRegularExpression(pattern: marker) else { return body }
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty || !definitions.isEmpty else { return body }

        // First definition wins if an id is defined twice, matching how a
        // duplicate link reference behaves.
        var defined: [String: String] = [:]
        for definition in definitions where defined[definition.id] == nil {
            defined[definition.id] = definition.text
        }

        // Walk the references forward once: assign each id its number, and
        // each individual reference its occurrence, so repeated references to
        // one footnote each get a distinct anchor to come back to.
        struct Reference { let range: NSRange; let id: String; let occurrence: Int }
        var references: [Reference] = []
        var occurrences: [String: Int] = [:]
        var number: [String: Int] = [:]
        var ordered: [String] = []
        for match in matches {
            let id = ns.substring(with: match.range(at: 1))
            let occurrence = (occurrences[id] ?? 0) + 1
            occurrences[id] = occurrence
            references.append(Reference(range: match.range, id: id, occurrence: occurrence))
            if defined[id] != nil, number[id] == nil {
                number[id] = ordered.count + 1
                ordered.append(id)
            }
        }
        for definition in definitions where number[definition.id] == nil {
            number[definition.id] = ordered.count + 1
            ordered.append(definition.id)
        }

        // Substitute back-to-front so the earlier ranges stay valid.
        var result = body
        for reference in references.reversed() {
            let replacement: String
            if let n = number[reference.id], defined[reference.id] != nil {
                let anchor = reference.occurrence == 1
                    ? "fnref-\(n)" : "fnref-\(n)-\(reference.occurrence)"
                replacement = """
                <sup class="md-fnref" id="\(anchor)"><a href="#fn-\(n)">\(n)</a></sup>
                """
            } else {
                replacement = escape("[^\(reference.id)]")
            }
            result = (result as NSString).replacingCharacters(in: reference.range, with: replacement)
        }

        guard !ordered.isEmpty else { return result }
        var items = ""
        for id in ordered {
            guard let n = number[id] else { continue }
            // A footnote's own text is inline Markdown. Should it contain a
            // further reference, that placeholder has missed the numbering
            // pass above, so it is cleaned back to literal text below rather
            // than left as markup the reader would see.
            let text = inline(defined[id] ?? "")
            let back = occurrences[id] != nil
                ? " <a class=\"md-fnback\" href=\"#fnref-\(n)\">&#8617;</a>" : ""
            items += "<li id=\"fn-\(n)\">\(text)\(back)</li>"
        }
        result += "\n<section class=\"md-footnotes\"><hr><ol>\(items)</ol></section>"
        return replace(marker, escape("[^") + "$1" + escape("]"), in: result)
    }

    // MARK: - Inline

    /// Convert a block's inline Markdown to HTML. Code spans and math spans are
    /// lifted out first — their content is literal and must not be re-interpreted
    /// by the span-syntax pass — then the remainder is HTML-escaped, span syntax
    /// is converted, optional soft breaks are inserted, and finally the protected
    /// spans are restored. Math is emitted as explicit `.md-mathi` / `.md-mathd`
    /// spans (rendered by md-init.js with KaTeX), so this pass — not a browser
    /// delimiter scan — decides what is a formula. Their content is escaped, but
    /// KaTeX reads the decoded textContent so `<`, `>`, `&` in a formula are fine.
    private static func inline(_ text: String, softBreaks: Bool = false) -> String {
        var protected: [String] = []
        var working = text

        // 1. Protect, in order: code spans, then display math ($$…$$, \[…\]),
        //    then inline math ($…$, \(…\)). Code wins over math, so `$x$` inside
        //    backticks stays literal code. The inline `$…$` form carries a
        //    currency guard so "$5 and $10" is left as prose.
        working = protect(#"`([^`]+)`"#, in: working, store: &protected) { "<code>\(escape($0))</code>" }
        working = protect(#"\$\$([\s\S]+?)\$\$"#, in: working, store: &protected) { mathSpan($0, display: true) }
        working = protect(#"\\\[([\s\S]+?)\\\]"#, in: working, store: &protected) { mathSpan($0, display: true) }
        working = protect(#"(?<![\w$])\$([^$\n]+?)\$(?![\w$])"#, in: working, store: &protected) { mathSpan($0, display: false) }
        working = protect(#"\\\(([^\n]+?)\\\)"#, in: working, store: &protected) { mathSpan($0, display: false) }
        //    A footnote reference needs no protection: `[^id]` has no `](`,
        //    so no link or image pattern can match it, and one written inside
        //    backticks is already a code token by now.

        // 2. Escape the literal text (protection tokens are private-use, untouched).
        working = escape(working)

        // 3. Span syntax → tags. Images before links (image syntax is link
        //    syntax with a leading `!`, so the link pass would eat it), links
        //    before emphasis, bold before italic so `**` wins. The text is
        //    already escaped, so an optional source title reads `&quot;…&quot;`
        //    here and attribute values can't break out of their quotes.
        working = replace(#"!\[([^\]]*)\]\(([^)\s]+)\s+&quot;(.*?)&quot;\)"#,
                          "<img src=\"$2\" alt=\"$1\" title=\"$3\">", in: working)
        working = replace(#"!\[([^\]]*)\]\(([^)\s]+)\)"#,
                          "<img src=\"$2\" alt=\"$1\">", in: working)
        working = replace(#"\[([^\]]+)\]\(([^)\s]+)\s+&quot;(.*?)&quot;\)"#,
                          "<a href=\"$2\" title=\"$3\">$1</a>", in: working)
        working = replace(#"\[([^\]]+)\]\(([^)\s]+)\)"#, "<a href=\"$2\">$1</a>", in: working)
        // Footnote references come after images and links, and must: the
        // markup a reference becomes is full of quotes and angle brackets, so
        // converting it first would let an image carry it into an `alt`
        // attribute — straight through the quoting this pass relies on — and
        // let a link wrap it in an `<a>` inside another `<a>`. Running last
        // means a reference written inside a link's own label simply stops
        // that label from being a link, which is the harmless failure.
        //
        // The number and the target are not known yet — they depend on the
        // order of first reference across the whole document — so this leaves
        // a placeholder for `withFootnotes` to resolve.
        working = replace(#"\[\^([A-Za-z0-9_-]+)\]"#,
                          "<sup class=\"md-fnref\" data-fn=\"$1\"></sup>", in: working)
        working = replace(#"\*\*([^*]+)\*\*"#, "<strong>$1</strong>", in: working)
        working = replace(#"__([^_]+)__"#, "<strong>$1</strong>", in: working)
        working = replace(#"~~([^~]+)~~"#, "<del>$1</del>", in: working)
        working = replace(#"\*([^*]+)\*"#, "<em>$1</em>", in: working)
        // Underscore italic only at word boundaries, so snake_case survives.
        working = replace(#"(?<![\w])_([^_]+)_(?![\w])"#, "<em>$1</em>", in: working)

        // 4. Soft line breaks (paragraphs only), before restoring protected spans
        //    so a multi-line display-math span keeps its own internal newlines.
        if softBreaks {
            working = working.replacingOccurrences(of: "\n", with: "<br>\n")
        }

        // 5. Restore protected spans.
        for (index, html) in protected.enumerated() {
            working = working.replacingOccurrences(of: token(index), with: html)
        }
        return working
    }

    /// Replace every match of `pattern` (capture group 1) with a unique
    /// private-use token, appending `transform(group1)` to `store`. Matches are
    /// rewritten back-to-front so earlier ranges stay valid.
    private static func protect(_ pattern: String, in text: String,
                                store: inout [String], transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = text
        for match in matches.reversed() where match.numberOfRanges >= 2 {
            let content = ns.substring(with: match.range(at: 1))
            let index = store.count
            store.append(transform(content))
            result = (result as NSString).replacingCharacters(in: match.range, with: token(index))
        }
        return result
    }

    private static func token(_ index: Int) -> String { "\u{E000}\(index)\u{E001}" }

    /// A KaTeX target element for `latex`. md-init.js renders `.md-mathi`
    /// inline and `.md-mathd` in display mode; the LaTeX is escaped for HTML but
    /// KaTeX reads the decoded textContent.
    private static func mathSpan(_ latex: String, display: Bool) -> String {
        "<span class=\"md-math\(display ? "d" : "i")\">\(escape(latex))</span>"
    }

    private static func escape(_ s: String) -> String {
        // `"` is escaped too so a link URL (which lands in a double-quoted href
        // attribute, and whose characters aren't otherwise constrained) can't
        // break out and inject attributes / event handlers into the WebView.
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func replace(_ pattern: String, _ template: String, in s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
    }

    // MARK: - CSS

    private static func css(dark: Bool, export: Bool) -> String {
        let paper      = dark ? "#241E18" : "#F4EFE2"
        let ink        = dark ? "#E7DBC2" : "#2B2620"
        let secondary  = dark ? "#2F2820" : "#EAE2CF"
        let accent     = dark ? "#C99A55" : "#9C6B2E"
        let muted      = dark ? "#B3A98E" : "#6B635A"
        let border     = dark ? "rgba(231,219,194,0.16)" : "rgba(43,38,32,0.16)"
        // A code-string tone for the hand-written highlight.js theme below: a
        // shade drawn from the ink itself — quieter than the plain ink text but
        // warmer and darker than the grey `muted` used for comments, so the two
        // stay distinct without adding a new hue to the warm-paper palette.
        let codeString = dark ? "#CDBF9E" : "#4A4034"
        return """
        /* Force backgrounds to render in print / PDF so the content chrome
           (code blocks, table headers) survives, rather than being dropped. */
        * { -webkit-print-color-adjust: exact; print-color-adjust: exact; box-sizing: border-box; }
        :root { color-scheme: \(dark ? "dark" : "light"); }
        /* On paper the page keeps its own single color: the paper tint is a
           screen theme, and a content-height background would end mid-page
           next to the white A4 margins. */
        html, body { background: \(export ? "#FFFFFF" : paper); }
        body {
            color: \(ink);
            font-family: "American Typewriter", "Courier New", serif;
            font-size: \(export ? 11 : 13)pt;
            line-height: 1.55;
            margin: 0;
            padding: 48px 56px;
            -webkit-text-size-adjust: 100%;
        }
        h1, h2, h3, h4, h5, h6 { font-weight: bold; line-height: 1.25; margin: 1.2em 0 0.5em; }
        h1 { font-size: 2em; }
        h2 { font-size: 1.6em; }
        h3 { font-size: 1.3em; }
        h4 { font-size: 1.1em; }
        h5 { font-size: 1em; }
        h6 { font-size: 0.9em; color: \(muted); }
        p { margin: 0 0 0.9em; }
        a { color: \(accent); }
        code, pre { font-family: "Courier New", monospace; }
        code { background: \(secondary); padding: 0.1em 0.3em; border-radius: 4px; font-size: 0.92em; }
        pre { background: \(secondary); padding: 12px 14px; border-radius: 8px; overflow-x: auto; }
        /* In export, code wraps: paper can't scroll a too-wide block, so a
           long line would otherwise be clipped at the block's edge. */
        \(export ? "pre { white-space: pre-wrap; overflow-wrap: anywhere; }" : "")
        pre code { background: none; padding: 0; font-size: 0.92em; }
        /* Syntax highlighting (highlight.js). Deliberately NOT a stock hljs
           theme — github / monokai and the rest are bright rainbows that fight
           the warm-paper, American-Typewriter look. Instead three quiet tones
           taken from the page's own palette: language keywords and the
           structural names in the warm accent, comments in muted italic,
           strings a softer shade of the ink; numbers and everything else stay
           plain ink. The code face is still Courier New (inherited from `pre
           code`). Applied by md-init.js over the live DOM, so it reaches
           preview, print, PDF and HTML export — not EPUB, which snapshots this
           HTML before any script runs, so its code blocks stay plain. */
        .hljs-keyword, .hljs-selector-tag, .hljs-built_in, .hljs-literal,
        .hljs-type, .hljs-title, .hljs-section, .hljs-name, .hljs-doctag { color: \(accent); }
        .hljs-comment, .hljs-quote, .hljs-meta { color: \(muted); font-style: italic; }
        .hljs-string, .hljs-regexp, .hljs-symbol, .hljs-char,
        .hljs-attr, .hljs-attribute, .hljs-addition { color: \(codeString); }
        .hljs-deletion { color: \(muted); text-decoration: line-through; }
        .hljs-emphasis { font-style: italic; }
        .hljs-strong { font-weight: bold; }
        blockquote { margin: 0 0 0.9em; padding-left: 14px; border-left: 4px solid \(accent); color: \(muted); }
        hr { border: none; border-top: 1px solid \(border); margin: 1.4em 0; }
        /* The author's `\\newpage`: a dashed rule on screen; in export / print
           it collapses to an invisible marker where a new page starts (the
           PDF capture splits pages at it, and paginated printing breaks). */
        \(export
            ? ".md-pagebreak { height: 0; margin: 0; break-after: page; }"
            : ".md-pagebreak { border-top: 2px dashed \(border); margin: 1.6em 0; }")
        table { border-collapse: collapse; margin: 0 0 0.9em; }
        th, td { border: 1px solid \(border); padding: 6px 12px; }
        th { background: \(secondary); }
        .md-list { margin: 0 0 0.9em; }
        .md-item { display: flex; gap: 0.5em; margin: 0.22em 0; }
        .md-marker { color: \(muted); min-width: 1.5em; text-align: right; }
        .md-item.done { color: \(muted); text-decoration: line-through; }
        /* Rich blocks: diagrams and display formulas render as SVG/markup, not
           code — drop the code-block chrome, centre them, allow horizontal
           scroll. Inline math (.md-mathi) flows with the text. */
        .mermaid, .plantuml, .graphviz, .plot, .md-mathd {
            background: none; padding: 6px 0; margin: 0 0 0.9em;
            overflow-x: auto; text-align: center;
        }
        .mermaid svg, .plantuml svg, .graphviz svg, .plot svg { max-width: 100%; height: auto; }
        /* Graphviz draws in plain black on a transparent ground (md-init.js
           asks for `bgcolor=transparent`). Recolor it to the page's ink here,
           in CSS, rather than passing colors to the engine: these are
           presentation attributes, which any CSS rule outranks, and leaving
           the engine's own attributes alone keeps the layout metrics — and so
           the label positions it computed — exactly as Graphviz intended.

           An author's own `fontcolor` / `color` survives: Graphviz writes
           those out as attributes too, so each rule is scoped to the value the
           engine emits when nothing was asked for — text with no fill of its
           own, and explicit black. */
        .graphviz svg text:not([fill]) { fill: \(ink); }
        .graphviz svg text[fill="black"] { fill: \(ink); }
        .graphviz svg [stroke="black"] { stroke: \(ink); }
        .graphviz svg [fill="black"]:not(text) { fill: \(ink); }
        /* Footnotes. The references are superscript numerals in the running
           text; the notes themselves sit under a rule at the foot of the
           document, a size down, with a back-link to where they were cited. */
        .md-fnref a { text-decoration: none; color: \(accent); }
        .md-footnotes { margin-top: 2em; font-size: 0.9em; color: \(muted); }
        .md-footnotes hr { margin: 0 0 0.8em; }
        .md-footnotes ol { margin: 0; padding-left: 1.6em; }
        .md-footnotes li { margin: 0.35em 0; }
        .md-fnback { text-decoration: none; color: \(accent); }
        /* Images render at their natural size, only capped to the page width;
           height follows so the aspect ratio never distorts. */
        img { max-width: 100%; height: auto; }
        .md-mathd .katex-display { margin: 0; }
        .katex-display { overflow-x: auto; overflow-y: hidden; padding: 2px 0; }
        """
    }
}
