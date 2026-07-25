//
//  TextBundle.swift
//  md
//
//  Created by nettrash on 24/07/2026.
//
//  TextBundle (`.textbundle`, a directory package) and TextPack
//  (`.textpack`, a zipped TextBundle) — the Markdown-with-assets container
//  Ulysses, iA Writer and Bear write. A bundle is `text.md` (or
//  `text.markdown`), an `info.json` declaring the type, and an `assets/`
//  folder of images.
//
//  Scope, stated honestly so the macOS and Android ports match it: md's
//  document model is a single `String` and the preview has never shown a
//  local image, so the round-trip here is *text*, not pictures.
//
//   • Import loads a bundle's / pack's `text.md` as the editable document
//     (see `MarkdownDocument.init`). The `assets/` images are read but not
//     retained — the document is only the text — so a bundle carrying images
//     opens with its `![](assets/…)` refs showing as broken images in the
//     preview. That is the same honest failure a missing file already is, and
//     it still lets the author edit the prose. Wiring imported asset bytes
//     into the preview's scheme handler is the one thing md wholly lacks and
//     is deliberately *not* built here (it would have to thread asset storage
//     through the value-type document, the preview and all three platforms).
//
//   • Export writes the current document as a `.textbundle`, copying any
//     *findable* local images the Markdown references by relative path into
//     `assets/` and rewriting those refs. A ref that can't be found is left
//     exactly as the author wrote it — a broken ref stays a visible broken
//     ref, nothing vanishes silently.
//
//  The pure pieces (the zip reader, `info.json`, the ref rewrite, the bundle
//  assembly) carry no WebKit and no disk I/O, so they are unit-tested
//  directly; the picker plumbing lives in `DocumentExport`.
//

import Compression
import Foundation

// MARK: - ZIP reading (TextPack import)

/// A minimal ZIP reader: enough to pull the entries out of a `.textpack`.
///
/// It reads through the **central directory**, which is authoritative for
/// each entry's sizes and local-header offset even when the entry was written
/// with a streaming data descriptor (sizes zeroed in the local header) — the
/// reason a naive front-to-back local-header walk is unreliable. The two
/// storage methods a real TextPack uses are handled: STORED (0) and DEFLATE
/// (8, inflated via the system `Compression` framework, whose `ZLIB` codec is
/// the raw RFC 1951 stream a zip entry holds). Anything else, or a truncated
/// archive, yields nil rather than a guess. No I/O — `Data` in, entries out.
enum ZipReader {

    struct Entry: Equatable {
        let name: String
        let data: Data
    }

