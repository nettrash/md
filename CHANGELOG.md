# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The build number (`CFBundleVersion`) is auto-incremented on every build by
a scheme post-action (`agvtool bump`) and is not tracked here.

## [1.0] — 2026-06-28

### Added

- Initial release: a document-based Markdown editor + live previewer for
  iOS / iPadOS 26, built in SwiftUI with no third-party dependencies. (A
  native macOS version is planned separately; Mac Catalyst is intentionally
  disabled because its `DocumentGroup` file management — folder display,
  rename, New — is unfixably unreliable.)
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
- Edit / Split / Preview layout switch, presented as native iOS 26 Liquid
  Glass controls — inline glass chips on iPad, a compact menu on iPhone.
  Split is offered on iPad and re-renders live as you type. The chosen
  layout is remembered.
- **Typewriter theme.** Warm paper background — "fresh paper" in light
  mode, "carbon paper" in dark — with the American Typewriter face across
  the editor and preview, and Courier New for code. Warm-amber
  `AccentColor` and `PaperBackground` / `PaperBackgroundSecondary` /
  `PaperInk` color sets, all with light and dark variants.
- **`UITextView`-based editor.** Toolbar-driven Undo / Redo with live
  enabled state on iPhone and iPad; "smart" quote / dash / period
  substitutions are turned off so Markdown punctuation stays literal; every
  keystroke flows to the document, so the system autosave keeps the file
  current as you type.
- **In-app Rename.** A "Rename…" command renames the file in place
  (keeping its folder and extension) via coordinated file access — handy
  since `DocumentGroup` offers no in-editor rename on iOS.
- **Print & share.** Print the rendered document and share it as a PDF,
  both rendered through WebKit so the typewriter styling and paper
  background follow the current appearance. The raw Markdown source can be
  shared too — the saved file itself when it exists, otherwise the current
  text.
- App icon: a cream American Typewriter "md" on a dark warm-brown gradient.
- Unit tests (41 cases) covering the Markdown parser — including regression
  coverage for setext headings, wrapped list items, `C#`-style headings,
  tab-indented lists and bounded block-quote nesting — plus the
  `MarkdownHTML` export and the in-app rename algorithm.
