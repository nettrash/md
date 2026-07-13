//
//  DocumentView.swift
//  md
//
//  Created by nettrash on 28/06/2026.
//
//  The content of one document window: a raw-Markdown editor and a live
//  rendered preview, with a mode switch in the navigation bar. On a phone
//  the two are mutually exclusive (Edit ↔ Preview); on iPad and Mac,
//  where there's room, a Split mode shows them side by side and the
//  preview re-renders as you type. The chosen mode is remembered per
//  window via `@SceneStorage`, so two open document windows can each keep
//  their own layout.
//
//  The whole window wears the typewriter theme — warm paper behind both
//  panes, American Typewriter type — and the toolbar carries the mode
//  switch, Undo / Redo (driven by the editor's `EditorController`), the
//  navigation menus (Contents, Notes, Examples, Book — see below), and a
//  share / print menu, all as native iOS 26 Liquid Glass controls.
//
//  Navigation: the Contents menu lists the document's headings and jumps
//  whichever pane(s) are visible to the tapped one — the preview scrolls to
//  the heading's anchor, the editor moves its caret to the heading's source
//  line. The Notes menu lists the author's private `<!-- note: … -->`
//  comments and always jumps the *editor* (notes never render in the
//  preview). The Examples menu opens one of the bundled sample documents
//  as a fresh copy of the user's own. The Book menu is "writer mode": a
//  picked folder of chapters (subfolders) and articles (Markdown files) —
//  see BookNavigator.
//

import SwiftUI
import UIKit

// MARK: - Split-view scroll sync

/// Links the two panes of Split so they scroll as one: each pane reports
/// the fraction of its scrollable range it sits at, and the other follows.
/// Proportional, not line-mapped — the panes' heights diverge around tall
/// rendered content (a diagram is one source line), but the neighborhood
/// always matches, which is what side-by-side writing needs.
///
/// A plain class, deliberately not observable: scroll events arrive at
/// display rate and must never re-render SwiftUI views. Unlike the Mac
/// sibling, both panes here are real `UIScrollView`s, so the whole sync
/// is native — no JavaScript bridge. Echo suppression is UIKit's own
/// bookkeeping: a pane only *reports* a scroll the user's finger is
/// behind (tracking / dragging / decelerating), so relayed positions,
/// navigation jumps and reload restores never bounce back.
@MainActor
final class ScrollSync {
    /// Set by the editor pane: scroll the editor to a fraction [0, 1].
    var scrollEditor: ((CGFloat) -> Void)?
    /// Set by the preview pane: scroll the preview to a fraction [0, 1].
    var scrollPreview: ((CGFloat) -> Void)?

    func editorDidScroll(to fraction: CGFloat) {
        scrollPreview?(fraction)
    }

    func previewDidScroll(to fraction: CGFloat) {
        scrollEditor?(fraction)
    }
}

/// The per-pane geometry both sides of the sync share, inset-aware so the
/// fractions line up even with the keyboard up or content under bars.
extension UIScrollView {
    private var syncMaxOffset: CGFloat {
        contentSize.height + adjustedContentInset.top + adjustedContentInset.bottom
            - bounds.height
    }

    /// The fraction [0, 1] of the scrollable range currently scrolled to;
    /// nil when the content fits and there is nothing to sync.
    var syncFraction: CGFloat? {
        let maxOffset = syncMaxOffset
        guard maxOffset > 0 else { return nil }
        let offset = (contentOffset.y + adjustedContentInset.top) / maxOffset
        return min(max(offset, 0), 1)
    }

    /// Follow the other pane to `fraction` of this pane's range.
    func syncScroll(toFraction fraction: CGFloat) {
        let maxOffset = syncMaxOffset
        guard maxOffset > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        setContentOffset(CGPoint(x: contentOffset.x,
                                 y: clamped * maxOffset - adjustedContentInset.top),
                         animated: false)
    }

    /// True while the scroll is the user's finger or its momentum — the
    /// gate that keeps everything programmatic (relays, anchor jumps,
    /// reload restores) from being reported back into the sync.
    var isUserScrolling: Bool { isTracking || isDragging || isDecelerating }
}

