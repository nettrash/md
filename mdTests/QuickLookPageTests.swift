//
//  QuickLookPageTests.swift
//  mdTests
//
//  The Quick Look extension's page: the app's own rendered document with
//  Mermaid and PlantUML left as captioned source, so the two heavy engines
//  are never loaded under the extension's memory ceiling.
//

import XCTest
@testable import md

final class QuickLookPageTests: XCTestCase {

    private func page(_ source: String) -> String {
        QuickLookPage.adapt(MarkdownHTML.document(source, title: "t", dark: false))
    }

    func testMermaidBecomesCaptionedSourceAndItsEngineIsNotLoaded() {
        let html = page("# T\n\n```mermaid\ngraph TD; A-->B;\n```\n")
        XCTAssertFalse(html.contains("<pre class=\"mermaid\">"))
        XCTAssertFalse(html.contains("rich/mermaid.min.js"))
        XCTAssertTrue(html.contains("<p class=\"md-ql-caption\">\(QuickLookPage.caption("Mermaid"))</p><pre>graph TD; A--&gt;B;</pre>"))
    }

    func testPlantUMLBecomesCaptionedSourceSoMdInitNeverImportsItsEngine() {
        // md-init.js imports PlantUML only when a `.plantuml` block exists.
        for source in ["```plantuml\n@startuml\nA -> B\n@enduml\n```\n", "@startuml\nA -> B\n@enduml\n"] {
            let html = page(source)
            XCTAssertFalse(html.contains("<div class=\"plantuml\">"), source)
            XCTAssertTrue(html.contains(QuickLookPage.caption("PlantUML")), source)
            XCTAssertTrue(html.contains("A -&gt; B"), source)
        }
    }

    func testLightEnginesAreUntouched() {
        let html = page("Math $x^2$.\n\n```dot\ndigraph { a -> b }\n```\n\n```swift\nlet x = 1\n```\n")
        XCTAssertTrue(html.contains("rich/katex.min.js"))
        XCTAssertTrue(html.contains("rich/viz-global.js"))
        XCTAssertTrue(html.contains("<div class=\"graphviz\""))
        XCTAssertTrue(html.contains("rich/highlight.min.js"))
        XCTAssertFalse(html.contains("md-ql-caption\">"))
    }

    func testAPlainDocumentOnlyGainsTheStylesheet() {
        let original = MarkdownHTML.document("# Plain\n\nText.\n", title: "t", dark: false)
        let adapted = QuickLookPage.adapt(original)
        XCTAssertEqual(adapted, original.replacingOccurrences(of: "</head>", with: QuickLookPage.style + "\n</head>"))
    }

    func testAQuotedBlockInACodeFenceIsLeftAlone() {
        // A code block that merely shows the markup is escaped by the renderer.
        let html = page("```html\n<pre class=\"mermaid\">x</pre>\n```\n")
        XCTAssertFalse(html.contains(QuickLookPage.caption("Mermaid")))
    }
}
