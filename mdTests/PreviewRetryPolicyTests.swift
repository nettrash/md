//
//  PreviewRetryPolicyTests.swift
//  mdTests
//
//  What the preview does when WebKit's content process dies.
//
//  The decision is a value type with three inputs and three outputs
//  (`PreviewRetryPolicy`), so most of this is pure. The rest is hosted:
//  they build the real preview coordinator — a real `WKWebView` behind it
//  — and call the delegate methods WebKit would call, to check that the
//  second failure in a row puts the notice in the pane, that an edit makes
//  the pane try again, and that the line goes when a page is actually on
//  screen again (not the moment the reader types, because
//  `update(text:title:dark:)` runs inside a SwiftUI update and may publish
//  nothing). Nothing here kills a web process; what is tested is md's
//  answer to one, which is the part md owns.
//
//  The hosted cases play the order WebKit really delivers —
//  `didFinish` *then* the death, because md-init.js runs the diagram
//  engines after the load event — and one of them loads the real bundled
//  script in the real preview to prove its render-complete message
//  arrives. Playing only `terminate, terminate` is what let a finished
//  navigation pass for a finished render.
//

import XCTest
import WebKit
@testable import md

@MainActor
final class PreviewRetryPolicyTests: XCTestCase {

    // MARK: - The policy

    func testTheFirstTerminationReloads() {
        var policy = PreviewRetryPolicy()
        XCTAssertEqual(policy.handle(.terminated), .reload)
        XCTAssertEqual(policy.failures, 1)
        XCTAssertFalse(policy.hasGivenUp)
    }

    func testTheSecondTerminationInARowGivesUp() {
        var policy = PreviewRetryPolicy()
        XCTAssertEqual(policy.handle(.terminated), .reload)
        XCTAssertEqual(policy.handle(.terminated), .giveUp)
        XCTAssertTrue(policy.hasGivenUp)
    }

    /// Having given up, further terminations are counted by WebKit and
    /// ignored by md: acting on them is the loop the limit exists to stop.
    func testAfterGivingUpNothingIsRetried() {
        var policy = PreviewRetryPolicy()
        _ = policy.handle(.terminated)
        _ = policy.handle(.terminated)
        XCTAssertEqual(policy.handle(.terminated), .none)
        XCTAssertEqual(policy.handle(.terminated), .none)
        XCTAssertTrue(policy.hasGivenUp)
    }

    /// "In a row" is the whole rule: a page that came back between two
    /// deaths means the first one was a one-off, so the second starts over
    /// and is reloaded rather than given up on.
    func testARenderBetweenTwoDeathsStartsTheCountOver() {
        var policy = PreviewRetryPolicy()
        XCTAssertEqual(policy.handle(.terminated), .reload)
        XCTAssertEqual(policy.handle(.rendered), .none)
        XCTAssertEqual(policy.failures, 0)
        XCTAssertEqual(policy.handle(.terminated), .reload)
        XCTAssertFalse(policy.hasGivenUp)
    }

    /// An edit takes the pane out of having given up — the notice promises
    /// exactly that — and the load it triggers is the attempt. It does not
    /// put the count back to zero: only a page that finished rendering is
    /// evidence that the document can be rendered at all, so a death after
    /// the edit brings the line straight back instead of starting a fresh
    /// pair of reloads. In Split mode this arrives on every keystroke.
    func testEditingTheDocumentTakesThePolicyOutOfGivingUpButBuysOneAttempt() {
        var policy = PreviewRetryPolicy()
        _ = policy.handle(.terminated)
        _ = policy.handle(.terminated)
        XCTAssertTrue(policy.hasGivenUp)

        XCTAssertEqual(policy.handle(.documentChanged), .none)
        XCTAssertFalse(policy.hasGivenUp)
        XCTAssertEqual(policy.failures, PreviewRetryPolicy.limit,
                       "nothing rendered, so the run of failures still stands")
        XCTAssertEqual(policy.handle(.terminated), .giveUp)
        XCTAssertTrue(policy.hasGivenUp)
    }

    /// Typing does not buy an unbounded retry: however many keystrokes land
    /// between two deaths, the second is still the second.
    func testKeystrokesCannotRefillTheRetryBudget() {
        var policy = PreviewRetryPolicy()
        XCTAssertEqual(policy.handle(.terminated), .reload)
        for _ in 0..<50 { XCTAssertEqual(policy.handle(.documentChanged), .none) }
        XCTAssertEqual(policy.failures, 1)
        XCTAssertEqual(policy.handle(.terminated), .giveUp)
    }


    /// A completed render — unlike an edit — clears the count as well as
    /// the give-up: the document demonstrably rendered, so the budget is
    /// whole again.
    func testARenderAfterGivingUpAlsoClearsIt() {
        var policy = PreviewRetryPolicy()
        _ = policy.handle(.terminated)
        _ = policy.handle(.terminated)
        XCTAssertEqual(policy.handle(.rendered), .none)
        XCTAssertFalse(policy.hasGivenUp)
        XCTAssertEqual(policy.failures, 0)
        XCTAssertEqual(policy.handle(.terminated), .reload)
    }

