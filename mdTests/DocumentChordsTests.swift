//
//  DocumentChordsTests.swift
//  mdTests
//
//  Which document a chord acts on.
//
//  Found driving the real app for the 1.5 release check, on iOS 26.5 and
//  27.0 alike: open Welcome, then Formatting from the Examples menu, press
//  ⌘P — the print job is named "Welcome". Open a book article next and
//  ⌃⌘↓ steps from Welcome, which is not in the book, so nothing happens.
//  The hidden buttons that carry those chords are installed by every
//  document view alive in the scene, and the one key command SwiftUI
//  registers per chord reaches the *replaced* view's button. Gating the
//  buttons on the current document was tried and made things worse — the
//  key command goes with the button the system picked, and no chord was
//  installed at all after the second open. `DocumentChords` is the fix
//  that works: the buttons stay, and ask which document is current.
//

import XCTest
@testable import md

@MainActor
final class DocumentChordsTests: XCTestCase {

    private var token = ""

    override func setUp() {
        super.setUp()
        token = "test-scene-\(UUID().uuidString)"
    }

    override func tearDown() {
        DocumentChords.forget(scene: token)
        super.tearDown()
    }

    private func actions(_ log: @escaping (String) -> Void, name: String) -> DocumentChords.Actions {
        DocumentChords.Actions(
            print: { dark in log("\(name) print dark=\(dark)") },
            showBook: { log("\(name) showBook") },
            stepArticle: { log("\(name) step \($0)") })
    }

    /// Two documents opened into one scene, the second replacing the first
    /// on screen: whichever view's button fires, the second's actions run.
    func testTheNewestRegistrationWins() async {
        var log: [String] = []
        DocumentChords.register(actions({ log.append($0) }, name: "Welcome"), scene: token)
        DocumentChords.register(actions({ log.append($0) }, name: "Formatting"), scene: token)

        let current = DocumentChords.actions(scene: token)
        XCTAssertNotNil(current)
        await current?.print(true)
        current?.stepArticle(+1)
        current?.showBook()
        XCTAssertEqual(log, ["Formatting print dark=true", "Formatting step 1", "Formatting showBook"])
    }

    /// A second iPad window is a second scene: an open there must not
    /// change what a chord in the first window does.
    func testScenesAreIndependent() {
        var log: [String] = []
        let other = "test-scene-\(UUID().uuidString)"
        defer { DocumentChords.forget(scene: other) }
        DocumentChords.register(actions({ log.append($0) }, name: "A"), scene: token)
        DocumentChords.register(actions({ log.append($0) }, name: "B"), scene: other)

        DocumentChords.actions(scene: token)?.stepArticle(-1)
        DocumentChords.actions(scene: other)?.stepArticle(+1)
        XCTAssertEqual(log, ["A step -1", "B step 1"])
    }

    /// A view outside any scene — a hosted test window, where
    /// `@SceneStorage` never lands — has no token and gets nothing back, so
    /// it falls back to its own actions rather than another window's.
    func testNoTokenMeansNoRegistryEntry() {
        var log: [String] = []
        DocumentChords.register(actions({ log.append($0) }, name: "X"), scene: "")
        XCTAssertNil(DocumentChords.actions(scene: ""))
        XCTAssertNil(DocumentChords.actions(scene: "never-registered"))
        XCTAssertTrue(log.isEmpty)
    }
}
