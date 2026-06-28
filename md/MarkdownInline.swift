//
//  MarkdownInline.swift
//  md
//
//  Created by nettrash on 28/06/2026.
//
//  Inline (span-level) Markdown rendering. The block parser hands us the
//  raw text of a heading / paragraph / list item / cell; this turns the
//  inline syntax inside it — **bold**, *italic*, `code`, [links](url),
//  ~~strikethrough~~ — into a styled `AttributedString` that SwiftUI's
//  `Text` renders natively (it honours `inlinePresentationIntent` and
//  link attributes out of the box).
//
//  We lean entirely on Foundation's `AttributedString(markdown:)` here
//  rather than hand-rolling an inline tokenizer: it is correct, battle-
//  tested, and ships in the SDK. The one wrinkle is choosing the
//  `.inlineOnlyPreservingWhitespace` syntax so it does *not* try to
//  re-interpret block structure (it would otherwise swallow our newlines
//  and mangle text the block parser already classified).
//

import Foundation
import SwiftUI

enum MarkdownInline {

    /// Parse a single block's text into a styled `AttributedString`.
    /// Newlines are preserved as soft line breaks. Falls back to a plain
    /// attributed string if Foundation can't parse the (rare) input.
    static func attributed(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        // Treat the whole string as inline content: keep our line breaks,
        // don't let the parser collapse runs or re-discover block syntax.
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.allowsExtendedAttributes = true
        options.failurePolicy = .returnPartiallyParsedIfPossible

        if let parsed = try? AttributedString(markdown: text, options: options) {
            return parsed
        }
        return AttributedString(text)
    }
}
