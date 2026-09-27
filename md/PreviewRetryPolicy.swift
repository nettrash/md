//
//  PreviewRetryPolicy.swift
//  md
//
//  What the preview does when its web content process dies.
//
//  WebKit runs the preview's page in a process of its own, and that process
//  can be taken away: memory pressure on an iPad with several documents
//  open, a WebView update landing under a running app, or a Graphviz /
//  PlantUML layout that runs the process out of memory on its own. What the
//  reader sees is a blank pane — the view is still there, the page is gone,
//  and nothing says so.
//
//  The cure is to load the document again. The cure has to be bounded,
//  though: a diagram that kills the process will kill it again on the
//  reload, and an unbounded retry is a loop the reader cannot get out of.
//  So the second failure in a row stops the retrying and shows one quiet
//  line instead.
//
//  What counts as "in a row" is the whole of the bound, and it is
//  deliberately narrow: only a page that got all the way through its own
//  render puts the count back to zero. A *finished navigation* does not —
//  md-init.js runs Mermaid, Graphviz and the 7 MB PlantUML engine after
//  the load event, so every death this policy exists for lands after the
//  navigation finished, and crediting one would zero the count on every
//  cycle. Nor does an edit: a changed document is a fresh thing to try, so
//  it lifts the give-up and buys one more attempt, but in Split mode it
//  arrives on every keystroke, and a reader typing over a document whose
//  render keeps killing the process would otherwise refill the budget
//  faster than the deaths could empty it.
//
//  Kept here, away from the delegate, because it is a decision and not a
//  side effect: three inputs, three outputs, no WebKit, testable on its own
//  (`PreviewRetryPolicyTests`). md.win draws the same distinction from the
//  other end — see the comment on `OnCoreProcessFailed` in
//  md.win/src/Md.App/Controls/PreviewHost.cs, which also explains the event
//  that is deliberately *not* an input here: "unresponsive". A slow
//  PlantUML render looks exactly like an unresponsive one, and reloading on
//  it would kill the render that made the page slow in the first place.
//

import Foundation

/// The preview's retry state machine: terminations in, "reload" or "give
/// up" out. A value type — the coordinator owns one.
struct PreviewRetryPolicy: Equatable {

    /// What happened to the preview.
    enum Event: Equatable {
        /// The web content process died.
        case terminated
        /// The page finished rendering itself — md-init.js has run every
        /// engine the document asked for and reported it (`notifyComplete`).
        /// Emphatically *not* "a navigation finished": the engines run
        /// after the load event, which is precisely the window the process
        /// dies in.
        case rendered
        /// The document (or the theme, or the title) changed, so whatever
        /// the dead page held is not what would be loaded now.
        case documentChanged
    }

    /// What the coordinator should do about it.
    enum Action: Equatable {
        /// Load the document again.
        case reload
        /// Stop reloading and show the notice.
        case giveUp
        /// Nothing to do.
        case none
    }

    /// How many terminations in a row are worth a reload. The second one
    /// is the one that gives up: the first reload is the cure, and a
    /// failure straight after it says the cure is not working.
    static let limit = 2

    /// Terminations since the last *completed* render.
    private(set) var failures = 0

    /// True once `limit` terminations in a row have been seen: the pane is
    /// showing the notice and further terminations are not retried.
    private(set) var hasGivenUp = false

    init() {}

    /// Fold an event in and say what to do about it.
    mutating func handle(_ event: Event) -> Action {
        switch event {
        case .terminated:
            // Already given up: a page that is not being reloaded can still
            // report its process dying (the give-up itself leaves a dead
            // process behind). Count it, but do not act on it — acting is
            // exactly the loop this policy exists to stop.
            guard !hasGivenUp else { return .none }
            failures += 1
            guard failures >= Self.limit else { return .reload }
            hasGivenUp = true
            return .giveUp

        case .rendered:
            // The page survived its own render — engines and all. That,
            // and only that, ends the run: the thing that killed the
            // process demonstrably did not kill it this time.
            failures = 0
            hasGivenUp = false
            return .none

        case .documentChanged:
            // A different document is worth trying, so the pane stops
            // having given up and the next death is answered again. The
            // count stands, though: nothing rendered, and an edit that
            // zeroed it would hand a reader typing in Split an endless
            // supply of retries for a document that cannot render.
            hasGivenUp = false
            return .none
        }
    }
}
