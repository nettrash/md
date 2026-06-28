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
    static var readableContentTypes: [UTType] { [.markdown, .plainText] }
    static var writableContentTypes: [UTType] { [.markdown, .plainText] }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Decode strictly. Using the lossy `String(decoding:as:UTF8.self)`
        // would replace every non-UTF-8 byte with U+FFFD and then bake that
        // corruption into the file on the next autosave — silent data loss
        // for a legacy-encoded (Cyrillic, Latin-1, UTF-16) text file opened
        // in place. Instead try UTF-8 first (the Markdown convention), then
        // a few common encodings, and remember which one matched.
        guard let (decoded, enc) = Self.decode(data) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        text = decoded
        encoding = enc
    }

    /// Try to decode `data` as text, returning the matched encoding. The
    /// list is ordered most- to least-specific; `.isoLatin1` maps every
    /// byte, so it round-trips arbitrary bytes losslessly as a last resort.
    private static func decode(_ data: Data) -> (String, String.Encoding)? {
        for enc: String.Encoding in [.utf8, .utf16, .windowsCP1251, .isoLatin1] {
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