    func testTheLimitIsTwo() {
        // Named, because the notice's wording ("twice in a row") quotes it.
        XCTAssertEqual(PreviewRetryPolicy.limit, 2)
    }

    // MARK: - The coordinator, hosted

    private func makeCoordinator() -> (PreviewWebView.Coordinator, PreviewStatus) {
        let status = PreviewStatus()
        return (PreviewWebView.Coordinator(status: status), status)
    }

    func testTheSecondDeathPutsTheNoticeInThePane() {
        let (coordinator, status) = makeCoordinator()
        coordinator.update(text: "# Hello", title: "Hello", dark: false)
        XCTAssertFalse(status.contentProcessGaveUp)

        coordinator.webViewWebContentProcessDidTerminate(coordinator.webView)
        XCTAssertFalse(status.contentProcessGaveUp, "the first death is reloaded, not announced")
        XCTAssertEqual(coordinator.retryPolicy.failures, 1)

        coordinator.webViewWebContentProcessDidTerminate(coordinator.webView)
        XCTAssertTrue(status.contentProcessGaveUp)
        XCTAssertTrue(coordinator.retryPolicy.hasGivenUp)
    }

    func testEditingTheDocumentTakesTheNoticeAway() {
        let (coordinator, status) = makeCoordinator()
        coordinator.update(text: "# Hello", title: "Hello", dark: false)
        coordinator.webViewWebContentProcessDidTerminate(coordinator.webView)
        coordinator.webViewWebContentProcessDidTerminate(coordinator.webView)
        XCTAssertTrue(status.contentProcessGaveUp)

        coordinator.update(text: "# Hello again", title: "Hello", dark: false)
        XCTAssertFalse(coordinator.retryPolicy.hasGivenUp,
                       "an edit ends the run of failures, so the pane tries again")
        // The line itself stays until the page is actually back: `update`
        // runs inside a SwiftUI update and must publish nothing.
        XCTAssertTrue(status.contentProcessGaveUp)

        coordinator.webView(coordinator.webView, didFinish: nil)
        XCTAssertFalse(status.contentProcessGaveUp)
    }

    /// The order WebKit actually delivers when a diagram engine eats the
    /// content process, which is the case the bound was built for: the
    /// shell page loads and `didFinish` fires, *then* md-init.js imports
    /// the engine and the render kills the process. A finished navigation
    /// must therefore not count as a render — if it did, the count would
    /// be zeroed on every cycle, the notice would never appear, and the
    /// pane would reload for ever.
    func testAFinishedNavigationIsNotAPageThatSurvivedItsRender() {
        let (coordinator, status) = makeCoordinator()
        coordinator.update(text: "# Heavy", title: "Heavy", dark: false)

        coordinator.webView(coordinator.webView, didFinish: nil)
        coordinator.webViewWebContentProcessDidTerminate(coordinator.webView)
        XCTAssertEqual(coordinator.retryPolicy.failures, 1)

        coordinator.webView(coordinator.webView, didFinish: nil)
        XCTAssertEqual(coordinator.retryPolicy.failures, 1,
                       "the navigation finished; the diagrams had not run yet")
        coordinator.webViewWebContentProcessDidTerminate(coordinator.webView)

        XCTAssertTrue(coordinator.retryPolicy.hasGivenUp)
        XCTAssertTrue(status.contentProcessGaveUp,
                      "two deaths after two loads is twice in a row — the pane must stop")
    }

    /// And a page that really did get through its render starts the count
    /// over, so an isolated death stays an isolated death.
    func testAPageThatReportsItsRenderStartsTheCountOver() {
        let (coordinator, status) = makeCoordinator()
        coordinator.update(text: "# Fine", title: "Fine", dark: false)

        coordinator.webView(coordinator.webView, didFinish: nil)
        coordinator.renderDidComplete()
        coordinator.webViewWebContentProcessDidTerminate(coordinator.webView)
        XCTAssertEqual(coordinator.retryPolicy.failures, 1)

        coordinator.webView(coordinator.webView, didFinish: nil)
        coordinator.renderDidComplete()
        XCTAssertEqual(coordinator.retryPolicy.failures, 0)

        coordinator.webViewWebContentProcessDidTerminate(coordinator.webView)
        XCTAssertFalse(coordinator.retryPolicy.hasGivenUp)
        XCTAssertFalse(status.contentProcessGaveUp)
    }

