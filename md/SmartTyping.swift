//
//  SmartTyping.swift
//  md
//
//  Created by nettrash on 22/09/2026.
//
//  The editor's two typing rules, as two pure functions:
//
//      enter(text, selectionStart, selectionEnd)             -> EnterEdit?
//      capitalize(text, selectionStart, selectionEnd, typed) -> String?
//
//  `enter` continues a list item, a task, a quote or a table row when Return
//  is pressed, ends an empty item, and outdents an empty nested one.
//  `capitalize` upper-cases the first letter of a line and of a sentence,
//  Markdown-aware: never in a fence, a comment, front matter, a table cell,
//  a code span, math, a URL, or after an abbreviation, an initial or an
//  ellipsis. Neither function touches the view; the editor adapters
//  (`MarkdownEditor.swift`) apply the returned edit as one undoable step.
//
//  WHERE THE RULES COME FROM
//  -------------------------
//  This is a port, rule for rule and comment for comment, of the reference
//  `smartTyping.ts` that implements the family's shared SmartTyping
//  specification (SPEC.md v1, FINAL). The section numbers in the comments
//  below (§0.3, §1.1, §2.5 …) are that document's, so a reader can put the
//  two side by side. The reference generated `typing-vectors.json`, and
//  `SmartTypingTests.swift` asserts every one of its 1350 vectors (512 for
//  `enter`, 838 for `capitalize`) against this file — the same JSON the
//  Kotlin (`md.Android`) and C# (`md.win`) ports assert, so the four
//  editors answer every keystroke the same way.
//
//  THE THREE RULES OF THE PORT
//  ---------------------------
//  * **UTF-16 units, never `Character`s.** Every offset in, out and inside is
//    a UTF-16 code unit, exactly what `NSTextView` / `UITextView` report and
//    what the vectors record. The text is walked as `[UInt16]` through a
//    `Span` view; surrogate pairs are decoded by hand where the reference
//    reads a code point. A `Character` index would count graphemes and put
//    every caret after a combining mark or a ZWJ one unit out.
//  * **No Foundation string searching, no regular expressions, no
//    `.whitespaces`.** "Whitespace" has four answers across the family's
//    runtimes (`ScalarText.swift` tells that story); here it has one, the
//    19-unit set `WS19` (§0.3), and every predicate is a unit / scalar walk.
//    Character classes are `Unicode.Scalar.Properties.generalCategory`,
//    the uppercase mapping is `properties.uppercaseMapping` guarded to one
//    scalar (§0.7) — never `uppercased()`, which is the full, multi-scalar,
//    locale-blind mapping.
//  * **The vectors win.** Where a comment here and SPEC.md read differently,
//    the JSON is normative and the disagreement is reported, not "fixed".
//    §5 of the specification lists the divergences from md's own rendering
//    that are deliberate (fences inside quotes, a table under a paragraph,
//    a bare `-` line); do not repair them on one platform.
//
//  This file is byte-identical in `md` and `md.macOS`, like `ScalarText`,
//  `MarkdownParser`, `MarkdownHTML`, `MarkdownInline`, `Plot` and `ViewMode`;
//  `SmartTypingTests.swift` and `TypingVectors/typing-vectors.json` are the
//  same three artefacts in both repositories. Edit all copies together.
//

enum SmartTyping {

    /// The one edit `enter` asks the platform for: replace
    /// `[location, location + length)` of the **original** text with
    /// `replacement` and put a collapsed caret at `caret` (an offset into the
    /// text after the edit), as one undoable step (§0.9).
    struct EnterEdit: Equatable {
        let location: Int
        let length: Int
        let replacement: String
        let caret: Int
    }

    /// §1. Return `nil` for a plain newline, or the edit to apply instead.
    static func enter(_ text: String, selectionStart: Int, selectionEnd: Int) -> EnterEdit? {
        smartEnter(Array(text.utf16), selectionStart, selectionEnd)
    }

    /// §2. `typed` holds exactly one Unicode scalar. Return `nil` to insert
    /// it unchanged, or the string to insert in place of the selection.
    static func capitalize(_ text: String, selectionStart: Int, selectionEnd: Int, typed: String) -> String? {
        smartCapitalize(Array(text.utf16), selectionStart, selectionEnd, Array(typed.utf16))
    }
}

// ---------------------------------------------------------------------------
// §0.1 units and scalars
// ---------------------------------------------------------------------------

private let SP = 0x20
private let TAB = 0x09
private let CR = 0x0d
private let LF = 0x0a

private func isHigh(_ u: Int) -> Bool { u >= 0xd800 && u <= 0xdbff }
private func isLow(_ u: Int) -> Bool { u >= 0xdc00 && u <= 0xdfff }

/// A view of `base[lo..<hi]`, indexed from 0 the way the reference indexes
/// its strings. `at` answers -1 outside the view — the port's stand-in for
/// `charCodeAt`'s NaN: every comparison against it is false, every class
/// predicate rejects it, and no walk needs a bounds check of its own.
/// Slicing never copies; `units` does, and only where an edit is assembled.
private struct Span {
    let base: [UInt16]
    let lo: Int
    let hi: Int

    init(_ base: [UInt16], _ lo: Int, _ hi: Int) {
        self.base = base
        self.lo = lo
        self.hi = hi
    }

    init(_ base: [UInt16]) {
        self.init(base, 0, base.count)
    }

    var count: Int { hi - lo }

    @inline(__always)
    func at(_ i: Int) -> Int {
        i >= 0 && i < hi - lo ? Int(base[lo + i]) : -1
    }

    /// The reference's `slice`: bounds clamp, a negative bound counts from
    /// the end.
    func slice(_ a: Int, _ b: Int? = nil) -> Span {
        let n = hi - lo
        func clamp(_ x: Int) -> Int { x < 0 ? max(n + x, 0) : min(x, n) }
        let s = clamp(a)
        let e = b.map(clamp) ?? n
        return Span(base, lo + s, lo + max(e, s))
    }

    func indexOf(_ u: Int, from: Int = 0) -> Int {
        var i = max(from, 0)
        while i < count {
            if at(i) == u { return i }
            i += 1
        }
        return -1
    }

    func contains(_ u: Int) -> Bool { indexOf(u) >= 0 }

    func startsWith(_ p: [Int], at start: Int = 0) -> Bool {
        if start < 0 || start + p.count > count { return false }
        for k in 0..<p.count where at(start + k) != p[k] { return false }
        return true
    }

    func indexOf(_ p: [Int], from: Int = 0) -> Int {
        var i = max(from, 0)
        while i + p.count <= count {
            if startsWith(p, at: i) { return i }
            i += 1
        }
        return -1
    }

    func lastIndexOf(_ p: [Int]) -> Int {
        var i = count - p.count
        while i >= 0 {
            if startsWith(p, at: i) { return i }
            i -= 1
        }
        return -1
    }

    /// Ordinal equality with an ASCII literal, unit for unit.
    func equals(_ ascii: String) -> Bool {
        let p = ascii.utf16
        if p.count != count { return false }
        var k = 0
        for u in p {
            if at(k) != Int(u) { return false }
            k += 1
        }
        return true
    }

    var units: [UInt16] { Array(base[lo..<hi]) }
}

private func units(_ ascii: String) -> [Int] { ascii.utf16.map { Int($0) } }
private func u16(_ s: String) -> [UInt16] { Array(s.utf16) }
private func string(_ u: [UInt16]) -> String { String(decoding: u, as: UTF16.self) }

private struct Scalar {
    let cp: Int
    let len: Int
}

/// The scalar starting at unit index i (a lone surrogate is its own scalar).
private func scalarAt(_ s: Span, _ i: Int) -> Scalar {
    let u = s.at(i)
    if isHigh(u) && i + 1 < s.count && isLow(s.at(i + 1)) {
        return Scalar(cp: 0x10000 + ((u - 0xd800) << 10) + (s.at(i + 1) - 0xdc00), len: 2)
    }
    return Scalar(cp: u, len: 1)
}

/// The scalar ending just before unit index i, or nil at the start.
private func scalarBefore(_ s: Span, _ i: Int) -> Scalar? {
    if i <= 0 { return nil }
    let u = s.at(i - 1)
    if isLow(u) && i - 2 >= 0 && isHigh(s.at(i - 2)) { return scalarAt(s, i - 2) }
    return Scalar(cp: u, len: 1)
}

private func scalarsOf(_ s: Span) -> [Int] {
    var out: [Int] = []
    var i = 0
    while i < s.count {
        let sc = scalarAt(s, i)
        out.append(sc.cp)
        i += sc.len
    }
    return out
}

// ---------------------------------------------------------------------------
// §0.3 WS19, blank, trim
// ---------------------------------------------------------------------------

