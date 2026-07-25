# Writer Tools

Beyond formatting, md carries a few tools for longer work: in-document
links, private notes, page breaks, front matter, and footnotes. Jump
straight to [Private notes](#private-notes), [Page breaks](#page-breaks),
[Front matter](#front-matter) or [Footnotes](#footnotes) below.

## Navigating with Contents

Every heading in a document feeds the **Contents** menu, and each one is
also a link target: `[Page breaks](#page-breaks)` links to the heading of
that name — lowercase, with spaces turned into hyphens.

## Private notes

A comment beginning with `note:` is a private author note. It appears in
the **Notes** menu while you write, but never in Preview, PDF, or print.

<!-- note: This note is invisible in Preview — open the Notes menu to see it. Readers of an exported PDF will never know it was here. -->

There is a real note hidden just above this line. Ordinary HTML comments
are simply dropped.

## Page breaks

Put `\newpage` (or `\pagebreak`) on a line of its own to end the page in
PDF export and print. In Preview it shows as a dashed rule:

\newpage

Everything after the break starts a fresh page in the exported document —
ideal for title pages, chapters, and handouts. An exported HTML page is
read on a screen rather than on paper, so there it shows the same dashed
rule Preview does.

## Front matter

Files written for a blog, a site generator, or a notes app often begin
with a block of metadata — the title, the author, a date — fenced off
above the text. md reads both of the usual spellings, YAML between `---`
lines and TOML between `+++` lines:

```markdown
---
title: My Post
author: Ivan Alekseev
date: 2026-07-24
---

# Hello
```

The block is kept with the file and hidden from the page, so a document
like that one starts at its heading in Preview, PDF, and print instead of
opening with a stray rule and a paragraph of metadata.

It counts as front matter only at the very top of the file and only when
it is closed again (`---` or `...` for YAML, `+++` for TOML), and only
when it really holds fields: with no `key: value` line inside it at all,
the block is not metadata, and every word of it stays on the page — read
as the rule and text it looks like. Anywhere else, `---` is the ordinary
horizontal rule it has always been.

## Footnotes

An aside that would break the flow of a sentence can go to the foot of
the page instead. Mark the spot with `[^id]`, and write the note itself
on a line of its own as `[^id]: the note`.

The original Markdown had no footnotes[^gfm], so md follows the spelling
GitHub and Pandoc settled on — and a note may run as long as it needs
to[^wrap].

[^wrap]: A note can wrap over as many lines as it likes: carry on typing
on the next line and md joins it up, the way a wrapped list item behaves.

[^gfm]: `[^id]` comes from GitHub-Flavored Markdown and from Pandoc,
which spell it the same way.

[^uncited]: This note is never cited anywhere in the document, and is
printed all the same — last, and without an arrow, since there is nowhere
to go back to.

Nothing appears where those notes are written. They are collected under a
rule at the foot of the rendered page instead, so read the end of this
document in Preview to see them. They are numbered in the order you meet
the references while reading rather than the order they were written — the
notes above are deliberately the wrong way round, and they still come out
1 and 2 as you met them. Each number links down to its note, and each note
you cited ends in an arrow back to where you first cited it. Cite that
same note again[^wrap] and the second reference carries the same number
and links down to the same note; the note keeps its single arrow, pointing
at the first place you cited it.

A reference with no note behind it — [^missing] — stays exactly the text
you typed rather than becoming a link to nowhere. And a note you never
cite, like the third one at the foot of this page, is printed all the
same rather than quietly dropped.

[Back to the top](#writer-tools)
