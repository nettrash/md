//
//  SmartTypingAdapter.swift
//  md
//
//  Created by nettrash on 22/09/2026.
//
//  The iOS side of SmartTyping: what sits between `UITextView`'s keystrokes
//  and the two pure functions in `SmartTyping.swift`. The specification's
//  §3 ("Platform contract") is the contract implemented here; the section
//  numbers in the comments are that document's.
//
//  Three pieces, in order of purity:
//
//  * `WordInsertion` — §3.3, first paragraph. The keyboard hands a text
//    view whole *words* as often as single letters (QuickPath, the
//    predictive bar, dictation), and `capitalize` sees exactly one scalar.
//    This is the reduction: which insertions count as a word insertion,
//    what their first scalar is, and the one exemption from §3.4's last
//    sentence (a letter typed over its own capital). Pure; unit-tested.
//  * `CapitalOverride` — §3.4, the override state machine: the last
//    capital md produced is *tracked* by its offset `p` until an edit
//    takes it out, and that edit *arms* the override at its own start
//    `q`; a word typed at `q` then goes in as typed, once. Every other
//    edit only moves `p` and `q` along. Pure; unit-tested.
//  * `SmartTextView` — the `UITextView` subclass the editor pane actually
//    shows. It is deliberately a thin shell: `insertText(_:)` routes Return
//    to `SmartTyping.enter` and a word insertion to `SmartTyping.capitalize`
//    through the two helpers above, and applies whatever comes back as one
//    edit. Nothing here re-derives a rule; if a keystroke comes out wrong,
//    the vectors decide whether the functions or this glue are at fault.
//
//  The hook is `insertText(_:)`, not the delegate's `shouldChangeTextIn`:
//  that one also fires for autocorrect replacements and for every
//  programmatic `replace(_:withText:)` — including the ones this file
//  makes — and would see md's own edits as typing (§3.3, A.1).
//
//  WHERE THE OVERRIDE LEARNS ABOUT EVERY EDIT
//  ------------------------------------------
//  §3.4 is written in offsets: `p` has to follow the capital through
//  whatever else happens to the text, the edit that removes it has to be
//  seen removing it, and `q` has to follow the slot until a word is typed
//  there. Most edits never reach `insertText(_:)` or `deleteBackward()`:
//  Cut, Paste, a drop, a hardware forward delete, Scribble's scratch-out,
//  an autocorrect replacement and UIKit's own undo of a typing run all edit
//  the text through `replace(_:withText:)` or the text storage directly
//  (Paste does not even land synchronously — it arrives a run-loop pass or
//  two later). The one place every edit passes through is the
//  `NSTextStorage`, so the view is its storage's delegate and reads each
//  character edit off `textStorage(_:didProcessEditing:range:changeInLength:)`
//  — the original range, the text that replaced it — and hands it to
//  `CapitalOverride.edit`, which classifies it (§3.4). The typed text
//  itself and md's Enter edit are read there like everything else: they
//  are replacements, and the state machine needs their offsets. Two edits
//  are *not* read there, because they are md's own and would be
//  misread: the one-scalar swap that puts the capital in (the state
//  machine hears `produced` instead — the swap is the capital, not an edit
//  that removes one) and the swaps its Undo and Redo make (`capitalUndone`
//  and `produced` again: Undo is the edit that removed the capital, §3.5,
//  and the restored letter is not re-judged). They run under
//  `isApplyingOwnEdit`, which the storage delegate honours. Whether an
//  insertion read off the storage was a §3.3 word insertion is something
//  only `insertText(_:)` knows, so it says so (`observingWordInsertion`)
//  for the duration of its own `super.insertText`.
//
//  What the storage reports is not always the edit: `editedRange` is the
//  union of everything one editing pass touched, and a paste, for one,
//  lands together with the attribute fixing around it, so the report
//  covers the paragraph (its old length is `editedRange.length - delta`,
//  the union's, not the edit's). Taken at face value, a paste before the
//  capital reads as a replacement over it and the capital counts as
//  removed. So the view keeps `mirror`, a unit-for-unit copy of the text,
//  and trims each report to the true edit: the units the old and new
//  text share at the union's start and end were not edited. (Where the
//  edit is ambiguous — inserting `m` into `mm` — the trim picks one
//  place; the text is the same either way.)
//
//  This is also why there is no `paste(_:)` override: pasted text never
//  goes through `insertText(_:)` on this UIKit, so it is never offered to
//  `capitalize` (§3.3 wants a pasted single word left alone), and the
//  storage delegate sees it land, wherever and whenever it does.
//
//  UNDO (§3.5), AND WHY THE REGISTRATION IS DEFERRED
//  -------------------------------------------------
//  A capital must be its own undo step: Undo right after it restores the
//  lowercase letter and leaves the typing run alone. AppKit has
//  `breakUndoCoalescing()` for exactly this; UIKit has nothing public, and
//  its `_UITextUndoManager` groups strictly per run-loop event — every
//  registration made while a keystroke is being handled joins that
//  keystroke's group, and ending that group by hand corrupts its
//  bookkeeping (it raises on the next keystroke). What *does* work, and
//  what `SmartTypingAdapterTests` pins: a registration made after the
//  keystroke's group has closed is its own step and breaks the typing
//  coalescing on both sides. So the capital is applied synchronously with
//  undo registration disabled (the letter shows capitalized at once, and
//  the delegate — the document binding — sees the final text), and its
//  undo action is registered once the run loop has closed the keystroke's
//  group, in a group of its own. The action swaps the one scalar back,
//  puts the caret after it, arms the override, and registers its own
//  inverse, so Redo is symmetric.
//
//  "Once the group has closed" is not "on the next main-queue turn":
//  CFRunLoop may service the main dispatch queue *before* the
//  before-waiting observers of a pass, and a keystroke's pass skips those
//  observers altogether, so a `DispatchQueue.main.async` block can run
//  while the event group is still open (it did, one run in three, and
//  the capital then undid together with the next keystroke). What closes
//  the group is Foundation's own run-loop observer, at the documented
//  `NSUndoCloseGroupingRunLoopOrdering`; `SmartTextView` installs a
//  one-shot observer ordered right after it and checks `groupingLevel`
//  before registering, so the registration lands in the same pass that
//  closed the group, and never inside one. The group it registers in is
//  opened and closed on the spot, with `groupsByEvent` off for those
//  three calls, so no implicit event group is left open for the next
//  keystroke to fall into (`registerCapitalUndo`).
//

