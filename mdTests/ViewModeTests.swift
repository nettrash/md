//
//  ViewModeTests.swift
//  mdTests
//
//  Per-file view-mode memory: the rule that decides which mode a document
//  opens in, and the little store behind it.
//
//  Seven cases over rules the three ports share, so they can be diffed case
//  for case. The names match too, modulo the `test` prefix XCTest requires
//  to discover them:
//
//    1. the truth table                       openViewModeTruthTable
//    2. raw, never coerced                    rememberedSplitSurvivesANarrowOpen
//    3. the three literal tokens              tokensAreLiteralAndParseCaseInsensitively
//    4. codec round-trip, `v1` rejection      codecRoundTripsAndRejectsAForeignHeader
//    5. MRU + the 200 cap                     touchedMovesToFrontAndCapsAt200
//    6. the shared identity vector            identityMatchesTheSharedVector
//    7. a jump is not a preference            navigationNudgeIsTransient
//
//  Plus an eighth that is iOS-local, because the type under it is — macOS
//  keeps `md.bookViewMode` and Android carries the flag on its view-model:
//
//    8. the book exemption's marks            bookArticleMarksAreClaimedOnce…
//
//  Case 6 is the cross-port one: it hashes the *string* the spec names, not
//  a path this machine would resolve (macOS turns `/tmp` into
//  `/private/tmp`), because what has to agree between Swift, Swift and
//  Kotlin is the digest of the bytes — a UTF-16-vs-UTF-8 slip in any port
//  shows up here and nowhere else. Where it does touch `identity(for:)` it
//  works on a file it creates and removes, and asserts the property that
//  matters — two spellings of one real file agree — rather than a fixed
//  hash of a path whose resolution depends on what exists on the machine.
//

import XCTest
@testable import md

final class ViewModeTests: XCTestCase {

    // MARK: helpers

