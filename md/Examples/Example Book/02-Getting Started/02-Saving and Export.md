# Saving and Export

Your work is a plain `.md` file — readable anywhere, owned by you, and
stored where you chose to keep it. md saves your changes as you write, so
there is no ritual to remember.

## Sharing as PDF

When a document is ready for other eyes, export it as a **PDF** from the
share menu. The PDF matches the Preview: formatting, tables, code,
images, math, and diagrams all carry over.

Choose the page size it should come out at — A4, A5, US Letter or Legal,
or a paperback trim size like 6 × 9″ — and md remembers the choice for
next time. A whole book compiles to the same size, so it can be made at
the size it will really be printed at, rather than at one no print
service would accept.

> A `\newpage` line in the source ends the page right there in the PDF —
> useful for title pages and chapter starts.

## Sharing as HTML

From the same menu, export it as **HTML** instead: one self-contained
file that opens in any browser with nothing beside it and nothing to
fetch. The diagrams travel as drawings and the formulas as real text, so
a reader can select a formula and copy it out.

## Sharing as EPUB

From the same menu, export it as an **EPUB** — the e-book format Books
and other e-readers open. A single document becomes an EPUB of its own,
not only a whole book: its own headings become the table of contents a
reader navigates by, so every section is a place to jump to, and its
math and diagrams travel as the pictures a reader sees. Export the same
document again and it stays the same publication, so a reader's copy is
updated in place rather than joined by a second one.

## Sharing as LaTeX

From the same menu again, export it as **LaTeX** — a `.tex` file. This is
the one export where a formula stays a formula: a PDF and an HTML page
both hand the reader finished typesetting, while a `.tex` file gives back
the `$…$` you wrote, ready to paste into a paper and go on editing. The
rest comes with it — headings, lists, tables, quotes, code and footnotes
all become their LaTeX equivalents — and a whole book exports as a `book`
with its chapters and articles in place. A diagram is the one thing LaTeX
cannot draw, so its source travels in a `verbatim` block for you to
decide what to do with.

## Sharing a diagram as SVG

A diagram doesn't have to travel inside a page. Pick one from the **Export
Diagram as SVG…** menu and md saves that drawing on its own as a standalone
`.svg`: a real vector file that opens in any browser or vector editor and
stays crisp at any size. Only the three drawing engines — **Mermaid**,
**Graphviz** and **PlantUML** — can be exported this way, since those are
what render to vector; math is typeset as text rather than drawn, so it has
no vector to save and isn't offered.

## TextBundle and TextPack

A **TextBundle** (`.textbundle`) — and its zipped form, a **TextPack**
(`.textpack`) — is the Markdown-with-images container Ulysses, iA Writer and
Bear write. md opens one and loads its text to edit, and exports the current
document as one: an image you referenced by a plain relative name, sitting
beside the file, is gathered into the bundle's `assets/` folder and its link
rewritten to match, while an image md can't find — or one from the web — is
left exactly as you wrote it, so nothing you typed is dropped. For now the
round-trip is the text: an opened bundle's own `assets/` images aren't shown
in the preview yet, so those refs read as broken images while you edit.

## Staying portable

Because Markdown is plain text, nothing locks you in:

1. open the file in any other editor,
2. keep it in version control,
3. or paste it into anything that speaks Markdown.

The source you write is the document you keep.
