//
//  FileTypeTests.swift
//  mdTests
//
//  The file types the app is associated with, pinned at both ends.
//
//  (a) What the app declares. Info.plist is read from the test host — the
//      tests run hosted, so `Bundle.main` is md.app and its Info.plist is
//      the one that ships — with the source tree (via #filePath) as the
//      fallback should a run ever not be hosted. Every identifier's
//      extension list is pinned exactly, in order, against the canonical
//      sets all five md ports register, so a port that drifts fails here.
//
//  (b) What the system does with it. `UTType` asks Launch Services, which
//      learned about the host app when xcodebuild installed / launched it,
//      so `UTType(filenameExtension:)` here is the same lookup Finder, the
//      Files app and the document browser make. This is the check that
//      catches the trap the declarations grew around: an extension listed
//      on an identifier the system already declares (`.mdown` on
//      `net.daringfireball.markdown`, once) is silently dropped, and the
//      file resolves to a dynamic `dyn.*` type nobody is offered for.
//      Which tags survive depends on the release: iOS 26's live
//      declaration of that identifier knows only `.md`, so there even
//      `.markdown` was dropped. Nothing in (a) can see that; only (b) can.
//
//  The identifiers are spelled out as strings on purpose, next to the
//  `UTType` constants the app uses: if someone renames a constant's
//  identifier, the plist, the code and this file must all move together.
//

import UniformTypeIdentifiers
import XCTest
#if canImport(AppKit)
import AppKit
#endif
@testable import md

final class FileTypeTests: XCTestCase {

    // MARK: the canonical sets

    /// The extension sets every md port registers, in this order. Markdown's
    /// own identifier keeps the one tag every system declaration of it
    /// carries; everything else — `.markdown` included, because iOS 26 knows
    /// only `.md` — is on the alias, `.markdown` first so that it is the
    /// alias's preferred extension.
    private static let markdownOwn = ["md"]
    private static let markdownAliases = ["markdown", "mdown", "markdn", "mdtext", "mdtxt", "mkd", "mkdn", "mdwn", "mkdown"]
    private static let markdownAll = markdownOwn + markdownAliases
    private static let plantUML = ["puml", "plantuml", "iuml", "pu"]
    private static let graphviz = ["gv"]
    private static let plainText = ["txt", "text"]
    private static let textBundle = ["textbundle"]
    private static let textPack = ["textpack"]

    private static let markdownID = "net.daringfireball.markdown"
    private static let aliasID = "me.nettrash.md.markdown-alias"
    private static let plantUMLID = "net.sourceforge.plantuml.puml"
    private static let graphvizID = "org.graphviz.dot"
    private static let textBundleID = "org.textbundle.package"
    private static let textPackID = "org.textbundle.pack"
    private static let plainTextID = "public.plain-text"

    // MARK: helpers

    private typealias Plist = [String: Any]

