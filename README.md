# md

[![build](https://github.com/nettrash/md/actions/workflows/ios.yml/badge.svg)](https://github.com/nettrash/md/actions/workflows/ios.yml)

The simplest Markdown editor for iPhone and iPad. Write Markdown on the
left, see it rendered on the right — or flip between **Edit** and
**Preview** on a phone. Built in SwiftUI on top of the system document
architecture, with a hand-written Markdown renderer. **No third-party
dependencies, no accounts, no servers** — your files live wherever you
keep them (on device, in Files, or in iCloud Drive).

> A native **macOS** version is planned separately. The app previously
> shipped its Mac build via Mac Catalyst, but Catalyst's `DocumentGroup`
> isn't a real `NSDocument` app, so its folder display, rename and
> New-file handling are unfixably unreliable — so Catalyst is disabled
> until a proper native Mac target is built.

## Features

- **Document-based.** Open, edit and save `.md` / `.markdown` files in
  place through the system document browser — File ▸ New / Open / autosave,
  plus an in-app **Rename** (since `DocumentGroup` offers no in-editor
  rename on iOS). Plain-text files open too and keep their extension.
- **Live preview.** A built-in renderer covers the everyday Markdown you
  actually write:
  - Headings (`#`–`######`)
  - **Bold**, *italic*, `inline code`, [links](https://nettrash.me) and
    ~~strikethrough~~ (via Apple's own inline Markdown engine)
  - Bullet, numbered and **task lists** (`- [ ]` / `- [x]`), with nesting
  - Fenced code blocks (```` ``` ```` and `~~~`), with horizontal scroll
  - Block quotes (including nested)
  - GitHub-style tables, with column alignment
  - Thematic breaks (`---`)
- **Three layouts.** *Edit*, *Preview*, and — on iPad, where there's
  room — a side-by-side *Split* that re-renders as you type. The chosen
  layout is remembered.
- **Typewriter feel.** Warm paper background (light "fresh paper" / dark
  "carbon paper") and the American Typewriter face throughout, with
  Courier New for code — a native iOS 26 Liquid Glass toolbar on top.
- **Editing you'd expect.** A real Undo / Redo stack in the toolbar,
  continuous autosave through the document architecture, and Markdown
  punctuation left literal (no smart-quote / dash surprises).
- **Print & share.** Print or share the *rendered* document as a themed
  PDF, or share the raw Markdown source.
- **Dynamic Type, light/dark, text selection** throughout.

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

MIT — see [LICENSE](LICENSE). © 2026 nettrash (Ivan Alekseev).
