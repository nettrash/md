# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The build number (`CFBundleVersion`) is auto-incremented on every build by
a scheme post-action (`agvtool bump`) and is not tracked here.

## [1.4] — 2026-08-29

### Added

- **Plots.** A fenced block tagged `plot` is now drawn as a chart:

  ```
  x: -10..10
  y: -2..2
  title: Damped oscillation
  envelope = exp(-abs(x)/5)
  sin(x) * exp(-abs(x)/5)
  ```

  Any number of curves, each `f(x)` or `label = f(x)`; a parametric curve
  written `(cos(t), sin(t)) for t in 0..2*pi`; and measured data as
  `points: 0,0 1,2 2,1`. `x`, `y` (or `y: auto`, which fits the window to the
  curve), `title`, `xlabel`, `ylabel`, `legend`, `grid`, `axes`, `width`,
  `height` and `samples` set the rest; anything else before a colon is read as
  a label, so `f: sin(x)` plots. The expression language is the usual one —
  `+ - * / % ^`, comparisons, `&&`, `||`, `pi`, `e`, and `sin cos tan asin
  acos atan sinh cosh tanh asinh acosh atanh sqrt cbrt abs exp exp2 ln log2
  log10 floor ceil round atan2 pow hypot`. `^` binds to the right, so `2^3^2`
  is 512; `-x^2` is −(x²); every value is a real number, so `5/2` is 2.5; and
  a comparison is 1 or 0, which makes `(x > 0) * sqrt(x)` draw exactly the
  half of the domain it names. A curve that leaves the window or goes
  undefined breaks there and picks up again, which is why `tan(x)` draws as
  branches rather than as one spike across the figure.

  It costs **0 KB**. There is no engine behind it and no asset to download:
  the drawing is written straight into the page as an `<svg>`, in the same
  pass that renders the rest of the document, before anything runs. So it
  works everywhere at once and with nothing to wait for — the preview, print,
  an exported PDF, an exported HTML page, "Export Diagram as SVG…" (a plot
  appears in that menu as **Plot**), and an exported **EPUB**, where it is the
  first figure this app has ever shipped as a true vector rather than as a
  photograph of one. A document whose only rich blocks are plots loads no
  engine at all. The LaTeX export keeps the fence verbatim under a comment, as
  it does for the other diagram languages, since LaTeX has no renderer for it.

  The figure is drawn in the page's own ink, so it is right in a light
  preview, in a dark one and on paper without being redrawn — only the curves
  themselves carry fixed colours, eight of them in turn. A fence that cannot
  be read shows one `plot:` line saying what is wrong with your text still
  visible under it, the way every other rich block in md behaves: never a
  hole, never an error box.
- **Every document opens the way you left it.** md now remembers, per file,
  whether you were last in Edit, Split or Preview, and opens it there —
  something you keep coming back to read stays a reading page, something you
  are writing stays a writing page, and you stop re-tapping the same button
  every time. It is remembered for the last 200 files, on this device only,
  and nothing about the file itself changes; renaming or moving a document
  outside md simply lets it start fresh. Two windows open side by side on an
  iPad still keep their own layouts, as they always have.

  Only a mode you *pick* is remembered. Jumping to a note from the Notes menu
  still brings the editor up so the note is actually on screen, but that is a
  move rather than a choice, and the file opens next time in the mode you
  chose — not the one a jump happened to leave you in.

  Files md has not seen before are unchanged on iPad — a document with
  something in it still opens in Split, where both panes fit. On iPhone,
  where there is only ever one pane, an unfamiliar document now opens in
  Preview rather than in the editor: on a phone you are far more often
  opening something to read it than to write it, and Edit is one tap away.
  A brand-new document — or an empty one — opens in Edit everywhere, which
  is the only thing you can do with an empty page.

  Writer mode is deliberately left out of it: stepping from one chapter to
  the next keeps the mode you are working in, rather than dropping you into
  Preview on the chapter you were about to write.

## [1.3] — 2026-07-24

### Added


