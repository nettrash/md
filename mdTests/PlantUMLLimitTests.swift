//
//  PlantUMLLimitTests.swift
//  mdTests
//
//  The one deliberate patch inside a vendored engine, pinned — the same patch,
//  and the same two assertions, as md.vscode's `test/plantuml-limit.test.ts`.
//
//  The bundled browser build of PlantUML (1.2026.4beta4 / 9a0b195) compares a
//  laid-out diagram's width and height against 4096.0 and, past either, throws
//  the drawing away for "Diagram too large for browser rendering: 7655x1445
//  (max 4096)". A 48-participant sequence diagram is already past it. The
//  preview and the HTML and PDF exports keep the SVG, so they spend no raster
//  budget at all. The EPUB does — every rich block becomes a PNG — and with
//  the gate gone a very tall diagram would be photographed whole at 2×;
//  `EpubBuilder.snapshotScale` is that budget now, at most 16 Mpx a snapshot
//  (width alone is capped by `.plantuml svg { max-width: 100%; height: auto; }`).
//  So both literals are raised to 1.0E9 — `rich/plantuml.js` is now
//  byte-identical to md.vscode's.
//
//  A re-vendored engine brings the gate back silently; this test is how that
//  day fails loudly. Re-apply with
//
//      perl -pi -e 's/o<=4096\.0\)\{p=m\.bDm;if\(p<=4096\.0\)/o<=1.0E9){p=m.bDm;if(p<=1.0E9)/' md/rich/plantuml.js
//
//  adjusting the minified identifiers to whatever the new build calls them.
//

import XCTest
@testable import md

final class PlantUMLLimitTests: XCTestCase {

    /// The patched gate as it reads in the vendored file: width, then height.
    private let patchedGate = "o<=1.0E9){p=m.bDm;if(p<=1.0E9)"

    /// The engine the app ships — the test bundle is hosted in md.app.
    private func engine() throws -> String {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "plantuml", withExtension: "js", subdirectory: "rich"))
        // Latin-1 decodes any byte, so a stray non-UTF-8 byte cannot hide the file.
        return try XCTUnwrap(String(data: Data(contentsOf: url), encoding: .isoLatin1))
    }

    func testHoldsTheRaisedGateOnce() throws {
        XCTAssertEqual(try engine().components(separatedBy: patchedGate).count - 1, 1)
    }

    func testHoldsNo4096PixelComparison() throws {
        // `4096` alone appears legitimately; the gate compared doubles, and no
        // other double 4096.0 exists in the build.
        XCTAssertFalse(try engine().contains("4096.0"))
    }

    /// The raster budget that replaces the gate for the EPUB: 2× while it
    /// fits, scaled down so a snapshot never passes 16 Mpx.
    func testEpubSnapshotsStayWithinThePixelBudget() {
        XCTAssertEqual(EpubBuilder.snapshotScale(for: CGSize(width: 700, height: 1000)), 2)
        let tall = CGSize(width: 700, height: 40_000)
        let scale = EpubBuilder.snapshotScale(for: tall)
        XCTAssertLessThan(scale, 2)
        XCTAssertLessThanOrEqual(tall.width * scale * tall.height * scale, EpubBuilder.maxSnapshotPixels * 1.0001)
        XCTAssertEqual(EpubBuilder.snapshotScale(for: .zero), 2)
    }
}
