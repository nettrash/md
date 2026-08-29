//
//  ViewMode.swift
//  md
//
//  Created by nettrash on 29/08/2026.
//
//  Which of the editor's three display modes a window offers, which one it
//  actually shows, and — new in 1.4 — which one a *file* opens in.
//
//  Two rules and one small store, kept out of `DocumentView` so they are
//  plain, testable values rather than private computed properties on a
//  SwiftUI view:
//
//  * `ViewModeRule` — the width rule (`availableModes` / `effectiveMode`,
//    moved here verbatim from `DocumentView`), the open rule
//    (`openViewMode`), which decides the mode a document opens in, and the
//    display rule (`displayedMode` / `navigationNudge`), which keeps a
//    navigation jump from being mistaken for a layout preference.
//  * `ViewModeMemory` — the per-file memory behind the open rule: a tiny
//    MRU list in `UserDefaults`, keyed by a hash of the file's path.
//  * `BookArticleOpens` — the book exemption. Writer mode steps from
//    chapter to chapter through this same editor, and a writer must not be
//    dropped into Preview on the chapter they were about to write.
//
//  `DocumentView.Mode` itself deliberately stays on the view: the Mac's
//  `BookNavigator` and `BookWorkspace` name it there.
//
//  THIS FILE IS SHARED BYTE FOR BYTE between the iPhone app and the Mac
//  app — no `#if os(…)`, no UIKit, no AppKit, no SwiftUI. What differs
//  between the two is in the callers, not here: what each passes for
//  `isWide` (a Mac document window always passes `true`), and which view
//  marks a book article. The claim is checkable, so check it —
//
//      cmp md/md/ViewMode.swift md.macOS/md/ViewMode.swift
//
//  — and a difference means one of the two ports has quietly changed
//  behaviour for a document both of them open. `ui/ViewMode.kt` in the
//  Android port is the same rule, the same key, the same tokens and the
//  same identity hash once more; being Kotlin it cannot be the same
//  *bytes*, so it is held to the same behaviour by a suite whose six case
//  names match this one's. See the spec's §2.2.
//
//  THE ONE INVARIANT: what gets stored is the RAW preference, never
//  `effectiveMode`'s output. A phone coerces a remembered Split down to
//  Edit for display *without discarding the preference*, so writing the
//  coerced value back would destroy an iPad user's Split the first time
//  they opened the file on their phone. Everything here — the open rule's
//  result, the mode switch in `DocumentView`, the Save-As migration —
//  stores the uncoerced mode and lets the renderer coerce. And a navigation
//  nudge stores nothing at all: see `displayedMode`.
//
//  The other thing that is easy to get wrong: the stored tokens are
//  written out longhand. Never `String(describing:)`, never the enum's
//  `rawValue` — those are refactorable, and this string is on disk in
//  three apps.
//

import CryptoKit
import Foundation

// MARK: - The rules

/// The width rule and the open rule. Pure functions of their arguments —
/// no view, no storage, no clock.
enum ViewModeRule {

    /// The modes offered at the current width: all three when there's room
    /// for Split (iPad, Mac), otherwise just Edit and Preview (iPhone).
    static func availableModes(isWide: Bool) -> [DocumentView.Mode] {
        isWide ? DocumentView.Mode.allCases : [.edit, .preview]
    }

    /// The mode actually shown: the stored preference, coerced to one the
    /// current width supports (Split collapses to Edit on a phone).
    ///
    /// The coercion is display-only — the caller keeps the raw preference,
    /// so widening the window again brings Split back.
    static func effectiveMode(_ stored: DocumentView.Mode, isWide: Bool) -> DocumentView.Mode {
        if availableModes(isWide: isWide).contains(stored) { return stored }
        return stored == .preview ? .preview : .edit
    }

    /// The mode a window actually **displays**: the navigation nudge when
    /// one is in force, otherwise the file's preference — then coerced to
    /// the width by `effectiveMode` exactly as before.
    ///
    /// This split is what keeps merely *looking* at something from silently
    /// becoming a *preference*. A deliberate layout choice — the mode
    /// switch, the toolbar chips, ⌘1/⌘2/⌘3 — sets `preferred`, and that is
    /// what gets remembered for the file. A navigation nudge — jumping to a
    /// note needs the editor on screen; jumping to a heading needs the
    /// preview — sets only `navigation`, which is plain view state: nothing
    /// about the store changes, and the nudge dies with the window.
    ///
    /// Which restores what these apps did before per-file memory existed,
    /// when the mode was session-only: a jump moved you, and it was never a
    /// preference.
    static func displayedMode(preferred: DocumentView.Mode,
                              navigation: DocumentView.Mode?,
                              isWide: Bool) -> DocumentView.Mode {
        effectiveMode(navigation ?? preferred, isWide: isWide)
    }