    /// Every file entry (directory entries — names ending in `/` — dropped),
    /// or nil if the bytes are not a zip this reader can parse.
    ///
    /// `shouldInflate` decides which entries are actually decompressed: an
    /// entry it rejects is still listed (by name, with empty data) but never
    /// allocated or inflated. Import only ever reads `text.md`, so restricting
    /// inflation to that one file means a hostile pack full of huge asset
    /// entries can't exhaust memory no matter how many it declares — only the
    /// text is ever materialised.
    static func entries(in archive: Data,
                        shouldInflate: (String) -> Bool = { _ in true }) -> [Entry]? {
        let bytes = [UInt8](archive)
        guard let eocd = locateEndRecord(bytes) else { return nil }

        var offset = eocd.centralOffset
        var results: [Entry] = []
        for _ in 0..<eocd.count {
            // Central-directory file header: 46-byte fixed part, then name /
            // extra / comment. Every multi-byte field is little-endian.
            guard offset >= 0, offset + 46 <= bytes.count,
                  u32(bytes, offset) == 0x0201_4B50 else { return nil }
            let method = u16(bytes, offset + 10)
            let compressedSize = Int(u32(bytes, offset + 20))
            let uncompressedSize = Int(u32(bytes, offset + 24))
            let nameLength = u16(bytes, offset + 28)
            let extraLength = u16(bytes, offset + 30)
            let commentLength = u16(bytes, offset + 32)
            let localOffset = Int(u32(bytes, offset + 42))
            let nameStart = offset + 46
            guard nameStart + nameLength <= bytes.count else { return nil }
            let name = String(decoding: bytes[nameStart..<nameStart + nameLength], as: UTF8.self)
            offset = nameStart + nameLength + extraLength + commentLength

            // A directory carries no payload — skip it (and don't chase a
            // local header that isn't there).
            if ScalarText.hasSuffix(name, "/") { continue }

            // An entry the caller doesn't want inflated is listed but never
            // read or allocated — this is what keeps a hostile pack of huge
            // assets from exhausting memory (see `entries`' `shouldInflate`).
            guard shouldInflate(name) else {
                results.append(Entry(name: name, data: Data()))
                continue
            }

            // The local header repeats its own name/extra lengths, which can
            // differ from the central copy, so the data offset is computed
            // from the local ones.
            guard localOffset >= 0, localOffset + 30 <= bytes.count,
                  u32(bytes, localOffset) == 0x0403_4B50 else { return nil }
            let localNameLength = u16(bytes, localOffset + 26)
            let localExtraLength = u16(bytes, localOffset + 28)
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard dataStart >= 0, dataStart + compressedSize <= bytes.count else { return nil }
            let payload = Array(bytes[dataStart..<dataStart + compressedSize])

            let content: Data
            switch method {
            case 0:
                content = Data(payload)
            case 8:
                guard let inflated = inflate(payload, expectedSize: uncompressedSize) else { return nil }
                content = inflated
            default:
                return nil
            }
            results.append(Entry(name: name, data: content))
        }
        return results
    }

    private struct EndRecord { let count: Int; let centralOffset: Int }