- **Chemical equations.** Math written with `\ce{…}` — the chemistry
  notation from `mhchem` — now typesets as proper chemistry: `$\ce{H2SO4 + 2
  OH- -> SO4^2- + 2 H2O}$` sets its subscripts, charges and reaction arrow
  the way a textbook would, and `\pu{…}` formats physical units. It works
  anywhere math already does — inline `$…$`, display `$$…$$`, a ` ```math `
  block — in the preview, in print, in an exported PDF and, because it is
  math, in an exported EPUB. It draws **on-device** from `mhchem.min.js`
  (the `mhchem` extension from the same **KaTeX 0.17.0** build the app
  already carries, MIT-licensed), so it adds no network use and only ~33 KB,
  loaded only when a document actually contains a formula.
- **Syntax highlighting.** A fenced code block that names its language —
  ` ```swift `, ` ```js `, ` ```python ` and the like — now reads with its
  keywords, comments and strings set apart, so a snippet is easier to follow
  without turning into a coloured jumble. The theme is written to the app's
  own hand rather than borrowed: keywords take the warm accent, comments the
  muted ink in italic, strings a quieter shade of the ink, and everything
  else stays plain — three calm tones on the same paper as the prose, in the
  same Courier face, rather than a bright editor palette that would fight the
  page. It draws **on-device** from `highlight.min.js` (the
  "common"-languages build of **highlight.js 11.11.1**, ~124 KB,
  BSD-3-Clause), loaded only when a document actually has code to colour, and
  covers the forty-odd languages that build carries; a fence whose language
  it doesn't know, or a fence with no language at all, is simply left as
  plain code. The colouring shows in the preview, in print, in an exported
  PDF and in an exported HTML page; an exported **EPUB** keeps its code
  plain, since that format is built from the document before any of this
  runs.
- **Graphviz diagrams.** A fenced block tagged `dot`, `graphviz` or `gv` is
  now laid out by **Graphviz**, the classic tool for graphs that are
  described rather than drawn. Each of its layout programs can be named as
  the block's language instead — `neato`, `circo`, `fdp`, `sfdp`, `twopi`,
  `osage` and `patchwork` — so the same graph can be given a hierarchy, a
  spring model, a circle or a radial fan by changing one word. A bare `.gv`
  file opens in md the way a `.puml` file already does — from the document
  browser, Files, or "Open with md" — and renders as the diagram in the
  preview, print and exported PDF while the source stays fully editable.
  All of it draws **on-device** from an engine the app has carried all
  along as PlantUML's own back end, so this costs no extra download and no
  network. Graphviz's other usual extension, `.dot`, is deliberately left
  unclaimed — the system already declares it as a Word template — so rename
  such a file to `.gv` to open it; fenced ` ```dot ` blocks are unaffected.
- **YAML and TOML front matter.** A file written for a blog, a site
  generator or a notes app almost always opens with a block of metadata —
  title, author, date — fenced off above the text. md used to render that
  opening `---` as a horizontal rule and the metadata under it as stray
  prose, so any such file looked broken the moment it was opened. Both
  conventions are now understood — YAML between `---` lines (closed by
  `---` or `...`) and TOML between `+++` lines — and the block is
  recognised as metadata rather than text and hidden: the page begins at
  the first heading in the preview, in print, in an exported PDF and in an
  exported EPUB alike. The block stays in the file and is saved back
  untouched, so whatever else you hand the file to still finds it. Its
  fields are read as plain `key: value` (or `key = value`) pairs rather
  than by a full YAML parser — enough for a title and an author; a list or
  a nested key inside the block is passed over rather than understood, and
  so long as one plain field remains beside it the block is still hidden
  whole. A block that holds no recognisable field at all is not metadata
  and is not treated as such: `---`, three bullets and `---` stay a rule,
  a list and a rule, so prose that merely happens to sit between two rules
  is never hidden from the reader. And it only counts at the very top of a
  document, and only when the fence is closed again: a document that simply
  opens with a horizontal rule keeps its rule, and a `---` further down is
  the thematic break it always was.
- **Footnotes.** An aside that would interrupt a sentence can now be sent
  to the foot of the page instead, in the spelling GitHub and Pandoc
  already use. Mark the spot in your text with `[^id]`, and write the note
  itself on a line of its own as `[^id]: the note` — wrapping it over as
  many lines as it needs, and putting it wherever in the file suits you,
  since it never renders where it is written. The notes are gathered under
  a rule at the foot of the rendered page — in the preview, in print, in an
  exported PDF and in an exported EPUB alike — and numbered: each reference
  in the text becomes a small numbered link down to its note, and each note
  you cited ends in an arrow that takes the reader back to where it was
  first cited. The numbering follows the order a reader meets the
  references rather than the order the notes happen to be written in, so
  moving a note around the file changes nothing on the page. Two
  kindnesses are deliberate: a reference with no note behind it stays
  exactly the text you typed rather than becoming a link that leads
  nowhere, and a note you wrote but never cited is still printed, after
  the cited ones — nothing you wrote is dropped in silence.
- **CSV and TSV blocks draw as tables.** A table of figures usually begins
  life in a spreadsheet, and turning it into Markdown's pipes and dashes by
  hand is the sort of work nobody wants to do twice. Paste the data as it
  comes instead — into a fenced block tagged `csv`, or `tsv` for the
  tab-separated text a spreadsheet puts on the clipboard — and md draws it
  as an ordinary table in the preview, in print, in an exported PDF, in an
  exported HTML file and in an exported EPUB alike, while the source stays
  the data it always was. That is the point of it: when next month's
  numbers arrive, the block is replaced wholesale with a fresh copy rather
  than edited cell by cell. The first row is the header. Quoting works the
  way a spreadsheet writes it — a field wrapped in quotes may hold a comma
  or even a line break, a doubled quote inside such a field is one literal
  quote, and a quote that opens nothing, the inch mark in `5" pipe`, is
  simply a character. A column whose values are all numbers is lined up on
  the right, so the decimal points sit under one another; a single piece of
  text in the column and it stays left-aligned, as text should be. This is
  a fenced block and nothing more — md still neither opens nor saves `.csv`
  files.