import UIKit

// MARK: - §3.3 Word-insertion reduction

/// Which insertions are reduced to their first scalar, and how.
enum WordInsertion {

    /// The first scalar of `text` iff `text` is a **word insertion**
    /// (§3.3): it contains no line terminator and no WS19 unit other than
    /// at most one trailing SP, its first scalar is a Lowercase letter
    /// (`Ll`), and it contains none of `://`, `www.`, `@`, `/` — a pasted
    /// or predicted `https://a.b`, `~/Documents/x` or `@nettrash` is
    /// inserted unchanged, because `capitalize` sees only the first
    /// scalar and could not tell. Returns nil for anything else (a phrase,
    /// a digit, an uppercase letter, a lone surrogate, an empty string).
    static func firstScalar(of text: String) -> String? {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return nil }
        let last = units.count - 1
        for (i, unit) in units.enumerated() {
            if unit == 0x0A || unit == 0x0D { return nil }          // a line terminator
            if unit == 0x40 || unit == 0x2F { return nil }          // `@`, `/` (and so `://`)
            if isWS19(unit), !(unit == 0x20 && i == last) { return nil }
        }
        if contains(units, ascii: "www.") || contains(units, ascii: "://") { return nil }
        let (codePoint, length) = scalar(units, at: 0)
        guard let value = Unicode.Scalar(codePoint),
              value.properties.generalCategory == .lowercaseLetter else { return nil }
        return String(decoding: units[0..<length], as: UTF16.self)
    }

    /// `text` with its first scalar replaced by `replacement` — the word
    /// as it is inserted after `capitalize` answered (§3.3: "inserts the
    /// word with its first scalar replaced"). `text` must have passed
    /// `firstScalar(of:)`; on an empty string it returns `replacement`.
    static func replacingFirstScalar(of text: String, with replacement: String) -> String {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return replacement }
        let (_, length) = scalar(units, at: 0)
        return replacement + String(decoding: units[length...], as: UTF16.self)
    }

    /// §3.4, last sentence: "a single lowercase letter typed over a
    /// one-scalar selection whose scalar is that letter's `upper` is always
    /// inserted as typed" — independently of the override. `selected` is
    /// the text under the selection, `typed` the letter (one scalar).
    static func retypesOwnCapital(selected: String, typed: String) -> Bool {
        let s = Array(selected.utf16), t = Array(typed.utf16)
        guard !s.isEmpty, !t.isEmpty else { return false }
        let (sCode, sLength) = scalar(s, at: 0)
        let (tCode, tLength) = scalar(t, at: 0)
        guard sLength == s.count, tLength == t.count,                  // exactly one scalar each
              let sValue = Unicode.Scalar(sCode), let tValue = Unicode.Scalar(tCode),
              tValue.properties.generalCategory == .lowercaseLetter else { return false }
        // The §0.7 one-scalar guard: the full mapping, accepted only when
        // it is a single scalar (which is then the simple mapping).
        let upper = tValue.properties.uppercaseMapping.unicodeScalars
        guard upper.count == 1, let u = upper.first else { return false }
        return u == sValue
    }

    // MARK: Unit helpers (UTF-16 throughout — never `Character`s, §0.1)

    /// The 19 scalars the specification calls whitespace (§0.3) — and
    /// nothing else: not `.whitespaces`, not `isWhitespace`.
    static func isWS19(_ u: UInt16) -> Bool {
        u == 0x09 || u == 0x20 || u == 0xA0 || u == 0x1680
            || (u >= 0x2000 && u <= 0x200B) || u == 0x202F || u == 0x205F || u == 0x3000
    }

    /// The scalar starting at unit `i` and the number of units it spans
    /// (2 for a surrogate pair, else 1; a lone surrogate is returned as
    /// its own code, which `Unicode.Scalar.init` then rejects).
    static func scalar(_ units: [UInt16], at i: Int) -> (code: UInt32, length: Int) {
        let high = UInt32(units[i])
        if high >= 0xD800, high <= 0xDBFF, i + 1 < units.count {
            let low = UInt32(units[i + 1])
            if low >= 0xDC00, low <= 0xDFFF {
                return (0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00), 2)
            }
        }
        return (high, 1)
    }

    private static func contains(_ units: [UInt16], ascii pattern: String) -> Bool {
        let p = Array(pattern.utf16)
        guard units.count >= p.count else { return false }
        var i = 0
        while i + p.count <= units.count {
            var j = 0
            while j < p.count, units[i + j] == p[j] { j += 1 }
            if j == p.count { return true }
            i += 1
        }
        return false
    }
}

