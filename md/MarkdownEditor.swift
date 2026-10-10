//
//  MarkdownEditor.swift
//  md
//
//  Created by nettrash on 28/06/2026.
//
//  The raw-Markdown editing pane, a `UITextView` wrapped for SwiftUI.
//
//  Why not SwiftUI's `TextEditor`? Two of the things this app needs are
//  awkward or impossible to get from it: a *reliable, observable* undo /
//  redo stack the toolbar can drive and reflect (enabled state included),
//  consistently across iPhone and iPad; and full control of
//  the typing surface — the American Typewriter face, a clear paper
//  background, and turning off the "smart" quote / dash substitutions that
//  would silently rewrite Markdown punctuation (`"`, `--`, `...`).
//
//  A `UITextView` gives all of that. `EditorController` lifts the text
//  view's `undoManager` state into an `ObservableObject` so the SwiftUI
//  toolbar's Undo / Redo buttons enable, disable and fire correctly. Every
//  keystroke flows back through the `text` binding, which is what marks the
//  `FileDocument` dirty and drives the document architecture's autosave.
//
//  The view itself is `SmartTextView` (`SmartTypingAdapter.swift`), the
//  subclass that routes Return and typed words through `SmartTyping` —
//  list / quote / table continuation and sentence capitalization. The two
//  toolbar toggles behind it (`md.continueLists`, `md.capitalizeSentences`)
//  arrive here as plain values and are pushed into the view on every
//  update, so flipping one takes effect on the next keystroke without the
//  pane being rebuilt.
//

import SwiftUI
import UIKit
import os

/// The editor's own log. Find is a user-visible command: when it cannot do
/// what it was asked, it has to say so somewhere rather than return in
/// silence — see `EditorController.presentFind()`.
private let editorLog = Logger(subsystem: "me.nettrash.md", category: "editor")

/// Bridges the editor's `UITextView` undo stack to SwiftUI: publishes
/// whether undo / redo are currently available (so the toolbar buttons can
/// enable / disable) and exposes actions the toolbar can invoke.
@MainActor
final class EditorController: ObservableObject {
    @Published var canUndo = false
    @Published var canRedo = false

    /// Wired up by the editor's coordinator in `makeUIView`. They perform
    /// the undo / redo *and* push the resulting text back through the
    /// binding, so a programmatic undo still triggers autosave.
    fileprivate var undoAction: () -> Void = {}
    fileprivate var redoAction: () -> Void = {}

    /// The live text view, wired in `makeUIView`; weak so a torn-down pane
    /// (mode switched to Preview) doesn't linger. `scrollTo(line:)` uses it.
    fileprivate weak var textView: UITextView?

    /// A jump requested while no editor pane existed — e.g. tapping a note
    /// in Preview mode switches to Edit first, and the jump has to wait for
    /// the pane to be built. Consumed by `flushPendingScroll()`.
    private var pendingLine: Int?

    /// Wired in `makeUIView`: runs one formatting command over the live
    /// text view (see `MarkdownFormatting`) as a single undoable edit.
    fileprivate var formatAction: (MarkdownFormatting.Op) -> Void = { _ in }

    func undo() { undoAction() }
    func redo() { redoAction() }

    /// Bold, a heading, a list… over the editor's selection — the Format
    /// menu, the hardware-keyboard chords and the phone bar all land here.
    /// A no-op when there is no editor pane (Preview tore it down).
    func format(_ op: MarkdownFormatting.Op) { formatAction(op) }

    #if DEBUG
    /// Wire a text view in the way `makeUIView` does, so a hosted test can
    /// drive `presentFind()` over a real editor. `textView` is `fileprivate`
    /// and `@testable` does not reach that, and nothing here is compiled
    /// into a Release build.
    func attachForTesting(_ textView: UITextView) { self.textView = textView }
    #endif

