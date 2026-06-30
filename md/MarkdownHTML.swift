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
    static func document(_ source: String, title: String, dark: Bool) -> String {
        let body = MarkdownParser.parse(source).map(renderBlock).joined(separator: "\n")
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>\(css(dark: dark))</style>
        </head>
        <body>
        \(body)
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
            // Preserve soft line breaks the way the editor shows them.
            let html = inline(text).replacingOccurrences(of: "\n", with: "<br>\n")
            return "<p>\(html)</p>"

        case let .list(ordered, items):
            return renderList(items, ordered: ordered)

        case let .codeBlock(_, code):
            return "<pre><code>\(escape(code))</code></pre>"

        case let .quote(blocks):
            return "<blockquote>\n\(blocks.map(renderBlock).joined(separator: "\n"))\n</blockquote>"

        case let .table(header, alignments, rows):
            return renderTable(header: header, alignments: alignments, rows: rows)

        case .thematicBreak:
            return "<hr>"
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

    /// Convert a block's inline Markdown to HTML. Code spans are lifted out
    /// first (their content is literal and must not be re-interpreted), the
    /// remainder is HTML-escaped, span syntax is converted, then the code
    /// spans are restored.
    private static func inline(_ text: String) -> String {
        var codeSpans: [String] = []
        var working = text

        // 1. Extract `code spans`, replacing each with a private-use token.
        if let regex = try? NSRegularExpression(pattern: "`([^`]+)`") {
            let ns = working as NSString
            let matches = regex.matches(in: working, range: NSRange(location: 0, length: ns.length))
            // Replace back-to-front so earlier match ranges stay valid.
            var result = ns as String
            for match in matches.reversed() {
                let content = ns.substring(with: match.range(at: 1))
                let index = codeSpans.count
                codeSpans.append("<code>\(escape(content))</code>")
                result = (result as NSString).replacingCharacters(in: match.range, with: token(index))
            }
            working = result
        }

        // 2. Escape the literal text (tokens are private-use chars, untouched).
        working = escape(working)

        // 3. Span syntax → tags. Links first; bold before italic so `**` wins.
        working = replace(#"\[([^\]]+)\]\(([^)\s]+)\)"#, "<a href=\"$2\">$1</a>", in: working)
        working = replace(#"\*\*([^*]+)\*\*"#, "<strong>$1</strong>", in: working)
        working = replace(#"__([^_]+)__"#, "<strong>$1</strong>", in: working)
        working = replace(#"~~([^~]+)~~"#, "<del>$1</del>", in: working)
        working = replace(#"\*([^*]+)\*"#, "<em>$1</em>", in: working)
        // Underscore italic only at word boundaries, so snake_case survives.
        working = replace(#"(?<![\w])_([^_]+)_(?![\w])"#, "<em>$1</em>", in: working)

        // 4. Restore code spans.
        for (index, html) in codeSpans.enumerated() {
            working = working.replacingOccurrences(of: token(index), with: html)
        }
        return working
    }

    private static func token(_ index: Int) -> String { "\u{E000}\(index)\u{E001}" }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func replace(_ pattern: String, _ template: String, in s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
    }

    // MARK: - CSS

    private static func css(dark: Bool) -> String {
        let paper      = dark ? "#241E18" : "#F4EFE2"
        let ink        = dark ? "#E7DBC2" : "#2B2620"
        let secondary  = dark ? "#2F2820" : "#EAE2CF"
        let accent     = dark ? "#C99A55" : "#9C6B2E"
        let muted      = dark ? "#B3A98E" : "#6B635A"
        let border     = dark ? "rgba(231,219,194,0.16)" : "rgba(43,38,32,0.16)"
        return """
        /* Force backgrounds to render in print / PDF so the chosen theme
           (including the dark paper) survives, rather than being dropped. */
        * { -webkit-print-color-adjust: exact; print-color-adjust: exact; box-sizing: border-box; }
        :root { color-scheme: \(dark ? "dark" : "light"); }
        html, body { background: \(paper); }
        body {
            color: \(ink);
            font-family: "American Typewriter", "Courier New", serif;
            font-size: 13pt;
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
        pre code { background: none; padding: 0; font-size: 0.92em; }
        blockquote { margin: 0 0 0.9em; padding-left: 14px; border-left: 4px solid \(accent); color: \(muted); }
        hr { border: none; border-top: 1px solid \(border); margin: 1.4em 0; }
        table { border-collapse: collapse; margin: 0 0 0.9em; }
        th, td { border: 1px solid \(border); padding: 6px 12px; }
        th { background: \(secondary); }
        .md-list { margin: 0 0 0.9em; }
        .md-item { display: flex; gap: 0.5em; margin: 0.22em 0; }
        .md-marker { color: \(muted); min-width: 1.5em; text-align: right; }
        .md-item.done { color: \(muted); text-decoration: line-through; }
        """
    }
}