private func isWS19(_ u: Int) -> Bool {
    u == 0x09 || u == 0x20 || u == 0xa0 || u == 0x1680
        || (u >= 0x2000 && u <= 0x200a) || u == 0x200b || u == 0x202f || u == 0x205f || u == 0x3000
}

private func isBlank(_ s: Span) -> Bool {
    var i = 0
    while i < s.count {
        if !isWS19(s.at(i)) { return false }
        i += 1
    }
    return true
}

private func trim(_ s: Span) -> Span {
    var a = 0
    var b = s.count
    while a < b && isWS19(s.at(a)) { a += 1 }
    while b > a && isWS19(s.at(b - 1)) { b -= 1 }
    return s.slice(a, b)
}

// ---------------------------------------------------------------------------
// §0.4 character classes (general category of the scalar)
// ---------------------------------------------------------------------------

/// Unicode general category of one scalar. A lone surrogate — and the -1 a
/// `Span` answers outside its bounds — is `Cs`, which no class below admits.
private func category(_ cp: Int) -> Unicode.GeneralCategory {
    guard cp >= 0, cp <= 0x10ffff, let scalar = Unicode.Scalar(UInt32(cp)) else { return .surrogate }
    return scalar.properties.generalCategory
}

private func isLetter(_ cp: Int) -> Bool {
    switch category(cp) {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
    default: return false
    }
}
private func isLowercase(_ cp: Int) -> Bool { category(cp) == .lowercaseLetter }
private func isUppercase(_ cp: Int) -> Bool { category(cp) == .uppercaseLetter }
private func isMark(_ cp: Int) -> Bool {
    switch category(cp) {
    case .nonspacingMark, .spacingMark, .enclosingMark: return true
    default: return false
    }
}
private func isSymbolSoSk(_ cp: Int) -> Bool {
    switch category(cp) {
    case .otherSymbol, .modifierSymbol: return true
    default: return false
    }
}
private func isDigit(_ u: Int) -> Bool { u >= 0x30 && u <= 0x39 }

// ---------------------------------------------------------------------------
// §0.7 case mapping — simple, one-to-one, locale-independent
// ---------------------------------------------------------------------------

/// `upper(s)` or nil when undefined (§0.7). Swift's `uppercaseMapping` is the
/// FULL mapping, exactly like the reference's `toUpperCase`; the one-scalar
/// guard yields the simple mapping.
private func upper(_ cp: Int) -> Int? {
    if (cp >= 0x10d0 && cp <= 0x10ff) || (cp >= 0x2d00 && cp <= 0x2d2f) { return nil } // Georgian
    // Greek letters with ypogegrammeni: the simple mapping (Java, .NET) is one
    // titlecase scalar, the full mapping (Swift, JS) is two — undefined, so
    // all ports agree (§0.7).
    if (cp >= 0x1f80 && cp <= 0x1faf) || cp == 0x1fb3 || cp == 0x1fc3 || cp == 0x1ff3 { return nil }
    if cp == 0xb5 { return nil } // MICRO SIGN: never GREEK CAPITAL MU in a unit prefix (§0.7)
    if cp >= 0xd800 && cp <= 0xdfff { return nil }
    guard cp >= 0, cp <= 0x10ffff, let scalar = Unicode.Scalar(UInt32(cp)) else { return nil }
    let mapped = scalar.properties.uppercaseMapping.unicodeScalars
    guard mapped.count == 1, let first = mapped.first else { return nil }
    if first == scalar { return nil }
    return Int(first.value)
}

// ---------------------------------------------------------------------------
// §0.2 lines
// ---------------------------------------------------------------------------

private struct Line {
    let start: Int
    let end: Int // excludes the terminator
}

private func splitLines(_ t: [UInt16]) -> [Line] {
    var lines: [Line] = []
    var start = 0
    var i = 0
    let n = t.count
    while i < n {
        let u = Int(t[i])
        if u == CR {
            lines.append(Line(start: start, end: i))
            i += (i + 1 < n && Int(t[i + 1]) == LF) ? 2 : 1
            start = i
        } else if u == LF {
            lines.append(Line(start: start, end: i))
            i += 1
            start = i
        } else {
            i += 1
        }
    }
    lines.append(Line(start: start, end: n))
    return lines
}

/// Index of the line containing `caret`, or -1 when the caret sits strictly
/// between the CR and the LF of one terminator (§0.2).
private func lineOf(_ lines: [Line], _ caret: Int) -> Int {
    var i = 0
    while i < lines.count {
        if lines[i].start <= caret && caret <= lines[i].end { return i }
        i += 1
    }
    return -1
}

/// The document `text′` (§0.9): its units, its line table, and the §0.11
/// prefix of each line, parsed once. Lines are `Span`s over the one array —
/// no line is ever copied out.
private final class Doc {
    let t: [UInt16]
    let lines: [Line]
    private var prefixes: [Prefix?]

    init(_ t: [UInt16]) {
        self.t = t
        self.lines = splitLines(t)
        self.prefixes = [Prefix?](repeating: nil, count: lines.count)
    }

    var count: Int { lines.count }

    func line(_ k: Int) -> Span { Span(t, lines[k].start, lines[k].end) }

    func prefix(_ k: Int) -> Prefix {
        if let p = prefixes[k] { return p }
        let p = parsePrefix(line(k))
        prefixes[k] = p
        return p
    }

    /// The inner text of line k: the line minus `indent0` and `quotes` (§0.13).
    func inner(_ k: Int) -> Span { line(k).slice(prefix(k).innerStart) }
}

// ---------------------------------------------------------------------------
// §0.6 columns
// ---------------------------------------------------------------------------

private func columns(_ run: Span) -> Int {
    var col = 0
    var i = 0
    while i < run.count {
        if run.at(i) == TAB { col += 4 - (col % 4) } else { col += 1 }
        i += 1
    }
    return col
}

// ---------------------------------------------------------------------------
// §0.12 block tests on one line
// ---------------------------------------------------------------------------

private func isThematicBreak(_ s: Span) -> Bool {
    var n = 0
    var ch = -1
    var i = 0
    while i < s.count {
        let u = s.at(i)
        i += 1
        if u == SP || u == TAB { continue }
        if u != 0x2d && u != 0x2a && u != 0x5f { return false } // - * _
        if ch == -1 { ch = u } else if u != ch { return false }
        n += 1
    }
    return n >= 3
}

private func isATXHeading(_ s: Span) -> Bool {
    var i = 0
    while i < s.count && s.at(i) == SP { i += 1 }
    var n = 0
    while i < s.count && s.at(i) == 0x23 { n += 1; i += 1 }
    if n < 1 || n > 6 { return false }
    return i == s.count || s.at(i) == SP
}

private let NEWPAGE = "\\newpage"
private let PAGEBREAK = "\\pagebreak"

private func isPageBreak(_ s: Span) -> Bool {
    let t = trim(s)
    return t.equals(NEWPAGE) || t.equals(PAGEBREAK)
}

private func isFootnoteIdUnit(_ u: Int) -> Bool {
    (u >= 0x41 && u <= 0x5a) || (u >= 0x61 && u <= 0x7a) || isDigit(u) || u == 0x2d || u == 0x5f
}

/// Length of the footnote prefix `[^id]:` + WS19* measured on `t` (already
/// positioned at the `[`), or -1.
private func footnotePrefixLength(_ t: Span, _ from: Int) -> Int {
    if !(t.at(from) == 0x5b && t.at(from + 1) == 0x5e) { return -1 }
    var i = from + 2
    let idStart = i
    while i < t.count && isFootnoteIdUnit(t.at(i)) { i += 1 }
    if i == idStart { return -1 }
    if !(t.at(i) == 0x5d && t.at(i + 1) == 0x3a) { return -1 }
    i += 2
    while i < t.count && isWS19(t.at(i)) { i += 1 }
    return i - from
}

private func isFootnoteDefinition(_ s: Span) -> Bool {
    footnotePrefixLength(trim(s), 0) >= 0
}

private func isQuoteLine(_ s: Span) -> Bool {
    var i = 0
    while i < s.count && s.at(i) == SP { i += 1 }
    return s.at(i) == 0x3e
}

private let COMMENT_OPEN = units("<!--")
private let COMMENT_CLOSE = units("-->")

private func isCommentStart(_ s: Span) -> Bool {
    var i = 0
    while i < s.count && s.at(i) == SP { i += 1 }
    return s.startsWith(COMMENT_OPEN, at: i)
}

// ---------------------------------------------------------------------------
// §0.11 prefix grammar
// ---------------------------------------------------------------------------

private struct Marker {
    let bullet: Int?     // the bullet unit, or nil for an ordered marker
    let number: Int
    let delimiter: Int   // "." or ")" for an ordered marker
}

