//
//  SmartTypingAdapterTests.swift
//  mdTests
//
//  The iOS glue around `SmartTyping` (SPEC §3): the word-insertion
//  reduction, the override state machine, and `SmartTextView` itself.
//
//  The first two are pure and tested as such. The text-view tests run
//  hosted — the test host is md.app, so UIKit is real — on a
//  `SmartTextView` built off-screen, driven through the same
//  `insertText(_:)` / `deleteBackward()` entry points the keyboard uses
//  (and `replace(_:withText:)`, `cut(_:)` and `paste(_:)`, the paths Cut,
//  Paste, forward delete, Scribble and autocorrect take instead), and
//  assert the resulting text and caret. The undo, Cut and Paste tests put
//  the view in a window and make it first responder, because that is when
//  a `UITextView` owns an undo manager and answers the edit menu; Paste
//  lands asynchronously, so those wait for the text to change. Every
//  offset is a UTF-16 unit.
//

import XCTest
@testable import md

final class SmartTypingAdapterTests: XCTestCase {

    // MARK: - §3.3 Word-insertion reduction

    func testSingleLowercaseLetterIsAWordInsertion() {
        XCTAssertEqual(WordInsertion.firstScalar(of: "h"), "h")
    }

    func testWordYieldsItsFirstScalar() {
        XCTAssertEqual(WordInsertion.firstScalar(of: "hello"), "h")
        XCTAssertEqual(WordInsertion.firstScalar(of: "école"), "é")
    }

    func testOneTrailingSpaceIsAllowed() {
        // The predictive bar inserts `word ` — one trailing SP, nothing else.
        XCTAssertEqual(WordInsertion.firstScalar(of: "hello "), "h")
        XCTAssertNil(WordInsertion.firstScalar(of: "hello  "))
        XCTAssertNil(WordInsertion.firstScalar(of: " hello"))
        XCTAssertNil(WordInsertion.firstScalar(of: "hello\u{00A0}"))    // NBSP is WS19, not SP
        XCTAssertNil(WordInsertion.firstScalar(of: "hel\tlo"))
    }

    func testPhrasesAndLineBreaksAreNotWordInsertions() {
        XCTAssertNil(WordInsertion.firstScalar(of: "hello world"))
        XCTAssertNil(WordInsertion.firstScalar(of: "hello\n"))
        XCTAssertNil(WordInsertion.firstScalar(of: "\n"))
        XCTAssertNil(WordInsertion.firstScalar(of: "a\rb"))
        XCTAssertNil(WordInsertion.firstScalar(of: ""))
    }

    func testFirstScalarMustBeLowercaseLetter() {
        XCTAssertNil(WordInsertion.firstScalar(of: "Hello"))
        XCTAssertNil(WordInsertion.firstScalar(of: "1abc"))
        XCTAssertNil(WordInsertion.firstScalar(of: "-item"))
        XCTAssertNil(WordInsertion.firstScalar(of: "\u{0301}e"))          // a mark first
        XCTAssertNil(WordInsertion.firstScalar(of: "ǅ"))                  // Lt, not Ll
    }

    func testURLsPathsAndHandlesAreInsertedUnchanged() {
        XCTAssertNil(WordInsertion.firstScalar(of: "https://a.b"))
        XCTAssertNil(WordInsertion.firstScalar(of: "www.example.org"))
        XCTAssertNil(WordInsertion.firstScalar(of: "a/b"))
        XCTAssertNil(WordInsertion.firstScalar(of: "nettrash@nettrash.me"))
        XCTAssertNil(WordInsertion.firstScalar(of: "@nettrash"))
    }

    func testFirstScalarIsAScalarNotAGrapheme() {
        // NFD `é` is `e` + U+0301: the first *scalar* is `e`.
        XCTAssertEqual(WordInsertion.firstScalar(of: "e\u{0301}cole"), "e")
        // A non-BMP lowercase letter (DESERET SMALL LETTER LONG I) is one
        // scalar of two units.
        let deseret = WordInsertion.firstScalar(of: "\u{10428}x")
        XCTAssertEqual(deseret, "\u{10428}")
        XCTAssertEqual(deseret?.utf16.count, 2)
    }

    func testMicroSignIsReducedAndLeftToCapitalize() {
        // The reduction only asks "is it Ll"; §0.7's exclusions (µ, Georgian,
        // ypogegrammeni) are `capitalize`'s, which returns nil for them.
        XCTAssertEqual(WordInsertion.firstScalar(of: "µs"), "µ")
        XCTAssertNil(SmartTyping.capitalize("", selectionStart: 0, selectionEnd: 0, typed: "µ"))
    }

    func testReplacingFirstScalar() {
        XCTAssertEqual(WordInsertion.replacingFirstScalar(of: "hello ", with: "H"), "Hello ")
        XCTAssertEqual(WordInsertion.replacingFirstScalar(of: "h", with: "H"), "H")
        XCTAssertEqual(WordInsertion.replacingFirstScalar(of: "\u{10428}x", with: "\u{10400}"), "\u{10400}x")
        XCTAssertEqual(WordInsertion.replacingFirstScalar(of: "e\u{0301}", with: "E"), "E\u{0301}")
    }

    // MARK: - §3.4 last sentence: a letter typed over its own capital

    func testRetypingOwnCapitalIsRecognised() {
        XCTAssertTrue(WordInsertion.retypesOwnCapital(selected: "M", typed: "m"))
        XCTAssertTrue(WordInsertion.retypesOwnCapital(selected: "É", typed: "é"))
        XCTAssertTrue(WordInsertion.retypesOwnCapital(selected: "\u{10400}", typed: "\u{10428}"))
    }

    func testRetypingSomethingElseIsNot() {
        XCTAssertFalse(WordInsertion.retypesOwnCapital(selected: "N", typed: "m"))
        XCTAssertFalse(WordInsertion.retypesOwnCapital(selected: "m", typed: "m"))
        XCTAssertFalse(WordInsertion.retypesOwnCapital(selected: "Md", typed: "m"))    // two scalars
        XCTAssertFalse(WordInsertion.retypesOwnCapital(selected: "M", typed: "mm"))
        XCTAssertFalse(WordInsertion.retypesOwnCapital(selected: "M", typed: "M"))     // not Ll
        XCTAssertFalse(WordInsertion.retypesOwnCapital(selected: "SS", typed: "ß"))    // full mapping, 2 scalars
        XCTAssertFalse(WordInsertion.retypesOwnCapital(selected: "", typed: "m"))
        XCTAssertFalse(WordInsertion.retypesOwnCapital(selected: "M", typed: ""))
    }

    // MARK: - §3.4 Override state machine: the tracked capital and the armed offset

    private func units(_ s: String) -> [UInt16] { Array(s.utf16) }
    private func range(_ location: Int, _ length: Int) -> NSRange { NSRange(location: location, length: length) }