// MARK: - §3.4 Override state machine

/// The override gesture's state (§3.4): the **tracked capital** and the
/// **armed offset**.
///
/// md tracks the last capital it produced: `capitalAt` is `p`, the UTF-16
/// offset of that one scalar, until an edit removes it. Every edit to the
/// text updates the tracking: an edit whose range lies before `p` shifts
/// `p` by the edit's length delta (an insertion *at* `p` pushes the
/// capital right); an edit that removes the capital — a deletion or a
/// replacement whose range reaches into it, unless the new text has that
/// same capital at `p` again — forgets it and **arms** the override at the
/// edit's start `q`; an edit after `p` leaves it alone; a new capital
/// replaces the tracked one (the old one is forgotten, not armed).
///
/// While armed at `q`: a word insertion (§3.3) that starts exactly at `q`
/// goes in as typed — the view asks `overrides(_:inserting:)` before it
/// capitalizes — and clears the override; any insertion that starts
/// elsewhere clears it; a non-word insertion at `q` (a digit, a newline, a
/// paste) leaves it armed; deletions never clear it (one before `q`
/// shifts `q`, one covering `q` moves `q` to its start). An external
/// replacement (open, revert, reload, article switch) clears both.
///
/// Undo of a capital is the edit that removed it (`capitalUndone`), Redo
/// produces it again. Independently of all this, a lowercase letter typed
/// over a one-scalar selection of its own capital is inserted as typed
/// (`WordInsertion.retypesOwnCapital`) — and, when that capital was the
/// tracked one, the replacement removed it and arms the override.
///
/// Every offset is a UTF-16 unit offset into the view's text.
struct CapitalOverride: Equatable {
    /// `p`: where the last capital md produced stands, or nil once it is
    /// gone (or none was produced yet).
    private(set) var capitalAt: Int?
    /// `U`: the units of that capital — one scalar, one or two units —
    /// so an edit that puts it back at `p` can be told from one that
    /// removes it. Empty when nothing is tracked.
    private(set) var capital: [UInt16] = []
    /// `q`: where the override is armed, or nil when it is not.
    private(set) var armedAt: Int?

