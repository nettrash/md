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
//  switch, Undo / Redo (driven by the editor's `EditorController`), and a
//  share / print menu, all as native iOS 26 Liquid Glass controls.
//

import SwiftUI

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

    var body: some View {
        // No `.navigationDocument` / `.navigationTitle` here on purpose: in a
        // `DocumentGroup`, the system title bar is bound to the open document
        // automatically; setting `navigationDocument` to a snapshot of
        // `file.fileURL` only overrode that. `fileURL` is used solely to name
        // exports / the print job and to drive the in-app Rename.
        content
            .background(Typewriter.paper.ignoresSafeArea())
            .toolbar { toolbarContent }
            .navigationBarTitleDisplayMode(.inline)
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

    private var editorPane: some View {
        MarkdownEditor(text: $document.text, controller: editor)
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
        ScrollView {
            MarkdownView(document.text)
                .padding(.horizontal)
                .padding(.vertical, 16)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