    func testOverrideStartsIdle() {
        var o = CapitalOverride()
        XCTAssertFalse(o.isTracking)
        XCTAssertFalse(o.isArmed)
        XCTAssertFalse(o.overrides(range(0, 0), inserting: units("m")))
        o.edit(range(0, 3), inserted: [], isWordInsertion: false)
        o.edit(range(0, 0), inserted: units("abc"), isWordInsertion: true)
        XCTAssertEqual(o, CapitalOverride(), "nothing tracked, nothing armed: edits change nothing")
    }

    func testProducedTracksTheCapitalAndArmsNothing() {
        var o = CapitalOverride()
        o.produced(at: 4, capital: units("M"))
        XCTAssertTrue(o.isTracking)
        XCTAssertEqual(o.capitalAt, 4)
        XCTAssertEqual(o.capital, units("M"))
        XCTAssertFalse(o.isArmed)
        XCTAssertFalse(o.overrides(range(4, 0), inserting: units("a")),
                       "a letter in front of a standing capital is ordinary typing")
    }

    func testANewCapitalReplacesTheTrackedOneForgottenNotArmed() {
        var o = CapitalOverride()
        o.produced(at: 0, capital: units("M"))
        o.produced(at: 5, capital: units("D"))
        XCTAssertEqual(o.capitalAt, 5)
        XCTAssertEqual(o.capital, units("D"))
        XCTAssertFalse(o.isArmed)
        // The old one is not even remembered: deleting it arms nothing…
        o.edit(range(0, 1), inserted: [], isWordInsertion: false)
        XCTAssertFalse(o.isArmed)
        XCTAssertEqual(o.capitalAt, 4, "…but the deletion before p shifted p")
    }

    func testEditBeforeTheCapitalShiftsItByTheDelta() {
        var o = CapitalOverride()
        o.produced(at: 5, capital: units("M"))
        o.edit(range(0, 0), inserted: units("Abc. "), isWordInsertion: false)    // an insertion before it
        XCTAssertEqual(o.capitalAt, 10)
        o.edit(range(0, 5), inserted: [], isWordInsertion: false)                // a deletion before it
        XCTAssertEqual(o.capitalAt, 5)
        o.edit(range(1, 2), inserted: units("xyz"), isWordInsertion: false)      // a replacement before it: +1
        XCTAssertEqual(o.capitalAt, 6)
        o.edit(range(4, 2), inserted: [], isWordInsertion: false)                // ending exactly at p: still before
        XCTAssertEqual(o.capitalAt, 4)
        o.edit(range(4, 0), inserted: units("a"), isWordInsertion: true)         // *at* p: the capital is pushed right
        XCTAssertEqual(o.capitalAt, 5)
        XCTAssertFalse(o.isArmed)
    }

    func testEditAfterTheCapitalLeavesItAlone() {
        var o = CapitalOverride()
        o.produced(at: 2, capital: units("M"))
        o.edit(range(3, 0), inserted: units("d"), isWordInsertion: true)
        o.edit(range(3, 1), inserted: [], isWordInsertion: false)
        o.edit(range(3, 0), inserted: units("hello world"), isWordInsertion: false)
        XCTAssertEqual(o.capitalAt, 2)
        XCTAssertFalse(o.isArmed)
    }

    func testDeletingTheCapitalArmsTheOverrideAtTheEditsStart() {
        var o = CapitalOverride()
        o.produced(at: 4, capital: units("M"))
        o.edit(range(4, 1), inserted: [], isWordInsertion: false)           // ⌫ over it, or ⌦
        XCTAssertFalse(o.isTracking)
        XCTAssertEqual(o.capital, [])
        XCTAssertEqual(o.armedAt, 4)
        // A wider deletion: armed at its start, where the retype lands.
        o.produced(at: 4, capital: units("M"))
        o.edit(range(1, 5), inserted: [], isWordInsertion: false)
        XCTAssertEqual(o.armedAt, 1)
        XCTAssertFalse(o.isTracking)
    }

    func testReplacingTheCapitalArmsTheOverrideAtTheEditsStart() {
        var o = CapitalOverride()
        o.produced(at: 0, capital: units("I"))
        // Autocorrect turns `Ios` into `iOS`: the capital is gone.
        o.edit(range(0, 3), inserted: units("iOS"), isWordInsertion: false)
        XCTAssertFalse(o.isTracking)
        XCTAssertEqual(o.armedAt, 0)
        // A selection typed over — `Md` → `md` — is the word rule's own
        // edit: it removes the capital (so it is inserted as typed) and
        // the same word insertion at q spends the override it just armed.
        o.produced(at: 0, capital: units("M"))
        XCTAssertTrue(o.overrides(range(0, 2), inserting: units("md")))
        o.edit(range(0, 2), inserted: units("md"), isWordInsertion: true)
        XCTAssertEqual(o, CapitalOverride())
    }

    func testAReplacementThatPutsTheCapitalBackKeepsIt() {
        var o = CapitalOverride()
        o.produced(at: 1, capital: units("M"))
        o.edit(range(0, 3), inserted: units("xMy"), isWordInsertion: false)      // same capital, same offset
        XCTAssertEqual(o.capitalAt, 1)
        XCTAssertFalse(o.isArmed)
        XCTAssertFalse(o.overrides(range(0, 3), inserting: units("aMz")))
        o.edit(range(1, 1), inserted: units("M"), isWordInsertion: false)        // the capital typed over itself
        XCTAssertEqual(o.capitalAt, 1)
        o.edit(range(0, 3), inserted: units("xmy"), isWordInsertion: false)      // lowercase there now: removed
        XCTAssertFalse(o.isTracking)
        XCTAssertEqual(o.armedAt, 0)
    }

    func testWordInsertionAtQGoesInAsTypedAndSpendsTheOverride() {
        var o = CapitalOverride()
        o.produced(at: 4, capital: units("M"))
        o.edit(range(4, 1), inserted: [], isWordInsertion: false)
        XCTAssertTrue(o.overrides(range(4, 0), inserting: units("m")))
        o.edit(range(4, 0), inserted: units("m"), isWordInsertion: true)
        XCTAssertFalse(o.isArmed)
        XCTAssertEqual(o, CapitalOverride(), "spent: nothing remembered")
        XCTAssertFalse(o.overrides(range(4, 0), inserting: units("m")), "only once")
    }

    func testNonWordInsertionAtQKeepsItArmed() {
        var o = CapitalOverride()
        o.produced(at: 4, capital: units("M"))
        o.edit(range(4, 1), inserted: [], isWordInsertion: false)
        o.edit(range(4, 0), inserted: units("\n"), isWordInsertion: false)      // Return
        o.edit(range(4, 0), inserted: units("42"), isWordInsertion: false)      // a paste, a digit
        XCTAssertEqual(o.armedAt, 4)
    }

