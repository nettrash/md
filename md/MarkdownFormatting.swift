//
//  MarkdownFormatting.swift
//  md
//
//  The formatting commands — Bold, Italic, Code, Strikethrough, Link, the six
//  headings, Bullet List, Task List, Quote, Indent and Outdent — and the
//  typed wrap (`*`, `_`, a backtick or `$` over a selection), as two pure
//  functions over the text and its selection. The same file, byte for byte,
//  in md and md.macOS, as SmartTyping.swift is.
//
//  The specification is md.win's `docs/formatting.md`, written against a
//  TypeScript reference that also generates `formatting-vectors.json`; the
//  vectors are copied verbatim into every port's tests (`FormattingTests`),
//  exactly as `typing-vectors.json` is for SmartTyping. A disputed vector is
//  changed in the reference first, in one commit across the repos.
//
//  Offsets are UTF-16 code units — `NSRange` units, so an edit applies to a
//  text view without conversion. A line break is U+000A only; CR is an
//  ordinary unit. "Blank" means SP, TAB or LF and nothing else: never a
//  platform whitespace predicate (the family has four of those, and they
//  disagree).
//
//  An edit replaces `[start, end)` of the *original* text with `text`; the
//  selection it gives is in the *resulting* text. nil is no edit at all — the
//  editor does nothing and puts nothing on the undo stack.
//

import Foundation

enum MarkdownFormatting {

    /// One formatting command. The raw values are the vector file's `op`s.
    enum Op: String, CaseIterable {
        case bold, italic, code, strikethrough, link
        case heading1, heading2, heading3, heading4, heading5, heading6, headingCycle
        case bulletList, taskList, quote, indent, outdent
    }

    struct Edit: Equatable {
        /// The replaced range of the original text, in UTF-16 units.
        let start: Int
        let end: Int
        /// What replaces it.
        let text: String
        /// The selection afterwards, in the resulting text.
        let selectionStart: Int
        let selectionEnd: Int
    }

    // MARK: Entry points

    static func format(_ text: String, selectionStart: Int, selectionEnd: Int, op: Op) -> Edit? {
        let u = Array(text.utf16)
        let s = max(0, min(min(selectionStart, selectionEnd), u.count))
        let e = max(0, min(max(selectionStart, selectionEnd), u.count))
        switch op {
        case .bold: return inline(u, s, e, .bold)
        case .italic: return inline(u, s, e, .italic)
        case .code: return inline(u, s, e, .code)
        case .strikethrough: return inline(u, s, e, .strikethrough)
        case .link: return link(u, s, e)
        case .heading1: return headingOp(u, s, e, level: 1)
        case .heading2: return headingOp(u, s, e, level: 2)
        case .heading3: return headingOp(u, s, e, level: 3)
        case .heading4: return headingOp(u, s, e, level: 4)
        case .heading5: return headingOp(u, s, e, level: 5)
        case .heading6: return headingOp(u, s, e, level: 6)
        case .headingCycle: return headingOp(u, s, e, level: nil)
        case .bulletList: return bulletOp(u, s, e)
        case .taskList: return taskOp(u, s, e)
        case .quote: return quoteOp(u, s, e)
        case .indent: return indentOp(u, s, e)
        case .outdent: return outdentOp(u, s, e)
        }
    }

    /// Typing one of `*` `_` `` ` `` `$` over a non-empty selection wraps it;
    /// anything else is ordinary typing (nil).
    static func wrapTyped(_ text: String, selectionStart: Int, selectionEnd: Int, typed: String) -> Edit? {
        let u = Array(text.utf16)
        let s = max(0, min(min(selectionStart, selectionEnd), u.count))
        let e = max(0, min(max(selectionStart, selectionEnd), u.count))
        guard s < e, ["*", "_", "`", "$"].contains(typed) else { return nil }
        return Edit(start: s, end: e, text: typed + string(u[s..<e]) + typed,
                    selectionStart: s + 1, selectionEnd: e + 1)
    }

    /// Apply an edit to the text it was computed from.
    static func apply(_ edit: Edit, to text: String) -> String {
        let u = Array(text.utf16)
        return string(u[0..<edit.start]) + edit.text + string(u[edit.end...])
    }