- **Export as HTML.** A new "Export as HTML…" action in the share menu,
  beside "Export as PDF…", saves the rendered document to a location you
  pick in Files as **one self-contained `.html` file**: a single file that
  opens anywhere — a browser, a phone, a machine that has never heard of md
  — with nothing beside it. No engines, no folder of assets, and no engine
  left in the page to run. The only thing an exported page can still reach
  for is an image you linked to yourself: those are written out as the links
  they were, not fetched and embedded. What is saved is the finished page
  rather than the recipe for one: every Mermaid, Graphviz and PlantUML
  diagram has already been drawn and travels as a drawing, and every formula
  has already been typeset and travels as real text — so a reader can copy a
  formula out of the page, and it stays sharp at any zoom. A document with
  formulas carries the typesetting fonts it needs inside the file, and those
  fonts are most of what it weighs; a document without formulas carries none
  of them and is a few kilobytes. And because an exported file is read on a
  screen rather than on paper, the author's `\newpage` markers appear as the
  dashed rules the preview shows rather than as the page breaks the PDF
  gets.
- **Export as LaTeX.** A new "Export as LaTeX…" action in the share menu,
  below "Export as HTML…", writes the document as a `.tex` file to a
  location you pick in Files. This is the one export where your
  mathematics comes out as mathematics: everything else md produces turns
  a formula into a picture — a PDF page, an EPUB, a printout — or into the
  markup a browser typesets, while a `.tex` file hands it back as the
  `$…$` you typed, ready to paste into a paper and go on editing. The rest
  of the document travels with it: headings become `\section` and its
  deeper relatives, emphasis becomes `\textbf` and `\emph`, lists become
  `itemize` and `enumerate` nested the way you nested them, a table — and
  a `csv` or `tsv` block alike — becomes a `longtable` that keeps your
  column alignment and breaks across pages, repeating its header row, so a
  table longer than a page keeps every row instead of stopping at the one
  that filled it. Code becomes `verbatim`, a quote becomes `quote`, and
  your `\newpage` markers stay the `\newpage` they already look like. An
  image becomes `\includegraphics`, set in a captioned `figure` wherever
  you wrote it in body text and gave it alt text — a graphic as wide as
  the text block has nowhere to stand inside a sentence, so the float is
  left for LaTeX to place; inside a table cell or a footnote there is no
  float to be had, so the graphic goes in bare with your alt text in
  italic beside it. When LaTeX cannot include the picture at all — the
  file name has a character `\includegraphics` reads as something other
  than a name (a `"` among them, since graphicx quotes file names with
  those itself), or the image is a `https://` or `data:` URL, which TeX
  will not fetch — the image is skipped rather than taking the whole
  document down with it, and your alt text is set in its place, with a
  comment naming the file on the line below it. Front matter becomes the
  title block: `title`, `author` and `date` become `\title`, `\author` and
  `\date` with a `\maketitle`. A `[^id]` footnote is written into the text
  at the point you first cited it, which is how LaTeX itself would have
  you write it — a second citation becomes a `\footnotemark` carrying the
  same number, a note first cited from a table's header row has its text
  set just after the table, because LaTeX prints nothing from inside a
  header it repeats on every page, and a note you never cited is printed
  at the end all the same. In a book each article numbers its own notes,
  so two articles that both start at `[^1]` — which is the ordinary way to
  write them — each keep their own note's words. A whole book exports the
  same way from the book navigator's share menu, as one `book`-class file
  with each chapter a `\chapter` and each article a `\section`, in the
  order the compiled PDF and the EPUB read them. Three things are worth
  knowing. LaTeX has no renderer for a Mermaid, Graphviz or PlantUML
  diagram, so a diagram's source travels as a `verbatim` block under a
  comment naming its language — kept for you to decide what to do with
  rather than quietly dropped. A display formula that is really a
  multi-line one — a `\\` or an `&` at its own top level, with no
  environment of its own around them — is given an `aligned` so it sets
  where you meant it instead of stopping the compile; and in a table cell
  or a footnote, where LaTeX will not open a display at all, a `$$…$$` is
  set inline rather than being lost. And the preamble asks for exactly the
  packages the document actually uses and no others: `graphicx` only if
  there is an image, `hyperref` only if there is a link, `ulem` only for a
  strikethrough, `longtable` only if there is a table, and the T2A font
  encoding only when the text has Cyrillic in it, which the default
  encoding would otherwise drop without a word — plus `amsmath` whenever
  there is any mathematics at all, since that is where `aligned` and its
  relatives live. So a plain piece of prose comes out with a short, clean
  preamble — and whatever is in it is what your TeX installation has to be
  able to find. - **The diagram types that were already there.** md has
  bundled Mermaid and PlantUML since 1.1, but the examples only ever
  showed a flowchart or two, so most of what they can draw went unnoticed.
  The "Diagrams" example document now shows the range. Mermaid draws
  `flowchart`, `sequenceDiagram`, `classDiagram`, `stateDiagram-v2`,
  `erDiagram`, `journey`, `gantt`, `pie`, `quadrantChart`,
  `requirementDiagram`, `gitGraph`, `C4Context`, `mindmap`, `timeline`,
  `kanban`, `sankey-beta`, `xychart-beta`, `block-beta`, `packet-beta`,
  `architecture-beta`, `radar-beta` and `treemap-beta`. PlantUML draws the
  UML family inside `@startuml` — sequence, class, activity, state,
  component, use case, object and deployment — plus the C4 standard
  library, ArchiMate, timing diagrams and even sudoku. Beyond UML it draws
  a good deal more, each with its own opener: `@startmindmap` and
  `@startwbs` (mind maps and work breakdowns), `@startgantt` (schedules),
  `@startsalt` (interface wireframes), `@startjson` and `@startyaml` (data
  structures), `@startebnf` (grammars), `@startregex` (regular expressions
  as railroad diagrams), `@startnwdiag` (networks), `@startchen`
  (entity–relationship), `@startditaa` (ASCII art turned into a drawing),
  and `@startlatex` / `@startmath` (formulas). Nothing was added to the
  app to make these work — they were always there, only undocumented.