    func testInsertionElsewhereClearsTheOverride() {
        var o = CapitalOverride()
        o.produced(at: 4, capital: units("M"))
        o.edit(range(4, 1), inserted: [], isWordInsertion: false)
        o.edit(range(5, 0), inserted: units("d"), isWordInsertion: true)        // after q
        XCTAssertFalse(o.isArmed)
        o.produced(at: 4, capital: units("M"))
        o.edit(range(4, 1), inserted: [], isWordInsertion: false)
        o.edit(range(0, 0), inserted: units("Abc. "), isWordInsertion: false)   // a paste before q
        XCTAssertFalse(o.isArmed)
        o.produced(at: 4, capital: units("M"))
        o.edit(range(4, 1), inserted: [], isWordInsertion: false)
        o.edit(range(2, 3), inserted: units("z"), isWordInsertion: true)        // a replacement over q, from before it
        XCTAssertFalse(o.isArmed)
        XCTAssertEqual(o, CapitalOverride())
    }

    func testDeletionsNeverClearButKeepQOnTheSlot() {
        var o = CapitalOverride()
        o.produced(at: 4, capital: units("M"))
        o.edit(range(4, 1), inserted: [], isWordInsertion: false)
        XCTAssertEqual(o.armedAt, 4)
        o.edit(range(6, 3), inserted: [], isWordInsertion: false)      // after q: nothing
        XCTAssertEqual(o.armedAt, 4)
        o.edit(range(4, 1), inserted: [], isWordInsertion: false)      // starting at q: q stays
        XCTAssertEqual(o.armedAt, 4)
        o.edit(range(1, 2), inserted: [], isWordInsertion: false)      // wholly before q: shifts
        XCTAssertEqual(o.armedAt, 2)
        o.edit(range(1, 5), inserted: [], isWordInsertion: false)      // covering q: moves to its start
        XCTAssertEqual(o.armedAt, 1)
        o.edit(range(0, 0), inserted: [], isWordInsertion: false)      // nothing at all
        XCTAssertEqual(o.armedAt, 1)
        XCTAssertTrue(o.isArmed)
    }

    func testClearDropsBoth() {
        var o = CapitalOverride()
        o.produced(at: 2, capital: units("M"))
        o.clear()
        XCTAssertEqual(o, CapitalOverride())
        o.produced(at: 2, capital: units("M"))
        o.edit(range(2, 1), inserted: [], isWordInsertion: false)
        o.clear()
        XCTAssertEqual(o, CapitalOverride())
    }

    func testUndoOfTheCapitalRemovesItAndArms() {
        var o = CapitalOverride()
        o.produced(at: 7, capital: units("W"))
        o.capitalUndone(at: 7)
        XCTAssertFalse(o.isTracking)
        XCTAssertEqual(o.armedAt, 7)
        XCTAssertTrue(o.overrides(range(7, 0), inserting: units("w")))
        // Redo produces it again: tracked, not armed.
        o.produced(at: 7, capital: units("W"))
        XCTAssertEqual(o.capitalAt, 7)
        XCTAssertFalse(o.isArmed)
        // Undo of an older capital while a newer one stands elsewhere: it
        // arms at its own slot and leaves the tracked capital alone.
        o.capitalUndone(at: 0)
        XCTAssertEqual(o.capitalAt, 7)
        XCTAssertEqual(o.armedAt, 0)
    }

    func testTwoUnitCapitalIsTrackedWhole() {
        // DESERET CAPITAL LETTER LONG I is one scalar of two units.
        var o = CapitalOverride()
        o.produced(at: 3, capital: units("\u{10400}"))
        o.edit(range(5, 0), inserted: units("x"), isWordInsertion: true)          // right after it
        XCTAssertEqual(o.capitalAt, 3)
        o.edit(range(0, 3), inserted: units("a"), isWordInsertion: false)         // before: −2
        XCTAssertEqual(o.capitalAt, 1)
        o.edit(range(0, 3), inserted: units("a\u{10400}"), isWordInsertion: false) // put back at 1
        XCTAssertEqual(o.capitalAt, 1)
        XCTAssertFalse(o.isArmed)
        o.edit(range(1, 2), inserted: units("\u{10428}"), isWordInsertion: false)  // its lowercase over it
        XCTAssertFalse(o.isTracking)
        XCTAssertEqual(o.armedAt, 1)
    }

    func testPureSequenceFiveKeystrokesAfterTheCapitalThenFiveBackspaces() {
        // Consequence (3) on the state machine alone.
        var o = CapitalOverride()
        o.produced(at: 0, capital: units("M"))
        for (i, key) in ["d", " ", "i", "s"].enumerated() {
            o.edit(range(1 + i, 0), inserted: units(key), isWordInsertion: key != " ")
        }
        XCTAssertEqual(o.capitalAt, 0)
        for i in stride(from: 4, through: 1, by: -1) {
            o.edit(range(i, 1), inserted: [], isWordInsertion: false)
        }
        XCTAssertEqual(o.capitalAt, 0)
        XCTAssertFalse(o.isArmed)
        o.edit(range(0, 1), inserted: [], isWordInsertion: false)
        XCTAssertEqual(o.armedAt, 0)
        XCTAssertTrue(o.overrides(range(0, 0), inserting: units("m")))
    }

    func testPureSequenceCutBeforeThenBackspaceAndRetype() {
        // Consequence (7): `Xxx. M` (p = 5) → Cut `Xxx. ` → `M` (p = 0) → ⌫ → retype.
        var o = CapitalOverride()
        o.produced(at: 5, capital: units("M"))
        o.edit(range(0, 5), inserted: [], isWordInsertion: false)
        XCTAssertEqual(o.capitalAt, 0)
        o.edit(range(0, 1), inserted: [], isWordInsertion: false)
        XCTAssertEqual(o.armedAt, 0)
        XCTAssertTrue(o.overrides(range(0, 0), inserting: units("m")))
    }

    // MARK: - SmartTextView, hosted

    private func makeView(_ text: String = "", caret: Int? = nil) -> SmartTextView {
        let view = SmartTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        // As the pane configures it: this is Markdown source, so UIKit's
        // smart insert (which pads a paste with spaces, or a paragraph
        // break at a paragraph start) is off. `SmartTextView` itself sets
        // only what §3.2 makes its own.
        view.smartInsertDeleteType = .no
        view.text = text
        view.selectedRange = NSRange(location: caret ?? (text as NSString).length, length: 0)
        return view
    }

    func testViewOwnsCapitalization() {
        let view = makeView()
        XCTAssertEqual(view.autocapitalizationType, .none)
        XCTAssertEqual(view.autocorrectionType, .default)
        XCTAssertTrue(view.continueLists)
        XCTAssertTrue(view.capitalizeSentences)
        // The pane builds it with the no-argument initializer.
        let bare = SmartTextView()
        XCTAssertEqual(bare.autocapitalizationType, .none)
        bare.insertText("h")
        XCTAssertEqual(bare.text, "H")
    }

    func testEnterContinuesAListItem() {
        let view = makeView("- item")
        view.insertText("\n")
        XCTAssertEqual(view.text, "- item\n- ")
        XCTAssertEqual(view.selectedRange, NSRange(location: 9, length: 0))
    }

    func testEnterOnAnEmptyItemEndsTheList() {
        let view = makeView("- item\n- ")
        view.insertText("\n")
        XCTAssertEqual(view.text, "- item\n")
        XCTAssertEqual(view.selectedRange, NSRange(location: 7, length: 0))
    }