    /// The transient mode a jump needs in order for its destination to be
    /// visible, or nil when the pane it lands in is already on screen.
    ///
    /// `pane` says where the destination lives: `.edit` for anything that
    /// exists only in the source (a note), `.preview` for anything only the
    /// rendered document has. Split shows both, so it never nudges.
    ///
    /// Asked about the **displayed** mode, never the raw preference — the
    /// question is what the reader can currently see. That is safe only
    /// because the answer goes to `displayedMode`'s `navigation`, which
    /// persists nothing. Asking it about the raw mode instead (an earlier
    /// attempt at the same bug) breaks the feature: on a narrow window a
    /// raw-Split file displays as Edit, the raw mode answers "no nudge
    /// needed", and the tap scrolls a pane that is not on screen.
    static func navigationNudge(displayed: DocumentView.Mode,
                                wants pane: DocumentView.Mode) -> DocumentView.Mode? {
        displayed == pane || displayed == .split ? nil : pane
    }

    /// The mode a document opens in.
    ///
    ///     remembered != nil  ->  remembered   // raw, uncoerced: the file is known
    ///     isEmptyDocument    ->  .edit        // File ▸ New, or a real 0-byte file
    ///     isWide             ->  .split       // unknown + content, wide: unchanged
    ///     otherwise          ->  .preview     // unknown + content, narrow: reader
    ///
    /// The reader-first default lands **only where Split is not on offer**.
    /// On an iPad or a Mac nothing about opening a file changes, which is
    /// the whole point: the store ships empty, so on the first launch after
    /// this update every file in the library is "unknown", and a plain
    /// reader-first rule would open a wide user's entire library read-only.
    ///
    /// `hasFileIdentity` is part of the signature the three ports share and
    /// does not select a branch: a document with no identity simply cannot
    /// have been remembered (so `remembered` is nil) and will not be stored
    /// by the caller. It is passed — and covered by the truth table — so the
    /// three suites can assert that it stays that way.
    static func openViewMode(remembered: DocumentView.Mode?,
                             isEmptyDocument: Bool,
                             hasFileIdentity: Bool,
                             isWide: Bool) -> DocumentView.Mode {
        if let remembered { return remembered }
        if isEmptyDocument { return .edit }
        return isWide ? .split : .preview
    }
}

// MARK: - The per-file memory

/// Remembers, per file, the mode it was last shown in.
///
/// Stored as one small string under `md.viewModeMemory` — a `v1` header
/// line then one `<16 hex> <token>` line per file, newest first, capped at
/// 200 entries (~5 KB). Deliberately **not** JSON: the Android port's unit
/// tests have only JUnit on the classpath, where `org.json` throws "not
/// mocked", so a JSON codec could not be tested there at all, and the three
/// ports must agree byte for byte.
///
/// Deliberately **not** `@AppStorage`: an `@AppStorage` here would re-render
/// every open document window on every write, and would make the codec
/// untestable. `UserDefaults` is injected instead, so the tests get their
/// own suite.
enum ViewModeMemory {

    /// The defaults key, verbatim on iOS, macOS and Android (the family
    /// convention — `md.pdfPageSize` is shared the same way).
    static let defaultsKey = "md.viewModeMemory"

    /// The header that every stored value starts with. A value whose first
    /// line is anything else is treated as absent, which is how a future
    /// `v2` gets to change the format without misreading `v1` data.
    static let header = "v1"

    /// How many files are remembered. The oldest fall off the end.
    static let maxEntries = 200

    /// One remembered file: its identity hash and the raw mode it was last
    /// shown in.
    struct Entry: Equatable {
        let identity: String
        let mode: DocumentView.Mode
    }

    // MARK: Identity