    var isTracking: Bool { capitalAt != nil }
    var isArmed: Bool { armedAt != nil }

    /// md produced `capital` at `offset` (or Redo put it back): it is the
    /// tracked capital now; whatever was tracked before is forgotten, and
    /// the override is not armed.
    mutating func produced(at offset: Int, capital: [UInt16]) {
        capitalAt = offset
        self.capital = capital
        armedAt = nil
    }

    /// Undo restored the lowercase letter at `offset` (§3.5): the edit
    /// that removed the capital, so the override is armed there. The
    /// letter itself is not re-judged.
    mutating func capitalUndone(at offset: Int) {
        if capitalAt == offset {
            capitalAt = nil
            capital = []
        }
        armedAt = offset
    }

    /// An external replacement of the text: every offset is stale.
    mutating func clear() {
        capitalAt = nil
        capital = []
        armedAt = nil
    }

    /// Whether a word insertion of `inserted` over `range` must go in as
    /// typed (§3.4), asked *before* the edit is made: the override is
    /// armed at the insertion's start, or the edit itself is the one that
    /// removes the tracked capital (which arms it there — a word typed
    /// over a selection that starts on the capital).
    func overrides(_ range: NSRange, inserting inserted: [UInt16]) -> Bool {
        armedAt == range.location || removesCapital(range, inserted: inserted)
    }

    /// The bookkeeping for one character edit, reported after it: `range`
    /// is what was replaced, in the text *before* the edit (empty for a
    /// pure insertion), `inserted` the units that replaced it (empty for a
    /// pure deletion). `isWordInsertion` says whether the view offered
    /// this insertion to the word rule (§3.3) — the only insertion at `q`
    /// that spends the override.
    mutating func edit(_ range: NSRange, inserted: [UInt16], isWordInsertion: Bool) {
        let start = range.location
        let end = range.location + range.length
        if let p = capitalAt {
            if end <= p {                                       // before the capital: it moves
                capitalAt = p + inserted.count - range.length
            } else if removesCapital(range, inserted: inserted) {
                capitalAt = nil
                capital = []
                armedAt = start
            }                                                   // after it, or put back: nothing
        }
        guard let q = armedAt else { return }
        if inserted.isEmpty {                                   // a deletion never clears
            if end <= q {
                armedAt = q - range.length
            } else if start < q {
                armedAt = start
            }
        } else if start != q || isWordInsertion {               // elsewhere, or the retype itself
            armedAt = nil
        }
    }

    /// Whether replacing `range` with `inserted` takes the tracked capital
    /// out: the range reaches into its units, and the new text does not
    /// have `U` at `p` again.
    private func removesCapital(_ range: NSRange, inserted: [UInt16]) -> Bool {
        guard let p = capitalAt else { return false }
        let start = range.location
        let end = range.location + range.length
        guard end > p, start < p + capital.count else { return false }     // wholly before, or after
        let i = p - start
        guard i >= 0, i + capital.count <= inserted.count else { return true }
        return !inserted[i..<(i + capital.count)].elementsEqual(capital)
    }
}

// MARK: - The text view

