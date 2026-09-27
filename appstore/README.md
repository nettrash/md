# App Store listing copy (iPhone / iPad)

The text that goes into App Store Connect for **md** on iOS and iPadOS,
kept next to the code it describes. One file per field, plain text, paste
as-is. (The Mac app keeps its own copy in the `md.macOS` repo — the two
listings are written separately, because the apps differ.)

| File | App Store Connect field | Limit | Current |
| --- | --- | --- | --- |
| `promotional-text.txt` | Promotional Text | 170 | 158 |
| `description.txt` | Description | 4000 | 3987 |
| `keywords.txt` | Keywords | 100 | 99 |
| `whats-new.txt` | What's New in This Version | 4000 | 3440 |
| `review-notes.txt` | App Review Information ▸ Notes | 4000 | 3995 |

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
exercises every new 1.5 feature in about three minutes.

## Screenshots

`screenshots/iphone-6.9/` (1320 × 2868, the iPhone 6.9" slot) and
`screenshots/ipad-13/` (2064 × 2752, the iPad 13" slot), numbered in upload
order; the first three are what the App Store shows before a scroll. Taken
for 1.5 on iOS 27.0 simulators (iPhone 17 Pro Max, iPad Pro 13-inch M5) with
the status bar pinned to 9:41, US English, light appearance, and nothing but
the built-in examples plus one typed document. RGB PNG, no alpha — App Store
Connect refuses an alpha channel.

They are made, not staged by hand: the DEBUG launch harness
(`md/LaunchDiagnostics.swift`, `-mdScript`) opens each example through the
production path, jumps with Contents, types the list through the real text
view (so the capitals and the continued markers are md's own), and waits on
a gate file while `simctl io screenshot` takes the picture. Two things to
keep in mind next time: iPadOS 26's windowing refuses programmatic rotation,
so the iPad set is portrait; and a Contents jump in Split focuses the editor,
so the script's `blur` step puts the keyboard away before a shot that should
not show one.
