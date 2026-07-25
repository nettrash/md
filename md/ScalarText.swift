//
//  ScalarText.swift
//  md
//
//  Created by nettrash on 24/07/2026.
//
//  Scalar-exact string operations, shared by every file that matches a
//  *delimiter* inside author text — `MarkdownParser` (the block parser the
//  preview, the HTML, the PDF, the EPUB and the outline all sit on) and
//  `LaTeXExport` (the .tex writer).
//
//  **Neither of those files may call `contains`, `hasPrefix`, `hasSuffix`,
//  `components(separatedBy:)`, `split(separator:)`, `range(of:)` or
//  `replacingOccurrences(of:with:)` on a `String`, nor compare a
//  `Character` against a delimiter.** Use the functions below, or walk
//  `unicodeScalars` and compare `Unicode.Scalar`s.
//
//  Swift matches all of those against extended *grapheme clusters*, and a
//  grapheme is not a character in the sense a parser or a writer needs.
//  Any ASCII character followed by a combining mark, a variation selector
//  or a ZWJ is one `Character` that is not equal to the plain ASCII one —
//  so `"%\u{0301}".contains("%")` is **false**, `"[\u{FE0F}".hasPrefix("[")`
//  is **false**, and `">\u{0301} quoted".first == ">"` is **false**. Every
//  one of those is a guard silently not firing.
//
//  In `LaTeXExport` that meant a broken or dangerous `.tex`: a token whose
//  digits carried a mark was never restored and raw U+E000 landed where the
//  author's formula was; a `%` path was not refused and the document did not
//  compile; a code block's own `\end{verbatim}` was not split out, the
//  environment closed early, and the rest of the author's code ran as LaTeX.
//
//  In `MarkdownParser` it is worse, because the parser is upstream of
//  everything: a mark on a *block delimiter* makes the Apple parser miss a
//  block the Android parser finds, so the same document is a different
//  document on the two platforms — in the preview, the HTML, the PDF, the
//  EPUB, the outline and the notes panel alike. Demonstrated, all silent:
//  `- ́[draft]` was a paragraph on Apple and a list on Android; a fence whose
//  ``` carried a mark was a paragraph rather than a code block; the same for
//  a table's `|`, a `[^a]:` definition, a `>` quote marker and a heading's
//  `#`. A mark on the `-->` of an HTML comment was the loudest of them: the
//  comment never closed, and the Apple parser swallowed the rest of the
//  document into it.
//
//  It is a port divergence every time. Kotlin walks UTF-16 units and has no
//  notion of a grapheme, so the Android edition already does the right
//  thing; a differential run over the three ports found that *every*
//  diverging input carried a combining mark, a variation selector or a ZWJ.
//  These functions walk `Unicode.Scalar`s, which is what the JVM's `String`
//  operations do to within a surrogate pair — and no half of a surrogate
//  pair can equal any delimiter either file ever searches for.
//
//  Two things are deliberately *not* routed through here, because they are
//  already exact:
//
//  * `==` between two `String`s where at least one side is ASCII-only (a
//    front-matter fence, `\newpage`, a fence language, a footnote id). That
//    is canonical equivalence, not grapheme matching, and no string carrying
//    a combining mark is ever canonically equal to an ASCII-only one — so it
//    means what the JVM's UTF-16 `==` means.
//  * `trimmingCharacters(in: .whitespaces)`. Foundation trims *scalars*, not
//    graphemes: `" \u{0301}abc"` trims to `"\u{0301}abc"` — the space goes
//    even though space-plus-mark is one `Character`. That is exactly what
//    Kotlin's `trimSpaces()` does, and `CharacterSet.whitespaces` is exactly
//    its predicate (Unicode `Zs` plus CHARACTER TABULATION).
//

import Foundation

enum ScalarText {

    // MARK: - Searching

    /// True when `needle`'s scalars appear in `text`'s, in order. An empty
    /// needle is never found, as in the array form below.
    static func contains(_ text: String, _ needle: String) -> Bool {
        contains(text.unicodeScalars, needle)
    }