    // MARK: Units

    private static let sp: UInt16 = 0x20, tab: UInt16 = 0x09, lf: UInt16 = 0x0A
    private static let star: UInt16 = 0x2A, underscore: UInt16 = 0x5F, backtick: UInt16 = 0x60, tilde: UInt16 = 0x7E
    private static let hash: UInt16 = 0x23, gt: UInt16 = 0x3E

    private static func isBlankUnit(_ c: UInt16) -> Bool { c == sp || c == tab || c == lf }
    private static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func string<C: Collection>(_ units: C) -> String where C.Element == UInt16 {
        String(decoding: Array(units), as: UTF16.self)
    }
    private static func units(_ s: String) -> [UInt16] { Array(s.utf16) }

    // MARK: Inline

    private enum Inline { case bold, italic, code, strikethrough }

    private static func spec(_ kind: Inline) -> (ch: UInt16, width: Int, remove: Int, present: (Int, Int) -> Bool) {
        switch kind {
        case .bold: return (star, 2, 2, { $0 >= 2 && $1 >= 2 })
        case .italic: return (star, 1, 1, { $0 % 2 == 1 && $1 % 2 == 1 })
        case .code: return (backtick, 1, 1, { $0 == 1 && $1 == 1 })
        case .strikethrough: return (tilde, 2, 2, { $0 >= 2 && $1 >= 2 })
        }
    }

    /// The run of `ch` ending at `p`, looking no further back than `floor`.
    private static func runBefore(_ u: [UInt16], _ p: Int, _ ch: UInt16, floor: Int = 0) -> Int {
        var n = 0
        while p - n - 1 >= floor && u[p - n - 1] == ch { n += 1 }
        return n
    }

    /// The run of `ch` starting at `p`, looking no further than `ceiling`.
    private static func runAfter(_ u: [UInt16], _ p: Int, _ ch: UInt16, ceiling: Int? = nil) -> Int {
        let limit = ceiling ?? u.count
        var n = 0
        while p + n < limit && u[p + n] == ch { n += 1 }
        return n
    }

    /// The selection without its leading and trailing blank units.
    private static func trimmed(_ u: [UInt16], _ s: Int, _ e: Int) -> (Int, Int) {
        var a = s, b = e
        while a < b && isBlankUnit(u[a]) { a += 1 }
        while b > a && isBlankUnit(u[b - 1]) { b -= 1 }
        return (a, b)
    }

    private static func inline(_ u: [UInt16], _ s: Int, _ e: Int, _ kind: Inline) -> Edit {
        let spec = spec(kind)
        let marker = string(Array(repeating: spec.ch, count: spec.width))
        // Italic also recognises `_` — for removal only; it never inserts one.
        let markers: [UInt16] = kind == .italic ? [spec.ch, underscore] : [spec.ch]

        if s == e {
            // Between an empty pair of exactly this marker: take the pair out.
            if runBefore(u, s, spec.ch) == spec.width && runAfter(u, s, spec.ch) == spec.width {
                return Edit(start: s - spec.width, end: s + spec.width, text: "",
                            selectionStart: s - spec.width, selectionEnd: s - spec.width)
            }
            return Edit(start: s, end: s, text: marker + marker,
                        selectionStart: s + spec.width, selectionEnd: s + spec.width)
        }

        // 1. The selection carries the markers itself.
        for ch in markers {
            let lead = runAfter(u, s, ch, ceiling: e)
            let trail = runBefore(u, e, ch, floor: s)
            guard lead + trail < e - s else { continue }
            let present = ch == spec.ch ? spec.present(lead, trail) : lead == 1 && trail == 1
            let remove = ch == spec.ch ? spec.remove : 1
            if present {
                let inner = Array(u[(s + remove)..<(e - remove)])
                return Edit(start: s, end: e, text: string(inner),
                            selectionStart: s, selectionEnd: s + inner.count)
            }
        }
        // 2. The markers sit just outside the selection.
        for ch in markers {
            let before = runBefore(u, s, ch)
            let after = runAfter(u, e, ch)
            let present = ch == spec.ch ? spec.present(before, after) : before == 1 && after == 1
            let remove = ch == spec.ch ? spec.remove : 1
            if present {
                let inner = Array(u[s..<e])
                return Edit(start: s - remove, end: e + remove, text: string(inner),
                            selectionStart: s - remove, selectionEnd: s - remove + inner.count)
            }
        }
        // 3. Wrap what is selected, without its surrounding blanks.
        let (a, b) = trimmed(u, s, e)
        if a == b {
            return Edit(start: s, end: s, text: marker + marker,
                        selectionStart: s + spec.width, selectionEnd: s + spec.width)
        }
        return Edit(start: a, end: b, text: marker + string(u[a..<b]) + marker,
                    selectionStart: a + spec.width, selectionEnd: b + spec.width)
    }

