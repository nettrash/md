//
//  FindAndReplaceTests.swift
//  mdTests
//
//  Find and Replace in the editor pane.
//
//  The feature itself is one flag — `isFindInteractionEnabled` on the
//  text view — and everything a reader sees follows from it: the system
//  find panel with its Replace field, ⌘F / ⌘G / ⇧⌘G on a hardware
//  keyboard, and the Find items in the selection and Edit menus. So the
//  first thing tested is that the editor md actually builds has it on,
//  which is why `MarkdownEditor.configured()` exists as its own function.
//
//  The second thing is the part md has to get right around it. A replace
//  is *not* a keystroke: UIKit performs it, so `textViewDidChange` — the
//  call documented for a change made by the user — is not the path it
//  takes. Two consequences are checked here:
//
//    * the capital-override gesture (SPEC §3.4) hears about it anyway,
//      because it reads every edit off the text storage rather than off
//      the delegate — a replace lands exactly like a paste;
//    * the SwiftUI binding hears about it too, which is what marks the
//      document dirty and so what makes it autosave. That one runs with
//      the real find panel on screen, since the hook is gated on it.
//
//  Hosted: the test host is md.app, so UIKit is real.
//

import XCTest
import UIKit
@testable import md

@MainActor
final class FindAndReplaceTests: XCTestCase {

    // MARK: - The switch that is the feature

    func testTheEditorIsBuiltWithFindAndReplaceOn() {
        let view = MarkdownEditor.configured()
        XCTAssertTrue(view.isFindInteractionEnabled)
        XCTAssertNotNil(view.findInteraction,
                        "switching the flag on is what gives the view its find interaction")
    }

    /// The configuration moved out of `makeUIView` into `configured()`, and
    /// none of it may have been dropped on the way: this is Markdown
    /// *source*, and a smart quote or an en-dash in it is a corrupted file.
    func testTheEditorStillKeepsMarkdownPunctuationLiteral() {
        let view = MarkdownEditor.configured()
        XCTAssertEqual(view.smartQuotesType, .no)
        XCTAssertEqual(view.smartDashesType, .no)
        XCTAssertEqual(view.smartInsertDeleteType, .no)
        // md owns capitalization (§3.2); autocorrect stays on.
        XCTAssertEqual(view.autocapitalizationType, .none)
        XCTAssertEqual(view.autocorrectionType, .default)
        XCTAssertTrue(view.adjustsFontForContentSizeCategory)
        XCTAssertEqual(view.textContainer.lineFragmentPadding, 0)
    }

    /// Preview mode tears the editor pane down, and a chord can still
    /// arrive after it has. Asking for Find then is a no-op, not a crash.
    func testFindWithNoEditorPaneDoesNothing() {
        EditorController().presentFind()
    }

    // MARK: - The row has to reach the pane that is on screen (1.5)

    /// Find, driven the way the toolbar's row drives it: through
    /// `EditorController`, over a real editor in a real window.
    ///
    /// This is the half of the 1.5 report that read as "Find is not
    /// working". The command itself was never broken — what was broken was
    /// *which* editor the visible row reached (see
    /// `testFindDeclinesOnAPaneThatIsNotOnScreen` and
    /// `DocumentGenerationTests`) — so this pins the working half: the
    /// controller the on-screen pane wired itself to puts the panel up.
    func testFindPresentsThePanelOverTheEditorItIsWiredTo() throws {
        let window = try hostedWindow()
        defer { window.isHidden = true }
        let view = makeView("alpha beta alpha")
        let root = UIViewController()
        root.view = view
        window.rootViewController = root
        window.makeKeyAndVisible()

        let controller = EditorController()
        controller.attachForTesting(view)

        controller.presentFind()
        let interaction = try XCTUnwrap(view.findInteraction)
        try XCTSkipUnless(spin(until: { interaction.isFindNavigatorVisible }),
                          "this test host could not put the system find navigator on screen")
        interaction.dismissFindNavigator()
    }

    /// The failure that made Find look dead: a pane that is not in a window
    /// cannot present anything, so UIKit drops the request. The document
    /// view left behind by an open into the same scene is exactly that, and
    /// its Find row used to be the one in the bar.
    ///
    /// Asked for here is that the command declines rather than crashing —
    /// and, since a user-visible command must never *silently* do nothing,
    /// that it takes the deliberate "not on screen" exit. (The log it writes
    /// on the way out is the part a person reads; XCTest cannot assert on
    /// os_log, so what is pinned is the observable consequence.)
    func testFindDeclinesOnAPaneThatIsNotOnScreen() throws {
        let view = makeView("alpha beta alpha")
        XCTAssertNil(view.window, "the pane under test is deliberately detached")

        let controller = EditorController()
        controller.attachForTesting(view)

        controller.presentFind()

        let interaction = try XCTUnwrap(view.findInteraction)
        XCTAssertFalse(interaction.isFindNavigatorVisible,
                       "a detached pane has nothing to present over")
    }

