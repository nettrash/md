//
//  TypewriterTheme.swift
//  md
//
//  Created by nettrash on 28/06/2026.
//
//  The app's typewriter aesthetic gathered in one place: the paper-and-ink
//  palette and the typewriter fonts.
//
//  The colors are keyed off the app icon's warm scheme — a light "fresh
//  paper" (warm off-white, dark sepia ink) and a dark "carbon paper"
//  (warm near-black, soft cream ink) — and live in the asset catalog
//  (`PaperBackground`, `PaperBackgroundSecondary`, `PaperInk`,
//  `AccentColor`) so UIKit and SwiftUI both get the light/dark variants
//  for free.
//
//  Prose — headings, body text and the raw editor — is set in American
//  Typewriter, the slab serif that gives the app the feel of a typed page.
//  Code spans and fenced blocks fall back to Courier New, where monospaced
//  columns matter. Every font is built `relativeTo:` a text style (or via
//  `UIFontMetrics`) so it still scales with Dynamic Type.
//

import SwiftUI
import UIKit

enum Typewriter {

    // MARK: - Font families

    /// The slab-serif prose face the whole app is built around.
    static let prose = "American Typewriter"
    /// The monospaced face used for code, where character alignment matters.
    static let mono = "Courier New"

    // MARK: - SwiftUI fonts

    /// A Dynamic-Type-scaled prose font (American Typewriter).
    static func font(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(prose, size: size, relativeTo: style)
    }

    /// A Dynamic-Type-scaled monospaced font (Courier New), for code.
    static func code(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(mono, size: size, relativeTo: style)
    }

    // MARK: - UIKit font (editor)

    /// American Typewriter's PostScript name. `UIFont(name:)` is stricter
    /// than SwiftUI's `Font.custom` — it wants the PostScript name, not the
    /// "American Typewriter" family name — so the editor uses this directly
    /// to avoid silently falling back to the system font.
    static let proseUIName = "AmericanTypewriter"

    /// The editor's `UIFont`: American Typewriter at body size, scaled for
    /// the current Dynamic Type setting. Pair with
    /// `adjustsFontForContentSizeCategory = true` so it tracks later changes.
    /// Falls back to the system monospaced font only if the face is missing.
    static func editorUIFont(size: CGFloat = 17) -> UIFont {
        let base = UIFont(name: proseUIName, size: size)
            ?? UIFont(name: prose, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
    }

    // MARK: - Colors (asset-backed → adapt to light / dark automatically)

    /// The page itself: warm off-white in light mode, warm near-black in dark.
    static let paper = Color("PaperBackground")
    /// Slightly contrasting paper for code-block / table chrome.
    static let paperSecondary = Color("PaperBackgroundSecondary")
    /// The "ink" — primary text color that sits on `paper`.
    static let ink = Color("PaperInk")

    /// UIKit mirrors, for the `UITextView`-backed editor.
    static let paperUIColor = UIColor(named: "PaperBackground") ?? .systemBackground
    static let inkUIColor = UIColor(named: "PaperInk") ?? .label
    static let accentUIColor = UIColor(named: "AccentColor") ?? .tintColor
}
