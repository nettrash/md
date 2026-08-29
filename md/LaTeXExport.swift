//
//  LaTeXExport.swift
//  md
//
//  Created by nettrash on 24/07/2026.
//
//  Serializes the parsed block model to LaTeX source — the `.tex` export.
//
//  Every other output md produces turns a formula into a picture (PDF,
//  EPUB, print) or into KaTeX markup (HTML). This one hands the
//  mathematics back as the `$…$` the author wrote, ready to drop into a
//  paper and keep editing. That is the whole point of the format, and it
//  is why a math span — alone among everything here — is copied through
//  untouched while every other scrap of author text is escaped.
//
//  Pure string work: no UIKit, no WebKit, nothing asynchronous. The file
//  writing and the picker live in `DocumentExport`; everything the tests
//  (and the macOS / Android ports) care about is in this file.
//
//  Where LaTeX cannot do what the preview does, it says so instead of
//  dropping: a diagram fence keeps its source in a `verbatim` block under
//  a comment naming the language, and a footnote definition nothing
//  references is still printed at the end.
//

import Foundation

enum LaTeXExport {

    // MARK: - Entry points

    /// One document as a standalone `article` .tex file.
    ///
    /// The result has no title block unless the document's front matter
    /// gives one: an invented `\title` would be a line the author never
    /// wrote, and a file name is not part of a document.
    static func document(_ source: String) -> String {
        let blocks = MarkdownParser.parse(withoutSentinels(source))
        let writer = Writer(headingOffset: 0)
        let body = writer.renderUnit(blocks)
        return assemble(documentClass: "article",
                        writer: writer,
                        titleBlock: titleBlock(fields(of: blocks)),
                        body: body)
    }

    /// A whole book as a `book` .tex file: each chapter a `\chapter`, each
    /// article a `\section`, in the reading order the PDF compile and the
    /// EPUB already use — root articles first, then the chapters, each
    /// chapter's articles in order.
    ///
    /// An article's own headings drop one level (`#` becomes
    /// `\subsection`) so they nest *under* the `\section` the article
    /// itself is, instead of becoming its siblings.
    static func book(_ book: EpubBook) -> String {
        let writer = Writer(headingOffset: 1)
        var parts: [String] = []

        func append(_ article: EpubArticle) {
            parts.append("\\section{\(escape(withoutSentinels(article.title)))}")
            let body = writer.renderUnit(MarkdownParser.parse(withoutSentinels(article.source)))
            if !body.isEmpty { parts.append(body) }
        }

        book.rootArticles.forEach(append)
        for chapter in book.chapters {
            // `book` resets the footnote counter at every chapter, so the
            // numbers `\footnotemark` cites have to restart with it.
            writer.startChapter()
            parts.append("\\chapter{\(escape(withoutSentinels(chapter.title)))}")
            chapter.articles.forEach(append)
        }

        // A book has a title page in every other export, so it keeps one
        // here. `\date{}` rather than no date at all: `\maketitle` would
        // otherwise stamp today, which nobody wrote.
        let title = ["\\title{\(escape(withoutSentinels(book.title)))}", "\\date{}"]
        return assemble(documentClass: "book", writer: writer,
                        titleBlock: title, body: parts.joined(separator: "\n\n"))
    }

    // MARK: - Preamble

    /// Wrap a rendered body in its document class, packages and title block.
    ///
    /// Only the packages the document actually uses are emitted — a plain
    /// document should compile with a preamble short enough to read at a
    /// glance — and each flag was set by the renderer as it emitted the
    /// command that needs it, rather than by scanning the finished text:
    /// a code block quoting `\href` is not a link.
    private static func assemble(documentClass: String, writer: Writer,
                                 titleBlock: [String], body: String) -> String {
        var lines = ["\\documentclass{\(documentClass)}",
                     "\\usepackage[utf8]{inputenc}"]

        // T2A carries the Cyrillic glyphs, and it has to be the *last*
        // encoding listed: `fontenc` makes the last one the document
        // default, and T2A holds the Latin alphabet as well, so this order
        // leaves English untouched while T1 alone would leave Russian to
        // fail character by character. Only a document that actually has
        // Cyrillic in it pays for the switch.
        if containsCyrillic(body) || titleBlock.contains(where: containsCyrillic) {
            lines.append("\\usepackage[T1,T2A]{fontenc}")
        }
        // amsmath is where the mathematics actually lives: `aligned`,
        // `\text`, `\substack`, and the sane spacing around a display. A
        // document with a formula in it loads amsmath whatever the formula
        // says, because guessing which constructs the author reached for
        // means a compile that stops at the first one that was not guessed
        // ("LaTeX Error: Environment aligned undefined"), and it stops the
        // whole file rather than the one formula.
        if writer.needsAmsmath { lines.append("\\usepackage{amsmath}") }
        if writer.needsGraphicx { lines.append("\\usepackage{graphicx}") }
        // `normalem` is not optional: plain `ulem` redefines `\emph` to
        // underline, so loading it for one struck-through word would
        // quietly underline every italic in the document.
        if writer.needsUlem { lines.append("\\usepackage[normalem]{ulem}") }
        // Every table is a `longtable`; see `renderTable` for why nothing
        // here is a float.
        if writer.needsLongtable { lines.append("\\usepackage{longtable}") }
        // hyperref last — it redefines enough of LaTeX's internals that it
        // is the one package with a documented loading order.
        if writer.needsHyperref { lines.append("\\usepackage{hyperref}") }

        lines += titleBlock
        lines.append("\\begin{document}")
        if !titleBlock.isEmpty { lines.append("\\maketitle") }
        lines.append("")
        lines.append(body)
        lines.append("")
        lines.append("\\end{document}")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The document's front-matter fields, first occurrence winning — the
    /// same rule the rest of the app applies to a repeated key.
    private static func fields(of blocks: [MarkdownBlock]) -> [String: String] {
        var fields: [String: String] = [:]
        for case let .frontMatter(matter) in blocks.map(\.kind) {
            for field in matter {
                let key = field.key.lowercased()
                if fields[key] == nil { fields[key] = field.value }
            }
        }
        return fields
    }

    /// `\title` / `\author` / `\date` from front matter. Every other field
    /// is metadata *about* the document — a slug, a set of tags, a layout
    /// name — and has nowhere to go in a typeset one, so it is dropped the
    /// way the HTML and PDF renderers drop it.
    private static func titleBlock(_ fields: [String: String]) -> [String] {
        var lines: [String] = []
        if let title = fields["title"] { lines.append("\\title{\(escape(title))}") }
        if let author = fields["author"] { lines.append("\\author{\(escape(author))}") }
        if let date = fields["date"] {
            lines.append("\\date{\(escape(date))}")
        } else if !lines.isEmpty {
            // `\maketitle` prints today's date when none is given, which is
            // a date the author never wrote into the document.
            lines.append("\\date{}")
        }
        return lines
    }

    // MARK: - Scalar-exact string operations
    //
    // **Nothing in this file may call `contains`, `hasPrefix`, `hasSuffix`,
    // `components(separatedBy:)`, `split(separator:)`, `range(of:)` or
    // `replacingOccurrences(of:with:)` on a `String`.** Use `ScalarText`,
    // which is where those live — shared with `MarkdownParser`, which needs
    // them for exactly the same reason and had exactly the same defect. See
    // `ScalarText.swift` for what grapheme matching costs this writer (a
    // token never restored, a `%` path never refused, a code block's own
    // `\end{verbatim}` never split out) and why scalars are what the Kotlin
    // port already compares.

    // MARK: - Sentinels

    /// The author's text with this writer's own token sentinels taken out
    /// of it, applied to every string that enters the writer — a
    /// document's source, and a book's title, chapter names and article
    /// names and sources.
    ///
    /// U+E000 and U+E001 are what `inline` wraps a span index in, and a
    /// document holding them of its own has its *own* characters read back
    /// as a token index. `text **b <E000>0<E001> x** more` came out as
    /// `text \textbf{b \textbf{ x} more`: the command duplicated, the
    /// author's word dropped, the braces unbalanced and the file refused
    /// with "File ended while scanning use of \textbf". They are also the
    /// one class of character it costs nothing to drop — private-use
    /// scalars no font assigns and inputenc has no definition for, so a
    /// document that kept them would stop at "Unicode character U+E000 not
    /// set up for use with LaTeX" instead. They cannot be typed, only
    /// pasted or generated.
    ///
    /// Nothing else is stripped anywhere in this file, and this is the
    /// only place it happens: the working string of an inline pass is
    /// *made* of these scalars, so a strip applied any later would delete
    /// the writer's own tokens and with them every span in the document.
    static func withoutSentinels(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isSentinel) else { return text }
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !isSentinel(scalar) { out.append(scalar) }
        return String(out)
    }

