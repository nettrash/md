//
//  MarkdownParser.swift
//  md
//
//  Created by nettrash on 28/06/2026.
//
//  A small, dependency-free, block-level Markdown parser. It splits the
//  source into a flat list of block elements (headings, paragraphs,
//  lists, code fences, block quotes, tables, rules) which `MarkdownView`
//  renders with SwiftUI. *Inline* formatting inside a block (bold,
//  italic, code spans, links, strikethrough) is intentionally left to
//  Apple's `AttributedString(markdown:)` at render time — see
//  `MarkdownInline.swift` — so this file only ever reasons about lines.
//
//  This is a pragmatic subset of CommonMark + the common GitHub
//  extensions (fenced code, task lists, tables, strikethrough). It is
//  not a conformant CommonMark implementation, and deliberately so: the
//  goal is a faithful, readable preview of everyday Markdown, not spec
//  completeness. Parsing is single-pass and line-oriented, which keeps
//  it fast enough to re-run on every keystroke.
//
//  **Every delimiter here is matched scalar by scalar, through
//  `ScalarText` or a walk of `unicodeScalars` — never with `String`'s own
//  `hasPrefix` / `contains` / `firstIndex(of:)` and never by comparing a
//  `Character`.** Those match extended grapheme clusters: a combining
//  mark, a variation selector or a ZWJ written after a delimiter fuses
//  onto it, the cluster is no longer equal to the plain delimiter, and
//  the block is silently not recognised. `- ́[draft]` was a paragraph
//  here and a list on Android; a fence whose ``` carried a mark was a
//  paragraph rather than a code block; the same for a table's `|`, a
//  `[^a]:` definition, a `>` quote marker, a heading's `#`, and the
//  `-->` that ends an HTML comment — that last one swallowed the rest of
//  the document. Since this file is what the preview, the HTML, the PDF,
//  the EPUB, the outline and the notes panel are all built from, each of
//  those was the same document being a different document on the two
//  platforms. See `ScalarText.swift`; the exceptions, all of them
//  provably exact as they stand, are commented where they are.
//

import Foundation

// MARK: - Model

/// One rendered block. Identity in the view comes from position (the
/// renderer keys its `ForEach` on index), so blocks carry no stored id —
/// a fresh id per parse would defeat SwiftUI's diffing on every keystroke.
struct MarkdownBlock {
    let kind: Kind

    enum Kind {
        case heading(level: Int, text: String)
        case paragraph(text: String)
        case list(ordered: Bool, items: [ListItem])
        case codeBlock(language: String?, code: String)
        case quote(blocks: [MarkdownBlock])
        case table(header: [String], alignments: [ColumnAlignment], rows: [[String]])
        case thematicBreak
        case pageBreak
        case note(text: String)
        case frontMatter(fields: [MetadataField])
        case footnoteDefinition(id: String, text: String)
    }
}

/// One `key: value` line of a document's front matter. Order is the order
/// they were written in, and duplicate keys are kept rather than collapsed —
/// this is a record of what the author wrote, not a dictionary.
struct MetadataField: Equatable {
    let key: String
    let value: String
}

/// One table-of-contents entry. `line` is the 0-based source line of the
/// heading, so the editor can jump to it; `slug` matches the `id` the HTML
/// renderer gives the same heading, so the preview can scroll to it.
struct OutlineEntry {
    let level: Int
    let text: String
    let slug: String
    let line: Int
}

/// One private author note (`<!-- note: … -->`). `line` is the 0-based
/// source line the note starts on, so the notes panel can jump to it.
struct NoteEntry {
    let text: String
    let line: Int
}

/// A single list row. `level` is the indentation depth (0 = top level)
/// so the renderer can inset nested items without a full tree. `task`
/// is non-nil for GitHub task-list items (`- [ ]` / `- [x]`).
struct ListItem {
    let text: String
    let level: Int
    let ordinal: Int?
    let task: Bool?
}

enum ColumnAlignment {
    case leading, center, trailing
}

// MARK: - Parser

enum MarkdownParser {

