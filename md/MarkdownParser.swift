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
    }
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
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var i = 0

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

            // HTML comment block: `<!-- … -->`, possibly spanning lines.
            // A `<!-- note: … -->` comment is the author's private note —
            // kept as a block so the notes panel can list it. Any other
            // comment is simply dropped. Neither appears in the preview,
            // the PDF, or print.
            if isCommentStart(line) {
                var raw: [String] = []
                while i < lines.count {
                    raw.append(lines[i])
                    let closed = lines[i].contains("-->")
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
                while i < lines.count, lines[i].contains("|"),
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

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.drop { $0 == " " }
        guard trimmed.first == "#" else { return nil }
        var level = 0
        var rest = Substring(trimmed)
        while rest.first == "#", level < 7 {
            level += 1
            rest = rest.dropFirst()
        }
        guard (1...6).contains(level) else { return nil }
        // A valid ATX heading needs a space (or end of line) after the #s.
        guard rest.isEmpty || rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return (level, stripClosingHashes(text))
    }

    /// Remove a *closing* ATX `#` run (`## Title ##` → `Title`) but only
    /// when it is preceded by whitespace, per CommonMark — so a trailing
    /// `#` that is part of the title (`C#`, `F#`) is preserved.
    private static func stripClosingHashes(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)] == "#" {
            end = text.index(before: end)
        }
        guard end < text.endIndex else { return text }   // no trailing # run
        if end == text.startIndex { return "" }          // all #s → empty heading
        let before = text[text.index(before: end)]
        guard before == " " || before == "\t" else { return text } // e.g. "C#"
        return String(text[..<end]).trimmingCharacters(in: .whitespaces)
    }

    /// A setext underline: a non-empty line of only `=` (level 1) or only
    /// `-` (level 2), ignoring surrounding whitespace.
    private static func setextUnderline(_ line: String) -> Int? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.allSatisfy({ $0 == "=" }) { return 1 }
        if t.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    // MARK: - Page breaks & comments

    /// A page break: a line whose only content is `\newpage` or
    /// `\pagebreak` (the Pandoc / LaTeX conventions).
    private static func isPageBreak(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t == "\\newpage" || t == "\\pagebreak"
    }

    /// A line that opens an HTML comment block.
    private static func isCommentStart(_ line: String) -> Bool {
        line.drop { $0 == " " }.hasPrefix("<!--")
    }

    /// `<!-- note: … -->` → the note's text; any other comment → nil.
    private static func noteText(_ comment: String) -> String? {
        guard let open = comment.range(of: "<!--") else { return nil }
        let close = comment.range(of: "-->")?.lowerBound ?? comment.endIndex
        guard open.upperBound <= close else { return nil }
        let body = comment[open.upperBound..<close]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.lowercased().hasPrefix("note:") else { return nil }
        return String(body.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
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
                while i < lines.count, !lines[i].contains("-->") { i += 1 }
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
            let isPlain = !trimmed.isEmpty && !isThematicBreak(line) && !isQuote(line)
                && listMarker(line) == nil && !isPageBreak(line)
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
                    let closed = lines[i].contains("-->")
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
    static func slug(for text: String, used: inout [String: Int]) -> String {
        var base = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                base.append(ch)
            } else if ch == " " {
                base.append("-")
            }
        }
        if base.isEmpty { base = "section" }
        let seen = used[base, default: 0]
        used[base] = seen + 1
        return seen == 0 ? base : "\(base)-\(seen)"
    }

    /// Source split into terminator-free lines, with line endings normalised
    /// the same way `parse` does — so `outline` / `notes` line numbers match.
    private static func normalizedLines(_ source: String) -> [String] {
        source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    // MARK: - Thematic break

    private static func isThematicBreak(_ line: String) -> Bool {
        let stripped = line.filter { $0 != " " && $0 != "\t" }
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" }
            || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }

    // MARK: - Block quote

    private static func isQuote(_ line: String) -> Bool {
        line.drop { $0 == " " }.first == ">"
    }

    private static func stripQuoteMarker(_ line: String) -> String {
        var s = Substring(line.drop { $0 == " " })
        if s.first == ">" { s = s.dropFirst() }
        if s.first == " " { s = s.dropFirst() }
        return String(s)
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
        var indent = 0
        var start = line.startIndex
        while start < line.endIndex {
            let c = line[start]
            if c == " " { indent += 1 }
            else if c == "\t" { indent += 4 - (indent % 4) }
            else { break }
            start = line.index(after: start)
        }
        let body = line[start...]
        guard let first = body.first else { return nil }

        var ordinal: Int? = nil
        var rest: Substring

        if first == "-" || first == "*" || first == "+" {
            rest = body.dropFirst()
        } else if first.isNumber {
            // Up to 9 leading digits then a `.` or `)` delimiter.
            let digits = body.prefix { $0.isNumber }
            guard digits.count <= 9 else { return nil }
            let afterDigits = body.dropFirst(digits.count)
            guard let delim = afterDigits.first, delim == "." || delim == ")" else { return nil }
            ordinal = Int(digits) ?? 1
            rest = afterDigits.dropFirst()
        } else {
            return nil
        }

        // The marker must be followed by at least one space (or be empty).
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = String(rest.drop { $0 == " " })

        // GitHub task-list checkbox: `[ ]` / `[x]` immediately after marker.
        var task: Bool? = nil
        if text.hasPrefix("[ ] ") || text == "[ ]" {
            task = false
            text = String(text.dropFirst(3).drop { $0 == " " })
        } else if text.lowercased().hasPrefix("[x] ") || text.lowercased() == "[x]" {
            task = true
            text = String(text.dropFirst(3).drop { $0 == " " })
        }

        return Marker(level: indent / 2, ordinal: ordinal, text: text, task: task)
    }

    // MARK: - Tables (GFM)

    private struct TableHead {
        let header: [String]
        let alignments: [ColumnAlignment]
    }

    /// Parse a GFM table head: a `header` row plus a `delimiter` row such
    /// as `| :--- | :---: | ---: |`. Returns nil if the pair isn't a table.
    private static func parseTable(header: String, delimiter: String) -> TableHead? {
        guard header.contains("|") else { return nil }
        let delimTrim = delimiter.trimmingCharacters(in: .whitespaces)
        guard delimTrim.contains("-") else { return nil }
        // Every delimiter cell must look like `:?-+:?`.
        let delimCells = splitTableRow(delimiter, columns: nil)
        guard !delimCells.isEmpty else { return nil }
        var alignments: [ColumnAlignment] = []
        for cell in delimCells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty, c.allSatisfy({ $0 == "-" || $0 == ":" }),
                  c.contains("-") else { return nil }
            let left = c.hasPrefix(":")
            let right = c.hasSuffix(":")
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
        var trimmed = row.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }

        var cells: [String] = []
        var current = ""
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
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))

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
    let char: Character
    let count: Int
    let indent: Int
    let language: String?

    init?(line: String) {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }            // 4+ spaces = code, not a fence
        let body = line.dropFirst(indent)
        guard let first = body.first, first == "`" || first == "~" else { return nil }
        let run = body.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        let info = body.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        // An info string on a backtick fence may not contain a backtick.
        if first == "`", info.contains("`") { return nil }
        self.char = first
        self.count = run.count
        self.indent = indent
        let lang = info.split(separator: " ").first.map(String.init)
        self.language = (lang?.isEmpty ?? true) ? nil : lang
    }

    /// A closing fence: same char, at least as long, no trailing content.
    func closes(_ line: String) -> Bool {
        let trimmedIndent = line.drop { $0 == " " }
        let run = trimmedIndent.prefix { $0 == char }
        guard run.count >= count else { return false }
        return trimmedIndent.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Remove up to the opening fence's indentation from a body line.
    func stripIndent(_ line: String) -> String {
        var removed = 0
        var s = Substring(line)
        while removed < indent, s.first == " " {
            s = s.dropFirst()
            removed += 1
        }
        return String(s)
    }
}
