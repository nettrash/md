//
//  DocumentTitleTests.swift
//  mdTests
//
//  Which name the scene's title bar shows.
//
//  Found driving the real app on iOS 27.0 for the 1.5 release check: open
//  Welcome, then Formatting, then Plots from the Examples menu and the bar
//  still read "Formatting" — with `UIDocumentViewController.document`
//  correctly Plots.md underneath — and an in-app rename after that was
//  ignored the same way. iOS 26.5 kept the title right on every open. Every
//  document view alive in a scene (the retired ones included, see
//  `DocumentGeneration`) writes into the scene's one navigation item and the
//  last write wins, so md now publishes the current document's name to the
//  scene and every view applies it; `DocumentTitle` is the rule, and the
//  hosted test below is the part of it a plain window can witness.
//

import SwiftUI
import XCTest
@testable import md

final class DocumentTitleTests: XCTestCase {

    // MARK: - The rule

    /// A scene with a published name shows that name, whichever view is
    /// writing — that is the whole point: the retired view that re-renders
    /// last writes the newest document's name, not its own.
    func testAPublishedSceneNameWinsOverAViewsOwn() {
        XCTAssertEqual(DocumentTitle.displayed(scene: "Plots", own: "Formatting"), "Plots")
        XCTAssertEqual(DocumentTitle.displayed(scene: "Plots", own: "Plots"), "Plots")
    }

    /// Before anything is published — or in a window that is not a real
    /// scene, where a `@SceneStorage` write never lands — the view falls
    /// back to its own name. A blank bar is the failure this must not
    /// degrade into.
    func testNoPublishedNameFallsBackToTheViewsOwn() {
        XCTAssertEqual(DocumentTitle.displayed(scene: "", own: "Formatting"), "Formatting")
    }

    // MARK: - The name a rename publishes

    /// What the bar shows after a rename is what `renameInPlace` makes of the
    /// typed name: trimmed, and with the extension the move keeps taken off
    /// again when the writer typed it — and only then.
    func testBaseNameAfterRenamingMatchesWhatTheMoveProduces() {
        let file = URL(fileURLWithPath: "/tmp/Plots.md")
        XCTAssertEqual(DocumentExport.baseName(afterRenaming: file, to: "Plots Renamed"), "Plots Renamed")
        XCTAssertEqual(DocumentExport.baseName(afterRenaming: file, to: "Plots Renamed.md"), "Plots Renamed")
        XCTAssertEqual(DocumentExport.baseName(afterRenaming: file, to: "Notes.MD"), "Notes")
        XCTAssertEqual(DocumentExport.baseName(afterRenaming: file, to: "  spaced  "), "spaced")
        // `v1.2` renames to `v1.2.md`, whose base name is `v1.2` — a dot in
        // the name is not an extension unless it is the file's own.
        XCTAssertEqual(DocumentExport.baseName(afterRenaming: file, to: "v1.2"), "v1.2")
        XCTAssertEqual(DocumentExport.baseName(afterRenaming: URL(fileURLWithPath: "/tmp/x"), to: "y.md"), "y.md")
    }

    // MARK: - Hosted: the view really names its navigation item

    /// The rule is only worth anything if the view applies it. Host a real
    /// `DocumentView` under a navigation stack and read the title back off
    /// the navigation item UIKit shows: it is the file's base name. (No
    /// scene, so nothing is published and the fallback is what lands —
    /// which is also the guarantee that a plain window never gets a blank
    /// bar.)
    @MainActor
    func testTheDocumentViewNamesItsNavigationItemAfterTheFile() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the hosted test host has a window scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let host = UIHostingController(rootView: TitleHost(
            fileURL: URL(fileURLWithPath: "/tmp/Chapter Two.md")))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))

        let navigation = try XCTUnwrap(navigationController(under: host),
                                       "a NavigationStack is a UINavigationController underneath")
        XCTAssertEqual(navigation.topViewController?.navigationItem.title, "Chapter Two")
    }

    private struct TitleHost: View {
        let fileURL: URL
        @State private var document = MarkdownDocument(text: "# Hello\n")
        var body: some View {
            NavigationStack {
                DocumentView(document: $document, fileURL: fileURL)
            }
        }
    }

    private func navigationController(under controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        for child in controller.children {
            if let found = navigationController(under: child) { return found }
        }
        return nil
    }
}