    /// The End Of Central Directory record: 22 bytes near the file's tail,
    /// possibly trailed by a comment up to 65535 bytes, so it is found by
    /// scanning backward for its signature.
    private static func locateEndRecord(_ bytes: [UInt8]) -> EndRecord? {
        guard bytes.count >= 22 else { return nil }
        let lowerBound = max(0, bytes.count - 22 - 0xFFFF)
        var i = bytes.count - 22
        while i >= lowerBound {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                return EndRecord(count: u16(bytes, i + 10), centralOffset: Int(u32(bytes, i + 16)))
            }
            i -= 1
        }
        return nil
    }

    /// The most a single archive entry may claim to inflate to. The central
    /// directory's `uncompressedSize` is an attacker-controlled u32 (up to
    /// ~4.3 GB), and we allocate a buffer of that size *before* decoding — so a
    /// hundred-byte crafted `.textpack` could otherwise force a multi-gigabyte
    /// allocation and crash the app just by being opened. A TextBundle is a
    /// hand-authored document, so 128 MB per entry is far past anything real
    /// (and `text.md` — the only entry we actually inflate; see `entries`) is
    /// text, which is smaller still).
    private static let maxEntrySize = 128 * 1024 * 1024

    /// Inflate a raw DEFLATE stream to its known uncompressed size. Fails if
    /// the codec writes anything other than exactly that many bytes (a
    /// truncated or corrupt entry), rather than returning a short buffer — and
    /// refuses, without allocating, an entry that claims to be larger than
    /// `maxEntrySize`, so a malicious size field cannot exhaust memory.
    private static func inflate(_ compressed: [UInt8], expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        guard expectedSize <= maxEntrySize else { return nil }
        guard !compressed.isEmpty else { return nil }
        var destination = [UInt8](repeating: 0, count: expectedSize)
        let written = destination.withUnsafeMutableBufferPointer { dst in
            compressed.withUnsafeBufferPointer { src in
                compression_decode_buffer(dst.baseAddress!, expectedSize,
                                          src.baseAddress!, compressed.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { return nil }
        return Data(destination)
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | (Int(b[i + 1]) << 8)
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
}

// MARK: - TextBundle / TextPack

enum TextBundle {

    /// The `info.json` every bundle we write carries. A fixed, canonical
    /// document (stable key order) so it is trivially testable: version 2 of
    /// the spec, the Daring Fireball Markdown type md owns, and non-transient
    /// (this is a file the user is keeping, not a scratch hand-off).
    static let infoJSON = """
    {
      "version": 2,
      "type": "net.daringfireball.markdown",
      "transient": false
    }
    """

    /// One image copied into a written bundle's `assets/`.
    struct Asset: Equatable {
        let name: String   // the file name inside `assets/`, e.g. "photo.png"
        let data: Data
    }

    // MARK: Import

    /// The `text.md` of a `.textbundle` directory wrapper, decoded with the
    /// same encoding detection a bare file gets (so a legacy-encoded bundle
    /// round-trips). Prefers `text.md`, then `text.markdown`, then any
    /// `text.*` — the spec names the file `text` with an extension matching
    /// the declared type. Nil when there is no text file to read.
    static func textFromBundle(_ wrapper: FileWrapper) -> (String, String.Encoding)? {
        guard let children = wrapper.fileWrappers else { return nil }
        let textFile = children["text.md"]
            ?? children["text.markdown"]
            ?? children.first(where: { ScalarText.hasPrefix($0.key, "text.") })?.value
        guard let data = textFile?.regularFileContents else { return nil }
        return MarkdownDocument.decode(data)
    }

    /// The `text.md` of a `.textpack` (a zipped bundle). The pack wraps a
    /// `.textbundle` folder, so the entry is nested under it — matched by its
    /// last path component. Nil when the bytes aren't a readable zip or carry
    /// no text file.
    static func textFromPack(_ archive: Data) -> (String, String.Encoding)? {
        // Inflate only the text file. Every other entry (the assets, which
        // import does not use) is listed but never decompressed, so a pack
        // that declares gigabytes of assets costs nothing to open.
        guard let entries = ZipReader.entries(in: archive, shouldInflate: {
            ScalarText.hasPrefix(lastComponent($0), "text.")
        }) else { return nil }
        let entry = entries.first(where: { lastComponent($0.name) == "text.md" })
            ?? entries.first(where: { lastComponent($0.name) == "text.markdown" })
            ?? entries.first(where: { ScalarText.hasPrefix(lastComponent($0.name), "text.") })
        guard let data = entry?.data, !data.isEmpty else { return nil }
        return MarkdownDocument.decode(data)
    }

    // MARK: Export

    /// Whether a Markdown image destination names a *local file by relative
    /// path* — the only kind we can copy into `assets/`. Remote URLs
    /// (anything with a scheme), inline `data:` images, absolute paths and
    /// bare fragments are left untouched. Scalar-exact throughout (the
    /// house rule): a scheme delimiter carrying a combining mark would fool
    /// grapheme matching, and this is a Swift/Kotlin divergence point.
    static func isLocalRelativeReference(_ url: String) -> Bool {
        guard !url.isEmpty else { return false }
        if ScalarText.contains(url, "://") { return false }   // http:, https:, file:, custom
        let lower = url.lowercased()                          // schemes are ASCII; lowering is exact
        if ScalarText.hasPrefix(lower, "data:") { return false }   // inline image bytes
        if ScalarText.hasPrefix(lower, "mailto:") { return false }
        if ScalarText.hasPrefix(url, "/") { return false }    // absolute path — not "next to" the source
        if ScalarText.hasPrefix(url, "#") { return false }    // in-document fragment
        return true
    }

    /// Rewrite the document for export into a bundle: every local image ref
    /// the `resolveAsset` closure can satisfy is copied into `assets/` and its
    /// ref rewritten to `assets/<name>`; refs it can't satisfy (a file that
    /// isn't there, a remote URL, an absolute path) are left exactly as
    /// written. Returns the rewritten text and the assets to write.
    ///
    /// The image syntax recognized is exactly what `MarkdownHTML.inline`
    /// renders as an `<img>` — `![alt](dest)` and `![alt](dest "title")` /
    /// `'title'`, with `dest` a run of non-space non-`)` characters — matched
    /// with the same UTF-16-based regex the renderer uses, so what gets an
    /// asset is precisely what would show as an image, and Kotlin's regex
    /// matches unit-for-unit. The one accepted imprecision: an image-looking
    /// string inside a code span is also matched — but only rewritten when a
    /// real file of that name sits beside the document, in which case the ref
    /// still resolves (now from `assets/`), so nothing the author meant is
    /// lost.
    static func exportRewriting(source: String,
                                resolveAsset: (String) -> Data?) -> (text: String, assets: [Asset]) {
        guard let regex = try? NSRegularExpression(
            pattern: #"!\[[^\]]*\]\(([^)\s]+)(?:\s+(?:"[^"]*"|'[^']*'))?\)"#) else {
            return (source, [])
        }
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))

        var assets: [Asset] = []
        var assetForPath: [String: String] = [:]   // source ref -> assigned asset file name
        var usedNames: Set<String> = []             // case-insensitive, for collision-free names
        var edits: [(range: NSRange, replacement: String)] = []

        for match in matches {
            let urlRange = match.range(at: 1)
            guard urlRange.location != NSNotFound else { continue }
            let url = ns.substring(with: urlRange)
            guard isLocalRelativeReference(url) else { continue }

            // The same ref written twice becomes one asset, both refs rewritten.
            if let existing = assetForPath[url] {
                edits.append((urlRange, "assets/\(existing)"))
                continue
            }
            // Unfindable → leave the author's ref exactly as it is.
            guard let data = resolveAsset(url) else { continue }
            let base = lastComponent(url)
            guard !base.isEmpty else { continue }

            // Two distinct source paths can share a file name; disambiguate so
            // one never overwrites the other in `assets/`.
            var name = base
            var counter = 2
            while usedNames.contains(name.lowercased()) {
                name = disambiguated(base, counter)
                counter += 1
            }
            usedNames.insert(name.lowercased())
            assetForPath[url] = name
            assets.append(Asset(name: name, data: data))
            edits.append((urlRange, "assets/\(name)"))
        }

        guard !edits.isEmpty else { return (source, assets) }
        // Apply back-to-front so each still-untouched range stays valid.
        let mutable = NSMutableString(string: source)
        for edit in edits.reversed() {
            mutable.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return (mutable as String, assets)
    }

    /// Assemble the `.textbundle` directory: `text.md`, `info.json` and an
    /// `assets/` folder (empty or populated). A `FileWrapper`, so the caller
    /// writes it to the export picker's chosen location in one `write(to:)`.
    static func bundleWrapper(text: String, assets: [Asset]) -> FileWrapper {
        let textFile = FileWrapper(regularFileWithContents: Data(text.utf8))
        textFile.preferredFilename = "text.md"
        let infoFile = FileWrapper(regularFileWithContents: Data(infoJSON.utf8))
        infoFile.preferredFilename = "info.json"

        var assetChildren: [String: FileWrapper] = [:]
        for asset in assets {
            let file = FileWrapper(regularFileWithContents: asset.data)
            file.preferredFilename = asset.name
            assetChildren[asset.name] = file
        }
        let assetsDir = FileWrapper(directoryWithFileWrappers: assetChildren)
        assetsDir.preferredFilename = "assets"

        return FileWrapper(directoryWithFileWrappers: [
            "text.md": textFile,
            "info.json": infoFile,
            "assets": assetsDir,
        ])
    }

    // MARK: Helpers

    /// The last `/`-separated component of a path (the file name). Scalar-exact
    /// splitting, matching how the ports split a path.
    private static func lastComponent(_ path: String) -> String {
        ScalarText.split(path, "/").last ?? path
    }

    /// `photo.png` → `photo-2.png`; a name with no extension → `README-2`.
    /// The dot must be past the first scalar so a dotfile (`.gitignore`) keeps
    /// its whole name as the stem.
    private static func disambiguated(_ name: String, _ counter: Int) -> String {
        let scalars = Array(name.unicodeScalars)
        if let dot = scalars.lastIndex(of: "."), dot > 0 {
            let stem = ScalarText.string(scalars[0..<dot])
            let ext = ScalarText.string(scalars[dot...])   // includes the "."
            return "\(stem)-\(counter)\(ext)"
        }
        return "\(name)-\(counter)"
    }
}