    func testEnterInProseIsAPlainNewline() {
        let view = makeView("hello")
        view.insertText("\n")
        XCTAssertEqual(view.text, "hello\n")
        XCTAssertEqual(view.selectedRange, NSRange(location: 6, length: 0))
    }

    func testFirstLetterInAnEmptyViewIsCapitalized() {
        let view = makeView()
        view.insertText("h")
        XCTAssertEqual(view.text, "H")
        XCTAssertEqual(view.selectedRange, NSRange(location: 1, length: 0))
    }

    func testAWordInsertionGetsOnlyItsFirstScalarCapitalized() {
        let view = makeView()
        view.insertText("hello ")
        XCTAssertEqual(view.text, "Hello ")
        XCTAssertEqual(view.selectedRange, NSRange(location: 6, length: 0))
    }

    func testSentenceStartMidLineIsCapitalized() {
        let view = makeView("Done. ")
        view.insertText("n")
        XCTAssertEqual(view.text, "Done. N")
    }

    func testNoCapitalInsideAFence() {
        let view = makeView("```\n")
        view.insertText("h")
        XCTAssertEqual(view.text, "```\nh")
    }

    func testTypingReplacesASelection() {
        let view = makeView("hello world")
        view.selectedRange = NSRange(location: 0, length: 5)
        view.insertText("bye")
        XCTAssertEqual(view.text, "Bye world")
        XCTAssertEqual(view.selectedRange, NSRange(location: 3, length: 0))
    }

    func testContinueListsOffNeverCallsEnter() {
        let view = makeView("- item")
        view.continueLists = false
        view.insertText("\n")
        XCTAssertEqual(view.text, "- item\n")
    }

    func testCapitalizeSentencesOffNeverCallsCapitalize() {
        let view = makeView()
        view.capitalizeSentences = false
        view.insertText("h")
        XCTAssertEqual(view.text, "h")
        XCTAssertEqual(view.capitalOverride, CapitalOverride())
    }

    func testSettingsAreReadLive() {
        let view = makeView()
        view.capitalizeSentences = false
        view.insertText("hello")
        view.capitalizeSentences = true
        view.insertText(". ")
        view.insertText("i")
        XCTAssertEqual(view.text, "hello. I")
    }

    // MARK: §3.4 The eight consequences, on the view

    func testConsequence1BackspaceTheWordAndRetypeIt() {
        // type "md" → "Md"; ⌫ ⌫; type "md" → "md".
        let view = makeView()
        view.insertText("m")
        view.insertText("d")
        XCTAssertEqual(view.text, "Md")
        XCTAssertEqual(view.capitalOverride.capitalAt, 0)
        XCTAssertFalse(view.capitalOverride.isArmed)
        view.deleteBackward()
        XCTAssertEqual(view.capitalOverride.capitalAt, 0, "the d went; the capital still stands")
        XCTAssertFalse(view.capitalOverride.isArmed)
        view.deleteBackward()
        XCTAssertEqual(view.text, "")
        XCTAssertFalse(view.capitalOverride.isTracking)
        XCTAssertEqual(view.capitalOverride.armedAt, 0, "the capital went: armed at its slot")
        view.insertText("m")
        view.insertText("d")
        XCTAssertEqual(view.text, "md")
        XCTAssertEqual(view.capitalOverride, CapitalOverride(), "spent, and no capital produced")
    }

    func testConsequence2ThreeBackspacesOverAMixedCaseWord() {
        // type "iOS" → "IOS"; ⌫ ⌫ ⌫; type "iOS" → "iOS".
        let view = makeView()
        for key in ["i", "O", "S"] { view.insertText(key) }
        XCTAssertEqual(view.text, "IOS")
        XCTAssertEqual(view.capitalOverride.capitalAt, 0)
        for _ in 0..<3 { view.deleteBackward() }
        XCTAssertEqual(view.text, "")
        XCTAssertEqual(view.capitalOverride.armedAt, 0)
        for key in ["i", "O", "S"] { view.insertText(key) }
        XCTAssertEqual(view.text, "iOS")
        XCTAssertEqual(view.capitalOverride, CapitalOverride())
    }

    func testConsequence3FiveKeystrokesAfterTheCapitalThenFiveBackspaces() {
        // type "Md is"; five ⌫; type "md is" → "md is".
        let view = makeView()
        for key in ["m", "d", " ", "i", "s"] { view.insertText(key) }
        XCTAssertEqual(view.text, "Md is")
        XCTAssertEqual(view.capitalOverride.capitalAt, 0)
        for _ in 0..<5 { view.deleteBackward() }
        XCTAssertEqual(view.text, "")
        XCTAssertEqual(view.capitalOverride.armedAt, 0)
        for key in ["m", "d", " ", "i", "s"] { view.insertText(key) }
        XCTAssertEqual(view.text, "md is")
    }

    func testConsequence4SelectTheWholeWordAndTypeItAgain() {
        // select the whole word "Md" and type "md" → "md".
        let view = makeView()
        view.insertText("m")
        view.insertText("d")
        XCTAssertEqual(view.text, "Md")
        view.selectedRange = NSRange(location: 0, length: 2)
        view.insertText("md")
        XCTAssertEqual(view.text, "md")
        XCTAssertEqual(view.selectedRange, NSRange(location: 2, length: 0))
        XCTAssertEqual(view.capitalOverride, CapitalOverride(),
                       "the replacement removed the capital and the same word insertion spent the override")
        // With no capital of md's left, the rule decides again: the same
        // selection typed over once more is a sentence start.
        view.selectedRange = NSRange(location: 0, length: 2)
        view.insertText("md")
        XCTAssertEqual(view.text, "Md")
        XCTAssertEqual(view.capitalOverride.capitalAt, 0)
    }

    func testConsequence5ALetterInFrontOfAStandingCapitalIsCapitalized() {
        // after "M", place the caret before the M and type "a" → "AM": the
        // capital was not deleted; it shifts right, and the new capital
        // replaces it as the tracked one.
        let view = makeView()
        view.insertText("m")
        XCTAssertEqual(view.text, "M")
        view.selectedRange = NSRange(location: 0, length: 0)
        view.insertText("a")
        XCTAssertEqual(view.text, "AM")
        XCTAssertEqual(view.selectedRange, NSRange(location: 1, length: 0))
        XCTAssertEqual(view.capitalOverride.capitalAt, 0)
        XCTAssertEqual(view.capitalOverride.capital, Array("A".utf16))
        XCTAssertFalse(view.capitalOverride.isArmed)
        // The shift itself, pinned with something that produces no capital:
        // a digit in front of the tracked capital moves p to p + 1.
        view.selectedRange = NSRange(location: 0, length: 0)
        view.insertText("5")
        XCTAssertEqual(view.text, "5AM")
        XCTAssertEqual(view.capitalOverride.capitalAt, 1)
        XCTAssertFalse(view.capitalOverride.isArmed)
        // Delete that capital and type at its slot: now it is the gesture.
        view.selectedRange = NSRange(location: 2, length: 0)
        view.deleteBackward()
        XCTAssertEqual(view.text, "5M")
        XCTAssertEqual(view.capitalOverride.armedAt, 1)
        view.insertText("a")
        XCTAssertEqual(view.text, "5aM")
        XCTAssertFalse(view.capitalOverride.isArmed)
    }

