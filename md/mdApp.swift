//
//  mdApp.swift
//  md
//
//  Created by nettrash on 28/06/2026.
//
//  A document-based Markdown editor + live previewer for iPhone and iPad.
//  The whole app is a single `DocumentGroup` over `MarkdownDocument`: the
//  system gives us the document browser, open / save / autosave, iCloud
//  Drive and File ▸ New for free, with no custom file-picker plumbing.
//
//  Why `DocumentGroup` and not the `WindowGroup` + imperative
//  `UIDocumentPickerViewController` pattern the sibling apps (Scan,
//  Exchange) use? Those apps aren't document-centric — file import is a
//  side feature, and they deliberately avoid SwiftUI's `.fileImporter`
//  because its completion never fires on Mac Catalyst. `DocumentGroup`
//  is the document-app primitive Apple ships and the simplest way to get a
//  correct editor on iOS and iPadOS.
//
//  macOS note: this app shipped its Mac build via Mac Catalyst, but a
//  Catalyst `DocumentGroup` is a UIKit document stack bridged to AppKit —
//  not a real `NSDocument` app — so its title-bar enclosing-folder display,
//  Rename / Move To, and New-file handling are unfixably unreliable. Mac
//  Catalyst is therefore disabled (`SUPPORTS_MACCATALYST = NO`); a proper
//  native macOS target (with AppKit editor / alerts / print / share) will be
//  built separately, where the real `NSDocument`-backed `DocumentGroup`
//  makes all of that work natively.
//

import SwiftUI

@main
struct mdApp: App {
    /// Whether a book is remembered — decides if the launch screen offers
    /// Show Book at all (see `BookLaunchModel`).
    @AppStorage(BookLaunchModel.bookmarkKey) private var bookBookmark = ""

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            // Pass the file URL only so exports / the print job can be named
            // after the document. The title bar (filename, folder) is managed
            // natively by DocumentGroup.
            DocumentView(document: file.$document, fileURL: file.fileURL)
        }

        // The launch screen's actions. Without them, writer mode would be
        // unreachable from the app's first screen: the Book menu lives in
        // an open document's toolbar, and the bare document browser offers
        // no way to add one. The three actions say exactly what the
        // editor's Book menu says, and mean the same: Show Book reopens
        // the remembered book (and is only offered when there is one),
        // Open Book… always asks for a folder, New Book… makes one.
        //
        // The buttons only flip state on the shared model; the backdrop
        // (the scene's background view) does the presenting from inside
        // the scene, where sheets and their `dismiss` actually work (see
        // `BookLaunchModel`).
        DocumentGroupLaunchScene {
            NewDocumentButton("New Document")
            if !bookBookmark.isEmpty {
                Button("Show Book") {
                    BookLaunchModel.shared.showBook()
                }
            }
            Button("Open Book…") {
                BookLaunchModel.shared.chooseBook()
            }
            Button("New Book…") {
                BookLaunchModel.shared.startNewBook()
            }
        } background: {
            BookLaunchBackdrop()
        }
    }
}