    /// Parse Markdown source into a flat list of blocks. `quoteDepth` is
    /// internal: block quotes recurse, and the cap (see the quote branch)
    /// bounds that recursion so a pathological run of `>` can't overflow
    /// the stack on the main thread.
    static func parse(_ source: String, quoteDepth: Int = 0) -> [MarkdownBlock] {
        // Normalise line endings, then work on a line array with an index
        // cursor. Lines keep their content but never their terminator.
        let lines = normalizedLines(source)
        var blocks: [MarkdownBlock] = []
        var i = 0

        // Front matter: a metadata block fenced off at the very top of the
        // file, the convention every static-site generator and note-taker
        // uses (Jekyll, Hugo, Obsidian, Quarto). Without this the opening
        // `---` reads as a thematic break and the metadata as stray prose,
        // which is how such a file used to look here. It is only front
        // matter at the very start of the document and never inside a quote.
        if quoteDepth == 0, let matter = parseFrontMatter(lines, from: &i) {
            blocks.append(.init(kind: .frontMatter(fields: matter)))
        }

        while i < lines.count {
            let line = lines[i]

            // Blank line — paragraph / block separator, nothing to emit.
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }

            // Fenced code block: ``` or ~~~ (optionally indented, with an
            // optional info string / language on the opening fence).
            if let fence = FenceMarker(line: line) {
                var code: [String] = []
                i += 1
                while i < lines.count {
                    if fence.closes(lines[i]) { i += 1; break }
                    // Strip the fence's own indentation from body lines so
                    // an indented fence doesn't carry phantom leading spaces.
                    code.append(fence.stripIndent(lines[i]))
                    i += 1
                }
                blocks.append(.init(kind: .codeBlock(language: fence.language,
                                                      code: code.joined(separator: "\n"))))
                continue
            }

            // Thematic break: a line of 3+ -, * or _ (spaces allowed).
            if isThematicBreak(line) {
                blocks.append(.init(kind: .thematicBreak))
                i += 1
                continue
            }

            // Page break: a line of exactly `\newpage` (or `\pagebreak`),
            // the Pandoc convention — where the author says a page ends.
            // Shown as a subtle divider in the preview; starts a new page
            // in print and in the shared / exported PDF.
            if isPageBreak(line) {
                blocks.append(.init(kind: .pageBreak))
                i += 1
                continue
            }

            // Footnote definition: `[^id]: the note`, the GitHub / Pandoc
            // convention. Collected here so it never renders where it was
            // written — the renderer gathers the definitions and prints them
            // together at the foot of the document. Soft-wrapped continuation
            // lines are absorbed the way a list item's are.
            if let definition = parseFootnoteDefinition(line) {
                var text = definition.text
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).isEmpty { break }
                    if parseFootnoteDefinition(l) != nil || FenceMarker(line: l) != nil
                        || isThematicBreak(l) || parseHeading(l) != nil || isQuote(l)
                        || isPageBreak(l) || isCommentStart(l) || listMarker(l) != nil {
                        break
                    }
                    text += " " + l.trimmingCharacters(in: .whitespaces)
                    i += 1
                }
                blocks.append(.init(kind: .footnoteDefinition(id: definition.id, text: text)))
                continue
            }

            // HTML comment block: `<!-- … -->`, possibly spanning lines.
            // A `<!-- note: … -->` comment is the author's private note —
            // kept as a block so the notes panel can list it. Any other
            // comment is simply dropped. Neither appears in the preview,
            // the PDF, or print.
            if isCommentStart(line) {
                var raw: [String] = []
                while i < lines.count {
                    raw.append(lines[i])
                    let closed = ScalarText.contains(lines[i], "-->")
                    i += 1
                    if closed { break }
                }
                if let note = noteText(raw.joined(separator: "\n")) {
                    blocks.append(.init(kind: .note(text: note)))
                }
                continue
            }

            // ATX heading: 1–6 leading #, a space, then the text.
            if let heading = parseHeading(line) {
                blocks.append(.init(kind: .heading(level: heading.level, text: heading.text)))
                i += 1
                continue
            }

            // GFM table: current line is a header row and the next line is
            // the delimiter row (|---|:--:|). Requires the lookahead match.
            if i + 1 < lines.count, let table = parseTable(header: line, delimiter: lines[i + 1]) {
                var rows: [[String]] = []
                i += 2
                while i < lines.count, ScalarText.contains(lines[i], "|"),
                      !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(splitTableRow(lines[i], columns: table.header.count))
                    i += 1
                }
                blocks.append(.init(kind: .table(header: table.header,
                                                 alignments: table.alignments,
                                                 rows: rows)))
                continue
            }

            // Block quote: collect the run of `>`-prefixed lines, strip one
            // level of marker, and parse the inner content recursively. The
            // depth cap prevents a line of thousands of `>` (one recursion
            // per marker) from overflowing the stack — past the cap we stop
            // recursing and keep the remaining text as a plain paragraph.
            if isQuote(line) {
                var inner: [String] = []
                while i < lines.count, isQuote(lines[i]) {
                    inner.append(stripQuoteMarker(lines[i]))
                    i += 1
                }
                let innerText = inner.joined(separator: "\n")
                let innerBlocks = quoteDepth < 32
                    ? parse(innerText, quoteDepth: quoteDepth + 1)
                    : [MarkdownBlock(kind: .paragraph(text: innerText))]
                blocks.append(.init(kind: .quote(blocks: innerBlocks)))
                continue
            }

            // List: collect the run of consecutive list-item lines. Each
            // item absorbs its lazy / indented continuation lines (a wrapped
            // item like "- long line\n  rest") so the list isn't torn into
            // separate paragraphs and split lists.
            if listMarker(line) != nil {
                var items: [ListItem] = []
                var ordered = false
                while i < lines.count, let marker = listMarker(lines[i]) {
                    ordered = ordered || marker.ordinal != nil
                    var text = marker.text
                    i += 1
                    // Pull in following non-blank lines that don't start a new
                    // block — they're soft-wrapped continuation of this item.
                    while i < lines.count {
                        let l = lines[i]
                        if l.trimmingCharacters(in: .whitespaces).isEmpty { break }
                        if listMarker(l) != nil || FenceMarker(line: l) != nil
                            || isThematicBreak(l) || parseHeading(l) != nil || isQuote(l)
                            || isPageBreak(l) || isCommentStart(l) {
                            break
                        }
                        if i + 1 < lines.count, parseTable(header: l, delimiter: lines[i + 1]) != nil {
                            break
                        }
                        text += " " + l.trimmingCharacters(in: .whitespaces)
                        i += 1
                    }
                    items.append(ListItem(text: text,
                                          level: marker.level,
                                          ordinal: marker.ordinal,
                                          task: marker.task))
                }
                blocks.append(.init(kind: .list(ordered: ordered, items: items)))
                continue
            }

            // Otherwise: a paragraph — gather following lines until a blank
            // line or the start of another block, preserving line breaks.
            var paragraph: [String] = []
            var emittedHeading = false
            while i < lines.count {
                let l = lines[i]
                if l.trimmingCharacters(in: .whitespaces).isEmpty { break }
                // Setext heading: a single buffered line underlined by `===`
                // (h1) or `---` (h2). Checked before the thematic-break /
                // list branches so `Title\n---` is a heading, not a rule.
                if paragraph.count == 1, let level = setextUnderline(l) {
                    blocks.append(.init(kind: .heading(
                        level: level,
                        text: paragraph[0].trimmingCharacters(in: .whitespaces))))
                    i += 1
                    emittedHeading = true
                    break
                }
                if FenceMarker(line: l) != nil || isThematicBreak(l) || parseHeading(l) != nil
                    || isQuote(l) || listMarker(l) != nil
                    || isPageBreak(l) || isCommentStart(l) {
                    break
                }
                paragraph.append(l)
                i += 1
            }
            if !emittedHeading, !paragraph.isEmpty {
                blocks.append(.init(kind: .paragraph(text: paragraph.joined(separator: "\n"))))
            }
        }

        return blocks
    }

    // MARK: - Headings

    /// Parse a front-matter block if `lines` opens with one, advancing `i`
    /// past it. Returns nil — leaving `i` alone — for every other document,
    /// including one that merely starts with a thematic break.
    ///
    /// The opening fence must be the very first line: `---` for YAML (closed
    /// by `---` or `...`) or `+++` for TOML (closed by `+++`).
    ///
    /// Three things must all hold, because the opening fence of YAML front
    /// matter is spelled exactly like a thematic break and getting this wrong
    /// *hides the reader's prose*: the fence must be closed; the line straight
    /// after it must not be blank (no generator writes front matter that way,
    /// but a document opening with a rule and a blank line is commonplace);
    /// and the block must hold at least one recognisable field. A document
    /// that opens with a horizontal rule, says something, and rules off again
    /// therefore keeps every word of it — as does `---` followed by a setext
    /// heading's text, which stays a break and a heading the way it reads
    /// everywhere else.
    ///
    /// Values are read with a deliberately flat `key: value` (or `key = value`)
    /// scan rather than a YAML/TOML parser: the app has no room for one, and
    /// nothing here needs nesting. Anything the scan doesn't recognise — a
    /// list, a nested mapping, a comment — is skipped, and the block is still
    /// consumed, which is the part that matters for how the document looks.
    /// Quotes around a value are stripped, since every generator writes some.
    private static func parseFrontMatter(_ lines: [String], from i: inout Int) -> [MetadataField]? {
        guard let opener = lines.first?.trimmingCharacters(in: .whitespaces) else { return nil }
        let closers: Set<String>
        // A `Unicode.Scalar`, not a `Character`: `key:\u{0301} value` is a
        // colon fused with a mark, which no `Character` search for ":" can
        // find — the field, and with it the author's metadata, was dropped
        // on Apple and kept on Android.
        let separator: Unicode.Scalar
        // `==` against an ASCII-only literal (here and in `closers` below)
        // is canonical equivalence, not grapheme matching: no string
        // carrying a mark is ever canonically equal to `---`, so this means
        // what Kotlin's UTF-16 `==` means. See `ScalarText`.
        switch opener {
        case "---": closers = ["---", "..."]; separator = ":"
        case "+++": closers = ["+++"];        separator = "="
        default: return nil
        }

        // Nothing is committed to until all three guards pass. A blank line
        // straight after the opener means this is a rule with prose under it.
        guard lines.count > 1,
              !lines[1].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        var end: Int?
        for index in 1..<lines.count where closers.contains(lines[index].trimmingCharacters(in: .whitespaces)) {
            end = index
            break
        }
        guard let close = end else { return nil }

        var fields: [MetadataField] = []
        for line in lines[1..<close] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip comments, list items, and anything with no separator —
            // including a nested mapping's indented children, whose parent
            // key was already recorded with an empty value.
            if trimmed.isEmpty || ScalarText.hasPrefix(trimmed, "#")
                || ScalarText.hasPrefix(trimmed, "-") { continue }
            let scalars = trimmed.unicodeScalars
            guard let split = scalars.firstIndex(of: separator) else { continue }
            let key = ScalarText.string(scalars[..<split]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = ScalarText.string(scalars[scalars.index(after: split)...])
                .trimmingCharacters(in: .whitespaces)
            // Scalars on both sides of the count as well: a value of two
            // graphemes can be three scalars, and dropping the first
            // *grapheme* would take the mark off the character behind the
            // opening quote with it.
            for quote in ["\"", "'"] where value.unicodeScalars.count >= 2
                && ScalarText.hasPrefix(value, quote) && ScalarText.hasSuffix(value, quote) {
                value = ScalarText.string(value.unicodeScalars.dropFirst().dropLast())
                break
            }
            fields.append(MetadataField(key: key, value: value))
        }
        // No field at all means this was never metadata — most likely a
        // thematic break with prose beneath it, or a setext heading. Leave
        // `i` where it was and let the ordinary block parser have the lines.
        guard !fields.isEmpty else { return nil }
        i = close + 1
        return fields
    }

    /// A footnote definition line — `[^id]: the note` — or nil.
    ///
    /// Identifiers are **ASCII** letters, digits, `-` and `_`. That is
    /// narrower than Pandoc allows, and deliberately so twice over: the
    /// identifier travels through the HTML renderer's escaping pass and into
    /// an `id` attribute, and a character set with nothing to escape cannot
    /// come out the other side spelled differently from the definition it has
    /// to match — and it is the same set the renderer's reference pattern
    /// accepts, so a definition can never be written that no reference is able
    /// to name. (Allowing any Unicode letter here would do exactly that: the
    /// note would be parsed, found unreferenced, and printed on its own at the
    /// foot of the page, which is a puzzling thing to hand an author.)
    static func parseFootnoteDefinition(_ line: String) -> (id: String, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard ScalarText.hasPrefix(trimmed, "[^") else { return nil }
        let afterMarker = trimmed.unicodeScalars.dropFirst(2)
        guard let close = afterMarker.firstIndex(of: "]") else { return nil }
        let id = ScalarText.string(afterMarker[..<close])
        let afterClose = afterMarker[close...].dropFirst()
        guard !id.isEmpty, id.unicodeScalars.allSatisfy(isFootnoteIdentifier),
              afterClose.first == ":" else { return nil }
        let text = ScalarText.string(afterClose.dropFirst())
            .trimmingCharacters(in: .whitespaces)
        return (id, text)
    }

    /// Whether `scalar` may stand in a footnote identifier: an ASCII
    /// letter, an ASCII digit, `-` or `_` — spelled out rather than asked
    /// of `Character`, which would answer for a whole grapheme cluster.
    private static func isFootnoteIdentifier(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "-", "_": return true
        default: return false
        }
    }

    /// The front matter of `source`, or an empty list if it has none — the
    /// document's own metadata, for anything that needs to know the author or
    /// the title rather than just render the text.
    static func frontMatter(of source: String) -> [MetadataField] {
        for block in parse(source) {
            if case let .frontMatter(fields) = block.kind { return fields }
        }
        return []
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        // Scalars throughout: `# \u{0301}Heading` is a heading whose marker
        // space carries a mark, and to a `Character` walk that space is not
        // a space — the heading was a paragraph on Apple and a heading on
        // Android, and the outline lost the entry with it.
        var rest = line.unicodeScalars.drop { $0 == " " }
        guard rest.first == "#" else { return nil }
        var level = 0
        while rest.first == "#", level < 7 {
            level += 1
            rest = rest.dropFirst()
        }
        guard (1...6).contains(level) else { return nil }
        // A valid ATX heading needs a space (or end of line) after the #s.
        guard rest.isEmpty || rest.first == " " else { return nil }
        let text = ScalarText.string(rest).trimmingCharacters(in: .whitespaces)
        return (level, stripClosingHashes(text))
    }

    /// Remove a *closing* ATX `#` run (`## Title ##` → `Title`) but only
    /// when it is preceded by whitespace, per CommonMark — so a trailing
    /// `#` that is part of the title (`C#`, `F#`) is preserved.
    private static func stripClosingHashes(_ text: String) -> String {
        let scalars = text.unicodeScalars
        var end = scalars.endIndex
        while end > scalars.startIndex, scalars[scalars.index(before: end)] == "#" {
            end = scalars.index(before: end)
        }
        guard end < scalars.endIndex else { return text }   // no trailing # run
        if end == scalars.startIndex { return "" }          // all #s → empty heading
        let before = scalars[scalars.index(before: end)]
        guard before == " " || before == "\t" else { return text } // e.g. "C#"
        return ScalarText.string(scalars[..<end]).trimmingCharacters(in: .whitespaces)
    }

    /// A setext underline: a non-empty line of only `=` (level 1) or only
    /// `-` (level 2), ignoring surrounding whitespace.
    private static func setextUnderline(_ line: String) -> Int? {
        let t = line.trimmingCharacters(in: .whitespaces).unicodeScalars
        guard !t.isEmpty else { return nil }
        if t.allSatisfy({ $0 == "=" }) { return 1 }
        if t.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    // MARK: - Page breaks & comments

    /// A page break: a line whose only content is `\newpage` or
    /// `\pagebreak` (the Pandoc / LaTeX conventions).
    ///
    /// `==` against an ASCII-only literal is canonical equivalence and
    /// needs no scalar form: `\newpage` with a mark on its `e` is not
    /// canonically equal to `\newpage`, and is not a page break on either
    /// platform. See `ScalarText`.
    private static func isPageBreak(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t == "\\newpage" || t == "\\pagebreak"
    }

    /// A line that opens an HTML comment block.
    private static func isCommentStart(_ line: String) -> Bool {
        ScalarText.hasPrefix(line.unicodeScalars.drop { $0 == " " }, "<!--")
    }

    /// `<!-- note: … -->` → the note's text; any other comment → nil.
    private static func noteText(_ comment: String) -> String? {
        let scalars = Array(comment.unicodeScalars)
        guard let open = ScalarText.firstIndex(of: "<!--", in: scalars) else { return nil }
        let close = ScalarText.firstIndex(of: "-->", in: scalars) ?? scalars.count
        guard open + 4 <= close else { return nil }
        let body = ScalarText.string(scalars[(open + 4)..<close])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The prefix is tested on the lowercased copy but dropped from the
        // original, as on Android: five scalars, since `note:` is five
        // scalars and no lowercase mapping produces any of them from
        // fewer.
        guard ScalarText.hasPrefix(body.lowercased(), "note:") else { return nil }
        return ScalarText.dropFirst(body, 5)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Outline, notes & anchors

    /// The document's table of contents: every ATX / setext heading outside
    /// a code fence, with the source line and the same anchor slug the HTML
    /// renderer assigns. Line-oriented like `parse`, so it stays cheap
    /// enough to recompute whenever the TOC is shown.
    static func outline(_ source: String) -> [OutlineEntry] {
        let lines = normalizedLines(source)
        var entries: [OutlineEntry] = []
        var used: [String: Int] = [:]
        var fence: FenceMarker?
        var previousPlain: (text: String, line: Int)?
        // How many plain lines ran up to `previousPlain`. `parse` only treats
        // an underline as setext when the buffered paragraph has exactly ONE
        // line; the outline must apply the same rule, or it would list
        // headings the rendered document doesn't have (and their phantom
        // slugs would shift every later anchor).
        var plainRun = 0
        var i = 0
        // Skip the front matter, exactly as `parse` does. Its closing `---`
        // would otherwise underline the last metadata line into a phantom
        // setext heading — one the rendered document does not contain, whose
        // slug would then push every real heading's anchor out of step with
        // the ids `MarkdownHTML` assigns, so the TOC would scroll to nothing.
        _ = parseFrontMatter(lines, from: &i)
        while i < lines.count {
            let line = lines[i]
            if let open = fence {
                if open.closes(line) { fence = nil }
                previousPlain = nil
                plainRun = 0
                i += 1
                continue
            }
            if let open = FenceMarker(line: line) {
                fence = open
                previousPlain = nil
                plainRun = 0
                i += 1
                continue
            }
            if isCommentStart(line) {
                while i < lines.count, !ScalarText.contains(lines[i], "-->") { i += 1 }
                previousPlain = nil
                plainRun = 0
                i += 1
                continue
            }
            if let heading = parseHeading(line) {
                entries.append(OutlineEntry(level: heading.level, text: heading.text,
                                            slug: slug(for: heading.text, used: &used), line: i))
                previousPlain = nil
                plainRun = 0
                i += 1
                continue
            }
            // Setext heading: exactly one plain buffered line underlined by
            // === / --- (a longer run is a paragraph; `parse` then reads the
            // underline as a rule / plain text, and so must we).
            if let previous = previousPlain, plainRun == 1, let level = setextUnderline(line) {
                entries.append(OutlineEntry(level: level, text: previous.text,
                                            slug: slug(for: previous.text, used: &used),
                                            line: previous.line))
                previousPlain = nil
                plainRun = 0
                i += 1
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A footnote definition is not plain text either: `parse` claims
            // the line, so an underline beneath it is a rule and not a setext
            // heading. Counting it as plain would list a heading the rendered
            // document has not got, and its slug would drag every later
            // anchor out of step — the same failure front matter had.
            let isPlain = !trimmed.isEmpty && !isThematicBreak(line) && !isQuote(line)
                && listMarker(line) == nil && !isPageBreak(line)
                && parseFootnoteDefinition(line) == nil
            plainRun = isPlain ? plainRun + 1 : 0
            previousPlain = isPlain ? (trimmed, i) : nil
            i += 1
        }
        return entries
    }

    /// Every private author note in the document, with its source line.
    static func notes(_ source: String) -> [NoteEntry] {
        let lines = normalizedLines(source)
        var entries: [NoteEntry] = []
        var fence: FenceMarker?
        var i = 0
        // Skip the front matter, as `parse` and `outline` do — a comment
        // inside the metadata block is not part of the document, so listing
        // it would send the notes panel to a line the preview never renders.
        _ = parseFrontMatter(lines, from: &i)
        while i < lines.count {
            let line = lines[i]
            if let open = fence {
                if open.closes(line) { fence = nil }
                i += 1
                continue
            }
            if let open = FenceMarker(line: line) {
                fence = open
                i += 1
                continue
            }
            if isCommentStart(line) {
                let start = i
                var raw: [String] = []
                while i < lines.count {
                    raw.append(lines[i])
                    let closed = ScalarText.contains(lines[i], "-->")
                    i += 1
                    if closed { break }
                }
                if let note = noteText(raw.joined(separator: "\n")) {
                    entries.append(NoteEntry(text: note, line: start))
                }
                continue
            }
            i += 1
        }
        return entries
    }

    /// GitHub-style anchor slug for a heading, unique within one document
    /// via the caller-maintained `used` counts ("title", "title-1", …).
    /// Keeps letters, digits, `_` and `-`; spaces become hyphens; all other
    /// punctuation (including inline-markup characters) is dropped — the
    /// same rule GitHub applies, so links written for GitHub keep working.
    ///
    /// Walks *scalars* and keeps combining marks, which is what a
    /// `Character` walk did by accident and Android's code-point walk does
    /// on purpose: an NFD "café" keeps its accent because the mark rode
    /// along inside the letter's grapheme. Where the two parted company was
    /// a mark on a character the slug does not keep letter-wise — `-`, `_`
    /// or a space. `"a -\u{0301}b"` dropped the hyphen *and* the mark on
    /// Apple (the cluster equals neither "-" nor " ") and kept both on
    /// Android, so the same heading had two different anchors and a TOC
    /// link written on one platform scrolled to nothing on the other.
    static func slug(for text: String, used: inout [String: Int]) -> String {
        var base = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            if isSlugKept(scalar) {
                base.append(scalar)
            } else if scalar == " " {
                base.append("-")
            }
        }
        var slug = String(base)
        if slug.isEmpty { slug = "section" }
        let seen = used[slug, default: 0]
        used[slug] = seen + 1
        return seen == 0 ? slug : "\(slug)-\(seen)"
    }

    /// Whether a scalar survives into an anchor slug: the categories
    /// `Character.isLetter` and `Character.isNumber` answer for a cluster's
    /// first scalar (Unicode `Alphabetic` and any numeric type), plus the
    /// combining marks that used to ride along inside the cluster, plus the
    /// two punctuation marks GitHub keeps.
    private static func isSlugKept(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" || scalar == "-" { return true }
        let properties = scalar.properties
        if properties.isAlphabetic || properties.numericType != nil { return true }
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// Source split into terminator-free lines, with line endings normalised
    /// the same way `parse` does — so `outline` / `notes` line numbers match.
    ///
    /// One scalar pass rather than two `replacingOccurrences` and a
    /// `components(separatedBy:)`: those match grapheme clusters, and a
    /// line terminator is the one place where that is nearly right by
    /// accident (a `\r\n` is a single cluster, and every cluster breaks
    /// after a control character, so a mark on the character *after* a
    /// newline cannot fuse with it). "Nearly right by accident" is not what
    /// the file this feeds should rest on, and the single pass is cheaper
    /// on a parse that re-runs at every keystroke.
    private static func normalizedLines(_ source: String) -> [String] {
        let scalars = Array(source.unicodeScalars)
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\r" {
                // A lone CR ends a line; CR LF ends one line, not two.
                if index + 1 < scalars.count, scalars[index + 1] == "\n" { index += 1 }
                lines.append(String(current))
                current = String.UnicodeScalarView()
            } else if scalar == "\n" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
            index += 1
        }
        lines.append(String(current))
        return lines
    }

    // MARK: - Thematic break

    private static func isThematicBreak(_ line: String) -> Bool {
        let stripped = line.unicodeScalars.filter { $0 != " " && $0 != "\t" }
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" }
            || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }

    // MARK: - Block quote

    private static func isQuote(_ line: String) -> Bool {
        line.unicodeScalars.drop { $0 == " " }.first == ">"
    }

    private static func stripQuoteMarker(_ line: String) -> String {
        var s = line.unicodeScalars.drop { $0 == " " }
        if s.first == ">" { s = s.dropFirst() }
        if s.first == " " { s = s.dropFirst() }
        return ScalarText.string(s)
    }

    // MARK: - Lists

    private struct Marker {
        let level: Int
        let ordinal: Int?
        let text: String
        let task: Bool?
    }

    /// Recognise an unordered (`-`, `*`, `+`) or ordered (`1.`, `1)`) list
    /// item, returning its indentation level, ordinal, text and task state.
    private static func listMarker(_ line: String) -> Marker? {
        // Leading whitespace determines nesting depth (2 columns ≈ one
        // level), counting a tab as advancing to the next 4-column stop so
        // tab-indented items from externally-authored files are recognised.
        //
        // Scalars, not `Character`s, and this is the demonstrated one:
        // `- \u{0301}[draft]` — a mark on the space after the bullet — was
        // a paragraph on Apple and a list on Android, because the cluster
        // "space plus mark" is not a space. Every comparison below is
        // against a single ASCII scalar for the same reason.
        let scalars = line.unicodeScalars
        var indent = 0
        var start = scalars.startIndex
        while start < scalars.endIndex {
            let c = scalars[start]
            if c == " " { indent += 1 }
            else if c == "\t" { indent += 4 - (indent % 4) }
            else { break }
            start = scalars.index(after: start)
        }
        let body = scalars[start...]
        guard let first = body.first else { return nil }

        var ordinal: Int? = nil
        var rest: Substring.UnicodeScalarView

        if first == "-" || first == "*" || first == "+" {
            rest = body.dropFirst()
        } else if isASCIIDigit(first) {
            // Up to 9 leading digits then a `.` or `)` delimiter. ASCII
            // digits only, as CommonMark says and as Android's `isDigit`
            // does: `Character.isNumber` also admits ½ and Ⅻ, which `Int`
            // cannot read back, so such a line became an ordered list
            // numbered 1 on Apple and a paragraph on Android. With this set
            // the ordinal always parses and the two ports agree.
            let digits = body.prefix(while: isASCIIDigit)
            guard digits.count <= 9 else { return nil }
            let afterDigits = body.dropFirst(digits.count)
            guard let delim = afterDigits.first, delim == "." || delim == ")" else { return nil }
            ordinal = Int(ScalarText.string(digits)) ?? 1
            rest = afterDigits.dropFirst()
        } else {
            return nil
        }

        // The marker must be followed by at least one space (or be empty).
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = ScalarText.string(rest.drop { $0 == " " })

        // GitHub task-list checkbox: `[ ]` / `[x]` immediately after marker.
        // The two `==` are whole-string equality against an ASCII-only
        // literal, which is canonical equivalence rather than grapheme
        // matching and means what Kotlin's `==` means; only the prefixes
        // need the scalar form.
        var task: Bool? = nil
        if ScalarText.hasPrefix(text, "[ ] ") || text == "[ ]" {
            task = false
            text = uncheckedText(text)
        } else if ScalarText.hasPrefix(text.lowercased(), "[x] ") || text.lowercased() == "[x]" {
            task = true
            text = uncheckedText(text)
        }

        return Marker(level: indent / 2, ordinal: ordinal, text: text, task: task)
    }

    /// An ASCII digit — the whole of CommonMark's ordered-list marker.
    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }

    /// A task item's text with the three-scalar `[ ]` / `[x]` box and the
    /// spaces after it taken off. Three *scalars*: dropping three graphemes
    /// would take a mark the author put on the character after the box.
    private static func uncheckedText(_ text: String) -> String {
        ScalarText.string(text.unicodeScalars.dropFirst(3).drop { $0 == " " })
    }

    // MARK: - Tables (GFM)

    private struct TableHead {
        let header: [String]
        let alignments: [ColumnAlignment]
    }

    /// Parse a GFM table head: a `header` row plus a `delimiter` row such
    /// as `| :--- | :---: | ---: |`. Returns nil if the pair isn't a table.
    private static func parseTable(header: String, delimiter: String) -> TableHead? {
        guard ScalarText.contains(header, "|") else { return nil }
        let delimTrim = delimiter.trimmingCharacters(in: .whitespaces)
        guard ScalarText.contains(delimTrim, "-") else { return nil }
        // Every delimiter cell must look like `:?-+:?`.
        let delimCells = splitTableRow(delimiter, columns: nil)
        guard !delimCells.isEmpty else { return nil }
        var alignments: [ColumnAlignment] = []
        for cell in delimCells {
            let c = cell.trimmingCharacters(in: .whitespaces).unicodeScalars
            guard !c.isEmpty, c.allSatisfy({ $0 == "-" || $0 == ":" }),
                  c.contains("-") else { return nil }
            let left = c.first == ":"
            let right = c.last == ":"
            alignments.append(left && right ? .center : right ? .trailing : .leading)
        }
        let headerCells = splitTableRow(header, columns: nil)
        guard headerCells.count == alignments.count else { return nil }
        return TableHead(header: headerCells, alignments: alignments)
    }

    /// Split one table row into cell strings. A leading and trailing pipe
    /// are optional; escaped pipes (`\|`) stay inside a cell. When
    /// `columns` is given, the result is padded/truncated to that width.
    private static func splitTableRow(_ row: String, columns: Int?) -> [String] {
        var trimmed = row.trimmingCharacters(in: .whitespaces).unicodeScalars[...]
        if trimmed.first == "|" { trimmed = trimmed.dropFirst() }
        if trimmed.last == "|" { trimmed = trimmed.dropLast() }

        var cells: [String] = []
        var current = String.UnicodeScalarView()
        var escaped = false
        for ch in trimmed {
            if escaped {
                // Keep the pipe literal; drop the escaping backslash.
                if ch != "|" { current.append("\\") }
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(String(current).trimmingCharacters(in: .whitespaces))
                current = String.UnicodeScalarView()
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        cells.append(String(current).trimmingCharacters(in: .whitespaces))

        if let columns {
            while cells.count < columns { cells.append("") }
            if cells.count > columns { cells = Array(cells.prefix(columns)) }
        }
        return cells
    }
}

// MARK: - Fence helper

/// Parses and matches a fenced-code delimiter (``` or ~~~). Captures the
/// fence character, run length and indentation so the closing fence and
/// body de-indentation follow CommonMark's "at least as long, same char"
/// rule rather than a naive string compare.
private struct FenceMarker {
    let char: Unicode.Scalar
    let count: Int
    let indent: Int
    let language: String?

    /// Scalars throughout, like the parser: ```` ```\u{0301}js ```` is a
    /// fence whose third backtick carries a mark, and a `Character` walk
    /// counts a run of two there — so the block was a code block on Android
    /// and a paragraph on Apple, and the author's code was reflowed as
    /// prose and inline-formatted.
    init?(line: String) {
        let scalars = line.unicodeScalars
        let indent = scalars.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }            // 4+ spaces = code, not a fence
        let body = scalars.dropFirst(indent)
        guard let first = body.first, first == "`" || first == "~" else { return nil }
        let run = body.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        let info = ScalarText.string(body.dropFirst(run.count))
            .trimmingCharacters(in: .whitespaces)
        // An info string on a backtick fence may not contain a backtick.
        if first == "`", ScalarText.contains(info, "`") { return nil }
        self.char = first
        self.count = run.count
        self.indent = indent
        // The info string is already trimmed, so its first space-separated
        // word is everything up to the first space — the same word Kotlin's
        // `split(" ").first()` takes.
        let lang = ScalarText.string(info.unicodeScalars.prefix { $0 != " " })
        self.language = lang.isEmpty ? nil : lang
    }

    /// A closing fence: same char, at least as long, no trailing content.
    func closes(_ line: String) -> Bool {
        let trimmedIndent = line.unicodeScalars.drop { $0 == " " }
        let run = trimmedIndent.prefix { $0 == char }
        guard run.count >= count else { return false }
        return ScalarText.string(trimmedIndent.dropFirst(run.count))
            .trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Remove up to the opening fence's indentation from a body line.
    func stripIndent(_ line: String) -> String {
        var removed = 0
        var s = line.unicodeScalars[...]
        while removed < indent, s.first == " " {
            s = s.dropFirst()
            removed += 1
        }
        return ScalarText.string(s)
    }
}
