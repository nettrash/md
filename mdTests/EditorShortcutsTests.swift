//
//  EditorShortcutsTests.swift
//  mdTests
//
//  The hardware-keyboard chords, and the book navigation two of them drive.
//
//  `EditorShortcuts.table` is md.win's `CommandTable` copied into Swift —
//  key and *Windows* modifiers, one place, named in that file's header. A
//  test that read the same table back would prove nothing, so this one
//  checks it against a **second, independent source**: the Mac's own
//  `keyboardShortcut(...)` calls in md.macOS/md/mdApp.swift, quoted below
//  line for line. The Windows table, translated by md's rule (Ctrl is ⌘,
//  Alt is ⌃), has to come out equal to what the Mac already ships — so a
//  wrong row, or a wrong translation, fails here rather than shipping an
//  iPad whose ⌃⌘↑ does something else.
//
//  A table nothing installs would still be worth nothing, so two cases are
//  hosted: they put a real `DocumentView` in a real window and read the key
//  commands back off the responder tree UIKit dispatches through. The host
//  is an iPhone simulator, so the window is horizontally compact — which
//  makes the same test the one for the width rule: ⌘1 and ⌘3 are
//  installed and ⌘2 is not, because a chord for a pane the window cannot
//  show must do nothing rather than select it.
//
//  Then `BookTree`: ⌃⌘↑ / ⌃⌘↓ mean "one article along the book's reading
//  order", and that order is the navigator's listing order. The stepping
//  itself is pure, so it is tested on lists of URLs; only `read(root:)`
//  touches the disk, and it gets a book built in a temporary folder.
//

import XCTest
import SwiftUI
import UIKit
@testable import md

@MainActor
final class EditorShortcutsTests: XCTestCase {

    // MARK: - The table

    func testEveryActionHasExactlyOneChord() {
        for action in EditorShortcuts.Action.allCases {
            XCTAssertNotNil(EditorShortcuts.table[action], "\(action.rawValue) has no chord")
        }
        XCTAssertEqual(EditorShortcuts.table.count, EditorShortcuts.Action.allCases.count,
                       "the table has a row with no action behind it")
    }

    func testNoTwoCommandsShareAChord() {
        let chords = EditorShortcuts.Action.allCases.map(EditorShortcuts.chord)
        XCTAssertEqual(Set(chords).count, chords.count, "two commands answer to the same chord")
    }

    /// The Mac's chords, as md.macOS/md/mdApp.swift writes them:
    ///
    ///     modes             .keyboardShortcut(KeyEquivalent(Character(mode.commandKey)), modifiers: .command)
    ///                       with commandKey "1" / "2" / "3" (md.macOS/md/DocumentView.swift)
    ///     Show Book         .keyboardShortcut("b", modifiers: [.command, .shift])
    ///     Previous Article  .keyboardShortcut(.upArrow, modifiers: [.control, .command])
    ///     Next Article      .keyboardShortcut(.downArrow, modifiers: [.control, .command])
    ///     Print…            .keyboardShortcut("p", modifiers: .command)
    ///
    /// Find is not in that list on purpose: on the Mac ⌘F is the stock Edit
    /// ▸ Find item driving `NSTextFinder`, and on iOS it is UIKit's own
    /// find interaction. Windows is the only port that spells it out
    /// (`CommandId.Find`, Ctrl+F), which is the row the table carries.
    func testTheWindowsTableTranslatesToTheMacsOwnChords() {
        let expected: [(EditorShortcuts.Action, KeyEquivalent, EventModifiers)] = [
            (.viewEdit, "1", .command),
            (.viewSplit, "2", .command),
            (.viewPreview, "3", .command),
            (.find, "f", .command),
            (.print, "p", .command),
            (.showBook, "b", [.command, .shift]),
            (.previousArticle, .upArrow, [.control, .command]),
            (.nextArticle, .downArrow, [.control, .command]),
        ]
        XCTAssertEqual(expected.count, EditorShortcuts.Action.allCases.count,
                       "a command was added without a chord to check it against")
        for (action, key, modifiers) in expected {
            let chord = EditorShortcuts.chord(action)
            XCTAssertEqual(chord.keyEquivalent.character, key.character,
                           "\(action.rawValue) is on the wrong key")
            XCTAssertEqual(chord.eventModifiers, modifiers,
                           "\(action.rawValue) has the wrong modifiers")
        }
    }

    /// The translation rule itself, stated once: Windows Ctrl is Apple's
    /// Command and Windows Alt is Apple's Control — not the other way
    /// round, which is the mistake this test exists to catch.
    func testCtrlIsCommandAndAltIsControl() {
        XCTAssertEqual(EditorShortcuts.Modifiers.ctrl.eventModifiers, .command)
        XCTAssertEqual(EditorShortcuts.Modifiers.alt.eventModifiers, .control)
        XCTAssertEqual(EditorShortcuts.Modifiers.shift.eventModifiers, .shift)
        XCTAssertEqual(EditorShortcuts.Modifiers.ctrlAlt.eventModifiers, [.command, .control])
        XCTAssertEqual(EditorShortcuts.Modifiers.ctrlShift.eventModifiers, [.command, .shift])
        XCTAssertEqual(EditorShortcuts.Modifiers([]).eventModifiers, [])
    }