    private static func hasASCIIPrefixIgnoringCase(_ u: [UInt16], _ prefix: String) -> Bool {
        let p = units(prefix)
        guard u.count >= p.count else { return false }
        for k in 0..<p.count {
            var c = u[k]
            if c >= 0x41 && c <= 0x5A { c += 32 }
            if c != p[k] { return false }
        }
        return true
    }

    private static func link(_ u: [UInt16], _ s: Int, _ e: Int) -> Edit {
        let (a, b) = trimmed(u, s, e)
        if a == b {
            return Edit(start: s, end: s, text: "[]()", selectionStart: s + 1, selectionEnd: s + 1)
        }
        let inner = Array(u[a..<b])
        let blank = inner.contains(where: isBlankUnit)
        if !blank && (hasASCIIPrefixIgnoringCase(inner, "http://") || hasASCIIPrefixIgnoringCase(inner, "https://")) {
            return Edit(start: a, end: b, text: "[](" + string(inner) + ")", selectionStart: a + 1, selectionEnd: a + 1)
        }
        let urlAt = a + 1 + inner.count + 2
        return Edit(start: a, end: b, text: "[" + string(inner) + "](url)", selectionStart: urlAt, selectionEnd: urlAt + 3)
    }

    // MARK: Lines

    /// `[start, end)` of one line, without its LF.
    private struct Line { let start: Int; let end: Int }

    /// Within one line: replace `[at, at + old)` with `text`.
    private struct LineChange { let at: Int; let old: Int; let text: [UInt16] }

    private static func lineAt(_ u: [UInt16], _ p: Int) -> Line {
        var start = p
        while start > 0 && u[start - 1] != lf { start -= 1 }
        var end = p
        while end < u.count && u[end] != lf { end += 1 }
        return Line(start: start, end: end)
    }

    /// The lines the selection touches; a non-empty selection ending at a
    /// line's column 0 leaves that line out.
    private static func touchedLines(_ u: [UInt16], _ s: Int, _ e: Int) -> [Line] {
        let first = lineAt(u, s)
        var lastPos = e
        if e > s && e > 0 && u[e - 1] == lf { lastPos = e - 1 }
        var lines = [first]
        var current = first
        while current.end < lastPos {
            current = lineAt(u, current.end + 1)
            lines.append(current)
        }
        return lines
    }

    private static func isBlankLine(_ l: [UInt16]) -> Bool { l.allSatisfy { $0 == sp || $0 == tab } }

    private static func indentEnd(_ l: [UInt16]) -> Int {
        var i = 0
        while i < l.count && (l[i] == sp || l[i] == tab) { i += 1 }
        return i
    }

    private static func at(_ l: [UInt16], _ i: Int) -> UInt16? { i >= 0 && i < l.count ? l[i] : nil }

    /// Heading level and marker length (the `#`s and one following SP), after up to 3 SP.
    private static func heading(_ l: [UInt16]) -> (at: Int, level: Int, length: Int)? {
        var i = 0
        while i < 3 && at(l, i) == sp { i += 1 }
        var n = 0
        while at(l, i + n) == hash { n += 1 }
        guard (1...6).contains(n) else { return nil }
        let after = i + n
        if after == l.count { return (i, n, n) }
        if l[after] == sp { return (i, n, n + 1) }
        return nil
    }

    private struct ListMarker { let at: Int; let ordered: Bool; let task: Bool; let contentAt: Int }

