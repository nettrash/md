//
//  QuickLookPage.swift
//  md
//
//  The page the Quick Look extension shows: the app's own rendered document
//  (`MarkdownHTML.document`), with the two heavy diagram engines left out.
//
//  A Quick Look preview runs under a tight memory ceiling, and Mermaid
//  (≈ 3 MB of script) and PlantUML (≈ 7 MB, a whole JVM's worth of
//  transpiled code) are the engines that can cost hundreds of megabytes on a
//  big diagram. So a Mermaid or PlantUML block is shown as what it is — its
//  source, under a caption saying md draws it — and those engines are never
//  loaded. Everything light still renders as in the app: math (KaTeX),
//  Graphviz, highlighted code and plots, which are already SVG in the markup.
//
//  Pure string work, compiled into both the app (so `mdTests` can pin it)
//  and the extension.
//

import Foundation

enum QuickLookPage {

    /// The caption over a diagram Quick Look does not draw.
    static func caption(_ engine: String) -> String {
        "\(engine) diagram — open in md to see it drawn"
    }

    /// The extension's own stylesheet for those placeholders, added to the page.
    static let style = """
    <style>
    .md-ql-diagram { border: 1px dashed rgba(127,127,127,0.6); border-radius: 6px; padding: 0.6em 0.9em; margin: 1em 0; }
    .md-ql-diagram .md-ql-caption { margin: 0 0 0.5em; font-size: 0.85em; opacity: 0.75; }
    .md-ql-diagram pre { margin: 0; white-space: pre-wrap; }
    </style>
    """

    /// `html` with every Mermaid and PlantUML block turned into a captioned
    /// source placeholder and the Mermaid script no longer included. The
    /// block contents are already escaped by the renderer, so they move
    /// across untouched. With no such block the page is returned as it was,
    /// plus the placeholder stylesheet.
    static func adapt(_ html: String) -> String {
        var out = html
        out = replacingBlocks(in: out, open: "<pre class=\"mermaid\">", close: "</pre>", engine: "Mermaid")
        out = replacingBlocks(in: out, open: "<div class=\"plantuml\">", close: "</div>", engine: "PlantUML")
        out = out.replacingOccurrences(of: "\n<script src=\"rich/mermaid.min.js\"></script>", with: "")
        if let head = out.range(of: "</head>") {
            out.replaceSubrange(head, with: style + "\n</head>")
        }
        return out
    }

    private static func replacingBlocks(in html: String, open: String, close: String, engine: String) -> String {
        var out = ""
        var rest = html[...]
        while let start = rest.range(of: open) {
            guard let end = rest.range(of: close, range: start.upperBound..<rest.endIndex) else { break }
            out += rest[..<start.lowerBound]
            out += "<div class=\"md-ql-diagram\"><p class=\"md-ql-caption\">\(caption(engine))</p><pre>"
            out += rest[start.upperBound..<end.lowerBound]
            out += "</pre></div>"
            rest = rest[end.upperBound...]
        }
        return out + rest
    }
}