    /// Open the system find-and-replace panel over the editor pane.
    ///
    /// The panel is UIKit's own (`UIFindInteraction`, switched on by
    /// `isFindInteractionEnabled` below): the same one ⌘F brings up on a
    /// hardware keyboard and the same one the text-selection menu's Find
    /// item shows. Routed through here so `DocumentView` asks the editor
    /// for it, the way it asks for undo — the toolbar reaches into no
    /// UIKit of its own.
    ///
    /// A no-op when there is no editor pane (Preview mode tore it down);
    /// the toolbar hides the row there anyway, but a chord can still
    /// arrive, and doing nothing is the right answer to it.
    ///
    /// Every way this can decline to open the panel is logged. It used to
    /// return in silence, and a user-visible command that silently does
    /// nothing is indistinguishable from a broken one — which is exactly
    /// how the dead Find row of 1.5 was reported, with nothing in the
    /// Console to say why.
    func presentFind() {
        guard let textView else {
            editorLog.notice("Find: no editor pane to search (the document is in Preview)")
            return
        }
        guard let interaction = textView.findInteraction else {
            editorLog.error("Find: the editor pane has no find interaction")
            return
        }
        // A pane that is not in a window cannot present anything: UIKit
        // drops `presentFindNavigator` on the floor and the command reads
        // as dead. That is what a document view left behind by an open into
        // the same scene answers with (see `DocumentView.generation`).
        guard textView.window != nil else {
            editorLog.notice("Find: the editor pane is not on screen")
            return
        }
        // Focus first: the panel searches the text view it belongs to, and
        // a pane that never took focus has no selection for "Use Selection
        // for Find" to start from.
        if !textView.isFirstResponder {
            textView.becomeFirstResponder()
        }
        // Presented in this same turn, deliberately. Deferring it by a
        // runloop hop was tried and is not needed here — the row fires it
        // from a plain navigation-bar button, not from inside a menu that
        // is dismissing, and the panel comes up either way (measured on
        // iOS 26.5 and 27.0 by firing the bar item's own action).
        //
        // Replace on every platform, iPhone included — the system panel
        // offers the field and there is no reason for a phone to get less.
        interaction.presentFindNavigator(showingReplace: true)
    }

    /// Move the caret to the start of the given 0-based source line and
    /// scroll it into view (used by the Contents / Notes menus). If the
    /// editor pane doesn't exist yet, remember the request — the pane
    /// flushes it as soon as it comes on screen.
    func scrollTo(line: Int) {
        guard let textView else {
            pendingLine = line
            return
        }
        let range = NSRange(location: Self.offset(ofLine: line, in: textView.text ?? ""),
                            length: 0)
        textView.selectedRange = range
        textView.scrollRangeToVisible(range)
        // Focus the editor so the caret marks the destination — scrolling
        // alone leaves nothing visible at the target line. Only when the
        // view is actually installed; a detached view can't take focus.
        if textView.window != nil, !textView.isFirstResponder {
            textView.becomeFirstResponder()
        }
    }

    /// UTF-16 offset of the first character of `line` (0-based). Line
    /// breaks are counted exactly the way `MarkdownParser` normalises
    /// them — `\n`, `\r\n` and a bare `\r` each end one line — so parser
    /// line numbers land on the right spot even in a CRLF file.
    /// (`NSString.lineRange(for:)` is deliberately not used: it also
    /// breaks at U+2028 / U+2029, which the parser does not.)
    static func offset(ofLine line: Int, in string: String) -> Int {
        let ns = string as NSString
        var offset = 0
        var remaining = line
        var i = 0
        while remaining > 0, i < ns.length {
            let ch = ns.character(at: i)
            i += 1
            if ch == 0x0A {                               // \n
                remaining -= 1; offset = i
            } else if ch == 0x0D {                        // \r or \r\n
                if i < ns.length, ns.character(at: i) == 0x0A { i += 1 }
                remaining -= 1; offset = i
            }
        }
        // Asked for a line past the end? Stay at the start of the last
        // line that exists — the closest sensible spot.
        return offset
    }

    /// Complete a jump that was requested before the editor pane existed.
    /// Called by the pane (async, so the view is in the window and laid out
    /// by then) right after `makeUIView` wires `textView`.
    fileprivate func flushPendingScroll() {
        guard let line = pendingLine else { return }
        pendingLine = nil
        scrollTo(line: line)
    }

    /// Refresh the published availability from a text view's undo manager.
    fileprivate func refresh(_ undoManager: UndoManager?) {
        let u = undoManager?.canUndo ?? false
        let r = undoManager?.canRedo ?? false
        if u != canUndo { canUndo = u }
        if r != canRedo { canRedo = r }
    }
}

struct MarkdownEditor: UIViewRepresentable {
    @Binding var text: String
    /// Shared with the toolbar so it can drive and reflect undo / redo.
    let controller: EditorController
    /// The Split layout's pane link (see `ScrollSync`): the editor reports
    /// the scrolls the user's finger makes and follows the preview's.
    var scrollSync: ScrollSync? = nil
    /// The Typing menu's toggles (`@AppStorage` in `DocumentView`), read
    /// live: SwiftUI re-runs `updateUIView` when either flips.
    var continueLists = true
    var capitalizeSentences = true
    /// `md.wrapSelection`: typing `*`, `_`, a backtick or `$` over a
    /// selection wraps it (`MarkdownFormatting.wrapTyped`). On by default.
    var wrapSelection = true