    /// The list marker after the indentation: `-` `*` `+`, or 1–9 digits with
    /// `.` or `)`; then SP or end of line. A task adds `[ ]`, `[x]` or `[X]`,
    /// then SP or end of line.
    private static func listMarker(_ l: [UInt16]) -> ListMarker? {
        let start = indentEnd(l)
        var i = start
        let ordered: Bool
        if let c = at(l, i), c == 0x2D || c == star || c == 0x2B {
            ordered = false
            i += 1
        } else {
            var d = 0
            while d < 9, let c = at(l, i + d), isDigit(c) { d += 1 }
            guard d > 0, let p = at(l, i + d), p == 0x2E || p == 0x29 else { return nil }
            ordered = true
            i += d + 1
        }
        if i == l.count { return ListMarker(at: start, ordered: ordered, task: false, contentAt: i) }
        guard l[i] == sp else { return nil }
        if i + 4 <= l.count {
            let box = Array(l[(i + 1)..<(i + 4)])
            if box == units("[ ]") || box == units("[x]") || box == units("[X]") {
                let after = i + 4
                if after == l.count { return ListMarker(at: start, ordered: ordered, task: true, contentAt: after) }
                if l[after] == sp { return ListMarker(at: start, ordered: ordered, task: true, contentAt: after + 1) }
            }
        }
        return ListMarker(at: start, ordered: ordered, task: false, contentAt: i + 1)
    }

    /// `>` after up to 3 SP, with one following SP when there is one.
    private static func quoteMarker(_ l: [UInt16]) -> (at: Int, length: Int)? {
        var i = 0
        while i < 3 && at(l, i) == sp { i += 1 }
        guard at(l, i) == gt else { return nil }
        return (i, at(l, i + 1) == sp ? 2 : 1)
    }

    private static func applyLines(_ u: [UInt16], _ s: Int, _ e: Int,
                                   _ plan: ([[UInt16]], [Bool]) -> [LineChange?]) -> Edit? {
        let lines = touchedLines(u, s, e)
        let strings = lines.map { Array(u[$0.start..<$0.end]) }
        let multi = lines.count > 1
        let participating = strings.map { !(multi && isBlankLine($0)) }
        let changes = plan(strings, participating)
        if changes.allSatisfy({ $0 == nil || ($0!.old == 0 && $0!.text.isEmpty) }) { return nil }

        // A position on a changed line: before the replaced span it stays; at
        // or after the span's end it moves with the span; inside the span it
        // goes to the end of the new text. A position past a line takes that
        // line's delta.
        func map(_ p: Int) -> Int {
            var delta = 0
            for k in 0..<lines.count {
                let line = lines[k]
                let change = changes[k]
                let lineDelta = change.map { $0.text.count - $0.old } ?? 0
                if p > line.end {
                    delta += lineDelta
                    continue
                }
                guard let change else { return p + delta }
                let a = line.start + change.at
                if p >= a + change.old { return p + delta + lineDelta }
                if p <= a { return p + delta }
                return a + delta + change.text.count
            }
            return p + delta
        }

        var out: [UInt16] = []
        for (k, l) in strings.enumerated() {
            if k > 0 { out.append(lf) }
            if let c = changes[k] {
                out += l[0..<c.at] + c.text + l[(c.at + c.old)...]
            } else {
                out += l
            }
        }
        return Edit(start: lines[0].start, end: lines[lines.count - 1].end, text: string(out),
                    selectionStart: map(s), selectionEnd: map(e))
    }

    private static func setHeading(_ l: [UInt16], level: Int) -> LineChange? {
        if let h = heading(l) {
            if level == 0 { return LineChange(at: h.at, old: h.length, text: []) }
            if h.level == level && h.length == level + 1 { return nil }
            return LineChange(at: h.at, old: h.length, text: Array(repeating: hash, count: level) + [sp])
        }
        if level == 0 { return nil }
        let indent = indentEnd(l)
        let at = indent <= 3 && !l[0..<indent].contains(tab) ? indent : 0
        return LineChange(at: at, old: 0, text: Array(repeating: hash, count: level) + [sp])
    }