/// The §0.11 prefix of one line, as offsets into that line:
/// `indent0 = [0, indent0End)`, `quotes = [indent0End, quotesEnd)`,
/// `indent1 = [quotesEnd, indent1End)`, content from `prefixEnd`.
private struct Prefix {
    let indent0End: Int
    let quotesEnd: Int          // after indent0 + quotes: the "inner text" starts here (§0.13)
    let indent1End: Int
    let quoteGroupStarts: [Int] // offsets (within `quotes`) where each group starts (§1.3c)
    let depth: Int
    let marker: Marker?
    let box: Bool               // "[ ]" | "[x]" | "[X]" followed by SP
    let boxAtEnd: Bool          // the content is exactly a box (`- [ ]`): content for the caret, a box for §1.3a / §1.4
    let prefixEnd: Int          // where content starts
    let listIndentCols: Int     // §0.11 list indent in columns
    let listLevel: Int          // §0.11 list level = floor(columns / 2), the parser's `indent / 2`
    let indent0HasTab: Bool
    let indent1HasTab: Bool

    var innerStart: Int { quotesEnd }
    /// `box !== null || boxAtEnd` in the reference: the line HAS a box.
    var hasBox: Bool { box || boxAtEnd }
}

/// Parse the §0.11 prefix of one line. A marker or box counts only when
/// followed by SP: one at the line end is content for both functions (the
/// parser renders a bare `-` as an empty item, but Enter must not delete a
/// `2020.` line and a typed letter would land directly after the unit —
/// `-` + `a` is `-a`; §6 records the difference).
private func parsePrefix(_ s: Span) -> Prefix {
    var i = 0
    // indent0 := run of SP / TAB
    var indent0HasTab = false
    while i < s.count && (s.at(i) == SP || s.at(i) == TAB) {
        if s.at(i) == TAB { indent0HasTab = true }
        i += 1
    }
    let indent0End = i
    // quotes := ( run of SP, ">", at most one SP )*  — only when indent0 has no
    // TAB (the parser's `isQuote` drops SP only: `\t> x` is a paragraph).
    let quotesStart = i
    var groupStarts: [Int] = []
    var depth = 0
    if !indent0HasTab {
        while true {
            var j = i
            while j < s.count && s.at(j) == SP { j += 1 }
            if j < s.count && s.at(j) == 0x3e {
                groupStarts.append(i - quotesStart)
                j += 1
                if j < s.count && s.at(j) == SP { j += 1 }
                i = j
                depth += 1
            } else {
                break
            }
        }
    }
    let quotesEnd = i
    // indent1 := run of SP / TAB, only after quotes
    var indent1HasTab = false
    if depth > 0 {
        while i < s.count && (s.at(i) == SP || s.at(i) == TAB) {
            if s.at(i) == TAB { indent1HasTab = true }
            i += 1
        }
    }
    let indent1End = i
    // inner text = line minus indent0 and quotes (§0.13)
    let listIndentCols = columns(depth > 0 ? s.slice(quotesEnd, indent1End) : s.slice(0, indent0End))
    let afterIndent = i

    var marker: Marker? = nil
    var box = false
    var boxAtEnd = false
    var prefixEnd = afterIndent

    // marker is absent when the inner text is a thematic break (tested first, as the parser does)
    if !isThematicBreak(s.slice(quotesEnd)) {
        var m = afterIndent
        var bullet: Int? = nil
        var num = 0
        var delim = 0
        var ok = false
        let u = s.at(m)
        if u == 0x2d || u == 0x2a || u == 0x2b {
            bullet = u
            m += 1
            ok = true
        } else if isDigit(u) {
            var d = m
            while d < s.count && isDigit(s.at(d)) { d += 1 }
            let digits = d - m
            if digits <= 9 && (s.at(d) == 0x2e || s.at(d) == 0x29) {
                num = 0
                var k = m
                while k < d { num = num * 10 + (s.at(k) - 0x30); k += 1 }
                delim = s.at(d)
                m = d + 1
                ok = true
            }
        }
        if ok {
            // followed by SP (a marker at the line end is content, §0.11)
            let followedBySP = m < s.count && s.at(m) == SP
            if followedBySP {
                marker = Marker(bullet: bullet, number: num, delimiter: delim)
                // the marker absorbs the run of SP after it (the parser drops every SP)
                while m < s.count && s.at(m) == SP { m += 1 }
                prefixEnd = m
                // box := "[ ]" | "[x]" | "[X]", followed by SP (same refinement)
                let b1 = s.at(m + 1)
                if s.at(m) == 0x5b && (b1 == SP || b1 == 0x78 || b1 == 0x58) && s.at(m + 2) == 0x5d {
                    var e = m + 3
                    let bSP = e < s.count && s.at(e) == SP
                    if bSP {
                        box = true
                        while e < s.count && s.at(e) == SP { e += 1 }
                        prefixEnd = e
                    } else if e == s.count {
                        // §0.11: a box that is the whole content (`- [ ]`, `1. [x]`) is
                        // content for the caret test (§1.2) and for §1.3 (the item is not
                        // empty), but the line HAS a box for §1.3a and §1.4: the parser
                        // renders an empty task, and Enter continues the checklist
                        // (`enter-empty-task-no-space`).
                        boxAtEnd = true
                    }
                }
            }
        }
    }
    return Prefix(indent0End: indent0End, quotesEnd: quotesEnd, indent1End: indent1End,
                  quoteGroupStarts: groupStarts, depth: depth, marker: marker, box: box,
                  boxAtEnd: boxAtEnd, prefixEnd: prefixEnd, listIndentCols: listIndentCols,
                  listLevel: listIndentCols / 2, indent0HasTab: indent0HasTab,
                  indent1HasTab: indent1HasTab)
}

// ---------------------------------------------------------------------------
// §0.13 table grammar
// ---------------------------------------------------------------------------

private func splitCells(_ row: Span) -> [[UInt16]] {
    var r = trim(row)
    if r.count > 0 && r.at(0) == 0x7c { r = r.slice(1) }
    if r.count > 0 && r.at(r.count - 1) == 0x7c { r = r.slice(0, -1) }
    var cells: [[UInt16]] = []
    var cur: [UInt16] = []
    var escaped = false
    var i = 0
    while i < r.count {
        let ch = r.at(i)
        i += 1
        if escaped {
            if ch != 0x7c { cur.append(0x5c) }
            cur.append(UInt16(ch))
            escaped = false
        } else if ch == 0x5c {
            escaped = true
        } else if ch == 0x7c {
            cells.append(trim(Span(cur)).units)
            cur = []
        } else {
            cur.append(UInt16(ch))
        }
    }
    if escaped { cur.append(0x5c) }
    cells.append(trim(Span(cur)).units)
    return cells
}

private func innerMarkerExists(_ inner: Span) -> Bool {
    // the inner text has no quotes by construction; its prefix's marker
    parsePrefix(inner).marker != nil
}

private func isTablePair(_ header: Span, _ delimiter: Span) -> Bool {
    if !header.contains(0x7c) { return false }
    if innerMarkerExists(header) { return false }
    if isATXHeading(header) || isFootnoteDefinition(header) || isCommentStart(header) { return false }
    if !trim(delimiter).contains(0x2d) { return false }
    do {
        // §0.13: a delimiter line with a `marker` is excluded only when its
        // content contains no `|`: `- ` and `- x` are list items to a writer,
        // while `- | -` and `- |` are delimiter rows (the pipe says table, and
        // the parser tests tables before lists) — §5 table-delimiter-list-marker
        let dp = parsePrefix(delimiter)
        if dp.marker != nil && delimiter.indexOf(0x7c, from: dp.prefixEnd) < 0 { return false }
    }
    let dCells = splitCells(delimiter)
    for c in dCells {
        if c.isEmpty { return false }
        var dash = false
        for u in c {
            if u == 0x2d { dash = true } else if u != 0x3a { return false }
        }
        if !dash { return false }
    }
    return splitCells(header).count == dCells.count
}

// ---------------------------------------------------------------------------
// §0.10 state scan
// ---------------------------------------------------------------------------

private struct Scan {
    var code: [Bool]      // per line ≤ c: front matter / fence line / comment line
    var special: [Bool]   // per line ≤ c: blank, code (as above) or ATX heading
    var caretCode: Bool   // the caret's line is code (incl. tentative front matter)
}

private func leadingSPCount(_ s: Span) -> Int {
    var i = 0
    while i < s.count && s.at(i) == SP { i += 1 }
    return i
}

private struct Fence {
    let ch: Int
    let n: Int
}

