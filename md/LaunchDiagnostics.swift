//
//  LaunchDiagnostics.swift
//  md
//
//  A DEBUG-only harness for driving the app from `simctl launch` arguments
//  and for dumping what the UI really looks like from the inside.
//
//  Why it exists: this app has no UI-test target on Apple, and the two bugs
//  1.5 was tested with by hand — a Find row that searched the wrong document
//  and a toolbar whose every menu appeared twice — could not be *observed*
//  without tapping. Taps are not reproducible; launch arguments are. So the
//  moves a tester makes are reachable from the command line:
//
//      xcrun simctl launch <device> me.nettrash.md \
//          -mdOpenExample Welcome,Formatting,Writer  # open, then open again
//          -mdSelectMode edit                        # pick a layout
//          -mdTapFind                                # fire the toolbar's Find row
//          -mdPresentFind                            # call presentFind() directly
//          -mdDumpUI                                 # log the tree and the bar
//          -mdScript <file>                          # run a step script (below)
//
//  Each one goes through the *production* path — the Examples menu's own
//  copy-and-open, the mode control's own `select`, the Find row's own bar
//  button action — so what the harness exercises is what a finger exercises.
//
//  `-mdDumpUI` writes the view-controller tree, the number of document views
//  still alive, and every `UINavigationBar`'s items to os_log (subsystem
//  `me.nettrash.md`, category `diag`). That dump is what told the duplicated
//  toolbar apart from a toolbar the system had merely overflowed: it counted
//  6 trailing item groups after the first open, 12 after the second and 18
//  after the third, with a `DocumentHostingController` still parented for
//  each. Reading it:
//
//      xcrun simctl spawn <device> log stream --style compact \
//          --predicate 'subsystem == "me.nettrash.md"'
//
//  THE STEP SCRIPT (`-mdScript <path>`, absolute or relative to Documents)
//  ----------------------------------------------------------------------
//  One step per line, `#` comments, run in order on the main actor once the
//  launch screen has primed the document browser. Every step is the
//  production path again — `type` feeds `insertText` on the very
//  `SmartTextView` that is on screen, `undo` is the toolbar's Undo, `key`
//  fires the `UIKeyCommand` the responder chain really installed, `export`
//  calls the `DocumentExport` entry point the Share menu row calls, `book
//  rename` runs the navigator's own `performRename()`. After each step the
//  harness logs `step N done` and writes N to `<tmp>/harness/progress`, so a
//  driver outside the simulator can wait on it; `waitfor <name>` blocks
//  until `<tmp>/harness/<name>` exists (the driver touches it after taking
//  a screenshot, say) and removes it again.
//
//      wait <ms>                    waitfor <name>
//      open example <name>          open file <path>        open article <rel>
//      mode edit|split|preview      focus                   rotate landscape|portrait
//      type <text>   (\n Return, \b Backspace, \t, \s space, \\)
//      typeword <text>   (one insertText call — the predictive bar's shape)
//      backspace [n]   selectall   select <loc> <len>   caret <loc>
//      undo   redo   set continueLists|capitalizeSentences on|off
//      find   presentfind   findtext <q>   replaceall <q> -> <r>   blur
//      replaceone <q> -> <r>   dismissfind
//      dump [label]  dumptext  dumpkeys  dumpmode  dumppresented  dumpscroll
//      dumpfind  dumppreview  checktypes  activate <label>  activateindex <n>  dumplabels
//      key <chord>   (cmd+1, cmd+shift+b, ctrl+cmd+up, shift+return)
//      export pdf|html|epub|latex|textbundle|svg[ n]   print   sharesource
//      renameprompt   rename <name>   dismiss
//      contents <i>   note <i>   scrollsync <fraction>   scrollpreview <fraction>
//      book install | root <rel> | show | list | open <i> | rename <i> <name>
//           | move <i> <±1> | step <±1> | close
//
//  The whole file is `#if DEBUG`: nothing here is compiled into a Release
//  build, and the call sites in `DocumentView`, `BookNavigator` and
//  `BookLaunchBackdrop` are guarded the same way. Public UIKit only.
//

#if DEBUG

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit
import os

@MainActor
enum LaunchDiagnostics {

    static let log = Logger(subsystem: "me.nettrash.md", category: "diag")

    // MARK: - Arguments

    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static func isSet(_ flag: String) -> Bool { arguments.contains(flag) }