    /// The stable identity of a file: the first 16 hex digits of
    /// SHA-256 over `"file:" + <resolved path>`.
    ///
    /// The symlink resolution is required, not cosmetic: iOS hands the same
    /// document to the app as both `/var/…` and `/private/var/…`, and for a
    /// file that *exists* `resolvingSymlinksInPath()` maps both spellings
    /// onto one path — so the two hash alike and the file keeps its memory
    /// between opens. (`/tmp/…` and `/private/tmp/…` are the same pair.)
    ///
    /// The caveat: `resolvingSymlinksInPath()` is a **no-op on a path that
    /// does not exist**. For a file that is not there the two spellings do
    /// *not* collapse and do *not* hash alike — measured on this machine,
    /// `/var/x.md` → `28026f3dd288fe79` but `/private/var/x.md` →
    /// `7847cd1ad5d0556f`. That costs nothing in practice, because an
    /// identity is only ever computed for a document the app has open:
    /// `DocumentView`'s `fileURL`, and the article URLs writer mode hands
    /// `BookArticleOpens` — all files on disk. A path that names nothing
    /// has no remembered mode to lose.
    ///
    /// A rename or a move made outside the app changes the path and so
    /// loses the memory; the file re-enters as unknown. Accepted.
    static func identity(for url: URL) -> String {
        sha256Prefix("file:" + url.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    /// First 16 hex digits (8 bytes) of SHA-256 over the UTF-8 bytes of
    /// `string`. Split out from `identity(for:)` so the cross-port vector
    /// can be asserted on the string the spec names, rather than on a path
    /// this machine would resolve differently (`/tmp` → `/private/tmp`).
    static func sha256Prefix(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: Tokens

    /// The stored spelling of a mode. Written out by hand, never derived
    /// from the case name: `String(describing:)` and friends would silently
    /// re-spell every stored entry the day someone renames a case, and the
    /// three ports would drift apart.
    static func token(for mode: DocumentView.Mode) -> String {
        switch mode {
        case .edit: return "edit"
        case .split: return "split"
        case .preview: return "preview"
        }
    }

    /// The mode a stored token names, or nil if it names none.
    ///
    /// Case-insensitive, and surrounding spaces are forgiven — a defaults
    /// value hand-edited with `defaults write` is a real thing, and the
    /// Android port's `modeFromToken` forgives exactly the same two things.
    /// Neither can arise inside `decode` (the split already drops spaces);
    /// this is the contract for a direct caller, and it is pinned by the
    /// tests so the three ports keep answering alike.
    static func mode(forToken token: String) -> DocumentView.Mode? {
        switch token.trimmingCharacters(in: .whitespaces).lowercased() {
        case "edit": return .edit
        case "split": return .split
        case "preview": return .preview
        default: return nil
        }
    }

    // MARK: Codec

    /// Parse a stored value. A missing or wrong header means "absent" — the
    /// whole value is discarded. Past that, a line that doesn't parse is
    /// skipped, never fatal, and the first entry for an identity wins (the
    /// list is newest-first).
    static func decode(_ text: String) -> [Entry] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == Substring(header) else { return [] }
        lines.removeFirst()

        var entries: [Entry] = []
        var seen: Set<String> = []
        for line in lines {
            let fields = line.split(separator: " ")
            // The mode is parsed BEFORE the identity is marked seen: a line
            // whose token is unreadable must not consume that file's one
            // slot and hide a good line for the same file further down.
            // `ui/ViewMode.kt` carries the same note over the same order.
            guard fields.count == 2,
                  let mode = mode(forToken: String(fields[1])) else { continue }
            let identity = String(fields[0])
            guard isIdentity(identity), seen.insert(identity).inserted else { continue }
            entries.append(Entry(identity: identity, mode: mode))
        }
        return entries
    }

    /// Render entries back to the stored value. No trailing newline, so the
    /// codec round-trips exactly.
    static func encode(_ entries: [Entry]) -> String {
        ([header] + entries.map { "\($0.identity) \(token(for: $0.mode))" })
            .joined(separator: "\n")
    }

    /// Whether `candidate` has the shape `sha256Prefix` produces: exactly
    /// 16 lowercase hex digits, and nothing else.
    ///
    /// Uppercase is deliberately **not** accepted. No port writes it, so a
    /// `53BA…` line was not written by these apps, and taking it would let
    /// one file hold two entries that disagree. Android's `isIdentity`
    /// draws the line in the same place — and this is an ASCII membership
    /// test rather than `Character.isHexDigit`, which also admits the
    /// full-width digits no port emits.
    static func isIdentity(_ candidate: String) -> Bool {
        candidate.count == 16 && candidate.allSatisfy(hexDigits.contains)
    }

    private static let hexDigits: Set<Character> = Set("0123456789abcdef")

    // MARK: The MRU list

    /// `entries` with `identity` at the front, remembered as `mode`, and the
    /// oldest entries past `maxEntries` dropped. Touching a file already in
    /// the list moves it to the front rather than duplicating it.
    static func touched(_ entries: [Entry],
                        identity: String,
                        mode: DocumentView.Mode) -> [Entry] {
        var updated = entries.filter { $0.identity != identity }
        updated.insert(Entry(identity: identity, mode: mode), at: 0)
        if updated.count > maxEntries {
            updated.removeLast(updated.count - maxEntries)
        }
        return updated
    }

    // MARK: Lookup / store

    /// Everything remembered, newest first. The one read path: `lookup` and
    /// `remember` both come through it, so there is a single place where a
    /// missing or unreadable value becomes "nothing remembered".
    static func entries(defaults: UserDefaults = .standard) -> [Entry] {
        decode(defaults.string(forKey: defaultsKey) ?? "")
    }

    /// The mode remembered for `identity`, or nil if the file is unknown.
    static func lookup(_ identity: String,
                       defaults: UserDefaults = .standard) -> DocumentView.Mode? {
        entries(defaults: defaults).first { $0.identity == identity }?.mode
    }

    /// Remember `mode` for `identity`, moving it to the front of the list.
    ///
    /// `mode` must be the RAW preference — never `effectiveMode`'s output.
    /// See the invariant at the top of this file.
    static func remember(_ mode: DocumentView.Mode,
                         for identity: String,
                         defaults: UserDefaults = .standard) {
        let updated = touched(entries(defaults: defaults), identity: identity, mode: mode)
        defaults.set(encode(updated), forKey: defaultsKey)
    }
}

// MARK: - The book exemption

/// Marks the documents that writer mode is about to open, so the editor can
/// tell "the reader opened this file" from "the writer stepped to the next
/// chapter".
///
/// Book articles are exempt from the per-file memory on all three ports.
/// The reason is structural: an article opens as an ordinary document —
/// on the phone through `DocumentSceneOpener`, on the Mac through the book
/// navigator's Open in New Window — which is the very path a file opened
/// from the browser takes, so without a flag every chapter step would
/// re-run the open rule and drop a writer into Preview on the chapter they
/// were about to write, and an article pulled out into its own window would
/// take one of 200 slots meant for the documents a reader actually keeps.
/// Exempt means both ways: a book article neither reads the memory nor
/// writes to it, and simply keeps the mode the window is in — which is what
/// "one mode per book" means at the level of a single file.
///
/// Keyed by `ViewModeMemory.identity(for:)` rather than by the URL itself,
/// so the `/var` ↔ `/private/var` spellings iOS hands out still match. The
/// mark is claimed once, by the window the article lands in.
///
/// **A mark must not outlive the open it was made for.** It is claimed on
/// the way in — `DocumentView.applyOpenViewMode` claims *before* its
/// unchanged-identity early return — but one open can leave it unclaimed:
/// tapping the article that is already the open document reactivates the
/// existing scene without changing its `fileURL`, so the editor's hook
/// never fires and nobody calls `claimOpen`. A mark left lying about would
/// then be handed to the next ordinary open of that file, which would be
/// silently exempted from the memory. Hence the expiry: a scene activation
/// is immediate, so a mark older than `markLifetime` belongs to an open
/// that has already come and gone, and is discarded.
@MainActor
enum BookArticleOpens {

    /// How long a mark may wait for the window that claims it. Generous
    /// next to a scene activation (which is immediate), short next to a
    /// user opening the same file again from the browser.
    static let markLifetime: TimeInterval = 10

    /// The clock, injectable so the expiry is testable without sleeping.
    static var now: () -> Date = Date.init

    private static var pending: [String: Date] = [:]

    /// Called just before writer mode opens an article.
    static func mark(_ url: URL) {
        dropExpired()
        pending[ViewModeMemory.identity(for: url)] = now()
    }

    /// Called by the window the document lands in: true when this open came
    /// from the book. Consumes the mark, so re-opening the same file from
    /// the document browser later is an ordinary open.
    static func claimOpen(_ url: URL) -> Bool {
        dropExpired()
        return pending.removeValue(forKey: ViewModeMemory.identity(for: url)) != nil
    }

    /// Forget everything pending. For the tests, and for anywhere that
    /// wants a clean slate.
    static func reset() {
        pending.removeAll()
    }

    private static func dropExpired() {
        let cutoff = now().addingTimeInterval(-markLifetime)
        pending = pending.filter { $0.value > cutoff }
    }
}