    func testConsequence8DeletingTheLetterAfterTheCapitalArmsNothing() {
        // type "m" → "M", "d" → "Md", ⌫ (deletes d), "d" → "Md".
        let view = makeView()
        view.insertText("m")
        XCTAssertEqual(view.text, "M")
        view.insertText("d")
        XCTAssertEqual(view.text, "Md")
        view.deleteBackward()
        XCTAssertEqual(view.text, "M")
        XCTAssertEqual(view.capitalOverride.capitalAt, 0, "the capital still stands")
        XCTAssertFalse(view.capitalOverride.isArmed, "nothing armed")
        view.insertText("d")
        XCTAssertEqual(view.text, "Md")
        XCTAssertEqual(view.capitalOverride.capitalAt, 0)
        XCTAssertFalse(view.capitalOverride.isArmed)
    }

    // (6) and (7) need a hosted view — Undo and Cut — and follow below.

    // MARK: §3.4 The override gesture, on the view

    func testCapitalIsTrackedNotArmed() {
        let view = makeView()
        view.insertText("h")
        XCTAssertEqual(view.capitalOverride.capitalAt, 0)
        XCTAssertEqual(view.capitalOverride.capital, Array("H".utf16))
        XCTAssertFalse(view.capitalOverride.isArmed)
    }

    func testBackspaceAndRetypeKeepsTheLowercase() {
        let view = makeView()
        view.insertText("m")
        XCTAssertEqual(view.text, "M")
        view.deleteBackward()
        XCTAssertEqual(view.text, "")
        XCTAssertTrue(view.capitalOverride.isArmed, "deleting the capital arms the override")
        view.insertText("m")
        XCTAssertEqual(view.text, "m")
        XCTAssertFalse(view.capitalOverride.isArmed, "the override is spent")
        view.insertText("d")
        XCTAssertEqual(view.text, "md")
    }

    func testTypingOnKeepsTheCapitalTracked() {
        let view = makeView()
        view.insertText("m")
        view.insertText("d")
        XCTAssertEqual(view.text, "Md")
        XCTAssertEqual(view.capitalOverride.capitalAt, 0)
        XCTAssertFalse(view.capitalOverride.isArmed)
        // A new sentence's capital replaces it; the old one is forgotten.
        view.insertText(". ")
        view.insertText("i")
        XCTAssertEqual(view.text, "Md. I")
        XCTAssertEqual(view.capitalOverride.capitalAt, 4)
        XCTAssertEqual(view.capitalOverride.capital, Array("I".utf16))
    }

    func testSelectAndRetypeOwnCapitalIsAlwaysAsTyped() {
        // Not a capital of md's (the text was set, not typed): §3.4's last
        // sentence applies on its own, and nothing is armed afterwards.
        let view = makeView("Md is")
        view.selectedRange = NSRange(location: 0, length: 1)
        view.insertText("m")
        XCTAssertEqual(view.text, "md is")
        XCTAssertEqual(view.selectedRange, NSRange(location: 1, length: 0))
        XCTAssertEqual(view.capitalOverride, CapitalOverride())
    }

    func testSelectAndRetypeTheTrackedCapitalRemovesIt() {
        let view = makeView()
        view.insertText("m")
        view.insertText("d")
        view.selectedRange = NSRange(location: 0, length: 1)
        view.insertText("m")
        XCTAssertEqual(view.text, "md")
        XCTAssertFalse(view.capitalOverride.isTracking, "the replacement removed the capital")
        XCTAssertFalse(view.capitalOverride.isArmed, "and the letter typed at its slot spent the override")
        view.selectedRange = NSRange(location: 2, length: 0)
        view.insertText(" ")
        view.insertText("x")
        XCTAssertEqual(view.text, "md x")
    }

    func testCaretMovesAreNotEdits() {
        let view = makeView()
        view.insertText("m")
        view.selectedRange = NSRange(location: 0, length: 0)
        view.selectedRange = NSRange(location: 1, length: 0)
        XCTAssertEqual(view.capitalOverride.capitalAt, 0)
        view.deleteBackward()
        XCTAssertEqual(view.capitalOverride.armedAt, 0)
        view.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertEqual(view.capitalOverride.armedAt, 0)
        view.insertText("m")
        XCTAssertEqual(view.text, "m")
    }

    func testDeletionBeforeTheCapitalMovesIt() {
        let view = makeView("Ab. ")
        view.insertText("m")
        XCTAssertEqual(view.text, "Ab. M")
        XCTAssertEqual(view.capitalOverride.capitalAt, 4)
        view.selectedRange = NSRange(location: 4, length: 0)
        view.deleteBackward()                                    // the space before it
        XCTAssertEqual(view.text, "Ab.M")
        XCTAssertEqual(view.capitalOverride.capitalAt, 3)
        XCTAssertFalse(view.capitalOverride.isArmed)
        view.selectedRange = NSRange(location: 4, length: 0)
        view.deleteBackward()                                    // the capital
        XCTAssertEqual(view.capitalOverride.armedAt, 3)
    }

    func testExternalReplacementClearsBoth() {
        let view = makeView()
        view.insertText("m")
        XCTAssertTrue(view.capitalOverride.isTracking)
        view.text = "something else"
        view.textWasReplacedExternally()
        XCTAssertEqual(view.capitalOverride, CapitalOverride())
        view.selectedRange = NSRange(location: 0, length: 0)
        view.insertText("m")
        XCTAssertEqual(view.text, "Msomething else")
        view.deleteBackward()
        XCTAssertTrue(view.capitalOverride.isArmed)
        view.text = "again"
        view.textWasReplacedExternally()
        XCTAssertEqual(view.capitalOverride, CapitalOverride())
    }

    func testSameCapitalTypedInFrontOfItselfIsNotTheRetypeEither() {
        // `M` standing at 0, caret at 0, type `m`: `MM`, not `mM`.
        let view = makeView()
        view.insertText("m")
        view.selectedRange = NSRange(location: 0, length: 0)
        view.insertText("m")
        XCTAssertEqual(view.text, "MM")
        XCTAssertEqual(view.capitalOverride.capitalAt, 0)
    }

