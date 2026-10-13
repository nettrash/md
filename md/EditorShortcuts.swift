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
        /// The formatting commands (1.6, `MarkdownFormatting`): ⌘B, ⌘I, ⌘K,
        /// ⇧⌘C, ⇧⌘X, ⌥⌘1–6, ⇧⌘L, ⇧⌘T, ⌘' and ⌘] / ⌘[.
        case bold, italic, link, code, strikethrough
        case heading1, heading2, heading3, heading4, heading5, heading6
        case bulletList, taskList, quote, indent, outdent

        var id: String { rawValue }
    }

    /// The key a chord sits on, named the way `VirtualKeys` names it in
    /// md.win so the two tables read the same.
    enum Key: String {
        case number1 = "Number1"
        case number2 = "Number2"
        case number3 = "Number3"
        case number4 = "Number4"
        case number5 = "Number5"
        case number6 = "Number6"
        case b = "B"
        case c = "C"
        case f = "F"
        case i = "I"
        case k = "K"
        case l = "L"
        case p = "P"
        case q = "Q"
        case t = "T"
        case x = "X"
        case up = "Up"
        case down = "Down"
        case openBracket = "OemOpenBrackets"
        case closeBracket = "OemCloseBrackets"
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
    ///
    /// and the formatting rows of 1.6 (md.win `docs/formatting.md` §5):
    ///
    ///     Bold Ctrl+B · Italic Ctrl+I · Link Ctrl+K · Code Ctrl+Shift+C
    ///     Strikethrough Ctrl+Shift+X · Heading 1–6 Ctrl+Alt+1–6
    ///     Bullet List Ctrl+Shift+L · Task List Ctrl+Shift+T
    ///     Quote Ctrl+Shift+Q · Indent Ctrl+] · Outdent Ctrl+[
    ///
    /// Two of those are spelled differently on Apple — see `appleExceptions`.
    static let table: [Action: Chord] = [
        .viewEdit:        Chord(key: .number1, modifiers: .ctrl),
        .viewSplit:       Chord(key: .number2, modifiers: .ctrl),
        .viewPreview:     Chord(key: .number3, modifiers: .ctrl),
        .find:            Chord(key: .f,       modifiers: .ctrl),
        .print:           Chord(key: .p,       modifiers: .ctrl),
        .showBook:        Chord(key: .b,       modifiers: .ctrlShift),
        .previousArticle: Chord(key: .up,      modifiers: .ctrlAlt),
        .nextArticle:     Chord(key: .down,    modifiers: .ctrlAlt),
        .bold:            Chord(key: .b,       modifiers: .ctrl),
        .italic:          Chord(key: .i,       modifiers: .ctrl),
        .link:            Chord(key: .k,       modifiers: .ctrl),
        .code:            Chord(key: .c,       modifiers: .ctrlShift),
        .strikethrough:   Chord(key: .x,       modifiers: .ctrlShift),
        .heading1:        Chord(key: .number1, modifiers: .ctrlAlt),
        .heading2:        Chord(key: .number2, modifiers: .ctrlAlt),
        .heading3:        Chord(key: .number3, modifiers: .ctrlAlt),
        .heading4:        Chord(key: .number4, modifiers: .ctrlAlt),
        .heading5:        Chord(key: .number5, modifiers: .ctrlAlt),
        .heading6:        Chord(key: .number6, modifiers: .ctrlAlt),
        .bulletList:      Chord(key: .l,       modifiers: .ctrlShift),
        .taskList:        Chord(key: .t,       modifiers: .ctrlShift),
        .quote:           Chord(key: .q,       modifiers: .ctrlShift),
        .indent:          Chord(key: .closeBracket, modifiers: .ctrl),
        .outdent:         Chord(key: .openBracket,  modifiers: .ctrl),
    ]

    /// The two places Apple does not follow the translation rule, decided
    /// for 1.6 and the same on the Mac and the iPad:
    ///
    ///   * Headings are ⌥⌘1–6, not the rule's ⌃⌘1–6 — the spelling Mac
    ///     Markdown editors already use for headings (nettrash's call,
    ///     2026-10-10).
    ///   * Quote is ⌘', not the rule's ⇧⌘Q: on the Mac ⇧⌘Q is Log Out in the
    ///     Apple menu, which the system resolves before any app item, so the
    ///     command could never fire there — and the iPad follows the Mac so
    ///     the two tables stay equal.
    static let appleExceptions: [Action: (key: KeyEquivalent, modifiers: EventModifiers)] = [
        .heading1: ("1", [.command, .option]),
        .heading2: ("2", [.command, .option]),
        .heading3: ("3", [.command, .option]),
        .heading4: ("4", [.command, .option]),
        .heading5: ("5", [.command, .option]),
        .heading6: ("6", [.command, .option]),
        .quote: ("'", .command),
    ]

    /// The chord as Apple presses it: the table translated by the rule,
    /// unless `appleExceptions` says otherwise.
    static func appleChord(_ action: Action) -> (key: KeyEquivalent, modifiers: EventModifiers) {
        if let exception = appleExceptions[action] { return exception }
        let chord = chord(action)
        return (chord.keyEquivalent, chord.eventModifiers)
    }

    /// The formatting command an action runs, or nil for the others.
    static func formattingOp(_ action: Action) -> MarkdownFormatting.Op? {
        switch action {
        case .bold: return .bold
        case .italic: return .italic
        case .link: return .link
        case .code: return .code
        case .strikethrough: return .strikethrough
        case .heading1: return .heading1
        case .heading2: return .heading2
        case .heading3: return .heading3
        case .heading4: return .heading4
        case .heading5: return .heading5
        case .heading6: return .heading6
        case .bulletList: return .bulletList
        case .taskList: return .taskList
        case .quote: return .quote
        case .indent: return .indent
        case .outdent: return .outdent
        default: return nil
        }
    }

    /// The menu name of a formatting action.
    static func formattingTitle(_ action: Action) -> String {
        switch action {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .link: return "Link"
        case .code: return "Code"
        case .strikethrough: return "Strikethrough"
        case .heading1: return "Heading 1"
        case .heading2: return "Heading 2"
        case .heading3: return "Heading 3"
        case .heading4: return "Heading 4"
        case .heading5: return "Heading 5"
        case .heading6: return "Heading 6"
        case .bulletList: return "Bullet List"
        case .taskList: return "Task List"
        case .quote: return "Quote"
        case .indent: return "Indent"
        case .outdent: return "Outdent"
        default: return action.rawValue
        }
    }

    /// The formatting actions, in the Format menu's order.
    static let formattingActions: [Action] = [
        .bold, .italic, .code, .strikethrough, .link,
        .heading1, .heading2, .heading3, .heading4, .heading5, .heading6,
        .bulletList, .taskList, .quote, .indent, .outdent,
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
        case .number4: return "4"
        case .number5: return "5"
        case .number6: return "6"
        case .b: return "b"
        case .c: return "c"
        case .f: return "f"
        case .i: return "i"
        case .k: return "k"
        case .l: return "l"
        case .p: return "p"
        case .q: return "q"
        case .t: return "t"
        case .x: return "x"
        case .up: return .upArrow
        case .down: return .downArrow
        case .openBracket: return "["
        case .closeBracket: return "]"
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
        let chord = EditorShortcuts.appleChord(action)
        return keyboardShortcut(chord.key, modifiers: chord.modifiers)
    }
}