    // MARK: - The layouts a width offers

    func testEachLayoutCarriesItsOwnDigit() {
        XCTAssertEqual(DocumentView.Mode.edit.shortcutAction, .viewEdit)
        XCTAssertEqual(DocumentView.Mode.split.shortcutAction, .viewSplit)
        XCTAssertEqual(DocumentView.Mode.preview.shortcutAction, .viewPreview)
    }

    /// A chord for a layout this width does not offer is never installed:
    /// the toolbar and the shortcut sink both build theirs from
    /// `availableModes`, so ⌘2 on a phone has nothing behind it and does
    /// nothing — rather than selecting a Split the window cannot show.
    func testANarrowWindowOffersNoSplitChord() {
        let narrow = ViewModeRule.availableModes(isWide: false).map(\.shortcutAction)
        XCTAssertEqual(narrow, [.viewEdit, .viewPreview])
        XCTAssertFalse(narrow.contains(.viewSplit))

        let wide = ViewModeRule.availableModes(isWide: true).map(\.shortcutAction)
        XCTAssertEqual(wide, [.viewEdit, .viewSplit, .viewPreview])
    }

    // MARK: - The chords a real window installs, hosted

    /// The table is only worth anything if SwiftUI actually installs it.
    /// So: host a real `DocumentView` in a window and read the key
    /// commands back off the responder tree UIKit would dispatch through.
    ///
    /// The host is an iPhone simulator, so the window is horizontally
    /// compact and `availableModes` offers Edit and Preview but not Split
    /// — which makes this the test of the availability rule too: ⌘1
    /// and ⌘3 have to be installed and ⌘2 must not be, because a
    /// chord for a pane the window cannot show has to do nothing rather
    /// than select it.
    func testAWindowInstallsTheChordsTheTableNames() throws {
        let installed = try installedChords()
        XCTAssertTrue(installed.contains(Chord("1", .command)), "⌘1 (Edit)")
        XCTAssertTrue(installed.contains(Chord("3", .command)), "⌘3 (Preview)")
        XCTAssertFalse(installed.contains(Chord("2", .command)),
                       "⌘2 must not exist on a window too narrow for Split")
        XCTAssertTrue(installed.contains(Chord("f", .command)), "⌘F (Find)")
        XCTAssertTrue(installed.contains(Chord("p", .command)), "⌘P (Print)")
        XCTAssertTrue(installed.contains(Chord(UIKeyCommand.inputUpArrow, [.command, .control])),
                      "⌃⌘↑ (Previous Article)")
        XCTAssertTrue(installed.contains(Chord(UIKeyCommand.inputDownArrow, [.command, .control])),
                      "⌃⌘↓ (Next Article)")
    }

    /// Show Book is the one chord with something to be disabled by — the
    /// Book menu only offers it when a book is remembered, and so does the
    /// keyboard. SwiftUI installs no key command for a disabled button, so
    /// ⇧⌘B simply does not exist until there is a book, which is
    /// exactly the behaviour the menu row has.
    func testTheShowBookChordAppearsOnlyWhenThereIsABook() throws {
        let key = BookLaunchModel.bookmarkKey
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let showBook = Chord("b", [.command, .shift])

        defaults.removeObject(forKey: key)
        XCTAssertFalse(try installedChords().contains(showBook),
                       "with no book remembered there is nothing to show")

        defaults.set("a-remembered-book", forKey: key)
        XCTAssertTrue(try installedChords().contains(showBook),
                      "a remembered book puts ⇧⌘B back")
    }

    /// Host a real document window and read back every key command UIKit
    /// would dispatch through it.
    private func installedChords() throws -> Set<Chord> {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the hosted test host has a window scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let host = UIHostingController(rootView: ShortcutHost())
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        // One layout pass, so the background's buttons are really there.
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        return Set(chords(under: host).map(Chord.init))
    }

    /// A document window with nothing else around it.
    private struct ShortcutHost: View {
        @State private var document = MarkdownDocument(text: "# Hello\n")
        var body: some View {
            NavigationStack {
                DocumentView(document: $document, fileURL: nil)
            }
        }
    }

    /// A key command, comparable.
    private struct Chord: Hashable {
        let input: String
        let modifiers: UIKeyModifierFlags.RawValue
        init(_ input: String, _ modifiers: UIKeyModifierFlags) {
            self.input = input
            self.modifiers = modifiers.rawValue
        }
        init(_ command: UIKeyCommand) {
            self.input = command.input ?? ""
            self.modifiers = command.modifierFlags.rawValue
        }
    }