- **Open PlantUML files.** `.puml` (and `.plantuml`) documents now open in
  md — from the document browser, Files, or "Open with md". A file that is a
  raw PlantUML diagram (`@startuml … @enduml`, with no code fence) renders as
  the diagram in the preview, print and exported PDF, while the source stays
  fully editable and saves as plain UTF-8 text.
- **Export a single document as EPUB.** A whole book has been able to
  become an EPUB since 1.2; now a single open document can too, from a
  new "Export as EPUB…" action in the share menu, beside "Export as
  HTML…" and "Export as LaTeX…". What a reader opens is not one flat
  entry standing in for the whole file but the document itself, laid out
  with its own headings as the table of contents — the same outline the
  document already lists, in the same order — so every section is
  somewhere the reader can jump to. The title is taken from the front
  matter's `title:` field when the document has one and from the file's
  own name when it does not: a lone document has no folder to borrow a
  name from, so the file name has the last word. Everything the book
  export already does, this does — every formula and every Mermaid,
  Graphviz or PlantUML diagram is drawn once and travels as a picture,
  and it is the same self-contained EPUB — and the identifier is derived
  from that title, so the same document exports as the same publication
  every time, updating the copy a reader already has rather than settling
  in beside it, the same courtesy a book is given just below. There is no
  title page: a single document is its own first page, and the contents
  point at it rather than at a cover.
