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
}

// Equatable conformance for assertions on alignment arrays.
extension ColumnAlignment: Equatable {}