    func testReplaceDrivenDeletionBeforeTheCapitalMovesIt() throws {
        // A deletion made through `replace(_:withText:)` — what Cut, a
        // hardware forward delete, Scribble's scratch-out and an autocorrect
        // revert do — never reaches `deleteBackward()`. The tracked capital
        // must follow all the same, or a stale p makes a later deletion of
        // an unrelated letter arm the override.
        let view = makeView("Xxxx. Yy. \nqq. r", caret: 10)
        view.insertText("m")
        XCTAssertEqual(view.text, "Xxxx. Yy. M\nqq. r")
        XCTAssertEqual(view.capitalOverride.capitalAt, 10)
        view.replace(try XCTUnwrap(range(of: view, 0, 6)), withText: "")
        XCTAssertEqual(view.text, "Yy. M\nqq. r")
        XCTAssertEqual(view.capitalOverride.capitalAt, 4, "p followed the capital")
        // Offset 10 — the stale p — is now the slot before `r`, after
        // `qq. `, where rule B capitalizes (a single letter and a period,
        // `q. `, would be an enumerator: §2.6, B ii, null).
        XCTAssertEqual(SmartTyping.capitalize("Yy. M\nqq. r", selectionStart: 10, selectionEnd: 10, typed: "z"), "Z")
        view.selectedRange = NSRange(location: 10, length: 0)
        view.insertText("z")
        XCTAssertEqual(view.text, "Yy. M\nqq. Zr")
        // The new capital replaced the tracked one.
        XCTAssertEqual(view.capitalOverride.capitalAt, 10)
        XCTAssertEqual(view.capitalOverride.capital, Array("Z".utf16))
        XCTAssertFalse(view.capitalOverride.isArmed)
    }

    func testForwardDeleteOfTheCapitalArmsTheGesture() throws {
        let view = makeView("Ab. ")
        view.insertText("m")
        XCTAssertEqual(view.text, "Ab. M")
        view.selectedRange = NSRange(location: 4, length: 0)
        view.replace(try XCTUnwrap(range(of: view, 4, 1)), withText: "")      // ⌦ on a hardware keyboard
        XCTAssertEqual(view.text, "Ab. ")
        XCTAssertEqual(view.capitalOverride.armedAt, 4, "the capital's deletion arms at its slot")
        view.insertText("m")
        XCTAssertEqual(view.text, "Ab. m")
        XCTAssertFalse(view.capitalOverride.isArmed)
    }

    func testAutocorrectReplacingTheCapitalArmsTheGesture() throws {
        // `Ios` → `iOS`: an autocorrect replacement over the word, through
        // `replace(_:withText:)`. It takes the capital out, so it arms at
        // the word's start; typing on after the word clears it, and the
        // next sentence is capitalized as usual.
        let view = makeView()
        view.insertText("i")
        view.insertText("os")
        XCTAssertEqual(view.text, "Ios")
        view.replace(try XCTUnwrap(range(of: view, 0, 3)), withText: "iOS")
        XCTAssertEqual(view.text, "iOS")
        XCTAssertFalse(view.capitalOverride.isTracking)
        XCTAssertEqual(view.capitalOverride.armedAt, 0)
        view.selectedRange = NSRange(location: 3, length: 0)
        view.insertText(". ")
        XCTAssertFalse(view.capitalOverride.isArmed, "an insertion elsewhere clears it")
        view.insertText("n")
        XCTAssertEqual(view.text, "iOS. N")
    }

    func testReplaceDrivenInsertionBeforeTheCapitalMovesIt() throws {
        // An insertion that bypasses `insertText` (a paste, a drop) before
        // the capital shifts p — and must, or a stale p makes the deletion
        // of whatever now sits there arm the override.
        let view = makeView("Xxx. ")
        view.insertText("m")
        XCTAssertEqual(view.capitalOverride.capitalAt, 5)
        view.replace(try XCTUnwrap(range(of: view, 0, 0)), withText: "Abc. ")
        XCTAssertEqual(view.text, "Abc. Xxx. M")
        XCTAssertEqual(view.capitalOverride.capitalAt, 10)
        XCTAssertFalse(view.capitalOverride.isArmed)
        // Deleting what stands at the stale offset arms nothing…
        view.replace(try XCTUnwrap(range(of: view, 5, 1)), withText: "")
        XCTAssertEqual(view.text, "Abc. xx. M")
        XCTAssertFalse(view.capitalOverride.isArmed)
        XCTAssertEqual(view.capitalOverride.capitalAt, 9)
        // …so a letter typed there is capitalized, as the rule says.
        view.selectedRange = NSRange(location: 5, length: 0)
        view.insertText("z")
        XCTAssertEqual(view.text, "Abc. Zxx. M")
    }

    func testReplaceDrivenInsertionAtQKeepsTheOverride() throws {
        // A non-word insertion at q — a digit, a paste — is not the retype
        // and leaves the override armed.
        let view = makeView()
        view.insertText("m")
        view.deleteBackward()
        view.replace(try XCTUnwrap(range(of: view, 0, 0)), withText: "42")
        XCTAssertEqual(view.text, "42")
        XCTAssertEqual(view.capitalOverride.armedAt, 0)
    }

    func testReturnAfterTheCapitalKeepsItTracked() {
        let view = makeView("- ")
        view.insertText("m")
        XCTAssertEqual(view.text, "- M")
        XCTAssertEqual(view.capitalOverride.capitalAt, 2)
        view.insertText("\n")
        XCTAssertEqual(view.text, "- M\n- ")
        XCTAssertEqual(view.capitalOverride.capitalAt, 2, "the Enter edit was after the capital")
        XCTAssertFalse(view.capitalOverride.isArmed)
    }

    func testReturnElsewhereClearsTheOverride() {
        let view = makeView("Ab. ")
        view.insertText("m")
        view.deleteBackward()
        XCTAssertEqual(view.capitalOverride.armedAt, 4)
        view.selectedRange = NSRange(location: 0, length: 0)
        view.insertText("\n")
        XCTAssertEqual(view.text, "\nAb. ")
        XCTAssertFalse(view.capitalOverride.isArmed)
    }

    func testReturnAtQKeepsTheOverrideAndTheEnterEditMovesIt() {
        // Return is not a word insertion: at q it keeps the override. And
        // the Enter edit is read off the storage like any other edit: here
        // it ends the empty item by taking `- ` out before q, so q moves
        // to where the writer now types.
        let view = makeView("- ")
        view.insertText("m")
        view.deleteBackward()
        XCTAssertEqual(view.text, "- ")
        XCTAssertEqual(view.capitalOverride.armedAt, 2)
        view.insertText("\n")
        XCTAssertEqual(view.text, "")
        XCTAssertEqual(view.capitalOverride.armedAt, 0)
        view.insertText("m")
        XCTAssertEqual(view.text, "m")
        XCTAssertFalse(view.capitalOverride.isArmed)
    }

    func testTheViewIsItsStorageDelegateAndUIKitLeavesItFree() {
        // The override's bookkeeping reads every edit off the storage; that
        // only works while UIKit itself does not claim the delegate slot.
        XCTAssertNil(UITextView().textStorage.delegate, "UIKit leaves the text storage delegate to the app")
        let view = makeView()
        XCTAssertTrue(view.textStorage.delegate === view)
        XCTAssertTrue(SmartTextView().textStorage.delegate != nil)
    }

    /// `[location, location + length)` of `view` as a `UITextRange`.
    private func range(of view: UITextView, _ location: Int, _ length: Int) -> UITextRange? {
        guard let from = view.position(from: view.beginningOfDocument, offset: location),
              let to = view.position(from: from, offset: length) else { return nil }
        return view.textRange(from: from, to: to)
    }

