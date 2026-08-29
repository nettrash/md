# App Store listing copy (iPhone / iPad)

The text that goes into App Store Connect for **md** on iOS and iPadOS,
kept next to the code it describes. One file per field, plain text, paste
as-is. (The Mac app keeps its own copy in the `md.macOS` repo — the two
listings are written separately, because the apps differ.)

| File | App Store Connect field | Limit | Current |
| --- | --- | --- | --- |
| `promotional-text.txt` | Promotional Text | 170 | 167 |
| `description.txt` | Description | 4000 | 3939 |
| `keywords.txt` | Keywords | 100 | 99 |
| `whats-new.txt` | What's New in This Version | 4000 | 2520 |
| `review-notes.txt` | App Review Information ▸ Notes | 4000 | 3854 |

Promotional Text can be changed at any time without submitting a new build;
the Description, Keywords and What's New ship with a version.

## No angle brackets

App Store Connect rejects `<` and `>` in these fields — it reads them as
markup and answers *"This field contains one or more invalid characters."*
So the private-notes bullet describes the syntax in words ("an HTML comment
… whose text begins with note:") instead of showing the comment itself.
Keep it that way, and never paste Markdown or HTML samples into store copy.

## Ground rules these texts follow

Every claim was checked against the shipping build — App Review's
"Accurate Metadata" guideline is what a listing gets rejected on, and the
listing must describe *this* version, not the roadmap.

- No references to other platforms, no competitor comparisons, no pricing,
  promotions or "free", no unverifiable superlatives, no rating requests.
- Third-party names (Markdown, LaTeX, KaTeX, Mermaid, Graphviz, PlantUML,
  EPUB) are used descriptively; Apple's (iPhone, iPad, Files, iCloud Drive)
  without implying endorsement.
- Privacy claims match the code and the linked privacy policy: nothing is
  collected, and the only network use is fetching an image a document
  itself points at. The Privacy Nutrition Label answer that matches this
  build is **Data Not Collected**, with no tracking.

## Wording that must not drift back

- **Not** "no third-party dependencies" — the app bundles KaTeX, Mermaid,
  Graphviz and PlantUML. Only the Swift side is package-free.
- Private notes are hidden from the preview / PDF / print **only when the
  comment is on its own line**; written inline, it renders.
- Pagination is line-aware for *text*. A diagram taller than the page can
  still be split, so the copy does not promise otherwise.
- **Split is iPad-only** (it needs a regular width). The copy never
  promises it on iPhone.

## Keywords

Comma-separated, no spaces (spaces count against the 100). Singular forms
only — the App Store matches plurals and combinations by itself. Terms
already in the app name or subtitle are wasted here, so drop any that
appear there. Never include another app's name or a trademark (a 2.3.7
rejection).

## Review notes

`review-notes.txt` answers the seven things App Review asks for on a
Guideline 2.1 "information needed" hold: purpose, how to reach every
feature without an account, what the one network call is for, and why the
bundled JavaScript engines are not downloaded code (2.5.2). Section 2 is
also the script for a demo recording, if one is ever requested: it
exercises every new 1.2 feature in about three minutes.