/// Fence opener test (§0.10): ≤ 3 leading SP, run of ` or ~ of length ≥ 3,
/// no backtick in the rest of a backtick fence.
private func fenceOpener(_ s: Span) -> Fence? {
    let i = leadingSPCount(s)
    if i > 3 { return nil }
    let ch = s.at(i)
    if ch != 0x60 && ch != 0x7e { return nil }
    var j = i
    while j < s.count && s.at(j) == ch { j += 1 }
    let n = j - i
    if n < 3 { return nil }
    if ch == 0x60 && s.indexOf(0x60, from: j) >= 0 { return nil }
    return Fence(ch: ch, n: n)
}

private func fenceCloses(_ s: Span, _ ch: Int, _ n: Int) -> Bool {
    let i = leadingSPCount(s)
    var j = i
    while j < s.count && s.at(j) == ch { j += 1 }
    if j - i < n { return false }
    return isBlank(s.slice(j))
}

private enum FenceState {
    case normal
    case fence(Int, Int)
    case comment
}

private func scanState(_ doc: Doc, _ c: Int, forEnter: Bool) -> Scan {
    var code = [Bool](repeating: false, count: c + 1)
    var special = [Bool](repeating: false, count: c + 1)
    var caretCode = false

    // --- front matter (all the parser's guards)
    var fmEnd = -1
    let opener = trim(doc.line(0))
    var separator = -1
    var closers: [String] = []
    if opener.equals("---") {
        closers = ["---", "..."]
        separator = 0x3a
    } else if opener.equals("+++") {
        closers = ["+++"]
        separator = 0x3d
    }
    func isCloser(_ t: Span) -> Bool {
        for cl in closers where t.equals(cl) { return true }
        return false
    }
    if separator != -1 {
        var holds = doc.count > 1 && !isBlank(doc.line(1))
        var close = -1
        if holds {
            var k = 1
            while k < doc.count {
                if isCloser(trim(doc.line(k))) { close = k; break }
                k += 1
            }
            if close < 0 { holds = false }
        }
        if holds {
            var field = false
            var k = 1
            while k < close {
                let t = trim(doc.line(k))
                k += 1
                if t.count == 0 || t.at(0) == 0x23 || t.at(0) == 0x2d { continue }
                let sep = t.indexOf(separator)
                if sep < 0 { continue }
                if isBlank(t.slice(0, sep)) { continue }
                field = true
                break
            }
            if !field { holds = false }
        }
        if holds {
            fmEnd = close
        } else if c >= 1 {
            // tentative front matter (§0.10): a block that is already closed above
            // the caret is complete and rejected — prose. Otherwise the caret's
            // line is code iff every line of the tested range is non-blank and
            // field-like. The range is 1 ..< c for capitalize (the caret's line
            // is being typed) and 1 … c for enter (the line is complete).
            var closed = false
            var k = 1
            while k < c {
                if isCloser(trim(doc.line(k))) { closed = true; break }
                k += 1
            }
            if !closed {
                let last = forEnter ? c : c - 1
                var tentative = true
                var fieldSeen = false
                var k = 1
                while k <= last {
                    let t = trim(doc.line(k))
                    k += 1
                    if t.count == 0 { tentative = false; break }
                    let sep = t.indexOf(separator)
                    let hash = t.at(0) == 0x23
                    let dash = t.at(0) == 0x2d
                    // a field mirrors parseFrontMatter's guard: a `#` or `-` line is never
                    // a field (`---⏎- key: v⏎---` renders as rule + list + rule)
                    let isField = !hash && !dash && sep > 0 && !isBlank(t.slice(0, sep))
                    // a `#` comment (YAML and TOML) or a `-` list item (YAML only: TOML has
                    // no `-` lists) counts only under a field line: a list or heading
                    // directly under a bare `---` is Markdown
                    let fieldLike = isField || ((hash || (dash && separator == 0x3a)) && fieldSeen)
                    if !fieldLike { tentative = false; break }
                    if isField { fieldSeen = true }
                }
                if tentative { caretCode = true }
            }
        }
    }
    if fmEnd >= 0 {
        var k = 0
        while k <= min(fmEnd, c) {
            code[k] = true
            special[k] = true
            k += 1
        }
    }
    if fmEnd >= c { caretCode = true }

    // --- fences and comments, at quote depth 0 only
    var st = FenceState.normal
    var k = fmEnd + 1
    while k <= c {
        let s = doc.line(k)
        switch st {
        case .normal:
            if let f = fenceOpener(s) {
                st = .fence(f.ch, f.n)
                code[k] = true
            } else if isCommentStart(s) {
                code[k] = true
                st = s.indexOf(COMMENT_CLOSE) >= 0 ? .normal : .comment
            }
        case let .fence(ch, n):
            code[k] = true
            if fenceCloses(s, ch, n) { st = .normal }
        case .comment:
            code[k] = true
            if s.indexOf(COMMENT_CLOSE) >= 0 { st = .normal }
        }
        if code[k] || isBlank(s) || isATXHeading(s) { special[k] = true }
        k += 1
    }
    if code[c] { caretCode = true }
    return Scan(code: code, special: special, caretCode: caretCode)
}

// ---------------------------------------------------------------------------
// §0.13 tableContext
// ---------------------------------------------------------------------------

private struct TableCtx {
    let header: Int
    let n: Int
}

private func tableContext(_ doc: Doc, _ scan: Scan, _ k: Int) -> TableCtx? {
    let d = doc.prefix(k).depth
    var top = k
    while top - 1 >= 0 && !isBlank(doc.line(top - 1)) && doc.prefix(top - 1).depth == d && !scan.code[top - 1] {
        top -= 1
    }
    var h = top
    while h <= k {
        if h + 1 >= doc.count || doc.prefix(h + 1).depth != d || !isTablePair(doc.inner(h), doc.inner(h + 1)) {
            h += 1
            continue
        }
        // the pair at h opens a table; it runs while the lines below contain a
        // pipe. A line without one ends it (the parser's row loop stops there)
        // and is not a header itself, so the search resumes below that line —
        // greedy consumption, never a second pair inside the first table's rows.
        var ended = -1
        var j = h + 2
        while j <= k {
            if !doc.line(j).contains(0x7c) { ended = j; break }
            j += 1
        }
        if ended < 0 { return TableCtx(header: h, n: splitCells(doc.inner(h)).count) }
        h = ended + 1
    }
    return nil
}

private func isPipeLine(_ s: Span, _ p: Prefix) -> Bool {
    // §0.13: the inner text (line minus indent0 and quotes), after indent1, starts with `|`
    s.at(p.indent1End) == 0x7c
}

// ---------------------------------------------------------------------------
// §0.9 inputs, outputs and offsets
// ---------------------------------------------------------------------------

private struct Norm {
    let start: Int
    let end: Int
    let t: [UInt16]
    let caret: Int
}

private func normalize(_ text: [UInt16], _ selectionStart: Int, _ selectionEnd: Int) -> Norm? {
    let start = min(selectionStart, selectionEnd)
    let end = max(selectionStart, selectionEnd)
    if !(0 <= start && start <= end && end <= text.count) { return nil }
    func betweenCRLF(_ o: Int) -> Bool {
        o > 0 && o < text.count && Int(text[o - 1]) == CR && Int(text[o]) == LF
    }
    if betweenCRLF(start) || betweenCRLF(end) { return nil }
    // §0.9: an offset strictly between the high and the low half of a surrogate
    // pair would split one scalar in two (a corrupt document, and one Swift's
    // NSString bridge repairs differently from Kotlin and C#)
    func betweenSurrogates(_ o: Int) -> Bool {
        o > 0 && o < text.count && isHigh(Int(text[o - 1])) && isLow(Int(text[o]))
    }
    if betweenSurrogates(start) || betweenSurrogates(end) { return nil }
    var t = Array(text[0..<start])
    t.append(contentsOf: text[end...])
    return Norm(start: start, end: end, t: t, caret: start)
}

// ---------------------------------------------------------------------------
// §1 enter
// ---------------------------------------------------------------------------

/// §1.4 next(n)
private func nextNumber(_ n: Int) -> Int {
    n + 1 > 999_999_999 ? n : n + 1
}

private func markerPrime(_ m: Marker, _ number: Int) -> [UInt16] {
    if let bullet = m.bullet { return [UInt16(bullet), UInt16(SP)] }
    return u16(String(number)) + [UInt16(m.delimiter), UInt16(SP)]
}

private let BOX_PRIME = u16("[ ] ")

