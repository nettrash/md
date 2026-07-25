//
//  MarkdownDocument.swift
//  md
//
//  Created by nettrash on 28/06/2026.
//
//  The `FileDocument` that backs every editor window. A Markdown file is
//  just UTF-8 text, so the model is a single `String`. Reading and
//  writing therefore reduce to "decode the bytes" / "encode the string"
//  — no wrappers, no temp files, no security-scoped bookmarks; the
//  document architecture owns the file coordination on every platform.
//

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// The Markdown content type. `net.daringfireball.markdown` is the
    /// canonical identifier declared by the system on Apple platforms
    /// (and re-declared as an *imported* type in our Info.plist, since
    /// the type is owned by Daring Fireball, not us). It conforms to
    /// `public.plain-text`, so files we save are ordinary text.
    static let markdown = UTType(importedAs: "net.daringfireball.markdown")

    /// PlantUML source (`.puml`). The format is owned by the PlantUML
    /// project and the system declares no identifier for it, so we import
    /// one in Info.plist that conforms to `public.plain-text` — a `.puml`
    /// file is ordinary UTF-8 text and opens in the editor just like a
    /// `.md` file, with no special handling.
    static let plantUML = UTType(importedAs: "net.sourceforge.plantuml.puml")

    /// Graphviz DOT source (`.gv`). Like PlantUML it is ordinary UTF-8 text
    /// with no system-declared identifier, so we import one conforming to
    /// `public.plain-text`.
    ///
    /// Only `.gv` is claimed, deliberately — DOT's other extension, `.dot`,
    /// is already system-declared as `com.microsoft.word.dot` (a Word
    /// template, which does *not* conform to plain text). Claiming it too
    /// would leave the extension ambiguous and could offer md as a handler
    /// for real Word templates, so a `.dot` file has to be renamed `.gv` to
    /// open. Fenced ```dot blocks inside a Markdown document are unaffected.
    static let graphvizDOT = UTType(importedAs: "org.graphviz.dot")

    /// TextBundle (`.textbundle`) — a directory *package* carrying `text.md`,
    /// `info.json` and an `assets/` folder. The format is owned by the
    /// textbundle.org spec, not us, so we import its identifier; it conforms
    /// to `com.apple.package`, which is what makes the system hand us a
    /// directory `FileWrapper` (rather than trying to read the folder as a
    /// flat file) when one is opened.
    static let textBundle = UTType(importedAs: "org.textbundle.package")

    /// TextPack (`.textpack`) — a zipped TextBundle. It conforms to
    /// `public.zip-archive`, so it arrives as ordinary file bytes that
    /// `MarkdownDocument` unzips in memory (see `TextBundle.textFromPack`).
    static let textPack = UTType(importedAs: "org.textbundle.pack")
}

struct MarkdownDocument: FileDocument {
    /// The raw Markdown source. This is the single source of truth the
    /// editor binds to and the previewer renders.
    var text: String

    /// The encoding the file was read in, so a save round-trips in the
    /// file's original encoding instead of silently rewriting it as UTF-8.
    private var encoding: String.Encoding

    init(text: String = "") {
        self.text = text
        self.encoding = .utf8
    }

    /// Markdown is the document type we own, but we also read and write
    /// plain text so the app can open and round-trip a `.txt` the user
    /// drops on it without silently rewriting its extension.
    ///
    /// TextBundle / TextPack are readable but deliberately **not** writable:
    /// they can carry an `assets/` folder of images, and this document is only
    /// the text — saving one back would drop those images, which the house
    /// rule forbids. Opening a bundle imports its `text.md` for reading /
    /// editing; producing one is the explicit "Export as TextBundle…" action
    /// (see `DocumentExport`), which preserves the assets it can find.
    static var readableContentTypes: [UTType] {
        [.markdown, .plainText, .plantUML, .graphvizDOT, .textBundle, .textPack]
    }
    static var writableContentTypes: [UTType] { [.markdown, .plainText, .plantUML, .graphvizDOT] }

    init(configuration: ReadConfiguration) throws {
        // A `.textbundle` is a directory package: read its `text.md` out of the
        // directory `FileWrapper` (the roadmap's note — `configuration.file` IS
        // a `FileWrapper`; only its `regularFileContents` is nil for a package).
        if configuration.file.isDirectory {
            guard let (decoded, enc) = TextBundle.textFromBundle(configuration.file) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            text = decoded
            encoding = enc
            return
        }

        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        // A `.textpack` is a zipped bundle — unzip in memory and read its
        // `text.md`. A pack we can't unzip is a corrupt file, not text: falling
        // through to `decode` would (via the last-resort Latin-1 trial that
        // maps any byte) turn the zip's bytes into visible mojibake.
        if configuration.contentType.conforms(to: .textPack) {
            guard let (decoded, enc) = TextBundle.textFromPack(data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            text = decoded
            encoding = enc
            return
        }

        // Decode strictly (see `decode`). Using the lossy
        // `String(decoding:as:UTF8.self)` would replace every non-UTF-8
        // byte with U+FFFD and then bake that corruption into the file on
        // the next autosave — silent data loss for a legacy-encoded
        // (Cyrillic, Latin-1, UTF-16) text file opened in place.
        guard let (decoded, enc) = Self.decode(data) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        text = decoded
        encoding = enc
    }

    /// Try to decode `data` as text, returning the matched encoding.
    /// UTF-16 is only considered behind an explicit BOM — without one,
    /// `String(data:encoding:.utf16)` happily pairs up the bytes of many
    /// legacy single-byte files (BOM-less CP1251 prose, say) into CJK
    /// mojibake, and the next save would bake that corruption in. The
    /// BOM'd decode strips the BOM and `data(using: .utf16)` writes one
    /// back, so such files round-trip. The single-byte trials run most- to
    /// least-specific; `.isoLatin1` maps every byte, so it round-trips
    /// arbitrary bytes losslessly as a last resort. Internal for the tests.
    static func decode(_ data: Data) -> (String, String.Encoding)? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return (text, .utf16)
        }
        for enc: String.Encoding in [.utf8, .windowsCP1251, .isoLatin1] {
            if let s = String(data: data, encoding: enc) { return (s, enc) }
        }
        return nil
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Re-encode in the file's original encoding; if the edited text no
        // longer fits it (e.g. an emoji typed into a Windows-1251 file),
        // upgrade to UTF-8 so the new characters survive rather than failing.
        let data = text.data(using: encoding) ?? Data(text.utf8)
        return FileWrapper(regularFileWithContents: data)
    }
}
