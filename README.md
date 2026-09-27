# md

[![build](https://github.com/nettrash/md/actions/workflows/ios.yml/badge.svg)](https://github.com/nettrash/md/actions/workflows/ios.yml)

The simplest Markdown editor for iPhone and iPad. Write Markdown on the
left, see it rendered on the right — or flip between **Edit** and
**Preview** on a phone. Built in SwiftUI on top of the system document
architecture, with a hand-written Markdown renderer. **No third-party Swift
packages, no accounts, no servers** — your files live wherever you keep
them (on device, in Files, or in iCloud Drive). The only vendored code is
the offline math / diagram engines under `md/rich/` (KaTeX with the mhchem
chemistry extension, Mermaid, Graphviz, PlantUML, and highlight.js for code).

> A native **macOS** version is planned separately. The app previously
> shipped its Mac build via Mac Catalyst, but Catalyst's `DocumentGroup`
> isn't a real `NSDocument` app, so its folder display, rename and
> New-file handling are unfixably unreliable — so Catalyst is disabled
> until a proper native Mac target is built.

## Features

- **Document-based.** Open, edit and save `.md` / `.markdown` files in
  place through the system document browser — File ▸ New / Open / autosave,
  plus an in-app **Rename** (since `DocumentGroup` offers no in-editor
  rename on iOS). The other Markdown spellings — `.mdown`, `.markdn`,
  `.mdtext`, `.mdtxt`, `.mkd`, `.mkdn`, `.mdwn` and `.mkdown` — open and
  save the same way and keep their extension. Every spelling but `.md`,
  `.markdown` included, is registered under md's own document type, so it
  is associated with md on iOS 26 (which itself knows Markdown only as
  `.md`) as well as on iOS 27. Plain-text files (`.txt`,
  `.text`) open too and keep their extension. A
  **TextBundle** (`.textbundle`) or **TextPack** (`.textpack`) — the
  Markdown-with-images container Ulysses, iA Writer and Bear write — opens
  too, imported as its text for editing (the bundle's own `assets/` images
  aren't shown in the preview).
- **Live preview.** A built-in renderer covers the everyday Markdown you
  actually write:
  - Headings (`#`–`######`)
  - **Bold**, *italic*, `inline code`, [links](https://nettrash.me) and
    ~~strikethrough~~ (via Apple's own inline Markdown engine)
  - Bullet, numbered and **task lists** (`- [ ]` / `- [x]`), with nesting
  - Fenced code blocks (```` ``` ```` and `~~~`), with horizontal scroll —
    **syntax-highlighted** in md's own quiet paper palette when the fence
    names a language (`swift`, `js`, …); a bare fence stays plain
  - Block quotes (including nested)
  - GitHub-style tables, with column alignment
  - **CSV / TSV blocks** (` ```csv `, ` ```tsv `) — data pasted straight
    out of a spreadsheet drawn as a table, quoted fields and all, with
    all-number columns lined up on the right; the source stays the data,
    so it can be replaced wholesale when the numbers change
  - Thematic breaks (`---`)
  - YAML / TOML **front matter** (`---` … `---` or `+++` … `+++`) at the
    very top of a file — recognised as metadata and hidden from the page,
    print and PDF, instead of showing up as a rule and stray text
  - **Footnotes** (`[^id]` in the text, `[^id]: the note` on a line of its
    own) — gathered under a rule at the foot of the rendered page and
    numbered in the order a reader meets them, each reference linking down
    to its note and each cited note linking back
- **Math and diagrams.** TeX/LaTeX math (`$…$`, `$$…$$` and ` ```math `) —
  with **chemistry** notation (`\ce{…}` / `\pu{…}`) via the bundled mhchem
  extension — plus **Mermaid** (` ```mermaid `), **Graphviz** (` ```dot `, ` ```graphviz `
  or ` ```gv `, and every layout program — `neato`, `circo`, `fdp`, `sfdp`,
  `twopi`, `osage`, `patchwork` — usable as the block language) and
  **PlantUML** (` ```plantuml `), all drawn on-device by bundled engines and
  carried through to print and PDF. A raw PlantUML file (`.puml`,
  `.plantuml`, `.iuml` or `.pu`) or Graphviz file (`.gv`) opens and renders
  as the diagram it describes, source still editable.
- **Plots** (` ```plot `). A block of directives and formulas drawn as a
  chart — `x: -10..10`, `y: -2..2` (or `y: auto`), `title`, `xlabel`,
  `ylabel`, `legend`, `grid`, `axes`, `width`, `height`, `samples`, then a
  line per curve: `sin(x) * exp(-abs(x)/5)`, `envelope = exp(-abs(x)/5)`, a
  parametric `(cos(t), sin(t)) for t in 0..2*pi`, or measured data as
  `points: 0,0 1,2 2,1`. The expression language is the usual one —
  arithmetic, comparisons, `pi`, `e` and the thirty-odd functions from `sin`
  to `hypot` — with `^` binding to the right and every value a real number.
  There is no engine and no asset behind it: the chart is an `<svg>` in the
  markup before any script runs, so it costs nothing to load and comes out
  the same in the preview, print, PDF, the self-contained `.html`, the EPUB
  and a saved `.svg`.
- **Three layouts.** *Edit*, *Preview*, and — on iPad, where there's
  room — a side-by-side *Split* that re-renders as you type. The chosen
  layout is remembered per file, so a document opens back in the layout you
  left it in; two windows side by side on an iPad still keep their own.
- **Typewriter feel.** Warm paper background (light "fresh paper" / dark
  "carbon paper") and the American Typewriter face throughout, with
  Courier New for code — a native iOS 26 Liquid Glass toolbar on top.
- **Editing you'd expect.** A real Undo / Redo stack in the toolbar,
  continuous autosave through the document architecture, and Markdown
  punctuation left literal (no smart-quote / dash surprises).
- **Find and Replace.** The system find panel over the editor — **Find** in
  the toolbar, or ⌘F on a hardware keyboard — with a Replace field and
  Replace All, on iPhone as well as iPad. Matching is the rule every md app
  shares: plain text, case-insensitive, wrapping round the end of the document;
  no regular expressions. Replace All is one Undo step, and a replaced document
  is a dirty document — autosave sees it like any other edit.
- **Keyboard shortcuts.** On an iPad with a keyboard, the Mac's and Windows'
  chords: ⌘1 / ⌘2 / ⌘3 for Edit / Split / Preview (only the
  layouts the window is wide enough to offer), ⌘F Find, ⌘P Print,
  ⇧⌘B Show Book, and ⌃⌘↑ / ⌃⌘↓ to step
  through a book's articles in reading order. ⌘Z / ⌘X / ⌘C /
  ⌘V / ⌘A stay the text view's own, as they should. Shift-Return
  still inserts a plain line break.
- **Typing.** Return carries on what you were writing: a bullet, numbered
  or task item continues with the next marker (`- `, `3. `, `- [ ] `), a
  quote with its `> `, a table row with a fresh `|  |  |` row — and Return
  on an *empty* item ends the list (or steps a nested one out a level)
  instead of leaving a stray marker. The first letter of every line and of
  every sentence is capitalized as you type, Markdown-aware: never inside
  a code fence, a code span, math, a table cell, a URL, front matter or a
  comment, and not after an abbreviation, an initial or an ellipsis
  (`e.g. this`, `J. R. Tolkien`, `wait… what`). md does this itself — the
  keyboard's own auto-capitalization is off in the editor — so it works
  the same in every list, quote and heading, and the same as in the macOS,
  Android and Windows editors. Didn't want the capital (`md`, `iOS`, `npm`
  at the start of a sentence)? Delete the capital md wrote and type the
  letter again; it stays lowercase. A capital is also its own Undo step,
  so Undo right after one restores the lowercase letter.
  On a hardware keyboard, Shift-Return inserts a plain line break. Both
  behaviours are toggles in the toolbar's **Typing** menu — *Continue Lists
  and Tables* and *Capitalize Sentences* — and take effect at once.
- **Print & share.** Print or share the *rendered* document as a themed
  PDF — at A4, A5, US Letter or Legal, or a print-on-demand trim size
  (6 × 9″, 5 × 8″, 5.5 × 8.5″), the choice remembered and applied to the
  book compile too — export it as one self-contained `.html` file that
  opens anywhere with nothing beside it (diagrams as drawings, formulas as
  selectable text), export it as an **EPUB** e-book with the document's
  own headings as its table of contents, export it as LaTeX `.tex` source
  (formulas as the `$…$` you typed rather than a picture of them, ready to
  paste into a paper), export a single **figure** (Mermaid, Graphviz,
  PlantUML or a plot — math is HTML text, not a drawing, so it isn't
  offered) as a standalone `.svg` vector file, export the document as a
  **TextBundle** with any local images it references gathered into the
  bundle's `assets/`, or share the raw Markdown source.
- **Dynamic Type, light/dark, text selection** throughout.
- **A preview that comes back.** If WebKit's content process is taken away
  under the preview — memory pressure on an iPad, a runaway diagram
  layout — the pane reloads itself instead of going blank. If that
  fails twice in a row it stops retrying and says so in one line; the next
  edit brings it back.

## Platforms

- iOS / iPadOS **26+**
- macOS — a native version is planned (Mac Catalyst is intentionally disabled; see above)

## Build

Pure Apple system frameworks — nothing to resolve, just open and build.

```bash
# Run the unit tests on a simulator
xcodebuild test  -project md.xcodeproj -scheme md \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO

# Build for a device
xcodebuild build -project md.xcodeproj -scheme md \
  -destination 'generic/platform=iOS'
```

The build number (`CFBundleVersion`) auto-increments on every build via a
scheme post-action running `agvtool bump`.

## License

MIT — see [LICENSE](LICENSE). © 2026 nettrash.
