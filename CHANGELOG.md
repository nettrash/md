# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The build number (`CFBundleVersion`) is auto-incremented on every build by
a scheme post-action (`agvtool bump`) and is not tracked here.

## [1.2] — 2026-07-14

### Added

- **Export as PDF.** A dedicated "Export as PDF…" action in the share menu
  renders the document and saves the PDF straight to a location you pick in
  Files, alongside the existing share flow.
- **Table of contents.** A "Contents" menu in the toolbar lists every heading
  in the document; choosing one jumps the preview — and the editor — straight
  to it. Headings now carry GitHub-style anchors, so `[…](#section)` links
  navigate inside the document too.
- **Page breaks.** Write `\newpage` (or `\pagebreak`) on its own line — the
  Pandoc convention — to end a page where *you* decide: shared and exported
  PDFs and printouts start a fresh A4 page there, and the preview shows a
  subtle dashed rule.
- **Synchronized scrolling in Split.** On iPad, the editor and the preview
  scroll as one: move either pane and the other follows proportionally.
  Jumping to a heading from the Contents menu still lands each pane on its
  precise spot.
- **Word and character count.** Every document shows its live word and
  character count in a footer under the page.
- **Private author notes.** `<!-- note: … -->` comments are the writer's
  working notes: a new "Notes" toolbar menu lists them and jumps to them in
  the editor, and they never appear in the preview, the PDF, or print.
  (Other HTML comments are now dropped from the rendered output as well.)
- **Writer mode: books.** Create a book from scratch ("New Book…" — name it
  and choose where it lives) or open an existing folder as one, from the new
  "Book" toolbar menu: its subfolders are chapters, its Markdown files are
  articles, ordered by numeric filename prefix ("01-intro.md") and then
  alphabetically. The book navigator opens any article and creates new
  chapters and articles in place; the book is remembered across launches.
- **The book, right from the launch screen.** The opening screen now offers
  the same actions as the editor's Book menu beside "New Document": Show
  Book reopens the book you were writing, Open Book… picks a folder, and
  New Book… creates one — so writer mode no longer requires opening a
  document first.
- **Images.** `![alt](url "title")` now renders in the preview, shared and
  exported PDFs, and print — including linked images (`[![…](…)](…)`).
  Links also honour an optional hover title. Images keep their original
  size, capped to the page width.
- **Built-in examples.** A new "Examples" toolbar menu opens ready-made
  documents showing everything md can do — formatting, tables, code,
  images, math, diagrams, and the writer tools — each as a fresh document
  of your own to explore and edit. "Example Book…" in the same menu unpacks
  a small sample book into a folder you choose and opens it, so chapters
  and articles can be seen in action.
- **Book management.** Long-press any chapter or article in the book
  navigator to Rename, Move Up / Move Down, or Delete it. Reordering is
  written back to the filenames — the whole group is renumbered with tidy
  "01-", "02-" prefixes — so the order is real, portable, and visible in
  any file manager.
- **Compile a book to PDF.** The book navigator's new share menu renders
  the entire book — a title page, then every chapter and article in
  reading order, each starting on a fresh page — through the same PDF
  pipeline as a single document, ready to share or save as
  "&lt;Book name&gt;.pdf".
- **Export a book as EPUB.** "Export as EPUB…" packages the book as a
  standard EPUB 3 — chapters and articles in reading order with a proper
  table of contents — that opens in Apple Books and other readers. Math
  formulas and Mermaid / PlantUML diagrams are rendered by the app's own
  offline engines and embedded as images, so they display in any reader.

### Changed

- **PDFs are real A4 pages.** Shared and exported PDFs come from the same
  engine as printing: A4 pages, paginated line-aware — no line of text or
  diagram sliced at a fold — with `\newpage` starting a fresh page. The
  earlier one-long-page layout is gone; the continuous page lives on where
  it belongs, in the on-screen preview.
- **Paper is white.** Printouts and PDFs no longer carry the on-screen
  paper tint — the tinted block ended mid-page against the white A4
  margins — and always use the light ink, even from a dark-mode device:
  the whole page is one color, the way a manuscript prints. The preview
  keeps its warm paper and dark theme on screen.
- Printed and exported documents now use a smaller body size (11 pt, down
  from 13 pt) — standard print typography that fits more of the document per
  page — and long code lines wrap instead of being clipped at the code
  block's edge (on screen they scroll; paper can't). The on-screen preview
  is unchanged.

### Fixed

- **Book articles open again.** Tapping an article in the book did nothing
  on iPhone — the editor never appeared, and tapping a *second* article was
  just as dead. (Under the hood the app asked iOS for an extra window, which
  a phone flatly refuses.) Articles now open in the editor the way tapping a
  file in the browser does, including switching straight from one article to
  another while the first is open.
- **Shared PDFs no longer cut lines.** "Share Rendered PDF" (and the new
  export) paginates with the print engine's line-aware page breaks, so no
  line of text or diagram is ever sliced through the middle at a page
  boundary — the break falls between lines, as printing always did.
- **Legacy Cyrillic text files decode correctly.** A Windows-1251 file
  without a byte-order mark could be misread as UTF-16 — mojibake that the
  next autosave would have baked into the file. UTF-16 is now only detected
  by its BOM, so such files open (and round-trip) as the Cyrillic text they
  are.

## [1.1] — 2026-07-05

### Added

- **Math, Mermaid and PlantUML in the preview.** The rendered preview now draws
  TeX/LaTeX math — `$…$` inline and `$$…$$` display, plus ` ```math ` blocks,
  the way GitHub does — as well as **Mermaid** graphs (` ```mermaid `) and
  **PlantUML** diagrams (` ```plantuml `). Everything renders **on-device** from
  bundled engines: no network, no accounts, nothing leaves your device. The same
  rendering flows through to Print / Save-as-PDF and “share rendered”, so a
  diagram or formula you see in the preview is exactly what you export.

### Changed

- The rendered preview now uses the same HTML/WebKit rendering as Print / PDF /
  share (previously a separate native renderer), so the preview and the exported
  document are pixel-identical.

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