    /// A defaults suite of this test's own, emptied first — the memory is
    /// injectable precisely so no test touches `UserDefaults.standard`.
    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "me.nettrash.md.tests.viewMode.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func entries(_ pairs: [(String, DocumentView.Mode)]) -> [ViewModeMemory.Entry] {
        pairs.map { ViewModeMemory.Entry(identity: $0.0, mode: $0.1) }
    }

    /// A syntactically valid 16-hex identity for index `i`.
    private func identity(_ i: Int) -> String {
        String(format: "%016x", i)
    }

    // MARK: 1 — the truth table

    func testOpenViewModeTruthTable() {
        // A known file opens in exactly what was remembered, whatever the
        // width, whatever is in it, and whether or not it still has an
        // identity to look one up by.
        for remembered in DocumentView.Mode.allCases {
            for isEmpty in [true, false] {
                for hasIdentity in [true, false] {
                    for isWide in [true, false] {
                        XCTAssertEqual(
                            ViewModeRule.openViewMode(remembered: remembered,
                                                      isEmptyDocument: isEmpty,
                                                      hasFileIdentity: hasIdentity,
                                                      isWide: isWide),
                            remembered,
                            "remembered \(remembered) must win, uncoerced")
                    }
                }
            }
        }

        // An unknown document. Empty is Edit everywhere — File ▸ New, or a
        // real 0-byte file, is something to write in, not to read.
        for hasIdentity in [true, false] {
            for isWide in [true, false] {
                XCTAssertEqual(
                    ViewModeRule.openViewMode(remembered: nil,
                                              isEmptyDocument: true,
                                              hasFileIdentity: hasIdentity,
                                              isWide: isWide),
                    .edit)
            }
        }

        // Unknown with content: reader-first, but only where Split isn't on
        // offer. A wide window keeps today's Split — this is the decision
        // that stops the first launch after the update from turning an
        // iPad's whole library read-only.
        for hasIdentity in [true, false] {
            XCTAssertEqual(
                ViewModeRule.openViewMode(remembered: nil,
                                          isEmptyDocument: false,
                                          hasFileIdentity: hasIdentity,
                                          isWide: true),
                .split)
            XCTAssertEqual(
                ViewModeRule.openViewMode(remembered: nil,
                                          isEmptyDocument: false,
                                          hasFileIdentity: hasIdentity,
                                          isWide: false),
                .preview)
        }
    }

    // MARK: 2 — raw, never coerced

    func testRememberedSplitSurvivesANarrowOpen() {
        let defaults = makeDefaults("rememberedSplitSurvivesANarrowOpen")
        let file = identity(0x5171)

        // The user picked Split on their iPad.
        ViewModeMemory.remember(.split, for: file, defaults: defaults)

        // They open the same file on their phone. The rule hands back the
        // raw preference…
        let opened = ViewModeRule.openViewMode(
            remembered: ViewModeMemory.lookup(file, defaults: defaults),
            isEmptyDocument: false,
            hasFileIdentity: true,
            isWide: false)
        XCTAssertEqual(opened, .split)

        // …which the renderer — and only the renderer — narrows to Edit.
        XCTAssertEqual(ViewModeRule.effectiveMode(opened, isWide: false), .edit)
        XCTAssertEqual(ViewModeRule.effectiveMode(opened, isWide: true), .split)

        // Storing what the *window* holds must never store the coerced
        // value: the iPad's Split has to still be there afterwards.
        ViewModeMemory.remember(opened, for: file, defaults: defaults)
        XCTAssertEqual(ViewModeMemory.lookup(file, defaults: defaults), .split)
    }

    // MARK: 3 — the three literal tokens

    func testTokensAreLiteralAndParseCaseInsensitively() {
        XCTAssertEqual(ViewModeMemory.token(for: .edit), "edit")
        XCTAssertEqual(ViewModeMemory.token(for: .split), "split")
        XCTAssertEqual(ViewModeMemory.token(for: .preview), "preview")

        for mode in DocumentView.Mode.allCases {
            let token = ViewModeMemory.token(for: mode)
            XCTAssertEqual(ViewModeMemory.mode(forToken: token), mode)
            XCTAssertEqual(ViewModeMemory.mode(forToken: token.uppercased()), mode)
            XCTAssertEqual(ViewModeMemory.mode(forToken: token.capitalized), mode)
        }

        XCTAssertNil(ViewModeMemory.mode(forToken: ""))
        XCTAssertNil(ViewModeMemory.mode(forToken: "splitview"))
        XCTAssertNil(ViewModeMemory.mode(forToken: "read"))
        // Surrounding spaces are forgiven, exactly as the Android port's
        // `modeFromToken` forgives them — a hand-edited defaults value is a
        // real thing, and the three ports must answer it alike.
        XCTAssertEqual(ViewModeMemory.mode(forToken: " edit"), .edit)
        XCTAssertEqual(ViewModeMemory.mode(forToken: "  Split "), .split)
        // A space *inside* the token is still not a mode.
        XCTAssertNil(ViewModeMemory.mode(forToken: "sp lit"))
    }

    // MARK: 4 — the codec

    func testCodecRoundTripsAndRejectsAForeignHeader() {
        let list = entries([(identity(1), .split), (identity(2), .preview), (identity(3), .edit)])
        let encoded = ViewModeMemory.encode(list)

        XCTAssertEqual(encoded, """
        v1
        \(identity(1)) split
        \(identity(2)) preview
        \(identity(3)) edit
        """)
        XCTAssertEqual(ViewModeMemory.decode(encoded), list)

        // An empty list is still a valid value, and still round-trips.
        XCTAssertEqual(ViewModeMemory.encode([]), "v1")
        XCTAssertEqual(ViewModeMemory.decode("v1"), [])

        // No header, a foreign header, or a future one: the whole value is
        // absent. That is what lets a later format change `v1` safely.
        for header in ["", "v0", "v2", "V1", " v1", "{\"v\":1}"] {
            let text = "\(header)\n\(identity(1)) split"
            XCTAssertEqual(ViewModeMemory.decode(text), [],
                           "header \"\(header)\" must be rejected whole")
        }

        // Malformed lines are skipped, never fatal, and never take the good
        // ones down with them.
        let messy = """
        v1
        \(identity(1)) split
        garbage
        \(identity(2)) sideways
        short edit
        \(identity(3)) preview extra
        \(identity(4))
        \(identity(5)) EDIT

        \(identity(1)) preview
        """
        XCTAssertEqual(ViewModeMemory.decode(messy),
                       entries([(identity(1), .split), (identity(5), .edit)]))
    }

    // MARK: 5 — the MRU list and its cap

    func testTouchedMovesToFrontAndCapsAt200() {
        // A new file goes to the front.
        let two = ViewModeMemory.touched(entries([(identity(1), .edit)]),
                                         identity: identity(2), mode: .preview)
        XCTAssertEqual(two, entries([(identity(2), .preview), (identity(1), .edit)]))

        // A file already in the list moves to the front and takes its new
        // mode with it — it is never duplicated.
        let moved = ViewModeMemory.touched(two, identity: identity(1), mode: .split)
        XCTAssertEqual(moved, entries([(identity(1), .split), (identity(2), .preview)]))

        // Exactly 200 fits; the 201st pushes the oldest off the end.
        var full: [ViewModeMemory.Entry] = []
        for i in 0..<ViewModeMemory.maxEntries {
            full = ViewModeMemory.touched(full, identity: identity(i), mode: .edit)
        }
        XCTAssertEqual(full.count, ViewModeMemory.maxEntries)
        XCTAssertEqual(full.first?.identity, identity(ViewModeMemory.maxEntries - 1))
        XCTAssertEqual(full.last?.identity, identity(0))

        let overflowed = ViewModeMemory.touched(full, identity: identity(999), mode: .preview)
        XCTAssertEqual(overflowed.count, ViewModeMemory.maxEntries)
        XCTAssertEqual(overflowed.first, ViewModeMemory.Entry(identity: identity(999),
                                                              mode: .preview))
        XCTAssertEqual(overflowed.last?.identity, identity(1))
        XCTAssertFalse(overflowed.contains { $0.identity == identity(0) })

        // Re-touching at the cap keeps the count — a move is not a growth.
        let resaved = ViewModeMemory.touched(overflowed, identity: identity(50), mode: .split)
        XCTAssertEqual(resaved.count, ViewModeMemory.maxEntries)
        XCTAssertEqual(resaved.first?.identity, identity(50))
    }

    // MARK: 6 — the shared identity vector

    func testIdentityMatchesTheSharedVector() throws {
        // The two vectors the three ports share. The Android one is here on
        // purpose: it is the digest of a string, and a port that hashed
        // UTF-16 (or the platform's "native" encoding) would fail it while
        // still passing every round-trip test in this file.
        XCTAssertEqual(ViewModeMemory.sha256Prefix("file:/tmp/a.md"), "53ba23f60734adf1")
        XCTAssertEqual(
            ViewModeMemory.sha256Prefix(
                "saf:com.android.externalstorage.documents:primary:Documents/a.md"),
            "427542472354b900")

        // 16 lowercase hex digits, always — the codec skips anything else.
        let hash = ViewModeMemory.sha256Prefix("file:/anywhere.md")
        XCTAssertEqual(hash.count, 16)
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase })

        // The property that actually matters, asserted on a file this test
        // makes and removes rather than on a fixed hash of a path that may
        // or may not exist: two spellings of one *real* file agree.
        //
        // It has to be a real file. `resolvingSymlinksInPath()` is a no-op
        // on a path that does not exist, so a made-up path is hashed
        // literally — which is exactly why asserting
        // `identity(for: "/private/tmp/a.md") == sha256Prefix("file:/private/tmp/a.md")`
        // was environment-sensitive: the moment something else on the
        // machine created `/tmp/a.md`, the resolver started stripping the
        // `/private` and the identity became `sha256_16("file:/tmp/a.md")`.
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viewModeIdentity-\(UUID().uuidString)", isDirectory: true)
        let real = root.appendingPathComponent("real", isDirectory: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let file = real.appendingPathComponent("a.md")
        XCTAssertTrue(fm.createFile(atPath: file.path, contents: Data("# a".utf8)))

        // `alias` → `real`, standing in for the `/var` ↔ `/private/var` pair
        // the system hands out: one file, two spellings, one identity.
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        let viaAlias = alias.appendingPathComponent("a.md")
        XCTAssertEqual(ViewModeMemory.identity(for: file),
                       ViewModeMemory.identity(for: viaAlias),
                       "one file under two spellings must keep one identity")

        // …and the dot-slash noise a path picks up standardizes away.
        let noisy = real.appendingPathComponent("./b/../a.md")
        XCTAssertEqual(ViewModeMemory.identity(for: file),
                       ViewModeMemory.identity(for: noisy))

        // Different files still hash apart.
        XCTAssertNotEqual(ViewModeMemory.identity(for: file),
                          ViewModeMemory.identity(for: real.appendingPathComponent("c.md")))

        // The documented caveat, pinned: a path that names nothing is
        // hashed as written, because the resolver leaves it alone. Harmless
        // in the app — an identity is only ever taken for a document it has
        // open — but it is what the doc comment on `identity(for:)` claims,
        // so it is asserted here. The name is a fresh UUID, so this holds
        // whatever the machine happens to have lying around.
        let missing = URL(fileURLWithPath: "/private/tmp/\(UUID().uuidString)/a.md")
        XCTAssertFalse(fm.fileExists(atPath: missing.path))
        XCTAssertEqual(ViewModeMemory.identity(for: missing),
                       ViewModeMemory.sha256Prefix("file:" + missing.path))
    }

    // MARK: 7 — a navigation jump is not a preference

    /// The bug this pins, in the shape a user hits it: a file the reader
    /// keeps in Preview, one tap on a note in the Notes menu, and the file's
    /// remembered mode was Edit from then on — forever, because the jump
    /// went through the persisting setter. Reading is not choosing.
    ///
    /// The model below is `DocumentView`'s state written out longhand:
    /// `preferred` is the `@SceneStorage` mode (what `select(_:)` writes and
    /// what the memory stores), `navigation` is the `@State` nudge, and
    /// `displayed()` is `effectiveMode`. Keeping them separate here is the
    /// point of the case — the store must be provably untouched by a jump.
    func testNavigationNudgeIsTransient() {
        // The rule itself: nudge only when the destination's pane is off
        // screen. Split shows both panes, so it never nudges — and the
        // question is always asked of the *displayed* mode.
        XCTAssertEqual(ViewModeRule.navigationNudge(displayed: .preview, wants: .edit), .edit)
        XCTAssertEqual(ViewModeRule.navigationNudge(displayed: .edit, wants: .preview), .preview)
        XCTAssertNil(ViewModeRule.navigationNudge(displayed: .edit, wants: .edit))
        XCTAssertNil(ViewModeRule.navigationNudge(displayed: .preview, wants: .preview))
        XCTAssertNil(ViewModeRule.navigationNudge(displayed: .split, wants: .edit))
        XCTAssertNil(ViewModeRule.navigationNudge(displayed: .split, wants: .preview))

        let defaults = makeDefaults("navigationNudgeIsTransient")
        let file = identity(0x0143)

        // A file the reader keeps in Preview, opened on a phone.
        ViewModeMemory.remember(.preview, for: file, defaults: defaults)
        var preferred = ViewModeRule.openViewMode(
            remembered: ViewModeMemory.lookup(file, defaults: defaults),
            isEmptyDocument: false,
            hasFileIdentity: true,
            isWide: false)
        var navigation: DocumentView.Mode?
        func displayed() -> DocumentView.Mode {
            ViewModeRule.displayedMode(preferred: preferred, navigation: navigation, isWide: false)
        }
        XCTAssertEqual(displayed(), .preview)

        // They open the Notes menu and tap a note — `jump(to note:)`.
        if let nudge = ViewModeRule.navigationNudge(displayed: displayed(), wants: .edit) {
            navigation = nudge
        }
        XCTAssertEqual(displayed(), .edit, "the note has to be visible to be read")
        XCTAssertEqual(ViewModeMemory.lookup(file, defaults: defaults), .preview,
                       "reading a note is not a preference: the store is untouched")

        // A second note: the window is already nudged, so nothing changes —
        // in particular the override is not cleared out from under them.
        if let nudge = ViewModeRule.navigationNudge(displayed: displayed(), wants: .edit) {
            navigation = nudge
        }
        XCTAssertEqual(displayed(), .edit)
        XCTAssertEqual(ViewModeMemory.lookup(file, defaults: defaults), .preview)

        // Now a deliberate pick — `select(.split)`: the nudge goes and the
        // raw choice is persisted (raw, so their iPad still gets Split).
        navigation = nil
        preferred = .split
        ViewModeMemory.remember(preferred, for: file, defaults: defaults)
        XCTAssertNil(navigation, "a deliberate pick clears the nudge")
        XCTAssertEqual(ViewModeMemory.lookup(file, defaults: defaults), .split)
        XCTAssertEqual(displayed(), .edit, "…which this phone still shows as Edit")

        // The Android half of the same bug, which is why the nudge asks the
        // displayed mode rather than the raw one: a file remembered as Split
        // renders as Edit on a phone, so a jump into the preview still has a
        // pane to bring on screen — and Split survives in the store, where
        // it could never be re-picked at this width.
        XCTAssertEqual(ViewModeRule.navigationNudge(displayed: displayed(), wants: .preview),
                       .preview)
        navigation = .preview
        XCTAssertEqual(displayed(), .preview)
        XCTAssertEqual(ViewModeMemory.lookup(file, defaults: defaults), .split)

        // Opening another document drops the override (`applyOpenViewMode`).
        navigation = nil
        XCTAssertEqual(displayed(), .edit)
    }

    // MARK: 8 — the book exemption's marks (iOS-local)

    /// `BookArticleOpens` has no Mac or Android counterpart — macOS keeps
    /// its own `md.bookViewMode` and Android carries the flag on the
    /// view-model — so this case is not part of the shared seven.
    ///
    /// What it pins is that a mark cannot outlive the open it was made for.
    /// The claim is one-shot, and an unclaimed mark expires: writer mode can
    /// mark an article that is *already* the open document, in which case
    /// the editor's `fileURL` never changes, its hook never fires and
    /// nobody claims. Left pending, that mark would be handed to the next
    /// ordinary open of the file and wrongly exempt it from the memory.
    @MainActor
    func testBookArticleMarksAreClaimedOnceAndDoNotOutliveTheirOpen() {
        let clock = MutableClock()
        BookArticleOpens.reset()
        BookArticleOpens.now = clock.now
        defer {
            BookArticleOpens.reset()
            BookArticleOpens.now = Date.init
        }

        let article = URL(fileURLWithPath: "/private/tmp/book/1. intro.md")
        let other = URL(fileURLWithPath: "/private/tmp/notes.md")

        // Claimed once, by the window the article lands in.
        BookArticleOpens.mark(article)
        XCTAssertFalse(BookArticleOpens.claimOpen(other), "a mark is per file")
        XCTAssertTrue(BookArticleOpens.claimOpen(article))
        XCTAssertFalse(BookArticleOpens.claimOpen(article),
                       "the mark is consumed; a later browser open is ordinary")

        // Marked, never claimed — the article was already the open document.
        // The mark must not be waiting for the next ordinary open.
        BookArticleOpens.mark(article)
        clock.advance(BookArticleOpens.markLifetime + 1)
        XCTAssertFalse(BookArticleOpens.claimOpen(article),
                       "a mark nobody claimed must expire, not sit in wait")

        // Expiry is a deadline, not a timer that eats live marks: a mark
        // claimed inside its lifetime still counts.
        BookArticleOpens.mark(article)
        clock.advance(BookArticleOpens.markLifetime / 2)
        XCTAssertTrue(BookArticleOpens.claimOpen(article))
    }
}

/// A clock the test moves by hand, so the mark expiry is asserted without
/// sleeping through it.
private final class MutableClock {
    private var instant = Date(timeIntervalSinceReferenceDate: 0)
    var now: () -> Date { { [self] in instant } }
    func advance(_ seconds: TimeInterval) { instant += seconds }
}