    /// `level` nil is the phone bar's cycle: none → 1 → 2 → 3 → none, decided
    /// by the first participating line.
    private static func headingOp(_ u: [UInt16], _ s: Int, _ e: Int, level: Int?) -> Edit? {
        applyLines(u, s, e) { lines, on in
            let target: Int
            if let level {
                let all = lines.indices.allSatisfy { !on[$0] || heading(lines[$0])?.level == level }
                target = all ? 0 : level
            } else {
                let first = lines.indices.first { on[$0] }
                let current = first.flatMap { heading(lines[$0])?.level } ?? 0
                target = current == 0 ? 1 : current == 1 ? 2 : current == 2 ? 3 : 0
            }
            return lines.indices.map { on[$0] ? setHeading(lines[$0], level: target) : nil }
        }
    }

    private static func bulletOp(_ u: [UInt16], _ s: Int, _ e: Int) -> Edit? {
        applyLines(u, s, e) { lines, on in
            let all = lines.indices.allSatisfy { k in
                guard on[k] else { return true }
                guard let m = listMarker(lines[k]) else { return false }
                return !m.ordered && !m.task
            }
            return lines.indices.map { k -> LineChange? in
                guard on[k] else { return nil }
                let l = lines[k]
                let m = listMarker(l)
                if all, let m { return LineChange(at: m.at, old: m.contentAt - m.at, text: []) }
                guard let m else { return LineChange(at: indentEnd(l), old: 0, text: units("- ")) }
                if m.task || m.ordered { return LineChange(at: m.at, old: m.contentAt - m.at, text: units("- ")) }
                return nil
            }
        }
    }

    private static func taskOp(_ u: [UInt16], _ s: Int, _ e: Int) -> Edit? {
        applyLines(u, s, e) { lines, on in
            let all = lines.indices.allSatisfy { !on[$0] || listMarker(lines[$0])?.task == true }
            return lines.indices.map { k -> LineChange? in
                guard on[k] else { return nil }
                let l = lines[k]
                let m = listMarker(l)
                if all, let m { return LineChange(at: m.at, old: m.contentAt - m.at, text: []) }
                guard let m else { return LineChange(at: indentEnd(l), old: 0, text: units("- [ ] ")) }
                if m.task { return nil }
                if m.ordered { return LineChange(at: m.at, old: m.contentAt - m.at, text: units("- [ ] ")) }
                // A bullet: the box goes after its marker and space (a bare `-` gets its space too).
                return LineChange(at: m.at, old: m.contentAt - m.at, text: [l[m.at]] + units(" [ ] "))
            }
        }
    }

    private static func quoteOp(_ u: [UInt16], _ s: Int, _ e: Int) -> Edit? {
        let touched = touchedLines(u, s, e).map { Array(u[$0.start..<$0.end]) }
        let multi = touched.count > 1
        // Blank lines do not decide "all quoted"; when quoting they get a bare `>`.
        let all = touched.allSatisfy { (multi && isBlankLine($0)) || quoteMarker($0) != nil }
        return applyLines(u, s, e) { lines, _ in
            lines.map { l -> LineChange? in
                if all {
                    guard let q = quoteMarker(l) else { return nil }
                    return LineChange(at: q.at, old: q.length, text: [])
                }
                if quoteMarker(l) != nil { return nil }
                if multi && isBlankLine(l) { return LineChange(at: 0, old: 0, text: [gt]) }
                return LineChange(at: 0, old: 0, text: units("> "))
            }
        }
    }

    private static func indentOp(_ u: [UInt16], _ s: Int, _ e: Int) -> Edit? {
        applyLines(u, s, e) { lines, on in
            lines.indices.map { on[$0] ? LineChange(at: 0, old: 0, text: [sp, sp]) : nil }
        }
    }

    private static func outdentOp(_ u: [UInt16], _ s: Int, _ e: Int) -> Edit? {
        applyLines(u, s, e) { lines, _ in
            lines.map { l -> LineChange? in
                if at(l, 0) == tab { return LineChange(at: 0, old: 1, text: []) }
                let n = at(l, 0) == sp ? (at(l, 1) == sp ? 2 : 1) : 0
                return n == 0 ? nil : LineChange(at: 0, old: n, text: [])
            }
        }
    }
}
