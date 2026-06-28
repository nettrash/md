# md

[![build](https://github.com/nettrash/md/actions/workflows/ios.yml/badge.svg)](https://github.com/nettrash/md/actions/workflows/ios.yml)

The simplest Markdown editor for iPhone, iPad and Mac. Write Markdown on
the left, see it rendered on the right — or flip between **Edit** and
**Preview** on a phone. Built in SwiftUI on top of the system document
architecture, with a hand-written Markdown renderer. **No third-party
dependencies, no accounts, no servers** — your files live wherever you
keep them (on device, in Files, or in iCloud Drive).

## Features

- **Document-based.** Open, edit and save `.md` / `.markdown` files in
  place through the system document browser — the same File ▸ New /
  Open / autosave / rename you'd expect, on every platform. Plain-text
  files open too and keep their extension.
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
- **Three layouts.** *Edit*, *Preview*, and — on iPad and Mac, where
  there's room — a side-by-side *Split* that re-renders as you type. The
  chosen layout is remembered.
- **Dynamic Type, light/dark, text selection** throughout.

## Platforms

- iOS / iPadOS **26+**
- macOS **14+** via **Mac Catalyst**

## Build

Pure Apple system frameworks — nothing to resolve, just open and build.

```bash
# Run the unit tests on a simulator
xcodebuild test  -project md.xcodeproj -scheme md \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO

# Build for a device
xcodebuild build -project md.xcodeproj -scheme md \
  -destination 'generic/platform=iOS'

# Build the Mac (Catalyst) app
xcodebuild build -project md.xcodeproj -scheme md \
  -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO
```

The build number (`CFBundleVersion`) auto-increments on every build via a
scheme post-action running `agvtool bump`.

## License

MIT — see [LICENSE](LICENSE). © 2026 nettrash (Ivan Alekseev).