    // MARK: §3.6 Shift-Return

    func testShiftReturnKeyCommandIsRegistered() {
        let view = makeView()
        let command = view.keyCommands?.first { $0.input == "\r" && $0.modifierFlags == .shift }
        XCTAssertNotNil(command)
        XCTAssertEqual(command?.action, #selector(SmartTextView.insertPlainNewline(_:)))
        XCTAssertEqual(command?.wantsPriorityOverSystemBehavior, true)
    }

    func testShiftReturnInsertsAPlainNewline() {
        let view = makeView("- item")
        view.insertPlainNewline(nil)
        XCTAssertEqual(view.text, "- item\n")
        XCTAssertEqual(view.selectedRange, NSRange(location: 7, length: 0))
        // And only that one: the next Return continues the list again.
        view.insertText("x")
        view.insertText("\n")
        XCTAssertEqual(view.text, "- item\nX\n")
    }

    // MARK: The delegate sees the final text

    private final class DelegateSpy: NSObject, UITextViewDelegate {
        var seen: [String] = []
        func textViewDidChange(_ textView: UITextView) { seen.append(textView.text) }
    }

    func testDelegateIsToldAboutTheCapital() {
        // The pane pushes `textViewDidChange` into the document binding; the
        // last thing it hears must be the capitalized text, not the typed one.
        let view = makeView()
        let spy = DelegateSpy()
        view.delegate = spy
        view.insertText("h")
        XCTAssertEqual(spy.seen.last, "H")
    }

    func testDelegateIsToldAboutTheEnterEdit() {
        let view = makeView("- item")
        let spy = DelegateSpy()
        view.delegate = spy
        view.insertText("\n")
        XCTAssertEqual(spy.seen.last, "- item\n- ")
    }

    // MARK: §3.5 Undo

    /// A window-hosted, first-responder view: the state in which a
    /// `UITextView` owns an undo manager.
    private func makeHostedView(_ text: String = "") throws -> (SmartTextView, UIWindow) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "the hosted test host has a window scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        let view = makeView(text)
        view.frame = window.bounds
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.becomeFirstResponder()
        return (view, window)
    }

