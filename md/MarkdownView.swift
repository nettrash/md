//
//  MarkdownView.swift
//  md
//
//  Created by nettrash on 28/06/2026.
//
//  Renders the block list from `MarkdownParser` as native SwiftUI. Each
//  block maps to a small view; inline spans inside a block come from
//  `MarkdownInline` as an `AttributedString` so `Text` styles them for
//  free. Block quotes recurse through `BlockView`, which is why the
//  switch lives in its own view rather than inline in `MarkdownView`.
//

import SwiftUI

/// The whole rendered document: a vertically stacked, left-aligned column
/// of blocks. Callers wrap this in a `ScrollView`.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    /// Convenience: parse then render. The preview pane re-creates this on
    /// each keystroke; parsing is cheap, and the index-keyed `ForEach`
    /// below keeps a block's view identity stable across reparses (so e.g.
    /// a code block's horizontal scroll position survives typing).
    init(_ source: String) {
        self.blocks = MarkdownParser.parse(source)
    }

    init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Typewriter prose, on ink — `.secondary`/`.tertiary` below derive
        // from this, so muted text stays warm rather than going system-grey.
        .font(Typewriter.font(17))
        .foregroundStyle(Typewriter.ink)
        .textSelection(.enabled)
        .tint(.accentColor)
    }
}

/// Renders one block. Split out so block quotes can render their inner
/// blocks recursively.
private struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block.kind {
        case let .heading(level, text):
            Text(MarkdownInline.attributed(text))
                .font(Self.headingFont(level))
                .foregroundStyle(level >= 6 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .padding(.top, level <= 2 ? 4 : 0)

        case let .paragraph(text):
            Text(MarkdownInline.attributed(text))
                .fixedSize(horizontal: false, vertical: true)

        case let .list(ordered, items):
            ListBlock(ordered: ordered, items: items)

        case let .codeBlock(_, code):
            CodeBlock(code: code)

        case let .quote(blocks):
            QuoteBlock(blocks: blocks)

        case let .table(header, alignments, rows):
            TableBlock(header: header, alignments: alignments, rows: rows)

        case .thematicBreak:
            Divider().padding(.vertical, 2)
        }
    }

    /// Heading sizes use the typewriter face at sizes tied to a text style,
    /// so they still scale with Dynamic Type.
    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return Typewriter.font(30, relativeTo: .largeTitle).bold()
        case 2: return Typewriter.font(25, relativeTo: .title).bold()
        case 3: return Typewriter.font(21, relativeTo: .title2).bold()
        case 4: return Typewriter.font(19, relativeTo: .title3).weight(.semibold)
        case 5: return Typewriter.font(17, relativeTo: .headline).bold()
        default: return Typewriter.font(15, relativeTo: .subheadline).weight(.semibold)
        }
    }
}

// MARK: - List

private struct ListBlock: View {
    let ordered: Bool
    let items: [ListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(for: item)
                        .frame(minWidth: 18, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Text(MarkdownInline.attributed(item.text))
                        .strikethrough(item.task == true, color: .secondary)
                        .foregroundStyle(item.task == true ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(item.level) * 18)
            }
        }
    }

    @ViewBuilder
    private func marker(for item: ListItem) -> some View {
        if let done = item.task {
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .foregroundStyle(done ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        } else if ordered, let ordinal = item.ordinal {
            Text("\(ordinal).").monospacedDigit()
        } else {
            Text("•")
        }
    }
}

// MARK: - Code

private struct CodeBlock: View {
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code.isEmpty ? " " : code)
                .font(Typewriter.code(15, relativeTo: .callout))
                .textSelection(.enabled)
                .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Typewriter.paperSecondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Quote

private struct QuoteBlock: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor.opacity(0.45))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    BlockView(block: block)
                }
            }
            .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Table

private struct TableBlock: View {
    let header: [String]
    let alignments: [ColumnAlignment]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { index, cell in
                        Text(MarkdownInline.attributed(cell))
                            .fontWeight(.semibold)
                            .gridColumnAlignment(horizontal(at: index))
                    }
                }
                Divider().gridCellColumns(max(header.count, 1))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                            Text(MarkdownInline.attributed(cell))
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Typewriter.paperSecondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func horizontal(at index: Int) -> HorizontalAlignment {
        guard index < alignments.count else { return .leading }
        switch alignments[index] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
