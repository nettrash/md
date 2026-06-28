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

import SwiftUI

struct DocumentView: View {
    @Binding var document: MarkdownDocument

    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Per-window mode preference (SceneStorage, not AppStorage, so each
    /// document window keeps its own layout). Falls back to a sensible
    /// per-width default in `effectiveMode` when the stored value can't apply.
    @SceneStorage("md.viewMode") private var storedMode = Mode.split.rawValue

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

    var body: some View {
        content
            .toolbar {
                // The mode switch lives in the navigation/window toolbar —
                // the native, expected home for a view-mode control on Mac.
                // It's on the trailing edge (not `.principal`) so it doesn't
                // fight the document title + its tap-to-rename control.
                //
                // No explicit `.frame(maxWidth:)`: forcing a width made the
                // toolbar item an oversized backed container, and the smaller
                // segmented control sitting inside it looked like a double
                // border on Mac Catalyst. Letting the control size to its
                // own content keeps the toolbar item snug around it.
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("View mode", selection: modeBinding) {
                        ForEach(availableModes) { mode in
                            Label(mode.label, systemImage: mode.symbol).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.iconOnly)
                    .fixedSize()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        switch effectiveMode {
        case .edit:
            editor
        case .preview:
            preview
        case .split:
            // Side by side when there's room; if the window is a "regular"
            // size class but still physically narrow (a small Catalyst
            // window), stack the panes vertically rather than cramping two
            // unusable columns.
            GeometryReader { geo in
                if geo.size.width >= 640 {
                    HStack(spacing: 0) {
                        editor
                        Divider()
                        preview
                    }
                } else {
                    VStack(spacing: 0) {
                        editor
                        Divider()
                        preview
                    }
                }
            }
        }
    }

    /// Binds the segmented control to the persisted mode.
    private var modeBinding: Binding<Mode> {
        Binding(get: { effectiveMode }, set: { storedMode = $0.rawValue })
    }

    // MARK: - Panes

    private var editor: some View {
        TextEditor(text: $document.text)
            .font(.system(.body, design: .monospaced))
            .lineSpacing(2)
            .autocorrectionDisabled(false)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemBackground))
            .overlay(alignment: .topLeading) {
                if document.text.isEmpty {
                    // TextEditor has no native placeholder; mimic one.
                    Text("# Start writing…")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var preview: some View {
        ScrollView {
            MarkdownView(document.text)
                .padding(.horizontal)
                .padding(.vertical, 12)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(uiColor: .systemBackground))
    }
}