    /// The app's Info.plist: the host's when the tests run hosted (the very
    /// dictionary the OS registered), else the file in the source tree.
    private func infoPlist() throws -> Plist {
        if let hosted = Bundle.main.infoDictionary, hosted["CFBundleDocumentTypes"] != nil {
            return hosted
        }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()            // mdTests/
            .deletingLastPathComponent()            // repo root
            .appendingPathComponent("md/Info.plist")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? Plist,
                             "Info.plist at \(url.path) is not a dictionary")
    }

    private struct TypeDeclaration {
        let identifier: String
        let description: String?
        let conformsTo: [String]
        let extensions: [String]
    }

    private func declarations(_ plist: Plist, key: String) throws -> [TypeDeclaration] {
        let raw = try XCTUnwrap(plist[key] as? [Plist], "\(key) is missing from Info.plist")
        return try raw.map { entry in
            let tags = entry["UTTypeTagSpecification"] as? Plist
            return TypeDeclaration(
                identifier: try XCTUnwrap(entry["UTTypeIdentifier"] as? String, "\(key) entry without an identifier"),
                description: entry["UTTypeDescription"] as? String,
                conformsTo: entry["UTTypeConformsTo"] as? [String] ?? [],
                extensions: tags?["public.filename-extension"] as? [String] ?? [])
        }
    }

    private struct DocumentType {
        let name: String
        let rank: String?
        let role: String?
        let contentTypes: [String]
    }

    private func documentTypes(_ plist: Plist) throws -> [DocumentType] {
        let raw = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [Plist], "CFBundleDocumentTypes is missing")
        return try raw.map { entry in
            DocumentType(
                name: try XCTUnwrap(entry["CFBundleTypeName"] as? String, "document type without a name"),
                rank: entry["LSHandlerRank"] as? String,
                role: entry["CFBundleTypeRole"] as? String,
                contentTypes: entry["LSItemContentTypes"] as? [String] ?? [])
        }
    }

    /// The preferred type for an extension, as the system resolves it —
    /// unconstrained, the way Finder and the document browser look a file
    /// up. Not `UTType(filenameExtension:)`: that one defaults to
    /// `conformingTo: .data`, which a `.textbundle` (a package, not data)
    /// fails, so it would come back dynamic even though it is declared.
    private func preferred(_ ext: String) throws -> UTType {
        try XCTUnwrap(UTType(tag: ext, tagClass: .filenameExtension, conformingTo: nil),
                      "no type at all for .\(ext)")
    }

    /// Other registered copies of this app (the App Store build in
    /// /Applications, older DerivedData builds) — macOS only, where Launch
    /// Services can see several. An *imported* identifier is shared, and
    /// when several bundles declare it only one declaration is live: the
    /// first registered, which on a developer's Mac is usually an older copy.
    private func otherRegisteredCopies() -> [URL] {
        #if canImport(AppKit)
        guard let id = Bundle.main.bundleIdentifier else { return [] }
        let me = Bundle.main.bundleURL.standardizedFileURL
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id)
            .filter { $0.standardizedFileURL != me }
        #else
        return []
        #endif
    }

    /// Every identifier the system knows for an extension, ours included.
    private func allIdentifiers(_ ext: String) -> [String] {
        UTType.types(tag: ext, tagClass: .filenameExtension, conformingTo: nil).map(\.identifier)
    }

    // MARK: (a) the declarations

    func testExportedAliasDeclaresEveryOtherMarkdownExtension() throws {
        let exported = try declarations(try infoPlist(), key: "UTExportedTypeDeclarations")
        XCTAssertEqual(exported.map(\.identifier), [Self.aliasID],
                       "the alias is the only type the app owns outright")
        let alias = try XCTUnwrap(exported.first)
        XCTAssertEqual(alias.description, "Markdown Text")
        XCTAssertEqual(alias.extensions, Self.markdownAliases,
                       "every Markdown extension except .md, in canonical order, .markdown first")
        XCTAssertTrue(alias.conformsTo.contains(Self.markdownID),
                      "the alias must conform to Markdown so the document types still see it as Markdown")
        XCTAssertTrue(alias.conformsTo.contains(Self.plainTextID),
                      "the alias must conform to plain text so its bytes are read and written as text")
    }

    func testImportedDeclarationsPinTheCanonicalExtensionSets() throws {
        let imported = try declarations(try infoPlist(), key: "UTImportedTypeDeclarations")
        XCTAssertEqual(imported.map(\.identifier),
                       [Self.markdownID, Self.plantUMLID, Self.graphvizID, Self.textBundleID, Self.textPackID])
        let byID = Dictionary(uniqueKeysWithValues: imported.map { ($0.identifier, $0) })

        // Markdown carries only `md`: the one tag every system declaration
        // of it carries (iOS 26 lists nothing else). Anything more is
        // dropped wherever the system declares the identifier (see the
        // alias), and `.markdown` in particular was dropped on iOS 26.
        let markdown = try XCTUnwrap(byID[Self.markdownID])
        XCTAssertEqual(markdown.extensions, Self.markdownOwn)
        XCTAssertEqual(markdown.conformsTo, [Self.plainTextID])

        let plantUML = try XCTUnwrap(byID[Self.plantUMLID])
        XCTAssertEqual(plantUML.extensions, Self.plantUML)
        XCTAssertTrue(plantUML.conformsTo.contains(Self.plainTextID))

        let graphviz = try XCTUnwrap(byID[Self.graphvizID])
        XCTAssertEqual(graphviz.extensions, Self.graphviz, "gv only — .dot is a Word template on Apple platforms")
        XCTAssertTrue(graphviz.conformsTo.contains(Self.plainTextID))

        XCTAssertEqual(try XCTUnwrap(byID[Self.textBundleID]).extensions, Self.textBundle)
        XCTAssertEqual(try XCTUnwrap(byID[Self.textBundleID]).conformsTo, ["com.apple.package"],
                       "a .textbundle is a directory package, or the system would hand over a folder")
        XCTAssertEqual(try XCTUnwrap(byID[Self.textPackID]).extensions, Self.textPack)
        XCTAssertEqual(try XCTUnwrap(byID[Self.textPackID]).conformsTo, ["public.zip-archive"])
    }

    func testEveryExtensionIsClaimedOnceAndTheCanonicalSetIsComplete() throws {
        let plist = try infoPlist()
        let all = try declarations(plist, key: "UTExportedTypeDeclarations")
            + declarations(plist, key: "UTImportedTypeDeclarations")
        let claimed = all.flatMap(\.extensions)

        // One declaration per extension: two of our own types claiming the
        // same extension would leave it ambiguous.
        XCTAssertEqual(claimed.count, Set(claimed).count, "an extension is listed on two declarations: \(claimed)")

        // The union is the canonical set, and nothing else. Plain text is
        // absent on purpose — `public.plain-text` is the system's, so `.txt`
        // and `.text` are the system's tags, claimed through the document
        // type rather than declared by us.
        let canonical = Self.markdownAll + Self.plantUML + Self.graphviz + Self.textBundle + Self.textPack
        XCTAssertEqual(Set(claimed), Set(canonical))
        for ext in Self.plainText {
            XCTAssertFalse(claimed.contains(ext), ".\(ext) belongs to public.plain-text, not to a declaration of ours")
        }
        XCTAssertFalse(claimed.contains("dot"), ".dot must never be claimed — it is com.microsoft.word.dot")
    }

    func testDocumentTypesClaimExactlyWhatTheDocumentReads() throws {
        let types = try documentTypes(try infoPlist())
        let claimedIDs = types.flatMap(\.contentTypes)
        XCTAssertEqual(claimedIDs.count, Set(claimedIDs).count, "an identifier is claimed by two document types")
        XCTAssertEqual(Set(claimedIDs), Set(MarkdownDocument.readableContentTypes.map(\.identifier)),
                       "CFBundleDocumentTypes and readableContentTypes must claim the same identifiers")

        let byID = Dictionary(uniqueKeysWithValues: types.flatMap { t in t.contentTypes.map { ($0, t) } })
        // md owns Markdown, under both identifiers; everything else it merely opens.
        XCTAssertEqual(byID[Self.markdownID]?.rank, "Owner")
        XCTAssertEqual(byID[Self.aliasID]?.rank, "Owner")
        for id in [Self.plantUMLID, Self.graphvizID, Self.textBundleID, Self.textPackID, Self.plainTextID] {
            XCTAssertEqual(byID[id]?.rank, "Alternate", id)
        }
        // The two Markdown entries have distinct names: on macOS the Save
        // panel's format popup labels each writable type by its name, and
        // two entries called the same thing would be indistinguishable.
        XCTAssertNotEqual(byID[Self.markdownID]?.name, byID[Self.aliasID]?.name)
        #if os(macOS)
        for type in types {
            XCTAssertEqual(type.role, "Editor", "\(type.name) must be editable, not just viewable")
        }
        #endif
    }

    func testReadableAndWritableContentTypes() {
        XCTAssertEqual(MarkdownDocument.readableContentTypes.map(\.identifier),
                       [Self.markdownID, Self.aliasID, Self.plainTextID, Self.plantUMLID,
                        Self.graphvizID, Self.textBundleID, Self.textPackID])
        XCTAssertEqual(MarkdownDocument.writableContentTypes.map(\.identifier),
                       [Self.markdownID, Self.aliasID, Self.plainTextID, Self.plantUMLID, Self.graphvizID])
        XCTAssertEqual(MarkdownDocument.writableContentTypes.first, UTType.markdown,
                       "a new document is created as the first writable type, and that is a .md")
        // A type that is only readable opens read-only: a .mkd must be
        // writable or the user could not save the file they are editing.
        XCTAssertTrue(MarkdownDocument.writableContentTypes.contains(.markdownAlias))
        // Bundles are read-only by design — saving one back would drop assets/.
        XCTAssertFalse(MarkdownDocument.writableContentTypes.contains(.textBundle))
        XCTAssertFalse(MarkdownDocument.writableContentTypes.contains(.textPack))
    }

    // MARK: (b) the registration

    func testEveryMarkdownAliasExtensionResolvesToADeclaredMarkdownType() throws {
        for ext in Self.markdownAliases {
            XCTAssertTrue(allIdentifiers(ext).contains(Self.aliasID),
                          ".\(ext) is not registered to \(Self.aliasID); the system knows \(allIdentifiers(ext))")
            let type = try preferred(ext)
            XCTAssertTrue(type.isDeclared, ".\(ext) resolves to an undeclared type \(type.identifier)")
            XCTAssertFalse(type.isDynamic, ".\(ext) resolves to the dynamic type \(type.identifier) — the tag was dropped")
            XCTAssertTrue(type.conforms(to: .markdown), ".\(ext) → \(type.identifier) is not Markdown")
            XCTAssertTrue(type.conforms(to: .plainText), ".\(ext) → \(type.identifier) is not plain text")
        }
        // .markdown is claimed by two declarations that are both md's: the
        // system's own where it lists the extension (macOS, iOS 27), and the
        // alias, which is what iOS 26 — whose live declaration knows only
        // .md — resolves it to. Either is right; the loop above has already
        // required it to be declared, static, Markdown and plain text, and a
        // dynamic type is the failure this exists to catch.
        let markdown = try preferred("markdown")
        XCTAssertTrue([Self.markdownID, Self.aliasID].contains(markdown.identifier),
                      ".markdown resolved to \(markdown.identifier), neither the system's Markdown nor the alias")
        // .md resolves to Markdown's own identifier on every release — the
        // system's declaration where there is one, else our live copy.
        for ext in Self.markdownOwn {
            let type = try preferred(ext)
            XCTAssertEqual(type.identifier, Self.markdownID, ".\(ext)")
            XCTAssertTrue(type.isDeclared)
            XCTAssertTrue(type.conforms(to: .plainText))
        }
        // A new document takes the first writable type's preferred
        // extension, and that must be .md on every release: `md` is the one
        // tag every declaration of the identifier carries, and the first.
        XCTAssertEqual(UTType.markdown.preferredFilenameExtension, "md", "a new document must be a .md")
        // And the alias type itself is live — declared, with its tags intact
        // and .markdown, listed first, as its preferred extension.
        XCTAssertTrue(UTType.markdownAlias.isDeclared)
        XCTAssertFalse(UTType.markdownAlias.isDynamic)
        XCTAssertEqual(Set(UTType.markdownAlias.tags[.filenameExtension] ?? []), Set(Self.markdownAliases))
        XCTAssertEqual(UTType.markdownAlias.preferredFilenameExtension, "markdown")
        XCTAssertTrue(UTType.markdownAlias.conforms(to: .markdown))
        XCTAssertTrue(UTType.markdownAlias.conforms(to: .plainText))
    }

    func testEveryPlantUMLExtensionResolvesToThePlantUMLType() throws {
        // `net.sourceforge.plantuml.puml` is imported, so it is shared with
        // every other bundle that declares it — including another copy of
        // md. If one is registered and its (older, two-tag) declaration is
        // the live one, `.iuml` / `.pu` resolve to nothing on this machine
        // until that copy is updated. That is the machine, not the app: skip
        // and say so, rather than fail — or pass without looking. With a
        // single copy (CI, a simulator, a user's Mac) the check is hard.
        let live = Set(UTType.plantUML.tags[.filenameExtension] ?? [])
        let others = otherRegisteredCopies()
        if !others.isEmpty, live != Set(Self.plantUML) {
            throw XCTSkip("another registered copy of md holds the live PlantUML declaration "
                          + "(tags \(live.sorted())): \(others.map(\.path))")
        }
        for ext in Self.plantUML {
            let type = try preferred(ext)
            XCTAssertEqual(type.identifier, Self.plantUMLID, ".\(ext) resolved to \(type.identifier)")
            XCTAssertTrue(type.isDeclared, ".\(ext)")
            XCTAssertFalse(type.isDynamic, ".\(ext)")
            XCTAssertTrue(type.conforms(to: .plainText), ".\(ext)")
        }
        XCTAssertEqual(Set(UTType.plantUML.tags[.filenameExtension] ?? []), Set(Self.plantUML),
                       "no system declaration exists for PlantUML, so every tag listed must be live")
    }

    func testTheRemainingTypesResolveAsDeclared() throws {
        for ext in Self.graphviz {
            let type = try preferred(ext)
            XCTAssertEqual(type.identifier, Self.graphvizID, ".\(ext)")
            XCTAssertTrue(type.isDeclared && !type.isDynamic, ".\(ext)")
            XCTAssertTrue(type.conforms(to: .plainText), ".\(ext)")
        }
        XCTAssertFalse(allIdentifiers("dot").contains(Self.graphvizID),
                       ".dot must stay with Word templates; md is not to be offered for them")

        for ext in Self.textBundle {
            let type = try preferred(ext)
            XCTAssertEqual(type.identifier, Self.textBundleID, ".\(ext)")
            XCTAssertTrue(type.conforms(to: .package), "a .textbundle must be a package to arrive as a directory")
        }
        for ext in Self.textPack {
            let type = try preferred(ext)
            XCTAssertEqual(type.identifier, Self.textPackID, ".\(ext)")
            XCTAssertTrue(type.conforms(to: .zip), ".textpack")
        }
        for ext in Self.plainText {
            let type = try preferred(ext)
            XCTAssertTrue(type.conforms(to: .plainText), ".\(ext) → \(type.identifier)")
            XCTAssertTrue(type.isDeclared && !type.isDynamic, ".\(ext)")
        }
    }
}