private func smartEnter(_ text: [UInt16], _ selectionStart: Int, _ selectionEnd: Int) -> SmartTyping.EnterEdit? {
    guard let norm = normalize(text, selectionStart, selectionEnd) else { return nil }
    let start = norm.start
    let end = norm.end
    let caret = norm.caret
    let doc = Doc(norm.t)
    let c = lineOf(doc.lines, caret)
    if c < 0 { return nil }                                   // §0.2
    let scan = scanState(doc, c, forEnter: true)
    if scan.caretCode { return nil }                          // §1.0

    let removed = end - start
    let line = doc.line(c)
    let lineStart = doc.lines[c].start

    // §1.1 table row: the selection must lie within one line of `text`
    var withinLine = true
    var i = start
    while i < end {
        let u = Int(text[i])
        if u == CR || u == LF { withinLine = false; break }
        i += 1
    }
    if withinLine, let tc = tableContext(doc, scan, c) {
        let p = doc.prefix(c)
        let rowPrefix = line.slice(0, p.indent1End).units
        var cells: [UInt16] = []
        for _ in 0..<tc.n { cells += [0x20, 0x20, 0x7c] }
        let row: [UInt16] = [UInt16(LF)] + rowPrefix + [0x7c] + cells
        let inner = line.slice(p.innerStart)
        // insert the row after the line end `xPrime` of text′ (at or after caret′);
        // with a selection the same edit is one range from `start` that also
        // deletes the selection (§0.9)
        func insertAfter(_ xPrime: Int) -> SmartTyping.EnterEdit {
            let x = xPrime + removed
            if removed == 0 {
                return SmartTyping.EnterEdit(location: x, length: 0, replacement: string(row),
                                             caret: x + 1 + rowPrefix.count + 2)
            }
            let tail = Array(text[end..<x])
            return SmartTyping.EnterEdit(location: start, length: x - start, replacement: string(tail + row),
                                         caret: start + tail.count + 1 + rowPrefix.count + 2)
        }
        if c == tc.header {
            if caret == lineStart { return nil } // column 0 of the header: a plain newline pushes the table down
            return insertAfter(doc.lines[tc.header + 1].end)
        }
        // §1.1: the table continues below the caret's row iff line c+1 exists,
        // has the same quote depth and contains a `|` unit (the parser's row
        // loop). A blank row ends the table only when it is the LAST row: a
        // blank line in the middle would orphan the rows below it
        // (`enter-table-blank-row-mid-table`).
        let continuesBelow = c + 1 < doc.count && doc.prefix(c + 1).depth == p.depth && doc.line(c + 1).contains(0x7c)
        if removed == 0 && !continuesBelow && splitCells(inner).allSatisfy({ $0.isEmpty }) {
            // end the table; inside a quote the writer stays in the quote (as §1.3b)
            let r = p.depth > 0 ? line.slice(0, p.quotesEnd).units : []
            return SmartTyping.EnterEdit(location: lineStart, length: doc.lines[c].end - lineStart,
                                         replacement: string(r), caret: lineStart + r.count)
        }
        if removed == 0 && c >= tc.header + 2 && caret == lineStart {
            // column 0 of a body row: the new row goes ABOVE the caret's row, which
            // moves down intact exactly as a plain newline would push it — the
            // writer's only "insert a row above" gesture (A.1). The delimiter row
            // keeps the insert-after branch: a row between header and delimiter
            // would break the table.
            let above: [UInt16] = rowPrefix + [0x7c] + cells + [UInt16(LF)]
            return SmartTyping.EnterEdit(location: lineStart, length: 0, replacement: string(above),
                                         caret: lineStart + rowPrefix.count + 2)
        }
        return insertAfter(doc.lines[c].end)
    }

    let p = doc.prefix(c)
    let rel = caret - lineStart
    if rel < p.prefixEnd { return nil }                       // §1.2
    let content = line.slice(p.prefixEnd)

    // replaces text′[lineStart, caret′) with r
    func replaceHead(_ r: [UInt16]) -> SmartTyping.EnterEdit {
        SmartTyping.EnterEdit(location: lineStart, length: (caret - lineStart) + removed,
                              replacement: string(r), caret: lineStart + r.count)
    }

    // §1.3 empty item
    if isBlank(content) && (p.marker != nil || p.depth > 0) {
        if p.marker != nil {
            // a. outdent
            if let anc = ancestor(doc, scan, c, p) {
                let A = doc.prefix(anc)
                let aLine = doc.line(anc)
                let m = A.marker!
                let r = aLine.slice(0, A.indent1End).units + markerPrime(m, nextNumber(m.number)) + (A.hasBox ? BOX_PRIME : [])
                return replaceHead(r)
            }
            // b. terminate a list item
            return replaceHead(p.depth > 0 ? line.slice(0, p.quotesEnd).units : [])
        }
        // c. terminate a quote level
        let last = p.quoteGroupStarts[p.quoteGroupStarts.count - 1]
        // quotes′ = quotes[0, last): empty when the last group is the first
        return replaceHead(last == 0 ? [] : line.slice(0, p.indent0End + last).units)
    }

    // §1.4 continue
    if p.marker != nil || p.depth > 0 {
        let mp: [UInt16] = p.marker.map { markerPrime($0, nextNumber($0.number)) } ?? []
        let r: [UInt16] = [UInt16(LF)] + line.slice(0, p.indent1End).units + mp + (p.hasBox ? BOX_PRIME : [])
        return SmartTyping.EnterEdit(location: start, length: removed, replacement: string(r), caret: start + r.count)
    }

    return nil                                                // §1.5
}

/// §1.3a ancestor walk.
private func ancestor(_ doc: Doc, _ scan: Scan, _ c: Int, _ p: Prefix) -> Int? {
    var k = c - 1
    while k >= 0 {
        let s = doc.line(k)
        if isBlank(s) { return nil }
        let pk = doc.prefix(k)
        if pk.depth != p.depth { return nil }
        if scan.code[k] { return nil }
        if tableContext(doc, scan, k) != nil { return nil }
        let inner = s.slice(pk.innerStart)
        if isBlank(inner) { return nil } // `> ` between quoted items: the renderer sees a blank line
        if isThematicBreak(inner) || isATXHeading(inner) || isPageBreak(inner) { return nil }
        // §1.3a: the ancestor's list LEVEL (floor(columns / 2), the parser's
        // `indent / 2`) is strictly smaller — a 1-SP or 3-SP item renders as a
        // sibling, so Enter on it must not manufacture another sibling
        if pk.marker != nil && pk.listLevel < p.listLevel { return k }
        k -= 1
    }
    return nil
}

// ---------------------------------------------------------------------------
// §2 capitalize
// ---------------------------------------------------------------------------

/// §2.2 openers: * _ ~ " ' ( [ { « » ‹ › “ ” ‘ ’ „ ‚ ¿ ¡
private let OPENERS: Set<Int> = [0x2a, 0x5f, 0x7e, 0x22, 0x27, 0x28, 0x5b, 0x7b, 0xab, 0xbb, 0x2039, 0x203a,
                                 0x201c, 0x201d, 0x2018, 0x2019, 0x201e, 0x201a, 0xbf, 0xa1]
/// §2.2 closers: ) ] } " ' » « ‹ › ” ’ “ ‘ * _ ~
private let CLOSERS: Set<Int> = [0x29, 0x5d, 0x7d, 0x22, 0x27, 0xbb, 0xab, 0x2039, 0x203a,
                                 0x201d, 0x2019, 0x201c, 0x2018, 0x2a, 0x5f, 0x7e]
/// §2.2: the quotation marks among the openers (the colon rule, §2.5 1a):
/// " ' « » ‹ › “ ” ‘ ’ „ ‚
private let QUOTE_OPENERS: Set<Int> = [0x22, 0x27, 0xab, 0xbb, 0x2039, 0x203a, 0x201c, 0x201d, 0x2018, 0x2019,
                                       0x201e, 0x201a]
/// §2.2: guillemets « ‹ » ›, which carry French spacing after them when opening.
private let GUILLEMETS: Set<Int> = [0xab, 0x2039, 0xbb, 0x203a]
private func isTerminator(_ u: Int) -> Bool { u == 0x2e || u == 0x21 || u == 0x3f }
/// §2.3 dash units: em dash, en dash, minus, horizontal bar (Unicode's
/// "quotation dash"), figure dash, the pasted bullets • ‣ · and the section /
/// pilcrow signs § ¶ (Po since Unicode 6.1, leads to a writer).
private func isDashUnit(_ u: Int) -> Bool {
    u == 0x2014 || u == 0x2013 || u == 0x2212 || u == 0x2015 || u == 0x2012
        || u == 0x2022 || u == 0x2023 || u == 0xb7 || u == 0xa7 || u == 0xb6
}
/// §2.3: arrows (U+2190–U+21FF) are leads at the content start only (`→ next
/// step`, the arrow-bullet note style); they are not in the mid-line group.
private func isArrowUnit(_ u: Int) -> Bool { u >= 0x2190 && u <= 0x21ff }
/// §2.3 `dash` lead run: a run of dash units, arrows or U+002D that is not a
/// single hyphen-minus (`- ` is a list marker; `-- Привет` is a dialogue line
/// typed on a keyboard without an em dash).
private func isLeadDashUnit(_ u: Int) -> Bool { isDashUnit(u) || isArrowUnit(u) || u == 0x2d }
/// §2.5 step 1b: the mid-line dash group is a run of units each of which is a
/// dash unit or the hyphen-minus (`- `, `--`, `—-`), mixed freely; arrows are
/// not in it (`a → b. c` is untouched).
private func isMidLineDashUnit(_ u: Int) -> Bool { isDashUnit(u) || u == 0x2d }
private func isSectionUnit(_ u: Int) -> Bool { u == 0xa7 || u == 0xb6 }
private func isRomanUnit(_ u: Int) -> Bool {
    u == 0x69 || u == 0x76 || u == 0x78 || u == 0x49 || u == 0x56 || u == 0x58
}