- **A page size for the PDF.** The PDF export — and the whole-book PDF
  compile — always came out as A4, which suits a printout and little else
  a document is really made into: a booklet wants A5, a reader in the
  States wants US Letter or Legal, and a paperback printed on demand
  wants one of the trim sizes a print service asks for and will not
  accept as A4. So the size is now yours to choose — A4, A5, US Letter,
  US Legal, or the paperback trims 6 × 9″, 5 × 8″ and 5.5 × 8.5″ — from a
  size picker beside "Export as PDF…" in the share menu, and the same
  picker in the book navigator, where it matters most: a book can be
  compiled at the very size it will be printed at rather than at one no
  press would take. The choice is remembered from one export to the next,
  and the page's margins scale with the paper, so a 6 × 9 page is not
  left wearing the wide margins A4 was cut for. A4 stays the default, and
  an A4 export is unchanged to the pixel; the size reaches only the
  exported or shared PDF and its margins — the preview, the HTML export
  and the EPUB keep their own — and a printout to paper is left alone,
  since a paper proof goes out on whatever the printer is holding.
- **Export a diagram as SVG.** A new "Export Diagram as SVG…" submenu in the
  share menu lists the document's diagrams — one row apiece, named by engine
  and a line of the source so two of them are told apart — and saves the one
  you choose as a standalone `.svg` file to a location you pick in Files: a
  real vector drawing that opens in any browser or vector editor and stays
  sharp at any size. Only the three drawing engines are offered —
  **Mermaid**, **Graphviz** and **PlantUML** — since those are the blocks
  that render to vector; math is not among them, because KaTeX sets a formula
  as HTML and text rather than as a drawing, so a formula has no vector to
  hand over and is left off the list. The diagram is laid out once through
  the same offline engines the preview uses and its finished vector is
  written straight out, not a picture taken of it. Mermaid draws without
  stating a height — which would open a standalone file at no height at all —
  so md fills the real width and height in from the drawing's own coordinates
  before it saves; Graphviz and PlantUML already give their size and are left
  untouched. And a diagram whose source never drew — a syntax error, say —
  has no vector to export, so md says as much rather than leaving an empty
  file behind.
- **Open and export TextBundle.** A TextBundle (`.textbundle`) — and its
  zipped form, a TextPack (`.textpack`) — is the Markdown-with-images
  container that Ulysses, iA Writer and Bear write, and md now opens one,
  from the document browser, Files, or "Open with md": the `text.md` inside
  becomes the editable document. A new "Export as TextBundle…" action in the
  share menu, beside "Export as LaTeX…", writes the current document back out
  as one — `text.md`, the small `info.json` the format expects, and an
  `assets/` folder — and this is where images are handled. A picture you
  linked by a plain relative name (`![](photo.png)`, the file sitting beside
  your document) is copied into `assets/` and its link rewritten to point
  there, so the bundle carries the image with it; a picture md cannot find,
  or one linked on the web or embedded inline as data, is left exactly as you
  wrote it — a link that already led nowhere stays a visible broken link
  rather than being quietly dropped. Two limits are worth stating plainly. A
  bundle is imported for editing rather than adopted as a file to save back
  into, because writing only the text into the package would drop the
  `assets/` and `info.json` it carries — so keep the work as a Markdown file,
  or export a fresh bundle. And md's document is only its text, and its
  preview has never shown a local image, so an opened bundle's own `assets/`
  pictures are not displayed: those refs render as the broken images they
  point at while you edit the prose. The round-trip is the words; the
  pictures travel inside the file, not on the page.

### Fixed


- **An exported book keeps its identity.** Every EPUB export was stamped
  with a freshly invented identifier, so as far as a reader was concerned
  each export was a different publication: fix a typo, export again, and
  the new file settled into the library beside the old one instead of
  replacing it — two copies of the same book, and then three. A book's
  identifier is now derived from its title, so the same book exports as the
  same publication however many times you export it, and a reader updates
  the copy it already has. Rename the book and it becomes a new one, which
  is what a new name ought to mean. md's three apps derive it identically,
  so the same book exported from the phone and from the Mac is one
  publication rather than two. Nothing else about the file's metadata
  changed: the export still carries no author and no cover.

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