// MARK: - Writing stats (the footer)

/// The author-facing counters in the document footer.
enum WritingStats {
    /// Locale-aware word count (what "words" means to a writer, not a
    /// whitespace split — "it's" is one word, "—" is none).
    static func words(in text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex...,
                                 options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }
}

/// The footer's counters, computed off the per-keystroke `body` path: one
/// full-text scan per typing pause (the owner's `.task(id: text)` restart
/// is the debounce), off the main thread — a book-length document costs
/// real milliseconds per scan.
struct WordCounts: Equatable {
    var words = 0
    var characters = 0
    /// False only before the first computation — the owner's task skips
    /// the debounce then, so a fresh window's footer fills immediately.
    var computed = false

    static func compute(from text: String) async -> WordCounts {
        await Task.detached {
            WordCounts(words: WritingStats.words(in: text),
                       characters: text.count,
                       computed: true)
        }.value
    }

    func refreshed(from text: String) async -> WordCounts {
        if computed {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return self }
        }
        return await Self.compute(from: text)
    }
}

struct DocumentView: View {
    @Binding var document: MarkdownDocument
    /// The document's file URL, when it has been saved. Used only to name
    /// the shared / exported files and the print job — the title bar's
    /// rename / move menu is handled natively by `DocumentGroup`, not here.
    /// `nil` for a brand-new, never-saved document.
    let fileURL: URL?

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme
    /// Per-window mode preference (SceneStorage, not AppStorage, so each
    /// document window keeps its own layout). Falls back to a sensible
    /// per-width default in `effectiveMode` when the stored value can't apply.
    @SceneStorage("md.viewMode") private var storedMode = Mode.split.rawValue
    /// Bridges the editor's undo stack to the toolbar's Undo / Redo buttons.
    @StateObject private var editor = EditorController()
    /// The latest Contents-menu jump for the preview pane; a fresh value per
    /// tap (see `PreviewNavigation`) so repeated taps re-scroll.
    @State private var previewNavigation: PreviewNavigation?
    /// The persisted book folder, as a base64 security-scoped bookmark
    /// (AppStorage has no `Data` flavor). Empty string = no book. AppStorage,
    /// not SceneStorage: the book outlives any one window.
    @AppStorage("md.bookBookmark") private var bookBookmark = ""
    /// Links the panes' scrolling in Split (identity-stable across
    /// renders; the panes register themselves on it).
    @State private var scrollSync = ScrollSync()
    /// The footer's counters, cached off the per-keystroke render path
    /// (see `WordCounts`).
    @State private var counts = WordCounts()
    /// Presents the book navigator sheet when non-nil.
    @State private var bookSheet: BookPresentation?
    /// The "New Book…" name prompt (the folder picker follows it).
    @State private var showNewBook = false
    @State private var newBookName = ""
    /// A book or example operation failed (folder creation, copying,
    /// bookmarking); shown in an alert rather than failing silently — a
    /// dead menu item reads as a broken app.
    @State private var errorMessage: String?

    enum Mode: String, CaseIterable, Identifiable {
        case edit, split, preview
        var id: String { rawValue }
        var label: String {
            switch self {
            case .edit: return "Edit"
            case .split: return "Split"
            case .preview: return "Preview"
            }
        }
        var symbol: String {
            switch self {
            case .edit: return "square.and.pencil"
            case .split: return "rectangle.split.2x1"
            case .preview: return "eye"
            }
        }
    }

    /// Split is only offered when there's horizontal room (iPad / Mac).
    private var isWide: Bool { sizeClass == .regular }

    private var availableModes: [Mode] {
        isWide ? Mode.allCases : [.edit, .preview]
    }

    /// The mode actually shown: the stored preference, coerced to one the
    /// current width supports (e.g. Split collapses to Edit on a phone).
    private var effectiveMode: Mode {
        let stored = Mode(rawValue: storedMode) ?? .split
        if availableModes.contains(stored) { return stored }
        return stored == .preview ? .preview : .edit
    }