    private static func isSentinel(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\u{E000}" || scalar == "\u{E001}"
    }

    // MARK: - Escaping

    /// Escape LaTeX's ten special characters in a run of author text.
    ///
    /// Done in a single pass rather than a chain of replacements: three of
    /// the escapes (`\`, `~`, `^`) *contain* characters that are
    /// themselves special, so any sequential ordering re-escapes its own
    /// output.
    ///
    /// The pass walks Unicode *scalars*, not `Character`s, and that is not
    /// a detail. A `Character` is a grapheme cluster, so `#` followed by a
    /// combining mark — U+FE0F U+20E3 makes it the keycap emoji — is one
    /// `Character` that is not equal to `"#"`, and a grapheme walk would
    /// hand LaTeX a live parameter character. Kotlin, which has no
    /// grapheme clusters, escapes the same text: the two ports would be
    /// divergent as well as broken.
    ///
    /// `<`, `>` and `|` are deliberately left alone. They are not TeX
    /// specials — they only render as the wrong glyph under the ancient
    /// OT1 encoding — and the three ports have to agree character for
    /// character on this table.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\textbackslash{}"
            case "~": out += "\\textasciitilde{}"
            case "^": out += "\\textasciicircum{}"
            case "#", "$", "%", "&", "_", "{", "}":
                out.append("\\")
                out.unicodeScalars.append(scalar)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Escape a URL or an image path for `\href` / `\includegraphics`.
    ///
    /// Far less than `escape` does, and deliberately: hyperref reads its
    /// URL argument with its own catcodes, so `_`, `~` and `&` arrive
    /// intact and escaping them would put backslashes into the link
    /// itself. Only the characters that break the *argument* are escaped —
    /// a comment character would swallow the rest of the line, a parameter
    /// character is illegal there, and an unbalanced brace ends the
    /// argument early.
    ///
    /// Scalars rather than characters for the same reason `escape` walks
    /// them: a combining mark must not hide the special in front of it.
    ///
    /// A `%` or a `#` never reaches this by way of `\includegraphics` —
    /// graphicx reads its argument as a file name, where neither the raw
    /// nor the escaped form of either works at all, so `image` refuses the
    /// file outright rather than emitting something that cannot compile.
    static func escapeURL(_ url: String) -> String {
        var out = ""
        out.reserveCapacity(url.unicodeScalars.count)
        for scalar in url.unicodeScalars {
            switch scalar {
            case "\\": out += "\\textbackslash{}"
            case "%", "#", "{", "}":
                out.append("\\")
                out.unicodeScalars.append(scalar)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Percent-decode an image path, or hand back exactly what came in.
    ///
    /// `![](my%20dir/a.png)` is what an editor writes when the author
    /// drags in a file whose folder has a space in its name, and
    /// `my%20dir` is a directory on no disk anywhere: the author meant
    /// `my dir`, and that is what the `.tex` should point at.
    ///
    /// Anything that is not valid percent-encoding is not a mistake to be
    /// corrected — it is a file name that happens to contain a `%` — so it
    /// is returned untouched for `image` to refuse.
    static func percentDecoded(_ path: String) -> String {
        guard ScalarText.contains(path, "%") else { return path }
        var bytes: [UInt8] = []
        let scalars = Array(path.unicodeScalars)
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "%" else {
                bytes.append(contentsOf: Array(String(scalars[index]).utf8))
                index += 1
                continue
            }
            guard index + 2 < scalars.count,
                  let high = hexDigit(scalars[index + 1]),
                  let low = hexDigit(scalars[index + 2]) else { return path }
            bytes.append(high << 4 | low)
            index += 3
        }
        return String(bytes: bytes, encoding: .utf8) ?? path
    }

    private static func hexDigit(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar {
        case "0"..."9": return UInt8(scalar.value - 0x30)
        case "a"..."f": return UInt8(scalar.value - 0x61 + 10)
        case "A"..."F": return UInt8(scalar.value - 0x41 + 10)
        default: return nil
        }
    }

    /// True when `text` holds a Cyrillic letter.
    ///
    /// This is the trigger for the T2A font encoding, and the reason it
    /// matters is the failure mode: with no Cyrillic encoding loaded,
    /// pdfTeX does not stop — the document compiles and the Russian simply
    /// is not in it. Written as a scalar scan rather than a character
    /// class because `\w` and friends mean different things on the two
    /// regular-expression engines this code has to be ported to.
    static func containsCyrillic(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0400...0x04FF,   // Cyrillic
                 0x0500...0x052F,   // Cyrillic Supplement
                 0x2DE0...0x2DFF,   // Cyrillic Extended-A
                 0xA640...0xA69F:   // Cyrillic Extended-B
                return true
            default:
                continue
            }
        }
        return false
    }

