//
//  BookNavigator.swift
//  md
//
//  Created by nettrash on 08/07/2026.
//
//  "Writer mode": a book is nothing more than a folder the user picks.
//  Its subfolders are chapters, its Markdown files are articles — no
//  manifest, no sidecar metadata, so any Files-app change to the folder
//  *is* a change to the book. The navigator sheet lists the book and opens
//  an article in the editor; it can create a chapter folder or a starter
//  article, and each row's context menu manages the tree in place:
//  Rename… (keeping the numeric order prefix and extension), Move Up /
//  Move Down (materialized by renumbering the sibling group's "NN-"
//  prefixes — see BookNaming), and a confirmed Delete…. The Files app
//  stays just as authoritative — these are conveniences over the same
//  plain folder, not a competing source of truth.
//
//  Access rights: the folder comes from the system folder picker, so it is
//  security-scoped. It persists across launches as a security-scoped
//  bookmark (base64 in `@AppStorage("md.bookBookmark")` — see
//  DocumentView), and every folder enumeration / article open / creation
//  here brackets itself in start/stopAccessingSecurityScopedResource on
//  the book root.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

/// Trace for the book navigator's file operations, so a failed open is
/// visible in Console (subsystem `me.nettrash.md`, category `book`).
private let bookLog = Logger(subsystem: "me.nettrash.md", category: "book")

// MARK: - Persistence (security-scoped bookmark ↔ AppStorage string)

/// Wraps the chosen book folder for `.sheet(item:)` presentation — a plain
/// `URL` isn't `Identifiable`, and a fresh `id` per presentation means
/// re-opening the same book still presents.
struct BookPresentation: Identifiable {
    let id = UUID()
    let url: URL
}

/// Encoding and resolving the persisted book folder. `@AppStorage` has no
/// `Data` flavor, hence the base64 string round-trip.
enum BookStore {

    /// Encode a security-scoped bookmark for the picked folder. Bookmark
    /// creation itself needs the scope active on the picker-provided URL.
    /// On iOS a bookmark made from a scoped URL carries the scope
    /// implicitly (`.withSecurityScope` is a macOS-only option).
    static func encodeBookmark(for url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return (try? url.bookmarkData()).map { $0.base64EncodedString() }
    }

    /// Resolve a stored bookmark back to the folder. When iOS flags the
    /// data stale (the folder moved), a refreshed encoding is returned for
    /// the caller to persist so future launches resolve directly. `nil`
    /// when the string can't be decoded or the folder is gone entirely.
    static func resolve(bookmark base64: String) -> (url: URL, refreshed: String?)? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else {
            return nil
        }
        return (url, stale ? encodeBookmark(for: url) : nil)
    }
}

// MARK: - Opening a document programmatically

/// Ask the system to open a document in the editor.
///
/// The obvious API — SwiftUI's `openDocument` environment action — is
/// macOS-only (`@available(iOS, unavailable)` in the SDK), and iOS's
/// `DocumentGroup` ships *no* public programmatic open at all (a
/// well-documented gap). What DocumentGroup does handle is the document
/// user activity the system itself uses to open a document scene — the
/// path behind dragging a file out of Files into a new window on iPad:
/// activity type `com.apple.SwiftUI.document` carrying the file URL
/// under `documentURL` (both strings verified against the shipping
/// SwiftUI.framework binary). So we request a scene activation with
/// exactly that activity. The app declares multiple-scene support; on
/// iPad this may open the document in a new window, on a single-scene
/// iPhone the system routes the request into the existing scene.
/// Best-effort by nature — replace with the real `openDocument` the day
/// Apple ships it for iOS. Both the book navigator's article rows and
/// DocumentView's Examples menu open through here.
@MainActor
enum DocumentSceneOpener {