/// §2.3 `number` body: Digit{1,9} ( "." Digit{1,9} )* ( "." | ")" )? — the
/// end index after it, or -1.
private func numberBodyEnd(_ s: Span, _ i: Int) -> Int {
    func digits(_ from: Int) -> Int {
        var j = from
        while j < s.count && isDigit(s.at(j)) && j - from < 9 { j += 1 }
        return j
    }
    var j = digits(i)
    if j == i { return -1 }
    while true {
        if s.at(j) == 0x2e && j + 1 < s.count && isDigit(s.at(j + 1)) {
            j = digits(j + 1)
            continue
        }
        break
    }
    if s.at(j) == 0x2e || s.at(j) == 0x29 { j += 1 }
    return j
}

/// §2.3 `enum` body: "(" ( Digit{1,3} | Letter | roman{1,4} ) ")" or the
/// same without the "(" — the end index after the ")", or -1.
private func enumBodyEnd(_ s: Span, _ i: Int) -> Int {
    var j = i
    let paren = s.at(j) == 0x28
    if paren { j += 1 }
    let b = j
    var e = -1
    do {
        var d = b
        while d < s.count && isDigit(s.at(d)) && d - b < 3 { d += 1 }
        if d > b && !isDigit(s.at(d)) { e = d }
    }
    if e < 0 {
        var r = b
        while r < s.count && isRomanUnit(s.at(r)) && r - b < 4 { r += 1 }
        if r > b && s.at(r) == 0x29 { e = r }
    }
    if e < 0 && b < s.count {
        let sc = scalarAt(s, b)
        if isLetter(sc.cp) { e = b + sc.len }
    }
    if e < 0 || s.at(e) != 0x29 { return -1 }
    return e + 1
}

/// §2.3 `citation` lead body: "[" Digit{1,4} "]" — the end index after the
/// "]", or -1 (`[12] Author, Title` in a reference list).
private func citationBodyEnd(_ s: Span, _ i: Int) -> Int {
    if s.at(i) != 0x5b { return -1 }
    var d = i + 1
    while d < s.count && isDigit(s.at(d)) && d - (i + 1) < 4 { d += 1 }
    if d == i + 1 || s.at(d) != 0x5d { return -1 }
    return d + 1
}

/// §2.5 step 1b: start of the `symbols` run (§2.3, keycaps included) that
/// ends at unit `end` of `pre`, or `end` when there is none.
private func symbolsRunStart(_ pre: Span, _ end: Int) -> Int {
    var j = end
    while true {
        guard let sc = scalarBefore(pre, j) else { break }
        let cp = sc.cp
        if cp == 0x20e3 {
            // keycap: ( Digit | "#" | "*" ) U+FE0F? U+20E3
            var k = j - 1
            if k > 0 && pre.at(k - 1) == 0xfe0f { k -= 1 }
            let u = k > 0 ? pre.at(k - 1) : -1
            if isDigit(u) || u == 0x23 || u == 0x2a { j = k - 1; continue }
            j -= 1
            continue
        }
        if isSymbolSoSk(cp) || cp == 0xfe0e || cp == 0xfe0f || cp == 0x200d || (cp >= 0x1f3fb && cp <= 0x1f3ff) {
            j -= sc.len
            continue
        }
        break
    }
    return j
}

/// §2.5 step 2: a footnote reference `[^id]` or a bracketed digit run
/// `[12]` whose `]` sits at `end - 1` of `pre` — its start, or -1.
private func referenceStart(_ pre: Span, _ end: Int) -> Int {
    if end < 3 || pre.at(end - 1) != 0x5d { return -1 }
    var j = end - 1
    while j > 0 && isFootnoteIdUnit(pre.at(j - 1)) { j -= 1 }
    if j == end - 1 { return -1 }
    if j >= 2 && pre.at(j - 1) == 0x5e && pre.at(j - 2) == 0x5b { return j - 2 }
    var allDigits = true
    var k = j
    while k < end - 1 {
        if !isDigit(pre.at(k)) { allDigits = false; break }
        k += 1
    }
    if allDigits && j >= 1 && pre.at(j - 1) == 0x5b { return j - 1 }
    return -1
}

private func stripOpeners(_ tok: Span) -> Span {
    var o = 0
    while o < tok.count {
        if OPENERS.contains(tok.at(o)) { o += 1; continue }
        if tok.at(o) == 0x21 && tok.at(o + 1) == 0x5b { o += 1; continue }
        break
    }
    return tok.slice(o)
}

/// §2.5 B(ii): one Letter scalar followed by zero or more Marks.
private func isSingleLetter(_ cps: [Int]) -> Bool {
    if cps.count < 1 || !isLetter(cps[0]) { return false }
    var i = 1
    while i < cps.count {
        if !isMark(cps[i]) { return false }
        i += 1
    }
    return true
}

/// §2.5 B(ii): a compact initials chain — two or more groups of one Uppercase
/// letter (+ Marks) separated by single `.` units (`И.И`, `J.R.R`, `U.S.A`;
/// the final `.` is the terminator run).
private func isInitialsChain(_ cps: [Int]) -> Bool {
    var groups = 0
    var i = 0
    while i < cps.count {
        if !isUppercase(cps[i]) { return false }
        i += 1
        while i < cps.count && isMark(cps[i]) { i += 1 }
        groups += 1
        if i == cps.count { break }
        if cps[i] != 0x2e { return false }
        i += 1
        if i == cps.count { return false }
    }
    return groups >= 2
}

/// §2.5 B(ii): the token before `tokStart` (over ≥ 1 WS19) is itself a single
/// letter plus a terminator run — an initials chain (`J. R.`) or a spaced
/// abbreviation (`z. B.`).
private func prevTokenIsInitial(_ pre: Span, _ tokStart: Int) -> Bool {
    var i = tokStart
    while i > 0 && isWS19(pre.at(i - 1)) { i -= 1 }
    if i == tokStart { return false }
    let e = i
    while i > 0 && !isWS19(pre.at(i - 1)) { i -= 1 }
    let t = stripOpeners(pre.slice(i, e))
    var k = t.count
    while k > 0 && isTerminator(t.at(k - 1)) { k -= 1 }
    if k == t.count { return false }
    return isSingleLetter(scalarsOf(t.slice(0, k)))
}

/// §2.6 abbreviation list, stored exactly as listed (final dot removed), as
/// UTF-16 unit sequences so that the comparison is ordinal — a Swift `String`
/// compares by canonical equivalence, which would let an NFD `e\u{301}d`
/// match `éd` here and nowhere else in the family.
private let ABBREVIATIONS: Set<[UInt16]> = Set([
    // English
    "a.d", "a.m", "al", "approx", "apr", "assn", "aug", "ave", "b.c", "blvd", "ca", "cf", "ch", "co",
    "corp", "dec", "dept", "dr", "e.g", "e.u", "ed", "eds", "eq", "eqs", "esp", "etc", "excl", "ext",
    "feb", "ff", "fig", "figs", "fri", "govt", "i.e", "ibid", "inc", "incl", "jan", "jr", "jul", "jun",
    "ltd", "misc", "mr", "mrs", "ms", "mt", "nov", "oct", "p.m", "ph.d", "pp", "prof", "rd", "resp",
    "sep", "sept", "sr", "st", "tel", "thu", "tue", "u.k", "u.s", "univ", "viz", "vol", "vs",
    // German
    "abs", "bspw", "bzgl", "bzw", "d.h", "evtl", "exkl", "geb", "ggf", "hrsg", "inkl", "jh", "mio",
    "mrd", "nr", "o.ä", "o.g", "s.o", "s.u", "sog", "std", "str", "tsd", "u.a", "u.u", "usw",
    "vgl", "z.b", "z.t", "zzgl",
    // French
    "art", "av", "chap", "éd", "env", "ex", "mlle", "mme", "p.ex", "réf", "ste", "tél",
    "trad",
    // Spanish
    "aprox", "avda", "cap", "dña", "dpto", "ej", "núm", "p.ej", "pág", "págs",
    "sra", "srta", "ud", "uds",
    // Russian
    "акад", "англ", "г", "гг", "гл",
    "гос", "греч", "др", "зам",
    "изд", "им", "исп", "ит", "кв",
    "коп", "корп", "лат", "млн",
    "млрд", "напр", "нем", "н.э",
    "обл", "пер", "перев", "пл",
    "пп", "пр", "прим", "просп",
    "проф", "ред", "руб", "рус",
    "св", "см", "сокр", "сост",
    "ст", "стр", "табл", "тел",
    "т.д", "т.е", "т.к", "т.н", "т.о", "т.п",
    "т.ч", "тыс", "укр", "ул", "фр",
    "чел", "чл", "шт", "экз",
    // Ukrainian
    "буд", "вул", "грн", "див",
    "ін", "рр", "стор", "тис",
    "т.зв",
].map { u16($0) })