    /// Split mode calls `update` on every key change. Typing over a
    /// document whose render keeps killing the process must still reach
    /// the notice — the second path by which the count used to be
    /// refilled faster than the deaths could empty it.
    func testTypingInSplitDoesNotRefillTheRetryBudget() {
        let (coordinator, status) = makeCoordinator()
        coordinator.update(text: "# a", title: "Doc", dark: false)
        coordinator.webView(coordinator.webView, didFinish: nil)
        coordinator.webViewWebContentProcessDidTerminate(coordinator.webView)
        XCTAssertEqual(coordinator.retryPolicy.failures, 1)

        // Keystrokes, each one a genuine document change.
        coordinator.update(text: "# ab", title: "Doc", dark: false)
        coordinator.update(text: "# abc", title: "Doc", dark: false)
        XCTAssertEqual(coordinator.retryPolicy.failures, 1,
                       "an edit is a fresh attempt, not evidence that anything rendered")

        coordinator.webViewWebContentProcessDidTerminate(coordinator.webView)
        XCTAssertTrue(coordinator.retryPolicy.hasGivenUp)
        XCTAssertTrue(status.contentProcessGaveUp)
    }

    /// The wiring, end to end: the bundled `md-init.js`, running in the
    /// real preview web view, has to reach `renderDidComplete()`. The
    /// script has always posted `mdRender` — until now nothing in the
    /// preview's configuration was listening, so the message went nowhere
    /// and nothing could ever end a run of failures.
    func testTheBundledInitScriptReportsItsRenderToThePreview() async throws {
        let (coordinator, _) = makeCoordinator()
        coordinator.update(text: "# Plain", title: "Plain", dark: false)
        XCTAssertEqual(coordinator.renderCompletions, 0)

        // A plain heading pulls in no engine at all, so md-init.js settles
        // as soon as the page loads; the wait is slack, not a duration.
        let deadline = Date().addingTimeInterval(30)
        while coordinator.renderCompletions == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThan(coordinator.renderCompletions, 0,
                             "md-init.js's mdRender message never reached the coordinator")
        // And it is the render, not the navigation, that ends a run of
        // failures — the page itself said so.
        XCTAssertEqual(coordinator.retryPolicy.failures, 0)
        withExtendedLifetime(coordinator) {}
    }

    /// The same text arriving again is not a document change — `update`
    /// returns early on it — so it must not clear a notice that is up.
    /// (SwiftUI calls `updateUIView` freely; if a repeat cleared the
    /// notice, the line would flicker away on the next layout pass.)
    func testANoOpUpdateLeavesTheNoticeAlone() {
        let (coordinator, status) = makeCoordinator()
        coordinator.update(text: "# Hello", title: "Hello", dark: false)
        coordinator.webViewWebContentProcessDidTerminate(coordinator.webView)
        coordinator.webViewWebContentProcessDidTerminate(coordinator.webView)
        XCTAssertTrue(status.contentProcessGaveUp)

        coordinator.update(text: "# Hello", title: "Hello", dark: false)
        XCTAssertTrue(status.contentProcessGaveUp,
                      "the same text again is not an edit, so the line stays")
        XCTAssertTrue(coordinator.retryPolicy.hasGivenUp)
    }

    /// Edit, then Preview again: a *new* pane — a new coordinator — over
    /// the same document's status. It must come back with the notice, load
    /// nothing, and wait for a real edit. Before 2026-09-27 the policy lived
    /// in the coordinator and every mode switch started it over.
    func testAGiveUpSurvivesANewPaneForTheSameDocument() {
        let status = PreviewStatus()
        let first = PreviewWebView.Coordinator(status: status)
        first.update(text: "# Hello", title: "Hello", dark: false)
        first.webViewWebContentProcessDidTerminate(first.webView)
        first.webViewWebContentProcessDidTerminate(first.webView)
        XCTAssertTrue(status.contentProcessGaveUp)

        let again = PreviewWebView.Coordinator(status: status)
        again.update(text: "# Hello", title: "Hello", dark: false)
        XCTAssertTrue(again.retryPolicy.hasGivenUp, "the same document is no change")
        XCTAssertTrue(status.contentProcessGaveUp)
        XCTAssertNil(again.webView.url, "nothing is loaded for a document that stopped the preview")

        again.update(text: "# Hello, edited", title: "Hello", dark: false)
        XCTAssertFalse(again.retryPolicy.hasGivenUp, "an edit lifts it")
        XCTAssertEqual(again.retryPolicy.failures, PreviewRetryPolicy.limit, "one attempt, not a fresh budget")
    }

    /// A new pane for a document that never had trouble simply loads it.
    func testANewPaneForAHealthyDocumentLoadsIt() {
        let status = PreviewStatus()
        PreviewWebView.Coordinator(status: status).update(text: "# Fine", title: "Fine", dark: false)
        let again = PreviewWebView.Coordinator(status: status)
        again.update(text: "# Fine", title: "Fine", dark: false)
        XCTAssertFalse(status.contentProcessGaveUp)
        XCTAssertNotNil(again.webView.url, "the new pane loads the document")
    }
}