    /// The word after `flag`, when there is one (`-mdOpenExample Welcome`).
    static func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        let next = arguments[i + 1]
        return next.hasPrefix("-") ? nil : next
    }

    /// True when any harness argument was given — nothing below runs, and
    /// nothing is logged, for an ordinary launch.
    static var isActive: Bool {
        isSet("-mdOpenExample") || isSet("-mdPresentFind") || isSet("-mdDumpUI")
            || isSet("-mdSelectMode") || isSet("-mdTapFind") || isSet("-mdScript")
    }

    /// `-mdSelectMode edit|split|preview` — picks a layout the way the
    /// toolbar's mode control does, so the harness can reach Edit mode
    /// (where Find lives) on a phone, which opens documents in Preview.
    static var requestedMode: DocumentView.Mode? {
        value(after: "-mdSelectMode").flatMap { DocumentView.Mode(rawValue: $0) }
    }

    // MARK: - Hooks

    /// What a `DocumentView` hands the harness as it appears: the actions
    /// its toolbar rows and chords run, and the state a dump reads. Every
    /// closure is the view's own method — nothing is re-implemented here.
    struct DocumentHooks {
        let editor: EditorController
        let fileURL: URL?
        let baseName: String
        let dark: Bool
        let pageSize: PageSize
        let select: (DocumentView.Mode) -> Void
        let effectiveMode: () -> DocumentView.Mode
        let rawMode: () -> DocumentView.Mode
        let isWide: () -> Bool
        let text: () -> String
        let outline: () -> [OutlineEntry]
        let notes: () -> [NoteEntry]
        let jumpContents: (Int) -> Void
        let jumpNote: (Int) -> Void
        let showBook: () -> Void
        let stepArticle: (Int) -> Void
        let rename: (String) async -> String?
        let scrollSync: ScrollSync
        let diagrams: () -> [DiagramSVG.Diagram]
    }

    /// What the book navigator sheet hands the harness: its listing and the
    /// actions its rows and context menu run.
    struct NavigatorHooks {
        let root: URL
        let order: () -> [URL]
        let open: (URL) -> Void
        let rename: (URL, String) -> Void
        let move: (URL, [URL], Int) -> Void
    }

    private static var currentHooks: DocumentHooks?
    /// Bumped on every `documentAppeared`, so a step that opens a document
    /// can wait for the next one.
    private static var documentsSeen = 0
    private static var navigator: NavigatorHooks?
    /// The book the `book` steps act on (`book install` / `book root`).
    private static var bookRoot: URL?

    // MARK: - Live document views

    private final class WeakEditor {
        weak var editor: EditorController?
        init(_ editor: EditorController) { self.editor = editor }
    }

    /// Every `EditorController` a `DocumentView` has registered, weakly and
    /// in appearance order — so the count is the number of document views
    /// still alive. One per open document is correct; more means the view
    /// that was on screen before never went away, which is the shape of a
    /// toolbar whose every menu appears twice.
    private static var editors: [WeakEditor] = []

    private static func register(editor: EditorController) {
        editors.removeAll { $0.editor == nil }
        if !editors.contains(where: { $0.editor === editor }) {
            editors.append(WeakEditor(editor))
        }
        log.notice("document view appeared — live document views: \(editors.count, privacy: .public)")
    }

    private static var liveEditors: [EditorController] { editors.compactMap(\.editor) }

    // MARK: - Commands

    /// The examples still to open, in order: `-mdOpenExample A,B` opens A
    /// from the launch screen (a file picked in the browser) and B from
    /// inside A's editor (the Examples menu's own flow, which is the one
    /// that doubled the toolbar).
    private static var pendingExamples: [String] = {
        (value(after: "-mdOpenExample") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }()

    /// Run from the launch screen, once the document browser has been cached
    /// (`DocumentSceneOpener.primeBrowserCache()`): the Examples menu's open
    /// cannot work before that, and neither can this.
    /// Set once the launch screen has started the harness: the backdrop's
    /// `.task` runs again whenever the launch scene's view is rebuilt (a
    /// rotation does it), and a script must not start twice in one process.
    private static var started = false

    static func launchScreenPrimed() {
        guard isActive, !started else { return }
        started = true
        log.notice("launch screen primed; arguments: \(arguments.joined(separator: " "), privacy: .public)")
        // A beat: the launch screen is still being installed when the browser
        // first answers, and an open that lands mid-transition is dropped —
        // no editor is parented at all.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            openNextExample()
            if let script = value(after: "-mdScript") {
                await runScript(at: script)
            }
        }
        scheduleDumps(from: "launch")
    }

    /// Run from `DocumentView` when it comes on screen: registers it, picks
    /// the requested layout, opens the next queued example, and fires Find.
    static func documentAppeared(hooks: DocumentHooks) {
        guard isActive else { return }
        register(editor: hooks.editor)
        currentHooks = hooks
        documentsSeen += 1
        log.notice("harness: document \(documentsSeen, privacy: .public) appeared: \(hooks.fileURL?.lastPathComponent ?? "untitled", privacy: .public)")
        scheduleDumps(from: "document")
        let editor = hooks.editor

        if let mode = requestedMode {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                log.notice("harness: selecting mode \(mode.rawValue, privacy: .public)")
                hooks.select(mode)
            }
        }

        // Another example to open: this is the step that used to leave the
        // previous document view — and its toolbar — behind.
        if !pendingExamples.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                dump("before the next example")
                openNextExample()
            }
            return
        }

        if isSet("-mdTapFind") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                tapFind()
                try? await Task.sleep(for: .seconds(1))
                dump("after the Find row")
            }
        }
        if isSet("-mdPresentFind") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                log.notice("harness: calling presentFind() directly, \(liveEditors.count, privacy: .public) document views alive")
                editor.presentFind()
                try? await Task.sleep(for: .seconds(2))
                dump("after presentFind")
            }
        }
    }

    /// Run from `DocumentView` whenever its file URL changes (a rename, or
    /// an untitled document getting a file): keeps the hooks' URL live.
    static func fileURLChanged(to url: URL?, editor: EditorController) {
        guard isActive, let hooks = currentHooks, hooks.editor === editor else { return }
        log.notice("harness: fileURL of the current document is now \(url?.lastPathComponent ?? "nil", privacy: .public)")
        currentHooks = DocumentHooks(
            editor: hooks.editor, fileURL: url,
            baseName: url?.deletingPathExtension().lastPathComponent ?? hooks.baseName,
            dark: hooks.dark, pageSize: hooks.pageSize, select: hooks.select,
            effectiveMode: hooks.effectiveMode, rawMode: hooks.rawMode, isWide: hooks.isWide,
            text: hooks.text, outline: hooks.outline, notes: hooks.notes,
            jumpContents: hooks.jumpContents, jumpNote: hooks.jumpNote, showBook: hooks.showBook,
            stepArticle: hooks.stepArticle, rename: hooks.rename, scrollSync: hooks.scrollSync,
            diagrams: hooks.diagrams)
    }

    /// Run from `BookNavigator` when the sheet comes up.
    static func navigatorAppeared(_ hooks: NavigatorHooks) {
        guard isActive else { return }
        navigator = hooks
        log.notice("harness: book navigator appeared for \(hooks.root.lastPathComponent, privacy: .public) — \(hooks.order().count, privacy: .public) articles")
    }

    private static func openNextExample() {
        guard !pendingExamples.isEmpty else { return }
        openExample(named: pendingExamples.removeFirst())
    }

    /// Open a bundled example through the Examples menu's own path: copy it
    /// into Documents, hand the copy to the document-browser delegate.
    /// `name` matches loosely (`Welcome` finds `01-Welcome.md`).
    private static func openExample(named name: String) {
        let wanted = name.lowercased()
        guard let source = DocumentView.exampleURLs.first(where: {
            $0.lastPathComponent.lowercased().contains(wanted)
        }) else {
            log.error("harness: no bundled example matching \(name, privacy: .public)")
            return
        }
        do {
            let copy = try DocumentView.copyExample(source)
            log.notice("harness: opening example \(copy.lastPathComponent, privacy: .public)")
            DocumentSceneOpener.open(copy)
        } catch {
            log.error("harness: example copy failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fire the navigation bar's own Find row — the bar button item's
    /// target-action, which is what a finger on it sends. (Pressing the
    /// laid-out `UIButton` is *not*: UIKit routes a bar button's action
    /// through the item, and `performPrimaryAction()` on the button never
    /// reaches SwiftUI's closure at all — measured.)
    ///
    /// Going through the row rather than calling
    /// `EditorController.presentFind()` is the whole point: the row is the
    /// thing that was broken. It belonged to whichever document view got
    /// into the bar first, which after an open into the same scene was not
    /// the document on screen.
    static func tapFind() {
        let items = navigationItems().flatMap { $0.trailingItemGroups.flatMap(\.barButtonItems) }
        guard let find = items.first(where: { ($0.title ?? "").hasPrefix("Find") }) else {
            log.error("harness: no Find row in the navigation bar (is the document in Preview?)")
            return
        }
        guard let target = find.target, let action = find.action else {
            log.error("harness: the Find row carries no action")
            return
        }
        log.notice("harness: firing the toolbar's Find row")
        _ = target.perform(action, with: find)
    }

    // MARK: - The step script

    private static var documentsDirectory: URL {
        (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
    }

    /// Where the driver and the harness meet: `progress` (the last finished
    /// step), `finished`, and the gate files `waitfor` waits on.
    private static var harnessDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("harness", isDirectory: true)
    }

    private static func resolve(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path)
            : documentsDirectory.appendingPathComponent(path)
    }

    static func runScript(at path: String) async {
        let url = resolve(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            log.error("harness: cannot read script \(url.path, privacy: .public)")
            return
        }
        try? FileManager.default.createDirectory(at: harnessDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: harnessDirectory.appendingPathComponent("finished"))
        log.notice("harness: script \(url.lastPathComponent, privacy: .public) — gate directory \(harnessDirectory.path, privacy: .public)")
        var n = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            n += 1
            log.notice("harness: step \(n, privacy: .public): \(line, privacy: .public)")
            await perform(line)
            log.notice("harness: step \(n, privacy: .public) done")
            try? "\(n)\n".write(to: harnessDirectory.appendingPathComponent("progress"),
                                atomically: true, encoding: .utf8)
        }
        log.notice("harness: script finished after \(n, privacy: .public) steps")
        try? "done\n".write(to: harnessDirectory.appendingPathComponent("finished"),
                            atomically: true, encoding: .utf8)
    }

    private static func perform(_ line: String) async {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts[0].lowercased()
        let argument = parts.count > 1 ? parts[1] : ""
        let words = argument.split(separator: " ").map(String.init)

        switch command {
        case "wait":
            try? await Task.sleep(for: .milliseconds(Int(argument) ?? 500))
        case "waitfor":
            await waitForGate(argument)
        case "open":
            await open(words)
        case "mode":
            if let mode = DocumentView.Mode(rawValue: argument) {
                currentHooks?.select(mode)
            } else {
                log.error("harness: unknown mode \(argument, privacy: .public)")
            }
        case "focus":
            let became = textView?.becomeFirstResponder() ?? false
            log.notice("harness: focus → first responder: \(became, privacy: .public)")
        case "type":
            typeText(unescape(argument))
        case "typeword":
            textView?.insertText(unescape(argument))
        case "backspace":
            for _ in 0 ..< max(1, Int(argument) ?? 1) { textView?.deleteBackward() }
        case "selectall":
            if let tv = textView { tv.selectedRange = NSRange(location: 0, length: (tv.text as NSString).length) }
        case "select":
            if let tv = textView, words.count == 2, let loc = Int(words[0]), let len = Int(words[1]) {
                tv.selectedRange = NSRange(location: loc, length: len)
            }
        case "caret":
            if let tv = textView, let loc = Int(argument) {
                tv.selectedRange = NSRange(location: loc, length: 0)
            }
        case "undo":
            currentHooks?.editor.undo()
        case "redo":
            currentHooks?.editor.redo()
        case "set":
            if words.count == 2 {
                UserDefaults.standard.set(words[1] == "on", forKey: "md.\(words[0])")
                log.notice("harness: md.\(words[0], privacy: .public) = \(words[1] == "on", privacy: .public)")
            }
        case "find":
            tapFind()
        case "presentfind":
            currentHooks?.editor.presentFind()
        case "findtext":
            await findText(argument)
        case "replaceall":
            await replace(argument, all: true)
        case "replaceone":
            await replace(argument, all: false)
        case "dismissfind":
            textView?.findInteraction?.dismissFindNavigator()
        case "blur":
            // Put the keyboard away without changing a pane: a Contents jump
            // in Split moves the editor too, and focuses it (App Store shots).
            for window in windows { window.endEditing(true) }
        case "dump":
            dump(argument.isEmpty ? "script" : argument)
        case "dumptext":
            dumpText()
        case "dumpkeys":
            dumpKeyCommands()
        case "dumpmode":
            dumpMode()
        case "dumppresented":
            dumpPresented()
        case "dumpscroll":
            dumpScroll()
        case "dumpfind":
            dumpFind()
        case "dumppreview":
            await dumpPreview()
        case "checktypes":
            checkTypes()
        case "key":
            fireChord(argument)
        case "export":
            await export(words)
        case "print":
            guard let hooks = currentHooks else { return }
            // Not awaited: the print job's continuation only resumes when
            // the panel is dismissed, which is a later `dismiss` step.
            Task { await DocumentExport.print(source: hooks.text(), title: hooks.baseName, dark: hooks.dark) }
        case "sharesource":
            guard let hooks = currentHooks else { return }
            DocumentExport.shareSource(fileURL: hooks.fileURL, text: hooks.text(), title: hooks.baseName)
        case "renameprompt":
            guard let hooks = currentHooks, let fileURL = hooks.fileURL else { return }
            DocumentExport.promptRename(fileURL: fileURL, currentBaseName: hooks.baseName,
                                        perform: hooks.rename)
        case "rename":
            // The alert's Rename button's own work, minus the tap.
            guard let hooks = currentHooks, hooks.fileURL != nil else { return }
            let failure = await hooks.rename(argument)
            log.notice("harness: rename → \(failure ?? "ok", privacy: .public)")
        case "dismiss":
            dismissTop()
        case "contents":
            if let hooks = currentHooks, let i = Int(argument) {
                log.notice("harness: contents jump \(i, privacy: .public) of \(hooks.outline().count, privacy: .public)")
                hooks.jumpContents(i)
            }
        case "note":
            if let hooks = currentHooks, let i = Int(argument) {
                log.notice("harness: note jump \(i, privacy: .public) of \(hooks.notes().count, privacy: .public)")
                hooks.jumpNote(i)
            }
        case "scrollsync":
            if let f = Double(argument) { currentHooks?.scrollSync.editorDidScroll(to: CGFloat(f)) }
            dumpScroll()
        case "scrollpreview":
            if let f = Double(argument) { currentHooks?.scrollSync.previewDidScroll(to: CGFloat(f)) }
            dumpScroll()
        case "rotate":
            rotate(argument)
        case "activate":
            activate(argument)
        case "activateindex":
            activateBarControl(at: Int(argument) ?? 0)
        case "dumplabels":
            dumpLabels()
        case "book":
            await book(words)
        default:
            log.error("harness: unknown step \(line, privacy: .public)")
        }
    }

    // MARK: Waiting

    private static func waitForGate(_ name: String) async {
        let gate = harnessDirectory.appendingPathComponent(name)
        log.notice("harness: waiting for \(gate.path, privacy: .public)")
        for _ in 0 ..< 3000 {
            if FileManager.default.fileExists(atPath: gate.path) {
                try? FileManager.default.removeItem(at: gate)
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        log.error("harness: gate \(name, privacy: .public) never opened")
    }

    /// Wait for the document view an open should produce.
    private static func waitForNewDocument(since before: Int, timeout: Int = 15000) async -> Bool {
        for _ in 0 ..< (timeout / 100) {
            if documentsSeen > before { try? await Task.sleep(for: .milliseconds(800)); return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        log.error("harness: no document appeared within \(timeout, privacy: .public) ms")
        return false
    }

    // MARK: Opening

    private static func open(_ words: [String]) async {
        guard words.count >= 2 else { log.error("harness: open needs a kind and a name"); return }
        let before = documentsSeen
        let name = words.dropFirst().joined(separator: " ")
        switch words[0] {
        case "example":
            openExample(named: name)
        case "file":
            let url = resolve(name)
            log.notice("harness: opening file \(url.path, privacy: .public) exists=\(FileManager.default.fileExists(atPath: url.path), privacy: .public)")
            DocumentSceneOpener.open(url)
        case "article":
            // Exactly what an article row in the navigator does.
            guard let root = bookRoot else { log.error("harness: no book root"); return }
            let url = root.appendingPathComponent(name)
            BookScope.hold(root)
            BookArticleOpens.mark(url)
            DocumentSceneOpener.open(url)
        default:
            log.error("harness: open \(words[0], privacy: .public)?")
            return
        }
        _ = await waitForNewDocument(since: before)
    }

    // MARK: Typing

    private static func unescape(_ text: String) -> String {
        var out = ""
        var escaped = false
        for ch in text {
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "b": out.append("\u{08}")
                case "t": out.append("\t")
                case "s": out.append(" ")
                default: out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// One keystroke per character, through the on-screen editor's own
    /// `insertText` / `deleteBackward` — the hardware keyboard's path.
    private static func typeText(_ text: String) {
        guard let tv = textView else { log.error("harness: no editor pane to type into"); return }
        for ch in text {
            if ch == "\u{08}" { tv.deleteBackward() } else { tv.insertText(String(ch)) }
        }
    }

    // MARK: Finding

    /// The panel's own rule — plain text, case-insensitive.
    private final class CaseInsensitiveSearch: UITextSearchOptions {
        override var stringCompareOptions: NSString.CompareOptions { [.caseInsensitive] }
    }

    private static func searchOptions() -> UITextSearchOptions { CaseInsensitiveSearch() }

    private static func findText(_ query: String) async {
        guard let tv = textView, let interaction = tv.findInteraction else {
            log.error("harness: no find interaction"); return
        }
        if !interaction.isFindNavigatorVisible { interaction.presentFindNavigator(showingReplace: true) }
        try? await Task.sleep(for: .milliseconds(400))
        interaction.searchText = query
        guard let session = interaction.activeFindSession else {
            log.error("harness: no active find session"); return
        }
        session.performSearch(query: query, options: searchOptions())
        try? await Task.sleep(for: .milliseconds(400))
        dumpFind()
    }

    private static func replace(_ argument: String, all: Bool) async {
        let halves = argument.components(separatedBy: " -> ")
        guard halves.count == 2, let tv = textView, let interaction = tv.findInteraction else {
            log.error("harness: replace needs `<query> -> <replacement>` and an editor"); return
        }
        if !interaction.isFindNavigatorVisible { interaction.presentFindNavigator(showingReplace: true) }
        try? await Task.sleep(for: .milliseconds(400))
        interaction.searchText = halves[0]
        guard let session = interaction.activeFindSession else {
            log.error("harness: no active find session"); return
        }
        session.performSearch(query: halves[0], options: searchOptions())
        try? await Task.sleep(for: .milliseconds(400))
        let before = session.resultCount
        if all {
            session.replaceAll(searchQuery: halves[0], replacementString: halves[1], options: searchOptions())
        } else {
            session.performSingleReplacement(query: halves[0], replacementString: halves[1], options: searchOptions())
        }
        try? await Task.sleep(for: .milliseconds(600))
        log.notice("harness: replace\(all ? "All" : "One") '\(halves[0], privacy: .public)' → '\(halves[1], privacy: .public)': \(before, privacy: .public) matches before, supportsReplacement=\(session.supportsReplacement, privacy: .public)")
        dumpText()
    }

    private static func dumpFind() {
        guard let tv = textView, let interaction = tv.findInteraction else {
            log.notice("find: no editor pane / interaction on screen"); return
        }
        let session = interaction.activeFindSession
        log.notice("find: panelVisible=\(interaction.isFindNavigatorVisible, privacy: .public) searchText=\(interaction.searchText ?? "nil", privacy: .public) session=\(session != nil, privacy: .public) results=\(session?.resultCount ?? -1, privacy: .public) highlighted=\(session?.highlightedResultIndex ?? -1, privacy: .public) replace=\(session?.supportsReplacement ?? false, privacy: .public) textLength=\((tv.text as NSString).length, privacy: .public)")
    }

    // MARK: Dumps

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\t", with: "⇥")
    }

    private static func dumpText() {
        let views = textViews
        guard let tv = views.last else { log.notice("text: no editor pane on screen"); return }
        let text = tv.text ?? ""
        let bound = currentHooks?.text() ?? ""
        let shown = escaped(String(text.prefix(600)))
        log.notice("text: panes=\(views.count, privacy: .public) length=\((text as NSString).length, privacy: .public) selection=\(tv.selectedRange.location, privacy: .public),\(tv.selectedRange.length, privacy: .public) firstResponder=\(tv.isFirstResponder, privacy: .public) bindingInSync=\(bound == text, privacy: .public) canUndo=\(currentHooks?.editor.canUndo ?? false, privacy: .public) canRedo=\(currentHooks?.editor.canRedo ?? false, privacy: .public) continueLists=\(tv.continueLists, privacy: .public) capitalize=\(tv.capitalizeSentences, privacy: .public)")
        log.notice("text: «\(shown, privacy: .public)»")
    }

    private static func dumpMode() {
        guard let hooks = currentHooks else { log.notice("mode: no document"); return }
        let identity = hooks.fileURL.map(ViewModeMemory.identity(for:))
        let remembered = identity.flatMap { ViewModeMemory.lookup($0) }
        log.notice("mode: file=\(hooks.fileURL?.lastPathComponent ?? "untitled", privacy: .public) effective=\(hooks.effectiveMode().rawValue, privacy: .public) raw=\(hooks.rawMode().rawValue, privacy: .public) wide=\(hooks.isWide(), privacy: .public) identity=\(identity ?? "nil", privacy: .public) remembered=\(remembered?.rawValue ?? "nil", privacy: .public) entries=\(ViewModeMemory.entries().count, privacy: .public)")
        log.notice("mode: memory «\(escaped(UserDefaults.standard.string(forKey: ViewModeMemory.defaultsKey) ?? ""), privacy: .public)»")
    }

    private static func dumpPresented() {
        for window in windows {
            var vc = window.rootViewController?.presentedViewController
            var depth = 0
            if vc == nil { log.notice("presented: nothing on \(type(of: window), privacy: .public)") }
            while let current = vc {
                depth += 1
                var line = "presented[\(depth)]: \(type(of: current)) style=\(current.modalPresentationStyle.rawValue) title=\(current.title ?? "nil")"
                if let nav = current as? UINavigationController, let top = nav.topViewController {
                    line += " top=\(type(of: top)) topTitle=\(top.title ?? top.navigationItem.title ?? "nil")"
                }
                if String(describing: type(of: current)).contains("Print") {
                    line += " printJob=\(UIPrintInteractionController.shared.printInfo?.jobName ?? "nil")"
                }
                if let alert = current as? UIAlertController {
                    line += " alertTitle=\(alert.title ?? "nil") message=\(alert.message ?? "nil") fields=\(alert.textFields?.map { $0.text ?? "" } ?? []) actions=\(alert.actions.map { $0.title ?? "?" })"
                }
                log.notice("\(line, privacy: .public)")
                vc = current.presentedViewController
            }
        }
    }

    private static func dumpScroll() {
        if let tv = textViews.last {
            log.notice("scroll: editor offset=\(Int(tv.contentOffset.y), privacy: .public) content=\(Int(tv.contentSize.height), privacy: .public) fraction=\(tv.syncFraction.map { String(format: "%.3f", $0) } ?? "nil", privacy: .public)")
        }
        if let web = webViews.last {
            let sv = web.scrollView
            log.notice("scroll: preview offset=\(Int(sv.contentOffset.y), privacy: .public) content=\(Int(sv.contentSize.height), privacy: .public) fraction=\(sv.syncFraction.map { String(format: "%.3f", $0) } ?? "nil", privacy: .public) frame=\(Int(web.frame.width), privacy: .public)x\(Int(web.frame.height), privacy: .public)")
        }
        if let tv = textViews.last, let web = webViews.last {
            let a = tv.convert(tv.bounds, to: nil), b = web.convert(web.bounds, to: nil)
            log.notice("scroll: layout editor=\(Int(a.minX), privacy: .public),\(Int(a.minY), privacy: .public) \(Int(a.width), privacy: .public)x\(Int(a.height), privacy: .public) preview=\(Int(b.minX), privacy: .public),\(Int(b.minY), privacy: .public) \(Int(b.width), privacy: .public)x\(Int(b.height), privacy: .public) sideBySide=\(b.minX >= a.maxX - 1, privacy: .public)")
        }
    }

    /// What the rendered page holds, asked of the page itself.
    private static func dumpPreview() async {
        let views = webViews
        guard let web = views.last else { log.notice("preview: no web view on screen"); return }
        let js = """
        JSON.stringify({complete: document.documentElement.getAttribute('data-md-render-complete'),
          title: document.title, svgs: document.querySelectorAll('svg').length,
          mermaid: document.querySelectorAll('.mermaid svg').length,
          graphviz: document.querySelectorAll('.graphviz svg').length,
          plantuml: document.querySelectorAll('.plantuml svg').length,
          plots: document.querySelectorAll('.plot svg, .md-plot svg').length,
          katex: document.querySelectorAll('.katex').length,
          hljs: document.querySelectorAll('.hljs, code[class*="language-"], span[class^="hljs-"]').length,
          textLength: document.body ? document.body.innerText.length : -1,
          bodyStart: document.body ? document.body.innerText.slice(0, 80) : '',
          bg: getComputedStyle(document.body).backgroundColor,
          scrollY: window.scrollY, height: document.documentElement.scrollHeight})
        """
        let result: String = await withCheckedContinuation { continuation in
            web.evaluateJavaScript(js) { value, error in
                if let error { continuation.resume(returning: "JS failed: \(error.localizedDescription)") }
                else { continuation.resume(returning: (value as? String) ?? "no value") }
            }
        }
        log.notice("preview: views=\(views.count, privacy: .public) url=\(web.url?.absoluteString ?? "nil", privacy: .public) \(escaped(result), privacy: .public)")
    }

    /// Every extension the app claims, resolved the way the system resolves
    /// a file name — inside the running app, where the registered bundle is
    /// this build.
    private static func checkTypes() {
        let extensions = ["md", "markdown", "mdown", "markdn", "mdtext", "mdtxt", "mkd", "mkdn",
                          "mdwn", "mkdown", "puml", "plantuml", "iuml", "pu", "gv", "textbundle",
                          "textpack", "txt", "text", "dot"]
        for ext in extensions {
            // `conformingTo: nil`, as the system resolves a file name: the
            // one-argument initializer implies `.data`, which a package
            // (.textbundle, a directory) does not conform to.
            let type = UTType(tag: ext, tagClass: .filenameExtension, conformingTo: nil)
            let all = UTType.types(tag: ext, tagClass: .filenameExtension, conformingTo: nil)
            let readable = type.map { t in MarkdownDocument.readableContentTypes.contains { t.conforms(to: $0) } } ?? false
            let writable = type.map { t in MarkdownDocument.writableContentTypes.contains { t.conforms(to: $0) } } ?? false
            log.notice("types: .\(ext, privacy: .public) → \(type?.identifier ?? "nil", privacy: .public) declared=\(type?.isDeclared ?? false, privacy: .public) dynamic=\(type?.isDynamic ?? false, privacy: .public) readable=\(readable, privacy: .public) writable=\(writable, privacy: .public) all=\(all.map(\.identifier).joined(separator: ","), privacy: .public)")
        }
    }

    // MARK: Key commands

    private struct FoundCommand {
        let owner: UIResponder
        let command: UIKeyCommand
    }

    /// Every `UIKeyCommand` reachable on screen: the first responder's
    /// chain, then every view controller's and every view's. The chords
    /// SwiftUI installs for `.keyboardShortcut` surface here, which is how
    /// UIKit finds them for a hardware keyboard.
    private static func keyCommandsOnScreen() -> [FoundCommand] {
        var found: [FoundCommand] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ responder: UIResponder) {
            var r: UIResponder? = responder
            while let current = r {
                if seen.insert(ObjectIdentifier(current)).inserted, let commands = current.keyCommands {
                    for c in commands { found.append(FoundCommand(owner: current, command: c)) }
                }
                r = current.next
            }
        }
        func visitControllers(_ vc: UIViewController?) {
            guard let vc else { return }
            visit(vc)
            if vc.isViewLoaded { visit(vc.view) }
            for child in vc.children { visitControllers(child) }
            visitControllers(vc.presentedViewController)
        }
        func visitViews(_ view: UIView) {
            visit(view)
            for sub in view.subviews { visitViews(sub) }
        }
        for window in windows {
            if let first = firstResponder(in: window) { visit(first) }
            visitControllers(window.rootViewController)
            visitViews(window)
        }
        return found
    }

    private static func describe(_ command: UIKeyCommand) -> String {
        var mods: [String] = []
        if command.modifierFlags.contains(.control) { mods.append("ctrl") }
        if command.modifierFlags.contains(.alternate) { mods.append("alt") }
        if command.modifierFlags.contains(.shift) { mods.append("shift") }
        if command.modifierFlags.contains(.command) { mods.append("cmd") }
        let input: String
        switch command.input {
        case UIKeyCommand.inputUpArrow: input = "up"
        case UIKeyCommand.inputDownArrow: input = "down"
        case UIKeyCommand.inputLeftArrow: input = "left"
        case UIKeyCommand.inputRightArrow: input = "right"
        case "\r": input = "return"
        default: input = command.input ?? "?"
        }
        let action = command.action.map(NSStringFromSelector) ?? "nil"
        return "\((mods + [input]).joined(separator: "+")) title=\(command.title.isEmpty ? (command.discoverabilityTitle ?? "") : command.title) action=\(action) priority=\(command.wantsPriorityOverSystemBehavior)"
    }

    private static func dumpKeyCommands() {
        let all = keyCommandsOnScreen()
        log.notice("keys: \(all.count, privacy: .public) key commands on screen")
        for entry in all {
            log.notice("keys: \(describe(entry.command), privacy: .public) owner=\(type(of: entry.owner), privacy: .public)")
        }
    }

    /// Fire the chord the way UIKit would once a hardware keyboard sent it:
    /// find the installed `UIKeyCommand` with that input and those
    /// modifiers, and send its action.
    private static func fireChord(_ chord: String) {
        var flags: UIKeyModifierFlags = []
        var input = ""
        for part in chord.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": flags.insert(.command)
            case "ctrl", "control": flags.insert(.control)
            case "alt", "option": flags.insert(.alternate)
            case "shift": flags.insert(.shift)
            case "up": input = UIKeyCommand.inputUpArrow
            case "down": input = UIKeyCommand.inputDownArrow
            case "left": input = UIKeyCommand.inputLeftArrow
            case "right": input = UIKeyCommand.inputRightArrow
            case "return", "enter": input = "\r"
            default: input = part
            }
        }
        let matches = keyCommandsOnScreen().filter {
            ($0.command.input ?? "").lowercased() == input.lowercased()
                && $0.command.modifierFlags == flags
        }
        guard let match = matches.first, let action = match.command.action else {
            log.notice("key: \(chord, privacy: .public) — no key command installed for it")
            return
        }
        log.notice("key: \(chord, privacy: .public) → \(describe(match.command), privacy: .public) owner=\(type(of: match.owner), privacy: .public) (\(matches.count, privacy: .public) match(es))")
        // The responder that vends a key command is the one that handles
        // it: UIKit performs the command's action on it (SwiftUI's hosting
        // controller answers `_performShortcutKeyCommand:` for every chord
        // it installed, and says no to `canPerformAction` for it).
        // The owner vends the command, but SwiftUI's hosting controller
        // says no to `responds(to:)` for its action and reaches the handler
        // through message forwarding — so ask it where the message goes
        // (`forwardingTarget(for:)`, public NSObject API) and perform the
        // action there, never on an object that has no method for it.
        // Candidates: the owner, its view (a hosting controller's view is
        // the responder SwiftUI actually handles keys in, and it sits below
        // the controller in the chain UIKit walks up from the first
        // responder), and whatever either forwards the message to.
        var candidates: [NSObject] = [match.owner]
        if let controller = match.owner as? UIViewController, controller.isViewLoaded {
            candidates.append(controller.view)
        }
        for candidate in candidates {
            var target: NSObject? = candidate
            var hops = 0
            while let current = target, !current.responds(to: action), hops < 4 {
                target = current.forwardingTarget(for: action) as? NSObject
                hops += 1
            }
            let can = (candidate as? UIResponder)?.canPerformAction(action, withSender: match.command) ?? false
            log.notice("key: candidate \(type(of: candidate), privacy: .public) responds=\(candidate.responds(to: action), privacy: .public) canPerform=\(can, privacy: .public) forwards=\(target.map { String(describing: type(of: $0)) } ?? "nil", privacy: .public)")
            if let target, target.responds(to: action) {
                _ = target.perform(action, with: match.command)
                log.notice("key: performed on \(type(of: target), privacy: .public) (\(hops, privacy: .public) forwarding hop(s))")
                return
            }
            if can, let responder = candidate as? UIResponder {
                let ok = UIApplication.shared.sendAction(action, to: responder, from: match.command, for: nil)
                log.notice("key: sent to \(type(of: responder), privacy: .public) → \(ok, privacy: .public)")
                if ok { return }
            }
        }
        // UIKit's own dispatch: from the first responder up. A chord lands
        // only while something in the document's hierarchy has focus — the
        // editor pane, or in Preview the web view — which is also what a
        // hardware keyboard needs before it types into the app at all.
        if firstResponderInWindows() == nil {
            if let tv = textView, tv.becomeFirstResponder() {
                log.notice("key: focused the editor pane first")
            } else if let web = webViews.last, web.becomeFirstResponder() {
                log.notice("key: focused the preview first")
            }
        }
        let ok = UIApplication.shared.sendAction(action, to: nil, from: match.command, for: nil)
        log.notice("key: no responder answers \(NSStringFromSelector(action), privacy: .public) directly; sent through the responder chain from \(firstResponderInWindows().map { String(describing: type(of: $0)) } ?? "no first responder", privacy: .public) → \(ok, privacy: .public)")
    }

    // MARK: Exports

    private static func export(_ words: [String]) async {
        guard let hooks = currentHooks, let kind = words.first else { return }
        let source = hooks.text()
        let title = hooks.baseName
        let ext: String
        switch kind {
        case "pdf":
            await DocumentExport.exportPDF(source: source, title: title, dark: hooks.dark, pageSize: hooks.pageSize)
            ext = "pdf"
        case "html":
            await DocumentExport.exportHTML(source: source, title: title, dark: hooks.dark)
            ext = "html"
        case "epub":
            await DocumentExport.exportDocumentEPUB(source: source, fileName: title)
            ext = "epub"
        case "latex":
            DocumentExport.exportLaTeX(source: source, title: title)
            ext = "tex"
        case "textbundle":
            DocumentExport.exportTextBundle(source: source, fileURL: hooks.fileURL, title: title)
            ext = "textbundle"
        case "svg":
            let diagrams = hooks.diagrams()
            let index = words.count > 1 ? (Int(words[1]) ?? 0) : 0
            guard diagrams.indices.contains(index) else {
                log.error("harness: no diagram \(index, privacy: .public) (\(diagrams.count, privacy: .public) in the document)"); return
            }
            await DocumentExport.exportDiagramSVG(source: source, title: title, diagram: diagrams[index])
            ext = "svg"
        default:
            log.error("harness: export \(kind, privacy: .public)?"); return
        }
        try? await Task.sleep(for: .milliseconds(700))
        let top = topPresented()
        log.notice("export \(kind, privacy: .public): presented \(top.map { String(describing: type(of: $0)) } ?? "nothing", privacy: .public)")
        if let top, top is UIDocumentPickerViewController || top is UIAlertController {
            if let alert = top as? UIAlertController {
                log.error("export \(kind, privacy: .public): alert \(alert.title ?? "", privacy: .public) — \(alert.message ?? "", privacy: .public)")
            }
            top.presentingViewController?.dismiss(animated: false)
        }
        // The temp file the picker was offering, copied out for the driver.
        let tmp = FileManager.default.temporaryDirectory
        let items = ((try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == ext }
            .sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
            }
        guard let newest = items.first else {
            log.error("export \(kind, privacy: .public): no .\(ext, privacy: .public) in \(tmp.path, privacy: .public)"); return
        }
        let exports = documentsDirectory.appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let destination = exports.appendingPathComponent(newest.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: newest, to: destination)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? -1
            log.notice("export \(kind, privacy: .public): \(destination.path, privacy: .public) (\(size, privacy: .public) bytes)")
        } catch {
            log.error("export \(kind, privacy: .public): copy failed \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func dismissTop() {
        UIPrintInteractionController.shared.dismiss(animated: false)
        if let tv = textView, let interaction = tv.findInteraction, interaction.isFindNavigatorVisible {
            interaction.dismissFindNavigator()
        }
        guard let top = topPresented() else { log.notice("dismiss: nothing presented"); return }
        log.notice("dismiss: \(type(of: top), privacy: .public)")
        top.presentingViewController?.dismiss(animated: false)
    }

    // MARK: Books

    private static func book(_ words: [String]) async {
        guard let command = words.first else { return }
        let fm = FileManager.default
        switch command {
        case "install":
            // The Examples menu's "Example Book…" minus its folder picker:
            // the copy, the bookmark and the remembered-book key are the
            // ones `installExampleBook` writes.
            guard let source = Bundle.main.url(forResource: "Example Book", withExtension: nil,
                                               subdirectory: "Examples") else {
                log.error("harness: the example book is missing from the bundle"); return
            }
            var destination = documentsDirectory.appendingPathComponent("Example Book", isDirectory: true)
            var counter = 2
            while fm.fileExists(atPath: destination.path) {
                destination = documentsDirectory.appendingPathComponent("Example Book \(counter)", isDirectory: true)
                counter += 1
            }
            do { try fm.copyItem(at: source, to: destination) } catch {
                log.error("harness: book copy failed \(error.localizedDescription, privacy: .public)"); return
            }
            guard let encoded = BookStore.encodeBookmark(for: destination) else {
                log.error("harness: bookmark failed"); return
            }
            UserDefaults.standard.set(encoded, forKey: BookLaunchModel.bookmarkKey)
            bookRoot = destination
            log.notice("harness: book installed at \(destination.path, privacy: .public); bookmark stored")
        case "root":
            bookRoot = resolve(words.dropFirst().joined(separator: " "))
            if let root = bookRoot, let encoded = BookStore.encodeBookmark(for: root) {
                UserDefaults.standard.set(encoded, forKey: BookLaunchModel.bookmarkKey)
            }
        case "close":
            UserDefaults.standard.removeObject(forKey: BookLaunchModel.bookmarkKey)
            log.notice("harness: book bookmark removed")
        case "show":
            navigator = nil
            currentHooks?.showBook()
            for _ in 0 ..< 50 where navigator == nil { try? await Task.sleep(for: .milliseconds(100)) }
            log.notice("harness: navigator present=\(navigator != nil, privacy: .public)")
        case "list":
            let order = navigator?.order() ?? bookRoot.map { BookTree.readingOrder(BookTree.read(root: $0)) } ?? []
            for (i, url) in order.enumerated() {
                let rel = bookRoot.map { url.path.replacingOccurrences(of: $0.path + "/", with: "") } ?? url.path
                log.notice("book[\(i, privacy: .public)]: \(rel, privacy: .public)")
            }
            if let root = bookRoot {
                let disk = (try? fm.subpathsOfDirectory(atPath: root.path))?.sorted() ?? []
                log.notice("book on disk: \(disk.joined(separator: " | "), privacy: .public)")
            }
        case "open":
            guard let navigator, let i = Int(words.dropFirst().first ?? ""), navigator.order().indices.contains(i) else {
                log.error("harness: book open needs a presented navigator and an index"); return
            }
            let before = documentsSeen
            navigator.open(navigator.order()[i])
            _ = await waitForNewDocument(since: before)
        case "rename":
            guard let navigator, words.count >= 3, let i = Int(words[1]), navigator.order().indices.contains(i) else {
                log.error("harness: book rename needs a presented navigator, an index and a name"); return
            }
            navigator.rename(navigator.order()[i], words.dropFirst(2).joined(separator: " "))
            try? await Task.sleep(for: .milliseconds(300))
        case "move":
            guard let navigator, let root = bookRoot, words.count >= 3, let i = Int(words[1]),
                  let offset = Int(words[2]), navigator.order().indices.contains(i) else {
                log.error("harness: book move needs a presented navigator, an index and an offset"); return
            }
            let url = navigator.order()[i]
            let contents = BookTree.read(root: root)
            let siblings = contents.chapters.first { $0.articles.contains(url) }?.articles ?? contents.topArticles
            navigator.move(url, siblings, offset)
            try? await Task.sleep(for: .milliseconds(300))
        case "step":
            let before = documentsSeen
            currentHooks?.stepArticle(Int(words.dropFirst().first ?? "") ?? 1)
            let moved = await waitForNewDocument(since: before, timeout: 4000)
            log.notice("harness: book step → new document: \(moved, privacy: .public)")
        default:
            log.error("harness: book \(command, privacy: .public)?")
        }
    }

    // MARK: Menus

    /// Activate the on-screen control whose accessibility label is `label`
    /// — what VoiceOver's double-tap does, and for a bar button carrying a
    /// menu, what shows the menu.
    private static func activate(_ label: String) {
        var controls: [UIView] = []
        for window in windows { collect(UIView.self, in: window, into: &controls) }
        let wanted = label.lowercased()
        guard let control = controls.first(where: {
            $0 is UIControl && ($0.accessibilityLabel ?? "").lowercased() == wanted
        }) ?? controls.first(where: { ($0.accessibilityLabel ?? "").lowercased() == wanted }) else {
            let labels = Set(controls.compactMap(\.accessibilityLabel)).sorted()
            log.error("harness: nothing labelled \(label, privacy: .public) on screen; labels: \(labels.joined(separator: ", "), privacy: .public)")
            return
        }
        let ok = control.accessibilityActivate()
        log.notice("harness: activate \(label, privacy: .public) → \(type(of: control), privacy: .public) accepted=\(ok, privacy: .public)")
        // A bar button carrying a menu shows it on its primary action.
        if !ok, let button = control as? UIControl {
            button.sendActions(for: .menuActionTriggered)
            button.performPrimaryAction()
            log.notice("harness: activate \(label, privacy: .public) → sent menuActionTriggered + performPrimaryAction (isContextMenuInteractionEnabled=\(button.isContextMenuInteractionEnabled, privacy: .public))")
        }
    }

    /// The bar's `index`th control from the left among the trailing ones —
    /// a bar button on iPad carries no accessibility label to find it by,
    /// but its place in the bar is the place the dump lists it in.
    private static func activateBarControl(at index: Int) {
        var bars: [UINavigationBar] = []
        for window in windows { collectBars(window, into: &bars) }
        var controls: [UIControl] = []
        for bar in bars { collect(UIControl.self, in: bar, into: &controls) }
        // Top-level controls only: a bar button is a control holding
        // further controls, and only the outermost one carries the menu.
        func nestedInControl(_ view: UIView) -> Bool {
            var parent = view.superview
            while let current = parent {
                if current is UIControl { return true }
                parent = current.superview
            }
            return false
        }
        let trailing = controls
            .filter { !nestedInControl($0) && $0.bounds.width > 0 && $0.convert($0.bounds, to: nil).minX > 120 }
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        guard trailing.indices.contains(index) else {
            log.error("harness: no bar control \(index, privacy: .public) (\(trailing.count, privacy: .public) trailing controls)")
            return
        }
        let control = trailing[index]
        control.sendActions(for: .menuActionTriggered)
        control.performPrimaryAction()
        log.notice("harness: activated bar control \(index, privacy: .public) of \(trailing.count, privacy: .public): \(type(of: control), privacy: .public) menu=\(control.isContextMenuInteractionEnabled, privacy: .public)")
    }

    /// Every label in every window above the app's own — the rows of an
    /// open menu live in a window of their own.
    private static func dumpLabels() {
        for window in windows {
            var labels: [UILabel] = []
            collect(UILabel.self, in: window, into: &labels)
            let texts = labels.compactMap(\.text).filter { !$0.isEmpty }
            log.notice("labels: \(type(of: window), privacy: .public) level=\(window.windowLevel.rawValue, privacy: .public): \(texts.joined(separator: " | "), privacy: .public)")
        }
    }

    // MARK: Rotation

    private static func rotate(_ orientation: String) {
        let wanted: UIInterfaceOrientationMask = orientation == "landscape" ? .landscapeLeft : .portrait
        for scene in windowScenes {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: wanted)) { error in
                log.error("harness: rotate failed \(error.localizedDescription, privacy: .public)")
            }
            log.notice("harness: rotate \(orientation, privacy: .public) requested; scene orientation now \(scene.effectiveGeometry.interfaceOrientation.rawValue, privacy: .public) bounds=\(Int(scene.coordinateSpace.bounds.width), privacy: .public)x\(Int(scene.coordinateSpace.bounds.height), privacy: .public)")
        }
    }

    // MARK: View lookup

    private static var windowScenes: [UIWindowScene] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    }

    private static var windows: [UIWindow] {
        windowScenes.flatMap(\.windows).sorted { $0.isKeyWindow && !$1.isKeyWindow }
    }

    private static func collect<T: UIView>(_ type: T.Type, in view: UIView, into out: inout [T]) {
        if let v = view as? T { out.append(v) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }

    private static var textViews: [SmartTextView] {
        var out: [SmartTextView] = []
        for window in windows { collect(SmartTextView.self, in: window, into: &out) }
        return out
    }

    private static var textView: SmartTextView? { textViews.last }

    private static var webViews: [WKWebView] {
        var out: [WKWebView] = []
        for window in windows { collect(WKWebView.self, in: window, into: &out) }
        return out
    }

    private static func firstResponderInWindows() -> UIResponder? {
        for window in windows { if let r = firstResponder(in: window) { return r } }
        return nil
    }

    private static func firstResponder(in view: UIView) -> UIResponder? {
        if view.isFirstResponder { return view }
        for sub in view.subviews { if let r = firstResponder(in: sub) { return r } }
        return nil
    }

    private static func topPresented() -> UIViewController? {
        for window in windows {
            var top = window.rootViewController
            while let presented = top?.presentedViewController { top = presented }
            if top !== window.rootViewController { return top }
        }
        return nil
    }

    // MARK: - Dumping the UI

    private static var dumpsScheduled = false

    /// `-mdDumpUI` snapshots the UI a few times after launch, so a dump
    /// exists both before and after whatever the other arguments did.
    private static func scheduleDumps(from label: String) {
        guard isSet("-mdDumpUI"), !dumpsScheduled else { return }
        dumpsScheduled = true
        Task { @MainActor in
            for step in 1 ... 4 {
                try? await Task.sleep(for: .seconds(3))
                dump("\(label) +\(step * 3)s")
            }
        }
    }

    /// The decisive evidence: the whole view-controller tree, the live
    /// document-view count, and every navigation bar's items — the iOS 16+
    /// trailing item *groups* SwiftUI toolbars actually land in, plus
    /// whether the bar overflowed into the system's "…" menu.
    static func dump(_ label: String) {
        var lines: [String] = ["=== UI DUMP (\(label)) ==="]
        lines.append("live document views (EditorController): \(liveEditors.count)")
        lines.append("editor panes on screen: \(textViews.count), preview web views on screen: \(webViews.count)")
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            lines.append("scene \(scene.session.persistentIdentifier) windows=\(scene.windows.count) size=\(Int(scene.coordinateSpace.bounds.width))x\(Int(scene.coordinateSpace.bounds.height)) sizeClass=\(scene.traitCollection.horizontalSizeClass == .regular ? "regular" : "compact")")
            for window in scene.windows {
                lines.append("  window \(type(of: window)) level=\(window.windowLevel.rawValue)")
                if let root = window.rootViewController {
                    lines.append(contentsOf: describe(root, depth: 2))
                }
                lines.append(contentsOf: describeNavigationBars(in: window, depth: 2))
            }
        }
        lines.append("=== END UI DUMP (\(label)) ===")
        for line in lines { log.notice("\(line, privacy: .public)") }
    }

    private static func describe(_ vc: UIViewController, depth: Int) -> [String] {
        let pad = String(repeating: "  ", count: depth)
        var line = "\(pad)vc \(type(of: vc))"
        // The document-based controllers say which document they hold and
        // what their navigation item carries — the title bar is theirs.
        if let documentVC = vc as? UIDocumentViewController {
            line += " document=\(documentVC.document?.fileURL.lastPathComponent ?? "nil")"
        }
        if let title = vc.navigationItem.title { line += " navTitle=\(title)" }
        if vc.navigationItem.documentProperties != nil { line += " documentProperties=yes" }
        var lines = [line]
        for child in vc.children {
            lines.append(contentsOf: describe(child, depth: depth + 1))
        }
        if let presented = vc.presentedViewController {
            lines.append("\(pad)  presents:")
            lines.append(contentsOf: describe(presented, depth: depth + 2))
        }
        return lines
    }

    private static func navigationItems() -> [UINavigationItem] {
        var items: [UINavigationItem] = []
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                var bars: [UINavigationBar] = []
                collectBars(window, into: &bars)
                items.append(contentsOf: bars.flatMap { $0.items ?? [] })
            }
        }
        return items
    }

    /// Every `UINavigationBar` in a window, with what is actually in it.
    private static func describeNavigationBars(in window: UIWindow, depth: Int) -> [String] {
        var bars: [UINavigationBar] = []
        collectBars(window, into: &bars)
        let pad = String(repeating: "  ", count: depth)
        var lines = ["\(pad)navigation bars: \(bars.count)"]
        for (index, bar) in bars.enumerated() {
            lines.append("\(pad)  bar[\(index)] items=\(bar.items?.count ?? 0)")
            for (itemIndex, item) in (bar.items ?? []).enumerated() {
                lines.append("\(pad)    item[\(itemIndex)] title=\(item.title ?? "nil") trailingGroups=\(item.trailingItemGroups.count) leadingGroups=\(item.leadingItemGroups.count) centerGroups=\(item.centerItemGroups.count)")
                for (g, group) in item.trailingItemGroups.enumerated() {
                    let labels = group.barButtonItems.map { describe($0) }
                    lines.append("\(pad)      trailingGroup[\(g)]: \(labels.joined(separator: " | "))")
                }
                for (g, group) in item.leadingItemGroups.enumerated() {
                    let labels = group.barButtonItems.map { describe($0) }
                    lines.append("\(pad)      leadingGroup[\(g)]: \(labels.joined(separator: " | "))")
                }
                // Non-nil once the bar has more than it can show: everything
                // past the first couple of items is in the "…" menu, which is
                // where a doubled toolbar reads as two of every entry.
                lines.append("\(pad)      overflowed into “…”: \(item.overflowPresentationSource != nil)")
            }
        }
        return lines
    }

    private static func describe(_ item: UIBarButtonItem) -> String {
        let name = item.title ?? item.accessibilityLabel ?? "?"
        guard let menu = item.menu else { return name }
        let rows = menu.children.map { child -> String in
            if let action = child as? UIAction { return action.title }
            if let sub = child as? UIMenu { return sub.title.isEmpty ? "(submenu)" : sub.title }
            return String(describing: type(of: child))
        }
        return "\(name) (menu: \(rows.isEmpty ? "deferred" : rows.joined(separator: ", ")))"
    }

    private static func collectBars(_ view: UIView, into bars: inout [UINavigationBar]) {
        if let bar = view as? UINavigationBar { bars.append(bar) }
        for sub in view.subviews { collectBars(sub, into: &bars) }
    }
}

#endif