/// §2.6 fold: ASCII A–Z, Latin-1 À–Þ (not ×), Cyrillic А–Я, Ё Є І Ї Ґ only.
private func fold(_ s: Span) -> [UInt16] {
    var out: [UInt16] = []
    out.reserveCapacity(s.count)
    var i = 0
    while i < s.count {
        let u = s.at(i)
        i += 1
        var f = u
        if u >= 0x41 && u <= 0x5a { f = u + 0x20 }
        else if u >= 0xc0 && u <= 0xde && u != 0xd7 { f = u + 0x20 }
        else if u >= 0x410 && u <= 0x42f { f = u + 0x20 }
        else if u == 0x401 { f = 0x451 }
        else if u == 0x404 { f = 0x454 }
        else if u == 0x406 { f = 0x456 }
        else if u == 0x407 { f = 0x457 }
        else if u == 0x490 { f = 0x491 }
        out.append(UInt16(f))
    }
    return out
}

/// §2.3 prefix2 length on line `s`.
private func prefix2Length(_ s: Span) -> Int {
    let p = parsePrefix(s)
    var i = p.prefixEnd
    var heading = false
    var footnote = false
    if p.marker == nil {
        let base = p.indent1End // indent0.length + quotes.length + indent1.length
        // headingPrefix := indent0 quotes indent1 "#"{1,6} SP  (+ the WS19 run after it)
        var h = base
        var n = 0
        while h < s.count && s.at(h) == 0x23 { n += 1; h += 1 }
        // the parser's parseHeading drops SP only: `\t# h` is a paragraph (§0.12)
        let tabFree = !p.indent0HasTab && !p.indent1HasTab
        if tabFree && n >= 1 && n <= 6 && s.at(h) == SP {
            h += 1
            while h < s.count && isWS19(s.at(h)) { h += 1 }
            i = h
            heading = true
        } else {
            // footnotePrefix := indent0 quotes indent1 "[^" id "]:" WS19*
            let f = footnotePrefixLength(s, base)
            if f >= 0 {
                i = base + f
                footnote = true
            }
        }
    }
    if !heading && !footnote {
        // prefix WS19*: every §0.11 prefix — a marker, a box, a quote group or
        // nothing at all — absorbs the WS19 run after it, as headingPrefix does:
        // the parser drops SP only, but `- \tt`, `> t` and `​t` all
        // render `t` as the first visible unit of the line
        while i < s.count && isWS19(s.at(i)) { i += 1 }
    }
    // lead := ( section | enum | citation | number | dash | symbols ) WS19+
    //   enum and citation only as the first lead (directly after prefix,
    //   headingPrefix or footnotePrefix);
    //   number only as the first lead after headingPrefix (A.2: `2.5 cups`)
    func wsAfter(_ j: Int) -> Int {
        var w = j
        while w < s.count && isWS19(s.at(w)) { w += 1 }
        return w > j ? w : -1
    }
    var first = true
    while true {
        var j = i
        let u = s.at(j)
        var w = -1
        if isSectionUnit(u) {
            // section := run of ( "§" | "¶" ), WS19*, number
            var k = j
            while k < s.count && isSectionUnit(s.at(k)) { k += 1 }
            var m = k
            while m < s.count && isWS19(s.at(m)) { m += 1 }
            let n = numberBodyEnd(s, m)
            if n >= 0 { w = wsAfter(n) }
            if w < 0 { w = wsAfter(k) } // a bare `§ ` is a dash-group lead
        } else if first, enumBodyEnd(s, j) >= 0, wsAfter(enumBodyEnd(s, j)) >= 0 {
            w = wsAfter(enumBodyEnd(s, j))
        } else if first, citationBodyEnd(s, j) >= 0, wsAfter(citationBodyEnd(s, j)) >= 0 {
            w = wsAfter(citationBodyEnd(s, j))
        } else if first, heading, numberBodyEnd(s, j) >= 0, wsAfter(numberBodyEnd(s, j)) >= 0 {
            w = wsAfter(numberBodyEnd(s, j))
        }
        if w >= 0 {
            i = w
            first = false
            continue
        }
        if isLeadDashUnit(u) {
            while j < s.count && isLeadDashUnit(s.at(j)) { j += 1 }
            if j == i + 1 && u == 0x2d { break } // a single hyphen-minus is never a lead
        } else {
            while j < s.count {
                let sc = scalarAt(s, j)
                let cp = sc.cp
                // a keycap sequence (1️⃣ #️⃣ *️⃣): Digit, `#` or `*`, optional U+FE0F, U+20E3
                if isDigit(cp) || cp == 0x23 || cp == 0x2a {
                    var k = j + 1
                    if s.at(k) == 0xfe0f { k += 1 }
                    if s.at(k) == 0x20e3 { j = k + 1; continue }
                    break
                }
                let sym = isSymbolSoSk(cp) || cp == 0xfe0e || cp == 0xfe0f || cp == 0x200d || cp == 0x20e3
                    || (cp >= 0x1f3fb && cp <= 0x1f3ff)
                if !sym { break }
                j += sc.len
            }
            if j == i { break }
        }
        w = wsAfter(j)
        if w < 0 { break }
        i = w
        first = false
    }
    return i
}

/// §2.1 inline scan over P = lines s+1 … c. True when the caret is inside
/// a code span, display math or inline math. `typedFirst` is the first unit
/// of `typed`, which the reference reads as `next` at the caret.
private func insideInline(_ doc: Doc, _ scan: Scan, _ c: Int, _ before: Span, _ typedFirst: Int) -> Bool {
    // s = the last special line above c (excluded from P); a thematic break
    // and a page break end a paragraph the same way (§2.1)
    // a table row (§0.13) ends a paragraph too: the parser's row loop consumed
    // it, so an unclosed `$$` in a cell does not leak into the prose below
    var s = -1
    var k = c - 1
    while k >= 0 {
        if scan.special[k] || isThematicBreak(doc.line(k)) || isPageBreak(doc.line(k)) || tableContext(doc, scan, k) != nil {
            s = k
            break
        }
        k -= 1
    }
    // a quote line or a marker line starts a new block: P begins there (included)
    var first = s + 1
    k = c
    while k > s {
        if isQuoteLine(doc.line(k)) || doc.prefix(k).marker != nil { first = k; break }
        k -= 1
    }
    var display = false
    k = first
    while k <= c {
        let isCaretLine = k == c
        let line = isCaretLine ? before : doc.line(k)
        var code = 0
        var inline = false
        var i = 0
        func nextAt(_ idx: Int) -> Int {
            if idx < line.count { return line.at(idx) }
            if isCaretLine && idx == line.count { return typedFirst }
            return -1
        }
        func runOf(_ idx: Int, _ ch: Int) -> Int {
            var j = idx
            while j < line.count && line.at(j) == ch { j += 1 }
            return j - idx
        }
        while i < line.count {
            let u = line.at(i)
            if code > 0 {                                                  // 1.
                if u == 0x60 {
                    let n = runOf(i, 0x60)
                    if n == code { code = 0 }
                    i += n
                    continue
                }
                i += 1
                continue
            }
            if display {                                                   // 2.
                if (u == 0x24 && nextAt(i + 1) == 0x24) || (u == 0x5c && nextAt(i + 1) == 0x5d) {
                    display = false
                    i += 2
                    continue
                }
                i += 1
                continue
            }
            if inline {                                                    // 3.
                if u == 0x24 { inline = false; i += 1; continue }
                if u == 0x5c && nextAt(i + 1) == 0x29 { inline = false; i += 2; continue }
                if u == 0x5c { i += 2; continue }
                i += 1
                continue
            }
            // 4. normal
            if u == 0x60 {
                code = runOf(i, 0x60)
                i += code
                continue
            }
            if u == 0x5c {
                let n = nextAt(i + 1)
                if n == 0x5b { display = true }
                else if n == 0x28 { inline = true }
                i += 2
                continue
            }
            if u == 0x24 {
                if nextAt(i + 1) == 0x24 { display = true; i += 2; continue }
                let prev = scalarBefore(line, i)
                let prevOk = prev == nil || !(isLetter(prev!.cp) || isDigit(prev!.cp) || prev!.cp == 0x5f || prev!.cp == 0x24)
                let n = nextAt(i + 1)
                let nextOk = n != -1 && !isWS19(n) && !isDigit(n)
                if prevOk && nextOk { inline = true }
                i += 1
                continue
            }
            i += 1
        }
        // the caret line: state at the caret decides
        if isCaretLine { return code > 0 || display || inline }
        k += 1
    }
    return false
}