    /// A freshly built editor text view, configured but not yet wired to
    /// anything: face, colours, insets, the literal-punctuation rules and
    /// the find interaction. Everything here is a property of *the editor*
    /// rather than of one SwiftUI pane, which is why it is separable — and
    /// separable is what lets a test build the real thing and read the
    /// switches back (`FindAndReplaceTests`).
    static func configured() -> SmartTextView {
        let textView = SmartTextView()

        // Find and Replace. This one flag is the whole feature: UIKit adds
        // the system find panel (with the Replace field), the ⌘F / ⌘G /
        // ⇧⌘G chords on a hardware keyboard, and the Find items in the
        // text-selection and Edit menus. The match rule is the system's,
        // which is also the rule the other ports spell out in md.win's
        // `TextSearch`: ordinal, case-insensitive, wrapping.
        textView.isFindInteractionEnabled = true

        // Typewriter face, scaled for Dynamic Type and tracking later changes.
        textView.font = Typewriter.editorUIFont()
        textView.adjustsFontForContentSizeCategory = true

        // Paper shows through from the container; ink + accent caret on top.
        textView.backgroundColor = .clear
        textView.textColor = Typewriter.inkUIColor
        textView.tintColor = Typewriter.accentUIColor

        // This is Markdown *source*: keep punctuation literal so the smart
        // substitutions don't turn `"` into curly quotes or `--` into an
        // en-dash and corrupt the syntax. (Autocorrection stays on and the
        // keyboard's own sentence capitalization is off — `SmartTextView`
        // sets both: md capitalizes, Markdown-aware, and autocorrect still
        // repairs `Ios` → `iOS` after md's capital.)
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no

        // Comfortable margins; flush the text to the inset's left edge.
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive

        return textView
    }

    func makeUIView(context: Context) -> SmartTextView {
        let textView = Self.configured()
        textView.delegate = context.coordinator
        textView.continueLists = continueLists
        textView.capitalizeSentences = capitalizeSentences

        textView.text = text

        // A replace from the find panel is not a keystroke: it arrives as a
        // programmatic edit, and `textViewDidChange` is the delegate call
        // UIKit documents as "changed *by the user*". Without this the
        // replaced text would sit in the view with the binding — and so the
        // document's dirty flag, and so autosave — none the wiser. The hook
        // only fires while the panel is on screen, so ordinary typing still
        // pays for exactly one sync (`textViewDidChange`, below).
        textView.didEditWhileFinding = { [weak coordinator = context.coordinator] in
            coordinator?.sync()
        }

        // Buttons drive the *text view's* own undo manager (the same stack
        // the keyboard's ⌘Z and the system Edit menu use), then sync.
        controller.undoAction = { [weak textView, weak coordinator = context.coordinator] in
            textView?.undoManager?.undo()
            coordinator?.sync()
        }
        controller.redoAction = { [weak textView, weak coordinator = context.coordinator] in
            textView?.undoManager?.redo()
            coordinator?.sync()
        }
        controller.formatAction = { [weak textView, weak coordinator = context.coordinator] op in
            guard let textView, textView.markedTextRange == nil else { return }
            let selection = textView.selectedRange
            guard let edit = MarkdownFormatting.format(
                textView.text ?? "", selectionStart: selection.location,
                selectionEnd: selection.location + selection.length, op: op) else { return }
            Self.apply(edit, to: textView)
            coordinator?.sync()
        }
        // The typed wrap: `*`, `_`, a backtick or `$` typed over a selection
        // wraps it instead of replacing it — asked of the keystroke before
        // SmartTyping sees it, as one undoable edit.
        textView.interceptsInsertion = { [weak textView, weak coordinator = context.coordinator] typed in
            guard let textView, let coordinator, coordinator.parent.wrapSelection else { return false }
            let selection = textView.selectedRange
            guard let edit = MarkdownFormatting.wrapTyped(
                textView.text ?? "", selectionStart: selection.location,
                selectionEnd: selection.location + selection.length, typed: typed) else { return false }
            Self.apply(edit, to: textView)
            coordinator.sync()
            return true
        }
        // The phone bar: on an iPhone the formatting commands ride above the
        // keyboard, where a phone's thumb already is. An iPad has the Format
        // menu and the chords instead.
        if UIDevice.current.userInterfaceIdiom == .phone {
            textView.inputAccessoryView = FormattingBar { [weak controller] op in controller?.format(op) }
        }
        context.coordinator.textView = textView
        controller.textView = textView
        context.coordinator.registerScrollSync()
        // A jump may be waiting from before this pane existed (a Notes tap
        // in Preview mode switches to Edit first). Flush it on the next
        // main-actor turn — after SwiftUI has installed the view in the
        // window and laid it out, so the scroll actually lands.
        Task { [weak controller] in controller?.flushPendingScroll() }

        return textView
    }

