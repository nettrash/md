# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The build number (`CFBundleVersion`) is auto-incremented on every build by
a scheme post-action (`agvtool bump`) and is not tracked here.

## [1.0] — 2026-06-28

### Added

- Initial release: a document-based Markdown editor + live previewer for
  iOS / iPadOS 26 and macOS 14+ (Mac Catalyst), built in SwiftUI with no
  third-party dependencies.
- `DocumentGroup` over a `MarkdownDocument` (`FileDocument`): open, edit
  and save `.md` / `.markdown` files in place; plain-text files open and
  round-trip with their original extension. Markdown is declared as an
  imported UTI (`net.daringfireball.markdown`).
- Hand-written block-level Markdown parser and SwiftUI renderer covering
  headings, paragraphs, bullet / ordered / task lists (with nesting),
  fenced code blocks (``` and `~~~`), block quotes (nested), GitHub
  tables with column alignment, and thematic breaks. Inline formatting
  (bold, italic, code, links, strikethrough) is rendered via Foundation's
  `AttributedString(markdown:)`.
- Edit / Split / Preview layout switch; Split is offered on iPad and Mac
  and re-renders live as you type. The chosen layout is remembered.
- Unit tests for the parser (30 cases), including regression coverage for
  setext headings, wrapped list items, `C#`-style headings, tab-indented
  lists and bounded block-quote nesting.
