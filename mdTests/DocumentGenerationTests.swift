//
//  DocumentGenerationTests.swift
//  mdTests
//
//  Which document view owns a scene's toolbar.
//
//  The bug this guards was reported from a hand test of 1.5: "in menu i saw
//  two share, two examples and book — this abnormal behaviour I see if I
//  select example before". Opening a document into a scene that is already
//  showing one leaves the previous document view alive — SwiftUI parents a
//  second `DocumentHostingController` beside the first rather than replacing
//  it — and both go on applying `.toolbar` to the scene's single navigation
//  item. Measured on iPhone 17, iOS 26.5 and 27.0, by dumping the bar from
//  inside the running app (`LaunchDiagnostics`): 6 trailing item groups
//  after the first open, 12 after the second, 18 after the third, and the
//  system's "…" overflow listing Notes / Examples / Book / Share twice.
//
//  The same leak is what made Find read as broken: the Find row that stayed
//  *visible* in the bar was the first view's, so it opened the find panel
//  over an editor holding a document that was no longer on screen.
//
//  `DocumentGeneration` is the rule that fixes both — each document view
//  stamps itself with the scene's next generation as it appears, and only
//  the newest stamp fills the bar. It is a plain function of two integers,
//  so the rule can be tested even though the UIKit shape around it cannot.
//

import XCTest
@testable import md

final class DocumentGenerationTests: XCTestCase {

    /// The frame between a document view's first render and its `onAppear`:
    /// it has no stamp yet, and it is the view that just appeared, so it
    /// fills the bar. Treating it as stale would blank the toolbar instead.
    func testAnUnstampedViewIsCurrentWhateverTheSceneHasCounted() {
        XCTAssertTrue(DocumentGeneration.isCurrent(view: DocumentGeneration.unstamped, scene: 0))
        XCTAssertTrue(DocumentGeneration.isCurrent(view: DocumentGeneration.unstamped, scene: 7))
        XCTAssertTrue(DocumentGeneration.isCurrent(view: DocumentGeneration.unstamped,
                                                   scene: Int.max))
    }

    /// One document open in a scene: it claims 1, and it is the one shown.
    func testTheFirstDocumentViewToAppearOwnsTheBar() {
        var scene = 0
        let first = DocumentGeneration.next(after: scene)
        scene = first

        XCTAssertEqual(first, 1)
        XCTAssertTrue(DocumentGeneration.isCurrent(view: first, scene: scene))
    }

    /// The report's flow: a document is open, an example is picked, the new
    /// document arrives in the same scene. Both views are alive; only the
    /// new one may fill the bar, or every menu in it appears twice.
    func testOpeningASecondDocumentRetiresTheFirstsToolbar() {
        var scene = 0
        let first = DocumentGeneration.next(after: scene)
        scene = first
        let second = DocumentGeneration.next(after: scene)
        scene = second

        XCTAssertFalse(DocumentGeneration.isCurrent(view: first, scene: scene),
                       "the view that was replaced must stop filling the bar")
        XCTAssertTrue(DocumentGeneration.isCurrent(view: second, scene: scene))
    }

    /// And it keeps holding for a run of opens — the state that showed three
    /// of every menu.
    func testOnlyTheNewestOfManyOpensFillsTheBar() {
        var scene = 0
        var stamps: [Int] = []
        for _ in 0 ..< 6 {
            let stamp = DocumentGeneration.next(after: scene)
            scene = stamp
            stamps.append(stamp)
        }

        XCTAssertEqual(stamps, [1, 2, 3, 4, 5, 6], "each open takes the next stamp")
        for retired in stamps.dropLast() {
            XCTAssertFalse(DocumentGeneration.isCurrent(view: retired, scene: scene))
        }
        XCTAssertTrue(DocumentGeneration.isCurrent(view: stamps[stamps.count - 1], scene: scene))
    }

    /// The counter lives in `@SceneStorage`, which is restored from disk, so
    /// it can come back as anything at all. It must not wrap round to
    /// `unstamped` — that would hand two views the bar at once, which is the
    /// very state being fixed.
    func testTheCounterSaturatesRatherThanWrappingToUnstamped() {
        XCTAssertEqual(DocumentGeneration.next(after: Int.max), Int.max)
        XCTAssertEqual(DocumentGeneration.next(after: Int.max - 1), Int.max)
        XCTAssertNotEqual(DocumentGeneration.next(after: Int.max), DocumentGeneration.unstamped)
        XCTAssertTrue(DocumentGeneration.isCurrent(view: Int.max, scene: Int.max))
    }

    /// A restored scene counter the view knows nothing about: the view that
    /// appears next claims past it and owns the bar, rather than deferring
    /// to a stamp no live view holds.
    func testAViewAppearingIntoARestoredSceneClaimsPastIt() {
        let restored = 41
        let claimed = DocumentGeneration.next(after: restored)

        XCTAssertEqual(claimed, 42)
        XCTAssertTrue(DocumentGeneration.isCurrent(view: claimed, scene: claimed))
        XCTAssertFalse(DocumentGeneration.isCurrent(view: restored, scene: claimed))
    }

    /// The failure mode that must not blank the toolbar. `@SceneStorage`
    /// only round-trips inside a real scene: host a `DocumentView` in a
    /// plain window and the claim is dropped, so the counter stays at 0
    /// while the view holds 1. The view must still fill the bar — an
    /// equality rule would call it stale and take the whole toolbar, and
    /// its chords, away.
    func testAViewWhoseClaimWasDroppedStillFillsTheBar() {
        let sceneThatNeverPersisted = 0
        let stamp = DocumentGeneration.next(after: sceneThatNeverPersisted)

        XCTAssertTrue(DocumentGeneration.isCurrent(view: stamp,
                                                   scene: sceneThatNeverPersisted),
                      "a dropped claim must degrade to the old behaviour, not to no toolbar")
    }
}