    func updateUIView(_ textView: SmartTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.registerScrollSync()
        textView.continueLists = continueLists
        textView.capitalizeSentences = capitalizeSentences
        // Only reassign on a genuine *external* change (revert, open, a
        // programmatic edit) — never on our own keystroke echo, which would
        // yank the caret to the end. Preserve the selection across the swap.
        if textView.text != text {
            let selected = textView.selectedRange
            textView.text = text
            let clampedLocation = min(selected.location, (text as NSString).length)
            let clampedLength = min(selected.length, (text as NSString).length - clampedLocation)
            textView.selectedRange = NSRange(location: clampedLocation, length: clampedLength)
            // Every offset the override gesture remembered is now stale.
            textView.textWasReplacedExternally()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Apply one formatting edit as a single undoable replacement — the same
    /// `replace(_:withText:)` SmartTyping's Return uses — then select what
    /// the edit says to select.
    @MainActor static func apply(_ edit: MarkdownFormatting.Edit, to textView: UITextView) {
        guard let start = textView.position(from: textView.beginningOfDocument, offset: edit.start),
              let end = textView.position(from: textView.beginningOfDocument, offset: edit.end),
              let range = textView.textRange(from: start, to: end) else { return }
        textView.replace(range, withText: edit.text)
        let selection = NSRange(location: edit.selectionStart, length: edit.selectionEnd - edit.selectionStart)
        textView.selectedRange = selection
        textView.scrollRangeToVisible(selection)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownEditor
        weak var textView: UITextView?

        init(_ parent: MarkdownEditor) { self.parent = parent }

        /// Push the text view's current contents back through the binding
        /// (this is what marks the document dirty → autosave) and refresh
        /// the toolbar's undo / redo availability.
        @MainActor func sync() {
            guard let textView else { return }
            if parent.text != textView.text { parent.text = textView.text }
            parent.controller.refresh(textView.undoManager)
        }

        func textViewDidChange(_ textView: UITextView) { sync() }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.controller.refresh(textView.undoManager)
        }

        // MARK: Scroll sync (UITextView is a UIScrollView; its delegate
        // refines UIScrollViewDelegate, so the pane's scrolling arrives
        // right here.)

        /// (Re-)hand the sync our "follow the preview" closure — from make
        /// and update, so pane recreation (a mode round-trip) always
        /// leaves the live coordinator registered.
        @MainActor func registerScrollSync() {
            parent.scrollSync?.scrollEditor = { [weak self] fraction in
                self?.textView?.syncScroll(toFraction: fraction)
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // Only the user's finger (or its momentum) is reported: caret
            // scrolls, jump requests and the sync's own relays stay out,
            // which is the whole feedback-loop guard.
            guard scrollView.isUserScrolling, let fraction = scrollView.syncFraction else { return }
            parent.scrollSync?.editorDidScroll(to: fraction)
        }
    }
}

// MARK: - The phone bar

/// The formatting bar above an iPhone's keyboard: Bold, Italic, Code, Link,
/// Heading (H1 → H2 → H3 → none), Bullet List, Task List, Quote, Outdent and
/// Indent — the family's order (md.win `docs/formatting.md` §5). It scrolls
/// sideways rather than squeezing, so the narrowest phone still gets full-size
/// targets, and its buttons never take focus from the editor.
final class FormattingBar: UIInputView {

    /// The bar's commands in order, with the symbol and the spoken name each one shows.
    static let items: [(op: MarkdownFormatting.Op, symbol: String, name: String)] = [
        (.bold, "bold", "Bold"),
        (.italic, "italic", "Italic"),
        (.code, "chevron.left.forwardslash.chevron.right", "Code"),
        (.link, "link", "Link"),
        (.headingCycle, "number", "Heading"),
        (.bulletList, "list.bullet", "Bullet List"),
        (.taskList, "checklist", "Task List"),
        (.quote, "text.quote", "Quote"),
        (.outdent, "decrease.indent", "Outdent"),
        (.indent, "increase.indent", "Indent"),
    ]

    init(perform: @escaping (MarkdownFormatting.Op) -> Void) {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        for item in Self.items {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: item.symbol)
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
            let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in perform(item.op) })
            button.accessibilityLabel = item.name
            button.accessibilityIdentifier = "format.\(item.op.rawValue)"
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
            stack.addArrangedSubview(button)
        }
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            // Centred when it fits, scrolling when it does not.
            stack.widthAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor, constant: -8),
        ])
        stack.distribution = .equalSpacing
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