private let LINK_DEST = units("](")
private let SCHEME = units("://")
private let WWW = units("www.")

private func smartCapitalize(_ text: [UInt16], _ selectionStart: Int, _ selectionEnd: Int, _ typed: [UInt16]) -> String? {
    guard let norm = normalize(text, selectionStart, selectionEnd) else { return nil }
    let caret = norm.caret
    // §2.1a typed is one Lowercase letter with a defined upper()
    let tcp = scalarsOf(Span(typed))
    if tcp.count != 1 { return nil }
    if !isLowercase(tcp[0]) { return nil }
    guard let up = upper(tcp[0]), let upScalar = Unicode.Scalar(UInt32(up)) else { return nil }
    let upperTyped = String(upScalar)
    let typedFirst = Int(typed[0])

    let doc = Doc(norm.t)
    let c = lineOf(doc.lines, caret)
    if c < 0 { return nil }                                   // §0.2
    let scan = scanState(doc, c, forEnter: false)
    if scan.caretCode { return nil }                          // §2.1b
    let line = doc.line(c)
    let p = doc.prefix(c)
    if tableContext(doc, scan, c) != nil || isPipeLine(line, p) { return nil } // §2.1c
    let rel = caret - doc.lines[c].start
    let before = line.slice(0, rel)
    if insideInline(doc, scan, c, before, typedFirst) { return nil } // §2.1d

    // §2.1e link destination
    let lp = before.lastIndexOf(LINK_DEST)
    if lp >= 0 && before.indexOf(0x29, from: lp + 2) < 0 { return nil }

    // §2.1f current token. prefix2 is measured on `before` (§2.3): a caret
    // inside the SP run a marker absorbs is still at the content start.
    let p2 = prefix2Length(before)
    var lastWS = -1
    var i = before.count - 1
    while i >= 0 {
        if isWS19(before.at(i)) { lastWS = i; break }
        i -= 1
    }
    let tokenStart = max(lastWS + 1, min(p2, before.count))
    let token = before.slice(tokenStart)
    if token.indexOf(SCHEME) >= 0 || token.indexOf(WWW) >= 0 || token.contains(0x40) || token.contains(0x2f) { return nil }

    // §2.4: a task box being typed by hand — `[` directly after the marker's SP
    // run and the typed letter is `x` — is not link text: `- [x] done` must not
    // become `- [X] done`
    if p.marker != nil && !p.box && before.count == p.prefixEnd + 1
        && before.at(p.prefixEnd) == 0x5b && typed.count == 1 && typedFirst == 0x78 { return nil }

    // §2.2 pre = before minus its trailing run of openers. A guillemet opener
    // (« ‹ » ›) that is preceded by WS19, by another opener or by nothing but
    // prefix2 carries the WS19 run after it (French spacing: `« Bonjour »`);
    // a closing `»` or `«` (`Done.» then`, `»Hallo.« dann`) keeps its closer role.
    var preEnd = before.count
    var quoteStripped = false
    while true {
        if preEnd == 0 { break }
        let u = before.at(preEnd - 1)
        if OPENERS.contains(u) {
            preEnd -= 1
            if QUOTE_OPENERS.contains(u) { quoteStripped = true }
            continue
        }
        if u == 0x21 && preEnd < before.count && before.at(preEnd) == 0x5b { preEnd -= 1; continue }
        var w = preEnd
        while w > 0 && isWS19(before.at(w - 1)) { w -= 1 }
        if w < preEnd && w > 0 && GUILLEMETS.contains(before.at(w - 1)) {
            let g = w - 1
            if g == p2 || (g > 0 && (isWS19(before.at(g - 1)) || OPENERS.contains(before.at(g - 1)))) {
                preEnd = w
                continue
            }
        }
        break
    }
    let pre = before.slice(0, preEnd)

    // §2.4 rule A — line start: pre is exactly prefix2, or pre is empty (the
    // caret is at column 0, ahead of whatever prefix the line has: `|- item`,
    // or a selection that starts at the line start is being replaced)
    if preEnd == min(p2, before.count) || pre.count == 0 { return upperTyped }

    // §2.5 rule B — sentence start within the line
    i = pre.count
    let wsEnd = i
    while i > 0 && isWS19(pre.at(i - 1)) { i -= 1 }
    if i == wsEnd { return nil }                                        // 1. ≥ 1 WS19
    // 1a. direct speech after a colon: `:` before the WS19 run and a quotation
    //     opener among the stripped openers (`Он сказал: «`, `He said: "`)
    if quoteStripped && pre.at(i - 1) == 0x3a { return upperTyped }
    var viaDash = false                                                 // 1b. optional group: WS19+ (dash-run | symbols-run) WS19+
    do {
        var j = i
        while j > 0 && isMidLineDashUnit(pre.at(j - 1)) { j -= 1 }
        if j == i { j = symbolsRunStart(pre, i) }                       //    an emoji / keycap between two sentences (`Done. 🎉 next`)
        else { viaDash = true }
        if j < i {
            var w = j
            while w > 0 && isWS19(pre.at(w - 1)) { w -= 1 }
            if w < j { i = w } else { viaDash = false }
        }
    }
    var closers = 0
    while true {                                                        // 2. closers, and a footnote reference / citation
        if i > 0 && pre.at(i - 1) == 0x5d {                             //    `text.[^1] Next`, `text.[12] Next` — skipped like a closer
            let r = referenceStart(pre, i)
            if r >= 0 { i = r; closers += 1; continue }
        }
        if i > 0 && CLOSERS.contains(pre.at(i - 1)) { i -= 1; closers += 1; continue }
        break
    }
    if closers > 0 { while i > 0 && isWS19(pre.at(i - 1)) { i -= 1 } } //    French `? »`: WS19 between the terminator and a closer
    let termEnd = i
    var dots = 0
    var bangQ = false
    while i > 0 && isTerminator(pre.at(i - 1)) {
        if pre.at(i - 1) == 0x2e { dots += 1 } else { bangQ = true }
        i -= 1
    }
    if i == termEnd { return nil }                                      // 3. run length ≥ 1
    if dots >= 2 { return nil }                                         //    ellipsis
    if viaDash && pre.at(termEnd - 1) != 0x2e { return nil }            //    `? —` / `! —` are dialogue tags
    let tokEnd = i
    while i > 0 && !isWS19(pre.at(i - 1)) { i -= 1 }                    // 4. token
    var tokStart = i
    var tok = stripOpeners(pre.slice(tokStart, tokEnd))
    if tok.count == 0 && dots == 0 && tokEnd >= 1 && isWS19(pre.at(tokEnd - 1))
        && !(tokEnd >= 2 && isWS19(pre.at(tokEnd - 2))) {
        // French spacing (`Bonjour !`, `Ça va ?`): exactly one WS19 unit before the
        // run, then the token — never reaching into prefix2
        var j = tokEnd - 1
        while j > 0 && !isWS19(pre.at(j - 1)) { j -= 1 }
        if j >= p2 && j < tokEnd - 1 {
            tokStart = j
            tok = stripOpeners(pre.slice(j, tokEnd - 1))
        }
    }
    if tok.count == 0 { return nil }                                    // (i)
    if bangQ { return upperTyped }                                      //    a run with `?` or `!` ends the sentence whatever the token
    let tcps = scalarsOf(tok)
    if isSingleLetter(tcps) && tcps[0] != 0x44f {                       // (ii) one Letter (+ Marks)
        if isUppercase(tcps[0]) {
            if prevTokenIsInitial(pre, tokStart) { return nil }         // `J. R.`, `z. B.`
        } else {
            return nil                                                  // `p. 42`, `т. е.`, `J.` after a name is Lu
        }
    }
    if isInitialsChain(tcps) { return nil }                             // (ii) compact initials `И.И.`, `J.R.R.`, `U.S.A.`
    if ABBREVIATIONS.contains(fold(tok)) { return nil }                 // (iii)
    return upperTyped
}
