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

import SwiftUI
import UIKit

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

    func undo() { undoAction() }
    func redo() { redoAction() }

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

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator

        // Typewriter face, scaled for Dynamic Type and tracking later changes.
        textView.font = Typewriter.editorUIFont()
        textView.adjustsFontForContentSizeCategory = true

        // Paper shows through from the container; ink + accent caret on top.
        textView.backgroundColor = .clear
        textView.textColor = Typewriter.inkUIColor
        textView.tintColor = Typewriter.accentUIColor

        // This is Markdown *source*: keep punctuation literal so the smart
        // substitutions don't turn `"` into curly quotes or `--` into an
        // en-dash and corrupt the syntax.
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.autocorrectionType = .default
        textView.autocapitalizationType = .sentences

        // Comfortable margins; flush the text to the inset's left edge.
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive

        textView.text = text

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
        context.coordinator.textView = textView

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        // Only reassign on a genuine *external* change (revert, open, a
        // programmatic edit) — never on our own keystroke echo, which would
        // yank the caret to the end. Preserve the selection across the swap.
        if textView.text != text {
            let selected = textView.selectedRange
            textView.text = text
            let clampedLocation = min(selected.location, (text as NSString).length)
            let clampedLength = min(selected.length, (text as NSString).length - clampedLocation)
            textView.selectedRange = NSRange(location: clampedLocation, length: clampedLength)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

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
    }
}
