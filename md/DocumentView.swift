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
//  their own layout — and per *file* (see `ViewMode.swift`), so a document
//  opens back in the mode it was last shown in.
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
    ///
    /// Raw and uncoerced: the per-file memory seeds it on open
    /// (`applyOpenViewMode`) and `select(_:)` is the only thing that writes
    /// it afterwards — the window renders from this value (narrowed for the
    /// width, and overridden by a navigation nudge), which is what keeps two
    /// iPad windows independent.
    @SceneStorage("md.viewMode") private var storedMode = Mode.split.rawValue
    /// A navigation jump's transient override of the displayed mode, or nil
    /// when the window is simply showing its preference. Set by a jump whose
    /// destination lives in a pane the current mode doesn't show (see
    /// `jump(to note:)`); cleared by any deliberate mode pick and by opening
    /// another document.
    ///
    /// `@State`, deliberately: not `@SceneStorage`, and never written to the
    /// per-file memory. Merely *looking* at a note must not rewrite the
    /// layout the file is remembered in (see `ViewModeRule.displayedMode`).
    @State private var navigationMode: Mode?
    /// Bridges the editor's undo stack to the toolbar's Undo / Redo buttons.
    @StateObject private var editor = EditorController()
    /// The preview's recovery state for this document — its retry policy,
    /// its "stopped twice" notice, the document it last showed. Owned here,
    /// not by the pane, because the pane leaves the hierarchy in Edit and is
    /// rebuilt between Split and Preview (see `PreviewStatus`).
    @StateObject private var previewStatus = PreviewStatus()
    /// The latest Contents-menu jump for the preview pane; a fresh value per
    /// tap (see `PreviewNavigation`) so repeated taps re-scroll.
    @State private var previewNavigation: PreviewNavigation?
    /// The persisted book folder, as a base64 security-scoped bookmark
    /// (AppStorage has no `Data` flavor). Empty string = no book. AppStorage,
    /// not SceneStorage: the book outlives any one window.
    @AppStorage("md.bookBookmark") private var bookBookmark = ""
    /// The remembered PDF trim size, shared with the book navigator (one
    /// choice for the whole app). AppStorage, not SceneStorage: the last size
    /// the author picked should outlive the window. Stored as the stable
    /// `PageSize.id`; `PageSize.named` maps it back and defaults to A4.
    @AppStorage("md.pdfPageSize") private var pdfPageSizeID = PageSize.a4.id
    /// The Typing menu's two toggles, shared by every window and read live
    /// by the editor pane (see `SmartTextView`): whether Return continues
    /// lists, quotes and tables, and whether md capitalizes the first
    /// letter of a line and of a sentence. Both default to on.
    @AppStorage("md.continueLists") private var continueLists = true
    @AppStorage("md.capitalizeSentences") private var capitalizeSentences = true
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
    /// What the per-file open rule last ran against, in three states:
    /// `nil` — never ran; `.some(nil)` — ran on a document with no file yet
    /// (untitled); `.some(id)` — ran on that file's identity. The middle
    /// state is what tells a Save / Save As ("untitled becomes a file")
    /// apart from a genuine open, so the writer's current mode is carried
    /// onto the new file instead of being re-decided mid-write.
    @State private var lastIdentity: String??
    /// True when this window's document was opened by writer mode. Book
    /// articles are exempt from the per-file memory both ways — they
    /// neither seed the mode nor record it (see `BookArticleOpens`).
    @State private var isBookArticle = false
    /// How many documents this scene has shown, and which of them this view
    /// is — the guard that keeps one set of toolbar menus in the bar.
    ///
    /// Opening a document into a scene that is already showing one (the
    /// Examples menu, a book article — see `DocumentSceneOpener.open`)
    /// leaves the document view that was on screen *alive*: SwiftUI parents
    /// a second `DocumentHostingController` beside the first rather than
    /// replacing it. Both then apply `.toolbar` to the scene's one
    /// navigation bar, so after a second open every menu in it — and in the
    /// system's "…" overflow — appeared twice, after a third, three times.
    /// (Measured on iOS 26.5 and 27.0: 6 trailing item groups after the
    /// first open, 12 after the second, 18 after the third.)
    ///
    /// So each document view stamps itself with the scene's next generation
    /// as it appears, and only the newest stamp contributes toolbar content.
    /// `@SceneStorage`, not a global: a second iPad window has its own
    /// counter, and its document must not be silenced by an open in this one.
    @SceneStorage("md.documentGeneration") private var sceneGeneration = 0
    @State private var generation = 0
    /// The name the scene's title bar shows — published by the document
    /// view that is current, applied by every document view alive in the
    /// scene. See `DocumentTitle` for why the bar is not left to the system.
    @SceneStorage("md.documentTitle") private var sceneTitle = ""
    /// The scene's own token, minted by the first document view it shows —
    /// what `DocumentChords` keys the current document's chord actions by,
    /// so a second iPad window keeps its own current document.
    @SceneStorage("md.sceneToken") private var sceneToken = ""

    /// Whether this view is the document the scene is showing.
    private var isCurrentDocument: Bool {
        DocumentGeneration.isCurrent(view: generation, scene: sceneGeneration)
    }

    /// Claim this scene's next generation. Run from `onAppear`: every
    /// document view appears exactly once, and the newest claim is what
    /// retires the toolbar of the view it replaced.
    private func claimGeneration() {
        guard generation == DocumentGeneration.unstamped else { return }
        let next = DocumentGeneration.next(after: sceneGeneration)
        sceneGeneration = next
        generation = next
        sceneTitle = baseName
        if sceneToken.isEmpty { sceneToken = UUID().uuidString }
        DocumentChords.register(ownChordActions, scene: sceneToken)
    }

    /// This document's chord actions, for `DocumentChords`: what ⌘P,
    /// ⇧⌘B and ⌃⌘↑ / ⌃⌘↓ do when *this* is the document on screen.
    /// `document` is a binding and reads live; the appearance is the
    /// firing view's, passed in, because that view is in the same window.
    private var ownChordActions: DocumentChords.Actions {
        DocumentChords.Actions(
            print: { dark in
                await DocumentExport.print(source: document.text, title: baseName, dark: dark)
            },
            showBook: { showBook() },
            stepArticle: { stepArticle(by: $0) })
    }

    /// The actions a chord runs: the scene's current document's, whichever
    /// document view's hidden button the key command reached (see
    /// `DocumentChords`), or this view's own outside a scene.
    private var chordActions: DocumentChords.Actions {
        DocumentChords.actions(scene: sceneToken) ?? ownChordActions
    }

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
        /// The chord that picks this layout — ⌘1 / ⌘2 / ⌘3, off the one
        /// shared table (see `EditorShortcuts`).
        var shortcutAction: EditorShortcuts.Action {
            switch self {
            case .edit: return .viewEdit
            case .split: return .viewSplit
            case .preview: return .viewPreview
            }
        }
    }

    /// Split is only offered when there's horizontal room (iPad / Mac).
    private var isWide: Bool { sizeClass == .regular }

    /// The window's raw mode preference — what `@SceneStorage` holds,
    /// uncoerced, and with any navigation nudge deliberately ignored. This,
    /// not `effectiveMode`, is what gets remembered for a file: a Split
    /// chosen on an iPad shows as Edit on a phone, and must still be Split
    /// when the window is wide again (see `ViewMode.swift`). The Save-As
    /// migration in `applyOpenViewMode` reads it for the same reason — a
    /// nudge folded in here would be immortalised as the new file's
    /// preference.
    private var rawMode: Mode { Mode(rawValue: storedMode) ?? .split }

    private var availableModes: [Mode] { ViewModeRule.availableModes(isWide: isWide) }

    /// The mode actually shown: the navigation nudge if one is in force,
    /// otherwise the stored preference — either way coerced to one the
    /// current width supports (e.g. Split collapses to Edit on a phone).
    private var effectiveMode: Mode {
        ViewModeRule.displayedMode(preferred: rawMode,
                                   navigation: navigationMode,
                                   isWide: isWide)
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
    /// The document's diagram blocks (Mermaid / Graphviz / PlantUML), each
    /// exportable as a standalone `.svg`. Recomputed each render like the
    /// outline above so the SVG submenu's rows and enabled state track edits;
    /// it is one parse, the same cost the live preview already pays.
    private var diagrams: [DiagramSVG.Diagram] { DiagramSVG.diagrams(inSource: document.text) }

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
            // The chords that have no toolbar button of their own to hang
            // on. Behind the panes, and zero-sized: nothing to see, and
            // nothing to hit — the buttons exist so their key commands do.
            .background { keyboardShortcuts }
            .toolbar { toolbarContent }
            // The scene's one title, written by every document view alive
            // in it — see `DocumentTitle`.
            .navigationTitle(DocumentTitle.displayed(scene: sceneTitle, own: baseName))
            .navigationBarTitleDisplayMode(.inline)
            // Claim this scene's newest-document stamp; see `generation`.
            .onAppear { claimGeneration() }
            // DEBUG-only diagnostic harness (see `LaunchDiagnostics`); a
            // no-op in Release and for a launch with no harness arguments.
            .task { runLaunchDiagnostics() }
            // Recompute the footer's counters once per typing pause — the
            // task restarts (cancelling the sleeping one) on every change.
            .task(id: document.text) {
                counts = await counts.refreshed(from: document.text)
            }
            // Seed the window's mode from what this file was last shown in.
            // Keyed on `fileURL` and run on appearance too (`initial: true`),
            // so it covers both an open and the moment an untitled document
            // becomes a file. `applyOpenViewMode` does its own bookkeeping
            // to stay idempotent — the hook may fire more than once for the
            // same document.
            .onChange(of: fileURL, initial: true) { _, url in
                applyOpenViewMode(for: url)
                if isCurrentDocument {
                    sceneTitle = baseName
                    // An untitled document that just became a file: its
                    // registered step action must know the file.
                    if !sceneToken.isEmpty { DocumentChords.register(ownChordActions, scene: sceneToken) }
                }
                #if DEBUG
                LaunchDiagnostics.fileURLChanged(to: url, editor: editor)
                #endif
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

    /// Hands this window's editor controller to the DEBUG launch harness,
    /// which is how `-mdPresentFind` invokes the very row the toolbar's
    /// Find button invokes. Compiled away entirely in Release.
    private func runLaunchDiagnostics() {
        #if DEBUG
        // Every closure is this view's own method or property — the harness
        // re-implements nothing, it only reaches the same code a tap does.
        LaunchDiagnostics.documentAppeared(hooks: LaunchDiagnostics.DocumentHooks(
            editor: editor,
            fileURL: fileURL,
            baseName: baseName,
            dark: colorScheme == .dark,
            pageSize: PageSize.named(pdfPageSizeID),
            select: { select($0) },
            effectiveMode: { effectiveMode },
            rawMode: { rawMode },
            isWide: { isWide },
            text: { document.text },
            outline: { outline },
            notes: { noteEntries },
            jumpContents: { index in
                let entries = outline
                if entries.indices.contains(index) { jump(to: entries[index]) }
            },
            jumpNote: { index in
                let entries = noteEntries
                if entries.indices.contains(index) { jump(to: entries[index]) }
            },
            showBook: { showBook() },
            stepArticle: { stepArticle(by: $0) },
            rename: { await rename(to: $0) },
            scrollSync: scrollSync,
            diagrams: { diagrams }))
        #endif
    }

    // MARK: - Hardware keyboard

    /// The chords an iPad with a keyboard answers to, minus the ones a
    /// real toolbar button already carries (the mode chips on a wide
    /// window, and Find). Every value comes from `EditorShortcuts`, which
    /// is md.win's `CommandTable` in Swift — so the iPad, the Mac and
    /// Windows cannot drift apart without a test noticing.
    ///
    /// Which document the sink's actions run on is a separate question,
    /// answered by `DocumentChords`: every document view alive in the
    /// scene installs these buttons, and the one key command a chord
    /// resolves to reaches whichever view's SwiftUI registered — so the
    /// buttons ask the registry for the current document's actions.
    ///
    /// Why a sink instead of `.keyboardShortcut` on the menu rows: Print
    /// and Show Book live *inside* toolbar menus, whose contents are built
    /// only when the menu is opened, so a chord on one of those rows is
    /// not installed while the menu is shut — which is every moment the
    /// chord would be typed. A zero-sized button in the background is,
    /// and only one of the two spellings may exist or they race.
    ///
    /// The iPadOS menu bar (a `.commands` modifier on the `DocumentGroup`)
    /// is deliberately *not* here: this app's scene is a `DocumentGroup`
    /// plus a `DocumentGroupLaunchScene`, and the launch scene's browser
    /// plumbing is delicate enough (see `DocumentSceneOpener`) that it is
    /// not worth disturbing for a second copy of chords that already work.
    private var keyboardShortcuts: some View {
        Group {
            // On a wide window the three layouts are real toolbar chips and
            // carry their own chords. On a narrow one they collapse into a
            // Picker, which carries none — so they are installed here
            // instead, and only for the modes this width actually offers:
            // ⌘2 on a phone has no Split to select, and so selects nothing.
            if !isWide {
                ForEach(availableModes) { mode in
                    Button(mode.label) { select(mode) }
                        .keyboardShortcut(mode.shortcutAction)
                }
            }

            // Every action below is the *current* document's, not
            // necessarily this view's — see `DocumentChords`: the button
            // that carries the key command may belong to a document view
            // an open into this scene left behind.
            Button("Print…") {
                let dark = colorScheme == .dark
                Task { await chordActions.print(dark) }
            }
            .keyboardShortcut(.print)

            Button("Show Book") { chordActions.showBook() }
                .keyboardShortcut(.showBook)
                .disabled(bookBookmark.isEmpty)

            // Walking the book without leaving the keyboard. Both are
            // no-ops unless the open document really is an article of the
            // remembered book and there is one to step to — see
            // `stepArticle(by:)`.
            Button("Previous Article") { chordActions.stepArticle(-1) }
                .keyboardShortcut(.previousArticle)
            Button("Next Article") { chordActions.stepArticle(+1) }
                .keyboardShortcut(.nextArticle)
        }
        .frame(width: 0, height: 0)
        .clipped()
        .accessibilityHidden(true)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Only the document the scene is actually showing fills the bar. A
        // view left behind by an open into this same scene is still alive
        // and still rendering; without this guard its menus pile up in the
        // one navigation bar beside the live document's. See `generation`.
        if isCurrentDocument {
            documentToolbar
        }
    }

    @ToolbarContentBuilder
    private var documentToolbar: some ToolbarContent {
        // Mode switch. On a wide window the modes are inline glass chips
        // (the selected one tinted); on a phone they collapse to a single
        // menu so the bar stays uncluttered. Either way there's no nested
        // segmented-control chrome — hence no double border.
        if isWide {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ForEach(availableModes) { mode in
                    Button {
                        select(mode)
                    } label: {
                        Label(mode.label, systemImage: mode.symbol)
                    }
                    .labelStyle(.iconOnly)
                    .tint(effectiveMode == mode ? .accentColor : .secondary)
                    // ⌘1 / ⌘2 / ⌘3. Only over `availableModes`, so a chord
                    // for a layout this width doesn't offer is never
                    // installed in the first place.
                    .keyboardShortcut(mode.shortcutAction)
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

        // Undo / Redo and the Typing menu — only while a pane is being
        // edited; the buttons reflect and drive the editor's own undo stack,
        // the menu holds the two SmartTyping toggles (see `SmartTextView`).
        if effectiveMode != .preview {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Find and Replace — the system panel over the editor pane
                // (see `EditorController.presentFind`). First of the
                // editing affordances, and gone in Preview: the panel
                // searches the *source*, and a pane that isn't on screen
                // has nothing to search.
                Button { editor.presentFind() } label: {
                    Label("Find…", systemImage: "magnifyingglass")
                }
                .keyboardShortcut(.find)

                Button { editor.undo() } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!editor.canUndo)

                Button { editor.redo() } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!editor.canRedo)

                Menu {
                    Toggle("Continue Lists and Tables", isOn: $continueLists)
                    Toggle("Capitalize Sentences", isOn: $capitalizeSentences)
                } label: {
                    Label("Typing", systemImage: "keyboard")
                }
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
                        DocumentExport.promptRename(fileURL: fileURL, currentBaseName: baseName) {
                            await rename(to: $0)
                        }
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
                                                         dark: colorScheme == .dark,
                                                         pageSize: PageSize.named(pdfPageSizeID)) }
                } label: {
                    Label("Share Rendered PDF…", systemImage: "doc.richtext")
                }
                Button {
                    Task { await DocumentExport.exportPDF(source: document.text, title: baseName,
                                                          dark: colorScheme == .dark,
                                                          pageSize: PageSize.named(pdfPageSizeID)) }
                } label: {
                    Label("Export as PDF…", systemImage: "square.and.arrow.down")
                }
                // The trim size both PDF actions above use. A Picker inside a
                // Menu renders as an inline checklist — the platform's own
                // size-picker idiom — and the choice is remembered across
                // launches (and shared with the book navigator's PDF compile).
                Picker(selection: $pdfPageSizeID) {
                    ForEach(PageSize.all) { size in
                        Text(size.label).tag(size.id)
                    }
                } label: {
                    Label("PDF Page Size", systemImage: "rectangle.portrait")
                }
                Button {
                    Task { await DocumentExport.exportHTML(source: document.text, title: baseName,
                                                           dark: colorScheme == .dark) }
                } label: {
                    Label("Export as HTML…", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Button {
                    // The document as a single-unit EPUB (see
                    // DocumentExport.exportDocumentEPUB): its title comes from
                    // the front-matter `title:` or the file name, so `baseName`
                    // is passed as the fallback. No `dark:` — a reflowing book
                    // owns its own theme.
                    Task { await DocumentExport.exportDocumentEPUB(source: document.text,
                                                                   fileName: baseName) }
                } label: {
                    Label("Export as EPUB…", systemImage: "books.vertical")
                }
                Button {
                    // No theme and no rendering: the .tex is written from the
                    // parsed blocks alone, so there is nothing to await.
                    DocumentExport.exportLaTeX(source: document.text, title: baseName)
                } label: {
                    Label("Export as LaTeX…", systemImage: "function")
                }
                Button {
                    // The document as a `.textbundle` (text.md + info.json +
                    // assets/). `fileURL` is passed so referenced local images
                    // beside the saved document can be copied into assets/;
                    // pure string work plus a few small reads, so no await.
                    DocumentExport.exportTextBundle(source: document.text,
                                                    fileURL: fileURL, title: baseName)
                } label: {
                    Label("Export as TextBundle…", systemImage: "shippingbox")
                }
                // One diagram → one standalone .svg. A submenu lists the
                // document's diagram blocks (by engine and a snippet of the
                // source); math is not here — KaTeX renders it as HTML+CSS, not
                // SVG, so there is no vector to export. Disabled when the
                // document has no diagrams.
                Menu {
                    ForEach(diagrams, id: \.ordinal) { diagram in
                        Button {
                            Task { await DocumentExport.exportDiagramSVG(
                                source: document.text, title: baseName, diagram: diagram) }
                        } label: {
                            Text(diagram.menuTitle)
                        }
                    }
                } label: {
                    Label("Export Diagram as SVG…",
                          systemImage: "point.3.connected.trianglepath.dotted")
                }
                .disabled(diagrams.isEmpty)
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

    /// Binds the segmented control to the persisted mode: it shows what the
    /// window displays (nudge included) and every pick it makes is
    /// deliberate, so it reads `effectiveMode` and writes through `select`.
    private var modeBinding: Binding<Mode> {
        Binding(get: { effectiveMode }, set: { select($0) })
    }

    // MARK: - Rename

    /// Rename the open file to what the writer typed, and name the title
    /// bar after it. `fileURL` does not change after a coordinated move —
    /// measured on iOS 26.5 and 27.0 — so the bar would otherwise keep the
    /// old name on a release where md names the bar itself (see
    /// `DocumentTitle`). The move is `DocumentExport.rename`'s; only the
    /// title is this view's. Returns the failure to show, or nil.
    private func rename(to typed: String) async -> String? {
        guard let fileURL else { return nil }
        let failure = await DocumentExport.rename(fileURL: fileURL, to: typed)
        if failure == nil {
            sceneTitle = DocumentExport.baseName(afterRenaming: fileURL, to: typed)
        }
        return failure
    }

    // MARK: - View mode

    /// The one path that changes the view mode *deliberately* — the wide
    /// window's chips and the phone's menu both come through here, so there
    /// is no second way to pick a mode and forget to remember it.
    ///
    /// Writes the RAW mode: to the window (`@SceneStorage`, which is what
    /// keeps two iPad windows on separate layouts) and to this file's
    /// memory. Never `effectiveMode`'s output — a Split the user picked on
    /// an iPad has to survive being displayed as Edit on their phone.
    ///
    /// A navigation jump is **not** a deliberate pick and must not come
    /// through here: it sets `navigationMode` instead, which changes what is
    /// displayed and nothing else. See `jump(to note:)`.
    private func select(_ mode: Mode) {
        // A deliberate pick supersedes any navigation nudge: the user has
        // said what they want the window to show, so the transient override
        // goes and the preference below is what the file is remembered by.
        navigationMode = nil
        storedMode = mode.rawValue
        // Book articles are exempt: writer mode's own layout is the
        // writer's, not something to record against each chapter file.
        guard !isBookArticle, let fileURL else { return }
        ViewModeMemory.remember(mode, for: ViewModeMemory.identity(for: fileURL))
    }

    /// Seed the window's mode for the document that just opened.
    ///
    /// Runs from a `fileURL`-keyed `onChange(initial: true)`, which fires
    /// on appearance, on an open into an existing window, and on the moment
    /// an untitled document first gets a file. Those last two need telling
    /// apart, which is what `lastIdentity`'s three states are for.
    private func applyOpenViewMode(for url: URL?) {
        let identity = url.map(ViewModeMemory.identity(for:))

        // Writer mode steps from chapter to chapter through this same
        // editor, so an article open has to be told from a plain one — or
        // every step would re-run the rule and flip the writer into Preview
        // on the chapter they were about to write.
        //
        // Claimed here, *before* the unchanged-identity return below: the
        // mark belongs to this open and must not outlive it. Re-opening the
        // article that is already the open document arrives with the
        // identity unchanged, and a mark left pending would then be handed
        // to the next ordinary open of that same file.
        let cameFromBook = url.map(BookArticleOpens.claimOpen) ?? false

        // Same document as last time: the hook re-fired without the file
        // changing (SwiftUI is free to rebuild the view). Nothing to decide,
        // and re-deciding would overrule a mode the user has since picked.
        if case .some(let previous) = lastIdentity, previous == identity {
            // …but if this re-fire *was* a book open of the document already
            // on screen, the window is showing an article from here on: the
            // exemption applies even though there is nothing to decide.
            if cameFromBook { isBookArticle = true }
            return
        }
        // Whether the *previous* run saw an untitled document, captured
        // before the state moves on.
        let wasUntitled = lastIdentity == .some(nil)
        lastIdentity = .some(identity)

        // A nudge belongs to the document it was made in, so a different
        // document clears it. Save / Save As is the exception, and is not a
        // different document: the writer is still looking at the same text,
        // and pulling them back out of the pane they jumped to mid-write is
        // exactly the flip this hook's bookkeeping exists to prevent.
        if !wasUntitled { navigationMode = nil }

        isBookArticle = cameFromBook
        guard !isBookArticle else { return }

        if wasUntitled, let identity {
            // Save / Save As: an untitled document became a file. The writer
            // is already in a mode — carry it over rather than re-deciding
            // mid-write.
            ViewModeMemory.remember(rawMode, for: identity)
            return
        }

        let mode = ViewModeRule.openViewMode(
            remembered: identity.flatMap { ViewModeMemory.lookup($0) },
            isEmptyDocument: document.text.isEmpty,
            hasFileIdentity: identity != nil,
            isWide: isWide)
        // Raw, uncoerced — `effectiveMode` narrows it for display.
        storedMode = mode.rawValue
        // No identity means nothing to key the memory on (a never-saved
        // document): decide, but don't store.
        if let identity { ViewModeMemory.remember(mode, for: identity) }
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
        MarkdownEditor(text: $document.text, controller: editor, scrollSync: scrollSync,
                       continueLists: continueLists, capitalizeSentences: capitalizeSentences)
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
                        scrollSync: scrollSync, status: previewStatus)
            .ignoresSafeArea(.container, edges: .bottom)
    }

    // MARK: - Navigation (Contents / Notes / Book)

    /// Jump to a heading — in whichever pane(s) the current mode shows:
    /// the preview scrolls to the heading's anchor, the editor moves its
    /// caret to the heading's source line, Split does both.
    ///
    /// No navigation nudge is needed here, and none should be added: a
    /// heading exists in *both* panes, so whatever the window is showing,
    /// the destination is on screen. (The Android port's Contents tap did
    /// switch modes, which is where that port's data loss came from; this
    /// one never has.)
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
    /// lands in the editor — a Preview-only window is nudged to Edit first
    /// so the destination is actually visible. (`scrollTo` holds the request
    /// until the freshly created editor pane can honor it.)
    ///
    /// The nudge is transient — `navigationMode`, never `select(_:)`.
    /// Reading one note is not a statement about how the file should open
    /// next time, and routing it through the persisting setter is what used
    /// to rewrite a Preview file's remembered mode to Edit, permanently.
    /// Before per-file memory existed the mode was session-only and a jump
    /// worked exactly like this; the nudge restores that.
    ///
    /// Assigned only when a nudge is actually called for: a second note jump
    /// from an already-nudged window must not clear the override and drop
    /// the reader back into Preview.
    private func jump(to note: NoteEntry) {
        if let nudge = ViewModeRule.navigationNudge(displayed: effectiveMode, wants: .edit) {
            navigationMode = nudge
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

    /// Previous / Next Article (⌃⌘↑ / ⌃⌘↓): step one place along the
    /// remembered book's reading order and open what is there.
    ///
    /// Everything about it is a no-op unless it applies — no book, an
    /// untitled document, a document that isn't in the book, the first
    /// article stepping back or the last stepping on. A chord that has
    /// nowhere to go does nothing, which is what a chord on an iPad is
    /// expected to do; there is no alert to dismiss and nothing moves.
    ///
    /// The book is read from disk on the keystroke rather than kept in
    /// view state: two shallow directory reads (`BookTree.read`), and the
    /// alternative is a stale order after a rename or a reorder in the
    /// navigator. The open itself is the navigator's own — hold the book's
    /// security scope for as long as the article may stay open, and mark
    /// the open as a book open so the per-file view-mode memory stays out
    /// of it (a writer stepping to the next chapter keeps the mode they
    /// are writing in).
    private func stepArticle(by offset: Int) {
        guard let fileURL, !bookBookmark.isEmpty,
              let resolved = BookStore.resolve(bookmark: bookBookmark) else { return }
        if let refreshed = resolved.refreshed {
            bookBookmark = refreshed
        }
        let root = resolved.url
        let order = BookTree.readingOrder(BookTree.read(root: root))
        guard let destination = BookTree.step(from: fileURL, by: offset, in: order) else { return }

        BookScope.hold(root)
        BookArticleOpens.mark(destination)
        DocumentSceneOpener.open(destination)
    }

    // MARK: - Examples

    /// The bundled example documents — the root files of the `Examples/`
    /// folder reference, in filename order (their `01-`…`08-` prefixes are
    /// the intended reading order). The "Example Book" subfolder is not
    /// listed here; it ships behind the menu's own "Example Book…" item.
    /// Static: the bundle can't change mid-run.
    /// (Internal, not private: the DEBUG launch harness opens an example
    /// through this same list — see `LaunchDiagnostics`.)
    static let exampleURLs: [URL] = {
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
            DocumentSceneOpener.open(try Self.copyExample(source))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The copy half of `openExample`, on its own so the naming rule can be
    /// tested and so the DEBUG launch harness drives the very same path the
    /// menu row does (see `LaunchDiagnostics`).
    static func copyExample(_ source: URL) throws -> URL {
        let text = try String(contentsOf: source, encoding: .utf8)
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let title = exampleTitle(source)
        var destination = documents.appendingPathComponent(title)
            .appendingPathExtension("md")
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = documents.appendingPathComponent("\(title) \(counter)")
                .appendingPathExtension("md")
            counter += 1
        }
        try Data(text.utf8).write(to: destination, options: .atomic)
        return destination
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

// MARK: - Which document view owns the scene's toolbar

/// The rule that keeps one set of toolbar menus in a scene's navigation bar.
///
/// Opening a document into a scene that is already showing one — the
/// Examples menu, a book article, anything through
/// `DocumentSceneOpener.open` — leaves the document view that was on screen
/// alive: SwiftUI parents a second `DocumentHostingController` beside the
/// first instead of replacing it. Both then apply `.toolbar` to the one
/// navigation item the scene has, so a second open showed every menu twice
/// and a third showed it three times (measured on iOS 26.5 and 27.0: 6
/// trailing item groups, then 12, then 18). The Find row is the same story
/// with teeth: the row that stayed *visible* in the bar was the first
/// view's, so tapping it searched a document that was no longer on screen.
///
/// So each document view stamps itself with the scene's next generation as
/// it appears, and only the newest stamp fills the bar. Counting, rather
/// than "is my view visible", because a replaced view is not told anything:
/// it is never asked to disappear, and its panes stay laid out.
///
/// A plain `Int` per scene (`@SceneStorage`), not a global: a second iPad
/// window keeps its own count, and its document must not be silenced by an
/// open in this one.
enum DocumentGeneration {

    /// A document view that has not stamped itself yet. It is the one that
    /// just appeared, so it is current by construction — the alternative
    /// (treating it as stale) would blank the bar for the frame between
    /// first render and `onAppear`.
    static let unstamped = 0

    /// The stamp the document view appearing now should take.
    static func next(after scene: Int) -> Int {
        // Saturating, so a scene restored with a wild counter cannot wrap
        // into `unstamped` and hand two views the bar at once.
        scene >= Int.max - 1 ? Int.max : scene + 1
    }

    /// Whether the view holding `view` is the one the scene is showing:
    /// nothing newer has claimed the bar since it did.
    ///
    /// `>=`, not `==`, and that is the load-bearing part. `@SceneStorage`
    /// only round-trips inside a real scene — host a `DocumentView` in a
    /// plain window (as `EditorShortcutsTests` does) and the write is
    /// dropped, so the counter reads 0 for ever while each view holds 1. An
    /// `==` rule calls *every* view stale then and the toolbar disappears
    /// altogether, chords and all: a worse bug than the doubled menus this
    /// exists to stop. With `>=` the same failure degrades to the old
    /// behaviour instead, which is the direction to fail in.
    static func isCurrent(view: Int, scene: Int) -> Bool {
        view == unstamped || view >= scene
    }
}

// MARK: - Which document a chord acts on

/// The rule that keeps ⌘P, ⇧⌘B and ⌃⌘↑ / ⌃⌘↓ acting on the document on
/// screen.
///
/// The chords with no toolbar button of their own are carried by hidden
/// buttons behind the panes (`DocumentView.keyboardShortcuts`), and every
/// document view alive in a scene — the retired ones an open into the same
/// scene leaves behind (see `DocumentGeneration`) included — installs its
/// own. SwiftUI registers one key command per chord for the scene and hands
/// it to one of those views, not reliably the newest: measured on iOS 26.5
/// and 27.0, with Welcome replaced by Formatting, ⌘P's print job was named
/// *Welcome*, and ⌃⌘↓ on a book article stepped from Welcome — which is
/// not in the book — and so did nothing. Hiding the retired views' buttons
/// does not help: the key command then goes with them, and no chord is
/// installed at all after the second open (measured the same way).
///
/// So the buttons stay where SwiftUI finds them and *ask* which document is
/// current: the view that claims the scene's newest generation registers
/// its actions here under the scene's own token (`@SceneStorage`, so a
/// second iPad window is a second entry), and whichever view's button the
/// key command reaches runs the registered actions. A view outside any
/// scene — a hosted test — has no token and runs its own.
@MainActor
enum DocumentChords {

    /// What the three chords do for one document.
    struct Actions {
        /// ⌘P, with the firing view's appearance (same window, same
        /// appearance).
        let print: (Bool) async -> Void
        /// ⇧⌘B.
        let showBook: () -> Void
        /// ⌃⌘↑ / ⌃⌘↓, by −1 / +1.
        let stepArticle: (Int) -> Void
    }

    private static var byScene: [String: Actions] = [:]

    /// The document that just became current in the scene `token` names
    /// registers its actions; the previous entry for that scene is replaced.
    static func register(_ actions: Actions, scene token: String) {
        guard !token.isEmpty else { return }
        byScene[token] = actions
    }

    /// The current document's actions for the scene `token` names, or nil
    /// when the scene has none — or no token, which is a view outside any
    /// scene.
    static func actions(scene token: String) -> Actions? {
        guard !token.isEmpty else { return nil }
        return byScene[token]
    }

    /// Forget a scene's entry. For the tests.
    static func forget(scene token: String) {
        byScene[token] = nil
    }
}

// MARK: - Which name the scene's title bar shows

/// The rule that keeps the navigation bar naming the document on screen.
///
/// Every document view alive in a scene — the one on screen and the ones an
/// open into the same scene left behind (see `DocumentGeneration`) — writes
/// its navigation title into the *one* navigation item the scene has, and
/// the bar shows whichever write came last. On iOS 26 the system keeps that
/// item's title in step with the document itself. On iOS 27 it stops after
/// the second document a scene shows — measured on 27.0: Welcome, then
/// Formatting, then Plots opened, and the bar still read "Formatting" with
/// `UIDocumentViewController.document` correctly Plots.md; a rename after
/// that was ignored the same way. Stepping through a book's articles is the
/// same open three times over, so from the third chapter on the bar named
/// the wrong file.
///
/// So md names the bar itself. The current view publishes its name to the
/// scene (`@SceneStorage`, so a second iPad window keeps its own), and
/// *every* view applies the scene's name — which is what makes the write
/// order irrelevant: a retired view re-rendering after the newest one, the
/// very order the toolbar guard produces, writes the newest name too. An
/// in-app Rename publishes the new name the moment the file has moved,
/// because `fileURL` does not follow a coordinated move on either release.
enum DocumentTitle {

    /// The title a document view applies: the scene's published name, or
    /// its own when nothing has been published yet — a view hosted outside
    /// a real scene (a test) never sees a `@SceneStorage` write land, and a
    /// blank bar is the failure this must not degrade into.
    static func displayed(scene: String, own: String) -> String {
        scene.isEmpty ? own : scene
    }
}
