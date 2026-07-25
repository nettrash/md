# Privacy Policy

**Effective date:** 28 June 2026
**Applies to:** md — the iOS / iPadOS Markdown editor published by
nettrash. This policy is versioned alongside the
app's source code; the most recent commit on `main` is authoritative.

## TL;DR

md **does not collect, transmit, sell, or share any data.** It contains
no analytics, no advertising SDKs, no third-party trackers, and no
servers operated by us. The documents you open and edit stay where you
put them — on your device, in Files, or in your own iCloud Drive.

If that already answers your question, you don't need to read the rest.

## What we collect

**Nothing.** md has no account to create, no email to register, and no
telemetry. It contacts no servers of ours — there are none. The one time
the app touches the network at all is when a document you opened points at
an image by remote URL, and the renderer fetches that image so it can be
shown, printed and exported (see **Permissions** below).

## Your documents

md is a document editor. The files you open, create and save are handled
entirely by Apple's system document architecture and are stored wherever
you choose — locally, in the Files app, or in iCloud Drive. We never see
them. If you store a document in iCloud Drive, it syncs through *your*
Apple account under Apple's privacy terms, not ours.

The app stores two small settings on-device, through the standard system
preferences store: your last-used Edit / Split / Preview layout, and — if
you use writer mode — a security-scoped bookmark to the book folder you
chose, so the book reopens without asking you to find it again. A
security-scoped bookmark is simply how a sandboxed app is permitted to
reopen a folder you picked; it points at a place on your own device and
never leaves it. Closing the book discards it. Neither setting leaves your
device, and neither contains personal information.

## Permissions

md requests no special permissions — no camera, microphone, contacts,
location, or photo-library access, and no tracking prompt. File access is
mediated by the system document picker / browser: you choose the documents
the app may open, and the one folder it may use as a book.

The app does use the network for one thing, described above: if a document
you open references an image by remote URL (`![alt](https://…)`), the
renderer fetches that image so it can be shown, printed and exported. That
request goes straight to the host **your own document names**, which sees
your IP address exactly as it would if you opened the link in a browser. It
happens only for documents that contain such a link.

Everything else runs on your device: the Markdown renderer, and the math
and diagram engines (KaTeX, Mermaid, Graphviz, PlantUML) are bundled inside
the app and work offline.

## Children's privacy

Because md collects no data at all, it collects no data from children.

## Changes to this policy

Any change is committed to this file in the app's public source
repository, so the history is auditable.

## Contact

Questions: <nettrash@nettrash.me>.
