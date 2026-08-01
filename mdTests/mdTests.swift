//
//  mdTests.swift
//  mdTests
//
//  Created by nettrash on 28/06/2026.
//
//  Unit tests for the block-level Markdown parser. The parser is the one
//  piece with non-trivial logic (the views are declarative), so it gets
//  the coverage: headings, paragraphs, lists, fences, quotes, tables,
//  rules and the edge cases that separate them.
//

import Compression
import XCTest
@testable import md

final class mdTests: XCTestCase {

    // MARK: helpers

    private func parse(_ s: String) -> [MarkdownBlock.Kind] {
        MarkdownParser.parse(s).map(\.kind)
    }

    // MARK: headings

    func testHeadingLevels() {
        for level in 1...6 {
            let hashes = String(repeating: "#", count: level)
            guard case let .heading(l, text)? = parse("\(hashes) Title").first else {
                return XCTFail("expected heading for level \(level)")
            }
            XCTAssertEqual(l, level)
            XCTAssertEqual(text, "Title")
        }
    }

    func testHeadingRequiresSpace() {
        // `#Title` (no space) is a paragraph, not a heading.
        guard case .paragraph = parse("#Title").first else {
            return XCTFail("expected paragraph")
        }
    }

    func testHeadingSevenHashesIsParagraph() {
        guard case .paragraph = parse("####### too deep").first else {
            return XCTFail("expected paragraph for 7 hashes")
        }
    }

    func testHeadingClosingHashesStripped() {
        guard case let .heading(_, text)? = parse("## Title ##").first else {
            return XCTFail("expected heading")
        }
        XCTAssertEqual(text, "Title")
    }

    // MARK: paragraphs

    func testParagraphPreservesSoftBreaks() {
        guard case let .paragraph(text)? = parse("line one\nline two").first else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(text, "line one\nline two")
    }

    func testBlankLineSeparatesParagraphs() {
        let kinds = parse("first\n\nsecond")
        XCTAssertEqual(kinds.count, 2)
        if case .paragraph = kinds[0], case .paragraph = kinds[1] {} else {
            XCTFail("expected two paragraphs")
        }
    }

    // MARK: lists

    func testUnorderedList() {
        guard case let .list(ordered, items)? = parse("- a\n- b\n* c").first else {
            return XCTFail("expected list")
        }
        XCTAssertFalse(ordered)
        XCTAssertEqual(items.map(\.text), ["a", "b", "c"])
    }

    func testOrderedList() {
        guard case let .list(ordered, items)? = parse("1. one\n2. two\n3) three").first else {
            return XCTFail("expected list")
        }
        XCTAssertTrue(ordered)
        XCTAssertEqual(items.map(\.ordinal), [1, 2, 3])
    }

    func testNestedListLevels() {
        guard case let .list(_, items)? = parse("- top\n  - nested\n    - deeper").first else {
            return XCTFail("expected list")
        }
        XCTAssertEqual(items.map(\.level), [0, 1, 2])
    }

    func testTaskList() {
        guard case let .list(_, items)? = parse("- [ ] todo\n- [x] done\n- [X] also").first else {
            return XCTFail("expected list")
        }
        XCTAssertEqual(items.map(\.task), [false, true, true])
        XCTAssertEqual(items.map(\.text), ["todo", "done", "also"])
    }

    // MARK: code fences

    func testFencedCodeWithLanguage() {
        guard case let .codeBlock(lang, code)? = parse("```swift\nlet x = 1\n```").first else {
            return XCTFail("expected code block")
        }
        XCTAssertEqual(lang, "swift")
        XCTAssertEqual(code, "let x = 1")
    }

    func testTildeFence() {
        guard case let .codeBlock(_, code)? = parse("~~~\nplain\n~~~").first else {
            return XCTFail("expected code block")
        }
        XCTAssertEqual(code, "plain")
    }

    func testFenceContentIsNotInterpreted() {
        // A `#` inside a fence is code, not a heading.
        guard case let .codeBlock(_, code)? = parse("```\n# not a heading\n```").first else {
            return XCTFail("expected code block")
        }
        XCTAssertEqual(code, "# not a heading")
    }

    func testUnclosedFenceConsumesToEnd() {
        guard case let .codeBlock(_, code)? = parse("```\na\nb").first else {
            return XCTFail("expected code block")
        }
        XCTAssertEqual(code, "a\nb")
    }

    func testIndentedFenceStripsIndent() {
        guard case let .codeBlock(_, code)? = parse("  ```\n  indented\n  ```").first else {
            return XCTFail("expected code block")
        }
        XCTAssertEqual(code, "indented")
    }

    // MARK: block quotes

    func testBlockQuote() {
        guard case let .quote(inner)? = parse("> quoted\n> text").first else {
            return XCTFail("expected quote")
        }
        guard case let .paragraph(text)? = inner.first?.kind else {
            return XCTFail("expected paragraph inside quote")
        }
        XCTAssertEqual(text, "quoted\ntext")
    }

    func testNestedBlockQuote() {
        guard case let .quote(inner)? = parse("> > deep").first else {
            return XCTFail("expected quote")
        }
        guard case .quote = inner.first?.kind else {
            return XCTFail("expected nested quote")
        }
    }

    // MARK: thematic breaks

    func testThematicBreaks() {
        for rule in ["---", "***", "___", "- - -", "****"] {
            guard case .thematicBreak? = parse(rule).first else {
                return XCTFail("expected thematic break for \(rule)")
            }
        }
    }

    func testDashesUnderTextAreNotRuleWhenTooShort() {
        // Two dashes is not a rule; it's a paragraph.
        guard case .paragraph? = parse("--").first else {
            return XCTFail("expected paragraph for two dashes")
        }
    }

    // MARK: tables

    func testTableParsing() {
        let md = """
        | Name | Age |
        | :--- | ---: |
        | Ann  | 30 |
        | Bob  | 25 |
        """
        guard case let .table(header, alignments, rows)? = parse(md).first else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(header, ["Name", "Age"])
        XCTAssertEqual(alignments, [.leading, .trailing])
        XCTAssertEqual(rows, [["Ann", "30"], ["Bob", "25"]])
    }

    func testTableCenterAlignment() {
        let md = "| A | B |\n|:-:|:-:|\n| 1 | 2 |"
        guard case let .table(_, alignments, _)? = parse(md).first else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(alignments, [.center, .center])
    }

    func testTableEscapedPipe() {
        let md = "| Col |\n| --- |\n| a \\| b |"
        guard case let .table(_, _, rows)? = parse(md).first else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(rows, [["a | b"]])
    }

    func testNotATableWithoutDelimiterRow() {
        // A line with pipes but no delimiter below is a paragraph.
        guard case .paragraph? = parse("a | b | c\nx | y | z").first else {
            return XCTFail("expected paragraph")
        }
    }

    // MARK: front matter

    func testYAMLFrontMatterIsParsedAndHidden() {
        let md = """
        ---
        title: My Book
        author: nettrash
        date: 2026-07-24
        ---

        # Chapter One

        Text.
        """
        let kinds = parse(md)
        guard case let .frontMatter(fields)? = kinds.first else {
            return XCTFail("expected front matter first")
        }
        XCTAssertEqual(fields, [
            MetadataField(key: "title", value: "My Book"),
            MetadataField(key: "author", value: "nettrash"),
            MetadataField(key: "date", value: "2026-07-24"),
        ])
        // The opening `---` must not survive as a thematic break, and the
        // metadata must not survive as prose — that is how such a file used
        // to look, and it is the whole point of the feature.
        XCTAssertFalse(kinds.contains { if case .thematicBreak = $0 { return true }; return false })
        let html = MarkdownHTML.document(md, title: "t", dark: false)
        XCTAssertFalse(html.contains("My Book"))
        XCTAssertFalse(html.contains("<hr>"))
        XCTAssertTrue(html.contains("Chapter One"))
    }

    func testTOMLFrontMatterUsesEquals() {
        let kinds = parse("+++\ntitle = \"Quoted\"\ndraft = false\n+++\n\nBody.")
        guard case let .frontMatter(fields)? = kinds.first else {
            return XCTFail("expected front matter")
        }
        // Quotes around a value are stripped — every generator writes some.
        XCTAssertEqual(fields, [
            MetadataField(key: "title", value: "Quoted"),
            MetadataField(key: "draft", value: "false"),
        ])
    }

    func testFrontMatterOnlyAtTheVeryTopAndOnlyWhenClosed() {
        // An unclosed fence is not front matter: a document that simply opens
        // with a horizontal rule must keep its rule rather than have the rest
        // of the file swallowed as metadata.
        let unclosed = parse("---\n\nJust a rule above.")
        guard case .thematicBreak? = unclosed.first else {
            return XCTFail("an unclosed opener stays a thematic break")
        }
        // The dangerous case, because a YAML opener is spelled exactly like a
        // thematic break: a document that opens with a rule, says something,
        // and rules off again. Every word of it must survive — an earlier
        // version of this swallowed the prose between the two rules.
        let divider = parse("---\n\nIntro the reader must see.\n\n---\n\nMore.")
        guard case .thematicBreak? = divider.first else {
            return XCTFail("a rule followed by a blank line is a rule")
        }
        XCTAssertTrue(divider.contains {
            if case let .paragraph(t) = $0 { return t == "Intro the reader must see." }
            return false
        }, "the prose under the rule must survive")

        // The blank-line guard on its own. This input is the only shape that
        // isolates it — the two cases above are caught by the "at least one
        // field" guard as well, so without this the blank-line guard could be
        // deleted and the suite would stay green.
        let blankFirst = parse("---\n\ntitle: A\n---\n\nbody")
        XCTAssertFalse(blankFirst.contains { if case .frontMatter = $0 { return true }; return false })
        guard case .thematicBreak? = blankFirst.first else {
            return XCTFail("a blank line after the opener means this is a rule")
        }

        // Same guard without the blank line: no `key: value` anywhere means it
        // was never metadata, so this stays a break plus a setext heading —
        // which is how it reads in every other Markdown tool.
        let setext = parse("---\nChapter One\n---\n\nText.")
        XCTAssertFalse(setext.contains { if case .frontMatter = $0 { return true }; return false })
        XCTAssertTrue(setext.contains {
            if case let .heading(level, text) = $0 { return level == 2 && text == "Chapter One" }
            return false
        }, "the setext heading must survive")

        // A fence further down is an ordinary thematic break too.
        let later = parse("# Title\n\n---\n\ntitle: not metadata\n\n---")
        XCTAssertFalse(later.contains { if case .frontMatter = $0 { return true }; return false })
        // And it is never front matter inside a block quote.
        guard case let .quote(inner)? = parse("> ---\n> title: x\n> ---").first else {
            return XCTFail("expected a quote")
        }
        XCTAssertFalse(inner.contains { if case .frontMatter = $0.kind { return true }; return false })
    }

    func testFrontMatterSkipsWhatTheFlatScanCannotRead() {
        // Lists, nested mappings and comments are skipped, but the block is
        // still consumed whole — which is what decides how the page looks.
        let md = """
        ---
        title: Deep
        # a comment
        tags:
          - one
          - two
        ---
        Body.
        """
        let kinds = parse(md)
        guard case let .frontMatter(fields)? = kinds.first else {
            return XCTFail("expected front matter")
        }
        XCTAssertEqual(fields.first, MetadataField(key: "title", value: "Deep"))
        XCTAssertTrue(fields.contains(MetadataField(key: "tags", value: "")))
        XCTAssertFalse(fields.contains { $0.key.hasPrefix("-") })
        // Exactly one block follows, and it is the body paragraph.
        XCTAssertEqual(kinds.count, 2)
        guard case let .paragraph(text)? = kinds.last else {
            return XCTFail("expected the body paragraph")
        }
        XCTAssertEqual(text, "Body.")
    }

    func testFrontMatterDoesNotLeakIntoTheOutlineOrNotes() {
        // The closing `---` underlines the last metadata line, so a scanner
        // that walks the raw source reads it as a setext heading the rendered
        // document does not contain — and its slug then pushes every real
        // heading's anchor out of step with the ids MarkdownHTML assigns, so
        // the table of contents scrolls to nothing.
        let md = "---\ntitle: My Post\n---\n\n# Hello\n"
        let outline = MarkdownParser.outline(md)
        XCTAssertEqual(outline.map(\.text), ["Hello"])
        XCTAssertEqual(outline.first?.slug, "hello")
        let html = MarkdownHTML.document(md, title: "t", dark: false)
        XCTAssertTrue(html.contains("id=\"hello\""), "the TOC slug must match the rendered id")

        // The same for a heading whose slug the phantom would have stolen.
        let clash = "---\nHello: x\n---\n\n# Hello: x\n"
        XCTAssertEqual(MarkdownParser.outline(clash).first?.slug, "hello-x")
        XCTAssertTrue(MarkdownHTML.document(clash, title: "t", dark: false).contains("id=\"hello-x\""))

        // A comment inside the metadata is not one of the author's notes.
        XCTAssertTrue(MarkdownParser.notes("---\ntitle: X\n<!-- note: hidden -->\n---\n\nBody.").isEmpty)
        // …while a note in the document proper is still found.
        XCTAssertEqual(MarkdownParser.notes("---\ntitle: X\n---\n\n<!-- note: real -->").count, 1)
    }

    func testFrontMatterAccessor() {
        let fields = MarkdownParser.frontMatter(of: "---\nauthor: Ann\n---\n\nHi.")
        XCTAssertEqual(fields, [MetadataField(key: "author", value: "Ann")])
        XCTAssertTrue(MarkdownParser.frontMatter(of: "# Plain\n\nNo metadata.").isEmpty)
    }

    // MARK: footnotes

    func testFootnoteDefinitionIsParsedAndNotDrawnInPlace() {
        let kinds = parse("Text[^a].\n\n[^a]: The note.")
        guard case let .footnoteDefinition(id, text)? = kinds.last else {
            return XCTFail("expected a footnote definition")
        }
        XCTAssertEqual(id, "a")
        XCTAssertEqual(text, "The note.")
        // A definition must not also render as a paragraph where it was written.
        let html = MarkdownHTML.document("Text[^a].\n\n[^a]: The note.", title: "t", dark: false)
        XCTAssertFalse(html.contains("<p>[^a]: The note.</p>"))
        XCTAssertTrue(html.contains("<li id=\"fn-1\">The note."))
    }

    func testFootnotesAreNumberedByFirstReferenceNotDefinitionOrder() {
        // `b` is cited first, so it is footnote 1 even though `a` is defined
        // first — the number a reader sees follows the reading order.
        let html = MarkdownHTML.document(
            "See[^b] then[^a].\n\n[^a]: Alpha.\n[^b]: Bravo.", title: "t", dark: false)
        XCTAssertTrue(html.contains("<li id=\"fn-1\">Bravo."))
        XCTAssertTrue(html.contains("<li id=\"fn-2\">Alpha."))
        guard let first = html.range(of: "#fn-1"), let second = html.range(of: "#fn-2") else {
            return XCTFail("expected both references")
        }
        XCTAssertTrue(first.lowerBound < second.lowerBound)
    }

    func testRepeatedFootnoteReferenceGetsItsOwnAnchor() {
        let html = MarkdownHTML.document("One[^a] two[^a].\n\n[^a]: Note.", title: "t", dark: false)
        // Both cite footnote 1…
        XCTAssertEqual(html.components(separatedBy: "href=\"#fn-1\"").count - 1, 2)
        // …but each reference is its own anchor, so the ids stay unique.
        XCTAssertTrue(html.contains("id=\"fnref-1\""))
        XCTAssertTrue(html.contains("id=\"fnref-1-2\""))
        // The note's back-link goes to the first citation.
        XCTAssertTrue(html.contains("href=\"#fnref-1\""))
    }

    func testFootnoteReferenceWithoutDefinitionStaysLiteralText() {
        // Linking to nothing would be worse than leaving the author's text be.
        let html = MarkdownHTML.document("A claim[^nope].", title: "t", dark: false)
        XCTAssertTrue(html.contains("[^nope]"))
        // Assert on the emitted markup, not the class name: the stylesheet
        // names every class unconditionally, so a bare `contains` would pass
        // no matter what the body actually holds.
        XCTAssertFalse(html.contains("<sup class=\"md-fnref\""))
        XCTAssertFalse(html.contains("<section class=\"md-footnotes\">"))
    }

    func testUnreferencedFootnoteIsStillPrinted() {
        // Dropping it would silently discard something the author wrote. It
        // gets no back-link, having nowhere to go back to.
        let html = MarkdownHTML.document("Body.\n\n[^lone]: Never cited.", title: "t", dark: false)
        XCTAssertTrue(html.contains("<li id=\"fn-1\">Never cited."))
        XCTAssertFalse(html.contains("<a class=\"md-fnback\""))
    }

    func testFootnoteTextIsInlineMarkdownAndIsEscaped() {
        let html = MarkdownHTML.document(
            "X[^a].\n\n[^a]: *Emphasis* and <b>literal</b> & co.", title: "t", dark: false)
        XCTAssertTrue(html.contains("<em>Emphasis</em>"))
        XCTAssertTrue(html.contains("&lt;b&gt;literal&lt;/b&gt;"))
        XCTAssertTrue(html.contains("&amp; co."))
    }

    func testFootnoteInsideCodeIsNotAReference() {
        // A code span's content is literal — it must not sprout a footnote.
        let html = MarkdownHTML.document("Use `arr[^1]` here.\n\n[^1]: Note.", title: "t", dark: false)
        XCTAssertTrue(html.contains("<code>arr[^1]</code>"))
        XCTAssertFalse(html.contains("<code>arr<sup"))
    }

    func testFootnoteDefinitionAbsorbsWrappedLines() {
        let kinds = parse("X[^a].\n\n[^a]: first line\n  second line\n\nAfter.")
        guard case let .footnoteDefinition(_, text)? = kinds.dropFirst().first else {
            return XCTFail("expected a footnote definition")
        }
        XCTAssertEqual(text, "first line second line")
        // The paragraph after the blank line is its own block, not swallowed.
        guard case let .paragraph(after)? = kinds.last else {
            return XCTFail("expected the trailing paragraph")
        }
        XCTAssertEqual(after, "After.")
    }

    func testFootnoteReferenceCannotBreakOutIntoMarkup() {
        // The reference becomes markup full of quotes and angle brackets, so
        // it is converted *after* images and links. Converting it first let an
        // image carry that markup into an `alt` attribute, straight through
        // the quoting the inline pass relies on, and let a link wrap it in an
        // `<a>` inside another `<a>`. Writing a reference inside a link's own
        // label now simply stops that label being a link — the harmless
        // failure, and a nonsensical thing to write in the first place.
        let image = MarkdownHTML.document("![alt [^a] here](i.png)\n\n[^a]: N.", title: "t", dark: false)
        XCTAssertFalse(image.contains("alt=\"alt <sup"), "markup must never reach an attribute")

        let link = MarkdownHTML.document("[see [^a] here](u)\n\n[^a]: N.", title: "t", dark: false)
        XCTAssertFalse(link.contains("<a href=\"u\">"), "a label holding a reference is not a link")
        XCTAssertFalse(link.contains("</a></a>"), "no anchor may nest inside another")

        // An ordinary link and image are untouched by the footnote pass.
        let plain = MarkdownHTML.document("[text](u) and ![a](i.png)", title: "t", dark: false)
        XCTAssertTrue(plain.contains("<a href=\"u\">text</a>"))
        XCTAssertTrue(plain.contains("<img src=\"i.png\" alt=\"a\">"))
    }

    func testFootnoteReferenceNestedInsideANoteBecomesLiteralText() {
        // A reference inside a footnote's own text has missed the numbering
        // pass — it must be cleaned back to what the author typed, never left
        // as raw placeholder markup for the reader to see.
        let html = MarkdownHTML.document("X[^a].\n\n[^a]: see [^b] too.\n[^b]: Other.",
                                         title: "t", dark: false)
        XCTAssertFalse(html.contains("data-fn="), "no placeholder may survive into the page")
        XCTAssertTrue(html.contains("[^b]"))
    }

    func testFootnoteDefinitionDoesNotLeakIntoTheOutline() {
        // `parse` claims the definition line, so an underline beneath it is a
        // rule — not a setext heading. The outline must agree, or it lists a
        // heading that isn't there and every later anchor drifts.
        let md = "# Real\n\n[^a]: The note.\n---\n\nText[^a]."
        XCTAssertEqual(MarkdownParser.outline(md).map(\.text), ["Real"])
    }

    func testUnicodeSpacingAndWordBoundariesAgreeAcrossPlatforms() {
        // Foundation trims `CharacterSet.whitespaces` — Unicode's Zs category
        // plus tab — and the Android port trims exactly that set too. These
        // are the inputs that used to diverge: padded with a non-breaking
        // space, a fence was metadata on Apple and an ordinary paragraph on
        // Android, so a document's front matter went missing on one platform
        // of the three.
        let nbsp = "\u{00A0}"
        XCTAssertEqual(MarkdownParser.frontMatter(of: "---\ntitle: A\n---\(nbsp)\n\nbody"),
                       [MetadataField(key: "title", value: "A")])
        XCTAssertNotNil(MarkdownParser.parseFootnoteDefinition("\(nbsp)[^a]: note"))
        XCTAssertEqual(MarkdownParser.parseFootnoteDefinition("[^a]: note\(nbsp)")?.text, "note")

        // `\w` means Unicode here, through ICU. Android's regex engine reads it
        // as ASCII unless asked otherwise, which made a Cyrillic letter count
        // as a non-word character — turning prose into emphasis, and a pair of
        // prices into a formula, on that platform alone.
        let cyrillic = MarkdownHTML.document("\u{0444}_em_\u{0444} and \u{0444}$x$\u{0444}",
                                             title: "t", dark: false)
        XCTAssertFalse(cyrillic.contains("<em>"), "an underscore between letters is not emphasis")
        XCTAssertFalse(cyrillic.contains("<span class=\"md-mathi\">"),
                       "a dollar between letters is not a formula")
    }

    func testFootnoteIdentifierCharacterSet() {
        XCTAssertNotNil(MarkdownParser.parseFootnoteDefinition("[^a-1_B]: ok"))
        // Non-ASCII is rejected, and must be: the renderer's reference pattern
        // is ASCII-only, so a Unicode identifier would be a definition that no
        // reference could ever name — parsed, found unreferenced, and printed
        // on its own at the foot of the page.
        XCTAssertNil(MarkdownParser.parseFootnoteDefinition("[^caf\u{00E9}]: no"))
        XCTAssertNil(MarkdownParser.parseFootnoteDefinition("[^\u{0441}\u{043D}]: no"))
        // A space or punctuation in the identifier is not a definition, so the
        // line stays ordinary text rather than becoming a note that no
        // reference could ever match.
        XCTAssertNil(MarkdownParser.parseFootnoteDefinition("[^two words]: no"))
        XCTAssertNil(MarkdownParser.parseFootnoteDefinition("[^a.b]: no"))
        XCTAssertNil(MarkdownParser.parseFootnoteDefinition("[^]: no"))
        XCTAssertNil(MarkdownParser.parseFootnoteDefinition("[a]: not a footnote"))
    }

    // MARK: mixed document

    func testMixedDocumentBlockSequence() {
        let md = """
        # Title

        Intro paragraph.

        - one
        - two

        > a quote

        ```
        code
        ```

        ---
        """
        let kinds = parse(md)
        XCTAssertEqual(kinds.count, 6)
        guard case .heading = kinds[0] else { return XCTFail("0 heading") }
        guard case .paragraph = kinds[1] else { return XCTFail("1 paragraph") }
        guard case .list = kinds[2] else { return XCTFail("2 list") }
        guard case .quote = kinds[3] else { return XCTFail("3 quote") }
        guard case .codeBlock = kinds[4] else { return XCTFail("4 code") }
        guard case .thematicBreak = kinds[5] else { return XCTFail("5 rule") }
    }

    // MARK: setext headings (regression — review finding)

    func testSetextHeadings() {
        guard case let .heading(l1, t1)? = parse("My Title\n===").first else {
            return XCTFail("expected H1")
        }
        XCTAssertEqual(l1, 1)
        XCTAssertEqual(t1, "My Title")

        let h2 = parse("My Title\n---")
        guard case let .heading(l2, t2)? = h2.first else { return XCTFail("expected H2") }
        XCTAssertEqual(l2, 2)
        XCTAssertEqual(t2, "My Title")
        // The underline must NOT also emit a spurious thematic break.
        XCTAssertEqual(h2.count, 1)
    }