    /// True when `needle`'s scalars appear in `scalars`, in order.
    static func contains<C: Collection>(_ scalars: C, _ needle: String) -> Bool
        where C.Element == Unicode.Scalar {
        guard !needle.unicodeScalars.isEmpty else { return false }
        var index = scalars.startIndex
        while index < scalars.endIndex {
            if hasPrefix(scalars[index...], needle) { return true }
            index = scalars.index(after: index)
        }
        return false
    }

    /// The first index at or after `start` where `needle` begins in
    /// `scalars`, comparing scalar for scalar; nil when it does not occur.
    static func firstIndex(of needle: String, in scalars: [Unicode.Scalar],
                           from start: Int = 0) -> Int? {
        firstIndex(of: Array(needle.unicodeScalars), in: scalars, from: start)
    }

    /// The same search for a needle already reduced to scalars — for a
    /// caller that scans one string for the same needle many times.
    static func firstIndex(of needle: [Unicode.Scalar],
                           in haystack: [Unicode.Scalar],
                           from start: Int) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        var index = max(start, 0)
        while index + needle.count <= haystack.count {
            var offset = 0
            while offset < needle.count, haystack[index + offset] == needle[offset] {
                offset += 1
            }
            if offset == needle.count { return index }
            index += 1
        }
        return nil
    }

    // MARK: - Prefix & suffix

    /// True when `text` begins with exactly `prefix`'s scalars.
    static func hasPrefix(_ text: String, _ prefix: String) -> Bool {
        hasPrefix(text.unicodeScalars, prefix)
    }

    /// True when `scalars` begins with exactly `prefix`'s scalars — the
    /// form that takes a scalar view, so a caller that has already dropped
    /// indentation does not have to build a `String` to ask.
    static func hasPrefix<C: Collection>(_ scalars: C, _ prefix: String) -> Bool
        where C.Element == Unicode.Scalar {
        var index = scalars.startIndex
        for wanted in prefix.unicodeScalars {
            guard index < scalars.endIndex, scalars[index] == wanted else { return false }
            index = scalars.index(after: index)
        }
        return true
    }

    /// True when `text` ends with exactly `suffix`'s scalars.
    static func hasSuffix(_ text: String, _ suffix: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        let wanted = Array(suffix.unicodeScalars)
        guard scalars.count >= wanted.count else { return false }
        let offset = scalars.count - wanted.count
        for index in 0..<wanted.count where scalars[offset + index] != wanted[index] {
            return false
        }
        return true
    }

    // MARK: - Cutting

    /// `text` cut at every occurrence of `separator`, the separators
    /// dropped — the same list Kotlin's `split(String)` returns, including
    /// the empty pieces at either end.
    static func split(_ text: String, _ separator: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        let cut = Array(separator.unicodeScalars)
        guard !cut.isEmpty else { return [text] }
        var pieces: [String] = []
        var start = 0
        var index = 0
        while let found = firstIndex(of: cut, in: scalars, from: index) {
            pieces.append(string(scalars, start, found))
            start = found + cut.count
            index = start
        }
        pieces.append(string(scalars, start, scalars.count))
        return pieces
    }

    /// Every occurrence of `target` replaced by `replacement`, left to
    /// right and never rescanning what was just written.
    static func replacing(_ text: String, _ target: String,
                          with replacement: String) -> String {
        let scalars = Array(text.unicodeScalars)
        let wanted = Array(target.unicodeScalars)
        guard !wanted.isEmpty else { return text }
        var out = ""
        var start = 0
        var index = 0
        while let found = firstIndex(of: wanted, in: scalars, from: index) {
            out += string(scalars, start, found)
            out += replacement
            start = found + wanted.count
            index = start
        }
        guard start > 0 else { return text }
        return out + string(scalars, start, scalars.count)
    }

    /// `text` without its first `count` **scalars** — what Kotlin's
    /// `substring(count)` drops, and never a combining mark the author put
    /// on the character after the delimiter.
    static func dropFirst(_ text: String, _ count: Int) -> String {
        string(text.unicodeScalars.dropFirst(count))
    }

    // MARK: - Building

    /// A `String` from any run of scalars — a view, a slice or an array.
    static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    private static func string(_ scalars: [Unicode.Scalar], _ from: Int, _ to: Int) -> String {
        guard to > from else { return "" }
        return String(String.UnicodeScalarView(scalars[from..<to]))
    }
}
