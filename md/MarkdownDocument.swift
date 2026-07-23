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
    static var readableContentTypes: [UTType] { [.markdown, .plainText, .plantUML] }
    static var writableContentTypes: [UTType] { [.markdown, .plainText, .plantUML] }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
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