/// The editor pane's `UITextView`: SmartTyping's `insertText(_:)` hook,
/// the override gesture (fed by the text storage's edits), the dictation
/// skip, Shift-Return on a hardware keyboard, and the two live settings.
/// Everything else about the view (face, colours, insets, undo wiring) is
/// `MarkdownEditor`'s.
final class SmartTextView: UITextView, NSTextStorageDelegate {

    /// `md.continueLists` (§3.1): Return continues lists, quotes and
    /// tables. Off, `SmartTyping.enter` is never called.
    var continueLists = true
    /// `md.capitalizeSentences` (§3.1): the first letter of a line and of
    /// a sentence is capitalized. Off, `SmartTyping.capitalize` is never
    /// called.
    var capitalizeSentences = true

    /// The override gesture's state (§3.4); read by tests.
    private(set) var capitalOverride = CapitalOverride()

    /// Called after any character edit made while the system find panel is
    /// on screen — which is to say after a Replace or a Replace All.
    ///
    /// Those edits are not keystrokes: UIKit performs them itself, and
    /// `textViewDidChange(_:)` is documented as the call for a change made
    /// *by the user*. `MarkdownEditor` hangs its "push the text back
    /// through the binding" here so a replaced document is still a dirty
    /// document, and so still an autosaved one. Idempotent — the coordinator
    /// compares before it assigns — and gated on the panel being up, so an
    /// ordinary keystroke is not synced twice.
    var didEditWhileFinding: (() -> Void)?

    /// Set while this file swaps one scalar for its capital, or back (the
    /// capital, its undo, its redo): the storage delegate leaves those to
    /// the code that made them (see the header).
    private var isApplyingOwnEdit = false
    /// Set while `insertText(_:)` inserts a §3.3 word insertion, so the
    /// storage delegate can tell it from a paste or a composition landing
    /// at the same offset.
    private var observingWordInsertion = false
    /// A unit-for-unit copy of the text, kept in step with every character
    /// edit the storage reports, so a report can be trimmed to the edit it
    /// covers (see the header).
    private var mirror: [UInt16] = []
    /// Set by the Shift-Return key command (§3.6): the next `"\n"` is a
    /// plain newline, whatever the line looks like.
    private var wantsPlainNewline = false
    /// Capitals whose undo action is still to be registered (§3.5): they
    /// wait for the run loop to close the keystroke's undo group.
    private var pendingCapitalUndos: [(offset: Int, lower: [UInt16], upper: [UInt16])] = []
    /// The observer that flushes `pendingCapitalUndos`; nil when idle.
    private var capitalUndoObserver: CFRunLoopObserver?
    /// Passes the observer has seen a group still open; bounds the wait.
    private var capitalUndoPasses = 0

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    deinit {
        if let observer = capitalUndoObserver { CFRunLoopObserverInvalidate(observer) }
    }

    private func configure() {
        // §3.2: md owns capitalization. The keyboard's own sentence rule is
        // off so that code fences stop being capitalized and lists, quotes
        // and headings start being capitalized the same way everywhere;
        // autocorrection stays, it repairs `Ios` → `iOS` after md's capital.
        autocapitalizationType = .none
        autocorrectionType = .default
        // Every edit to the text, whoever makes it, passes through the
        // storage; the override's bookkeeping reads them there (§3.4).
        // UIKit leaves this delegate to the app (a test pins that).
        mirror = Self.units(of: textStorage.string as NSString)
        textStorage.delegate = self
    }

    /// The pane replaced the whole text from outside (revert, reload, an
    /// article switch): every offset the override remembered is stale.
    /// (A capital's undo action left on the stack checks the text before
    /// it touches anything, so it needs no clearing.)
    func textWasReplacedExternally() {
        capitalOverride.clear()
    }

    // MARK: §3.3 The hook