    /// LaTeX reads a `[` immediately after `\item` or `\\` as the opening
    /// of an optional argument — a label for the item, a vertical skip for
    /// the row — so anything that *begins* with a bracket would have its
    /// first words eaten. That is not a corner case here: a task list's
    /// checkbox is literally `[x]`, and "[draft]" is an ordinary thing to
    /// write in the first cell of a table. An empty group in front costs
    /// nothing and stops the scan.
    ///
    /// Every caller applies it to *finished* LaTeX, never to a string that
    /// still holds tokens: a line beginning with an undefined footnote
    /// reference begins with a token beforehand and with a `[` after.
    private static func bracketGuard(_ body: String) -> String {
        ScalarText.hasPrefix(body, "[") ? "{}\(body)" : body
    }

    /// A table header cell, set bold.
    ///
    /// `\textbf` is not `{\bfseries …}`: it reads its argument, and the
    /// reading is done by a delimited macro (`\check@nocorr@`) that a
    /// top-level `&` ends the table row out from underneath. So
    /// `\textbf{$\begin{aligned}a &= b\end{aligned}$}` is "Argument of
    /// \check@nocorr@ has an extra }" and `\textbf{\href{…?a=1&b=2}{x}}`
    /// is the same failure in `\href@split`, while either of them in a
    /// *body* cell — where nothing reads an argument — compiles. Both stop
    /// the whole file.
    ///
    /// An extra group is the whole fix: TeX only reads `&` as an alignment
    /// tab at the outermost brace level of a cell, and a delimited
    /// argument scan steps over a group whole. It costs nothing
    /// typographically, so it is written only where there is an alignment
    /// tab to guard and every other header cell in the corpus is
    /// unchanged.
    private static func headerCell(_ cell: String) -> String {
        holdsAlignmentTab(cell) ? "\\textbf{{\(cell)}}" : "\\textbf{\(cell)}"
    }

    /// True when finished LaTeX holds an `&` that is an alignment tab.
    ///
    /// An author's own ampersand is `\&` by the time this runs, so a
    /// backslash swallows the character after it — which also steps over
    /// the `\\` of a multi-line formula without reading its second
    /// backslash as an escape.
    private static func holdsAlignmentTab(_ latex: String) -> Bool {
        let scalars = Array(latex.unicodeScalars)
        var index = 0
        while index < scalars.count {
            if scalars[index] == "\\" {
                index += 2
            } else if scalars[index] == "&" {
                return true
            } else {
                index += 1
            }
        }
        return false
    }

    /// A formula, given an `aligned` of its own when its `\\` and `&` have
    /// nowhere else to live.
    ///
    /// `&` is an alignment tab wherever it is read, so `\[a &= b\]` is
    /// "Misplaced alignment tab character &" in ordinary body text, and
    /// inside a table cell a top-level `\\` ends the *row* from inside math
    /// mode ("Extra }, or forgotten $"). Either stops the whole file. Both
    /// are what `aligned` is for, and both mean the author wrote a
    /// multi-line formula without saying so — so one is supplied, and every
    /// symbol they typed is set exactly where they meant it.
    ///
    /// A formula that opens an environment of its own (`aligned`, `cases`,
    /// `array`, `matrix`) already owns its separators and is left as
    /// written; wrapping that would change what the author's own
    /// environment aligns on.
    static func aligned(_ math: String) -> String {
        guard !ScalarText.contains(math, "\\begin{"),
              ScalarText.contains(math, "\\\\") || ScalarText.contains(math, "&") else { return math }
        return "\\begin{aligned}\(math)\\end{aligned}"
    }