    /// One run-loop turn: what separates two real keystrokes. UIKit's text
    /// undo manager groups per event, so the undo tests type the way a
    /// keyboard does — one turn per key — instead of in one burst.
    private func nextEvent() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }

    private func type(_ keys: String..., into view: SmartTextView) {
        for key in keys {
            view.insertText(key)
            nextEvent()
        }
    }

    func testUndoRestoresTheLowercaseLetterAndArmsTheOverride() throws {
        let (view, window) = try makeHostedView()
        defer { window.isHidden = true }
        let undo = try XCTUnwrap(view.undoManager, "a first-responder text view has an undo manager")
        type("m", into: view)
        XCTAssertEqual(view.text, "M")
        XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(undo.undoActionName, SmartTextView.capitalActionName)
        undo.undo()
        XCTAssertEqual(view.text, "m", "Undo restores the lowercase letter, not the empty view")
        XCTAssertEqual(view.selectedRange, NSRange(location: 1, length: 0))
        XCTAssertFalse(view.capitalOverride.isTracking, "the capital is gone")
        XCTAssertEqual(view.capitalOverride.armedAt, 0)
        undo.undo()
        XCTAssertEqual(view.text, "", "the second Undo takes the letter itself")
        XCTAssertEqual(view.capitalOverride.armedAt, 0, "a deletion at q keeps it")
    }

    func testConsequence6UndoThenTypingOnKeepsTheLowercase() throws {
        // type "m" → "M"; Undo → "m" (Apple restores the lowercase letter);
        // type "d" → "md".
        let (view, window) = try makeHostedView()
        defer { window.isHidden = true }
        type("m", into: view)
        XCTAssertEqual(view.text, "M")
        view.undoManager?.undo()
        XCTAssertEqual(view.text, "m")
        XCTAssertEqual(view.capitalOverride.armedAt, 0, "Undo removed the capital: armed at its slot")
        XCTAssertFalse(view.capitalOverride.isTracking)
        type("d", into: view)
        XCTAssertEqual(view.text, "md")
        XCTAssertEqual(view.capitalOverride, CapitalOverride(), "typing on elsewhere cleared it; no capital produced")
    }

    func testUndoAfterTypingOnRestoresTheRunThenTheLetter() throws {
        let (view, window) = try makeHostedView()
        defer { window.isHidden = true }
        let undo = try XCTUnwrap(view.undoManager)
        type("m", "d", " ", "i", "s", into: view)
        XCTAssertEqual(view.text, "Md is")
        XCTAssertEqual(view.capitalOverride.capitalAt, 0)
        XCTAssertFalse(view.capitalOverride.isArmed)
        undo.undo()
        XCTAssertEqual(view.text, "M", "the typing run after the capital is its own step")
        XCTAssertEqual(view.capitalOverride.capitalAt, 0)
        undo.undo()
        XCTAssertEqual(view.text, "m")
        XCTAssertEqual(view.selectedRange, NSRange(location: 1, length: 0))
        XCTAssertEqual(view.capitalOverride.armedAt, 0, "Undo of the capital arms the override")
        // The recovery the override is for: retype the letter, lowercase.
        view.deleteBackward()
        type("m", "d", into: view)
        XCTAssertEqual(view.text, "md")
    }

    func testCapitalUndoStepDoesNotSwallowTheNextKeystrokes() throws {
        // The keystrokes after the capital arrive before the run loop had a
        // quiet pass (fast typing, a busy main thread): they must still be
        // their own step, not fall into the capital's group.
        let (view, window) = try makeHostedView()
        defer { window.isHidden = true }
        let undo = try XCTUnwrap(view.undoManager)
        type("m", into: view)                                    // capital registered here
        view.insertText("d")
        view.insertText(" ")
        nextEvent()
        XCTAssertEqual(view.text, "Md ")
        undo.undo()
        XCTAssertEqual(view.text, "M")
        undo.undo()
        XCTAssertEqual(view.text, "m")
        undo.undo()
        XCTAssertEqual(view.text, "")
    }

    func testRedoRestoresTheCapitalAndUndoTakesItAgain() throws {
        let (view, window) = try makeHostedView("Hello. ")
        defer { window.isHidden = true }
        let undo = try XCTUnwrap(view.undoManager)
        type("w", into: view)
        XCTAssertEqual(view.text, "Hello. W")
        undo.undo()
        XCTAssertEqual(view.text, "Hello. w")
        XCTAssertEqual(view.capitalOverride.armedAt, 7)
        undo.redo()
        XCTAssertEqual(view.text, "Hello. W")
        XCTAssertEqual(view.selectedRange, NSRange(location: 8, length: 0))
        XCTAssertEqual(view.capitalOverride.capitalAt, 7, "Redo produces the capital again")
        XCTAssertFalse(view.capitalOverride.isArmed)
        undo.undo()
        XCTAssertEqual(view.text, "Hello. w")
        XCTAssertEqual(view.capitalOverride.armedAt, 7)
        undo.undo()
        XCTAssertEqual(view.text, "Hello. ")
        XCTAssertEqual(view.selectedRange, NSRange(location: 7, length: 0))
    }

    func testStaleCapitalUndoIsANoOp() throws {
        // An external replacement leaves the capital's action on the stack;
        // it must not touch text that no longer holds the capital.
        let (view, window) = try makeHostedView()
        defer { window.isHidden = true }
        let undo = try XCTUnwrap(view.undoManager)
        type("m", into: view)
        view.text = "xyz"
        view.textWasReplacedExternally()
        undo.undo()
        XCTAssertEqual(view.text, "xyz")
        XCTAssertEqual(view.capitalOverride, CapitalOverride())
    }

    func testEnterEditIsOneUndoStep() throws {
        let (view, window) = try makeHostedView("- item")
        defer { window.isHidden = true }
        let undo = try XCTUnwrap(view.undoManager)
        view.selectedRange = NSRange(location: 6, length: 0)
        type("\n", into: view)
        XCTAssertEqual(view.text, "- item\n- ")
        type("x", into: view)
        XCTAssertEqual(view.text, "- item\n- X")
        undo.undo()                                              // the capital
        XCTAssertEqual(view.text, "- item\n- x")
        undo.undo()                                              // the letter
        XCTAssertEqual(view.text, "- item\n- ")
        undo.undo()                                              // the whole Enter edit
        XCTAssertEqual(view.text, "- item")
        XCTAssertEqual(view.selectedRange, NSRange(location: 6, length: 0))
        XCTAssertEqual(view.capitalOverride.armedAt, 6, "q followed the slot through the undone Enter edit")
    }

    // MARK: §3.4 Cut and Paste, on a hosted view

    /// Cut and Paste go through the pasteboard and land on a later run-loop
    /// pass; wait, bounded, for the text to move on from `before`.
    private func waitForTextChange(of view: SmartTextView, from before: String,
                                   timeout: TimeInterval = 2) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while view.text == before, Date() < deadline {
            _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.05, false)
        }
    }

    func testConsequence7CutBeforeTheCapitalThenBackspaceAndRetype() throws {
        // type "Xxx. " then "m" → "Xxx. M"; select and cut "Xxx. " (before
        // the capital); ⌫ deletes the M; type "m" → "m": the offset
        // tracking survives the cut.
        let (view, window) = try makeHostedView()
        defer { window.isHidden = true }
        type("x", "x", "x", ".", " ", into: view)
        XCTAssertEqual(view.text, "Xxx. ")
        XCTAssertEqual(view.capitalOverride.capitalAt, 0)
        type("m", into: view)
        XCTAssertEqual(view.text, "Xxx. M")
        XCTAssertEqual(view.capitalOverride.capitalAt, 5, "the new capital replaced the X as the tracked one")
        view.selectedRange = NSRange(location: 0, length: 5)
        view.cut(nil)
        waitForTextChange(of: view, from: "Xxx. M")
        XCTAssertEqual(view.text, "M")
        XCTAssertEqual(view.capitalOverride.capitalAt, 0, "Cut is a deletion before p: p followed the capital")
        XCTAssertFalse(view.capitalOverride.isArmed)
        view.selectedRange = NSRange(location: 1, length: 0)
        view.deleteBackward()
        XCTAssertEqual(view.text, "")
        XCTAssertEqual(view.capitalOverride.armedAt, 0)
        type("m", into: view)
        XCTAssertEqual(view.text, "m", "the retype after the deletion goes in as typed")
        XCTAssertEqual(view.capitalOverride, CapitalOverride())
    }

    func testPasteBeforeTheCapitalMovesIt() throws {
        // `Xxx. ` → m → `Xxx. M` (p = 5) → paste `Abc. ` at 0: the capital
        // moves to 10; a letter typed at 5 — now the start of the sentence
        // `Xxx.` — is capitalized, not silenced by a stale offset.
        let (view, window) = try makeHostedView("Xxx. ")
        defer { window.isHidden = true }
        type("m", into: view)
        XCTAssertEqual(view.capitalOverride.capitalAt, 5)
        view.selectedRange = NSRange(location: 0, length: 0)
        UIPasteboard.general.string = "Abc. "
        view.paste(nil)
        waitForTextChange(of: view, from: "Xxx. M")
        XCTAssertEqual(view.text, "Abc. Xxx. M")
        XCTAssertEqual(view.capitalOverride.capitalAt, 10)
        XCTAssertFalse(view.capitalOverride.isArmed)
        view.selectedRange = NSRange(location: 5, length: 0)
        type("z", into: view)
        XCTAssertEqual(view.text, "Abc. ZXxx. M")
    }

    func testPasteAfterTheCapitalLeavesItTracked() throws {
        // The storage reports a paste together with the paragraph it fixed
        // up around it; the view trims that to the paste itself, so a paste
        // *after* the capital in the same paragraph neither moves nor
        // removes it — and deleting the capital afterwards still arms.
        let (view, window) = try makeHostedView("Xxx. ")
        defer { window.isHidden = true }
        type("m", into: view)
        XCTAssertEqual(view.capitalOverride.capitalAt, 5)
        UIPasteboard.general.string = " abc"
        view.paste(nil)
        waitForTextChange(of: view, from: "Xxx. M")
        XCTAssertEqual(view.text, "Xxx. M abc")
        XCTAssertEqual(view.capitalOverride.capitalAt, 5)
        XCTAssertFalse(view.capitalOverride.isArmed)
        view.selectedRange = NSRange(location: 6, length: 0)
        view.deleteBackward()
        XCTAssertEqual(view.text, "Xxx.  abc")
        XCTAssertEqual(view.capitalOverride.armedAt, 5)
    }

    func testPastedWordIsNeverCapitalized() throws {
        // §3.3: a pasted single word at a sentence start goes in as pasted.
        let (view, window) = try makeHostedView("Done. ")
        defer { window.isHidden = true }
        UIPasteboard.general.string = "hello"
        view.paste(nil)
        waitForTextChange(of: view, from: "Done. ")
        XCTAssertEqual(view.text, "Done. hello")
        XCTAssertEqual(view.capitalOverride, CapitalOverride(), "nothing was capitalized, nothing is tracked")
        // And the paste did not leave anything behind for the next key.
        type(" ", "w", into: view)
        XCTAssertEqual(view.text, "Done. hello w")
    }

    func testPasteAtQKeepsTheOverride() throws {
        // A paste at q is not a §3.3 word insertion: armed it stays.
        let (view, window) = try makeHostedView()
        defer { window.isHidden = true }
        type("m", into: view)
        view.deleteBackward()
        XCTAssertEqual(view.capitalOverride.armedAt, 0)
        UIPasteboard.general.string = "md"
        view.paste(nil)
        waitForTextChange(of: view, from: "")
        XCTAssertEqual(view.text, "md")
        XCTAssertEqual(view.capitalOverride.armedAt, 0)
    }
}