    override func insertText(_ text: String) {
        // Composition in progress (CJK, a Latin marked-text session): the
        // committed text comes back through here later as a word.
        guard markedTextRange == nil else {
            super.insertText(text)
            return
        }
        let selection = selectedRange
        let start = selection.location
        let end = selection.location + selection.length
        let current = self.text ?? ""

        if text == "\n" {
            if wantsPlainNewline {
                wantsPlainNewline = false
                super.insertText(text)
                return
            }
            // Dictation's spoken "new line" arrives here as well and is
            // treated the same (§3.3).
            if continueLists,
               let edit = SmartTyping.enter(current, selectionStart: start, selectionEnd: end),
               let range = textRange(location: edit.location, length: edit.length) {
                // One undoable step: the replacement over the original
                // range, then the caret where the function put it. The
                // storage delegate reads the edit like any other: it is
                // a replacement (never a word insertion), and it may take
                // a prefix out before `p` or `q`, which then move.
                replace(range, withText: edit.replacement)
                let caret = NSRange(location: edit.caret, length: 0)
                selectedRange = caret
                scrollRangeToVisible(caret)
                return
            }
            super.insertText(text)
            return
        }

        // The word rule. The override first, on the text as it still is:
        // is this the retype it is armed for, or the edit that removes the
        // tracked capital (§3.4)? Then it goes in as typed.
        let first = WordInsertion.firstScalar(of: text)
        let overridden = first != nil
            && capitalOverride.overrides(selection, inserting: Array(text.utf16))
        guard capitalizeSentences, !isDictating, !overridden, let first else {
            insertTyped(text, isWordInsertion: first != nil)
            return
        }
        if selection.length > 0,
           WordInsertion.retypesOwnCapital(selected: (current as NSString).substring(with: selection),
                                           typed: first) {
            insertTyped(text, isWordInsertion: true)
            return
        }
        guard let capital = SmartTyping.capitalize(current, selectionStart: start, selectionEnd: end,
                                                   typed: first) else {
            insertTyped(text, isWordInsertion: true)
            return
        }
        insertCapitalized(text, first: first, capital: capital, at: start)
    }

    /// `text` as typed. The storage delegate reads the insertion; it is
    /// told whether it was a word insertion, the one kind that spends an
    /// armed override (§3.4).
    private func insertTyped(_ text: String, isWordInsertion: Bool) {
        observingWordInsertion = isWordInsertion
        super.insertText(text)
        observingWordInsertion = false
    }

    /// §3.5: the capitalization is its own undo step. The word goes in as
    /// typed — part of the typing run, exactly as if md were not there —
    /// then the first scalar is replaced by its capital with undo
    /// registration off, and the capital's own undo action is registered
    /// once the run loop has closed the keystroke's undo group (see the
    /// header for why UIKit needs it that way). Undo then restores the
    /// lowercase letter and leaves the rest of the run alone.
    private func insertCapitalized(_ text: String, first: String, capital: String, at offset: Int) {
        insertTyped(text, isWordInsertion: true)
        let lower = Array(first.utf16)
        let upper = Array(capital.utf16)
        let restLength = (text as NSString).length - lower.count
        guard let range = textRange(location: offset, length: lower.count) else { return }
        undoManager?.disableUndoRegistration()
        applyingOwnEdit { replace(range, withText: capital) }
        undoManager?.enableUndoRegistration()
        // `replace` leaves the caret after the capital; put it back after
        // the word (which is where the writer is typing).
        selectedRange = NSRange(location: offset + upper.count + restLength, length: 0)
        capitalOverride.produced(at: offset, capital: upper)
        scheduleCapitalUndoRegistration(at: offset, lower: lower, upper: upper)
    }