    static func open(_ url: URL) {
        let activity = NSUserActivity(activityType: "com.apple.SwiftUI.document")
        activity.userInfo = ["documentURL": url]
        // (`var`, not `let`: UIKit's Swift overlay imports the request as a
        // value type.)
        var request = UISceneSessionActivationRequest()
        request.userActivity = activity
        UIApplication.shared.activateSceneSession(for: request) { error in
            // Fires only when the *activation* fails (e.g. multitasking
            // restrictions) — a Console trace, not an alert: the requesting
            // UI (sheet / menu) is already dismissed by then.
            bookLog.error("open document failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Folder picker

/// Presents the system folder picker imperatively and delivers the picked
/// folder. Imperative (not `.fileImporter`) for the same reason the export
/// paths are — and it replicates `DocumentExport`'s top-view-controller
/// walk locally because that helper is private to the export file, which
/// this feature leaves untouched.
///
/// The picker's own "new folder" affordance doubles as *starting* a book:
/// create a fresh folder right inside the picker, then choose it.
@MainActor
final class BookFolderPicker: NSObject, UIDocumentPickerDelegate {

    /// UIKit holds the picker's delegate weakly; this static reference
    /// keeps the handler alive for the duration of the presentation.
    private static var active: BookFolderPicker?

    private let onPick: (URL) -> Void

    private init(onPick: @escaping (URL) -> Void) {
        self.onPick = onPick
    }

    static func present(onPick: @escaping (URL) -> Void) {
        guard let presenter = topViewController() else { return }
        let handler = BookFolderPicker(onPick: onPick)
        active = handler
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = handler
        presenter.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        Self.active = nil
        guard let url = urls.first else { return }
        onPick(url)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Self.active = nil
    }

    /// The view controller to present from — the same walk DocumentExport
    /// uses (kept private there; replicated rather than exposed).
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// MARK: - Ordering

/// The book's display order, applied everywhere a book lists names —
/// chapters and articles alike. Names with a leading integer prefix
/// ("01-intro", "2. setup") come first, ordered by that number; everything
/// else follows alphabetically, case-insensitively
/// (`localizedStandardCompare` — the Finder's ordering). Ties between
/// equal numbers ("01-a" vs "1-b") fall back to the name compare so the
/// order stays deterministic.
enum BookOrdering {

    static func areInIncreasingOrder(_ a: String, _ b: String) -> Bool {
        switch (leadingNumber(a), leadingNumber(b)) {
        case let (x?, y?):
            if x != y { return x < y }
            return a.localizedStandardCompare(b) == .orderedAscending
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil):
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    /// The integer prefix of a name ("01-intro" → 1), or nil when the name
    /// doesn't start with an ASCII digit (or the digit run overflows Int —
    /// such a name just sorts with the alphabetical rest).
    static func leadingNumber(_ name: String) -> Int? {
        let digits = name.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }
}

// MARK: - Naming (rename / reorder plans)

/// Pure name arithmetic behind the navigator's manage actions. Everything
/// here takes sibling *names* and returns names — no file system, no I/O —
/// so the rename and renumbering rules are unit-testable on their own; the
/// navigator applies the resulting plans with `FileManager` moves inside
/// the book's security scope.
enum BookNaming {

    /// What counts as an article, shared with the navigator's listing.
    /// Only these are treated as an extension when splitting names — a
    /// chapter folder named "2. setup" keeps its dot.
    static let articleExtensions: Set<String> = ["md", "markdown", "txt"]

    /// "01-The Editor.md" → ("01-The Editor", ".md"). The extension part
    /// includes its dot so the pieces concatenate back losslessly.
    static func splitExtension(_ name: String) -> (base: String, ext: String) {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, articleExtensions.contains(ext.lowercased()) else {
            return (name, "")
        }
        return (String(name.dropLast(ext.count + 1)), "." + ext)
    }

    /// "01-The Editor" → ("01-", "The Editor"). The separator run after the
    /// digits ("-", ".", "_" or spaces) belongs to the prefix, so a rename
    /// keeps the author's own punctuation ("2. setup" keeps "2. "). A name
    /// that is *all* digits has no display part left and counts as
    /// unprefixed — its digits are its title.
    static func splitPrefix(_ base: String) -> (prefix: String, display: String) {
        let digits = base.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return ("", base) }
        var rest = base.dropFirst(digits.count)
        var separator = ""
        while let head = rest.first, head == "-" || head == "." || head == "_" || head == " " {
            separator.append(head)
            rest.removeFirst()
        }
        guard !rest.isEmpty else { return ("", base) }
        return (String(digits) + separator, String(rest))
    }

    /// The name as the user reads (and retypes) it: extension and numeric
    /// ordering prefix stripped — "01-The Editor.md" → "The Editor".
    static func displayName(_ name: String) -> String {
        splitPrefix(splitExtension(name).base).display
    }

    /// The on-disk name for a rename to `display`: only the display part
    /// changes — the existing numeric prefix and extension are kept, so a
    /// rename never reorders the book.
    static func renamed(_ name: String, toDisplay display: String) -> String {
        let (base, ext) = splitExtension(name)
        return splitPrefix(base).prefix + display + ext
    }

    /// Reorder plan: move `siblings[moveFrom]` to index `to` (the array is
    /// the group's *displayed* order), then materialize the new order by
    /// renumbering every sibling with a zero-padded two-digit prefix —
    /// "01-", "02-", … — keeping each item's display name and extension;
    /// items that had no numeric prefix gain one. Returns only the names
    /// that actually change, in the new display order; an out-of-range
    /// index returns an empty plan.
    static func renamePlan(siblings: [String], moveFrom: Int,
                           to: Int) -> [(from: String, to: String)] {
        guard siblings.indices.contains(moveFrom), siblings.indices.contains(to) else {
            return []
        }
        var ordered = siblings
        ordered.insert(ordered.remove(at: moveFrom), at: to)
        return ordered.enumerated().compactMap { index, name in
            let (base, ext) = splitExtension(name)
            let target = String(format: "%02d-", index + 1) + splitPrefix(base).display + ext
            return target == name ? nil : (from: name, to: target)
        }
    }
}

// MARK: - Compiling (book → one Markdown source)

/// Compiles a book's already-read pieces into a single Markdown source for
/// the PDF pipeline. Pure string assembly — no file system — so the shape
/// (title page, reading order, page breaks) is unit-testable on its own;
/// the navigator reads the article files inside the book's security scope
/// and hands the strings here.
enum BookLibrary {

    /// One unit of the book: the root articles (no title) or a chapter —
    /// its display title and its articles' contents, in reading order.
    struct Part {
        let title: String?
        let articles: [String]

        init(title: String? = nil, articles: [String]) {
            self.title = title
            self.articles = articles
        }
    }

    /// The compiled book: a title page ("# <book name>"), then the parts
    /// in order — a chapter opens with "# <chapter name>" on a page of its
    /// own — and every article starts on a fresh page. The joints are the
    /// parser's own `\newpage` marker, so the PDF renderers paginate the
    /// compiled book exactly as they would a hand-written document.
    /// Article content is verbatim: nothing is inserted or stripped beyond
    /// those page breaks (the renderer already keeps private notes out,
    /// and a `---` stays an ordinary rule).
    static func compile(bookName: String, parts: [Part]) -> String {
        var units = ["# \(bookName)"]
        for part in parts {
            if let title = part.title {
                units.append("# \(title)")
            }
            units.append(contentsOf: part.articles)
        }
        return units.joined(separator: "\n\n\\newpage\n\n")
    }
}

// MARK: - Navigator sheet

struct BookNavigator: View {
    /// The book's root folder (security-scoped; see the header comment).
    let root: URL

    @Environment(\.dismiss) private var dismiss
    /// For the compiled PDF's theme, same as the document's share menu.
    @Environment(\.colorScheme) private var colorScheme

    /// One chapter: a subfolder of the book root and its articles.
    private struct Chapter: Identifiable {
        let url: URL
        let articles: [URL]
        var id: URL { url }
    }

    /// Loose articles directly at the book root, shown before the chapters.
    @State private var topArticles: [URL] = []
    @State private var chapters: [Chapter] = []

    // Creation prompts. The article prompt needs to know *where* to create,
    // so the tapped section's folder is stashed alongside the flag.
    @State private var showNewChapter = false
    @State private var newChapterName = ""
    @State private var showNewArticle = false
    @State private var newArticleName = ""
    @State private var newArticleFolder: URL?

    // Management prompts (each row's context menu). The tapped item is
    // stashed alongside the flag, same as the creation prompts above;
    // `deleteIsChapter` picks the confirmation wording.
    @State private var showRename = false
    @State private var renameName = ""
    @State private var renameTarget: URL?
    @State private var showDeleteConfirm = false
    @State private var deleteTarget: URL?
    @State private var deleteIsChapter = false

    /// A file operation failed (open / create / manage); shown in an alert
    /// rather than failing silently — a dead tap reads as a broken app.
    @State private var errorMessage: String?

    /// What counts as an article. Everything else in the folder (images,
    /// PDFs, …) is simply not part of the book's navigation. Shared with
    /// the naming logic, which must split the same extensions.
    private static let articleExtensions = BookNaming.articleExtensions

    var body: some View {
        NavigationStack {
            List {
                // Loose articles at the book root come first. The section is
                // shown even when empty — its "New Article…" row is how the
                // first root article gets created.
                Section {
                    ForEach(topArticles, id: \.self) { articleRow($0, siblings: topArticles) }
                    newArticleButton(in: root)
                }
                ForEach(chapters) { chapter in
                    Section {
                        ForEach(chapter.articles, id: \.self) {
                            articleRow($0, siblings: chapter.articles)
                        }
                        newArticleButton(in: chapter.url)
                    } header: {
                        // The chapter's manage menu hangs off its header —
                        // a chapter has no row of its own.
                        Text(chapter.url.lastPathComponent)
                            .contextMenu {
                                manageMenu(for: chapter.url,
                                           siblings: chapters.map(\.url),
                                           isChapter: true)
                            }
                    }
                }
            }
            .navigationTitle(root.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newChapterName = ""
                        showNewChapter = true
                    } label: {
                        Label("New Chapter…", systemImage: "folder.badge.plus")
                    }
                }
                // The whole book as one file: root articles first, then the
                // chapters in order (see BookLibrary.compile / EpubBook).
                // The PDFs render through the same pipeline as a single
                // document — real A4 pages, each part starting a fresh one;
                // the EPUB packages the same reading order with rich blocks
                // snapshotted to images.
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            shareBookPDF()
                        } label: {
                            Label("Share as PDF", systemImage: "doc.richtext")
                        }
                        Button {
                            exportBookPDF()
                        } label: {
                            Label("Export as PDF…", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            exportBookEPUB()
                        } label: {
                            Label("Export as EPUB…", systemImage: "books.vertical")
                        }
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .alert("New Chapter", isPresented: $showNewChapter) {
                TextField("Chapter name", text: $newChapterName)
                Button("Create") { createChapter() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Creates a folder in “\(root.lastPathComponent)”.")
            }
            .alert("New Article", isPresented: $showNewArticle) {
                TextField("Article name", text: $newArticleName)
                Button("Create") { createArticle() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Creates a Markdown file in “\(newArticleFolder?.lastPathComponent ?? "")”.")
            }
            .alert("Rename", isPresented: $showRename) {
                TextField("Name", text: $renameName)
                Button("Rename") { performRename() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The numeric order prefix and file extension are kept.")
            }
            .alert("Delete “\(deleteTarget.map { BookNaming.displayName($0.lastPathComponent) } ?? "")”?",
                   isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) { performDelete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteIsChapter
                     ? "The chapter and all its articles will be deleted. This cannot be undone."
                     : "This cannot be undone.")
            }
            .alert("Something Went Wrong",
                   isPresented: Binding(get: { errorMessage != nil },
                                        set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task { refresh() }
        }
    }

    // MARK: Rows

    private func articleRow(_ url: URL, siblings: [URL]) -> some View {
        Button {
            open(url)
        } label: {
            // Names read without the file extension — the extension is an
            // implementation detail of "article", not part of its title.
            Label(url.deletingPathExtension().lastPathComponent, systemImage: "doc.text")
        }
        .contextMenu {
            manageMenu(for: url, siblings: siblings, isChapter: false)
        }
        // Swipe-to-delete as well; it routes through the same confirmation
        // (no full swipe — an unconfirmed full swipe would delete a file).
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                confirmDelete(url, isChapter: false)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// The shared manage menu (context menu content) for an article row or
    /// a chapter header. Move Up / Move Down act within the item's own
    /// sibling group — `siblings` in displayed order — and are disabled at
    /// the ends; the moves are materialized by renumbering (see BookNaming).
    @ViewBuilder
    private func manageMenu(for url: URL, siblings: [URL], isChapter: Bool) -> some View {
        let index = siblings.firstIndex(of: url)
        Button {
            startRename(url)
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        Button {
            move(url, in: siblings, by: -1)
        } label: {
            Label("Move Up", systemImage: "arrow.up")
        }
        .disabled(index == nil || index == siblings.startIndex)
        Button {
            move(url, in: siblings, by: +1)
        } label: {
            Label("Move Down", systemImage: "arrow.down")
        }
        .disabled(index == nil || index == siblings.count - 1)
        Divider()
        Button(role: .destructive) {
            confirmDelete(url, isChapter: isChapter)
        } label: {
            Label("Delete…", systemImage: "trash")
        }
    }

    private func newArticleButton(in folder: URL) -> some View {
        Button {
            newArticleName = ""
            newArticleFolder = folder
            showNewArticle = true
        } label: {
            Label("New Article…", systemImage: "plus")
        }
    }

    // MARK: Listing

    /// (Re)read the book from disk. Synchronous on the main actor on
    /// purpose: a book is a hand-arranged folder of chapters, two shallow
    /// directory reads at most — not worth an async pipeline.
    private func refresh() {
        // Hold the security scope across the whole enumeration.
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        var folders: [URL] = []
        var files: [URL] = []
        for entry in entries {
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                folders.append(entry)
            } else if isArticle(entry) {
                files.append(entry)
            }
        }

        topArticles = sortedArticles(files)
        // Chapters are one level deep by design: a book is folders of
        // articles, not an arbitrary tree — nesting stops here.
        chapters = folders
            .sorted { BookOrdering.areInIncreasingOrder($0.lastPathComponent,
                                                        $1.lastPathComponent) }
            .map { folder in
                let articles = ((try? fm.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])) ?? [])
                    .filter { isArticle($0) }
                return Chapter(url: folder, articles: sortedArticles(articles))
            }
    }

    private func isArticle(_ url: URL) -> Bool {
        Self.articleExtensions.contains(url.pathExtension.lowercased())
    }

    /// Articles sort by their *displayed* name — extension stripped — so
    /// "2. setup.md" and "2. setup.txt" order by "2. setup" alike.
    private func sortedArticles(_ urls: [URL]) -> [URL] {
        urls.sorted {
            BookOrdering.areInIncreasingOrder($0.deletingPathExtension().lastPathComponent,
                                              $1.deletingPathExtension().lastPathComponent)
        }
    }

    // MARK: Actions

    /// Open an article in the editor, via the shared scene-activation
    /// request (see `DocumentSceneOpener` for why that's the mechanism).
    private func open(_ url: URL) {
        // Keep the book's security scope alive while the receiving scene
        // performs its coordinated open — that happens asynchronously, so
        // release on a grace delay rather than immediately. (The balancing
        // stop is guaranteed: the Task runs however the request fares.)
        let scoped = root.startAccessingSecurityScopedResource()
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if scoped { root.stopAccessingSecurityScopedResource() }
        }

        DocumentSceneOpener.open(url)
        dismiss()
    }

    private func createChapter() {
        guard let name = validName(newChapterName) else { return }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: false)
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    private func createArticle() {
        guard let folder = newArticleFolder, let name = validName(newArticleName) else { return }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let url = folder.appendingPathComponent(name).appendingPathExtension("md")
        guard !FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "“\(url.lastPathComponent)” already exists."
            return
        }
        do {
            // A starter heading so the article opens as a page, not a void.
            try Data("# \(name)\n".utf8).write(to: url, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    // MARK: Manage (rename / reorder / delete)

    /// Prompt for a new name, pre-filled with the *display* name — the
    /// numeric prefix and extension are the app's bookkeeping, not the
    /// user's to retype; `performRename` puts them back.
    private func startRename(_ url: URL) {
        renameTarget = url
        renameName = BookNaming.displayName(url.lastPathComponent)
        showRename = true
    }

    private func performRename() {
        guard let target = renameTarget, let name = validName(renameName) else { return }
        let newName = BookNaming.renamed(target.lastPathComponent, toDisplay: name)
        guard newName != target.lastPathComponent else { return }   // no-op rename

        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let destination = target.deletingLastPathComponent().appendingPathComponent(newName)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            errorMessage = "“\(newName)” already exists."
            return
        }
        do {
            try FileManager.default.moveItem(at: target, to: destination)
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    private func confirmDelete(_ url: URL, isChapter: Bool) {
        deleteTarget = url
        deleteIsChapter = isChapter
        showDeleteConfirm = true
    }

    private func performDelete() {
        guard let target = deleteTarget else { return }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        do {
            // One call either way: removeItem deletes a chapter folder
            // recursively, articles and all.
            try FileManager.default.removeItem(at: target)
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    /// Move an item one place up or down within its sibling group, then
    /// materialize the new order on disk by renumbering the whole group
    /// (see `BookNaming.renamePlan`). Out-of-range moves (first item up,
    /// last item down) are no-ops — the menu disables them too.
    private func move(_ url: URL, in siblings: [URL], by offset: Int) {
        guard let index = siblings.firstIndex(of: url),
              siblings.indices.contains(index + offset) else { return }
        let plan = BookNaming.renamePlan(siblings: siblings.map(\.lastPathComponent),
                                         moveFrom: index, to: index + offset)
        apply(plan, in: url.deletingLastPathComponent())
    }

    /// Apply a reorder plan with `FileManager` moves. Two phases — every
    /// source first moves to a unique dot-hidden temporary, then to its
    /// final name — so exchange cycles never collide mid-flight (swapping
    /// "01-Draft" and "02-Draft" renames one *onto* the other's old name).
    private func apply(_ plan: [(from: String, to: String)], in folder: URL) {
        guard !plan.isEmpty else { return }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        var staged: [(from: URL, temp: URL, to: URL)] = []
        do {
            for step in plan {
                let temp = folder.appendingPathComponent(".md-reorder-\(UUID().uuidString)")
                try fm.moveItem(at: folder.appendingPathComponent(step.from), to: temp)
                staged.append((from: folder.appendingPathComponent(step.from),
                               temp: temp,
                               to: folder.appendingPathComponent(step.to)))
            }
            for entry in staged {
                try fm.moveItem(at: entry.temp, to: entry.to)
            }
        } catch {
            // Best effort: park nothing at a temporary name — a hidden temp
            // would simply vanish from the navigator. (Items already at
            // their final names stay there; the plan just ends half-done.)
            for entry in staged { try? fm.moveItem(at: entry.temp, to: entry.from) }
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    // MARK: Compile to PDF / EPUB

    /// The book's reading title — the folder name without any numeric
    /// ordering prefix; also the suggested "<name>.pdf" / "<name>.epub"
    /// output name.
    private var bookTitle: String {
        BookNaming.displayName(root.lastPathComponent)
    }

    /// Read the whole book (inside its security scope, in the navigator's
    /// displayed order — what you see is what compiles) and assemble it
    /// into one Markdown source. `nil` when a read fails; the failure is
    /// already surfaced in the error alert.
    private func compiledBook() -> String? {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        do {
            var parts = [BookLibrary.Part(articles: try topArticles.map(read))]
            for chapter in chapters {
                parts.append(BookLibrary.Part(
                    title: BookNaming.displayName(chapter.url.lastPathComponent),
                    articles: try chapter.articles.map(read)))
            }
            return BookLibrary.compile(bookName: bookTitle, parts: parts)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// The compiled book through the same share pipeline as a document —
    /// the share sheet presents over this sheet, so no dismiss.
    private func shareBookPDF() {
        guard let source = compiledBook() else { return }
        Task {
            await DocumentExport.sharePDF(source: source, title: bookTitle,
                                          dark: colorScheme == .dark)
        }
    }

    /// The compiled book through the Files export picker.
    private func exportBookPDF() {
        guard let source = compiledBook() else { return }
        Task {
            await DocumentExport.exportPDF(source: source, title: bookTitle,
                                           dark: colorScheme == .dark)
        }
    }

    /// The book as an EPUB 3, through the Files export picker. All the
    /// file reading happens here, inside the book's security scope and in
    /// the displayed order; the packaging (and its rich-block snapshots)
    /// runs in DocumentExport on the strings alone.
    private func exportBookEPUB() {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        do {
            let rootArticles = try topArticles.map {
                EpubArticle(title: BookNaming.displayName($0.lastPathComponent),
                            source: try read($0))
            }
            let bookChapters = try chapters.map { chapter in
                EpubChapter(title: BookNaming.displayName(chapter.url.lastPathComponent),
                            articles: try chapter.articles.map {
                                EpubArticle(title: BookNaming.displayName($0.lastPathComponent),
                                            source: try read($0))
                            })
            }
            let book = EpubBook(title: bookTitle,
                                rootArticles: rootArticles, chapters: bookChapters)
            Task { await DocumentExport.exportEPUB(book: book) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Trim and reject path-breaking names — the same rule the in-app
    /// rename applies (`/` and `:` can't appear in a file name).
    private func validName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":") else { return nil }
        return trimmed
    }
}
