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
        let blocks = MarkdownParser.parse(source)
        // Top-level headings carry a GitHub-style anchor id, so `[…](#slug)`
        // links navigate and the table of contents can scroll the preview.
        // The slugs come from the same `MarkdownParser.slug` the TOC uses,
        // so the two always agree.
        var slugs: [String: Int] = [:]
        let body = blocks.map { block -> String in
            if case let .heading(level, text) = block.kind {
                let id = MarkdownParser.slug(for: text, used: &slugs)
                return "<h\(level) id=\"\(id)\">\(inline(text))</h\(level)>"
            }
            return renderBlock(block)
        }.joined(separator: "\n")

        // Rich renderers (KaTeX math, Mermaid, PlantUML) load entirely from
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
        let langs = Set(blocks.compactMap { block -> String? in
            if case let .codeBlock(language, _) = block.kind { return (language ?? "").lowercased() }
            return nil
        })
        let needsMermaid = langs.contains("mermaid")
        let needsPlantuml = !langs.isDisjoint(with: ["plantuml", "puml", "plant-uml"])
        // Math is needed iff `inline()` actually emitted a math span — which it
        // only does for real formulas, never for currency like "$5". Keying off
        // the produced markup (rather than a raw "$" heuristic) means prose with
        // stray dollar signs never even loads KaTeX.
        let needsMath = body.contains("md-mathi") || body.contains("md-mathd")

        var head = ""
        if needsMath {
            head += """
            <link rel="stylesheet" href="rich/katex.min.css">
            <script defer src="rich/katex.min.js"></script>
            """
        }
        if needsMermaid { head += "\n<script src=\"rich/mermaid.min.js\"></script>" }
        if needsPlantuml { head += "\n<script src=\"rich/viz-global.js\"></script>" }

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
            case "math", "latex", "tex":
                // A whole-block display formula: md-init.js typesets the .md-mathd
                // element's text with KaTeX (displayMode).
                return "<div class=\"md-mathd\">\(escape(code))</div>"
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
        blockquote { margin: 0 0 0.9em; padding-left: 14px; border-left: 4px solid \(accent); color: \(muted); }
        hr { border: none; border-top: 1px solid \(border); margin: 1.4em 0; }
        /* The author's `\newpage`: a dashed rule on screen; in export / print
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
        .mermaid, .plantuml, .md-mathd {
            background: none; padding: 6px 0; margin: 0 0 0.9em;
            overflow-x: auto; text-align: center;
        }
        .mermaid svg, .plantuml svg { max-width: 100%; height: auto; }
        /* Images render at their natural size, only capped to the page width;
           height follows so the aspect ratio never distorts. */
        img { max-width: 100%; height: auto; }
        .md-mathd .katex-display { margin: 0; }
        .katex-display { overflow-x: auto; overflow-y: hidden; padding: 2px 0; }
        """
    }
}
