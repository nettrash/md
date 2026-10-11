//
//  EditorFormattingTests.swift
//  mdTests
//
//  The formatting commands through the real editor, as the Format menu, the
//  chords, the phone bar and a typed `*` reach it: `MarkdownEditor.perform`
//  and `MarkdownEditor.wrapTyped` over a hosted `SmartTextView`, with a
//  coordinator bound to a document's text. The rewriting itself is
//  `MarkdownFormatting`, whose vectors `FormattingTests` runs.
//

import SwiftUI
import UIKit
import XCTest
@testable import md

@MainActor
final class EditorFormattingTests: XCTestCase {

    /// The document's text, as the binding the editor writes back to.
    private final class Document { var text = "" }

    private func makeEditor(_ text: String, wrapSelection: Bool = true,
                            capitalize: Bool = false) throws
        -> (SmartTextView, MarkdownEditor.Coordinator, Document, UIWindow) {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the hosted test runs inside md's scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        let view = SmartTextView(frame: window.bounds)
        view.smartInsertDeleteType = .no
        view.capitalizeSentences = capitalize
        view.text = text
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.becomeFirstResponder()

        let document = Document()
        document.text = text
        var editor = MarkdownEditor(text: Binding(get: { document.text }, set: { document.text = $0 }),
                                    controller: EditorController())
        editor.wrapSelection = wrapSelection
        let coordinator = MarkdownEditor.Coordinator(editor)
        coordinator.textView = view
        return (view, coordinator, document, window)
    }

    /// One run-loop turn: what separates two real keystrokes, and what
    /// closes UIKit's per-event undo group.
    private func nextEvent() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }

    func testACommandIsOneUndoStepAndReachesTheDocument() throws {
        let (view, coordinator, document, window) = try makeEditor("say hello now")
        defer { window.isHidden = true }
        let undo = try XCTUnwrap(view.undoManager)
        view.selectedRange = NSRange(location: 4, length: 5)
        MarkdownEditor.perform(.bold, on: view, coordinator: coordinator)
        XCTAssertEqual(view.text, "say **hello** now")
        XCTAssertEqual(view.selectedRange, NSRange(location: 6, length: 5))
        XCTAssertEqual(document.text, "say **hello** now", "the binding hears of the edit")
        nextEvent()
        MarkdownEditor.perform(.heading2, on: view, coordinator: coordinator)
        XCTAssertEqual(view.text, "## say **hello** now")
        XCTAssertEqual(document.text, "## say **hello** now")
        nextEvent()
        undo.undo()
        XCTAssertEqual(view.text, "say **hello** now")
        undo.undo()
        XCTAssertEqual(view.text, "say hello now")
        XCTAssertFalse(undo.canUndo)
    }

    func testANoEditCommandChangesNothing() throws {
        let (view, coordinator, document, window) = try makeEditor("text")
        defer { window.isHidden = true }
        view.selectedRange = NSRange(location: 2, length: 0)
        MarkdownEditor.perform(.outdent, on: view, coordinator: coordinator)
        XCTAssertEqual(view.text, "text")
        XCTAssertEqual(document.text, "text")
        XCTAssertFalse(view.undoManager?.canUndo ?? false)
    }

    func testTypingOverASelectionWrapsItAsOneUndoStep() throws {
        let (view, coordinator, document, window) = try makeEditor("area pi r")
        defer { window.isHidden = true }
        view.interceptsInsertion = { MarkdownEditor.wrapTyped($0, on: view, coordinator: coordinator) }
        view.selectedRange = NSRange(location: 5, length: 4)
        view.insertText("$")
        XCTAssertEqual(view.text, "area $pi r$")
        XCTAssertEqual(view.selectedRange, NSRange(location: 6, length: 4))
        XCTAssertEqual(document.text, "area $pi r$")
        nextEvent()
        view.undoManager?.undo()
        XCTAssertEqual(view.text, "area pi r")
        XCTAssertFalse(view.undoManager?.canUndo ?? false)
    }

    func testWithTheSettingOffOrACaretTypingIsOrdinary() throws {
        let (view, coordinator, _, window) = try makeEditor("word", wrapSelection: false)
        defer { window.isHidden = true }
        view.interceptsInsertion = { MarkdownEditor.wrapTyped($0, on: view, coordinator: coordinator) }
        view.selectedRange = NSRange(location: 0, length: 4)
        view.insertText("*")
        XCTAssertEqual(view.text, "*")

        let (caretView, caretCoordinator, _, caretWindow) = try makeEditor("word")
        defer { caretWindow.isHidden = true }
        caretView.interceptsInsertion = { MarkdownEditor.wrapTyped($0, on: caretView, coordinator: caretCoordinator) }
        caretView.selectedRange = NSRange(location: 4, length: 0)
        caretView.insertText("*")
        XCTAssertEqual(caretView.text, "word*")
    }

    /// Formatting a word md has just capitalized is not the writer deleting
    /// that capital: `**Word**` must not arm the delete-and-retype override
    /// (§3.4) where `Word` began, or the next word typed there — straight
    /// after the command, or after its Undo — would skip the sentence rule.
    func testFormattingAFreshCapitalLeavesNoOverrideBehind() throws {
        for viaUndo in [false, true] {
            let (view, coordinator, _, window) = try makeEditor("", capitalize: true)
            defer { window.isHidden = true }
            view.insertText("word")
            nextEvent()
            XCTAssertEqual(view.text, "Word")
            XCTAssertTrue(view.capitalOverride.isTracking)

            view.selectedRange = NSRange(location: 0, length: 4)
            MarkdownEditor.perform(.bold, on: view, coordinator: coordinator)
            XCTAssertEqual(view.text, "**Word**")
            XCTAssertFalse(view.capitalOverride.isArmed, "the command armed the override")
            nextEvent()
            if viaUndo {
                view.undoManager?.undo()
                XCTAssertEqual(view.text, "Word")
                XCTAssertFalse(view.capitalOverride.isArmed, "the command's Undo armed the override")
            }

            view.selectedRange = NSRange(location: 0, length: 0)
            view.insertText("big")
            nextEvent()
            XCTAssertEqual(view.text, viaUndo ? "BigWord" : "Big**Word**", "viaUndo: \(viaUndo)")
        }
    }

    func testTypingAWrapOverAFreshCapitalLeavesNoOverrideBehind() throws {
        let (view, coordinator, _, window) = try makeEditor("", capitalize: true)
        defer { window.isHidden = true }
        view.interceptsInsertion = { MarkdownEditor.wrapTyped($0, on: view, coordinator: coordinator) }
        view.insertText("word")
        nextEvent()
        view.selectedRange = NSRange(location: 0, length: 4)
        view.insertText("*")
        XCTAssertEqual(view.text, "*Word*")
        XCTAssertFalse(view.capitalOverride.isArmed)
    }
}