    /// Queue the capital's undo registration for the moment the run loop
    /// has closed the keystroke's group (see the header).
    private func scheduleCapitalUndoRegistration(at offset: Int, lower: [UInt16], upper: [UInt16]) {
        guard undoManager != nil else { return }         // nothing records typing either
        pendingCapitalUndos.append((offset, lower, upper))
        guard capitalUndoObserver == nil else { return }
        capitalUndoPasses = 0
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        // Foundation closes the event group at NSUndoCloseGroupingRunLoopOrdering;
        // observers of one activity run in ascending order, so this one
        // runs right after it.
        let order = CFIndex(NSUndoCloseGroupingRunLoopOrdering) + 1
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, order) {
            [weak self] _, _ in self?.flushCapitalUndoRegistrations()
        }
        capitalUndoObserver = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Register every pending capital, each in a group of its own, once
    /// no event group is open — or after a bounded wait, whatever the
    /// state, so an oddity never leaves an observer running forever.
    private func flushCapitalUndoRegistrations() {
        guard let undoManager else {
            pendingCapitalUndos.removeAll()
            stopCapitalUndoObserver()
            return
        }
        if undoManager.groupingLevel > 0 {
            capitalUndoPasses += 1
            if capitalUndoPasses < 8 { return }
        }
        let pending = pendingCapitalUndos
        pendingCapitalUndos.removeAll()
        stopCapitalUndoObserver()
        for capital in pending {
            registerCapitalUndo(at: capital.offset, lower: capital.lower, upper: capital.upper)
        }
    }

    private func stopCapitalUndoObserver() {
        guard let observer = capitalUndoObserver else { return }
        CFRunLoopObserverInvalidate(observer)
        capitalUndoObserver = nil
    }

    /// The capital's undo action, in a group of its own, opened and closed
    /// here. With `groupsByEvent` on, `beginUndoGrouping()` at level 0
    /// would also open the implicit *event* group, which only the run
    /// loop's next quiet pass closes — and a keystroke handled before then
    /// (a keystroke's own pass skips that close) would join it and undo
    /// together with the capital. `NSUndoManager` provides for a client
    /// managing its own group: `groupsByEvent` off for the duration.
    private func registerCapitalUndo(at offset: Int, lower: [UInt16], upper: [UInt16]) {
        guard let undoManager else { return }
        let groupsByEvent = undoManager.groupsByEvent
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        undoManager.setActionName(Self.capitalActionName)
        undoManager.registerUndo(withTarget: self) { view in
            view.swapCapital(at: offset, from: upper, to: lower, capital: upper)
        }
        undoManager.endUndoGrouping()
        undoManager.groupsByEvent = groupsByEvent
    }

    /// What the Edit menu / ⌘Z hint calls the step.
    static let capitalActionName = "Capitalization"

    /// Undo (or Redo) of a capital: put `to` where `from` is — if it still
    /// is; the stack may be older than the text — with the caret after it,
    /// and register the inverse so the step redoes and undoes again.
    /// `capital` is the capital of the pair whichever way the swap goes.
    /// The swap is md's own edit and is not read off the storage; the
    /// state machine hears it in its own words: Undo is the edit that
    /// removed the capital and arms the override at its slot (§3.5), Redo
    /// produces the capital again.
    private func swapCapital(at offset: Int, from: [UInt16], to: [UInt16], capital: [UInt16]) {
        guard units(at: offset, count: from.count) == from,
              let range = textRange(location: offset, length: from.count),
              let undoManager else { return }
        undoManager.disableUndoRegistration()
        applyingOwnEdit { replace(range, withText: String(decoding: to, as: UTF16.self)) }
        undoManager.enableUndoRegistration()
        selectedRange = NSRange(location: offset + to.count, length: 0)
        undoManager.setActionName(Self.capitalActionName)
        undoManager.registerUndo(withTarget: self) { view in
            view.swapCapital(at: offset, from: to, to: from, capital: capital)
        }
        if to == capital {
            capitalOverride.produced(at: offset, capital: capital)
        } else {
            capitalOverride.capitalUndone(at: offset)
        }
    }

    // MARK: §3.4 Every edit, read off the text storage

    /// Run `edit` as md's own one-scalar swap: the storage delegate below
    /// ignores what it does to the text.
    private func applyingOwnEdit(_ edit: () -> Void) {
        let outer = isApplyingOwnEdit
        isApplyingOwnEdit = true
        edit()
        isApplyingOwnEdit = outer
    }

