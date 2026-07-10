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

    // MARK: PDF layout setting (share / export pagination)

    @MainActor
    func testPDFLayoutDecodingDefaultsToSinglePage() {
        // Missing or unrecognized stored values keep today's behavior.
        XCTAssertEqual(PDFLayout.from(stored: nil), .single)
        XCTAssertEqual(PDFLayout.from(stored: "letter"), .single)
        // The two real choices round-trip (they're what AppStorage writes).
        XCTAssertEqual(PDFLayout.from(stored: "single"), .single)
        XCTAssertEqual(PDFLayout.from(stored: "a4"), .a4)
        XCTAssertEqual(PDFLayout.single.rawValue, "single")
        XCTAssertEqual(PDFLayout.a4.rawValue, "a4")
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
}

// Equatable conformance for assertions on alignment arrays.
extension ColumnAlignment: Equatable {}