    /// And the case the toolbar cannot reach but a chord can: the pane was
    /// torn down (Preview) while the controller lived on.
    func testFindDeclinesOnceThePaneHasGoneAway() {
        let controller = EditorController()
        autoreleasepool {
            let view = makeView("alpha")
            controller.attachForTesting(view)
        }
        // `textView` is weak; the pane is gone, and asking is still safe.
        controller.presentFind()
    }

    private func hostedWindow() throws -> UIWindow {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the hosted test host has a window scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        return window
    }

    // MARK: - A replace is an external edit

    private func makeView(_ text: String = "") -> SmartTextView {
        let view = MarkdownEditor.configured()
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        view.text = text
        view.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        return view
    }

    /// `[location, location + length)` of `view` as a `UITextRange` — the
    /// shape `replace(_:withText:)` takes, and the shape the find panel's
    /// own Replace hands it.
    private func range(of view: UITextView, _ location: Int, _ length: Int) -> UITextRange? {
        guard let from = view.position(from: view.beginningOfDocument, offset: location),
              let to = view.position(from: from, offset: length) else { return nil }
        return view.textRange(from: from, to: to)
    }

    func testReplacingMdsOwnCapitalArmsTheOverride() throws {
        let view = makeView()
        view.insertText("m")
        XCTAssertEqual(view.text, "M", "md capitalizes the first letter of a line")
        XCTAssertEqual(view.capitalOverride.capitalAt, 0)

        // What Replace does to the text: swap the found range for the
        // replacement. Nothing tells the override about it except the text
        // storage, which is the point.
        let match = try XCTUnwrap(range(of: view, 0, 1))
        view.replace(match, withText: "x")

        XCTAssertEqual(view.text, "x")
        XCTAssertNil(view.capitalOverride.capitalAt, "the tracked capital is gone")
        XCTAssertEqual(view.capitalOverride.armedAt, 0,
                       "and the edit that removed it arms the override at its slot, as a paste would")
    }

    func testAReplaceThatMissesTheCapitalLeavesItTracked() throws {
        let view = makeView()
        view.insertText("m")
        view.insertText("d")
        XCTAssertEqual(view.text, "Md")
        XCTAssertEqual(view.capitalOverride.capitalAt, 0)

        let match = try XCTUnwrap(range(of: view, 1, 1))
        view.replace(match, withText: "X")

        XCTAssertEqual(view.text, "MX")
        XCTAssertEqual(view.capitalOverride.capitalAt, 0,
                       "an edit after the capital does not disturb it")
    }

    /// Replace All is several edits, and each one is reported. The override
    /// must survive the run rather than be left pointing at an offset the
    /// replacements have moved.
    func testReplaceAllShiftsATrackedCapitalWithTheText() throws {
        let view = makeView()
        view.text = "aa bb aa"
        view.selectedRange = NSRange(location: 8, length: 0)
        view.insertText("\n")
        view.insertText("m")
        XCTAssertEqual(view.text, "aa bb aa\nM")
        XCTAssertEqual(view.capitalOverride.capitalAt, 9)

        // Every "aa" → "aaa", last match first, as a wrapping replace-all
        // walks the document.
        for location in [6, 0] {
            let match = try XCTUnwrap(range(of: view, location, 2))
            view.replace(match, withText: "aaa")
        }
        XCTAssertEqual(view.text, "aaa bb aaa\nM")
        XCTAssertEqual(view.capitalOverride.capitalAt, 11,
                       "the capital moved with the text in front of it")
    }

    // MARK: - The panel itself, and autosave after a replace

    /// The real find panel, on screen, over the real editor: presented the
    /// way the toolbar's Find row presents it, then a replace performed
    /// through it. What is asserted is the thing that would otherwise be
    /// silently lost — that the edit is pushed back out of the text view,
    /// which is what marks the document dirty and so what autosaves it.
    func testAReplaceThroughTheFindPanelIsPushedBackOut() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the hosted test host has a window scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let view = makeView("alpha beta alpha")
        let root = UIViewController()
        root.view = view
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        view.becomeFirstResponder()

        let interaction = try XCTUnwrap(view.findInteraction)
        // Replace on every platform, iPhone included — the toolbar row asks
        // for the Replace field, so the panel comes up with one.
        interaction.presentFindNavigator(showingReplace: true)
        try XCTSkipUnless(spin(until: { interaction.isFindNavigatorVisible }),
                          "this test host could not put the system find navigator on screen")
        defer { interaction.dismissFindNavigator() }

        var pushes = 0
        view.didEditWhileFinding = { pushes += 1 }

        let match = try XCTUnwrap(range(of: view, 0, 5))
        view.replace(match, withText: "omega")
        XCTAssertEqual(view.text, "omega beta alpha")

        XCTAssertTrue(spin(until: { pushes > 0 }),
                      "a replace has to reach the binding, or the document is never marked dirty")
    }

    /// Run the main run loop until `condition` holds, or ~2 seconds pass.
    private func spin(until condition: () -> Bool) -> Bool {
        for _ in 0 ..< 100 {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }
}