    /// Every key command under `responder`: its own, its child view
    /// controllers' and its whole view tree's — which between them is
    /// where SwiftUI puts what `.keyboardShortcut` asks for.
    private func chords(under responder: UIResponder) -> [UIKeyCommand] {
        var found: [UIKeyCommand] = []
        func walk(_ r: UIResponder) {
            found.append(contentsOf: r.keyCommands ?? [])
            if let controller = r as? UIViewController {
                controller.children.forEach(walk)
                walk(controller.view)
            } else if let view = r as? UIView {
                view.subviews.forEach(walk)
            }
        }
        walk(responder)
        return found
    }

    // MARK: - Previous / Next Article (⌃⌘↑ / ⌃⌘↓)

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testReadingOrderIsRootArticlesThenEachChapters() {
        let contents = BookTree.Contents(
            topArticles: [url("/b/00-preface.md"), url("/b/01-intro.md")],
            chapters: [
                BookTree.Chapter(url: url("/b/01-part"),
                                 articles: [url("/b/01-part/01-a.md"), url("/b/01-part/02-b.md")]),
                BookTree.Chapter(url: url("/b/02-part"),
                                 articles: [url("/b/02-part/01-c.md")]),
            ])
        XCTAssertEqual(BookTree.readingOrder(contents).map(\.lastPathComponent),
                       ["00-preface.md", "01-intro.md", "01-a.md", "02-b.md", "01-c.md"])
    }

    func testSteppingWalksTheWholeBookAndStopsAtBothEnds() {
        let order = [url("/b/1.md"), url("/b/c/2.md"), url("/b/c/3.md")]
        XCTAssertEqual(BookTree.step(from: order[0], by: +1, in: order), order[1])
        // Across the joint between the root's articles and a chapter's.
        XCTAssertEqual(BookTree.step(from: order[1], by: +1, in: order), order[2])
        XCTAssertEqual(BookTree.step(from: order[2], by: -1, in: order), order[1])
        // The ends: nowhere to go, and nothing happens.
        XCTAssertNil(BookTree.step(from: order[0], by: -1, in: order))
        XCTAssertNil(BookTree.step(from: order[2], by: +1, in: order))
    }

    func testADocumentOutsideTheBookNeverSteps() {
        let order = [url("/b/1.md"), url("/b/2.md")]
        XCTAssertNil(BookTree.step(from: url("/elsewhere/notes.md"), by: +1, in: order))
        XCTAssertNil(BookTree.step(from: url("/b/1.md"), by: +1, in: []))
    }

    /// The document architecture hands back a file URL spelled its own way.
    /// A `/tmp` document arrives as `/private/tmp` (or the other way about)
    /// and a path can carry a `..`; none of that may mean "not in this
    /// book", so the step resolves both sides before it compares.
    func testASpellingDifferenceStillFindsTheArticle() throws {
        let root = try makeBook(["01-one.md", "02-two.md"])
        defer { try? FileManager.default.removeItem(at: root) }
        let order = BookTree.readingOrder(BookTree.read(root: root))
        XCTAssertEqual(order.count, 2)

        let detour = root.appendingPathComponent("chapters/../01-one.md")
        XCTAssertEqual(BookTree.step(from: detour, by: +1, in: order)?.lastPathComponent,
                       "02-two.md")
    }

    func testReadingABookFromDiskOrdersItLikeTheNavigator() throws {
        let root = try makeBook(["02-second.md", "01-first.md", "cover.png", "notes.txt"],
                                chapters: ["02-later": ["01-x.md"],
                                           "01-early": ["02-b.markdown", "01-a.md"]])
        defer { try? FileManager.default.removeItem(at: root) }

        let contents = BookTree.read(root: root)
        // Numbered names come first in number order; the unnumbered ones
        // follow alphabetically (BookOrdering). `cover.png` is not an
        // article and is simply not in the book.
        XCTAssertEqual(contents.topArticles.map(\.lastPathComponent),
                       ["01-first.md", "02-second.md", "notes.txt"])
        XCTAssertEqual(contents.chapters.map(\.url.lastPathComponent), ["01-early", "02-later"])
        XCTAssertEqual(BookTree.readingOrder(contents).map(\.lastPathComponent),
                       ["01-first.md", "02-second.md", "notes.txt",
                        "01-a.md", "02-b.markdown", "01-x.md"])
    }

    /// A book in a temporary folder: `files` at the root, then one folder
    /// per chapter with the articles named in it.
    private func makeBook(_ files: [String],
                          chapters: [String: [String]] = [:]) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("md-book-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            try Data("# \(file)\n".utf8).write(to: root.appendingPathComponent(file))
        }
        for (chapter, articles) in chapters {
            let folder = root.appendingPathComponent(chapter, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for article in articles {
                try Data("# \(article)\n".utf8).write(to: folder.appendingPathComponent(article))
            }
        }
        return root
    }
}