    func testStandaloneRuleStillParsesAfterSetextChange() {
        guard case .thematicBreak? = parse("---").first else {
            return XCTFail("a standalone --- is still a rule")
        }
    }

    // MARK: list continuation (regression — review finding)

    func testListItemContinuationIsAbsorbed() {
        let blocks = parse("- First item\n  with continuation\n- Second item")
        XCTAssertEqual(blocks.count, 1, "should be one list, not list+paragraph+list")
        guard case let .list(_, items)? = blocks.first else {
            return XCTFail("expected list")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].text, "First item with continuation")
        XCTAssertEqual(items[1].text, "Second item")
    }

    // MARK: heading trailing '#' (regression — review finding)

    func testHeadingPreservesTrailingHashInWord() {
        guard case let .heading(_, text)? = parse("# C#").first else {
            return XCTFail("expected heading")
        }
        XCTAssertEqual(text, "C#")
        guard case let .heading(_, t2)? = parse("# F# notes").first else {
            return XCTFail("expected heading")
        }
        XCTAssertEqual(t2, "F# notes")
    }

    // MARK: tab-indented lists (regression — review finding)

    func testTabIndentedNestedListRecognised() {
        guard case let .list(_, items)? = parse("- top\n\t- nested").first else {
            return XCTFail("expected list")
        }
        XCTAssertEqual(items.map(\.text), ["top", "nested"])
        XCTAssertGreaterThan(items[1].level, items[0].level)
    }

    // MARK: deep block-quote recursion is bounded (regression — crash)

    func testDeeplyNestedQuoteDoesNotOverflow() {
        let input = String(repeating: ">", count: 5000) + " deep"
        let blocks = MarkdownParser.parse(input)   // must return, not crash
        XCTAssertFalse(blocks.isEmpty)
        guard case .quote? = blocks.first?.kind else {
            return XCTFail("expected a quote block")
        }
    }

    // MARK: HTML serialization (print / PDF / share-rendered)

    func testHTMLWrapsDocument() {
        let html = MarkdownHTML.document("# Title", title: "Doc", dark: false)
        XCTAssertTrue(html.contains("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("<title>Doc</title>"))
        XCTAssertTrue(html.contains("<h1 id=\"title\">Title</h1>"))
    }

    func testHTMLEscapesSpecialCharacters() {
        let html = MarkdownHTML.document("a < b & c > d", title: "t", dark: false)
        XCTAssertTrue(html.contains("a &lt; b &amp; c &gt; d"))
    }

    func testHTMLInlineEmphasis() {
        let html = MarkdownHTML.document("**bold** and *italic* and ~~gone~~", title: "t", dark: false)
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<em>italic</em>"))
        XCTAssertTrue(html.contains("<del>gone</del>"))
    }

    func testHTMLCodeSpanIsEscapedAndNotReinterpreted() {
        let html = MarkdownHTML.document("`a < *b* > c`", title: "t", dark: false)
        XCTAssertTrue(html.contains("<code>a &lt; *b* &gt; c</code>"))
        // The `*` inside the code span must stay literal, not become <em>.
        XCTAssertFalse(html.contains("<em>b</em>"))
    }

    func testHTMLLink() {
        let html = MarkdownHTML.document("[site](https://nettrash.me)", title: "t", dark: false)
        XCTAssertTrue(html.contains("<a href=\"https://nettrash.me\">site</a>"))
    }

    func testHTMLLinkWithTitle() {
        let html = MarkdownHTML.document("[site](https://nettrash.me \"Hover title\")",
                                         title: "t", dark: false)
        XCTAssertTrue(html.contains("<a href=\"https://nettrash.me\" title=\"Hover title\">site</a>"))
    }

    func testHTMLImage() {
        let html = MarkdownHTML.document("![Alt text](https://nettrash.me/favicon.ico)",
                                         title: "t", dark: false)
        XCTAssertTrue(html.contains("<img src=\"https://nettrash.me/favicon.ico\" alt=\"Alt text\">"))
    }

    func testHTMLImageWithTitle() {
        let html = MarkdownHTML.document("![Alt](https://nettrash.me/favicon.ico \"The favicon\")",
                                         title: "t", dark: false)
        XCTAssertTrue(html.contains(
            "<img src=\"https://nettrash.me/favicon.ico\" alt=\"Alt\" title=\"The favicon\">"))
    }

    func testHTMLLinkedImage() {
        // The image pass must run before the link pass, so `[![…](…)](…)`
        // nests the <img> inside the <a> instead of the link eating the label.
        let html = MarkdownHTML.document(
            "[![badge](https://nettrash.me/favicon.ico)](https://nettrash.me)",
            title: "t", dark: false)
        XCTAssertTrue(html.contains(
            "<a href=\"https://nettrash.me\"><img src=\"https://nettrash.me/favicon.ico\" alt=\"badge\"></a>"))
    }

    func testHTMLUnderscoreInWordIsNotItalic() {
        // snake_case must survive (underscore italic is word-boundary only).
        let html = MarkdownHTML.document("call some_long_name now", title: "t", dark: false)
        XCTAssertFalse(html.contains("<em>"))
    }

    func testHTMLTableAlignmentsAndCells() {
        let html = MarkdownHTML.document("| A | B |\n|:-:|--:|\n| 1 | 2 |", title: "t", dark: false)
        XCTAssertTrue(html.contains("text-align:center"))
        XCTAssertTrue(html.contains("text-align:right"))
        XCTAssertTrue(html.contains("<td"))
    }

    func testHTMLThemeVariantsDiffer() {
        let light = MarkdownHTML.document("hi", title: "t", dark: false)
        let dark = MarkdownHTML.document("hi", title: "t", dark: true)
        XCTAssertNotEqual(light, dark)
        XCTAssertTrue(dark.contains("color-scheme: dark"))
        // Backgrounds must be forced to print so the theme survives to PDF.
        XCTAssertTrue(dark.contains("print-color-adjust: exact"))
    }

    // MARK: rich blocks — math / Mermaid / PlantUML (v1.1)

    func testHTMLMermaidBlockEmitsContainer() {
        let html = MarkdownHTML.document("```mermaid\ngraph TD\nA-->B\n```", title: "t", dark: false)
        XCTAssertTrue(html.contains("<pre class=\"mermaid\">"))
        XCTAssertTrue(html.contains("graph TD"))
        // A mermaid fence must NOT become an ordinary code block.
        XCTAssertFalse(html.contains("<pre><code>graph TD"))
        // And the Mermaid engine is pulled in, but not KaTeX/PlantUML.
        XCTAssertTrue(html.contains("mermaid.min.js"))
        XCTAssertFalse(html.contains("katex.min.js"))
        XCTAssertFalse(html.contains("viz-global.js"))
    }

    func testHTMLPlantumlBlockEmitsContainer() {
        let html = MarkdownHTML.document("```plantuml\n@startuml\nA->B\n@enduml\n```", title: "t", dark: false)
        XCTAssertTrue(html.contains("<div class=\"plantuml\">"))
        XCTAssertTrue(html.contains("@startuml"))
        // PlantUML needs Viz/Graphviz; the engine itself is imported lazily by md-init.js.
        XCTAssertTrue(html.contains("viz-global.js"))
    }

    func testHTMLGraphvizBlockEmitsContainer() {
        let html = MarkdownHTML.document("```dot\ndigraph { a -> b }\n```", title: "t", dark: false)
        XCTAssertTrue(html.contains("<div class=\"graphviz\" data-engine=\"dot\">"))
        XCTAssertTrue(html.contains("digraph { a -&gt; b }"))
        // A dot fence must NOT become an ordinary code block.
        XCTAssertFalse(html.contains("<pre><code>digraph"))
        // Graphviz *is* Viz.js — the engine md already bundles for PlantUML —
        // so a dot block adds no payload beyond the include PlantUML needs.
        XCTAssertTrue(html.contains("viz-global.js"))
        XCTAssertFalse(html.contains("mermaid.min.js"))
        XCTAssertFalse(html.contains("katex.min.js"))
    }

    func testHTMLGraphvizAliasesAndLayoutEngines() {
        // ```graphviz and ```gv are spellings of the default `dot` layout…
        for alias in ["graphviz", "gv"] {
            let html = MarkdownHTML.document("```\(alias)\ngraph { a -- b }\n```", title: "t", dark: false)
            XCTAssertTrue(html.contains("data-engine=\"dot\""), "\(alias) selects the dot layout")
        }
        // …while the layout programs name themselves, the way Graphviz is
        // invoked on a command line (`neato -Tsvg`). Every one of these must be
        // a name Viz.js accepts, or the render throws.
        for engine in ["neato", "circo", "fdp", "sfdp", "twopi", "osage", "patchwork"] {
            let html = MarkdownHTML.document("```\(engine)\ngraph { a -- b }\n```", title: "t", dark: false)
            XCTAssertTrue(html.contains("data-engine=\"\(engine)\""), "\(engine) selects its own layout")
        }
        // An unrelated language is a code block, not a diagram — and now
        // carries its `language-` hint for highlighting rather than being bare.
        let swift = MarkdownHTML.document("```swift\nlet x = 1\n```", title: "t", dark: false)
        XCTAssertTrue(swift.contains("<pre><code class=\"language-swift\">let x = 1"))
        XCTAssertFalse(swift.contains("class=\"graphviz\""))
        XCTAssertFalse(swift.contains("viz-global.js"))
    }

    func testHTMLGraphvizEscapesAngleBrackets() {
        // DOT's HTML-like labels are full of `<`/`>`. They must be escaped into
        // the container (md-init.js reads the decoded textContent back out), or
        // the label markup would be parsed as page markup.
        let html = MarkdownHTML.document(
            "```dot\ndigraph { n [label=<<b>hi</b>>] }\n```", title: "t", dark: false)
        XCTAssertTrue(html.contains("&lt;&lt;b&gt;hi&lt;/b&gt;&gt;"))
        XCTAssertFalse(html.contains("<b>hi</b>"))
    }

    func testGraphvizInkRulesSurviveCSSCommentStripping() {
        // The Graphviz ink rules sit under a long explanatory comment. If that
        // comment ever closes early, the loose prose that follows becomes the
        // prelude of the next rule and the CSS parser swallows that rule whole
        // — the diagram then draws in black on the dark paper. A test that
        // merely greps the document for the rule text still passes in that
        // state, because the text *is* there; it just isn't CSS any more. So
        // strip comments the way a parser does, and assert on what survives.
        for dark in [false, true] {
            let html = MarkdownHTML.document("```dot\ndigraph { a }\n```", title: "t", dark: dark)
            guard let open = html.range(of: "<style>"), let close = html.range(of: "</style>") else {
                return XCTFail("no stylesheet in the document")
            }
            let css = String(html[open.upperBound..<close.lowerBound])
            XCTAssertEqual(css.components(separatedBy: "/*").count,
                           css.components(separatedBy: "*/").count,
                           "Every CSS comment must open and close exactly once")

            var stripped = ""
            var scanning = Substring(css)
            while let start = scanning.range(of: "/*") {
                stripped += scanning[..<start.lowerBound]
                let after = scanning[start.upperBound...]
                guard let end = after.range(of: "*/") else {
                    return XCTFail("unterminated CSS comment")
                }
                scanning = after[end.upperBound...]
            }
            stripped += scanning

            let ink = dark ? "#E7DBC2" : "#2B2620"
            for rule in ["text:not([fill])", "text[fill=\"black\"]",
                         "[stroke=\"black\"]", "[fill=\"black\"]:not(text)"] {
                XCTAssertTrue(stripped.contains(".graphviz svg \(rule)"),
                              "`.graphviz svg \(rule)` must survive comment stripping (dark=\(dark))")
            }
            // The uncolored-label rule is the one an early comment close eats
            // first, and it is the one that matters: Graphviz writes no fill
            // attribute at all unless the author asked for a color.
            XCTAssertTrue(stripped.contains(".graphviz svg text:not([fill]) { fill: \(ink); }"),
                          "Default Graphviz labels must take the page ink (dark=\(dark))")
        }
    }

    func testHTMLMathFenceEmitsDisplayMath() {
        let html = MarkdownHTML.document("```math\n\\int_0^1 x\\,dx\n```", title: "t", dark: false)
        XCTAssertTrue(html.contains("class=\"md-mathd\""))
        XCTAssertTrue(html.contains("\\int_0^1"))
        XCTAssertTrue(html.contains("katex.min.js"))
    }

    func testHTMLInlineMathIsNotMangledByEmphasis() {
        // A `*` inside inline math must stay literal, not become <em>.
        let html = MarkdownHTML.document("total $a*b*c$ units", title: "t", dark: false)
        XCTAssertTrue(html.contains("class=\"md-mathi\""))
        XCTAssertTrue(html.contains("a*b*c"))
        XCTAssertFalse(html.contains("<em>"))
        XCTAssertTrue(html.contains("katex.min.js"))
    }

    func testHTMLDisplayMathSpanPreserved() {
        let html = MarkdownHTML.document("$$x^2 + y^2$$", title: "t", dark: false)
        XCTAssertTrue(html.contains("class=\"md-mathd\""))
        XCTAssertTrue(html.contains("x^2 + y^2"))
    }

    func testHTMLMhchemLoadsWithAndAfterKatex() {
        // mhchem is a KaTeX extension gated by the same `needsMath` signal, so
        // it must appear exactly when — and only when — KaTeX does, and it must
        // come *after* KaTeX in the document (KaTeX defines the global `katex`;
        // mhchem registers `\ce{}` onto it). The actual `\ce{}` render is proven
        // in a real WebView; here we only assert the include is present and
        // ordered. `\ce{}` lives inside math delimiters, so a plain formula is
        // enough to pull it in.
        let math = MarkdownHTML.document("Reaction $\\ce{H2O}$ here", title: "t", dark: false)
        XCTAssertTrue(math.contains("katex.min.js"))
        XCTAssertTrue(math.contains("mhchem.min.js"))
        guard let katexAt = math.range(of: "katex.min.js"),
              let mhchemAt = math.range(of: "mhchem.min.js") else {
            return XCTFail("both KaTeX and mhchem must be included for a math document")
        }
        XCTAssertTrue(katexAt.lowerBound < mhchemAt.lowerBound,
                      "mhchem must load after KaTeX so the global `katex` exists")
        // mhchem shares KaTeX's `defer`, or it would run before the deferred
        // KaTeX and find no global to extend.
        XCTAssertTrue(math.contains("<script defer src=\"rich/mhchem.min.js\"></script>"))
    }

    func testHTMLCodeLanguageEmitsHighlightClassAndLoadsEngine() {
        // A fenced block that names a real code language is tagged
        // `language-<lang>` — which md-init.js hands to highlight.js — and pulls
        // in highlight.min.js. The actual colouring is proven in
        // RichRenderTests' real WebView; here we assert the class and the
        // conditional include (and that the language is lower-cased, matching
        // hljs's own names).
        let html = MarkdownHTML.document("```Swift\nlet x = 1\n```", title: "t", dark: false)
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">"))
        XCTAssertTrue(html.contains("<script defer src=\"rich/highlight.min.js\"></script>"))
    }

    func testHTMLBareFenceAndSpecialFencesAreNotHighlighted() {
        // A fence with no language stays plain <pre><code> and pulls in nothing.
        let bare = MarkdownHTML.document("```\nplain text\n```", title: "t", dark: false)
        XCTAssertTrue(bare.contains("<pre><code>plain text"))
        XCTAssertFalse(bare.contains("language-"))
        XCTAssertFalse(bare.contains("highlight.min.js"))
        // The diagram / math / data languages have their own handling and must
        // never be tagged for highlight.js or pull the engine in.
        let mermaid = MarkdownHTML.document("```mermaid\ngraph TD\nA-->B\n```", title: "t", dark: false)
        XCTAssertFalse(mermaid.contains("highlight.min.js"))
        XCTAssertFalse(mermaid.contains("language-mermaid"))
        let dot = MarkdownHTML.document("```dot\ndigraph{a->b}\n```", title: "t", dark: false)
        XCTAssertFalse(dot.contains("highlight.min.js"))
        let mathFence = MarkdownHTML.document("```math\n\\int_0^1 x\\,dx\n```", title: "t", dark: false)
        XCTAssertFalse(mathFence.contains("highlight.min.js"))
        let csv = MarkdownHTML.document("```csv\na,b\n1,2\n```", title: "t", dark: false)
        XCTAssertFalse(csv.contains("highlight.min.js"))
    }

    func testHTMLPlainDocumentDoesNotLoadHighlightEngine() {
        // No code block at all → the ~124 KB engine is never included.
        let html = MarkdownHTML.document("# Title\n\nJust prose, `inline code` aside.", title: "t", dark: false)
        XCTAssertFalse(html.contains("highlight.min.js"))
        XCTAssertFalse(html.contains("language-"))
    }

    func testHTMLMhchemAbsentWithoutMath() {
        // No math → no KaTeX → no mhchem either, for every non-math document.
        let plain = MarkdownHTML.document("# Just text\n\nA paragraph.", title: "t", dark: false)
        XCTAssertFalse(plain.contains("mhchem.min.js"))
        let mermaid = MarkdownHTML.document("```mermaid\ngraph TD\nA-->B\n```", title: "t", dark: false)
        XCTAssertFalse(mermaid.contains("mhchem.min.js"))
        // A currency dollar sign is prose, not a formula — no engines at all.
        let currency = MarkdownHTML.document("it costs $5 and $10 today", title: "t", dark: false)
        XCTAssertFalse(currency.contains("mhchem.min.js"))
    }

    func testHTMLCurrencyDollarsAreNotMath() {
        // "$5 and $10" is prose, not a formula; leave the text intact.
        let html = MarkdownHTML.document("it costs $5 and $10 today", title: "t", dark: false)
        XCTAssertTrue(html.contains("$5 and $10"))
        XCTAssertFalse(html.contains("class=\"md-mathi\""))
        XCTAssertFalse(html.contains("katex.min.js"))
    }

    func testHTMLPlainDocumentStaysLight() {
        // No rich content → none of the heavy engines are included; md-init.js
        // (tiny, always present) still runs and flags render-complete.
        let html = MarkdownHTML.document("# Just text\n\nA paragraph.", title: "t", dark: false)
        XCTAssertFalse(html.contains("katex.min.js"))
        XCTAssertFalse(html.contains("mermaid.min.js"))
        XCTAssertFalse(html.contains("viz-global.js"))
        XCTAssertTrue(html.contains("rich/md-init.js"))
    }

    func testHTMLCodeSpanDollarIsNotMath() {
        // `$x$` inside a code span stays literal code, not a formula.
        let html = MarkdownHTML.document("use `$x$` here", title: "t", dark: false)
        XCTAssertTrue(html.contains("<code>$x$</code>"))
    }

    // MARK: Page breaks, notes & outline

    func testPageBreakParses() {
        let blocks = MarkdownParser.parse("before\n\n\\newpage\n\nafter")
        XCTAssertEqual(blocks.count, 3)
        guard case .pageBreak = blocks[1].kind else { return XCTFail("Expected a page break") }
    }

    func testPageBreakVariantInterruptsParagraph() {
        // `\pagebreak` works too, and a marker interrupts a paragraph run.
        let blocks = MarkdownParser.parse("line one\n\\pagebreak\nline two")
        XCTAssertEqual(blocks.count, 3)
        guard case .pageBreak = blocks[1].kind else { return XCTFail("Expected a page break") }
    }

    func testNoteCommentBecomesNoteBlock() {
        let blocks = MarkdownParser.parse("<!-- note: check the intro -->")
        XCTAssertEqual(blocks.count, 1)
        guard case let .note(text) = blocks[0].kind else { return XCTFail("Expected a note") }
        XCTAssertEqual(text, "check the intro")
    }

    func testPlainCommentIsDropped() {
        // A non-note HTML comment vanishes entirely — no block, no output.
        let blocks = MarkdownParser.parse("a\n\n<!-- just a comment -->\n\nb")
        XCTAssertEqual(blocks.count, 2)
    }

    func testMultilineNote() {
        let blocks = MarkdownParser.parse("<!-- note: first\nsecond -->")
        guard case let .note(text) = blocks.first?.kind else { return XCTFail("Expected a note") }
        XCTAssertTrue(text.contains("first"))
        XCTAssertTrue(text.contains("second"))
    }

    func testOutlineLevelsSlugsAndLines() {
        let source = "# One\n\ntext\n\n## Two\n\n```\n# not a heading\n```\n\nSetext\n---"
        let outline = MarkdownParser.outline(source)
        XCTAssertEqual(outline.count, 3)
        XCTAssertEqual(outline[0].level, 1)
        XCTAssertEqual(outline[0].slug, "one")
        XCTAssertEqual(outline[0].line, 0)
        XCTAssertEqual(outline[1].slug, "two")
        XCTAssertEqual(outline[2].level, 2)          // setext `---` underline
        XCTAssertEqual(outline[2].text, "Setext")
        XCTAssertEqual(outline[2].line, 10)
    }

    func testDuplicateHeadingSlugsAreDeduped() {
        let outline = MarkdownParser.outline("# Same\n\n# Same")
        XCTAssertEqual(outline.map(\.slug), ["same", "same-1"])
    }

    func testOutlineSkipsUnderlineAfterMultiLineParagraph() {
        // `---` after a 2+-line paragraph is a rule, not a setext heading —
        // parse() and outline() must agree, or the Contents menu would list
        // a phantom entry and desync every later anchor slug.
        XCTAssertTrue(MarkdownParser.outline("line1\nline2\n---").isEmpty)
        XCTAssertEqual(MarkdownParser.outline("only\n---").count, 1)
    }

    func testSlugDropsPunctuationLikeGitHub() {
        var used: [String: Int] = [:]
        XCTAssertEqual(MarkdownParser.slug(for: "C# & F#!", used: &used), "c--f")
    }

    func testNotesHelperFindsLine() {
        let notes = MarkdownParser.notes("start\n\n<!-- note: fix me -->\n\nend")
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].text, "fix me")
        XCTAssertEqual(notes[0].line, 2)
    }

    func testHTMLHeadingsCarryAnchorIds() {
        let html = MarkdownHTML.document("# My Title\n\n# My Title", title: "t", dark: false)
        XCTAssertTrue(html.contains("<h1 id=\"my-title\">"))
        XCTAssertTrue(html.contains("<h1 id=\"my-title-1\">"))
    }

    func testHTMLPageBreakMarkerAndExportCSS() {
        let preview = MarkdownHTML.document("a\n\n\\newpage\n\nb", title: "t", dark: false)
        XCTAssertTrue(preview.contains("md-pagebreak"))
        XCTAssertFalse(preview.contains("break-after: page"))
        let export = MarkdownHTML.document("a\n\n\\newpage\n\nb", title: "t", dark: false, export: true)
        XCTAssertTrue(export.contains("break-after: page"))
    }

    func testHTMLOmitsAuthorNotes() {
        let html = MarkdownHTML.document("visible\n\n<!-- note: secret draft thought -->",
                                         title: "t", dark: false)
        XCTAssertTrue(html.contains("visible"))
        XCTAssertFalse(html.contains("secret draft thought"))
    }

    // MARK: In-app rename

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdRename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    func testRenameMovesFileInPlaceKeepingExtension() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("Old Notes.md")
        try "content".write(to: old, atomically: true, encoding: .utf8)

        XCTAssertNil(DocumentExport.renameInPlace(fileURL: old, to: "New Notes"))
        let moved = dir.appendingPathComponent("New Notes.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        // Same folder, content preserved.
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "content")
    }

    @MainActor
    func testRenameDoesNotDoubleAnAlreadyTypedExtension() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("Doc.md")
        try "x".write(to: old, atomically: true, encoding: .utf8)

        XCTAssertNil(DocumentExport.renameInPlace(fileURL: old, to: "Final.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Final.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Final.md.md").path))
    }

    @MainActor
    func testRenameRejectsCollisionAndInvalidNames() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("A.md")
        try "a".write(to: a, atomically: true, encoding: .utf8)
        try "b".write(to: dir.appendingPathComponent("Taken.md"), atomically: true, encoding: .utf8)

        XCTAssertNotNil(DocumentExport.renameInPlace(fileURL: a, to: "Taken"))  // collision
        XCTAssertNotNil(DocumentExport.renameInPlace(fileURL: a, to: "   "))    // empty
        XCTAssertNotNil(DocumentExport.renameInPlace(fileURL: a, to: "a/b"))    // path separator
        // The original is untouched after every rejected rename.
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
    }

    // MARK: Book naming (the navigator's rename / reorder plans)

    @MainActor
    func testBookReorderPlanRenumbersSiblings() {
        // Move "03-End" up one place; the whole group renumbers to match
        // the new display order, and the untouched first item is skipped.
        let plan = BookNaming.renamePlan(
            siblings: ["01-Intro.md", "02-Middle.md", "03-End.md"], moveFrom: 2, to: 1)
        XCTAssertEqual(plan.map { $0.from }, ["03-End.md", "02-Middle.md"])
        XCTAssertEqual(plan.map { $0.to }, ["02-End.md", "03-Middle.md"])
    }

    @MainActor
    func testBookReorderPlanAssignsPrefixToUnprefixed() {
        // Unprefixed siblings gain a "NN-" prefix when the group
        // materializes; chapters (no article extension) renumber alike.
        let plan = BookNaming.renamePlan(
            siblings: ["01-First", "Drafts", "Extras"], moveFrom: 2, to: 1)
        XCTAssertEqual(plan.map { $0.from }, ["Extras", "Drafts"])
        XCTAssertEqual(plan.map { $0.to }, ["02-Extras", "03-Drafts"])
    }

    @MainActor
    func testBookReorderPlanSwapsIdenticalDisplayNames() {
        // Swapping two siblings whose display names match is an exchange
        // cycle — the plan simply states both renames; the navigator's
        // two-phase apply is what makes it collision-safe on disk.
        let plan = BookNaming.renamePlan(
            siblings: ["01-Draft.md", "02-Draft.md"], moveFrom: 0, to: 1)
        XCTAssertEqual(plan.map { $0.from }, ["02-Draft.md", "01-Draft.md"])
        XCTAssertEqual(plan.map { $0.to }, ["01-Draft.md", "02-Draft.md"])
    }

    @MainActor
    func testBookReorderPlanNoOpAndBoundsAreEmpty() {
        // Already numbered and not actually moving → nothing to rename.
        XCTAssertTrue(BookNaming.renamePlan(
            siblings: ["01-A.md", "02-B.md"], moveFrom: 1, to: 1).isEmpty)
        // Out-of-range destinations (first item up / last item down).
        XCTAssertTrue(BookNaming.renamePlan(
            siblings: ["01-A.md", "02-B.md"], moveFrom: 0, to: -1).isEmpty)
        XCTAssertTrue(BookNaming.renamePlan(
            siblings: ["01-A.md", "02-B.md"], moveFrom: 1, to: 2).isEmpty)
    }

    @MainActor
    func testBookRenameKeepsPrefixAndExtension() {
        XCTAssertEqual(BookNaming.renamed("01-The Editor.md", toDisplay: "Editing"),
                       "01-Editing.md")
        // The author's own separator punctuation survives a rename.
        XCTAssertEqual(BookNaming.renamed("2. setup.txt", toDisplay: "Setup"),
                       "2. Setup.txt")
        // No prefix, no article extension (a chapter): the whole name is
        // the display name.
        XCTAssertEqual(BookNaming.renamed("Old Chapter", toDisplay: "New Chapter"),
                       "New Chapter")
        // Display names round-trip: what the rename prompt pre-fills is
        // exactly what the prefix/extension get re-attached to.
        XCTAssertEqual(BookNaming.displayName("01-The Editor.md"), "The Editor")
        XCTAssertEqual(BookNaming.displayName("Preface.markdown"), "Preface")
        // An all-numeric name is its own title, not a prefix.
        XCTAssertEqual(BookNaming.displayName("01.md"), "01")
    }

    // MARK: Book compilation (share / export the whole book as one PDF)

    @MainActor
    func testBookCompileOrdersRootArticlesThenChapters() {
        let source = BookLibrary.compile(
            bookName: "My Book",
            parts: [
                BookLibrary.Part(articles: ["Root one.", "Root two."]),
                BookLibrary.Part(title: "Getting Started", articles: ["The editor."]),
                BookLibrary.Part(title: "Going Further", articles: ["Rich content.", "Books."]),
            ])
        // Split at the exact joint the compiler emits: every unit — the
        // title page, each chapter heading, every single article — is its
        // own page, in reading order, with article content untouched.
        XCTAssertEqual(source.components(separatedBy: "\n\n\\newpage\n\n"), [
            "# My Book",
            "Root one.",
            "Root two.",
            "# Getting Started",
            "The editor.",
            "# Going Further",
            "Rich content.",
            "Books.",
        ])
    }

    @MainActor
    func testBookCompileEdgeShapes() {
        // An empty book is just its title page — no trailing page break.
        XCTAssertEqual(BookLibrary.compile(bookName: "Empty", parts: []), "# Empty")
        // No root articles → the book opens straight into chapter one; an
        // article-less chapter still contributes its heading page.
        XCTAssertEqual(
            BookLibrary.compile(bookName: "B", parts: [
                BookLibrary.Part(articles: []),
                BookLibrary.Part(title: "One", articles: []),
            ]),
            "# B\n\n\\newpage\n\n# One")
    }

    @MainActor
    func testBookCompileJointsParseAsPageBreaks() {
        // The joints must be the marker the parser (and thus the export
        // CSS's `break-after: page`) actually honors — and the units must
        // still parse as their own blocks around them.
        let source = BookLibrary.compile(
            bookName: "B",
            parts: [BookLibrary.Part(title: "One", articles: ["Hello.", "World."])])
        let kinds = parse(source)
        XCTAssertEqual(kinds.count, 7)   // 4 units + 3 breaks
        let breaks = kinds.filter { if case .pageBreak = $0 { return true } else { return false } }
        XCTAssertEqual(breaks.count, 3)
        guard case let .heading(level, text)? = kinds.first else {
            return XCTFail("expected the title page heading first")
        }
        XCTAssertEqual(level, 1)
        XCTAssertEqual(text, "B")
    }

    // MARK: Export theming (print / PDF pages)

    func testExportPageIsPlainWhiteAndAlwaysLight() {
        // Print / PDF pages keep their own single color: no paper tint
        // (which would end mid-page next to the white A4 margins), and the
        // light palette even from a dark window — dark cream-on-carbon is
        // a screen theme, unreadable as cream-on-white.
        let export = MarkdownHTML.document("hello", title: "t", dark: true, export: true)
        XCTAssertTrue(export.contains("background: #FFFFFF"), "The page background is plain white")
        XCTAssertTrue(export.contains("color-scheme: light"), "Export always renders light")
        XCTAssertFalse(export.contains("#241E18"), "No dark-paper color anywhere in an export")
        XCTAssertTrue(export.contains("data-md-dark=\"0\""),
                      "The rich renderers (Mermaid theme) see the light mode too")
        // The on-screen preview still honors the app's appearance.
        let preview = MarkdownHTML.document("hello", title: "t", dark: true)
        XCTAssertTrue(preview.contains("background: #241E18"), "Dark preview keeps the carbon paper")
        XCTAssertTrue(preview.contains("data-md-dark=\"1\""))
    }

    func testRawPlantUMLDocumentRendersAsDiagram() {
        // An opened `.puml` is bare diagram source with no ```plantuml fence.
        // It must render as one PlantUML diagram — a `.plantuml` container that
        // md-init.js turns into an SVG — not as Markdown text, which would show
        // the `@startuml…` source as paragraphs and never draw anything.
        let puml = "@startuml\nAlice -> Bob: hi\nBob --> Alice: hi\n@enduml\n"
        let html = MarkdownHTML.document(puml, title: "d", dark: false)
        XCTAssertTrue(html.contains("<div class=\"plantuml\">"),
                      "Raw PlantUML renders through the .plantuml container")
        XCTAssertTrue(html.contains("rich/viz-global.js"),
                      "The PlantUML engine's Viz dependency is pulled in")
        XCTAssertFalse(html.contains("<p>@startuml"),
                       "The source must not be parsed as Markdown paragraphs")

        // Detection skips PlantUML line comments and blank lines before the
        // opener, and recognizes any @start… diagram, not only @startuml.
        XCTAssertTrue(MarkdownHTML.isRawPlantUML("' header comment\n\n@startmindmap\n* root\n@endmindmap"))
        XCTAssertTrue(MarkdownHTML.isRawPlantUML("   \n@startuml\n@enduml"))

        // A normal Markdown document is untouched: not a whole-document diagram,
        // and `@startuml` mentioned mid-prose is not a false positive.
        XCTAssertFalse(MarkdownHTML.isRawPlantUML("# Title\n\nSome prose about @startuml in passing."))
        let md = MarkdownHTML.document("# Title\n\nHello.", title: "d", dark: false)
        XCTAssertFalse(md.contains("<div class=\"plantuml\">"))
        XCTAssertTrue(md.contains("<h1"))
    }

    func testRawGraphvizDocumentRendersAsDiagram() {
        // An opened `.gv` is bare DOT source with no ```dot fence — the
        // Graphviz counterpart of a raw `.puml`. It must render as one diagram,
        // not as Markdown text.
        let dot = "digraph G {\n  a -> b;\n}\n"
        let html = MarkdownHTML.document(dot, title: "d", dark: false)
        XCTAssertTrue(html.contains("<div class=\"graphviz\" data-engine=\"dot\">"),
                      "Raw DOT renders through the .graphviz container")
        XCTAssertTrue(html.contains("rich/viz-global.js"))
        XCTAssertFalse(html.contains("<p>digraph"),
                       "The source must not be parsed as Markdown paragraphs")

        // Every shape of opener, and DOT's case-insensitive keywords.
        XCTAssertTrue(MarkdownHTML.isRawGraphviz("digraph { a -> b }"))
        XCTAssertTrue(MarkdownHTML.isRawGraphviz("graph {}"))
        XCTAssertTrue(MarkdownHTML.isRawGraphviz("strict digraph G {\n}"))
        XCTAssertTrue(MarkdownHTML.isRawGraphviz("DiGraph Foo {\n}"))
        XCTAssertTrue(MarkdownHTML.isRawGraphviz("digraph{a}"))
        // The brace may open on a later line.
        XCTAssertTrue(MarkdownHTML.isRawGraphviz("digraph\n{\n  a\n}"))
        // Comments and blank lines before the opener are skipped.
        XCTAssertTrue(MarkdownHTML.isRawGraphviz("// generated\n\n/* by hand */\ndigraph { a }"))
        // …but a `#` line is not, precisely so a Markdown heading can't be
        // mistaken for a DOT comment and let the check read past the title.
        XCTAssertFalse(MarkdownHTML.isRawGraphviz("# Notes\n\ngraph { the mental model }"))

        // A quoted graph name, which DOT allows.
        XCTAssertTrue(MarkdownHTML.isRawGraphviz("digraph \"my graph\" {\n}"))

        // Unicode graph names, pinned on both platforms because the two
        // languages disagree by default: a Swift Character is a grapheme
        // cluster, so an NFD-decomposed accent is one letter here, while a
        // Kotlin Char is a UTF-16 unit and the combining mark would end the
        // name early. The Android port accepts the mark categories explicitly
        // so the same file is a diagram on every platform.
        XCTAssertTrue(MarkdownHTML.isRawGraphviz("digraph cafe\u{0301} {\n}"))  // NFD
        XCTAssertTrue(MarkdownHTML.isRawGraphviz("digraph caf\u{00E9} {\n}"))   // NFC
        XCTAssertTrue(MarkdownHTML.isRawGraphviz("digraph \u{2169} {\n}"))      // Nl numeral
        // NEL is a line break to Foundation's newline set; Android lists it
        // explicitly so this file is several lines on both sides.
        XCTAssertTrue(MarkdownHTML.isRawGraphviz("// generated\u{0085}digraph G {\u{0085}}"))

        // Not DOT: prose that merely opens with the word, a word that only
        // starts with a keyword, and anything with no brace at all. DOT's
        // header allows one optional name and then a brace — prose has more
        // words than that, which is what keeps an essay opening "graph theory
        // is…" from being swallowed just because a `{` appears further down.
        XCTAssertFalse(MarkdownHTML.isRawGraphviz("graph theory is a branch of maths.\n\nSee $\\frac{a}{b}$."))
        XCTAssertFalse(MarkdownHTML.isRawGraphviz("digraph models are useful { in theory }"))
        XCTAssertFalse(MarkdownHTML.isRawGraphviz("graphviz is a fine tool { see }"))
        XCTAssertFalse(MarkdownHTML.isRawGraphviz("digraphs are a topic { here }"))
        XCTAssertFalse(MarkdownHTML.isRawGraphviz("digraph without a brace"))
        XCTAssertFalse(MarkdownHTML.isRawGraphviz("# Title\n\nSome prose about digraph { } in passing."))
        XCTAssertFalse(MarkdownHTML.isRawGraphviz(""))

        // Windows line endings. A Swift Character is a grapheme cluster and
        // CRLF is one of them, so a naive split on "\n" hands back the whole
        // file as a single line and any leading blank line or comment hides
        // the opener. Both raw-diagram checks must survive a file saved on
        // Windows — this covers the `.puml` path too, which had the same flaw.
        XCTAssertTrue(MarkdownHTML.isRawGraphviz("\r\ndigraph G {\r\n  a -> b;\r\n}\r\n"))
        XCTAssertTrue(MarkdownHTML.isRawGraphviz("// generated\r\ndigraph G {\r\n}\r\n"))
        XCTAssertTrue(MarkdownHTML.isRawPlantUML("\r\n@startuml\r\nA -> B\r\n@enduml\r\n"))
        XCTAssertTrue(MarkdownHTML.isRawPlantUML("' note\r\n\r\n@startmindmap\r\n* r\r\n@endmindmap"))

        // A diagram nested in a block quote still pulls its engine in: the
        // renderer recurses into quoted blocks, so keying the script includes
        // off the emitted markup (not a scan of the top-level blocks) is what
        // keeps the container and the engine from getting separated.
        let quoted = MarkdownHTML.document("> ```dot\n> digraph { a }\n> ```", title: "d", dark: false)
        XCTAssertTrue(quoted.contains("class=\"graphviz\""))
        XCTAssertTrue(quoted.contains("rich/viz-global.js"),
                      "A quoted diagram must still load the engine that draws it")

        // A Markdown document that merely *contains* a dot fence is still
        // Markdown — the whole-file diagram path must not swallow it.
        let mixed = MarkdownHTML.document("# Title\n\n```dot\ndigraph { a }\n```\n", title: "d", dark: false)
        XCTAssertTrue(mixed.contains("<h1"))
        XCTAssertTrue(mixed.contains("class=\"graphviz\""))
    }

    // MARK: CSV / TSV blocks

    func testCSVFenceRendersAsATable() {
        let html = MarkdownHTML.document("```csv\nName,Role\nAnn,Editor\n```", title: "t", dark: false)
        XCTAssertTrue(html.contains("<th style=\"text-align:left\">Name</th>"))
        XCTAssertTrue(html.contains("<td style=\"text-align:left\">Ann</td>"))
        XCTAssertFalse(html.contains("<pre><code>Name,Role"))
    }

    func testDelimitedParsingFollowsRFC4180() {
        let rows = MarkdownHTML.parseDelimited(
            "Name,Note\n\"Doe, Jane\",\"She said \"\"hi\"\"\"\nAnn,\n", separator: ",")
        XCTAssertEqual(rows, [
            ["Name", "Note"],
            ["Doe, Jane", "She said \"hi\""],  // quoted separator, doubled quote
            ["Ann", ""],                            // an empty trailing field
        ])

        // A quoted field may hold a line break…
        XCTAssertEqual(MarkdownHTML.parseDelimited("a,\"one\ntwo\"\n", separator: ","),
                       [["a", "one\ntwo"]])
        // …and a quote that is not at the start of a field is just a character.
        XCTAssertEqual(MarkdownHTML.parseDelimited("5\" pipe,x", separator: ","),
                       [["5\" pipe", "x"]])
        // A last row with no trailing newline is still a row.
        XCTAssertEqual(MarkdownHTML.parseDelimited("a,b", separator: ","), [["a", "b"]])
        XCTAssertEqual(MarkdownHTML.parseDelimited("", separator: ","), [])
    }

    func testDelimitedParsingHandlesWindowsLineEndings() {
        // A Swift Character is a grapheme cluster and CRLF is one of them, so
        // a naive comparison against "\n" never fires — and a spreadsheet
        // export is exactly where CRLF comes from.
        XCTAssertEqual(MarkdownHTML.parseDelimited("a,b\r\nc,d\r\n", separator: ","),
                       [["a", "b"], ["c", "d"]])
        XCTAssertEqual(MarkdownHTML.parseDelimited("a,b\rc,d", separator: ","),
                       [["a", "b"], ["c", "d"]])
    }

    func testCSVNumericColumnsAreRightAligned() {
        // Decimal points lining up is most of what makes figures readable.
        let html = MarkdownHTML.document("```csv\nCity,People\nOslo,709037\nBergen,289330\n```",
                                         title: "t", dark: false)
        XCTAssertTrue(html.contains("<th style=\"text-align:left\">City</th>"))
        XCTAssertTrue(html.contains("<th style=\"text-align:right\">People</th>"))
        // A column with any non-numeric value stays left-aligned.
        let mixed = MarkdownHTML.document("```csv\nA\n1\nn/a\n```", title: "t", dark: false)
        XCTAssertTrue(mixed.contains("<th style=\"text-align:left\">A</th>"))
    }

    func testDecimalNumberGrammarIsExplicitNotDoubleInit() {
        // What counts as a number decides column alignment, and it must mean
        // the same thing on every platform. `Double(_:)` does not: Swift takes
        // hex and any casing of inf/nan, Java's parseDouble takes neither, so
        // the same spreadsheet aligned differently on Android.
        for number in ["0", "-1", "+2", "3.5", ".5", "5.", "1e9", "-2.5E-3", "007"] {
            XCTAssertTrue(MarkdownHTML.isDecimalNumber(number), "\(number) is a figure")
        }
        for other in ["0x10", "inf", "Inf", "INF", "nan", "NaN", "1,000", "1 000",
                      "", "-", ".", "e5", "1e", "1e+", "12abc", "1.2.3", "٣", "½"] {
            XCTAssertFalse(MarkdownHTML.isDecimalNumber(other), "\(other) is not a figure")
        }

        // A hex column therefore stays left-aligned — the same on both sides.
        let hex = MarkdownHTML.document("```csv\nItem,Value\na,0x10\n```", title: "t", dark: false)
        XCTAssertTrue(hex.contains("<th style=\"text-align:left\">Value</th>"))

        // And an invisible U+200B is not padding: Foundation's `.whitespaces`
        // strips it and Java's Zs-based trim does not, so the alignment scan
        // trims ASCII only and both platforms agree the cell is not a number.
        let zwsp = MarkdownHTML.document("```csv\nItem,Value\na,\u{200B}1\u{200B}\n```",
                                         title: "t", dark: false)
        XCTAssertTrue(zwsp.contains("<th style=\"text-align:left\">Value</th>"))
    }

    func testTSVFenceUsesTabs() {
        let html = MarkdownHTML.document("```tsv\nCity\tPeople\nOslo\t709037\n```",
                                         title: "t", dark: false)
        XCTAssertTrue(html.contains("<th style=\"text-align:left\">City</th>"))
        XCTAssertTrue(html.contains("<td style=\"text-align:right\">709037</td>"))
    }

    func testEmptyCSVFenceStaysACodeBlock() {
        // Nothing the author wrote may disappear because it failed to parse.
        let html = MarkdownHTML.document("```csv\n\n```", title: "t", dark: false)
        XCTAssertFalse(html.contains("<table>"))
    }

    // MARK: EPUB identifier

    func testEpubIdentifierIsStableForTheSameBook() {
        // A fresh random UUID per export made every export a *different*
        // publication: re-exporting after fixing a typo stacked up beside the
        // old file in a reader's library instead of replacing it, and a store
        // that expects a stable identifier across releases could not take it.
        let first = EpubBuilder.stableIdentifier(forTitle: "My Book")
        let second = EpubBuilder.stableIdentifier(forTitle: "My Book")
        XCTAssertEqual(first, second, "the same book must export the same identifier")

        // A different book is a different publication.
        XCTAssertNotEqual(first, EpubBuilder.stableIdentifier(forTitle: "Other Book"))

        // A well-formed RFC 4122 version 5 URN: `urn:uuid:` then 8-4-4-4-12
        // hex, with the version nibble 5 and the variant bits `10`.
        XCTAssertTrue(first.hasPrefix("urn:uuid:"))
        let uuid = String(first.dropFirst("urn:uuid:".count))
        let groups = uuid.split(separator: "-")
        XCTAssertEqual(groups.map(\.count), [8, 4, 4, 4, 12])
        XCTAssertTrue(uuid.allSatisfy { $0.isHexDigit || $0 == "-" })
        XCTAssertEqual(groups[2].first, "5", "version 5 — name-based, not random")
        XCTAssertTrue("89ab".contains(groups[3].first!), "RFC 4122 variant")

        // And it is the value that actually reaches the package document.
        let opf = EpubBuilder.contentOPF(title: "My Book", identifier: first,
                                         modified: "2026-07-24T00:00:00Z",
                                         units: [], images: [])
        XCTAssertTrue(opf.contains("<dc:identifier id=\"book-id\">\(first)</dc:identifier>"))
    }

    // MARK: HTML export

    @MainActor
    func testEmbeddedKatexCSSInlinesEveryFaceAsWoff2() {
        guard let css = DocumentExport.embeddedKatexCSS() else {
            return XCTFail("the bundle should carry rich/katex.min.css")
        }
        // Every face must end up as a data: URI. A relative `fonts/…` path
        // left behind is a dead link in a file that has no folder beside it.
        XCTAssertFalse(css.contains("url(fonts/"), "no relative font path may survive")
        XCTAssertTrue(css.contains("url(data:font/woff2;base64,"))

        // Only woff2 — carrying the woff and ttf alternates as well would
        // quadruple the payload for formats nothing in use needs.
        XCTAssertFalse(css.contains("format(\"woff\")"))
        XCTAssertFalse(css.contains("format(\"truetype\")"))

        // One embedded source per face, and the stylesheet's own rules are
        // still there — a formula is positioned by this CSS, not just glyphed.
        let faces = css.components(separatedBy: "@font-face").count - 1
        let embedded = css.components(separatedBy: "url(data:font/woff2;base64,").count - 1
        XCTAssertEqual(faces, embedded, "every @font-face carries exactly one embedded source")
        XCTAssertTrue(css.contains(".katex"))
    }

    func testHTMLExportKeepsPageBreaksVisible() {
        // The export stylesheet turns `\newpage` into `break-after: page`,
        // which means nothing on a screen — a reader scrolling the exported
        // file would find the author's page breaks silently gone. The HTML
        // export swaps that rule back for the dashed rule the preview shows.
        let exportCSS = MarkdownHTML.document("a\n\n\\newpage\n\nb", title: "t", dark: false, export: true)
        XCTAssertTrue(exportCSS.contains("break-after: page"),
                      "the PDF path still wants a real page break")
        XCTAssertTrue(exportCSS.contains("<div class=\"md-pagebreak\"></div>"))
    }

    // MARK: Plain-text decode (legacy encodings)

    func testDecodeReadsUTF8() {
        let decoded = MarkdownDocument.decode(Data("# Привет\n".utf8))
        XCTAssertEqual(decoded?.0, "# Привет\n")
        XCTAssertEqual(decoded?.1, .utf8)
    }

    func testDecodeDoesNotMistakeBOMlessCP1251ForUTF16() {
        // Cyrillic prose in Windows-1251 — even-length and BOM-less, the
        // shape a naive UTF-16 trial happily (and wrongly) accepts as CJK
        // mojibake. It must decode as CP1251 and round-trip byte-exactly.
        let original = "Привет, мир!"
        let data = original.data(using: .windowsCP1251)!
        let decoded = MarkdownDocument.decode(data)
        XCTAssertEqual(decoded?.0, original)
        XCTAssertEqual(decoded?.1, .windowsCP1251)
        XCTAssertEqual(decoded!.0.data(using: decoded!.1), data)
    }

    func testDecodeRoundTripsBOMedUTF16() {
        let original = "# Chapter\n"
        let data = original.data(using: .utf16)! // data(using:) writes a BOM
        let decoded = MarkdownDocument.decode(data)
        XCTAssertEqual(decoded?.0, original)
        XCTAssertEqual(decoded?.1, .utf16)
    }

    // MARK: Writing stats (the document footer)

    func testWordCountIsLocaleAwareNotAWhitespaceSplit() {
        XCTAssertEqual(WritingStats.words(in: ""), 0)
        XCTAssertEqual(WritingStats.words(in: "   \n\n"), 0)
        XCTAssertEqual(WritingStats.words(in: "Hello, world!"), 2)
        // An apostrophe joins a word; a dash alone is none.
        XCTAssertEqual(WritingStats.words(in: "it's — done"), 2)
        XCTAssertEqual(WritingStats.words(in: "One\ntwo\n\nthree"), 3)
    }

    // MARK: EPUB export (zip / XHTML / package — the pure pieces)

    @MainActor
    func testStoredZipShapeAndCRC() {
        // The standard CRC-32 check value.
        XCTAssertEqual(StoredZip.crc32(Data("123456789".utf8)), 0xCBF4_3926)

        let archive = StoredZip.archive([
            (name: "mimetype", data: Data("application/epub+zip".utf8)),
            (name: "META-INF/container.xml", data: Data("<container/>".utf8)),
        ])
        // Local-file-header magic first…
        XCTAssertEqual(Array(archive.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        // …stored method (bytes 8–9)…
        XCTAssertEqual(archive[8], 0)
        XCTAssertEqual(archive[9], 0)
        // …and the mimetype name + payload directly after the fixed 30-byte
        // header — the sniffable EPUB magic readers check without unzipping.
        XCTAssertEqual(String(data: archive.subdata(in: 30..<38), encoding: .utf8),
                       "mimetype")
        XCTAssertEqual(String(data: archive.subdata(in: 38..<58), encoding: .utf8),
                       "application/epub+zip")
        // End-of-central-directory record: magic and total entry count.
        let eocd = archive.count - 22
        XCTAssertEqual(Array(archive.subdata(in: eocd..<(eocd + 4))),
                       [0x50, 0x4B, 0x05, 0x06])
        XCTAssertEqual(archive[eocd + 10], 2)
        XCTAssertEqual(archive[eocd + 11], 0)
    }

    @MainActor
    func testEpubXHTMLFixerClosesVoidsAndStripsScripts() {
        let html = """
        <p>a<br>
        b</p>
        <hr>
        <img src="x.png" alt="pic">
        <table><thead><tr><th style="text-align:left">h</th></tr></thead>\
        <tbody><tr><td style="text-align:left">c</td></tr></tbody></table>
        <div class="md-list"><div class="md-item">\
        <span class="md-marker">&bull;</span><span>item</span></div></div>
        <script type="module" src="rich/md-init.js"></script>
        """
        let fixed = EpubBuilder.xhtml(html)
        // Void elements self-closed for XML.
        XCTAssertTrue(fixed.contains("<br/>"))
        XCTAssertTrue(fixed.contains("<hr/>"))
        XCTAssertTrue(fixed.contains("<img src=\"x.png\" alt=\"pic\"/>"))
        // No scripts or engine references survive.
        XCTAssertFalse(fixed.contains("<script"))
        XCTAssertFalse(fixed.contains("md-init"))
        // XML-undefined named entities become numeric references.
        XCTAssertFalse(fixed.contains("&bull;"))
        XCTAssertTrue(fixed.contains("&#8226;"))
        // Already well-formed content passes through untouched.
        XCTAssertTrue(fixed.contains("<td style=\"text-align:left\">c</td>"))
    }

    @MainActor
    func testEpubPackageAndNavForSmallTree() {
        let opf = EpubBuilder.contentOPF(
            title: "My Book", identifier: "urn:uuid:TEST",
            modified: "2026-07-10T00:00:00Z",
            units: [(id: "u001", href: "u001.xhtml"), (id: "u002", href: "u002.xhtml")],
            images: ["images/u002-01.png"])
        XCTAssertTrue(opf.contains("<dc:title>My Book</dc:title>"))
        XCTAssertTrue(opf.contains("<dc:language>en</dc:language>"))
        XCTAssertTrue(opf.contains("<dc:identifier id=\"book-id\">urn:uuid:TEST</dc:identifier>"))
        XCTAssertTrue(opf.contains("property=\"dcterms:modified\">2026-07-10T00:00:00Z<"))
        XCTAssertTrue(opf.contains("properties=\"nav\""))
        XCTAssertTrue(opf.contains("href=\"images/u002-01.png\" media-type=\"image/png\""))
        // Spine order is reading order.
        let first = opf.range(of: "<itemref idref=\"u001\"/>")
        let second = opf.range(of: "<itemref idref=\"u002\"/>")
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertLessThan(first!.lowerBound, second!.lowerBound)

        let nav = EpubBuilder.navXHTML(
            bookTitle: "My Book",
            rootArticles: [(title: "Intro", href: "u002.xhtml")],
            chapters: [(title: "One", href: "u003.xhtml",
                        articles: [(title: "First", href: "u004.xhtml")])])
        XCTAssertTrue(nav.contains("epub:type=\"toc\""))
        XCTAssertTrue(nav.contains("xmlns:epub=\"http://www.idpf.org/2007/ops\""))
        // Root article before the chapter, the chapter's articles nested
        // in an inner list (one outer <ol> + one nested).
        let root = nav.range(of: "<a href=\"u002.xhtml\">Intro</a>")
        let chapter = nav.range(of: "<a href=\"u003.xhtml\">One</a>")
        let article = nav.range(of: "<a href=\"u004.xhtml\">First</a>")
        XCTAssertNotNil(root)
        XCTAssertNotNil(chapter)
        XCTAssertNotNil(article)
        XCTAssertLessThan(root!.lowerBound, chapter!.lowerBound)
        XCTAssertLessThan(chapter!.lowerBound, article!.lowerBound)
        XCTAssertEqual(nav.components(separatedBy: "<ol>").count - 1, 2)
    }

    @MainActor
    func testEpubRichElementRangesFindContainersInOrder() {
        // The scanner must see the containers exactly as MarkdownHTML
        // emits them, in document order — the DOM query pairs with it
        // index-for-index when snapshots replace them.
        let source = "Inline $a^2$ math.\n\n```mermaid\ngraph TD; A-->B\n```\n\n```math\nE=mc^2\n```"
        let html = MarkdownHTML.document(source, title: "t", dark: false, export: true)
        let body = EpubBuilder.bodyContent(ofDocument: html)
        let ranges = EpubBuilder.richElementRanges(in: body)
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges[0].kind, .formula)   // $a^2$
        XCTAssertEqual(ranges[1].kind, .diagram)   // mermaid
        XCTAssertEqual(ranges[2].kind, .formula)   // math fence
        // Ranges are ordered and non-overlapping.
        XCTAssertLessThan(ranges[0].range.upperBound, ranges[1].range.lowerBound)
        XCTAssertLessThan(ranges[1].range.upperBound, ranges[2].range.lowerBound)
    }

    @MainActor
    func testEpubRichElementRangesCoverGraphvizWhateverItsEngine() {
        // A ```dot block in a book article must be snapshotted like any
        // other diagram — otherwise the EPUB ships its DOT source as text.
        // The container names its layout program in the tag
        // (`<div class="graphviz" data-engine="neato">`), so the scanner has
        // to match the containers of every engine, not just the default one.
        let source = "```dot\ndigraph { a -> b }\n```\n\n```neato\ngraph { a -- b }\n```"
        let html = MarkdownHTML.document(source, title: "t", dark: false, export: true)
        let body = EpubBuilder.bodyContent(ofDocument: html)
        XCTAssertTrue(body.contains("data-engine=\"neato\""), "fixture exercises a non-default engine")

        let ranges = EpubBuilder.richElementRanges(in: body)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].kind, .diagram)
        XCTAssertEqual(ranges[1].kind, .diagram)
        // Each range must span the whole element — from `<div` through the
        // matching `</div>` — so replacing it leaves no orphaned markup.
        for range in ranges {
            let element = String(body[range.range])
            XCTAssertTrue(element.hasPrefix("<div class=\"graphviz\""))
            XCTAssertTrue(element.hasSuffix("</div>"))
        }
        XCTAssertTrue(body[ranges[0].range].contains("data-engine=\"dot\""))
        XCTAssertTrue(body[ranges[1].range].contains("data-engine=\"neato\""))
        XCTAssertLessThan(ranges[0].range.upperBound, ranges[1].range.lowerBound)
    }

    // MARK: EPUB export — single document (Feature 1)
    //
    // A lone document exports as EPUB too ("Export as EPUB…" in the document
    // share menu). It reuses the book pipeline but is *not* a book: no title
    // page, and its nav is the document's own headings. The packing is pure,
    // so it is covered here directly rather than only through the async export.

    /// The single-document EPUB entries for `source`, assembled exactly as the
    /// async export does for a document with no rich blocks: the body is
    /// `renderArticleBody`'s output — `xhtml(bodyContent(of: the export HTML))`
    /// — and the outline is read from the same source, so the nav slugs and
    /// the content ids are produced by the real code paths, not fixtures. No
    /// WebKit is touched (only a rich block would reach the offscreen view).
    @MainActor
    private func documentEpubEntries(for source: String, title: String)
        -> [(name: String, data: Data)] {
        let html = MarkdownHTML.document(source, title: title, dark: false, export: true)
        let body = EpubBuilder.xhtml(EpubBuilder.bodyContent(ofDocument: html))
        return DocumentExport.documentEpubEntries(
            title: title, body: body, images: [],
            outline: MarkdownParser.outline(source),
            modified: "2026-07-24T00:00:00Z")
    }

    /// The bytes of the entry named `name`, or nil if it isn't there.
    private func entry(_ name: String, in entries: [(name: String, data: Data)]) -> Data? {
        entries.first { $0.name == name }?.data
    }

    func testDocumentEpubTitlePrefersFrontMatterThenFileName() {
        // The front-matter `title:` wins when present…
        XCTAssertEqual(
            EpubBuilder.documentTitle(
                frontMatter: MarkdownParser.frontMatter(of: "---\ntitle: My Essay\n---\n\n# H"),
                fileName: "notes"),
            "My Essay")
        // …the key is matched case-insensitively, and the first non-empty wins…
        XCTAssertEqual(
            EpubBuilder.documentTitle(
                frontMatter: [MetadataField(key: "Title", value: "  Spaced  ")],
                fileName: "notes"),
            "Spaced")
        // …an empty value falls through to the file name…
        XCTAssertEqual(
            EpubBuilder.documentTitle(frontMatter: [MetadataField(key: "title", value: "  ")],
                                      fileName: "notes"),
            "notes")
        // …and with no front matter at all the file name is the title.
        XCTAssertEqual(
            EpubBuilder.documentTitle(frontMatter: MarkdownParser.frontMatter(of: "# Just a heading"),
                                      fileName: "My File"),
            "My File")
    }

    @MainActor
    func testDocumentEpubIsAValidStoredZipWithMimetypeFirst() {
        let entries = documentEpubEntries(for: "# Alpha\n\nText.", title: "Alpha")
        // The pure entries list already puts `mimetype` first…
        XCTAssertEqual(entries.first?.name, "mimetype")
        XCTAssertEqual(entries.first.map { String(decoding: $0.data, as: UTF8.self) },
                       "application/epub+zip")

        // …and once archived it is a valid stored zip whose sniffable magic —
        // the `mimetype` name and payload right after the fixed 30-byte local
        // header — is exactly what a reader checks before unzipping.
        let archive = StoredZip.archive(entries)
        XCTAssertEqual(Array(archive.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertEqual(archive[8], 0)   // stored method, not deflated
        XCTAssertEqual(archive[9], 0)
        XCTAssertEqual(String(data: archive.subdata(in: 30..<38), encoding: .utf8), "mimetype")
        XCTAssertEqual(String(data: archive.subdata(in: 38..<58), encoding: .utf8),
                       "application/epub+zip")
    }

    @MainActor
    func testDocumentEpubOPFReferencesResolveWithOneRealUnitAndNoTitlePage() {
        let entries = documentEpubEntries(for: "# Alpha\n\nText.\n\n## Beta\n\nMore.",
                                          title: "Alpha")
        let names = Set(entries.map(\.name))
        guard let opfData = entry("OEBPS/content.opf", in: entries) else {
            return XCTFail("the package document must be present")
        }
        let opf = String(decoding: opfData, as: UTF8.self)

        // Every href the manifest names must resolve to a packed file — nav,
        // stylesheet and the one content unit alike, no dangling reference.
        let regex = try! NSRegularExpression(pattern: "href=\"([^\"]+)\"")
        let ns = opf as NSString
        let hrefs = regex.matches(in: opf, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
        XCTAssertTrue(hrefs.contains("content.xhtml"))
        for href in hrefs {
            XCTAssertTrue(names.contains("OEBPS/\(href)"),
                          "manifest href \(href) has no packed file")
        }

        // Exactly one content unit — content.xhtml — and no phantom title
        // page: the book path makes `u001` an `<h1>title</h1>` page and starts
        // its nav cursor past it, and that unit must simply not exist here.
        let contentUnits = names.filter { $0.hasSuffix(".xhtml") && $0 != "OEBPS/nav.xhtml" }
        XCTAssertEqual(contentUnits, ["OEBPS/content.xhtml"])

        // The spine is that one unit, once.
        XCTAssertEqual(opf.components(separatedBy: "<itemref").count - 1, 1)
        XCTAssertTrue(opf.contains("<itemref idref=\"content\"/>"))
    }

    @MainActor
    func testDocumentEpubNavListsHeadingsWithSlugsMatchingTheContentAnchors() {
        // Two headings that would collide on slug, so the dedup ("beta",
        // "beta-1") is exercised on both sides at once.
        let source = "# Alpha\n\nText.\n\n## Beta\n\nMore.\n\n## Beta\n\nEnd."
        let entries = documentEpubEntries(for: source, title: "Alpha")
        let outline = MarkdownParser.outline(source)
        XCTAssertEqual(outline.map(\.slug), ["alpha", "beta", "beta-1"])

        guard let navData = entry("OEBPS/nav.xhtml", in: entries),
              let contentData = entry("OEBPS/content.xhtml", in: entries) else {
            return XCTFail("nav and content must be present")
        }
        let nav = String(decoding: navData, as: UTF8.self)
        let content = String(decoding: contentData, as: UTF8.self)
        XCTAssertTrue(nav.contains("epub:type=\"toc\""))

        // Every heading is a nav entry pointing at its anchor inside the one
        // content file, and that anchor id really exists in the content — the
        // nav slug (`MarkdownParser.outline`) and the id (`MarkdownHTML`) are
        // the same rule, so a reader's tap lands on the section, not nothing.
        for slug in outline.map(\.slug) {
            XCTAssertTrue(nav.contains("href=\"content.xhtml#\(slug)\""),
                          "nav must link heading #\(slug)")
            XCTAssertTrue(content.contains("id=\"\(slug)\""),
                          "content must carry the anchor #\(slug)")
        }
        // The nav is the document's sections, not a single flat entry, and the
        // first link points at the real content file — not a phantom the
        // title-page cursor would leave behind.
        XCTAssertEqual(nav.components(separatedBy: "content.xhtml#").count - 1, 3)
        XCTAssertTrue(nav.range(of: "content.xhtml#")!.lowerBound
                      < nav.range(of: "content.xhtml#", options: .backwards)!.lowerBound)
    }

    @MainActor
    func testDocumentEpubOfAHeadinglessDocumentHasAValidNav() {
        // A document with no headings has an empty outline, and a toc <nav>
        // whose <ol> holds no <li> is not valid EPUB 3. The fallback is a
        // single entry — the whole document under its title, linking to the
        // content file itself — matching Android and valid for a reader.
        let entries = documentEpubEntries(for: "Just a paragraph, no headings.",
                                          title: "Untitled")
        guard let navData = entry("OEBPS/nav.xhtml", in: entries) else {
            return XCTFail("nav must be present")
        }
        let nav = String(decoding: navData, as: UTF8.self)
        XCTAssertFalse(nav.contains("<ol>\n\n</ol>"), "the nav must not have an empty list")
        XCTAssertFalse(nav.replacingOccurrences(of: " ", with: "")
                          .replacingOccurrences(of: "\n", with: "").contains("<ol></ol>"))
        XCTAssertTrue(nav.contains("<li>"), "a headingless document still needs one nav entry")
        XCTAssertTrue(nav.contains("href=\"content.xhtml\""),
                      "the fallback entry links to the content file itself")
        XCTAssertTrue(nav.contains(">Untitled</a>"), "under the document's title")
    }

    @MainActor
    func testDocumentEpubIdentifierIsStableAcrossTwoExports() {
        // Two exports of the same document (same title) reach the same
        // `dc:identifier`, so re-exporting after an edit replaces the file in a
        // reader's library instead of stacking a second copy beside it.
        func identifier(of entries: [(name: String, data: Data)]) -> String? {
            guard let opf = entry("OEBPS/content.opf", in: entries)
                .map({ String(decoding: $0, as: UTF8.self) }),
                  let open = opf.range(of: "<dc:identifier id=\"book-id\">"),
                  let close = opf.range(of: "</dc:identifier>", range: open.upperBound..<opf.endIndex)
            else { return nil }
            return String(opf[open.upperBound..<close.lowerBound])
        }
        let first = documentEpubEntries(for: "# Title\n\nBody v1.", title: "The Same Doc")
        let second = documentEpubEntries(for: "# Title\n\nBody v2, edited.", title: "The Same Doc")
        XCTAssertEqual(identifier(of: first), identifier(of: second))
        XCTAssertEqual(identifier(of: first), EpubBuilder.stableIdentifier(forTitle: "The Same Doc"))
        // A differently-titled document is a different publication.
        XCTAssertNotEqual(
            identifier(of: first),
            identifier(of: documentEpubEntries(for: "# X", title: "Another Doc")))
    }

    // MARK: PDF page size — trim sizes (Feature 2)
    //
    // The PDF export paginates to a chosen trim size, not only A4 (a booklet
    // A5, a US Letter/Legal reader, a print-on-demand 6×9"/5×8"/5.5×8.5"). The
    // sizes are one shared table (`PageSize`) the three platforms copy verbatim,
    // so the dimensions are pinned here; A4 stays the default, so an A4 export
    // is byte-for-byte unchanged.

    func testPageSizeTableHasTheAgreedPointDimensions() {
        // 1 inch = 72 pt; these exact numbers are copied verbatim to macOS and
        // Android, so a drift here is a cross-platform pagination bug.
        func dims(_ id: String) -> (CGFloat, CGFloat) {
            let s = PageSize.named(id); return (s.width, s.height)
        }
        XCTAssertEqual(dims("a4").0, 595.2);  XCTAssertEqual(dims("a4").1, 841.8)
        XCTAssertEqual(dims("a5").0, 419.5);  XCTAssertEqual(dims("a5").1, 595.3)
        XCTAssertEqual(dims("letter").0, 612); XCTAssertEqual(dims("letter").1, 792)
        XCTAssertEqual(dims("legal").0, 612);  XCTAssertEqual(dims("legal").1, 1008)
        XCTAssertEqual(dims("6x9").0, 432);    XCTAssertEqual(dims("6x9").1, 648)
        XCTAssertEqual(dims("5x8").0, 360);    XCTAssertEqual(dims("5x8").1, 576)
        XCTAssertEqual(dims("5.5x8.5").0, 396); XCTAssertEqual(dims("5.5x8.5").1, 612)

        // The offered list is exactly these seven, A4 first — the default.
        XCTAssertEqual(PageSize.all.map(\.id),
                       ["a4", "a5", "letter", "legal", "6x9", "5x8", "5.5x8.5"])
        XCTAssertEqual(PageSize.all.first, .a4)
        // A4's table entry is exactly the geometry the renderer defaulted to
        // before trim sizes existed, so the default page rect is unchanged.
        XCTAssertEqual(PageSize.a4.size, WebRenderer.a4PageSize)
    }

    func testPageSizePreferenceRoundTripsAndDefaultsToA4() {
        // @AppStorage stores the stable id; `named` maps it back, so the
        // remembered choice round-trips.
        for size in PageSize.all {
            XCTAssertEqual(PageSize.named(size.id), size)
        }
        // An empty (first launch) or unknown (a stale / future-version) key
        // falls back to A4 — the historical default — never nil or a crash.
        XCTAssertEqual(PageSize.named(""), .a4)
        XCTAssertEqual(PageSize.named("tabloid"), .a4)
    }

    func testA4MarginIsUnchangedAndSmallerPagesScaleTheMarginDown() {
        // A4 reproduces the historical body margin to the pixel, so an A4 export
        // carries the exact CSS it always did.
        XCTAssertEqual(PageSize.a4.cssPadding, "48px 56px")

        // Every smaller page gets a strictly smaller margin on both axes — a
        // 6×9" booklet must not wear A4-sized margins.
        for size in [PageSize.a5, .sixByNine, .fiveByEight, .digest] {
            let parts = size.cssPadding.components(separatedBy: " ")
            let vertical = Int(parts[0].dropLast(2))!    // strip "px"
            let horizontal = Int(parts[1].dropLast(2))!
            XCTAssertLessThan(vertical, 48, "\(size.id) vertical margin should shrink")
            XCTAssertLessThan(horizontal, 56, "\(size.id) horizontal margin should shrink")
            XCTAssertGreaterThan(vertical, 0)
            XCTAssertGreaterThan(horizontal, 0)
        }
        // Letter is wider than A4, so its horizontal margin grows — the scale is
        // proportional to each dimension, not a blanket cap.
        XCTAssertEqual(PageSize.usLetter.cssPadding, "45px 58px")
    }

    @MainActor
    func testChosenPageSizeReachesTheRenderedPdfMediaBoxAndA4StaysDefault() async throws {
        // The strongest proof the choice flows the whole way through: render a
        // real one-page PDF and read the page's MediaBox back — a plain heading,
        // so the offscreen web view settles at once (no rich engines).
        let renderer = WebRenderer()
        try await renderer.load(
            html: MarkdownHTML.document("# Page", title: "Page", dark: false, export: true))

        func mediaBox(_ size: CGSize) throws -> CGRect {
            let data = try renderer.makePDF(pageSize: size)
            let pdf = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
            return pdf.page(at: 1)!.getBoxRect(.mediaBox)
        }

        // A chosen 6×9" trim reaches the page rect…
        let sixByNine = try mediaBox(PageSize.sixByNine.size)
        XCTAssertEqual(sixByNine.width, 432, accuracy: 0.6)
        XCTAssertEqual(sixByNine.height, 648, accuracy: 0.6)
        // …and `makePDF()`'s default is still real A4 — existing behaviour intact.
        let a4 = try mediaBox(WebRenderer.a4PageSize)
        XCTAssertEqual(a4.width, 595.2, accuracy: 0.6)
        XCTAssertEqual(a4.height, 841.8, accuracy: 0.6)
        withExtendedLifetime(renderer) {}
    }

    // MARK: LaTeX export (.tex)
    //
    // Pure string work with no rendering behind it, so it is covered
    // densely: every block kind, the escaping table, and the handful of
    // places where LaTeX's own syntax bites back (an optional argument
    // eaten off the front of an item, a code block that closes its own
    // verbatim environment).

    /// The body between `\begin{document}` and `\end{document}`, trimmed —
    /// most assertions are about the content, not the preamble.
    private func texBody(_ source: String) -> String {
        let tex = LaTeXExport.document(source)
        guard let start = tex.range(of: "\\begin{document}\n"),
              let end = tex.range(of: "\n\\end{document}") else {
            XCTFail("the document is not wrapped in a document environment")
            return tex
        }
        return String(tex[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The preamble: everything before `\begin{document}`.
    private func texPreamble(_ source: String) -> String {
        let tex = LaTeXExport.document(source)
        guard let start = tex.range(of: "\\begin{document}") else { return tex }
        return String(tex[..<start.lowerBound])
    }

    // MARK: LaTeX — escaping

    func testLaTeXEscapesEverySpecialCharacter() {
        // The ten characters TeX reserves. Three of them have no backslash
        // form at all and need a command instead — a leading backslash on
        // `~` or `^` would be an accent waiting for its letter.
        XCTAssertEqual(LaTeXExport.escape("#"), "\\#")
        XCTAssertEqual(LaTeXExport.escape("$"), "\\$")
        XCTAssertEqual(LaTeXExport.escape("%"), "\\%")
        XCTAssertEqual(LaTeXExport.escape("&"), "\\&")
        XCTAssertEqual(LaTeXExport.escape("_"), "\\_")
        XCTAssertEqual(LaTeXExport.escape("{"), "\\{")
        XCTAssertEqual(LaTeXExport.escape("}"), "\\}")
        XCTAssertEqual(LaTeXExport.escape("~"), "\\textasciitilde{}")
        XCTAssertEqual(LaTeXExport.escape("^"), "\\textasciicircum{}")
        XCTAssertEqual(LaTeXExport.escape("\\"), "\\textbackslash{}")
    }

    func testLaTeXEscapeDoesNotEscapeItsOwnOutput() {
        // The regression a chain of `replacingOccurrences` would produce:
        // `\` becomes `\textbackslash{}`, whose own braces and backslash
        // are then escaped again and the reader sees the command.
        XCTAssertEqual(LaTeXExport.escape("a\\b"), "a\\textbackslash{}b")
        XCTAssertEqual(LaTeXExport.escape("~^"),
                       "\\textasciitilde{}\\textasciicircum{}")
        // One pass, in order, whatever the mix.
        XCTAssertEqual(LaTeXExport.escape("100% of {a_b} & \\c ~ ^ $#"),
                       "100\\% of \\{a\\_b\\} \\& \\textbackslash{}c "
                       + "\\textasciitilde{} \\textasciicircum{} \\$\\#")
    }

    func testLaTeXEscapeLeavesUnreservedPunctuationAlone() {
        // `<`, `>` and `|` are not TeX specials — they only pick the wrong
        // glyph under an encoding nothing here selects — and the three
        // ports have to agree on this table character for character.
        XCTAssertEqual(LaTeXExport.escape("a < b > c | d"), "a < b > c | d")
    }

    func testLaTeXEscapeWalksScalarsNotGraphemeClusters() {
        // A special followed by a combining mark is a single `Character`,
        // and it is not `"#"` — so a walk over characters leaves the
        // special raw. A live `%` comments away the rest of the author's
        // sentence, and a live `#` is "Illegal parameter number".
        //
        // Kotlin, which has no grapheme clusters, escapes exactly this
        // text: a character walk is divergent as well as broken.
        XCTAssertEqual(LaTeXExport.escape("%\u{0301}"), "\\%\u{0301}")
        XCTAssertEqual(LaTeXExport.escape("#\u{FE0F}\u{20E3}"), "\\#\u{FE0F}\u{20E3}")
        XCTAssertEqual(LaTeXExport.escapeURL("a%\u{0301}b"), "a\\%\u{0301}b")
        // Whole-document form: the sentence after the special survives.
        XCTAssertEqual(texBody("Fifty%\u{0301} percent, and the rest survives."),
                       "Fifty\\%\u{0301} percent, and the rest survives.")
    }

    func testLaTeXPercentDecodesAnImagePath() {
        // `my%20dir` is a directory on no disk anywhere: an editor writes
        // it when the author drags in a file whose folder has a space in
        // its name, and they meant `my dir`.
        XCTAssertEqual(LaTeXExport.percentDecoded("my%20dir/a.png"), "my dir/a.png")
        XCTAssertEqual(LaTeXExport.percentDecoded("a%2Fb%20c.png"), "a/b c.png")
        // Multi-byte sequences come back as the character they encode.
        XCTAssertEqual(LaTeXExport.percentDecoded("%D0%9F.png"), "П.png")
        // What is not percent-encoding is not a mistake to correct — it is
        // a file name with a `%` in it, handed back exactly as it came.
        XCTAssertEqual(LaTeXExport.percentDecoded("100%.png"), "100%.png")
        XCTAssertEqual(LaTeXExport.percentDecoded("a%zzb"), "a%zzb")
        XCTAssertEqual(LaTeXExport.percentDecoded("trailing%2"), "trailing%2")
        // Bytes that are not UTF-8 are not repaired into U+FFFD either —
        // that would put a replacement character into a file name.
        XCTAssertEqual(LaTeXExport.percentDecoded("a%C0%80b"), "a%C0%80b")
        XCTAssertEqual(LaTeXExport.percentDecoded("plain.png"), "plain.png")
    }

    func testLaTeXURLEscapeGuardsOnlyWhatBreaksTheArgument() {
        // hyperref reads its URL argument with its own catcodes, so an
        // underscore or an ampersand arrives intact; escaping those would
        // put backslashes into the link itself.
        XCTAssertEqual(LaTeXExport.escapeURL("https://x.com/a_b?c=1&d=2"),
                       "https://x.com/a_b?c=1&d=2")
        // A comment character would swallow the rest of the line and a
        // parameter character is illegal there, so both are escaped.
        XCTAssertEqual(LaTeXExport.escapeURL("https://x.com/100%25#top"),
                       "https://x.com/100\\%25\\#top")
        // An unbalanced brace would end the argument early.
        XCTAssertEqual(LaTeXExport.escapeURL("a{b}c"), "a\\{b\\}c")
    }

    // MARK: LaTeX — preamble

    func testLaTeXPlainDocumentHasShortPreamble() {
        // Nothing but the class and the input encoding: a document with no
        // image, no link, no table and no strikethrough owes no packages.
        let preamble = texPreamble("# Title\n\nJust prose.")
        XCTAssertEqual(preamble, "\\documentclass{article}\n\\usepackage[utf8]{inputenc}\n")
    }

    func testLaTeXPackagesFollowTheFeaturesUsed() {
        XCTAssertTrue(texPreamble("![a](x.png)").contains("\\usepackage{graphicx}"))
        XCTAssertTrue(texPreamble("[a](https://x.com)").contains("\\usepackage{hyperref}"))
        XCTAssertTrue(texPreamble("| a |\n|---|\n| b |").contains("\\usepackage{longtable}"))
        // `normalem` is not decoration: plain ulem redefines `\emph` to
        // underline, so one struck-through word would underline every
        // italic in the document.
        XCTAssertTrue(texPreamble("~~gone~~").contains("\\usepackage[normalem]{ulem}"))
        XCTAssertFalse(texPreamble("~~gone~~").contains("\\usepackage{ulem}"))
    }

    func testLaTeXPackagesAreNotTriggeredByQuotedCode() {
        // The flags are set by the renderer as it emits each command, not
        // by scanning the finished file — a code block *about* LaTeX is not
        // a link, an image or a table.
        let preamble = texPreamble("```\n\\href{x}{y} \\includegraphics{z} \\begin{tabular}{l}\n```")
        XCTAssertFalse(preamble.contains("hyperref"))
        XCTAssertFalse(preamble.contains("graphicx"))
        XCTAssertFalse(preamble.contains("longtable"))
    }

    func testLaTeXHyperrefIsLoadedLast() {
        // The one package with a documented loading order — it redefines
        // enough of LaTeX's internals that anything after it may break.
        let preamble = texPreamble("[a](https://x.com) ![b](c.png) ~~d~~\n\n| a |\n|---|\n| b |")
        guard let hyperref = preamble.range(of: "\\usepackage{hyperref}") else {
            return XCTFail("hyperref should be loaded")
        }
        for other in ["graphicx", "ulem", "longtable"] {
            guard let range = preamble.range(of: other) else {
                return XCTFail("\(other) should be loaded")
            }
            XCTAssertLessThan(range.lowerBound, hyperref.lowerBound,
                              "\(other) must come before hyperref")
        }
    }

    func testLaTeXCyrillicPullsInFontencWithT2ALast() {
        // Without a Cyrillic encoding pdfTeX does not stop — the document
        // compiles and the Russian is simply not in it.
        let preamble = texPreamble("Привет, мир!")
        XCTAssertTrue(preamble.contains("\\usepackage[T1,T2A]{fontenc}"))
        // The order is the whole point: `fontenc` makes the *last* encoding
        // listed the document default, so `[T2A,T1]` would leave the
        // default at T1 and drop exactly the letters it was added for.
        XCTAssertFalse(preamble.contains("[T2A,T1]"))
    }

    func testLaTeXPlainEnglishGetsNoFontenc() {
        XCTAssertFalse(texPreamble("Plain English prose.").contains("fontenc"))
    }

    func testLaTeXCyrillicInsideCodeStillPullsInFontenc() {
        // Verbatim content is typeset too — a code sample with a Russian
        // comment needs the encoding as much as prose does.
        XCTAssertTrue(texPreamble("```\n// комментарий\n```").contains("fontenc"))
    }

    func testLaTeXCyrillicOnlyInAPrivateNoteDoesNotPullInFontenc() {
        // A private note never reaches the document, so it cannot make the
        // document need anything.
        let preamble = texPreamble("English.\n\n<!-- note: Привет -->")
        XCTAssertFalse(preamble.contains("fontenc"))
    }

    // MARK: LaTeX — front matter and the title block

    func testLaTeXFrontMatterBecomesTitleBlock() {
        let tex = LaTeXExport.document("""
        ---
        title: On Escaping
        author: nettrash
        date: 24 July 2026
        slug: on-escaping
        tags: latex, md
        ---

        Body.
        """)
        XCTAssertTrue(tex.contains("\\title{On Escaping}"))
        XCTAssertTrue(tex.contains("\\author{nettrash}"))
        XCTAssertTrue(tex.contains("\\date{24 July 2026}"))
        XCTAssertTrue(tex.contains("\\maketitle"))
        // Everything else is metadata *about* the document and has nowhere
        // to go in a typeset one.
        XCTAssertFalse(tex.contains("on-escaping"))
        XCTAssertFalse(tex.contains("tags"))
    }

    func testLaTeXTitleBlockWithoutADateDoesNotInventOne() {
        // `\maketitle` stamps today when no date is given — a date nobody
        // wrote into the document.
        let tex = LaTeXExport.document("---\ntitle: Untimed\n---\n\nBody.")
        XCTAssertTrue(tex.contains("\\date{}"))
    }

    func testLaTeXWithoutFrontMatterHasNoTitleBlock() {
        let tex = LaTeXExport.document("# Heading\n\nBody.")
        XCTAssertFalse(tex.contains("\\title"))
        XCTAssertFalse(tex.contains("\\maketitle"))
    }

    func testLaTeXTitleFieldsAreEscaped() {
        let tex = LaTeXExport.document("---\ntitle: 100% & more_stuff\n---\n\nBody.")
        XCTAssertTrue(tex.contains("\\title{100\\% \\& more\\_stuff}"))
    }

    // MARK: LaTeX — headings

    func testLaTeXHeadingLevelsMapOntoSectioning() {
        let expected = ["\\section{H}", "\\subsection{H}", "\\subsubsection{H}",
                        "\\paragraph{H}", "\\subparagraph{H}", "\\subparagraph{H}"]
        for level in 1...6 {
            let hashes = String(repeating: "#", count: level)
            XCTAssertEqual(texBody("\(hashes) H"), expected[level - 1],
                           "level \(level)")
        }
    }

    func testLaTeXHeadingTextIsEscapedAndFormatted() {
        XCTAssertEqual(texBody("# 50% **off**"), "\\section{50\\% \\textbf{off}}")
    }

    // MARK: LaTeX — mathematics

    func testLaTeXInlineMathPassesThroughUnescaped() {
        // The reason the format exists: the formula comes back as the
        // source the author typed, not as a picture of it.
        XCTAssertEqual(texBody("Then $a_1^{2} \\frac{x}{y}$ follows."),
                       "Then $a_1^{2} \\frac{x}{y}$ follows.")
    }

    func testLaTeXDisplayMathUsesTheBracketForm() {
        XCTAssertEqual(texBody("$$x^2$$"), "\\[x^2\\]")
        XCTAssertEqual(texBody("\\[x^2\\]"), "\\[x^2\\]")
        XCTAssertEqual(texBody("```math\nx^2\n```"), "\\[\nx^2\n\\]")
        // ```latex and ```tex name the same thing.
        XCTAssertEqual(texBody("```latex\nx^2\n```"), "\\[\nx^2\n\\]")
        XCTAssertEqual(texBody("```tex\nx^2\n```"), "\\[\nx^2\n\\]")
    }

    func testLaTeXParenMathBecomesDollarMath() {
        XCTAssertEqual(texBody("A \\(a_i\\) here."), "A $a_i$ here.")
    }

    func testLaTeXCurrencyIsNotMistakenForMathematics() {
        // The same guard the preview uses, so the two agree about what a
        // formula is in the same document.
        XCTAssertEqual(texBody("It costs $5 and $10."), "It costs \\$5 and \\$10.")
    }

    func testLaTeXWordGuardIsSpelledOutRatherThanBackslashW() {
        // `\w` is not one character class but three: ICU takes in every
        // combining mark and leaves out every number that is not a decimal
        // digit, and the JVM the Android tests run on reads it as ASCII
        // outright. The guard is spelled `[\p{L}\p{N}_]` on all three
        // ports so that the same span is mathematics in all three — which
        // is the whole point of this export.
        //
        // A superscript two is `\p{N}` and is *not* in ICU's `\w`, so it
        // stops what follows being a formula only if the guard is the
        // spelled-out one.
        XCTAssertEqual(texBody("²$x$"), "²\\$x\\$")
        XCTAssertEqual(texBody("²_x_"), "²\\_x\\_")
        // A combining mark is in ICU's `\w` and is not a letter, a number
        // or an underscore, so it stops nothing.
        XCTAssertEqual(texBody("e\u{0301}$x$"), "e\u{0301}$x$")
        XCTAssertEqual(texBody("e\u{0301}_x_"), "e\u{0301}\\emph{x}")
    }

    func testLaTeXMathInsideBackticksStaysCode() {
        // Code wins over math, exactly as in the preview.
        XCTAssertEqual(texBody("Use `$x$` literally."),
                       "Use \\texttt{\\$x\\$} literally.")
    }

    // MARK: LaTeX — inline formatting

    func testLaTeXEmphasisBecomesCommands() {
        XCTAssertEqual(texBody("**b** __b__ *i* _i_ ~~s~~"),
                       "\\textbf{b} \\textbf{b} \\emph{i} \\emph{i} \\sout{s}")
    }

    func testLaTeXSnakeCaseSurvivesUnderscoreItalic() {
        XCTAssertEqual(texBody("a_b_c is one word"), "a\\_b\\_c is one word")
    }

    func testLaTeXInlineCodeIsTexttt() {
        // `\texttt` rather than `\verb`, because this text has to survive
        // inside a section title, a caption and a table cell, where `\verb`
        // is not allowed. Its content is escaped like any other text.
        XCTAssertEqual(texBody("Type `a_b & c%`."),
                       "Type \\texttt{a\\_b \\& c\\%}.")
    }

    func testLaTeXLinkBecomesHref() {
        XCTAssertEqual(texBody("See [the docs](https://x.com/a_b)."),
                       "See \\href{https://x.com/a_b}{the docs}.")
    }

    func testLaTeXLinkLabelKeepsItsOwnMarkup() {
        // The label stays ordinary text through the link pass, so the
        // emphasis pass afterwards still finds what is inside it.
        XCTAssertEqual(texBody("[a **bold** label](https://x.com)"),
                       "\\href{https://x.com}{a \\textbf{bold} label}")
    }

    func testLaTeXLinkTitleIsConsumedNotPrinted() {
        // A title is a browser tooltip; a typeset page has nowhere to put
        // one — but it must not be left behind as stray prose either.
        XCTAssertEqual(texBody("[a](https://x.com \"hover text\")"),
                       "\\href{https://x.com}{a}")
    }

    func testLaTeXImageWithAltTextBecomesACaptionedFigure() {
        XCTAssertEqual(texBody("![A wide shot](img/a_1.png)"), """
        \\begin{figure}[ht]
        \\centering
        \\includegraphics[width=\\linewidth]{img/a_1.png}
        \\caption{A wide shot}
        \\end{figure}
        """)
    }

    func testLaTeXImageWithoutAltTextIsJustTheGraphic() {
        // No caption, because an empty one prints a bare "Figure 1" — and
        // `\noindent`, because a graphic exactly `\linewidth` wide starting
        // a paragraph is pushed over the margin by the paragraph indent and
        // LaTeX reports an overfull box for every image in the document.
        XCTAssertEqual(texBody("![](img/a.png)"),
                       "\\noindent\\includegraphics[width=\\linewidth]{img/a.png}")
    }

    func testLaTeXAltTextIsRenderedFromTheMarkupTheAuthorWrote() {
        // The alt text is captured from a string the literal-span pass has
        // already tokenised, so rendering it where it stands leaves that
        // pass's tokens inside the caption — where the outer restore never
        // looks, because it has already gone past them. The author's
        // formula then reaches the page as U+E000 ("Missing character:
        // There is no  (U+E000)"), and a code span next to a bold run
        // closes neither ("File ended while scanning use of \@xdblarg").
        //
        // So the caption is a fresh, complete pass over the Markdown they
        // actually wrote.
        XCTAssertTrue(texBody("![Alt with $x$ set](f.png)")
            .contains("\\caption{Alt with $x$ set}"))
        XCTAssertTrue(texBody("![Alt `c` and **b**](f.png)")
            .contains("\\caption{Alt \\texttt{c} and \\textbf{b}}"))
        // Nothing of either pass is left in the file.
        XCTAssertFalse(texBody("![Alt with $x$ and `c`](f.png)").contains("\u{E000}"))
        XCTAssertFalse(texBody("![Alt with $x$ and `c`](f.png)").contains("\u{E001}"))
    }

    func testLaTeXImagePathIsPercentDecodedBeforeItIsWritten() {
        XCTAssertEqual(texBody("![](my%20dir/a.png)"),
                       "\\noindent\\includegraphics[width=\\linewidth]{my dir/a.png}")
    }

    func testLaTeXImagePathLaTeXCannotReadIsSkippedAndNamed() {
        // graphicx reads its argument as a file name, and there is no
        // spelling of `%` or `#` that works in one: raw, the comment
        // character eats the rest of the line; escaped, the compile stops
        // ("Missing endcsname inserted"). Neither is worth a whole
        // document, so the file is skipped and named — and the alt text is
        // set in its place, because it is the author's own description of
        // the picture and the only part of it that can survive.
        let body = texBody("Before ![alt](a#b.png) after.")
        XCTAssertFalse(body.contains("\\includegraphics"))
        XCTAssertTrue(body.contains("\\emph{alt}"), "the author's words survive")
        XCTAssertTrue(body.contains("% md: image skipped"))
        XCTAssertTrue(body.contains("a#b.png"), "the author is told which file")
        XCTAssertTrue(body.contains("Before"))
        XCTAssertTrue(body.contains("after."), "nothing after the image is lost")
        // The comment comes last and ends its own line. `%` runs to the end
        // of the physical line, so one in front of the text would swallow
        // the text and one with nothing after it would swallow the rest of
        // a table row.
        XCTAssertTrue(body.contains("\\emph{alt}\n% md: image skipped"))
        XCTAssertTrue(body.contains("LaTeX can read.\n"))
        // A path that is not percent-encoding keeps its `%` and is refused
        // for it.
        XCTAssertTrue(texBody("![](100%.png)").contains("% md: image skipped"))
        // A package is not loaded for a graphic that was never drawn.
        XCTAssertFalse(texPreamble("![](a#b.png)").contains("graphicx"))
    }

    // MARK: LaTeX — lists

    func testLaTeXListsUseItemizeAndEnumerate() {
        XCTAssertEqual(texBody("- a\n- b"), """
        \\begin{itemize}
        \\item a
        \\item b
        \\end{itemize}
        """)
        XCTAssertEqual(texBody("1. a\n2. b"), """
        \\begin{enumerate}
        \\item a
        \\item b
        \\end{enumerate}
        """)
    }

    func testLaTeXNestedListsNestEnvironments() {
        XCTAssertEqual(texBody("- a\n  - b\n    - c\n- d"), """
        \\begin{itemize}
        \\item a
        \\begin{itemize}
        \\item b
        \\begin{itemize}
        \\item c
        \\end{itemize}
        \\end{itemize}
        \\item d
        \\end{itemize}
        """)
    }

    func testLaTeXListStartingIndentedOpensOnlyOneEnvironment() {
        // Two `\begin{itemize}` in a row is a LaTeX error ("perhaps a
        // missing \item"), and a list whose first item is already indented
        // is exactly what would produce it.
        let body = texBody("  - already indented\n    - deeper")
        XCTAssertFalse(body.contains("\\begin{itemize}\n\\begin{itemize}"),
                       "no environment may open without an item before it")
        XCTAssertEqual(body.components(separatedBy: "\\begin{itemize}").count - 1, 2)
        XCTAssertEqual(body.components(separatedBy: "\\end{itemize}").count - 1, 2)
    }

    func testLaTeXDeepListStopsAtLaTeXsNestingLimit() {
        // LaTeX refuses to nest lists more than four deep. Every item still
        // has to appear — the deepest ones simply share the deepest level
        // LaTeX has.
        let source = (0..<6).map { String(repeating: " ", count: $0 * 2) + "- l\($0)" }
            .joined(separator: "\n")
        let body = texBody(source)
        XCTAssertEqual(body.components(separatedBy: "\\begin{itemize}").count - 1, 4)
        for level in 0..<6 {
            XCTAssertTrue(body.contains("\\item l\(level)"), "l\(level) must survive")
        }
    }

    func testLaTeXTaskListRendersLiteralCheckboxes() {
        // A literal checkbox rather than a package for one glyph — and the
        // empty group in front of it earns its place: `\item [x]` reads the
        // bracket as the item's optional *label*, which would swallow the
        // checkbox instead of printing it.
        XCTAssertEqual(texBody("- [ ] open\n- [x] done"), """
        \\begin{itemize}
        \\item {}[\\,] open
        \\item {}[x] done
        \\end{itemize}
        """)
    }

    func testLaTeXItemBeginningWithABracketIsGuarded() {
        // Same hazard, no task list in sight.
        XCTAssertTrue(texBody("- [draft] not a task").contains("\\item {}[draft]"))
        // …and an item that does not start with one is left alone.
        XCTAssertTrue(texBody("- plain").contains("\\item plain"))
    }

    // MARK: LaTeX — code and diagrams

    func testLaTeXCodeBlockIsVerbatimAndUnescaped() {
        // Verbatim is verbatim: escaping it would put backslashes on the page.
        XCTAssertEqual(texBody("```\nif (a & b) { x_1 = 100%; }\n```"), """
        \\begin{verbatim}
        if (a & b) { x_1 = 100%; }
        \\end{verbatim}
        """)
    }

    func testLaTeXCodeBlockQuotingVerbatimEndIsSplit() {
        // The one real hazard. LaTeX's verbatim terminator is matched as
        // *characters*, so a block that quotes `\end{verbatim}` would close
        // the environment early and spill the rest of the block into the
        // document as LaTeX to execute.
        let body = texBody("```\nbefore\n\\end{verbatim}\nafter\n```")
        XCTAssertTrue(body.contains("\\verb|\\end{verbatim}|"),
                      "the terminator itself must be set with \\verb")
        XCTAssertTrue(body.contains("before"))
        XCTAssertTrue(body.contains("after"), "nothing after the hazard may be lost")
        // Every environment opened is closed: one more `\end{verbatim}`
        // than `\begin{verbatim}` would be the early close itself.
        let opens = body.components(separatedBy: "\\begin{verbatim}").count - 1
        let closes = body.components(separatedBy: "\\end{verbatim}").count - 1
        XCTAssertEqual(opens, 2, "the block is split around the terminator")
        XCTAssertEqual(closes, opens + 1, "the extra one is inside the \\verb")
    }

    func testLaTeXDiagramSourceSurvivesAsVerbatim() {
        // LaTeX has no Mermaid, PlantUML or Graphviz, and md's renderers
        // are JavaScript engines that cannot travel in a .tex file. Dropping
        // the diagram would lose a whole figure without saying so.
        for language in ["mermaid", "plantuml", "dot", "neato"] {
            let body = texBody("```\(language)\nA -> B\n```")
            XCTAssertTrue(body.hasPrefix("% \(language) diagram source"),
                          "\(language) should name itself in a comment")
            XCTAssertTrue(body.contains("\\begin{verbatim}\nA -> B\n\\end{verbatim}"),
                          "\(language) source must survive verbatim")
        }
    }

    // MARK: LaTeX — tables

    func testLaTeXTableColumnSpecFollowsTheAlignments() {
        XCTAssertEqual(texBody("| L | C | R |\n|:--|:-:|--:|\n| a | b | c |"), """
        \\begin{longtable}{lcr}
        \\hline
        \\textbf{L} & \\textbf{C} & \\textbf{R} \\\\
        \\hline
        \\endhead
        a & b & c \\\\
        \\hline
        \\end{longtable}
        """)
    }

    func testLaTeXTableCellsAreEscapedAndKeepInlineMarkup() {
        let body = texBody("| a | b |\n|---|---|\n| 50% | $x^2$ **b** |")
        XCTAssertTrue(body.contains("50\\% & $x^2$ \\textbf{b} \\\\"))
    }

    func testLaTeXTableRowBeginningWithABracketIsGuarded() {
        // `\\` followed by `[` is a row with a vertical skip, not a row
        // beginning with a bracket.
        let body = texBody("| a |\n|---|\n| [draft] |")
        XCTAssertTrue(body.contains("{}[draft] \\\\"))
    }

    func testLaTeXCSVBlockBecomesTheSameTable() {
        // The parse and the "a column of figures is right-aligned" rule are
        // shared with the HTML renderer, so the same spreadsheet lands the
        // same way in the PDF and in the .tex.
        let body = texBody("```csv\nName,Qty\nBolt,12\nNut,3.5\n```")
        XCTAssertTrue(body.contains("\\begin{longtable}{lr}"),
                      "the numeric column is right-aligned")
        XCTAssertTrue(body.contains("\\textbf{Name} & \\textbf{Qty} \\\\"))
        XCTAssertTrue(body.contains("Bolt & 12 \\\\"))
        // A tab-separated block is the same table.
        XCTAssertTrue(texBody("```tsv\nName\tQty\nBolt\t12\n```")
            .contains("\\begin{longtable}{lr}"))
    }

    func testLaTeXUnparseableDelimitedBlockStaysCode() {
        // Nothing the author wrote disappears: a ```csv block that parses
        // to no table is still their text.
        XCTAssertEqual(texBody("```csv\n\n```"), "\\begin{verbatim}\n\n\\end{verbatim}")
    }

    // MARK: LaTeX — quotes, rules and breaks

    func testLaTeXQuotesRecurse() {
        XCTAssertEqual(texBody("> outer\n>\n> > inner"), """
        \\begin{quote}
        outer

        \\begin{quote}
        inner
        \\end{quote}
        \\end{quote}
        """)
    }

    func testLaTeXThematicBreakAndPageBreak() {
        XCTAssertEqual(texBody("***"), "\\par\\noindent\\hrulefill\\par")
        XCTAssertEqual(texBody("a\n\n\\newpage\n\nb"), "a\n\n\\newpage\n\nb")
    }

    func testLaTeXPrivateNotesAreDropped() {
        // As in every other output: they live in the editor and the notes
        // panel, never in the document.
        XCTAssertEqual(texBody("before\n\n<!-- note: private -->\n\nafter"),
                       "before\n\nafter")
    }

    func testLaTeXSoftBreaksBecomeLineBreaks() {
        // md shows a soft break as a break in the preview, the HTML and the
        // PDF; the .tex agrees rather than reflowing the paragraph.
        XCTAssertEqual(texBody("one\ntwo\nthree"), "one\\\\\ntwo\\\\\nthree")
        // Never a trailing `\\` — "there's no line here to end" is an error.
        XCTAssertFalse(texBody("one\ntwo").hasSuffix("\\\\"))
    }

    func testLaTeXSoftBreakBeforeABracketIsGuarded() {
        // `\\` followed by `[` is read as `\\[length]`.
        XCTAssertEqual(texBody("line\n[bracketed]"), "line\\\\\n{}[bracketed]")
    }

    func testLaTeXSoftBreakBeforeAnUndefinedFootnoteIsGuarded() {
        // Same hazard, one pass later. While the lines are being split the
        // reference is still a token, so a guard applied there sees no
        // bracket at all and `\\[\textasciicircum{}missing]` reaches LaTeX
        // as a vertical skip ("Illegal unit of measure (pt inserted)").
        // The guard has to run on the restored line, like the other two.
        XCTAssertEqual(texBody("line one\n[^missing] line two"),
                       "line one\\\\\n{}[\\textasciicircum{}missing] line two")
    }

    // MARK: LaTeX — footnotes

    func testLaTeXFootnoteIsInlinedAtItsFirstReference() {
        // What a LaTeX footnote *is* — which is why this export has no
        // collected list at the foot of the document the way the HTML has.
        XCTAssertEqual(texBody("Text[^a] here.\n\n[^a]: The note with *emphasis*."),
                       "Text\\footnote{The note with \\emph{emphasis}.} here.")
    }

    func testLaTeXRepeatedFootnoteReferencesCiteTheNumber() {
        // The number is right because every `\footnote` here is emitted in
        // the order it was numbered, so LaTeX's counter and this one agree.
        XCTAssertEqual(texBody("A[^a] B[^b] C[^a].\n\n[^a]: one\n\n[^b]: two"),
                       "A\\footnote{one} B\\footnote{two} C\\footnotemark[1].")
    }

    func testLaTeXUndefinedFootnoteReferenceStaysLiteral() {
        // A reference with no definition is not a footnote at all, so it
        // goes back to being the text the author typed.
        XCTAssertEqual(texBody("Text[^missing] here."),
                       "Text[\\textasciicircum{}missing] here.")
    }

    func testLaTeXUncitedFootnoteIsStillPrinted() {
        // Dropping it would silently discard something the author wrote.
        let body = texBody("Prose.\n\n[^unused]: Nobody points at this.")
        XCTAssertTrue(body.contains("% Footnotes defined but never referenced"))
        XCTAssertTrue(body.contains("\\footnote{Nobody points at this.}"))
    }

    func testLaTeXFootnoteInsideAFootnoteDegradesToText() {
        // LaTeX cannot nest footnotes; the inner reference becomes the text
        // the author typed, and its definition — now uncited — is printed
        // at the end rather than lost.
        let body = texBody("A[^a].\n\n[^a]: See[^b].\n\n[^b]: The target.")
        XCTAssertTrue(body.contains("\\footnote{See[\\textasciicircum{}b].}"))
        XCTAssertTrue(body.contains("\\footnote{The target.}"))
    }

    func testLaTeXFootnoteInAHeadingIsProtected() {
        // A section title is a moving argument — LaTeX writes it to the
        // `.toc`, and a bare `\footnote` there is a compile error.
        XCTAssertEqual(texBody("# Head[^a]\n\n[^a]: note"),
                       "\\section{Head\\protect\\footnote{note}}")
    }

    func testLaTeXFootnoteDefinitionRendersNothingWhereItWasWritten() {
        XCTAssertEqual(texBody("A[^a].\n\n[^a]: note\n\nB."),
                       "A\\footnote{note}.\n\nB.")
    }

    // MARK: LaTeX — restricted places
    //
    // A table cell, a footnote's own text and an image caption are places
    // LaTeX will not open a float or a display environment in. Each of
    // these was a compile that stopped at the first one, or a note whose
    // words never reached the page.

    func testLaTeXDisplayMathInATableCellIsSetInline() {
        // `\[` inside `tabular` stops the *file*, not the cell. Set inline
        // the formula is smaller than the author asked for; every symbol
        // of it is still on the page.
        let body = texBody("| formula |\n|---------|\n| $$x^2$$ |")
        XCTAssertTrue(body.contains("$x^2$ \\\\"))
        XCTAssertFalse(body.contains("\\["))
        // The `\[…\]` spelling of the same thing degrades the same way.
        XCTAssertTrue(texBody("| a |\n|---|\n| \\[x^2\\] |").contains("$x^2$ \\\\"))
    }

    func testLaTeXDisplayMathInAFootnoteIsSetInline() {
        XCTAssertEqual(texBody("A[^a].\n\n[^a]: $$x^2$$ ends it."),
                       "A\\footnote{$x^2$ ends it.}.")
    }

    func testLaTeXImageInATableCellIsNotAFloat() {
        // "LaTeX Error: Not in outer par mode." — and the whole document
        // stops there.
        let body = texBody("| picture |\n|---------|\n| ![A caption](a.png) |")
        XCTAssertTrue(body.contains(
            "\\includegraphics[width=\\linewidth]{a.png} \\emph{A caption} \\\\"))
        XCTAssertFalse(body.contains("\\begin{figure}"))
        XCTAssertFalse(body.contains("\\caption"))
    }

    func testLaTeXImageInAFootnoteIsNotAFloat() {
        // "LaTeX Error: Float(s) lost." — same again.
        let body = texBody("Text[^a] here.\n\n[^a]: See ![A caption](a.png) for detail.")
        XCTAssertTrue(body.contains(
            "\\footnote{See \\includegraphics[width=\\linewidth]{a.png} "
            + "\\emph{A caption} for detail.}"))
        XCTAssertFalse(body.contains("\\begin{figure}"))
    }

    func testLaTeXFootnoteCitedFromATableCellKeepsItsWords() {
        // A `table` float typesets no footnote text from inside itself:
        // the mark prints, the counter steps, and the note's words are
        // simply not in the PDF. A `longtable` is not a float, so an
        // ordinary `\footnote` sets its own words in the cell where the
        // author put the reference — and there is no `\footnotemark` /
        // `\footnotetext` split left to keep in step.
        let body = texBody("| cell |\n|------|\n| A[^a] |\n\n[^a]: Zarquon lives here.")
        XCTAssertTrue(body.contains("A\\footnote{Zarquon lives here.} \\\\"))
        XCTAssertFalse(body.contains("\\footnotemark"))
        XCTAssertFalse(body.contains("\\footnotetext"))
    }

    func testLaTeXFootnoteNumbersKeepAgreeingAcrossATable() {
        // The counter this file keeps and the one LaTeX keeps have to stay
        // in step across the split: the note after the table is number 2,
        // and a second citation of the first one still says 1.
        let body = texBody("""
        | cell |
        |------|
        | A[^a] B[^a] |

        Then C[^b].

        [^a]: first

        [^b]: second
        """)
        XCTAssertTrue(body.contains("A\\footnote{first} B\\footnotemark[1]"))
        XCTAssertTrue(body.contains("Then C\\footnote{second}."))
    }

    func testLaTeXRestrictionIsInheritedByAFootnoteRaisedFromATable() {
        // The note's text is written after `\end{table}`, but it is still
        // a footnote: a float in it is "Float(s) lost" wherever it was
        // cited from.
        let body = texBody("| a |\n|---|\n| A[^a] |\n\n[^a]: $$x^2$$ and ![cap](a.png)")
        XCTAssertTrue(body.contains(
            "\\footnote{$x^2$ and \\includegraphics[width=\\linewidth]{a.png} \\emph{cap}}"))
        XCTAssertFalse(body.contains("\\begin{figure}"))
        XCTAssertFalse(body.contains("\\["))
    }

    func testLaTeXTableEndsAtItsOwnEnd() {
        // Nothing is collected below a table any more: the notes it cites
        // are set in its own cells.
        XCTAssertTrue(texBody("| a |\n|---|\n| b |").hasSuffix("\\end{longtable}"))
        XCTAssertFalse(texBody("| a |\n|---|\n| b |").contains("\\footnotetext"))
    }

    // MARK: LaTeX — books

    /// A two-chapter book in the reading order the PDF compile and the EPUB
    /// already use.
    private func sampleBook() -> EpubBook {
        EpubBook(title: "The Book",
                 rootArticles: [EpubArticle(title: "Preface", source: "Opening words.")],
                 chapters: [
                    EpubChapter(title: "One", articles: [
                        EpubArticle(title: "First", source: "# Inner\n\nA[^a].\n\n[^a]: n1"),
                        EpubArticle(title: "Second", source: "B[^b].\n\n[^b]: n2"),
                    ]),
                    EpubChapter(title: "Two", articles: [
                        EpubArticle(title: "Third", source: "C[^c] C[^c].\n\n[^c]: n3"),
                    ]),
                 ])
    }

    func testLaTeXBookUsesTheBookClassAndTheReadingOrder() {
        let tex = LaTeXExport.book(sampleBook())
        XCTAssertTrue(tex.hasPrefix("\\documentclass{book}\n"))
        XCTAssertTrue(tex.contains("\\title{The Book}"))
        XCTAssertTrue(tex.contains("\\maketitle"))
        // Root articles first, then each chapter with its articles — the
        // same order the EPUB packs and the PDF compiles.
        let order = ["\\section{Preface}", "\\chapter{One}", "\\section{First}",
                     "\\section{Second}", "\\chapter{Two}", "\\section{Third}"]
        var cursor = tex.startIndex
        for piece in order {
            guard let found = tex.range(of: piece, range: cursor..<tex.endIndex) else {
                return XCTFail("\(piece) is missing or out of order")
            }
            cursor = found.upperBound
        }
    }

    func testLaTeXBookPushesArticleHeadingsBelowTheirSection() {
        // An article is already a `\section`, so its own `#` has to become a
        // `\subsection` — otherwise the author's heading is the article's
        // sibling rather than its content.
        XCTAssertTrue(LaTeXExport.book(sampleBook()).contains("\\subsection{Inner}"))
    }

    func testLaTeXBookRestartsFootnoteNumbersAtEachChapter() {
        // `book` resets the footnote counter at every `\chapter`, so the
        // numbers `\footnotemark` cites have to restart with it — the third
        // chapter's repeated note is number 1 again, not number 3.
        let tex = LaTeXExport.book(sampleBook())
        XCTAssertTrue(tex.contains("C\\footnote{n3} C\\footnotemark[1]."))
    }

    func testLaTeXBookCollectsPackagesAcrossEveryArticle() {
        // The preamble belongs to the whole file: a package one article
        // needs must be loaded even if nothing else in the book uses it.
        let book = EpubBook(title: "B", rootArticles: [],
                            chapters: [EpubChapter(title: "C", articles: [
                                EpubArticle(title: "Plain", source: "Nothing special."),
                                EpubArticle(title: "Rich", source: "![a](x.png) ~~b~~"),
                            ])])
        let tex = LaTeXExport.book(book)
        XCTAssertTrue(tex.contains("\\usepackage{graphicx}"))
        XCTAssertTrue(tex.contains("\\usepackage[normalem]{ulem}"))
    }

    func testLaTeXBookTitlesAreEscaped() {
        let book = EpubBook(title: "R&D 100%", rootArticles: [],
                            chapters: [EpubChapter(title: "A_B", articles: [])])
        let tex = LaTeXExport.book(book)
        XCTAssertTrue(tex.contains("\\title{R\\&D 100\\%}"))
        XCTAssertTrue(tex.contains("\\chapter{A\\_B}"))
    }

    // MARK: LaTeX — whole documents

    func testLaTeXDocumentIsWellFormed() {
        let tex = LaTeXExport.document("# H\n\nBody with $x$ and a [link](https://x.com).")
        XCTAssertTrue(tex.hasPrefix("\\documentclass{article}\n"))
        XCTAssertTrue(tex.hasSuffix("\\end{document}\n"))
        XCTAssertEqual(tex.components(separatedBy: "\\begin{document}").count - 1, 1)
        XCTAssertEqual(tex.components(separatedBy: "\\end{document}").count - 1, 1)
    }

    func testLaTeXEmptyDocumentStillCompilesAsOne() {
        let tex = LaTeXExport.document("")
        XCTAssertTrue(tex.contains("\\begin{document}"))
        XCTAssertTrue(tex.contains("\\end{document}"))
    }

    // MARK: LaTeX — scalar-exact string work (regression — third review)
    //
    // Swift's `contains`, `hasPrefix`, `components(separatedBy:)` and
    // `replacingOccurrences(of:with:)` all match extended *grapheme
    // clusters*, so every one of them is blind to an ASCII character that
    // has a combining mark, a variation selector or a ZWJ after it: the two
    // together are a single `Character` that is not equal to the plain one.
    // Every guard in the writer that used one silently stopped firing, and
    // Kotlin — which walks UTF-16 units — kept firing, so each was a port
    // divergence as well as a broken guard.

    /// Three ways to make the character in front part of a longer grapheme:
    /// a combining acute, a variation selector, a zero-width joiner.
    private static let marks = ["\u{0301}", "\u{FE0F}", "\u{200D}"]

    func testLaTeXEveryEscapeFiresWithACombiningMarkAfterIt() {
        // The whole escaping table against all three marks. Left raw, a `%`
        // comments the author's sentence away, a `#` is "Illegal parameter
        // number", a `\` starts a command that does not exist.
        let table = [("#", "\\#"), ("$", "\\$"), ("%", "\\%"), ("&", "\\&"),
                     ("_", "\\_"), ("{", "\\{"), ("}", "\\}"),
                     ("~", "\\textasciitilde{}"), ("^", "\\textasciicircum{}"),
                     ("\\", "\\textbackslash{}")]
        for (special, escaped) in table {
            for mark in Self.marks {
                XCTAssertEqual(LaTeXExport.escape("a\(special)\(mark)b"),
                               "a\(escaped)\(mark)b",
                               "\(special) with a mark after it must still be escaped")
            }
        }
        // …and the URL table, which is a different set of characters.
        for (special, escaped) in [("%", "\\%"), ("#", "\\#"), ("{", "\\{"),
                                   ("}", "\\}"), ("\\", "\\textbackslash{}")] {
            for mark in Self.marks {
                XCTAssertEqual(LaTeXExport.escapeURL("a\(special)\(mark)b"),
                               "a\(escaped)\(mark)b")
            }
        }
    }

    func testLaTeXEveryGuardFiresWithACombiningMarkAfterIt() {
        for mark in Self.marks {
            // The bracket guard, at all three of its callers. `\item [x]`,
            // `\\[x]` and `& [x] \\` each read the bracket as an optional
            // argument and eat the words behind it.
            // The assertions are scalar-exact too, and they have to be:
            // the `[` in the output is fused with the mark, so XCTest's own
            // `contains` cannot see it any better than the writer could.
            XCTAssertTrue(ScalarText.contains(
                texBody("- [\(mark)draft] item"), "\\item {}["), "list item guard")
            XCTAssertTrue(ScalarText.contains(
                texBody("line\n[\(mark)draft]"), "\\\\\n{}["), "soft-break guard")
            XCTAssertTrue(ScalarText.contains(
                texBody("| a |\n|---|\n| [\(mark)draft] |"), "{}["), "table row guard")

            // The percent-decoder's own early exit: a `%` it cannot see is
            // a `%` it hands to `\includegraphics`.
            XCTAssertEqual(LaTeXExport.percentDecoded("a%\(mark)b"), "a%\(mark)b")
            XCTAssertTrue(texBody("![](a%\(mark)b.png)").contains("% md: image skipped"),
                          "an unreadable path must still be refused")
        }
    }

    func testLaTeXVerbatimIsSplitAroundATerminatorCarryingAMark() {
        // The worst of them. `verbatim` scans for the *characters*
        // `\end{verbatim}`, so a terminator the split did not see closes
        // the environment early and the rest of the author's code block is
        // executed as LaTeX.
        for mark in Self.marks {
            let body = texBody("```\nbefore\n\\end{verbatim}\(mark)\nafter\n```")
            XCTAssertTrue(body.contains("\\verb|\\end{verbatim}|"),
                          "the terminator must be set with \\verb")
            XCTAssertTrue(body.contains("after"), "nothing after it may be lost")
            let opens = ScalarText.split(body, "\\begin{verbatim}").count - 1
            XCTAssertEqual(opens, 2, "the block is split around the terminator")
        }
    }

    func testLaTeXTokenRestoreSurvivesAMarkAfterTheToken() {
        // A token is U+E000, digits, U+E001, and a mark can land after the
        // last of those. A grapheme-matching restore then never finds it:
        // raw U+E000 lands in the .tex and the author's span is gone.
        for mark in Self.marks {
            let body = texBody("A `code` span\(mark) and $x^2$\(mark) after.")
            XCTAssertFalse(body.contains("\u{E000}"), "no token may reach the file")
            XCTAssertFalse(body.contains("\u{E001}"))
            XCTAssertTrue(ScalarText.contains(body, "\\texttt{code}"))
            XCTAssertTrue(ScalarText.contains(body, "$x^2$"))
        }
    }

    func testLaTeXSoftBreaksSplitOnEveryNewlineIncludingCRLF() {
        // `\r\n` is one grapheme cluster, so `components(separatedBy: "\n")`
        // does not split there at all and a whole document written on
        // Windows reflows into one paragraph. Kotlin's `split("\n")` splits.
        XCTAssertEqual(ScalarText.split("a\r\nb", "\n"), ["a\r", "b"])
        XCTAssertEqual(ScalarText.split("a\nb\nc", "\n"), ["a", "b", "c"])
        XCTAssertEqual(ScalarText.split("", "\n"), [""])
        XCTAssertEqual(ScalarText.split("aXbXc", "X"), ["a", "b", "c"])
        XCTAssertEqual(ScalarText.split("XaX", "X"), ["", "a", ""])
        // A CRLF document is normalised by the parser before it reaches the
        // writer, so the whole-document form is the same on both ports too.
        XCTAssertEqual(texBody("a\r\nb"), "a\\\\\nb")
    }

    func testLaTeXScalarHelpersAreExactWhereTheStdlibIsNot() {
        // Stated as the property the writer depends on: each helper says
        // yes where Swift's own says no.
        let marked = "a%\u{0301}b"
        XCTAssertTrue(ScalarText.contains(marked, "%"))
        XCTAssertFalse(marked.contains("%"), "the stdlib is the thing being worked around")

        XCTAssertTrue(ScalarText.hasPrefix("[\u{FE0F}x", "["))
        XCTAssertFalse("[\u{FE0F}x".hasPrefix("["))

        XCTAssertTrue(ScalarText.hasSuffix("x\n", "\n"))
        XCTAssertFalse(ScalarText.hasSuffix("x", "\n"))

        XCTAssertEqual(ScalarText.replacing("a\u{E000}0\u{E001}\u{0301}b",
                                                   "\u{E000}0\u{E001}", with: "!"),
                       "a!\u{0301}b")
        XCTAssertEqual("a\u{E000}0\u{E001}\u{0301}b"
            .replacingOccurrences(of: "\u{E000}0\u{E001}", with: "!"),
                       "a\u{E000}0\u{E001}\u{0301}b",
                       "the stdlib leaves the token in place — this is the defect")
    }

    // MARK: LaTeX — tables break across pages (regression — third review)

    func testLaTeXTableIsALongtableAndNotAFloat() {
        // A float cannot break across a page, so a table taller than one is
        // *truncated*: exit 0, the PDF stops at the row that filled the
        // page, and the only trace is a "Float too large for page" warning
        // in a log nobody reads. Nothing here may be a float.
        let rows = (1...70).map { "| r\($0) | c\($0) |" }.joined(separator: "\n")
        let body = texBody("| A | B |\n|---|---|\n" + rows)
        XCTAssertTrue(body.hasPrefix("\\begin{longtable}{ll}"))
        XCTAssertTrue(body.hasSuffix("\\end{longtable}"))
        XCTAssertFalse(body.contains("\\begin{table}"))
        XCTAssertFalse(body.contains("\\begin{tabular}"))
        // Every row the author wrote is in the file.
        for index in 1...70 {
            XCTAssertTrue(body.contains("r\(index) & c\(index) \\\\"), "row \(index)")
        }
    }

    func testLaTeXLongtableRepeatsItsHeaderOnEveryPage() {
        // A reader who turns to the second page of a table needs to know
        // what its columns are, and `\endhead` is the whole of that.
        let body = texBody("| A | B |\n|---|---|\n| a | b |")
        guard let head = body.range(of: "\\endhead") else {
            return XCTFail("the header must be marked as one")
        }
        XCTAssertTrue(body[..<head.lowerBound].contains("\\textbf{A} & \\textbf{B}"),
                      "the header row belongs above \\endhead")
        XCTAssertTrue(body[head.upperBound...].contains("a & b \\\\"),
                      "the body rows below it")
    }

    // MARK: LaTeX — images LaTeX cannot include (regression — third review)

    func testLaTeXImagePathWithBracesOrABackslashIsSkipped() {
        // `escapeURL` turns each of these into a control sequence, which is
        // right for `\href` and fatal for `\includegraphics`: graphicx
        // reads its argument as a file name, so `\{` is not a character it
        // can open and the whole document fails.
        for path in ["img/{a}.png", "img/a}.png", "img\\b.png"] {
            let body = texBody("Before ![alt](\(path)) after.")
            XCTAssertFalse(body.contains("\\includegraphics"), path)
            XCTAssertTrue(body.contains("% md: image skipped"), path)
            XCTAssertTrue(body.contains("\\emph{alt}"), "the alt text survives \(path)")
            XCTAssertTrue(body.contains("after."), "nothing after it is lost")
        }
        // A path with none of them is still an image.
        XCTAssertTrue(texBody("![](img/a-b_1.png)").contains("\\includegraphics"))
    }

    func testLaTeXRemoteAndDataImagesAreSkippedAndNamed() {
        // TeX fetches nothing: `\includegraphics{https://…}` is "File not
        // found" and the document stops there. A `data:` URI is a picture
        // with no file name at all. Both are the same answer as a name
        // graphicx cannot read.
        for path in ["https://nettrash.me/favicon.ico", "http://x.com/a.png",
                     "data:image/png;base64,iVBORw0KGgo="] {
            let body = texBody("![A picture](\(path))")
            XCTAssertFalse(body.contains("\\includegraphics"), path)
            XCTAssertTrue(body.contains("% md: image skipped"), path)
            XCTAssertTrue(body.contains(path), "the author is told which one")
            XCTAssertTrue(body.contains("\\emph{A picture}"), "the alt text survives")
        }
        // A relative path with a colon in it is a file somebody can really
        // have, and is not refused for the shape of its name.
        XCTAssertTrue(texBody("![](notes:draft.png)").contains("\\includegraphics"))
    }

    func testLaTeXAltTextSurvivesWhereThereIsNoCaption() {
        // Three places the author's own description of a picture used to be
        // dropped without a word. This project's rule is that nothing
        // written vanishes silently.
        XCTAssertTrue(texBody("| p |\n|---|\n| ![In a cell](a.png) |")
            .contains("\\emph{In a cell}"))
        XCTAssertTrue(texBody("A[^a].\n\n[^a]: ![In a note](a.png)")
            .contains("\\emph{In a note}"))
        XCTAssertTrue(texBody("![On a skipped one](a#b.png)")
            .contains("\\emph{On a skipped one}"))
        // It is the Markdown the author wrote, rendered — not the raw text.
        XCTAssertTrue(texBody("| p |\n|---|\n| ![Alt with `c`](a.png) |")
            .contains("\\emph{Alt with \\texttt{c}}"))
    }

    func testLaTeXSoftBreakAfterAnImageAloneOnItsLineIsNotWritten() {
        // `\end{figure}\\` is "There's no line here to end" — a float
        // begins no line — and it stops the whole document. So is a `\\`
        // after a comment that is all the line holds.
        let figure = texBody("![A caption](a.png)\nafter")
        XCTAssertTrue(figure.contains("\\end{figure}\nafter"))
        XCTAssertFalse(figure.contains("\\end{figure}\\\\"))

        // A skipped image with alt text does set a line, so the break
        // after it is written — and it is safe, because the paragraph the
        // `\emph` opened is still open when the comment's newline ends.
        let skipped = texBody("![Alt](https://x.com/a.png)\nafter")
        XCTAssertTrue(skipped.contains("\\emph{Alt}"))
        XCTAssertTrue(skipped.contains("after"))
        XCTAssertFalse(skipped.contains("\\\\\n\n"), "never a blank line after a \\\\")

        // Without alt text there is nothing but the comment, so no break is
        // written before it and none after it either.
        let bare = texBody("![](https://x.com/a.png)\nafter")
        XCTAssertTrue(bare.contains("% md: image skipped"))
        XCTAssertTrue(bare.contains("after"))
        XCTAssertFalse(bare.contains("\\\\"), "a comment begins no line to end")
        XCTAssertFalse(bare.contains("\n\n"), "and no paragraph break either")

        // An ordinary pair of lines still breaks, and a line with the image
        // *and* words on it still breaks after the words.
        XCTAssertEqual(texBody("one\ntwo"), "one\\\\\ntwo")
    }

    // MARK: LaTeX — mathematics that carries its own separators

    func testLaTeXDisplayMathWithItsOwnSeparatorsGetsAnAligned() {
        // `&` is an alignment tab wherever it is read, so `\[a &= b\]` is
        // "Misplaced alignment tab character" in ordinary body text; and in
        // a table cell a top-level `\\` ends the *row* from inside math
        // mode. Both stop the whole file, and both are what `aligned` is
        // for.
        XCTAssertEqual(texBody("$$a &= b \\\\ c &= d$$"),
                       "\\[\\begin{aligned}a &= b \\\\ c &= d\\end{aligned}\\]")
        XCTAssertTrue(texBody("| f |\n|---|\n| $$a \\\\ b$$ |")
            .contains("$\\begin{aligned}a \\\\ b\\end{aligned}$ \\\\"))
        // A formula that opens an environment of its own already owns its
        // separators; wrapping it would change what it aligns on.
        XCTAssertEqual(texBody("$$\\begin{aligned} p &= q \\end{aligned}$$"),
                       "\\[\\begin{aligned} p &= q \\end{aligned}\\]")
        // And a formula with neither is left exactly as written.
        XCTAssertEqual(texBody("$$x^2$$"), "\\[x^2\\]")
    }

    func testLaTeXAmsmathIsLoadedForAnyMathematics() {
        // `\begin{aligned}` in a ```math fence is "Environment aligned
        // undefined" without it, and that is one of the eight examples md
        // ships. Guessing which constructs a formula reached for is how
        // that happened; a document with any mathematics loads amsmath.
        for source in ["$x^2$", "$$x^2$$", "\\[x^2\\]", "\\(x^2\\)",
                       "```math\n\\begin{aligned}a &= b\\end{aligned}\n```",
                       "| f |\n|---|\n| $x$ |"] {
            XCTAssertTrue(texPreamble(source).contains("\\usepackage{amsmath}"), source)
        }
        // And not for a document with none — the preamble stays short
        // enough to read at a glance.
        XCTAssertFalse(texPreamble("Just prose.").contains("amsmath"))
        XCTAssertFalse(texPreamble("```\n$x^2$\n```").contains("amsmath"),
                       "a code block quoting a formula is not one")
    }

    func testLaTeXBookArticlesEachNumberTheirOwnNotes() {
        // Two articles of one chapter, each numbering its own notes from
        // `[^1]` — which is the normal thing, not a clash: an id belongs to
        // the file it was written in. Carrying the numbers across made the
        // second article's `[^1]` a `\footnotemark[1]` citing the *first*
        // article's note, and the words written for the second were never
        // printed at all.
        let book = EpubBook(title: "B", rootArticles: [], chapters: [
            EpubChapter(title: "C", articles: [
                EpubArticle(title: "One", source: "First[^1].\n\n[^1]: The first note."),
                EpubArticle(title: "Two", source: "Second[^1].\n\n[^1]: The second note."),
            ]),
        ])
        let tex = LaTeXExport.book(book)
        XCTAssertTrue(tex.contains("First\\footnote{The first note.}"))
        XCTAssertTrue(tex.contains("Second\\footnote{The second note.}"),
                      "the second article's own note must be printed")
        XCTAssertFalse(tex.contains("\\footnotemark"))
    }


    func testLaTeXNoCommandItEmitsIsEverEscaped() {
        // The ordering guarantee, stated as a property: after a document
        // full of specials and markup, no command this file produced has
        // been through the escaper (`\textbackslash{}textbf` would be the
        // symptom).
        let tex = LaTeXExport.document("""
        **bold** with 100% & _under_ and `a_b`, a [link](https://x.com/a_b),
        ![alt](p.png), $x_1^2$ and ~~gone~~.

        | a & b |
        |-------|
        | 50%   |
        """)
        XCTAssertFalse(tex.contains("\\textbackslash{}text"))
        XCTAssertFalse(tex.contains("\\textbackslash{}begin"))
        XCTAssertFalse(tex.contains("\\{}"), "no command's braces were escaped")
        XCTAssertTrue(tex.contains("\\textbf{bold}"))
        XCTAssertTrue(tex.contains("$x_1^2$"))
    }

    // MARK: LaTeX — the last silent losses (regression — fourth review)

    func testLaTeXFootnoteCitedFromATableHeaderKeepsItsWords() {
        // A `longtable` typesets its header row *once*, into the box
        // `\endhead` reinserts at every page break — and LaTeX throws a
        // footnote insertion made inside a box away. A plain `\footnote` in
        // a header cell therefore compiles at exit 0 with the note's words
        // on no page at all: the same silent loss the longtable switch
        // cured for body cells, still alive in the head. So the head
        // carries the mark and the note's text is written after the table,
        // where it is read exactly once.
        let body = texBody("| h1[^1] | h2 |\n|---|---|\n| c1 | c2 |\n\n[^1]: Zarquon in the head.")
        XCTAssertTrue(body.contains("\\textbf{h1\\stepcounter{footnote}\\footnotemark[1]}"))
        XCTAssertTrue(body.contains("\\end{longtable}\n\\footnotetext[1]{Zarquon in the head.}"))
        XCTAssertFalse(body.contains("\\footnote{Zarquon"),
                       "never an insertion inside the saved head box")

        // `\footnotemark[n]` does not step LaTeX's counter, so the head
        // steps it by hand. Without that every number after it is one too
        // low: the body cell's note would print the header's number and
        // two notes would share it.
        let mixed = texBody("""
        | ha[^a] | hb |
        |--------|----|
        | b[^b]  | c  |

        Tail[^c].

        [^a]: note a

        [^b]: note b

        [^c]: note c
        """)
        XCTAssertTrue(mixed.contains("\\textbf{ha\\stepcounter{footnote}\\footnotemark[1]}"))
        XCTAssertTrue(mixed.contains("b\\footnote{note b}"))
        XCTAssertTrue(mixed.contains("Tail\\footnote{note c}."))
        XCTAssertTrue(mixed.contains("\\end{longtable}\n\\footnotetext[1]{note a}"))

        // A note cited again from a body cell is the number, as ever — the
        // split is only about where the *text* goes.
        XCTAssertTrue(texBody("| h[^a] |\n|---|\n| A[^a] |\n\n[^a]: n")
            .contains("A\\footnotemark[1] \\\\"))

        // And a note first cited from a body cell keeps the plain
        // `\footnote` it always had: the head is the only exception, and a
        // table without a note in its head owes nothing after itself.
        let plain = texBody("| h |\n|---|\n| A[^a] |\n\n[^a]: n")
        XCTAssertTrue(plain.contains("A\\footnote{n} \\\\"))
        XCTAssertFalse(plain.contains("\\footnotetext"))
        XCTAssertTrue(plain.hasSuffix("\\end{longtable}"))
    }

    func testLaTeXHeaderCellCarryingAnAlignmentTabIsGrouped() {
        // `\textbf` is not `{\bfseries …}`: it *reads* its argument, with a
        // delimited macro that a top-level `&` ends the row out from
        // underneath — "Argument of \check@nocorr@ has an extra }" for a
        // formula, the same failure in `\href@split` for a query string,
        // and either stops the whole file. An extra group is the whole fix:
        // TeX reads `&` as an alignment tab only at the outermost brace
        // level of a cell.
        XCTAssertTrue(texBody("| $a &= b$ | h |\n|---|---|\n| c | d |")
            .contains("\\textbf{{$\\begin{aligned}a &= b\\end{aligned}$}}"))
        XCTAssertTrue(texBody("| [x](http://e.com/?a=1&b=2) | h |\n|---|---|\n| c | d |")
            .contains("\\textbf{{\\href{http://e.com/?a=1&b=2}{x}}}"))

        // Written only where there is a tab to guard. An ordinary header
        // cell is untouched, and so is one holding the author's own
        // ampersand — by then it is `\&`, which is a character and not a
        // tab.
        XCTAssertTrue(texBody("| A | B |\n|---|---|\n| a | b |")
            .contains("\\textbf{A} & \\textbf{B}"))
        XCTAssertTrue(texBody("| a & b | B |\n|---|---|\n| c | d |")
            .contains("\\textbf{a \\& b} & \\textbf{B}"))

        // A body cell needs none of it: nothing reads an argument there,
        // and the `aligned` the formula was given owns its own tab.
        XCTAssertTrue(texBody("| h |\n|---|\n| $a &= b$ |")
            .contains("$\\begin{aligned}a &= b\\end{aligned}$ \\\\"))
    }

    func testLaTeXImagePathWithADoubleQuoteIsSkipped() {
        // graphicx quotes a file name that has spaces in it with a pair of
        // `"`, so one the author wrote breaks graphicx's own parser: "Use
        // of ??? doesn't match its definition", and the document stops
        // there. A sweep of all 95 printable ASCII characters through
        // `unreadableImage` found it the only one that was neither refused
        // here nor compilable, so it joins `% # { } \`.
        XCTAssertNotNil(LaTeXExport.unreadableImage("a\"b.png"))
        let body = texBody("Before ![alt](a\"b.png) after.")
        XCTAssertFalse(body.contains("\\includegraphics"))
        XCTAssertTrue(body.contains("% md: image skipped — a\"b.png"))
        XCTAssertTrue(body.contains("\\emph{alt}"), "the alt text survives")
        XCTAssertTrue(body.contains("after."), "and so does the rest of the sentence")

        // A `"` in a *link* is refused nothing: hyperref reads its argument
        // as a URL and opens no file.
        XCTAssertNil(LaTeXExport.unreadableImage("a-b_1.png"))
        XCTAssertTrue(texBody("[x](http://e.com/a\"b)").contains("\\href{http://e.com/a\"b}{x}"))
    }

    func testLaTeXAuthorsOwnTokenSentinelsCannotBeReadAsTokens() {
        // U+E000 and U+E001 are what an inline pass wraps a span index in.
        // A document carrying them of its own had its *own* characters read
        // back as a token index: `text **b <E000>0<E001> x** more` came out
        // as `text \textbf{b \textbf{ x} more` — the command duplicated, a
        // word dropped, the braces unbalanced, and the file refused with
        // "File ended while scanning use of \textbf". They are stripped
        // from everything that enters the writer, and nothing typesettable
        // goes with them: inputenc has no definition for either, so a
        // document that kept them would stop at "Unicode character U+E000
        // not set up for use with LaTeX" instead.
        XCTAssertEqual(texBody("text **b \u{E000}0\u{E001} x** more"),
                       "text \\textbf{b 0 x} more")
        // Every other place the author's text is read: a formula, which is
        // the one span copied through unescaped; a code span; a table cell;
        // and the front matter, which never reaches an inline pass at all.
        XCTAssertEqual(texBody("A $x\u{E000}_1\u{E001}$ and `c\u{E000}d` here."),
                       "A $x_1$ and \\texttt{cd} here.")
        XCTAssertTrue(texBody("| h\u{E001}1 | b |\n|---|---|\n| c | d |")
            .contains("\\textbf{h1} & \\textbf{b}"))
        XCTAssertTrue(texPreamble("---\ntitle: Ti\u{E000}tle\n---\n\nBody.")
            .contains("\\title{Title}"))

        // The strip itself, and that it is the only thing it touches.
        XCTAssertEqual(LaTeXExport.withoutSentinels("a\u{E000}b\u{E001}c"), "abc")
        XCTAssertEqual(LaTeXExport.withoutSentinels("plain"), "plain")
        XCTAssertEqual(LaTeXExport.withoutSentinels("\u{E002}\u{F8FF}"), "\u{E002}\u{F8FF}")
    }

    func testLaTeXSkippedImageNamesItsFileBelowTheAltText() {
        // The alt text comes *first* and the comment after it, and it has
        // to: `%` runs to the end of its physical line, so a comment in
        // front of the words would swallow the words it is there to
        // explain. (The CHANGELOG said the opposite of the code for a
        // release and a half.)
        XCTAssertTrue(LaTeXExport.document("![Alt words](https://x.com/a.png)").contains("""
        \\emph{Alt words}
        % md: image skipped — https://x.com/a.png is a URL, and LaTeX has nothing to fetch it with.

        """))

        // And an image is a captioned float wherever it stands in body
        // text, not only alone in a paragraph. A graphic `\linewidth` wide
        // has nowhere to sit inside a sentence — set in the flow it would
        // be an overfull line on every image in the document — so LaTeX is
        // left to place it, and the words around it are untouched.
        let sentence = texBody("See ![the chart](c.png) for details.")
        XCTAssertTrue(sentence.hasPrefix("See \\begin{figure}[ht]"))
        XCTAssertTrue(sentence.contains("\\caption{the chart}"))
        XCTAssertTrue(sentence.hasSuffix("\\end{figure} for details."))
    }

    // MARK: Parser — scalar-exact block delimiters (regression — fifth review)
    //
    // The writer's defect, one layer down and worth more. A combining mark,
    // a variation selector or a ZWJ written after a *block* delimiter fuses
    // onto it into a single `Character`, and `String`'s grapheme matching
    // then cannot see the delimiter at all — so the block is silently not
    // recognised. `MarkdownParser` is what the preview, the HTML, the PDF,
    // the EPUB, the outline and the notes panel are all built from, so each
    // of these was the same document being a different document on Apple
    // and Android everywhere at once.
    //
    // Every expected value below is what the Kotlin port already produced.
    // A differential run of the two ports over 3,555 marked documents put
    // the divergence at 465 records before this change and 0 after, and the
    // eight shipped examples, the example book and the 16 TestData files
    // parse byte-for-byte as they did.

    func testParserListMarkerSurvivesAMarkOnItsSpace() {
        // The demonstrated one: `- ́[draft]` was a paragraph here and a
        // list on Android.
        for mark in Self.marks {
            guard case let .list(ordered, items)? = parse("- \(mark)[draft]").first else {
                return XCTFail("a marked marker space must still start a list")
            }
            XCTAssertFalse(ordered)
            XCTAssertEqual(items.map(\.text), ["\(mark)[draft]"],
                           "and the mark stays where the author put it")
        }
    }

    func testParserFenceSurvivesAMarkOnItsOpeningRun() {
        // A mark on the third backtick made the run two characters long,
        // so the fence was prose: the author's code reflowed and got
        // inline-formatted.
        for mark in Self.marks {
            guard case let .codeBlock(language, code)? =
                    parse("```\(mark)js\ncode()\n```").first else {
                return XCTFail("a marked fence must still open a code block")
            }
            XCTAssertEqual(code, "code()")
            XCTAssertEqual(language, "\(mark)js")
        }
    }

    func testParserTableRowSurvivesAMarkOnItsOnlyPipe() {
        // The row scan asks whether the line has a pipe at all. With the
        // only one marked it said no, and the row dropped out of the table
        // and became a paragraph under it.
        for mark in Self.marks {
            let kinds = parse("a | b\n--- | ---\n1 |\(mark) 2")
            guard case let .table(_, _, rows)? = kinds.first else {
                return XCTFail("expected a table")
            }
            XCTAssertEqual(rows, [["1", "\(mark) 2"]])
            XCTAssertEqual(kinds.count, 1, "the row must not also become a paragraph")
        }
    }

    func testParserFootnoteDefinitionSurvivesAMarkOnItsColon() {
        for mark in Self.marks {
            guard case let .footnoteDefinition(id, text)? =
                    parse("[^a]:\(mark) the note").first else {
                return XCTFail("expected a footnote definition")
            }
            XCTAssertEqual(id, "a")
            XCTAssertEqual(text, "\(mark) the note")
        }
    }

    func testParserQuoteMarkerSurvivesAMarkAfterIt() {
        for mark in Self.marks {
            guard case let .quote(inner)? = parse(">\(mark) quoted").first else {
                return XCTFail("expected a block quote")
            }
            guard case let .paragraph(text)? = inner.first?.kind else {
                return XCTFail("expected a paragraph inside the quote")
            }
            XCTAssertEqual(text, "\(mark) quoted")
        }
        // The marker stripper too: `> ́text` dropped the space *and* the
        // author's mark here, and only the space on Android.
        for mark in Self.marks {
            guard case let .quote(inner)? = parse("> \(mark)text").first,
                  case let .paragraph(text)? = inner.first?.kind else {
                return XCTFail("expected a block quote")
            }
            XCTAssertEqual(text, "\(mark)text")
        }
    }

    func testParserHeadingSurvivesAMarkOnItsMarkerSpace() {
        for mark in Self.marks {
            guard case let .heading(level, text)? = parse("# \(mark)Heading").first else {
                return XCTFail("expected a heading")
            }
            XCTAssertEqual(level, 1)
            XCTAssertEqual(text, "\(mark)Heading")
            // …and the outline must list the same heading the document has.
            XCTAssertEqual(MarkdownParser.outline("# \(mark)Heading").map(\.text),
                           ["\(mark)Heading"])
        }
    }

    func testParserCommentEndSurvivesAMarkAfterIt() {
        // The loudest of them: a mark on the closing `-->` left the comment
        // open, so the parser swallowed the rest of the document into it —
        // headings, outline entries and all.
        for mark in Self.marks {
            let kinds = parse("<!-- note: private -->\(mark)\n\nafter")
            XCTAssertEqual(kinds.count, 2, "the comment must end where it ends")
            guard case let .note(text)? = kinds.first else {
                return XCTFail("expected a note")
            }
            XCTAssertEqual(text, "private")
            guard case let .paragraph(after) = kinds[1] else {
                return XCTFail("the text after the comment must survive")
            }
            XCTAssertEqual(after, "after")

            let source = "<!-- x -->\(mark)\n\n# After"
            XCTAssertEqual(MarkdownParser.outline(source).map(\.text), ["After"])
            XCTAssertEqual(MarkdownParser.notes("<!-- note: n -->\(mark)").map(\.text), ["n"])
        }
        // And the opening `<!--`, which made the comment show up as prose.
        for mark in Self.marks {
            XCTAssertEqual(parse("<!--\(mark) hidden -->\n\nafter").count, 1)
        }
    }

    func testParserFrontMatterFieldSurvivesAMarkOnItsSeparator() {
        // A field whose `:` carried a mark was dropped from the metadata
        // here and kept on Android.
        for mark in Self.marks {
            guard case let .frontMatter(fields)? =
                    parse("---\ntitle: T\nauthor:\(mark) A\n---\n\nbody").first else {
                return XCTFail("expected front matter")
            }
            XCTAssertEqual(fields.map(\.key), ["title", "author"])
            XCTAssertEqual(fields.map(\.value), ["T", "\(mark) A"])
        }
        // Quote stripping counts scalars too, so the mark behind the
        // opening quote is not dropped with it.
        guard case let .frontMatter(quoted)? =
                parse("---\ntitle: \"\u{0301}Q\"\n---\n\nbody").first else {
            return XCTFail("expected front matter")
        }
        XCTAssertEqual(quoted.map(\.value), ["\u{0301}Q"])
    }

    func testParserTaskBoxIsScalarExact() {
        for mark in Self.marks {
            guard case let .list(_, items)? = parse("- [ ] \(mark)task").first else {
                return XCTFail("expected a list")
            }
            XCTAssertEqual(items.map(\.task), [false], "still a task item")
            XCTAssertEqual(items.map(\.text), ["\(mark)task"])
        }
    }

    func testParserOrderedListMarkerIsASCIIDigitsOnly() {
        // `Character.isNumber` also admits ½ and ٣, which `Int(_:)` cannot
        // read back — so such a line was an ordered list numbered 1 here,
        // a list numbered 3 on Android (its `toIntOrNull` reads ٣), and a
        // paragraph on neither. CommonMark says ASCII digits, and with that
        // set the ordinal always parses and the ports agree.
        guard case .paragraph = parse("½. half").first else {
            return XCTFail("½ is not an ordered-list marker")
        }
        guard case .paragraph = parse("\u{0663}. three").first else {
            return XCTFail("٣ is not an ordered-list marker")
        }
        // A digit carrying a mark is not one either: the mark ends the run
        // before the `.`, so the line joins the item above it.
        for mark in Self.marks {
            guard case let .list(_, items)? = parse("1. one\n2\(mark). two").first else {
                return XCTFail("expected a list")
            }
            XCTAssertEqual(items.map(\.text), ["one 2\(mark). two"])
        }
        // The ordinary case is untouched.
        guard case let .list(ordered, items)? = parse("1. one\n2. two").first else {
            return XCTFail("expected a list")
        }
        XCTAssertTrue(ordered)
        XCTAssertEqual(items.map(\.ordinal), [1, 2])
    }

    func testParserSlugKeepsWhatTheAndroidPortKeeps() {
        // The slug walked graphemes, so a mark on a character it does not
        // keep letter-wise took the character with it: `a -́b c` anchored as
        // "a-b-c" here and "a--́b-c" on Android, and a TOC link written on
        // one platform scrolled to nothing on the other.
        var used: [String: Int] = [:]
        XCTAssertEqual(MarkdownParser.slug(for: "a -\u{0301}b c", used: &used),
                       "a--\u{0301}b-c")
        // A ZWJ is a format character and is kept by neither.
        used = [:]
        XCTAssertEqual(MarkdownParser.slug(for: "Heading\u{200D}", used: &used), "heading")
        // A combining mark on a letter still rides along, as it always did.
        used = [:]
        XCTAssertEqual(MarkdownParser.slug(for: "Cafe\u{0301}", used: &used),
                       "cafe\u{0301}")
        // And the everyday one is unchanged, uniquing included.
        used = [:]
        XCTAssertEqual(MarkdownParser.slug(for: "Getting Started", used: &used),
                       "getting-started")
        XCTAssertEqual(MarkdownParser.slug(for: "Getting Started", used: &used),
                       "getting-started-1")
    }

    func testParserBlankLineSetIsFoundationsOwn() {
        // Pins the one character where Foundation's `.whitespaces` and the
        // JVM's `Zs` disagree: U+200B is a space separator to Apple's
        // (frozen) tables and a format character to Java's current ones.
        // A line holding one was a blank line here and a paragraph on
        // Android until the Kotlin port was given the same set.
        let kinds = parse("para\n\u{200B}\nnext")
        XCTAssertEqual(kinds.count, 2, "a zero-width space alone is a blank line")
        // The ordinary spaces, for company.
        XCTAssertEqual(parse("para\n \t\u{00A0}\nnext").count, 2)
    }

    func testParserNoteAndFenceTrimsAreFoundationsOwn() {
        // The other half of the same parity claim, pinned from this side:
        // the Android port trimmed a note's body with Kotlin's whitespace
        // set (which keeps U+0085) and a fence's info string with only
        // space and tab (which keeps U+00A0), so a note vanished from its
        // panel and a fence kept a language nobody typed — and a closing
        // fence padded with U+00A0 did not close, swallowing the rest of
        // the document into the code block.
        XCTAssertEqual(MarkdownParser.notes("<!--\u{0085} note: n -->").map(\.text), ["n"])
        XCTAssertEqual(MarkdownParser.notes("<!-- note: n \u{0085}-->").map(\.text), ["n"])
        guard case let .codeBlock(language, code)? = parse("```\u{00A0}js\ncode()\n```").first else {
            return XCTFail("expected a code block")
        }
        XCTAssertEqual(language, "js")
        XCTAssertEqual(code, "code()")
        XCTAssertEqual(parse("```\ncode()\n```\u{00A0}\n\nafter").count, 2,
                       "the fence closes, so the text after it is its own block")
    }

    func testParserLineEndingsAreScalarExact() {
        // CRLF, lone CR and LF all end exactly one line, and a mark on the
        // character after a newline cannot hide the newline.
        let kinds = parse("one\r\ntwo\rthree\nfour")
        guard case let .paragraph(text)? = kinds.first else {
            return XCTFail("expected one paragraph")
        }
        XCTAssertEqual(text, "one\ntwo\nthree\nfour")
        XCTAssertEqual(parse("a\r\n\r\nb").count, 2)
        XCTAssertEqual(MarkdownParser.outline("# One\r\n\r\n# Two").map(\.line), [0, 2])
    }

    // MARK: Diagram → standalone SVG (Feature 1)
    //
    // The two pure halves: which blocks a document offers (diagrams yes,
    // math and plain code no), and the fix-up that turns a rendered `<svg>`
    // into a standalone file. The offscreen capture in between is a five-line
    // DOM read, not covered here.

    func testDiagramSVGOffersOnlyDiagramsInDocumentOrder() {
        // Inline math, a math fence and a plain code block are all NOT
        // diagrams; the three engine fences are, in document order, each with
        // the ordinal the DOM query will index it by.
        let source = "Inline $a^2$ math.\n\n"
            + "```math\nE=mc^2\n```\n\n"
            + "```swift\nlet x = 1\n```\n\n"
            + "```mermaid\ngraph TD; A-->B\n```\n\n"
            + "```dot\ndigraph { a -> b }\n```\n\n"
            + "```plantuml\n@startuml\nA->B\n@enduml\n```"
        let diagrams = DiagramSVG.diagrams(inSource: source)
        XCTAssertEqual(diagrams.map(\.kind),
                       [.mermaid, .graphviz, .plantuml])
        XCTAssertEqual(diagrams.map(\.ordinal), [0, 1, 2])
        XCTAssertEqual(diagrams.map(\.engine), [nil, "dot", nil])
        // The label is the first non-empty source line, so two diagrams read
        // apart in the menu.
        XCTAssertEqual(diagrams[0].label, "graph TD; A-->B")
        XCTAssertEqual(diagrams[2].label, "@startuml")
    }

    func testDiagramSVGOffersNothingWithoutDiagrams() {
        // Prose, a formula and plain code — nothing that renders to an <svg>.
        let none = DiagramSVG.diagrams(inSource:
            "# Title\n\nText $x^2$ here.\n\n```swift\nlet y = 1\n```\n\n```math\nE=mc^2\n```")
        XCTAssertTrue(none.isEmpty)
        XCTAssertTrue(DiagramSVG.diagrams(inSource: "").isEmpty)
    }

    func testDiagramSVGRecursesIntoQuotesAndCoversLayoutAliases() {
        // A diagram nested in a block quote keeps its place — MarkdownHTML
        // renders quoted blocks in line, so its container is first in the DOM
        // — and a layout-named Graphviz fence is offered with its engine.
        let source = "> ```mermaid\n> graph TD; A-->B\n> ```\n\n"
            + "```neato\ngraph { a -- b }\n```"
        let diagrams = DiagramSVG.diagrams(inSource: source)
        XCTAssertEqual(diagrams.map(\.kind), [.mermaid, .graphviz])
        XCTAssertEqual(diagrams.map(\.engine), [nil, "neato"])
        XCTAssertEqual(diagrams.map(\.ordinal), [0, 1])
    }

    func testDiagramSVGRawDiagramDocumentIsASingleDiagram() {
        // An opened `.puml` / `.gv` is one whole-file diagram (MarkdownHTML
        // renders it without parsing Markdown), so it is exactly one entry.
        let puml = DiagramSVG.diagrams(inSource: "@startuml\nA->B\n@enduml")
        XCTAssertEqual(puml.map(\.kind), [.plantuml])
        XCTAssertEqual(puml.first?.ordinal, 0)
        XCTAssertEqual(puml.first?.label, "@startuml")

        let dot = DiagramSVG.diagrams(inSource: "digraph { a -> b }")
        XCTAssertEqual(dot.map(\.kind), [.graphviz])
        XCTAssertEqual(dot.first?.engine, "dot")
    }

    func testDiagramMenuTitlesNameEngineAndSourceSnippet() {
        let mermaid = DiagramSVG.Diagram(ordinal: 0, kind: .mermaid, engine: nil,
                                         label: "graph TD")
        XCTAssertEqual(mermaid.typeName, "Mermaid")
        XCTAssertEqual(mermaid.menuTitle, "Mermaid: graph TD")

        // The default `dot` layout isn't named; a non-default one is.
        let dot = DiagramSVG.Diagram(ordinal: 1, kind: .graphviz, engine: "dot", label: "g")
        XCTAssertEqual(dot.typeName, "Graphviz")
        let neato = DiagramSVG.Diagram(ordinal: 2, kind: .graphviz, engine: "neato", label: "")
        XCTAssertEqual(neato.typeName, "Graphviz (neato)")
        XCTAssertEqual(neato.menuTitle, "Graphviz (neato)")   // no label → type only

        // A long first line is capped so one diagram can't dwarf the menu.
        let long = DiagramSVG.diagrams(inSource:
            "```mermaid\n" + String(repeating: "x", count: 100) + "\n```")
        XCTAssertEqual(long.count, 1)
        XCTAssertTrue(long[0].label.hasSuffix("…"))
        XCTAssertLessThanOrEqual(long[0].label.count, 41)     // 40 chars + ellipsis
    }

    func testStandaloneSVGResolvesMermaidSizeFromViewBox() {
        // Mermaid's root is `width="100%"` with no height — unusable in a file.
        // The standalone document must carry the XML prolog, keep the SVG
        // namespace, and take real pixel width/height from the viewBox.
        let svg = "<svg id=\"m\" class=\"flowchart\" viewBox=\"0 0 200 100\" "
            + "style=\"max-width: 200px;\" width=\"100%\" "
            + "xmlns=\"http://www.w3.org/2000/svg\"><g></g></svg>"
        let out = DiagramSVG.standaloneDocument(fromSVG: svg)
        XCTAssertTrue(out.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"))
        XCTAssertTrue(out.contains("xmlns=\"http://www.w3.org/2000/svg\""))
        XCTAssertTrue(out.contains("width=\"200\""))
        XCTAssertTrue(out.contains("height=\"100\""))
        XCTAssertFalse(out.contains("width=\"100%\""), "the percentage width must be gone")
    }

    func testStandaloneSVGLeavesSizedRootAloneButAddsProlog() {
        // Graphviz / PlantUML already write absolute width/height, so the
        // viewBox must NOT overwrite them — only the prolog is added.
        let svg = "<svg width=\"120pt\" height=\"48pt\" viewBox=\"0.00 0.00 120.00 48.00\" "
            + "xmlns=\"http://www.w3.org/2000/svg\"><g/></svg>"
        let out = DiagramSVG.standaloneDocument(fromSVG: svg)
        XCTAssertTrue(out.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"))
        XCTAssertTrue(out.contains("width=\"120pt\""))
        XCTAssertTrue(out.contains("height=\"48pt\""))
        XCTAssertFalse(out.contains("width=\"120.00\""), "the viewBox must not resize a sized root")
    }

    func testStandaloneSVGAddsNamespaceWhenMissing() {
        // A root without a default namespace must gain one, without disturbing
        // an already-absolute size.
        let svg = "<svg viewBox=\"0 0 10 10\" width=\"10\" height=\"10\"><g/></svg>"
        let out = DiagramSVG.standaloneDocument(fromSVG: svg)
        XCTAssertTrue(out.contains("xmlns=\"http://www.w3.org/2000/svg\""))
        XCTAssertTrue(out.contains("width=\"10\""))
        XCTAssertTrue(out.contains("height=\"10\""))
        // A namespaced root is left with exactly one declaration.
        let already = DiagramSVG.standaloneDocument(fromSVG:
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"5\" height=\"5\"></svg>")
        XCTAssertEqual(already.components(separatedBy: "xmlns=").count - 1, 1)
    }

    // MARK: TextBundle / TextPack import + export (Feature 2)
    //
    // The pure pieces: the zip reader (stored + deflate), the info.json shape,
    // the export image-ref rewrite, the bundle assembly, and reading text.md
    // out of a directory FileWrapper / a zipped pack. The picker plumbing in
    // DocumentExport (and the read-only DocumentGroup open path) is not here.

    func testZipReaderParsesStoredArchive() {
        // A stored (uncompressed) archive built by the app's own EPUB writer:
        // the reader must walk its central directory and return each payload,
        // including a nested path.
        let a = Data([1, 2, 3, 4, 5])
        let b = Data("hello".utf8)
        let zip = StoredZip.archive([("a.bin", a), ("sub/b.txt", b)])
        let entries = ZipReader.entries(in: zip)
        XCTAssertEqual(entries?.count, 2)
        XCTAssertEqual(entries?.first(where: { $0.name == "a.bin" })?.data, a)
        XCTAssertEqual(entries?.first(where: { $0.name == "sub/b.txt" })?.data, b)
    }

    func testZipReaderInflatesDeflatedEntry() {
        // Real TextPacks deflate their entries; prove the inflate path against
        // a hand-built method-8 archive (a stored-only reader would miss it).
        let payload = Data(String(repeating: "abcABC123 the quick brown fox ", count: 40).utf8)
        let archive = deflatedArchive(name: "x/text.md", payload: payload)
        let entries = ZipReader.entries(in: archive)
        XCTAssertEqual(entries?.first?.name, "x/text.md")
        XCTAssertEqual(entries?.first?.data, payload)
    }

    func testZipReaderRejectsNonZip() {
        XCTAssertNil(ZipReader.entries(in: Data("not a zip at all".utf8)))
        XCTAssertNil(ZipReader.entries(in: Data()))
    }

    func testInfoJSONHasTheTextBundleShape() throws {
        let object = try JSONSerialization.jsonObject(
            with: Data(TextBundle.infoJSON.utf8)) as? [String: Any]
        XCTAssertEqual(object?["version"] as? Int, 2)
        XCTAssertEqual(object?["type"] as? String, "net.daringfireball.markdown")
        XCTAssertEqual(object?["transient"] as? Bool, false)
    }

    func testTextBundleImportReadsTextMarkdownWithEncoding() {
        // A `text.markdown` (the spec's other name) in a legacy encoding must
        // decode with the right encoding and round-trip byte-for-byte.
        let cyrillic = "Привет".data(using: .windowsCP1251)!
        let textFile = FileWrapper(regularFileWithContents: cyrillic)
        textFile.preferredFilename = "text.markdown"
        let bundle = FileWrapper(directoryWithFileWrappers: ["text.markdown": textFile])
        let result = TextBundle.textFromBundle(bundle)
        XCTAssertEqual(result?.0, "Привет")
        XCTAssertEqual(result?.1, .windowsCP1251)
        XCTAssertEqual(result?.0.data(using: result!.1), cyrillic)
    }

    func testTextBundleImportPrefersTextMd() {
        let md = FileWrapper(regularFileWithContents: Data("md\n".utf8))
        md.preferredFilename = "text.md"
        let markdown = FileWrapper(regularFileWithContents: Data("markdown\n".utf8))
        markdown.preferredFilename = "text.markdown"
        let bundle = FileWrapper(directoryWithFileWrappers:
            ["text.md": md, "text.markdown": markdown])
        XCTAssertEqual(TextBundle.textFromBundle(bundle)?.0, "md\n")
    }

    func testTextBundleImportNilWithoutATextFile() {
        let info = FileWrapper(regularFileWithContents: Data("{}".utf8))
        info.preferredFilename = "info.json"
        let bundle = FileWrapper(directoryWithFileWrappers: ["info.json": info])
        XCTAssertNil(TextBundle.textFromBundle(bundle))
    }

    func testTextPackImportReadsStoredZip() {
        // A pack wraps a `.textbundle` folder, so text.md is nested under it.
        let zip = StoredZip.archive([
            ("Doc.textbundle/info.json", Data(TextBundle.infoJSON.utf8)),
            ("Doc.textbundle/text.md", Data("# Packed\n".utf8)),
        ])
        let result = TextBundle.textFromPack(zip)
        XCTAssertEqual(result?.0, "# Packed\n")
        XCTAssertEqual(result?.1, .utf8)
    }

    func testTextPackImportReadsDeflatedZip() {
        let payload = "# Deflated\n\nSome longer body text to compress well.\n"
        let archive = deflatedArchive(name: "Doc.textbundle/text.md",
                                      payload: Data(payload.utf8))
        XCTAssertEqual(TextBundle.textFromPack(archive)?.0, payload)
    }

    func testTextPackImportRejectsNonZip() {
        XCTAssertNil(TextBundle.textFromPack(Data("plain text, not a pack".utf8)))
    }

    func testZipReaderInflatesOnlyTheEntriesTheCallerAsksFor() {
        // The memory-exhaustion defense: an entry the caller doesn't want is
        // listed by name but never inflated (nor allocated), so a hostile pack
        // full of huge deflate-bomb assets costs nothing to open — import reads
        // only `text.md`. Proven through the skip mechanism directly: the same
        // deflated archive yields real bytes when inflated and empty bytes when
        // skipped, and the name survives either way.
        let archive = deflatedArchive(name: "assets/big.bin",
                                      payload: Data(repeating: 0, count: 50_000))
        let inflated = ZipReader.entries(in: archive)
        XCTAssertEqual(inflated?.first?.data.count, 50_000, "control: it does inflate when asked")

        let skipped = ZipReader.entries(in: archive, shouldInflate: { _ in false })
        XCTAssertEqual(skipped?.first?.name, "assets/big.bin", "the entry is still listed")
        XCTAssertEqual(skipped?.first?.data.count, 0, "but its bytes were never allocated")

        // And end to end: a pack whose only inflated entry is text.md imports,
        // while its (skipped) assets are irrelevant to the outcome.
        let pack = StoredZip.archive([
            ("Doc.textbundle/text.md", Data("# Real\n".utf8)),
            ("Doc.textbundle/assets/x.png", Data(repeating: 0xFF, count: 10_000)),
        ])
        XCTAssertEqual(TextBundle.textFromPack(pack)?.0, "# Real\n")
    }

    func testExportCopiesFoundImageAndLeavesTheRestUntouched() {
        // A findable local ref is copied to assets/ and rewritten; an
        // unfindable local ref and a remote URL are left exactly as written.
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let source = "![cat](photo.png) ![dog](missing.png) ![web](https://e/x.png)"
        let result = TextBundle.exportRewriting(source: source) { path in
            path == "photo.png" ? png : nil
        }
        XCTAssertTrue(result.text.contains("![cat](assets/photo.png)"))
        XCTAssertTrue(result.text.contains("![dog](missing.png)"))
        XCTAssertTrue(result.text.contains("![web](https://e/x.png)"))
        XCTAssertEqual(result.assets, [TextBundle.Asset(name: "photo.png", data: png)])
    }

    func testExportKeepsImageTitleWhenRewriting() {
        // Only the URL is rewritten; a following "title" is preserved.
        let result = TextBundle.exportRewriting(source: "![alt](pic.png \"A cat\")") { _ in
            Data([1])
        }
        XCTAssertTrue(result.text.contains("![alt](assets/pic.png \"A cat\")"))
    }

    func testExportDedupesAssetNamesButReusesOnePathOnce() {
        // Two distinct paths sharing a file name get distinct assets; the same
        // path used again reuses its asset (copied once, both refs rewritten).
        let source = "![a](a/logo.png) ![b](b/logo.png) ![c](a/logo.png)"
        let result = TextBundle.exportRewriting(source: source) { _ in Data([7]) }
        XCTAssertEqual(result.assets.map(\.name), ["logo.png", "logo-2.png"])
        XCTAssertTrue(result.text.contains("![a](assets/logo.png)"))
        XCTAssertTrue(result.text.contains("![b](assets/logo-2.png)"))
        XCTAssertTrue(result.text.contains("![c](assets/logo.png)"))
    }

    func testLocalRelativeReferenceClassification() {
        XCTAssertTrue(TextBundle.isLocalRelativeReference("photo.png"))
        XCTAssertTrue(TextBundle.isLocalRelativeReference("images/photo.png"))
        XCTAssertFalse(TextBundle.isLocalRelativeReference("https://x/y.png"))
        XCTAssertFalse(TextBundle.isLocalRelativeReference("http://x/y.png"))
        XCTAssertFalse(TextBundle.isLocalRelativeReference("data:image/png;base64,AAAA"))
        XCTAssertFalse(TextBundle.isLocalRelativeReference("/abs/photo.png"))
        XCTAssertFalse(TextBundle.isLocalRelativeReference("#anchor"))
        XCTAssertFalse(TextBundle.isLocalRelativeReference(""))
    }

    func testBundleWrapperHoldsTextInfoAndAssets() {
        let assets = [TextBundle.Asset(name: "p.png", data: Data([1, 2]))]
        let wrapper = TextBundle.bundleWrapper(text: "# Hi\n", assets: assets)
        let children = wrapper.fileWrappers
        XCTAssertEqual(children?["text.md"]?.regularFileContents, Data("# Hi\n".utf8))
        XCTAssertNotNil(children?["info.json"]?.regularFileContents)
        let assetsDir = children?["assets"]
        XCTAssertEqual(assetsDir?.isDirectory, true)
        XCTAssertEqual(assetsDir?.fileWrappers?["p.png"]?.regularFileContents, Data([1, 2]))
    }

    func testBundleWrapperWithNoImagesStillCarriesEmptyAssets() {
        let wrapper = TextBundle.bundleWrapper(text: "plain\n", assets: [])
        let assetsDir = wrapper.fileWrappers?["assets"]
        XCTAssertEqual(assetsDir?.isDirectory, true)
        XCTAssertEqual(assetsDir?.fileWrappers?.isEmpty, true)
    }

    // A one-entry zip using DEFLATE (method 8), so the reader's inflate path is
    // exercised against a genuine compressed stream (the EPUB writer only
    // stores). Little-endian throughout; CRC-32 reuses the app's own table.
    private func deflatedArchive(name: String, payload: Data) -> Data {
        let compressed = deflate(payload)
        let nameBytes = [UInt8](name.utf8)
        let crc = StoredZip.crc32(payload)
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
             UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }

        var out = [UInt8]()
        // Local file header + compressed payload.
        out += le32(0x0403_4B50)
        out += le16(20) + le16(0) + le16(8)          // version / flags / method: deflate
        out += le16(0) + le16(0x21)                  // dos time / date
        out += le32(crc)
        out += le32(UInt32(compressed.count)) + le32(UInt32(payload.count))
        out += le16(nameBytes.count) + le16(0)       // name / extra length
        out += nameBytes
        out += [UInt8](compressed)

        // Central-directory file header.
        let centralStart = out.count
        out += le32(0x0201_4B50)
        out += le16(20) + le16(20) + le16(0) + le16(8)   // made-by / needed / flags / method
        out += le16(0) + le16(0x21)
        out += le32(crc)
        out += le32(UInt32(compressed.count)) + le32(UInt32(payload.count))
        out += le16(nameBytes.count) + le16(0) + le16(0) // name / extra / comment
        out += le16(0) + le16(0) + le32(0)               // disk / internal / external attrs
        out += le32(0)                                   // local header offset
        out += nameBytes
        let centralSize = out.count - centralStart

        // End of central directory.
        out += le32(0x0605_4B50)
        out += le16(0) + le16(0) + le16(1) + le16(1)     // disks / entries
        out += le32(UInt32(centralSize)) + le32(UInt32(centralStart))
        out += le16(0)                                   // comment length
        return Data(out)
    }

    /// Raw DEFLATE (no zlib header) — the symmetric encode to the reader's
    /// `COMPRESSION_ZLIB` decode, so a test archive matches a real one.
    private func deflate(_ data: Data) -> Data {
        let src = [UInt8](data)
        guard !src.isEmpty else { return Data() }
        var dst = [UInt8](repeating: 0, count: src.count + 128)
        let n = dst.withUnsafeMutableBufferPointer { d in
            src.withUnsafeBufferPointer { s in
                compression_encode_buffer(d.baseAddress!, d.count,
                                          s.baseAddress!, s.count, nil, COMPRESSION_ZLIB)
            }
        }
        return Data(dst.prefix(n))
    }
}

// Equatable conformance for assertions on alignment arrays.
extension ColumnAlignment: Equatable {}