    /// True when `line` sets something on the page — anything at all that
    /// is not white space, a comment or a float.
    ///
    /// `\\` ends a *line*, and LaTeX refuses it with "There's no line here
    /// to end" when the paragraph has not begun. A captioned image alone on
    /// its line is a `figure`, which is a float and begins nothing; a
    /// skipped one is a comment, which is not even read. Either of them
    /// with a soft break after it takes the whole document down, so the
    /// soft-break join asks this before it writes a `\\`.
    ///
    /// Scalar work throughout, and by hand rather than by regular
    /// expression: this runs on finished LaTeX, where a `%` that was
    /// escaped is `\%` and must not be read as the start of a comment.
    static func setsSomething(_ line: String) -> Bool {
        let scalars = Array(line.unicodeScalars)
        let figure = Array("\\begin{figure}".unicodeScalars)
        let endFigure = Array("\\end{figure}".unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                index += 1
            } else if scalar == "%" {
                // A comment runs to the end of its physical line.
                index += 1
                while index < scalars.count, scalars[index] != "\n" { index += 1 }
            } else if ScalarText.firstIndex(of: figure, in: scalars, from: index) == index {
                guard let end = ScalarText.firstIndex(of: endFigure, in: scalars,
                                           from: index + figure.count) else { return false }
                index = end + endFigure.count
            } else {
                return true
            }
        }
        return false
    }

    /// Why `\includegraphics` cannot be handed this path, or nil when it
    /// can.
    ///
    /// graphicx reads its argument as a *file name*: it goes to the file
    /// system, not to the typesetter. So a control sequence in it is not a
    /// character that can be opened — and `{`, `}` and `\` are exactly what
    /// `escapeURL` turns into control sequences, which is right for `\href`
    /// and wrong here — while a `%` comments the rest of the line away
    /// before the argument is even read, and a `#` is an illegal parameter
    /// character. There is no spelling of any of them that works.
    ///
    /// `"` is refused for a reason of its own: graphicx quotes a file name
    /// that has spaces in it with a pair of them, so one the author wrote
    /// breaks graphicx's own parser — `\includegraphics{a"b.png}` is "Use
    /// of ??? doesn't match its definition" and the document stops there.
    /// A sweep of all 95 printable ASCII characters through this function
    /// found it the only one that was neither refused here nor compilable.
    ///
    /// A URL is the same problem from the other end: TeX fetches nothing,
    /// so `\includegraphics{https://…}` is "File not found" and the
    /// document stops there, and a `data:` URI is a picture with no file
    /// name at all.
    static func unreadableImage(_ file: String) -> String? {
        let refused = Array("%#{}\\\"".unicodeScalars)
        for scalar in file.unicodeScalars where refused.contains(scalar) {
            return "is not a file name LaTeX can read"
        }
        if uriScheme(file) != nil {
            return "is a URL, and LaTeX has nothing to fetch it with"
        }
        return nil
    }

    /// The URI scheme of `path` when it is a URL rather than a file name,
    /// nil otherwise.
    ///
    /// A scheme followed by `//` (`https://…`, `file://…`) or the schemeless
    /// `data:` form. Deliberately not "any letters then a colon": `C:` is a
    /// drive and `notes:draft.png` is a file somebody can really have, and
    /// neither should be refused for the shape of its name.
    private static func uriScheme(_ path: String) -> String? {
        let scalars = Array(path.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == ":" { break }
            let letter = (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
            let rest = index > 0
                && ((scalar >= "0" && scalar <= "9")
                    || scalar == "+" || scalar == "-" || scalar == ".")
            guard letter || rest else { return nil }
            index += 1
        }
        guard index > 0, index < scalars.count else { return nil }
        let scheme = ScalarText.string(scalars[0..<index])
        let authority = index + 1 < scalars.count
            && scalars[index + 1] == "/" && index + 2 < scalars.count && scalars[index + 2] == "/"
        guard authority || scheme.lowercased() == "data" else { return nil }
        return scheme
    }

    // MARK: - Context

    /// Where a run of inline text is being written, which decides what
    /// LaTeX is legal in it.
    ///
    /// `.restricted` is a table cell, a footnote's own text or an image
    /// caption — anywhere a float or a display environment is an error
    /// rather than a layout choice ("Not in outer par mode", "Bad math
    /// environment delimiter"), and one that stops the whole file rather
    /// than the one paragraph. It is only ever added, never lifted: a
    /// footnote raised from a table cell is inside the float too.
    private enum Context {
        case body
        case restricted
    }

    // MARK: - Writer

    /// Renders blocks to LaTeX while accumulating what the preamble owes
    /// them: which packages the commands emitted so far need, and where
    /// the document's footnotes are up to.
    ///
    /// A class rather than a value type because the footnote numbering is
    /// a running count that has to survive nested calls — a reference
    /// inside a table cell inside a block quote still takes the next
    /// number the reader will meet.
    private final class Writer {

        /// How far to push the author's headings down, so the structure a
        /// book imposes (`\chapter`, `\section`) sits above them.
        let headingOffset: Int

        var needsAmsmath = false
        var needsGraphicx = false
        var needsHyperref = false
        var needsLongtable = false
        var needsUlem = false

        /// The current unit's footnote definitions, and the order they
        /// were written in — needed to print the ones nothing cites.
        private var definitions: [String: String] = [:]
        private var written: [String] = []
        private var cited: Set<String> = []
        /// id → the number LaTeX will give that footnote. Ours and LaTeX's
        /// counters agree because every `\footnote` and every bare
        /// `\footnotemark` this file emits is emitted in the order it is
        /// numbered, and both step the same counter.
        private var number: [String: Int] = [:]
        private var counter = 0
        /// Inside a footnote's own text (LaTeX cannot nest footnotes) and
        /// inside a moving argument (a section title, a caption) — both
        /// change what a footnote reference is allowed to become.
        private var inFootnote = false
        private var movingArgument = false
        /// Inside a table's header row — the one box in a `longtable` whose
        /// footnote insertions LaTeX throws away.
        private var inTableHead = false
        /// The `\footnotetext` lines the header row being written owes,
        /// emitted after that table's `\end{longtable}`.
        private var headerNotes: [String] = []
        /// What the run of inline text now being written is allowed to
        /// contain.
        private var context: Context = .body

        init(headingOffset: Int) {
            self.headingOffset = headingOffset
        }

        /// Start a new chapter: `book` resets the footnote counter at every
        /// `\chapter`, so the numbers `\footnotemark` cites restart too.
        func startChapter() {
            counter = 0
            number = [:]
        }

        // MARK: Units

        /// One whole document or book article: its blocks, then any
        /// footnote definition the text never referenced.
        ///
        /// Every one of the four stores resets, `number` included. Footnote
        /// ids belong to the file they were written in — each article of a
        /// book numbers its own notes from `[^1]`, which is the normal thing
        /// and not a clash — so carrying the previous article's numbers over
        /// makes the second article's `[^1]` a `\footnotemark[1]` citing the
        /// *first* article's note, and the words the author wrote for it are
        /// never printed at all.
        func renderUnit(_ blocks: [MarkdownBlock]) -> String {
            definitions = [:]
            written = []
            cited = []
            number = [:]
            for case let .footnoteDefinition(id, text) in blocks.map(\.kind)
            where definitions[id] == nil {
                definitions[id] = text
                written.append(id)
            }

            var out = renderBlocks(blocks)
            // A definition nothing points at is still something the author
            // wrote, so it is printed rather than dropped — with no
            // reference of its own, since it has nowhere to point back to.
            let orphans = written.filter { !cited.contains($0) }
            guard !orphans.isEmpty else { return out }
            var trailer = ["% Footnotes defined but never referenced — kept so nothing is lost."]
            for id in orphans {
                counter += 1
                trailer.append("\\footnote{\(footnoteText(definitions[id] ?? ""))}")
            }
            if !out.isEmpty { out += "\n\n" }
            return out + trailer.joined(separator: "\n")
        }

        /// A run of blocks, blank-line separated. Blocks that render to
        /// nothing (private notes, front matter, footnote definitions)
        /// drop out rather than leaving holes in the spacing.
        func renderBlocks(_ blocks: [MarkdownBlock]) -> String {
            blocks.map(renderBlock).filter { !$0.isEmpty }.joined(separator: "\n\n")
        }

        // MARK: Blocks

        /// The five sectioning commands `article` and `book` share. Six
        /// heading levels map onto them, so the deepest two both land on
        /// `\subparagraph` — LaTeX has nothing below it.
        private static let sections = ["section", "subsection", "subsubsection",
                                       "paragraph", "subparagraph"]

        private func sectionCommand(_ level: Int) -> String {
            let index = min(max(level - 1 + headingOffset, 0), Self.sections.count - 1)
            return Self.sections[index]
        }

        func renderBlock(_ block: MarkdownBlock) -> String {
            switch block.kind {
            case let .heading(level, text):
                return "\\\(sectionCommand(level)){\(headingInline(text))}"

            case let .paragraph(text):
                // Soft line breaks are breaks in md's preview, its HTML and
                // its PDF; they stay breaks here rather than reflowing the
                // way raw LaTeX would treat the same newlines.
                return inline(text, softBreaks: true)

            case let .list(ordered, items):
                return renderList(items, ordered: ordered)

            case let .codeBlock(language, code):
                return renderCode(language: language, code: code)

            case let .quote(blocks):
                return "\\begin{quote}\n\(renderBlocks(blocks))\n\\end{quote}"

            case let .table(header, alignments, rows):
                return renderTable(header: header, alignments: alignments, rows: rows)

            case .thematicBreak:
                return "\\par\\noindent\\hrulefill\\par"

            case .pageBreak:
                return "\\newpage"

            case .note:
                // Private author notes never reach a rendered document —
                // they live in the editor and the notes panel only.
                return ""

            case .frontMatter:
                // Hoisted into the preamble's title block; nothing is drawn
                // where it was written, as everywhere else.
                return ""

            case .footnoteDefinition:
                // Inlined at the point of first reference (see
                // `footnoteReference`), or printed by `renderUnit` if
                // nothing references it.
                return ""
            }
        }

        /// A section title: a moving argument, so a footnote inside it
        /// needs `\protect` before LaTeX writes the title to the `.toc`.
        private func headingInline(_ text: String) -> String {
            let saved = movingArgument
            movingArgument = true
            defer { movingArgument = saved }
            return inline(text)
        }

        // MARK: Lists

        /// `itemize` / `enumerate`, nested by the item's level.
        ///
        /// The model is flat — every item carries its own indentation
        /// depth — so the levels are mapped onto a stack of open
        /// environments rather than trusted directly. Two things make that
        /// necessary: LaTeX errors on a `\begin{itemize}` that is not
        /// preceded by an `\item` (which is what a list whose first item is
        /// already indented would produce), and it refuses to nest lists
        /// more than four deep. Opening at most one level per item, and
        /// stopping at four, keeps every item in the output either way.
        private func renderList(_ items: [ListItem], ordered: Bool) -> String {
            let environment = ordered ? "enumerate" : "itemize"
            var lines: [String] = []
            var open: [Int] = []

            for item in items {
                while let deepest = open.last, item.level < deepest {
                    lines.append("\\end{\(environment)}")
                    open.removeLast()
                }
                if open.isEmpty || (item.level > open[open.count - 1] && open.count < 4) {
                    lines.append("\\begin{\(environment)}")
                    open.append(item.level)
                }
                var body = inline(item.text)
                if let done = item.task {
                    // A literal checkbox rather than a package: `amssymb`'s
                    // boxes would be a dependency for one glyph, and the
                    // author reads `[x]` in the source anyway.
                    body = "\(done ? "[x]" : "[\\,]") \(body)"
                }
                lines.append("\\item \(LaTeXExport.bracketGuard(body))")
            }
            lines += open.map { _ in "\\end{\(environment)}" }
            return lines.joined(separator: "\n")
        }

        // MARK: Code, diagrams and data

        private static let verbatimEnd = "\\end{verbatim}"

        /// A fenced block. The info string decides what it is, using the
        /// same names the HTML renderer answers to, so the two agree about
        /// every fence in the document.
        private func renderCode(language: String?, code: String) -> String {
            let name = language ?? ""
            switch name.lowercased() {
            case "mermaid", "plantuml", "puml", "plant-uml":
                return diagram(language: name, code: code)
            case let engine where MarkdownHTML.graphvizEngines[engine] != nil:
                return diagram(language: name, code: code)
            case let delimited where delimited == "csv" || delimited == "tsv":
                // Already a table everywhere else in the app; the parse and
                // the alignment rule are shared with the HTML renderer so
                // the same spreadsheet lands the same way in both.
                guard let table = MarkdownHTML.delimitedTable(
                    code, separator: delimited == "tsv" ? "\t" : ",") else {
                    return verbatim(code)
                }
                return renderTable(header: table.header,
                                   alignments: table.alignments, rows: table.rows)
            case "math", "latex", "tex":
                // The author's mathematics, untouched — the point of the
                // whole export.
                return display("\n\(code)\n")
            case "plot":
                // A plot is an `<svg>` everywhere else, with no engine behind
                // it — but LaTeX has no SVG either, and pgfplots would be a
                // second renderer to keep in step with this one. So the fence
                // travels the way the other figures do: verbatim, under a
                // comment naming it, for the author to draw with whatever
                // package their document already loads.
                return diagram(language: name, code: code)
            default:
                return verbatim(code)
            }
        }

        /// A diagram fence. LaTeX has no Mermaid, PlantUML or Graphviz, and
        /// md's renderers are JavaScript engines that cannot travel in a
        /// `.tex` file — so the source is kept verbatim under a comment
        /// naming the language, and the author decides what to do with it.
        /// Dropping it would lose a whole figure without saying so.
        private func diagram(language: String, code: String) -> String {
            "% \(language) diagram source — LaTeX has no renderer for it, so it is kept as written.\n"
                + verbatim(code)
        }

        /// Wrap code in `verbatim`. The content is not escaped: verbatim is
        /// verbatim, and escaping it would put backslashes on the page.
        ///
        /// One hazard is real. LaTeX's `verbatim` scans for the *characters*
        /// `\end{verbatim}` — the environment's terminator is defined with
        /// `\`, `{` and `}` as ordinary characters precisely so it can be
        /// found inside verbatim text — so a code block that quotes them
        /// closes the environment early and spills the rest of the block
        /// into the document as LaTeX to execute. Nothing can be inserted to
        /// escape it without changing the code, so the block is split around
        /// each occurrence and the terminator itself set with `\verb`,
        /// which keeps every character the author typed.
        private func verbatim(_ code: String) -> String {
            let pieces = ScalarText.split(code, Self.verbatimEnd)
            guard pieces.count > 1 else { return verbatimBlock(pieces[0]) }
            var out: [String] = []
            for (index, piece) in pieces.enumerated() {
                if index > 0 {
                    out.append("\\noindent\\verb|\(Self.verbatimEnd)|\\par")
                }
                if !piece.isEmpty { out.append(verbatimBlock(piece)) }
            }
            return out.joined(separator: "\n")
        }

        private func verbatimBlock(_ code: String) -> String {
            "\\begin{verbatim}\n\(code)\n\(Self.verbatimEnd)"
        }

        // MARK: Tables

        /// A `longtable`, its column spec taken from the alignments the
        /// author wrote in the delimiter row.
        ///
        /// A `longtable` and not a `tabular` inside a `table` float, and
        /// the difference is whether the author's rows are in the PDF. A
        /// float cannot break across a page, so a table taller than one
        /// does not overflow onto the next — it is **truncated**. The
        /// compile is exit 0, the PDF simply stops at the row that filled
        /// the page, and the only trace is one "Float too large for page"
        /// line in a log nobody reads. A sixty-row table loses its last
        /// five rows and says nothing. `longtable` breaks across pages, so
        /// every row the author wrote is printed.
        ///
        /// Not being a float pays a second time. LaTeX typesets no footnote
        /// text from inside a float: with a plain `\footnote` in a cell the
        /// mark prints, the counter steps, and the note's words are not on
        /// the page. Inside a `longtable` an ordinary `\footnote` works, so
        /// every *body* cell keeps the note it cites where the author put
        /// the reference. The header row is the one exception, and the last
        /// paragraph here is why.
        ///
        /// The header repeats at the top of each page (`\endhead`) — a
        /// reader who turns to the second page of a table needs to know
        /// what its columns are.
        ///
        /// The width is the widest row in the table, not the header's: a
        /// row with a cell too many would otherwise overrun the alignment
        /// and take the rest of the document down with it, and truncating
        /// it would throw the cell away.
        ///
        /// The head is the one place inside a `longtable` where a plain
        /// `\footnote` still loses its words, and `\endhead` is why: the
        /// header row is typeset **once** into a box that is reinserted at
        /// every page break, and LaTeX discards a footnote insertion made
        /// inside a box. The compile is exit 0 and the note's text is on no
        /// page. So a note first cited from the head is split — see
        /// `footnoteReference` — and the `\footnotetext` it owes is written
        /// after `\end{longtable}`, where it is read exactly once.
        private func renderTable(header: [String], alignments: [ColumnAlignment],
                                 rows: [[String]]) -> String {
            needsLongtable = true
            let columns = max(header.count, rows.map(\.count).max() ?? 0)
            guard columns > 0 else { return "" }

            let spec = (0..<columns).map { column -> String in
                guard column < alignments.count else { return "l" }
                switch alignments[column] {
                case .leading: return "l"
                case .center: return "c"
                case .trailing: return "r"
                }
            }.joined()

            func row(_ cells: [String], heading: Bool) -> String {
                let rendered = (0..<columns).map { column -> String in
                    let cell = column < cells.count
                        ? inline(cells[column], context: .restricted) : ""
                    return heading && !cell.isEmpty ? LaTeXExport.headerCell(cell) : cell
                }
                return LaTeXExport.bracketGuard(rendered.joined(separator: " & ")) + " \\\\"
            }

            // The header row is rendered first — it is what the reader
            // meets first, so its notes take the first numbers — and while
            // `inTableHead` is set, so a note cited from it is split rather
            // than dropped into the saved head box.
            let savedHead = inTableHead
            let savedNotes = headerNotes
            inTableHead = true
            headerNotes = []
            let head = row(header, heading: true)
            let notes = headerNotes
            inTableHead = savedHead
            headerNotes = savedNotes

            var lines = ["\\begin{longtable}{\(spec)}", "\\hline",
                         head, "\\hline", "\\endhead"]
            lines += rows.map { row($0, heading: false) }
            lines += ["\\hline", "\\end{longtable}"]
            lines += notes
            return lines.joined(separator: "\n")
        }

        // MARK: Footnotes

        /// A reference to `id`, resolved the moment the reader meets it.
        ///
        /// The first reference to a defined note carries the note's text —
        /// that is what a LaTeX footnote *is*, and the reason this export
        /// has no collected list at the foot of the document the way the
        /// HTML one does. A later reference to the same note can only cite
        /// the number, which works because every mark here is emitted in
        /// the order it was numbered, so LaTeX's counter and this one never
        /// disagree.
        ///
        /// A reference with no definition is not a footnote at all, so it
        /// goes back to being the text the author typed.
        private func footnoteReference(_ id: String) -> String {
            let protection = movingArgument ? "\\protect" : ""
            // LaTeX cannot nest footnotes, so a reference inside a note's
            // own text stays literal — the same degradation the HTML
            // renderer applies to the same case.
            guard !inFootnote, let text = definitions[id] else {
                return LaTeXExport.escape("[^\(id)]")
            }
            cited.insert(id)
            if let existing = number[id] {
                return "\(protection)\\footnotemark[\(existing)]"
            }
            counter += 1
            number[id] = counter
            // The header row is the exception, and only the header row: it
            // is typeset once into the box `\endhead` reinserts at every
            // page break, and LaTeX drops a footnote insertion made inside
            // a box — the mark prints, the counter steps, and the note's
            // words are on no page at all. The standard idiom is the mark
            // here and the text after the table, and the counter is stepped
            // by hand because `\footnotemark[n]` does not step it: a body
            // cell further down this same table takes the next number, and
            // would otherwise print this one's.
            if inTableHead {
                let mark = counter
                headerNotes.append("\\footnotetext[\(mark)]{\(footnoteText(text))}")
                return "\\stepcounter{footnote}\(protection)\\footnotemark[\(mark)]"
            }
            // A plain `\footnote` everywhere else, a table *body* cell
            // included: the tables here are `longtable`s and a `longtable`
            // is not a float, so the note's own words are typeset where a
            // `table` would have dropped them.
            return "\(protection)\\footnote{\(footnoteText(text))}"
        }

        /// A footnote's own text is inline Markdown, rendered with nesting
        /// disabled for the duration — and restricted, because a footnote
        /// is no more able to hold a float than a table cell is.
        private func footnoteText(_ text: String) -> String {
            let saved = inFootnote
            inFootnote = true
            defer { inFootnote = saved }
            return inline(text, context: .restricted)
        }

        // MARK: Inline

        /// Convert a block's inline Markdown to LaTeX.
        ///
        /// The ordering is the whole of the correctness here, and it is not
        /// the HTML renderer's. There, escaping can run first because none
        /// of `&`, `<`, `>` is Markdown syntax; here `_` and `~` are both
        /// LaTeX specials *and* emphasis delimiters, so escaping first
        /// would destroy the very markup that still has to be found.
        ///
        /// So the commands go in first — but as *tokens*, never as text.
        /// Each conversion replaces its delimiters with a private-use token
        /// standing for the LaTeX it becomes and leaves the author's words
        /// between them, which does two things at once: the escaping pass
        /// at the end sees author text and nothing else (no backslash this
        /// file emitted is ever escaped), and markup nested inside a link
        /// label or a bold run is still plain text when the later passes
        /// look for it.
        ///
        /// The patterns themselves are the HTML renderer's, deliberately:
        /// if the two disagreed about what a formula is, the preview and
        /// the `.tex` would disagree about the same document. That includes
        /// the spelled-out `[\p{L}\p{N}_]` word guards — `\w` is a
        /// different set of characters again on the JVM the Android tests
        /// run on, and the three ports have to call the same span
        /// mathematics.
        ///
        /// `context` is *added* to whatever is already in force, never
        /// substituted for it: a footnote raised from a table cell is still
        /// inside the float.
        func inline(_ text: String, softBreaks: Bool = false,
                    context: Context = .body) -> String {
            // A pass owns its tokens. `image` starts a second, complete
            // pass over the alt text in the middle of this one, and the two
            // stores must never meet: a token belonging to this pass that
            // ended up inside that one's output would be restored by
            // nobody, and the author's formula would print as U+E000.
            let savedSpans = spans
            let savedContext = self.context
            spans = Spans()
            if context == .restricted { self.context = .restricted }
            defer {
                spans = savedSpans
                self.context = savedContext
            }

            var working = text

            // 1. Literal spans first — their content must not be read as
            //    markup, and math's must not be escaped either. Code wins
            //    over math, so `$x$` in backticks stays code; the inline
            //    `$…$` form keeps its currency guard so "$5 and $10" is
            //    prose. `\texttt` rather than `\verb`: this text has to
            //    survive inside a section title, a caption and a table
            //    cell, where `\verb` is not allowed.
            working = substitute(#"`([^`]+)`"#, in: working,
                                 options: [.dotMatchesLineSeparators]) {
                "\\texttt{\(LaTeXExport.escape($0[1]))}"
            }
            working = substitute(#"\$\$([\s\S]+?)\$\$"#, in: working,
                                 options: [.dotMatchesLineSeparators]) { self.display($0[1]) }
            working = substitute(#"\\\[([\s\S]+?)\\\]"#, in: working,
                                 options: [.dotMatchesLineSeparators]) { self.display($0[1]) }
            working = substitute(#"(?<![\p{L}\p{N}_$])\$([^$\n]+?)\$(?![\p{L}\p{N}_$])"#,
                                 in: working) { self.inlineMath($0[1]) }
            working = substitute(#"\\\(([^\n]+?)\\\)"#, in: working) { self.inlineMath($0[1]) }

            // 2. Images before links (image syntax is link syntax with a
            //    `!` in front, so the link pass would eat it), links before
            //    emphasis. A source title is matched only so it is consumed
            //    — it is a browser tooltip, and a typeset page has nowhere
            //    to put one.
            working = substitute(#"!\[([^\]]*)\]\(([^)\s]+)\s+"(.*?)"\)"#, in: working) {
                self.image(alt: $0[1], path: $0[2])
            }
            working = substitute(#"!\[([^\]]*)\]\(([^)\s]+)\)"#, in: working) {
                self.image(alt: $0[1], path: $0[2])
            }
            working = wrap(#"\[([^\]]+)\]\(([^)\s]+)\s+"(.*?)"\)"#, in: working,
                           close: "}") { self.href($0[2]) }
            working = wrap(#"\[([^\]]+)\]\(([^)\s]+)\)"#, in: working,
                           close: "}") { self.href($0[2]) }

            // 3. Footnote references after images and links, and for the
            //    same reason the HTML renderer runs them last: converting
            //    one first would let an image carry a whole `\footnote`
            //    into its caption. Running here, a reference written inside
            //    a link label simply stops that label being a link.
            working = substitute(#"\[\^([A-Za-z0-9_-]+)\]"#, in: working) {
                self.footnoteReference($0[1])
            }

            // 4. Emphasis: bold before italic so `**` wins, underscore
            //    italic only at word boundaries so snake_case survives.
            working = wrap(#"\*\*([^*]+)\*\*"#, in: working, close: "}") { _ in "\\textbf{" }
            working = wrap(#"__([^_]+)__"#, in: working, close: "}") { _ in "\\textbf{" }
            working = wrap(#"~~([^~]+)~~"#, in: working, close: "}") { _ in
                self.needsUlem = true
                return "\\sout{"
            }
            working = wrap(#"\*([^*]+)\*"#, in: working, close: "}") { _ in "\\emph{" }
            working = wrap(#"(?<![\p{L}\p{N}_])_([^_]+)_(?![\p{L}\p{N}_])"#, in: working,
                           close: "}") { _ in "\\emph{" }

            // 5. Everything still in the string is the author's own text.
            //    Tokens are private-use scalars and digits, none of them
            //    special, so they pass through untouched.
            working = LaTeXExport.escape(working)

            // 6. Restore the spans, and with them the soft breaks.
            //
            //    The lines are split while the spans are still tokens — a
            //    multi-line formula is one token here, and would otherwise
            //    collect a `\\` at each of its own newlines — but the
            //    bracket guard runs on the *restored* line, the way the
            //    item and row guards do. A line that begins with an
            //    undefined footnote reference begins with a token now and
            //    with a `[` a moment later, and `\\[` is a vertical skip.
            //    A soft break is only written between two lines that both
            //    set something. `\\` ends a line, and LaTeX refuses it with
            //    "There's no line here to end" when the paragraph has not
            //    begun — which is exactly a captioned image alone on its
            //    line (a float) or a skipped one (a comment). Those join
            //    with an ordinary newline, which is what LaTeX reads as
            //    "the paragraph goes on" anyway.
            guard softBreaks else { return restored(working) }
            let lines = ScalarText.split(working, "\n").map(restored)
            var out = lines[0]
            var opened = LaTeXExport.setsSomething(lines[0])
            for line in lines.dropFirst() {
                if opened, LaTeXExport.setsSomething(line) {
                    out += "\\\\\n" + LaTeXExport.bracketGuard(line)
                    opened = true
                } else {
                    // Never two newlines in a row: a blank line is a
                    // paragraph break, and one straight after a `\\` is the
                    // very error this is avoiding.
                    if !ScalarText.hasSuffix(out, "\n") { out += "\n" }
                    out += line
                    opened = opened || LaTeXExport.setsSomething(line)
                }
            }
            return out
        }

        /// An inline formula. Nothing about it changes with the context —
        /// `$…$` is legal in a table cell, a caption and a footnote alike —
        /// but its own `\\` and `&` still have to be given somewhere to
        /// live, and the document still owes amsmath for whatever is in it.
        private func inlineMath(_ math: String) -> String {
            needsAmsmath = true
            return "$\(LaTeXExport.aligned(math))$"
        }

        /// A display formula — or an inline one, where LaTeX will not open
        /// a display environment at all. `\[…\]` in a table cell is "Bad
        /// math environment delimiter" and the file stops there; set inline
        /// the formula is smaller than the author asked for, but every
        /// symbol of it is still on the page.
        private func display(_ math: String) -> String {
            needsAmsmath = true
            let body = LaTeXExport.aligned(math)
            return context == .restricted ? "$\(body)$" : "\\[\(body)\\]"
        }

        private func href(_ url: String) -> String {
            needsHyperref = true
            return "\\href{\(LaTeXExport.escapeURL(url))}{"
        }

        /// An image.
        ///
        /// In body text, alt text makes it a captioned `figure`, which is
        /// what alt text is for on a printed page; without alt text, just
        /// the graphic, since an empty `\caption` would print a bare
        /// "Figure 1".
        ///
        /// The uncaptioned form carries a `\noindent`, and it earns its
        /// place: a graphic exactly `\linewidth` wide starting a paragraph
        /// is pushed over the margin by the paragraph indent, and LaTeX
        /// reports an overfull box on every single image in the document.
        /// Inside the `figure` the same graphic is already unindented.
        ///
        /// In a restricted place there is no float to be had — a `figure`
        /// in a table cell is "Not in outer par mode" and in a footnote it
        /// is "Float(s) lost", and either takes the whole file down — so
        /// the graphic is written bare and the alt text goes beside it in
        /// italic. It is a description of the picture, not a sentence of
        /// the author's prose, and dropping it because there is no
        /// `\caption` to put it in would lose words somebody wrote.
        private func image(alt: String, path: String) -> String {
            let file = LaTeXExport.percentDecoded(path)
            if let reason = LaTeXExport.unreadableImage(file) {
                return skipped(file: file, reason: reason, alt: alt)
            }
            needsGraphicx = true
            let include = "\\includegraphics[width=\\linewidth]{\(LaTeXExport.escapeURL(file))}"
            if context == .restricted {
                guard !alt.isEmpty else { return include }
                return "\(include) \\emph{\(altText(alt))}"
            }
            guard !alt.isEmpty else { return "\\noindent\(include)" }
            let saved = movingArgument
            movingArgument = true
            defer { movingArgument = saved }
            return """
            \\begin{figure}[ht]
            \\centering
            \(include)
            \\caption{\(altText(alt))}
            \\end{figure}
            """
        }

        /// An image LaTeX cannot include, set as the words the author wrote
        /// about it.
        ///
        /// Nothing here vanishes without saying so: the alt text is the
        /// author's own description and is printed in place of the picture,
        /// and the file is named in a comment so the reason is in the file
        /// they are handed.
        ///
        /// The comment comes **last** and ends with a newline, and that is
        /// the whole of its safety. `%` runs to the end of its physical
        /// line, so a comment in front of the text would swallow the text,
        /// and one without a newline after it would swallow the rest of a
        /// table row or the rest of a sentence.
        private func skipped(file: String, reason: String, alt: String) -> String {
            let note = "% md: image skipped — \(file) \(reason).\n"
            guard !alt.isEmpty else { return note }
            return "\\emph{\(altText(alt))}\n\(note)"
        }

        /// An image's alt text as LaTeX.
        ///
        /// A fresh, complete pass over the Markdown the author wrote. `alt`
        /// arrives here carrying the tokens of the pass that found this
        /// image, and re-tokenising a half-tokenised string leaves those
        /// tokens behind for the outer restore never to see — which is a
        /// formula, a code span or a bold run silently replaced by U+E000.
        ///
        /// Restricted, wherever it is going: a caption cannot hold a float
        /// or a display any more than a table cell can.
        private func altText(_ alt: String) -> String {
            inline(rawSource(of: alt), context: .restricted)
        }

        // MARK: Token plumbing

        /// The spans one inline pass has lifted out of the text: for each
        /// token, the LaTeX it stands for and the Markdown it was made
        /// from.
        ///
        /// The source half is there for exactly one caller — an image's alt
        /// text, which is captured from a string this pass has already
        /// tokenised and has to be rendered from what the author typed.
        private struct Spans {
            private(set) var latex: [String] = []
            private(set) var source: [String] = []
            var count: Int { latex.count }

            mutating func append(latex: String, source: String) {
                self.latex.append(latex)
                self.source.append(source)
            }
        }

        private var spans = Spans()

        private static func token(_ index: Int) -> String { "\u{E000}\(index)\u{E001}" }

        /// Put the LaTeX back where the tokens are.
        ///
        /// Newest span first: a span's replacement can only ever hold a
        /// token from a pass older than itself, so resolving downwards
        /// finishes in one sweep whatever nests inside what.
        private func restored(_ text: String) -> String {
            resolve(text) { spans.latex[$0] }
        }

        /// The author's own Markdown for a stretch of the working string,
        /// every token in it put back to the source it was made from.
        private func rawSource(of text: String) -> String {
            resolve(text) { spans.source[$0] }
        }

        private func resolve(_ text: String, _ replacement: (Int) -> String) -> String {
            guard text.unicodeScalars.contains("\u{E000}") else { return text }
            var out = text
            for index in stride(from: spans.count - 1, through: 0, by: -1) {
                out = ScalarText.replacing(out, Self.token(index),
                                                  with: replacement(index))
            }
            return out
        }

        /// Replace every match of `pattern` with a token standing for
        /// `transform(groups)`, a finished LaTeX fragment the escaping pass
        /// must never see. `groups[0]` is the whole match.
        ///
        /// The transforms run **forward** and the splicing runs backward:
        /// footnote numbering depends on the order the reader meets the
        /// references, while rewriting from the end is what keeps the
        /// earlier ranges valid.
        private func substitute(_ pattern: String, in text: String,
                                options: NSRegularExpression.Options = [],
                                transform: ([String]) -> String) -> String {
            splice(pattern, in: text, options: options) { match in
                // The transform runs before the span is filed because it
                // may start an inline pass of its own — an image caption
                // does — which borrows the store and hands it back.
                let latex = transform(match.groups)
                spans.append(latex: latex, source: match.groups[0])
                return (Self.token(spans.count - 1), nil)
            }
        }

        /// Replace every match with an opening token, the text of capture
        /// group 1, and a closing token — so the command's braces are
        /// hidden from the escaping pass while the author's words between
        /// them stay ordinary text that the later passes can still match.
        private func wrap(_ pattern: String, in text: String,
                          close: String, open: ([String]) -> String) -> String {
            splice(pattern, in: text) { match in
                let latex = open(match.groups)
                let first = spans.count
                spans.append(latex: latex, source: match.before)
                spans.append(latex: close, source: match.after)
                return (Self.token(first), Self.token(first + 1))
            }
        }

        /// One regex match, as the passes need it: the captured groups, and
        /// the author's own text on either side of group 1 — the
        /// delimiters, which is what `wrap` replaces and what it has to be
        /// able to give back.
        private struct Match {
            let groups: [String]
            let before: String
            let after: String
        }

        /// The shared rewrite: match forward, build each replacement in
        /// reading order, then splice from the end of the string back.
        private func splice(_ pattern: String, in text: String,
                            options: NSRegularExpression.Options = [],
                            build: (Match) -> (open: String, close: String?)) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                return text
            }
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return text }

            let replacements = matches.map { match -> String in
                let groups = (0..<match.numberOfRanges).map { index -> String in
                    let range = match.range(at: index)
                    return range.location == NSNotFound ? "" : ns.substring(with: range)
                }
                let whole = match.range
                let inner = match.numberOfRanges > 1
                    ? match.range(at: 1) : NSRange(location: NSNotFound, length: 0)
                var before = ""
                var after = ""
                if inner.location != NSNotFound {
                    before = ns.substring(with: NSRange(
                        location: whole.location, length: inner.location - whole.location))
                    let innerEnd = inner.location + inner.length
                    after = ns.substring(with: NSRange(
                        location: innerEnd, length: whole.location + whole.length - innerEnd))
                }
                let built = build(Match(groups: groups, before: before, after: after))
                guard let close = built.close else { return built.open }
                return built.open + (groups.count > 1 ? groups[1] : "") + close
            }

            var result = text
            for (match, replacement) in zip(matches, replacements).reversed() {
                result = (result as NSString).replacingCharacters(in: match.range,
                                                                  with: replacement)
            }
            return result
        }
    }
}
