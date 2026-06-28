//
//  mdApp.swift
//  md
//
//  Created by nettrash on 28/06/2026.
//
//  A document-based Markdown editor + live previewer for iPhone, iPad
//  and Mac (via Mac Catalyst). The whole app is a single `DocumentGroup`
//  over `MarkdownDocument`: the system gives us the document browser,
//  open / save / rename / autosave, iCloud Drive, and File ▸ New on the
//  Mac for free, on every platform, with no custom file-picker plumbing.
//
//  Why `DocumentGroup` and not the `WindowGroup` + imperative
//  `UIDocumentPickerViewController` pattern the sibling apps (Scan,
//  Exchange) use? Those apps aren't document-centric — file import is a
//  side feature, and they deliberately avoid SwiftUI's `.fileImporter`
//  because its completion never fires on Mac Catalyst. `DocumentGroup`
//  is a different mechanism that does *not* suffer that bug: it is the
//  document-app primitive Apple ships, and it is the genuinely simplest
//  way to get a correct editor across iOS, iPadOS and Catalyst at once.
//

import SwiftUI

@main
struct mdApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            DocumentView(document: file.$document)
        }
    }
}