    /// Base name used for export / print filenames and the print job.
    private var baseName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    /// The document's headings / notes, parsed fresh each render. Both are
    /// a single cheap line scan (the live preview already re-parses the
    /// whole document per keystroke), and the menus' enabled state has to
    /// track edits, so there's nothing worth caching here.
    private var outline: [OutlineEntry] { MarkdownParser.outline(document.text) }
    private var noteEntries: [NoteEntry] { MarkdownParser.notes(document.text) }

    var body: some View {
        // No `.navigationDocument` / `.navigationTitle` here on purpose: in a
        // `DocumentGroup`, the system title bar is bound to the open document
        // automatically; setting `navigationDocument` to a snapshot of
        // `file.fileURL` only overrode that. `fileURL` is used solely to name
        // exports / the print job and to drive the in-app Rename.
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
            .background(Typewriter.paper.ignoresSafeArea())
            .toolbar { toolbarContent }
            .navigationBarTitleDisplayMode(.inline)
            // Recompute the footer's counters once per typing pause — the
            // task restarts (cancelling the sleeping one) on every change.
            .task(id: document.text) {
                counts = await counts.refreshed(from: document.text)
            }
            .sheet(item: $bookSheet) { presentation in
                BookNavigator(root: presentation.url)
            }
            .alert("New Book", isPresented: $showNewBook) {
                TextField("Book name", text: $newBookName)
                Button("Create") { createBook() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll choose where to keep it next.")
            }
            .alert("Something Went Wrong",
                   isPresented: Binding(get: { errorMessage != nil },
                                        set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Mode switch. On a wide window the modes are inline glass chips
        // (the selected one tinted); on a phone they collapse to a single
        // menu so the bar stays uncluttered. Either way there's no nested
        // segmented-control chrome — hence no double border.
        if isWide {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ForEach(availableModes) { mode in
                    Button {
                        storedMode = mode.rawValue
                    } label: {
                        Label(mode.label, systemImage: mode.symbol)
                    }
                    .labelStyle(.iconOnly)
                    .tint(effectiveMode == mode ? .accentColor : .secondary)
                }
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("View mode", selection: modeBinding) {
                        ForEach(availableModes) { mode in
                            Label(mode.label, systemImage: mode.symbol).tag(mode)
                        }
                    }
                } label: {
                    Label("View mode", systemImage: effectiveMode.symbol)
                }
            }
        }

        // Undo / Redo — only while a pane is being edited; they reflect and
        // drive the editor's own undo stack.
        if effectiveMode != .preview {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { editor.undo() } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!editor.canUndo)

                Button { editor.redo() } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!editor.canRedo)
            }
        }

        // Table of contents — every heading in the document; tapping jumps
        // whichever pane(s) are visible to it (see `jump(to:)`).
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                // OutlineEntry carries no identity of its own; the position
                // in the outline is the identity that matters here.
                ForEach(Array(outline.enumerated()), id: \.offset) { _, entry in
                    Button {
                        jump(to: entry)
                    } label: {
                        // Nested headings indent by two spaces per level
                        // beyond H1 — menu rows offer no real leading inset.
                        Text(String(repeating: "  ", count: max(0, entry.level - 1)) + entry.text)
                    }
                }
            } label: {
                Label("Contents", systemImage: "list.bullet")
            }
            .disabled(outline.isEmpty)
        }

        // Author notes (`<!-- note: … -->`) — private annotations that never
        // render; tapping one jumps the editor to its source line.
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                ForEach(Array(noteEntries.enumerated()), id: \.offset) { _, note in
                    Button {
                        jump(to: note)
                    } label: {
                        Text(Self.notePreview(note.text))
                    }
                }
            } label: {
                Label("Notes", systemImage: "note.text")
            }
            .disabled(noteEntries.isEmpty)
        }

        // Examples — the sample documents bundled with the app; picking one
        // copies it into the app's Documents folder as a fresh document of
        // the user's own and opens the copy (the bundle itself is read-only).
        // The sample book lives here too, below the documents.
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                ForEach(Self.exampleURLs, id: \.self) { url in
                    Button {
                        openExample(url)
                    } label: {
                        Text(Self.exampleTitle(url))
                    }
                }
                Divider()
                Button {
                    // Copies the bundled sample book wherever the user
                    // picks and adopts the copy — a guided tour of writer
                    // mode the reader can edit freely.
                    installExampleBook()
                } label: {
                    Label("Example Book…", systemImage: "text.book.closed")
                }
            } label: {
                Label("Examples", systemImage: "lightbulb")
            }
        }

        // Book (writer mode) — a folder of chapters and articles, browsed
        // in a sheet. "New Book…" creates that folder from scratch;
        // "Open Book…" adopts an existing one (its picker can also create
        // a folder inline). See BookNavigator.
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    // A friendly default the writer can just accept; the
                    // alert's field lets them retype it.
                    newBookName = "My Book"
                    showNewBook = true
                } label: {
                    Label("New Book…", systemImage: "plus")
                }
                Button {
                    openBookPicker()
                } label: {
                    Label("Open Book…", systemImage: "folder")
                }
                if !bookBookmark.isEmpty {
                    Button {
                        showBook()
                    } label: {
                        // No ellipsis: showing the navigator needs no
                        // further input (macOS and Android say the same).
                        Label("Show Book", systemImage: "book")
                    }
                    Button {
                        // "Close" only forgets the bookmark; the folder and
                        // its contents are untouched.
                        bookBookmark = ""
                    } label: {
                        Label("Close Book", systemImage: "xmark")
                    }
                }
            } label: {
                Label("Book", systemImage: "books.vertical")
            }
        }

        // Rename / share / export / print.
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    if let fileURL {
                        DocumentExport.promptRename(fileURL: fileURL, currentBaseName: baseName)
                    }
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                .disabled(fileURL == nil)   // nothing to rename until first save

                Divider()

                Button {
                    DocumentExport.shareSource(fileURL: fileURL, text: document.text, title: baseName)
                } label: {
                    Label("Share Source…", systemImage: "doc.plaintext")
                }
                Button {
                    Task { await DocumentExport.sharePDF(source: document.text, title: baseName,
                                                         dark: colorScheme == .dark) }
                } label: {
                    Label("Share Rendered PDF…", systemImage: "doc.richtext")
                }
                Button {
                    Task { await DocumentExport.exportPDF(source: document.text, title: baseName,
                                                          dark: colorScheme == .dark) }
                } label: {
                    Label("Export as PDF…", systemImage: "square.and.arrow.down")
                }
                Divider()
                Button {
                    Task { await DocumentExport.print(source: document.text, title: baseName,
                                                      dark: colorScheme == .dark) }
                } label: {
                    Label("Print…", systemImage: "printer")
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    // MARK: - Panes

    @ViewBuilder
    private var content: some View {
        switch effectiveMode {
        case .edit:
            editorPane
        case .preview:
            previewPane
        case .split:
            // Side by side when there's room; if the window is a "regular"
            // size class but still physically narrow (a narrow iPad Split
            // View / Stage Manager window), stack the panes vertically rather
            // than cramping two unusable columns.
            GeometryReader { geo in
                if geo.size.width >= 640 {
                    HStack(spacing: 0) {
                        editorPane
                        Divider()
                        previewPane
                    }
                } else {
                    VStack(spacing: 0) {
                        editorPane
                        Divider()
                        previewPane
                    }
                }
            }
        }
    }

    /// Binds the segmented control to the persisted mode.
    private var modeBinding: Binding<Mode> {
        Binding(get: { effectiveMode }, set: { storedMode = $0.rawValue })
    }

    /// The author's counters: live words and characters, tucked under the
    /// panes.
    private var footer: some View {
        HStack {
            Spacer()
            Text("\(counts.words) words · \(counts.characters) characters")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(Typewriter.font(11))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Typewriter.paperSecondary)
    }

    private var editorPane: some View {
        MarkdownEditor(text: $document.text, controller: editor, scrollSync: scrollSync)
            .overlay(alignment: .topLeading) {
                if document.text.isEmpty {
                    // The text view has no native placeholder; mimic one,
                    // aligned to its content inset.
                    Text("# Start writing…")
                        .font(Typewriter.font(17))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 16)
                        .padding(.leading, 16)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewPane: some View {
        // The rendered preview is a WebView showing the same themed HTML as
        // print / share, so LaTeX math, Mermaid and PlantUML render (offline).
        // It scrolls and lays out internally (see the CSS in MarkdownHTML).
        MarkdownWebView(text: document.text, title: baseName, navigation: previewNavigation,
                        scrollSync: scrollSync)
            .ignoresSafeArea(.container, edges: .bottom)
    }

    // MARK: - Navigation (Contents / Notes / Book)

    /// Jump to a heading — in whichever pane(s) the current mode shows:
    /// the preview scrolls to the heading's anchor, the editor moves its
    /// caret to the heading's source line, Split does both.
    private func jump(to entry: OutlineEntry) {
        let mode = effectiveMode
        if mode != .edit {
            previewNavigation = PreviewNavigation(id: UUID(), slug: entry.slug)
        }
        if mode != .preview {
            editor.scrollTo(line: entry.line)
        }
    }

    /// Jump to a note. Notes exist only in the source, so the jump always
    /// lands in the editor — Preview-only mode switches to Edit first so
    /// the destination is actually visible. (`scrollTo` holds the request
    /// until the freshly created editor pane can honor it.)
    private func jump(to note: NoteEntry) {
        if effectiveMode == .preview {
            storedMode = Mode.edit.rawValue
        }
        editor.scrollTo(line: note.line)
    }

    /// A menu-sized note preview: first line only, whitespace collapsed,
    /// capped at ~50 characters so one long note can't dwarf the menu.
    private static func notePreview(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let collapsed = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return "(empty note)" }
        guard collapsed.count > 50 else { return collapsed }
        return collapsed.prefix(50).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Create a brand-new book: ask where to keep it, create the named
    /// folder there, adopt it as the current book and show it. The name
    /// itself was collected by the "New Book" alert (`newBookName`).
    private func createBook() {
        // Same naming rule as the app's rename: non-empty, and no path
        // separators a file name can't carry.
        let name = newBookName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":") else { return }

        // The alert is still animating out when its Create action runs, so
        // present the picker a beat later — presenting mid-dismissal finds
        // no usable presenter and silently drops the picker (same rationale
        // as DocumentExport's presentAlert retry).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            // The picker chooses the *parent* folder — where the book will
            // live; the book folder itself is created inside it below.
            BookFolderPicker.present { parent in
                let scoped = parent.startAccessingSecurityScopedResource()
                defer { if scoped { parent.stopAccessingSecurityScopedResource() } }

                let bookURL = parent.appendingPathComponent(name, isDirectory: true)
                do {
                    // No intermediate directories, and an existing "<name>"
                    // is an error — a new book must be a fresh folder.
                    try FileManager.default.createDirectory(
                        at: bookURL, withIntermediateDirectories: false)
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }

                // Mint the new folder's bookmark *while the parent's scope
                // is still active* (the `defer` above releases it only when
                // this closure returns): the fresh folder has no sandbox
                // grant of its own — the extension covering it is the
                // parent's, so encoding after the release would fail.
                guard let encoded = BookStore.encodeBookmark(for: bookURL) else {
                    errorMessage = "Couldn't keep access to “\(name)” — try Open Book… instead."
                    return
                }
                bookBookmark = encoded
                bookSheet = BookPresentation(url: bookURL)
            }
        }
    }

    /// Pick (or create, via the picker's own new-folder button) the book
    /// folder, persist it as a security-scoped bookmark, and show it.
    private func openBookPicker() {
        BookFolderPicker.present { url in
            guard let encoded = BookStore.encodeBookmark(for: url) else { return }
            bookBookmark = encoded
            bookSheet = BookPresentation(url: url)
        }
    }

    /// Re-resolve the persisted bookmark and present the navigator. A stale
    /// bookmark (the folder moved) is refreshed in place; an unresolvable
    /// one (the folder is gone) is dropped rather than failing forever.
    private func showBook() {
        guard let resolved = BookStore.resolve(bookmark: bookBookmark) else {
            bookBookmark = ""
            return
        }
        if let refreshed = resolved.refreshed {
            bookBookmark = refreshed
        }
        bookSheet = BookPresentation(url: resolved.url)
    }

    // MARK: - Examples

    /// The bundled example documents — the root files of the `Examples/`
    /// folder reference, in filename order (their `01-`…`08-` prefixes are
    /// the intended reading order). The "Example Book" subfolder is not
    /// listed here; it ships behind the menu's own "Example Book…" item.
    /// Static: the bundle can't change mid-run.
    private static let exampleURLs: [URL] = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "md",
                                    subdirectory: "Examples") ?? []
        return urls
            .filter { !$0.hasDirectoryPath }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                == .orderedAscending }
    }()

    /// "01-Welcome.md" → "Welcome": the extension and the numeric ordering
    /// prefix are shelf arrangement, not part of the example's title.
    private static func exampleTitle(_ url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let digits = base.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return base }
        var rest = base.dropFirst(digits.count)
        if rest.first == "-" { rest.removeFirst() }
        return rest.isEmpty ? base : String(rest)
    }

    /// Open an example as a fresh document of the user's own: copy its text
    /// into the app's Documents folder (the bundled original is read-only)
    /// and open the copy exactly the way a book article opens (see
    /// `DocumentSceneOpener`). Re-opening an example makes another copy —
    /// "Welcome 2.md", "Welcome 3.md", … — rather than clobbering edits
    /// made to an earlier one.
    private func openExample(_ source: URL) {
        do {
            let text = try String(contentsOf: source, encoding: .utf8)
            let documents = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let title = Self.exampleTitle(source)
            var destination = documents.appendingPathComponent(title)
                .appendingPathExtension("md")
            var counter = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = documents.appendingPathComponent("\(title) \(counter)")
                    .appendingPathExtension("md")
                counter += 1
            }
            try Data(text.utf8).write(to: destination, options: .atomic)
            DocumentSceneOpener.open(destination)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Install the bundled example book: ask where to keep it (the same
    /// parent-folder picker as New Book…), copy the "Example Book" folder
    /// tree there, and adopt the copy as the current book — the same
    /// bookmark-and-show dance as `createBook()`, with a copied tree in
    /// place of an empty folder.
    private func installExampleBook() {
        guard let source = Bundle.main.url(forResource: "Example Book",
                                           withExtension: nil,
                                           subdirectory: "Examples") else {
            // Effectively unreachable — the folder ships in the bundle and
            // the tests pin it — but a silent no-op menu item is worse.
            errorMessage = "The example book is missing from the app bundle."
            return
        }
        // The picker chooses the *parent* folder — where the copy will
        // live; the book folder itself is created inside it below.
        BookFolderPicker.present { parent in
            let scoped = parent.startAccessingSecurityScopedResource()
            defer { if scoped { parent.stopAccessingSecurityScopedResource() } }

            // Unlike New Book, an existing "Example Book" is not an error —
            // the name isn't the user's to retype — so dedupe it instead.
            let fm = FileManager.default
            let name = source.lastPathComponent
            var bookURL = parent.appendingPathComponent(name, isDirectory: true)
            var counter = 2
            while fm.fileExists(atPath: bookURL.path) {
                bookURL = parent.appendingPathComponent("\(name) \(counter)",
                                                        isDirectory: true)
                counter += 1
            }
            do {
                try fm.copyItem(at: source, to: bookURL)
            } catch {
                errorMessage = error.localizedDescription
                return
            }

            // Mint the copy's bookmark *while the parent's scope is still
            // active* — same rationale as in `createBook()`.
            guard let encoded = BookStore.encodeBookmark(for: bookURL) else {
                errorMessage = "Couldn't keep access to “\(bookURL.lastPathComponent)” — try Open Book… instead."
                return
            }
            bookBookmark = encoded
            bookSheet = BookPresentation(url: bookURL)
        }
    }
}
