# Writer Tools

Beyond formatting, md carries a few tools for longer work: in-document
links, private notes, and page breaks. Jump straight to
[Private notes](#private-notes) or [Page breaks](#page-breaks) below.

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
ideal for title pages, chapters, and handouts.

[Back to the top](#writer-tools)
