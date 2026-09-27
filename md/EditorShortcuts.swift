//
//  EditorShortcuts.swift
//  md
//
//  The hardware-keyboard chords, written down once.
//
//  md answers to the same chords on every port, and the port that spells
//  them out in full is the Windows one: `md.win/src/Md.App.Logic/Commands/
//  CommandTable.cs` is the single table its menus, its accelerators and its
//  enablement are all built from. The rows below are that table's chords,
//  copied verbatim for the commands an iPad can reach — key and *Windows*
//  modifiers, not Apple's — so a diff between the two is a diff between two
//  lists of the same shape rather than a translation argument.
//
//  The translation to Apple's spelling is the one rule the whole family
//  follows, and it is not the obvious one:
//
//      Windows Ctrl  →  Apple Command   (⌘)
//      Windows Alt   →  Apple Control   (⌃)
//      Windows Shift →  Apple Shift     (⇧)
//
//  which is why Previous Article is Ctrl+Alt+Up on Windows and ⌃⌘↑ on the
//  Mac and iPad. `EditorShortcutsTests` pins the translation against the
//  Mac's own `keyboardShortcut` calls in md.macOS/md/mdApp.swift — two
//  independent sources, so a wrong row fails the test rather than shipping.
//
//  Nothing here knows about views. `DocumentView` reads the table to build
//  the chords it installs; the table never reaches back.
//

import SwiftUI

enum EditorShortcuts {

    /// One command a chord can run. Exactly the commands the iPad offers —
    /// the Windows table is larger (Save, Close, Zen Mode, Full Screen …),
    /// and the commands iOS has no surface for are simply not rows here.
    enum Action: String, CaseIterable, Identifiable {
        /// ⌘1 / ⌘2 / ⌘3 — the three layouts.
        case viewEdit, viewSplit, viewPreview
        /// ⌘F — the system find-and-replace panel over the editor pane.
        case find
        /// ⌘P — print the rendered document.
        case print
        /// ⇧⌘B — bring the book navigator up.
        case showBook
        /// ⌃⌘↑ / ⌃⌘↓ — step through the book in reading order.
        case previousArticle, nextArticle

        var id: String { rawValue }
    }

    /// The key a chord sits on, named the way `VirtualKeys` names it in
    /// md.win so the two tables read the same.
    enum Key: String {
        case number1 = "Number1"
        case number2 = "Number2"
        case number3 = "Number3"
        case b = "B"
        case f = "F"
        case p = "P"
        case up = "Up"
        case down = "Down"
    }

    /// A chord's modifiers **as Windows writes them** (`KeyModifiers` in
    /// md.win). Kept in the Windows spelling on purpose: this is the copy
    /// of the shared table, and a copy that had already been translated
    /// could not be diffed against its source.
    struct Modifiers: OptionSet, Hashable {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue }

        static let ctrl  = Modifiers(rawValue: 1 << 0)
        static let shift = Modifiers(rawValue: 1 << 1)
        static let alt   = Modifiers(rawValue: 1 << 2)

        static let ctrlShift: Modifiers = [.ctrl, .shift]
        static let ctrlAlt: Modifiers = [.ctrl, .alt]
    }

    /// One row: a key and the modifiers held with it.
    struct Chord: Hashable {
        let key: Key
        let modifiers: Modifiers
    }

    /// The table. Every value is CommandTable.cs's, unchanged:
    ///
    ///     ViewEdit          Chord(VirtualKeys.Number1, Ctrl)
    ///     ViewSplit         Chord(VirtualKeys.Number2, Ctrl)
    ///     ViewPreview       Chord(VirtualKeys.Number3, Ctrl)
    ///     Find              Chord(VirtualKeys.F,       Ctrl)
    ///     Print             Chord(VirtualKeys.P,       Ctrl)
    ///     ShowBook          Chord(VirtualKeys.B,       CtrlShift)
    ///     PreviousArticle   Chord(VirtualKeys.Up,      CtrlAlt)
    ///     NextArticle       Chord(VirtualKeys.Down,    CtrlAlt)
    static let table: [Action: Chord] = [
        .viewEdit:        Chord(key: .number1, modifiers: .ctrl),
        .viewSplit:       Chord(key: .number2, modifiers: .ctrl),
        .viewPreview:     Chord(key: .number3, modifiers: .ctrl),
        .find:            Chord(key: .f,       modifiers: .ctrl),
        .print:           Chord(key: .p,       modifiers: .ctrl),
        .showBook:        Chord(key: .b,       modifiers: .ctrlShift),
        .previousArticle: Chord(key: .up,      modifiers: .ctrlAlt),
        .nextArticle:     Chord(key: .down,    modifiers: .ctrlAlt),
    ]

    /// The chord for a command. Every `Action` has one — the table is
    /// complete by construction and a test says so — so the lookup is
    /// allowed to be total.
    static func chord(_ action: Action) -> Chord {
        // A missing row would be a programming error, not a runtime
        // condition; ⌘1 is a harmless stand-in rather than a crash in the
        // reader's hands.
        table[action] ?? Chord(key: .number1, modifiers: .ctrl)
    }
}

// MARK: - Apple's spelling

extension EditorShortcuts.Key {

    /// The SwiftUI key this Windows virtual key is.
    var keyEquivalent: KeyEquivalent {
        switch self {
        case .number1: return "1"
        case .number2: return "2"
        case .number3: return "3"
        case .b: return "b"
        case .f: return "f"
        case .p: return "p"
        case .up: return .upArrow
        case .down: return .downArrow
        }
    }
}

extension EditorShortcuts.Modifiers {

    /// The Apple modifiers these Windows ones mean — Ctrl is ⌘, Alt is ⌃
    /// (see this file's header for why that is not a typo).
    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if contains(.ctrl) { result.insert(.command) }
        if contains(.alt) { result.insert(.control) }
        if contains(.shift) { result.insert(.shift) }
        return result
    }
}

extension EditorShortcuts.Chord {
    var keyEquivalent: KeyEquivalent { key.keyEquivalent }
    var eventModifiers: EventModifiers { modifiers.eventModifiers }
}

extension View {

    /// Install a command's chord, straight off the shared table.
    func keyboardShortcut(_ action: EditorShortcuts.Action) -> some View {
        let chord = EditorShortcuts.chord(action)
        return keyboardShortcut(chord.keyEquivalent, modifiers: chord.eventModifiers)
    }
}