    /// The bookkeeping for whatever changed the characters — the typed
    /// text, Backspace, forward delete, Cut, Paste, a drop, Scribble,
    /// autocorrect, UIKit's undo of a typing run, md's Enter edit (see the
    /// header). The report is on the text *after* the pass: `editedRange`
    /// is the new extent of what the pass touched, `delta` the change in
    /// length, so the touched range began at `editedRange.location` and
    /// was `editedRange.length - delta` units long. The mirror still holds
    /// that range as it was; the units it shares with the new text at
    /// either end were not edited, and what lies between is the edit that
    /// `CapitalOverride.edit` classifies (§3.4).
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // A Replace or Replace All from the find panel lands here like any
        // other external edit — the override bookkeeping below classifies
        // it exactly as it classifies a paste — but nothing else would tell
        // the SwiftUI binding about it, so say so. Asynchronously: this runs
        // inside the storage's edit pass, which is no place to write a
        // binding and start a SwiftUI update.
        if !isApplyingOwnEdit, findInteraction?.isFindNavigatorVisible == true {
            DispatchQueue.main.async { [weak self] in self?.didEditWhileFinding?() }
        }
        let all = textStorage.string as NSString
        let location = editedRange.location
        let oldLength = editedRange.length - delta
        guard oldLength >= 0, mirror.count == all.length - delta,
              location + oldLength <= mirror.count, location + editedRange.length <= all.length else {
            // The mirror and the storage disagree: whatever happened was
            // not reported as one edit. Start over from the text as it is;
            // every offset is stale.
            mirror = Self.units(of: all)
            capitalOverride.clear()
            return
        }
        let new = Self.units(of: all, in: editedRange)
        let old = mirror[location ..< location + oldLength]
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[old.startIndex + prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.endIndex - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        mirror.replaceSubrange(location ..< location + oldLength, with: new)
        guard !isApplyingOwnEdit, capitalOverride.isTracking || capitalOverride.isArmed else { return }
        let range = NSRange(location: location + prefix, length: oldLength - prefix - suffix)
        let inserted = Array(new[prefix ..< new.count - suffix])
        guard range.length > 0 || !inserted.isEmpty else { return }       // the same text again
        capitalOverride.edit(range, inserted: inserted, isWordInsertion: observingWordInsertion)
    }

    // MARK: §3.3 Dictation never capitalizes

    private var isDictating: Bool {
        textInputMode?.primaryLanguage == "dictation"
    }

    // MARK: §3.6 Shift-Return on a hardware keyboard

    override var keyCommands: [UIKeyCommand]? {
        let shiftReturn = UIKeyCommand(input: "\r", modifierFlags: .shift,
                                       action: #selector(insertPlainNewline(_:)))
        // Return produces text, which the input system otherwise claims
        // before key commands are consulted.
        shiftReturn.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [shiftReturn]
    }

    /// Shift-Return: a plain `"\n"`, bypassing `enter` (§3.6).
    @objc func insertPlainNewline(_ sender: Any?) {
        wantsPlainNewline = true
        insertText("\n")
        wantsPlainNewline = false        // never outlives this one keystroke
    }

    // MARK: Helpers

    /// `count` units of the text starting at `offset`, or nil past the end.
    /// Read off the storage's `NSString`: no bridging that would fold a
    /// lone surrogate into U+FFFD.
    private func units(at offset: Int, count: Int) -> [UInt16]? {
        let all = textStorage.string as NSString
        guard offset >= 0, count >= 0, offset + count <= all.length else { return nil }
        return Self.units(of: all, in: NSRange(location: offset, length: count))
    }

    /// The units of `string` in `range` (the whole string by default).
    private static func units(of string: NSString, in range: NSRange? = nil) -> [UInt16] {
        let range = range ?? NSRange(location: 0, length: string.length)
        guard range.length > 0 else { return [] }
        var units = [UInt16](repeating: 0, count: range.length)
        units.withUnsafeMutableBufferPointer { buffer in
            string.getCharacters(buffer.baseAddress!, range: range)
        }
        return units
    }

    /// A `UITextRange` over `[location, location + length)` in UTF-16
    /// units (`position(from:offset:)` counts units on `UITextView`).
    private func textRange(location: Int, length: Int) -> UITextRange? {
        guard let from = position(from: beginningOfDocument, offset: location),
              let to = position(from: from, offset: length) else { return nil }
        return textRange(from: from, to: to)
    }
}
