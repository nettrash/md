//
//  Plot.swift
//  md
//
//  Created by nettrash on 29/08/2026.
//
//  The ```plot fence: source text in, an SVG string out.
//
//  THE ONE PROPERTY WORTH PROTECTING
//  ---------------------------------
//  This file is **pure and synchronous**. No engine, no bundled asset, no
//  `<script>`, no network, no platform API — a string goes in and a string
//  comes out. That is what makes every surface work for free: the live
//  preview, the self-contained HTML export, print, PDF, EPUB, LaTeX and the
//  "export this diagram as SVG" command all receive a finished `<svg>` in the
//  bytes the renderer already returns. A plot-only document never loads an
//  engine and never touches the WebView's engines at all.
//
//  The one piece of state in the file is `PlotMemo`, the renderer's memo, and
//  it is state only in the bookkeeping sense: a memo of a pure function returns
//  exactly what recomputing would, so `renderPlot` remains a function of its
//  argument alone. Read that type's comment before touching it — the lock is
//  load-bearing, because the export paths render off the main thread.
//
//  It is also why nothing here reaches for UIKit, WebKit or `rich/**`, and why
//  `md-init.js` is not touched: that file is byte-identical across `md`,
//  `md.macOS` and `md.Android`, and the plot needs no client-side engine —
//  the SVG is in the markup before any script runs.
//
//  This is a transliteration of `md.vscode/src/render/plot.ts`, which is the
//  parity core the four ports are written against: same function names, same
//  order, same comments. Everything is deliberately written in the subset
//  that translates literally — hand-written scanning instead of regular
//  expressions, plain records instead of generics, explicit loops instead of
//  clever reductions — so a defect fixed in one port can be found in the
//  other three by reading the same lines.
//
//  WHAT IT IS A PORT OF, AND WHERE IT DELIBERATELY DIVERGES
//  -------------------------------------------------------
//  The geometry comes from nettrash.me's own plotter
//  (`frontend/src/components/math.rs`: `render_plot_svg`, `nice_step`,
//  `format_label`), so a figure drawn here lands where the site draws it. Four
//  behaviours of that plotter are **bugs**, and they are fixed here rather than
//  inherited — each one is called out at the code that fixes it:
//
//    1. `floor`, `ceil` and `round` draw nothing on the site (its preprocessor
//       rewrites every name to `math::…` while evalexpr binds those three
//       bare), so all 1001 samples fail. They work here.
//    2. A comparison yields a Boolean the site's eval closure throws away, so
//       `x > 0` is a blank chart. Here comparisons yield 1.0 / 0.0, which makes
//       `(x > 0) * sqrt(x)` the half-domain idiom it should be.
//    3. `^` is right-associative here — `2^3^2` is 512, not evalexpr's 64.
//    4. Everything is a double: `5/2` is 2.5, not evalexpr's integer 2.
//
//  and two more in the axis code, where the site's own output is visibly wrong:
//  tick labels are rounded rather than truncated (a tick at −4 printed "-3"),
//  and tick positions are computed by index rather than accumulated (a tick at
//  0 printed "-5.6e-17").
//
//  NUMBER FORMATTING IS THE CROSS-PLATFORM HAZARD
//  ----------------------------------------------
//  Rust's `{:.1e}` writes `1.0e3`; C's `%.1e` — which is what `String(format:)`
//  calls — writes `1.0e+03`; Java the same; JavaScript's `toExponential(1)`
//  writes `1.0e+3`. Worse, the *rounding* differs: 1250 is `1.2e3` in Rust
//  (ties to even) and `1.3e+3` in Java and JavaScript (ties away from zero).
//  So the formatters at the foot of this file are written by hand, round ties
//  to even on the exact binary value, and emit the Rust spelling. **Do not
//  replace them with `String(format:)`.**
//
//  AND SO IS `pow`
//  ---------------
//  `pow` and `log10` are not correctly rounded and are not specified to be, so
//  they are one ULP apart between **engine versions** — not between CPUs, which
//  is where an earlier draft of this comment sent people looking. Compare
//  `pow(10, n)` against the decimal literal `1e<n>` over all 632 integer
//  exponents in [-323, 308] and the split falls by runtime, never by machine:
//  Node 20 disagrees 68 times on arm64 and 69 times on x86-64, Node 22 the same
//  68, Node 24 twice (at e = 23 and 210), Node 26 not once. On this one Mac,
//  Darwin's libm is correct for all 632 while OpenJDK 21's
//  `Math.pow(10.0, -5.0)` is one ULP below the literal — same CPU, different
//  answers. `niceStep` used to build its decade as
//  `pow(10, floor(log10(rough)))`, and that one ULP moved the tick step, the
//  tick count and every label with it — md.vscode's CI, which runs Node 20,
//  went red on the pushed v1.2.0 while the same code passed here on Node 26 and
//  on Darwin's libm. Decades are now parsed from decimal literals
//  (`Plot.decade(_:)`), which every one of these languages does specify to be
//  correctly rounded. **Do not reintroduce `pow(10, e)`.**
//
//  SCALARS, NOT CHARACTERS
//  -----------------------
//  Every scan below walks `Unicode.Scalar`s, the way `ScalarText` requires of
//  `MarkdownParser` and `LaTeXExport`. This file is new and not bound by that
//  rule, but the rule's reason applies here too: `"&\u{0301}".contains("&")` is
//  false, so a grapheme-based escape would let a raw `&` through into an EPUB's
//  XHTML and make the book unopenable. Scalars are also exactly what the
//  TypeScript reference counts, so the four ports agree byte for byte.
//

import Foundation

/// Everything that makes a block unrenderable, with the message the reader sees.
struct PlotError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// A bounded, thread-safe memo of finished ```plot containers, keyed on the
/// exact fence text that produced them.
///
/// WHY THE RENDERER NEEDS ONE
/// --------------------------
/// The live preview rebuilds the whole HTML document on every text change; the
/// debounce delays the WebView reload, not the render. Every *other* rich block
/// is only escaped text at that layer — its engine runs asynchronously in the
/// page — so a plot is the first fence whose real cost is paid synchronously,
/// in the render, on the main thread, for every block in the document, on every
/// keystroke. Measured in a release build: 4.87 ms for one default plot,
/// 9.52 ms for the golden fence, 36 ms for an eight-series plot, 187 ms for a
/// document with four eight-series plots and 289 ms for ten `samples: 5000`
/// plots. The per-fence caps bound one fence; they do not bound a document.
///
/// WHY MEMOISING IS SOUND, AND WHY HERE
/// ------------------------------------
/// `Plot.renderPlot` is a pure function of one string: no clock, no locale, no
/// theme (the ink is `currentColor` and the series colours are baked, which is
/// exactly why the renderer takes no `dark` flag), no counter. So a cache keyed
/// on that string is trivially correct, and while an author types prose around
/// their figures every plot in the document is a hit. This is also the cheapest
/// and safest place to fix the cost: the debounce and the preview coordinator
/// carry scroll-sync and document-token behaviour that a render cache has no
/// business touching.
///
/// THE LOCK IS NOT DECORATION
/// --------------------------
/// `renderPlot` is called from the export paths — PDF, self-contained HTML,
/// EPUB, LaTeX, "export diagram as SVG" — which build their markup off the main
/// thread while the preview may be rendering on it. Two threads inside an
/// unsynchronised `Dictionary` is a crash, not a stale read. An `NSLock` is
/// enough: every critical section is a dictionary probe, and the render itself
/// happens *outside* the lock, so a slow figure never blocks another thread.
/// (Two threads racing on the same miss both render it; the function is pure,
/// so they compute the same string and the second store simply wins.)
///
/// THE BOUND
/// ---------
/// 32 entries, least-recently-used — the same number `md.vscode`'s preview
/// client uses for its own diagram cache (`src/preview/md-preview.ts`,
/// `CACHE_LIMIT = 32`). Bounded rather than unbounded because an editing
/// session would otherwise retain every intermediate fence the author ever
/// typed through; 32 because a document that shows more than 32 plots at once
/// is not the case worth tuning for, and each entry is one SVG string
/// (~17 KB for the default figure, so ~0.5 MB at the ceiling).
final class PlotMemo {

    /// Entries, hits and misses. Read by the tests; nothing else.
    struct Statistics: Equatable {
        var entries: Int
        var hits: Int
        var misses: Int
    }

    private let limit: Int
    private let lock = NSLock()
    private var entries: [String: String] = [:]
    /// Keys, oldest first. At 32 entries a linear move costs less than the
    /// bookkeeping a linked list would need, and it ports to the other three
    /// repos as the same two lines.
    private var order: [String] = []
    private var hits = 0
    private var misses = 0

    /// The largest container worth remembering, in UTF-8 bytes — eight times
    /// the default figure. See `store(_:for:)` for why there is a byte bound
    /// as well as an entry bound.
    static let largestMemoisedValue = 128 * 1024

    init(limit: Int) { self.limit = limit }

    /// The memoised container for `key`, moved to the young end, or nil.
    func value(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = entries[key] else {
            misses += 1
            return nil
        }
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
        hits += 1
        return value
    }

    /// Memoise `value`, evicting the least recently used key past the limit.
    func store(_ value: String, for key: String) {
        // An oversized figure is not memoised. The entry ceiling bounds the
        // *count*, not the bytes, and one fence may legally reach 1.8 MB
        // (24 series x `samples: 5000` at 2000x2000), so 32 of those would
        // retain ~57 MB for the life of the process — on a phone, a plausible
        // way to be killed for memory. A figure this large is also the one a
        // memo helps least: it is rare, and its re-render is measured in
        // hundreds of milliseconds either way. Everything ordinary is far
        // below the line — the default figure is 16,888 bytes — so this bounds
        // the memo at roughly 4 MB without costing the common case anything.
        if value.utf8.count > Self.largestMemoisedValue { return }
        lock.lock()
        defer { lock.unlock() }
        if entries.updateValue(value, forKey: key) != nil,
           let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
        while order.count > limit {
            entries.removeValue(forKey: order.removeFirst())
        }
    }

    var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return Statistics(entries: entries.count, hits: hits, misses: misses)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
        hits = 0
        misses = 0
    }
}

enum Plot {

    // MARK: - The entry point

    /// One ```plot fence, as the block of markup the renderer embeds.
    ///
    /// The container is emitted **unconditionally** — for a good plot, an empty
    /// block and a broken one alike. Every export path counts `div.plot`
    /// containers to pair a rendered figure with its source block, so a fence
    /// that emitted nothing would shift every later diagram onto the wrong
    /// figure.
    ///
    /// A block that cannot be parsed keeps its source text visible under one
    /// `plot: …` line, which is the family's rule for every rich block: never a
    /// hole, never an error box.
    ///
    /// **Memoised on `source`.** See `PlotMemo` for why, and why that is sound.
    static func renderPlot(_ source: String) -> String {
        if let memoised = memo.value(for: source) { return memoised }
        let container: String
        do {
            container = "<div class=\"plot\">\(try plotSVG(source))</div>"
        } catch let error as PlotError {
            container = "<div class=\"plot\"><pre>\(escapeHTML("plot: \(error.message)\n\(source)"))</pre></div>"
        } catch {
            container = "<div class=\"plot\"><pre>\(escapeHTML("plot: \(error)\n\(source)"))</pre></div>"
        }
        // Failures are stored too, on purpose: a half-typed fence is a parse
        // error on most keystrokes, and that is the state a fence spends most
        // of its life in while it is being written. Re-deriving "unknown
        // function 'si'" on every keystroke buys nothing.
        memo.store(container, for: source)
        return container
    }

    /// The renderer's memo. See `PlotMemo` for the sizing and the lock.
    private static let memo = PlotMemo(limit: 32)

    /// Entries, hits and misses — for the tests, and for anyone reasoning
    /// about the bound. Nothing in the app branches on these.
    static var memoStatistics: PlotMemo.Statistics { memo.statistics }

    /// Drop every memoised container.
    ///
    /// Only the tests need this: the memo is a pure function's memo, so an app
    /// has no reason to invalidate it. Kept next to `memoStatistics` so the two
    /// test hooks are one place rather than two.
    static func clearMemo() { memo.removeAll() }

    /// The `<svg>` element for a fence, or a `PlotError` describing why not.
    ///
    /// An empty block — no series at all — is not an error and draws nothing,
    /// the same way an empty Mermaid block does.
    static func plotSVG(_ source: String) throws -> String {
        let spec = try parsePlot(source)
        // A block with nothing in it draws nothing, the way an empty Mermaid
        // block does. A block the author *did* write in — directives but no
        // series — is not empty, and returning "" there would swallow what they
        // typed into a container with no figure and no explanation. Draw the
        // empty axes those directives describe: it shows the range and title
        // took effect, and the missing curve is then obviously the missing curve.
        if spec.series.isEmpty && !spec.hasDirectives { return "" }
        return draw(spec)
    }

    // MARK: - The fence

    /// A parsed ```plot block: the directives, resolved, and the series in order.
    struct Spec {
        var xMin: Double = -10
        var xMax: Double = 10
        /// nil when `y: auto` (the default) — the range is fitted to the samples.
        var yMin: Double?
        var yMax: Double?
        var title: String = ""
        var xLabel: String = ""
        var yLabel: String = ""
        var legend: Legend = .auto
        var grid: Bool = true
        var axes: Bool = true
        var width: Int = defaultWidth
        var height: Int = defaultHeight
        var samples: Int = defaultSamples
        var series: [Series] = []
        /// Whether the fence carried at least one directive.
        ///
        /// Distinguishes a genuinely empty block (draws nothing, like an empty
        /// Mermaid block) from one the author wrote directives into but no
        /// series — which must still draw, or their text vanishes into a
        /// container with nothing in it.
        var hasDirectives: Bool = false
    }

    enum Legend { case on, off, auto }

    /// One curve.
    ///
    /// Three shapes, one flat record rather than three types: a `kind` tag and
    /// the fields each kind uses, which is the shape the drawing code reads
    /// without a downcast in any of the four ports.
    struct Series {
        enum Kind { case function, parametric, points }
        var kind: Kind
        /// The author's own label, or nil — in which case the legend shows `source`.
        var label: String?
        /// The source text of the series, verbatim, for the legend and for messages.
        var source: String
        /// `function`: y = f(x). `parametric`: the x half. Unused by `points`.
        var expression: Node?
        /// `parametric` only: the y half.
        var yExpression: Node?
        /// `parametric` only: the parameter's name and range.
        var parameter: String
        var tMin: Double
        var tMax: Double
        /// `points` only.
        var points: [Point]
    }

    struct Point: Equatable {
        var x: Double
        var y: Double
    }

    /// The directive keys. Anything else before a colon is a series, not an error.
    private static let directives = [
        "x", "y", "title", "xlabel", "ylabel", "legend", "grid", "axes", "width", "height", "samples",
    ]

    private static let defaultWidth = 600
    private static let defaultHeight = 400
    private static let defaultSamples = 1000
    private static let minWidth = 160
    private static let maxWidth = 2000
    private static let minHeight = 120
    private static let maxHeight = 2000
    private static let minSamples = 50
    private static let maxSamples = 5000
    /// The most series one fence may draw.
    ///
    /// `samples`, `width` and `height` are all clamped, but the series count is
    /// the one input an author sets just by adding lines — and the preview
    /// re-renders the whole document on every keystroke. A thousand-series
    /// fence is a frozen editor rather than a slow one. Twenty-four is well
    /// past any legible figure (the palette holds eight) and cheap at the
    /// sampling limit.
    private static let maxSeries = 24
    /// The deepest an expression may nest.
    ///
    /// The parser and the evaluator both recurse, so `((((…x…))))` or `x+x+x+…`
    /// can exhaust the stack. **On this platform a stack overflow is a crash,
    /// not an exception**, so this guard is load-bearing in a way it is not in
    /// TypeScript: there is no `catch` that would turn it back into a
    /// `plot: <what>` line.
    private static let maxDepth = 128
    /// The most nodes one expression may hold.
    ///
    /// The depth guard cannot see a long *flat* chain: `x+x+x+…` parses through
    /// the left-associative loop at constant depth, then blows the stack in the
    /// evaluator, which walks the resulting left-deep tree recursively.
    /// Budgeting nodes at parse time catches both shapes in one place, before
    /// anything is evaluated 1000 times over.
    private static let maxNodes = 4096

    /// Read a fence into a `Spec`.
    ///
    /// Blank lines are ignored, a line whose first non-space character is `#` is
    /// a comment, and order is free — directives may follow series. A line is a
    /// directive when it reads `key: value` **and the key is known**, so `f: x`
    /// still plots rather than failing on an unknown directive.
    static func parsePlot(_ source: String) throws -> Spec {
        var spec = Spec()

        for raw in splitLines(source) {
            let line = trim(raw)
            if line.isEmpty { continue }
            if line[0] == "#" { continue }
            if let directive = matchDirective(line) {
                try applyDirective(&spec, directive.key, directive.value)
                spec.hasDirectives = true
                continue
            }
            if spec.series.count == maxSeries {
                throw PlotError("too many series (limit \(maxSeries))")
            }
            spec.series.append(try parseSeries(line))
        }

        if !(spec.xMax > spec.xMin) { throw PlotError("x range must be increasing") }
        if let low = spec.yMin, let high = spec.yMax, !(high > low) {
            throw PlotError("y range must be increasing")
        }
        return spec
    }

    /// `key: value`, whatever the key.
    ///
    /// Hand-scanned rather than matched with `^\s*([a-z][a-z-]*)\s*:\s*(.*)$`,
    /// because the same scan has to exist in TypeScript and Kotlin.
    private static func matchKeyed(_ line: [Unicode.Scalar]) -> (key: String, value: [Unicode.Scalar])? {
        var index = 0
        while index < line.count && isSpace(line[index]) { index += 1 }
        let start = index
        if index >= line.count || !isLowerLetter(line[index]) { return nil }
        while index < line.count && (isLowerLetter(line[index]) || line[index] == "-") {
            index += 1
        }
        let key = string(slice(line, start, index))
        while index < line.count && isSpace(line[index]) { index += 1 }
        if index >= line.count || line[index] != ":" { return nil }
        return (key, trim(slice(line, index + 1, line.count)))
    }

    /// The same line, when the key is one this renderer knows.
    ///
    /// The known-key test is what keeps an unknown `key:` line from failing the
    /// block: `f: x` is a series labelled `f`, not a complaint about a directive
    /// nobody meant to write.
    private static func matchDirective(_ line: [Unicode.Scalar]) -> (key: String, value: [Unicode.Scalar])? {
        guard let keyed = matchKeyed(line), contains(directives, keyed.key) else { return nil }
        return keyed
    }

    private static func applyDirective(_ spec: inout Spec, _ key: String,
                                       _ value: [Unicode.Scalar]) throws {
        if key == "x" {
            let range = try parseRange(value, "x")
            spec.xMin = range.min
            spec.xMax = range.max
            return
        }
        if key == "y" {
            if lowercased(value) == "auto" {
                spec.yMin = nil
                spec.yMax = nil
                return
            }
            let range = try parseRange(value, "y")
            spec.yMin = range.min
            spec.yMax = range.max
            return
        }
        if key == "title" {
            spec.title = string(value)
            return
        }
        if key == "xlabel" {
            spec.xLabel = string(value)
            return
        }
        if key == "ylabel" {
            spec.yLabel = string(value)
            return
        }
        if key == "legend" {
            let word = lowercased(value)
            if word == "on" { spec.legend = .on; return }
            if word == "off" { spec.legend = .off; return }
            if word == "auto" { spec.legend = .auto; return }
            throw PlotError("legend must be 'on', 'off' or 'auto'")
        }
        if key == "grid" || key == "axes" {
            let word = lowercased(value)
            if word != "on" && word != "off" { throw PlotError("\(key) must be 'on' or 'off'") }
            if key == "grid" { spec.grid = word == "on" } else { spec.axes = word == "on" }
            return
        }
        if key == "width" {
            spec.width = clampInteger(try number(value, "width"), minWidth, maxWidth)
            return
        }
        if key == "height" {
            spec.height = clampInteger(try number(value, "height"), minHeight, maxHeight)
            return
        }
        // `samples`, the only key left.
        spec.samples = clampInteger(try number(value, "samples"), minSamples, maxSamples)
    }

    /// `A..B`.
    ///
    /// Both ends are parsed as constant expressions rather than bare number
    /// literals, so `x: -pi..pi` and `x: 0..2*pi` work. A number literal is the
    /// simplest such expression, so nothing that the stricter reading accepts is
    /// lost, and an end that mentions a variable is an error rather than a silent
    /// zero.
    private static func parseRange(_ value: [Unicode.Scalar],
                                   _ key: String) throws -> (min: Double, max: Double) {
        let at = indexOfPair(value, ".", ".")
        if at < 0 { throw PlotError("\(key) range must be written min..max") }
        let min = try constant(slice(value, 0, at), key)
        let max = try constant(slice(value, at + 2, value.count), key)
        if !(max > min) { throw PlotError("\(key) range must be increasing") }
        return (min, max)
    }

    /// A constant expression: no variable, finite.
    private static func constant(_ text: [Unicode.Scalar], _ key: String) throws -> Double {
        let trimmed = trim(text)
        if trimmed.isEmpty { throw PlotError("\(key) range must be written min..max") }
        let value = evaluate(try parseExpression(trimmed, ""), "", 0)
        if !isFiniteNumber(value) { throw PlotError("\(key) range must be finite") }
        return value
    }

    private static func number(_ value: [Unicode.Scalar], _ key: String) throws -> Double {
        let parsed = evaluate(try parseExpression(trim(value), ""), "", 0)
        if !isFiniteNumber(parsed) { throw PlotError("\(key) must be a number") }
        return parsed
    }

    /// A pixel count or a sample count: rounded to a whole number, then clamped.
    ///
    /// `number` has already refused anything that is not finite, so the whole
    /// value is always representable once it is inside the bounds.
    private static func clampInteger(_ value: Double, _ low: Int, _ high: Int) -> Int {
        let whole = roundTiesAway(value)
        if whole < Double(low) { return low }
        if whole > Double(high) { return high }
        return Int(whole)
    }

    /// One series line.
    ///
    /// The label is everything left of the first top-level `=` that is not part
    /// of `==`, `<=`, `>=` or `!=`. There is no ambiguity to resolve: the
    /// expression language has no assignment, so a bare `=` is always a label
    /// separator.
    private static func parseSeries(_ line: [Unicode.Scalar]) throws -> Series {
        var label: String?
        var body = line
        let at = labelSeparator(line)
        if at >= 0 {
            label = string(trim(slice(line, 0, at)))
            body = trim(slice(line, at + 1, line.count))
            if label!.isEmpty { label = nil }
        } else if !isPointsLine(line) {
            // `f: x` — a `key:` line whose key is no directive of ours. The key
            // is the label and the rest is the series, which is what lets an
            // unknown directive plot instead of failing the block. `points:` is
            // the one colon that means something else, and it is claimed above.
            if let keyed = matchKeyed(line), !keyed.value.isEmpty {
                label = keyed.key
                body = keyed.value
            }
        }
        if body.isEmpty { throw PlotError("a series needs an expression") }

        if let points = try parsePointsSeries(label, body) { return points }
        if let parametric = try parseParametricSeries(label, body) { return parametric }

        return Series(kind: .function, label: label, source: string(body),
                      expression: try parseExpression(body, "x"), yExpression: nil,
                      parameter: "x", tMin: 0, tMax: 0, points: [])
    }

    /// The index of the label `=`, or −1.
    private static func labelSeparator(_ line: [Unicode.Scalar]) -> Int {
        var depth = 0
        for index in 0..<line.count {
            let c = line[index]
            if c == "(" { depth += 1 } else if c == ")" { depth -= 1 } else if c == "=" && depth == 0 {
                // `==` is a comparison, and `<=`, `>=`, `!=` end with one.
                if index + 1 < line.count && line[index + 1] == "=" { return -1 }
                if index > 0 {
                    let before = line[index - 1]
                    if before == "=" || before == "<" || before == ">" || before == "!" { return -1 }
                }
                return index
            }
        }
        return -1
    }

    private static let pointsPrefix = "points:"

    /// Does this line open a points series?
    private static func isPointsLine(_ line: [Unicode.Scalar]) -> Bool {
        let count = pointsPrefix.unicodeScalars.count
        if line.count < count { return false }
        return lowercased(slice(line, 0, count)) == pointsPrefix
    }

    /// `points: x,y x,y …`, or nil when this is not a points series.
    private static func parsePointsSeries(_ label: String?,
                                          _ body: [Unicode.Scalar]) throws -> Series? {
        if !isPointsLine(body) { return nil }
        let prefix = pointsPrefix.unicodeScalars.count

        var points: [Point] = []
        for token in splitWhitespace(slice(body, prefix, body.count)) {
            let comma = indexOf(token, ",")
            if comma < 0 {
                throw PlotError("points must be x,y pairs — '\(string(token))' is not one")
            }
            points.append(Point(x: try constant(slice(token, 0, comma), "point"),
                                y: try constant(slice(token, comma + 1, token.count), "point")))
        }
        if points.isEmpty { throw PlotError("points needs at least one x,y pair") }
        return Series(kind: .points, label: label, source: string(body),
                      expression: nil, yExpression: nil,
                      parameter: "", tMin: 0, tMax: 0, points: points)
    }

    /// `(fx(t), fy(t)) for t in A..B`, or nil when this is not a parametric series.
    ///
    /// The test is deliberately narrow — an opening parenthesis whose match is
    /// followed by the word `for`, with exactly one top-level comma inside — so
    /// that `(x+1)*2` stays an ordinary function of x.
    private static func parseParametricSeries(_ label: String?,
                                              _ body: [Unicode.Scalar]) throws -> Series? {
        if body[0] != "(" { return nil }
        let close = matchingParenthesis(body, 0)
        if close < 0 { return nil }
        let tail = trim(slice(body, close + 1, body.count))
        if !startsWithWord(tail, "for") { return nil }

        let inside = slice(body, 1, close)
        let comma = topLevelComma(inside)
        if comma < 0 { throw PlotError("a parametric series needs (x(t), y(t))") }

        // `for t in A..B`
        let rest = trim(slice(tail, 3, tail.count))
        var index = 0
        while index < rest.count && isIdentifierPart(rest[index]) { index += 1 }
        let parameter = string(slice(rest, 0, index))
        if index == 0 || !isIdentifierStart(rest[0]) {
            throw PlotError("expected a parameter name after 'for'")
        }
        let afterName = trim(slice(rest, index, rest.count))
        if !startsWithWord(afterName, "in") { throw PlotError("expected 'in' after '\(parameter)'") }
        let range = try parseRange(trim(slice(afterName, 2, afterName.count)), parameter)

        return Series(kind: .parametric, label: label, source: string(body),
                      expression: try parseExpression(trim(slice(inside, 0, comma)), parameter),
                      yExpression: try parseExpression(trim(slice(inside, comma + 1, inside.count)),
                                                       parameter),
                      parameter: parameter, tMin: range.min, tMax: range.max, points: [])
    }

    // MARK: - The expression language: tokens

    /// A token.
    ///
    /// `kind` says what it is; `text` carries the spelling of a name or an
    /// operator and `value` the value of a number. One flat record rather than
    /// an enum with associated values, because the parser only ever asks two
    /// questions of a token and the associated values would cost every port a
    /// pattern match.
    private struct Token {
        enum Kind { case number, name, op, open, close, comma, end }
        var kind: Kind
        var text: String
        var value: Double
    }

    /// The two-character operators, longest match first — `<=` before `<`.
    private static let longOperators = ["||", "&&", "==", "!=", "<=", ">="]
    private static let shortOperators = ["+", "-", "*", "/", "%", "^", "<", ">", "!"]

    private static func tokenize(_ text: [Unicode.Scalar]) throws -> [Token] {
        var tokens: [Token] = []
        var index = 0
        while index < text.count {
            let c = text[index]
            if isSpace(c) {
                index += 1
                continue
            }
            if isDigit(c) || (c == "." && index + 1 < text.count && isDigit(text[index + 1])) {
                let scanned = try scanNumber(text, index)
                tokens.append(Token(kind: .number, text: string(slice(text, index, scanned.end)),
                                    value: scanned.value))
                index = scanned.end
                continue
            }
            if isIdentifierStart(c) {
                let start = index
                while index < text.count && isIdentifierPart(text[index]) { index += 1 }
                tokens.append(Token(kind: .name, text: string(slice(text, start, index)), value: 0))
                continue
            }
            if c == "(" {
                tokens.append(Token(kind: .open, text: "(", value: 0))
                index += 1
                continue
            }
            if c == ")" {
                tokens.append(Token(kind: .close, text: ")", value: 0))
                index += 1
                continue
            }
            if c == "," {
                tokens.append(Token(kind: .comma, text: ",", value: 0))
                index += 1
                continue
            }
            let two = index + 1 < text.count ? string(slice(text, index, index + 2)) : ""
            if !two.isEmpty && contains(longOperators, two) {
                tokens.append(Token(kind: .op, text: two, value: 0))
                index += 2
                continue
            }
            let one = string([c])
            if contains(shortOperators, one) {
                tokens.append(Token(kind: .op, text: one, value: 0))
                index += 1
                continue
            }
            throw PlotError("unexpected character '\(one)'")
        }
        tokens.append(Token(kind: .end, text: "", value: 0))
        return tokens
    }

    /// A number literal: `123`, `1.5`, `.5`, `5.`, `1e-3`, `1.2E+4`. No hex, no
    /// digit separators.
    ///
    /// The digits are handed to the platform's own decimal→binary conversion,
    /// which is correctly rounded everywhere this ships (it is the one place
    /// where the platform is more trustworthy than anything written by hand).
    private static func scanNumber(_ text: [Unicode.Scalar],
                                   _ start: Int) throws -> (end: Int, value: Double) {
        var index = start
        while index < text.count && isDigit(text[index]) { index += 1 }
        if index < text.count && text[index] == "." {
            index += 1
            while index < text.count && isDigit(text[index]) { index += 1 }
        }
        if index < text.count && (text[index] == "e" || text[index] == "E") {
            var lookahead = index + 1
            if lookahead < text.count && (text[lookahead] == "+" || text[lookahead] == "-") {
                lookahead += 1
            }
            if lookahead < text.count && isDigit(text[lookahead]) {
                index = lookahead
                while index < text.count && isDigit(text[index]) { index += 1 }
            }
        }
        let literal = string(slice(text, start, index))
        // A trailing `.` (`5.`) and a leading one (`.5`) are both accepted by
        // Swift's own conversion, the same as JavaScript's `Number` and Rust's
        // `parse::<f64>` — the scan above is what decides where the literal ends.
        guard let value = Double(literal), !value.isNaN else {
            throw PlotError("'\(literal)' is not a number")
        }
        return (index, value)
    }

    // MARK: - The expression language: the tree

    /// An expression node.
    ///
    /// As with `Token` this is one record with the fields each kind uses, so the
    /// tree ports to TypeScript and Kotlin without generics. A reference type,
    /// because a value type cannot hold itself.
    final class Node {
        enum Kind { case number, variable, unary, binary, call }
        /// `number`.
        let kind: Kind
        let value: Double
        /// `variable` (its name), `unary` / `binary` (the operator), `call` (the function).
        let text: String
        /// `unary` (the operand), `binary` (the left side).
        let left: Node?
        /// `binary`.
        let right: Node?
        /// `call`.
        let arguments: [Node]

        init(kind: Kind, value: Double, text: String, left: Node?, right: Node?, arguments: [Node]) {
            self.kind = kind
            self.value = value
            self.text = text
            self.left = left
            self.right = right
            self.arguments = arguments
        }
    }

    private static func numberNode(_ value: Double) -> Node {
        Node(kind: .number, value: value, text: "", left: nil, right: nil, arguments: [])
    }

    private static func variableNode(_ name: String) -> Node {
        Node(kind: .variable, value: 0, text: name, left: nil, right: nil, arguments: [])
    }

    private static func unaryNode(_ operator_: String, _ operand: Node) -> Node {
        Node(kind: .unary, value: 0, text: operator_, left: operand, right: nil, arguments: [])
    }

    private static func binaryNode(_ operator_: String, _ left: Node, _ right: Node) -> Node {
        Node(kind: .binary, value: 0, text: operator_, left: left, right: right, arguments: [])
    }

    private static func callNode(_ name: String, _ args: [Node]) -> Node {
        Node(kind: .call, value: 0, text: name, left: nil, right: nil, arguments: args)
    }

    /// The function roster — exactly the site's names and arity, and nothing else.
    ///
    /// `min`, `max`, `if`, `log` and evalexpr's other builtins are deliberately
    /// absent: the roster is the contract four implementations share, and a name
    /// that works in one of them and not the others is worse than a name that
    /// works in none.
    private static let functions = [
        "sin", "cos", "tan", "asin", "acos", "atan",
        "sinh", "cosh", "tanh", "asinh", "acosh", "atanh",
        "sqrt", "cbrt", "abs", "exp", "exp2", "ln", "log2", "log10",
        "floor", "ceil", "round",
        "atan2", "pow", "hypot",
    ]

    /// The three two-argument functions; everything else in `functions` takes one.
    private static let binaryFunctions = ["atan2", "pow", "hypot"]

    private static func arity(_ name: String) -> Int {
        contains(binaryFunctions, name) ? 2 : 1
    }

    /// Precedence, loosest to tightest. `^` is the only right-associative level.
    private static func precedence(_ operator_: String) -> Int {
        if operator_ == "||" { return 1 }
        if operator_ == "&&" { return 2 }
        if operator_ == "==" || operator_ == "!=" { return 3 }
        if operator_ == "<" || operator_ == "<=" || operator_ == ">" || operator_ == ">=" { return 3 }
        if operator_ == "+" || operator_ == "-" { return 4 }
        if operator_ == "*" || operator_ == "/" || operator_ == "%" { return 5 }
        if operator_ == "^" { return 6 }
        return 0
    }

    private static let powerPrecedence = 6

    /// Parse `text` as an expression in which `variable` is the only free name
    /// (besides the constants `pi` and `e`). Pass `""` for a constant expression.
    ///
    /// Precedence climbing, hand-written — no dependency, and the same twenty
    /// lines in every port.
    static func parseExpression(_ text: String, _ variable: String) throws -> Node {
        try parseExpression(Array(text.unicodeScalars), variable)
    }

    static func parseExpression(_ text: [Unicode.Scalar], _ variable: String) throws -> Node {
        let parser = Parser(try tokenize(text), variable)
        let node = try parser.expression(1)
        try parser.expectEnd()
        return node
    }

    private final class Parser {
        private let tokens: [Token]
        private let variable: String
        private var index = 0
        private var depth = 0
        private var nodes = 0

        init(_ tokens: [Token], _ variable: String) {
            self.tokens = tokens
            self.variable = variable
        }

        /// Charge one node against the budget, so a flat chain cannot outrun the
        /// depth guard.
        private func count() throws {
            nodes += 1
            if nodes > Plot.maxNodes { throw PlotError("expression too large") }
        }

        func expression(_ minimum: Int) throws -> Node {
            depth += 1
            if depth > Plot.maxDepth { throw PlotError("expression nested too deeply") }
            defer { depth -= 1 }
            return try expressionInner(minimum)
        }

        private func expressionInner(_ minimum: Int) throws -> Node {
            var left = try unary()
            while true {
                let token = peek()
                if token.kind != .op { break }
                let level = Plot.precedence(token.text)
                if level == 0 || level < minimum { break }
                index += 1
                // `^` is RIGHT-associative — `2^3^2` is 2^(3^2) = 512. The site's
                // evalexpr makes it left-associative and answers 64; this is the
                // deliberate divergence, not an accident of the algorithm.
                let next = token.text == "^" ? level : level + 1
                let right = try expression(next)
                try count()
                left = Plot.binaryNode(token.text, left, right)
            }
            return left
        }

        private func unary() throws -> Node {
            let token = peek()
            if token.kind == .op && (token.text == "-" || token.text == "+" || token.text == "!") {
                index += 1
                // The operand is parsed at the `^` level, which is what makes
                // unary minus bind *looser* than exponentiation: `-x^2` is −(x²),
                // and `-2^2` is −4.
                let operand = try expression(Plot.powerPrecedence)
                try count()
                return Plot.unaryNode(token.text, operand)
            }
            return try primary()
        }

        private func primary() throws -> Node {
            let token = peek()
            if token.kind == .number {
                index += 1
                return Plot.numberNode(token.value)
            }
            if token.kind == .open {
                index += 1
                let inner = try expression(1)
                if peek().kind != .close { throw PlotError("expected ')'") }
                index += 1
                return inner
            }
            if token.kind == .name {
                index += 1
                return try name(token.text)
            }
            if token.kind == .end { throw PlotError("the expression ends too early") }
            if token.kind == .close { throw PlotError("unmatched ')'") }
            throw PlotError("unexpected '\(token.text)'")
        }

        private func name(_ spelling: String) throws -> Node {
            if peek().kind == .open {
                if !Plot.contains(Plot.functions, spelling) {
                    throw PlotError("unknown function '\(spelling)'")
                }
                index += 1
                var args: [Node] = []
                if peek().kind != .close {
                    args.append(try expression(1))
                    while peek().kind == .comma {
                        index += 1
                        args.append(try expression(1))
                    }
                }
                if peek().kind != .close { throw PlotError("expected ')'") }
                index += 1
                let wanted = Plot.arity(spelling)
                if args.count != wanted {
                    throw PlotError(
                        "\(spelling) takes \(wanted) argument\(wanted == 1 ? "" : "s"), not \(args.count)")
                }
                return Plot.callNode(spelling, args)
            }
            if spelling == "pi" || spelling == "e" {
                return Plot.numberNode(spelling == "pi" ? Double.pi : M_E)
            }
            if !variable.isEmpty && spelling == variable { return Plot.variableNode(spelling) }
            if Plot.contains(Plot.functions, spelling) {
                throw PlotError("\(spelling) is a function — write \(spelling)(…)")
            }
            throw PlotError("unknown name '\(spelling)'")
        }

        func expectEnd() throws {
            let token = peek()
            if token.kind == .end { return }
            if token.kind == .close { throw PlotError("unmatched ')'") }
            throw PlotError("unexpected '\(token.text)'")
        }

        private func peek() -> Token {
            tokens[index]
        }
    }

    // MARK: - Evaluation

    /// Evaluate `node` with `variable` bound to `value`.
    ///
    /// Every value is an IEEE-754 double and **evaluation never fails**: a domain
    /// error is NaN or ±∞, which breaks the curve where it happens rather than
    /// failing the block. Everything that can be wrong about an expression —
    /// an unknown name, the wrong number of arguments, a missing parenthesis —
    /// was settled once, at parse time.
    ///
    /// Comparisons and the Boolean operators yield 1.0 and 0.0, which is the
    /// second deliberate divergence from the site: there they produce a Boolean
    /// the eval closure discards, so `(x > 0) * sqrt(x)` draws nothing at all.
    static func evaluate(_ node: Node, _ variable: String, _ value: Double) -> Double {
        if node.kind == .number { return node.value }
        if node.kind == .variable { return node.text == variable ? value : Double.nan }
        if node.kind == .unary {
            let operand = evaluate(node.left!, variable, value)
            if node.text == "-" { return -operand }
            if node.text == "+" { return operand }
            return operand == 0 ? 1 : 0
        }
        if node.kind == .binary {
            let left = evaluate(node.left!, variable, value)
            let right = evaluate(node.right!, variable, value)
            return binary(node.text, left, right)
        }
        // A call.
        let first = evaluate(node.arguments[0], variable, value)
        if node.arguments.count == 2 {
            let second = evaluate(node.arguments[1], variable, value)
            if node.text == "atan2" { return atan2(first, second) }
            if node.text == "pow" { return pow(first, second) }
            return hypot(first, second)
        }
        return unary(node.text, first)
    }

    private static func binary(_ operator_: String, _ left: Double, _ right: Double) -> Double {
        if operator_ == "+" { return left + right }
        if operator_ == "-" { return left - right }
        if operator_ == "*" { return left * right }
        // Division is real division: `5/2` is 2.5. evalexpr's integer division
        // answers 2, which is a trap in a plotting language.
        if operator_ == "/" { return left / right }
        // The truncated remainder — C's `fmod`, JavaScript's `%` and Rust's `%`,
        // never Swift's own `%` (which is not defined for doubles at all).
        if operator_ == "%" { return left.truncatingRemainder(dividingBy: right) }
        if operator_ == "^" { return pow(left, right) }
        if operator_ == "==" { return left == right ? 1 : 0 }
        if operator_ == "!=" { return left != right ? 1 : 0 }
        if operator_ == "<" { return left < right ? 1 : 0 }
        if operator_ == "<=" { return left <= right ? 1 : 0 }
        if operator_ == ">" { return left > right ? 1 : 0 }
        if operator_ == ">=" { return left >= right ? 1 : 0 }
        if operator_ == "&&" { return left != 0 && right != 0 ? 1 : 0 }
        return left != 0 || right != 0 ? 1 : 0
    }

    private static func unary(_ name: String, _ v: Double) -> Double {
        if name == "sin" { return sin(v) }
        if name == "cos" { return cos(v) }
        if name == "tan" { return tan(v) }
        if name == "asin" { return asin(v) }
        if name == "acos" { return acos(v) }
        if name == "atan" { return atan(v) }
        if name == "sinh" { return sinh(v) }
        if name == "cosh" { return cosh(v) }
        if name == "tanh" { return tanh(v) }
        if name == "asinh" { return asinh(v) }
        if name == "acosh" { return acosh(v) }
        if name == "atanh" { return atanh(v) }
        if name == "sqrt" { return sqrt(v) }
        if name == "cbrt" { return cbrt(v) }
        if name == "abs" { return Swift.abs(v) }
        if name == "exp" { return exp(v) }
        if name == "exp2" { return pow(2, v) }
        if name == "ln" { return log(v) }
        if name == "log2" { return log2(v) }
        if name == "log10" { return log10(v) }
        // floor / ceil / round DRAW. On the site they silently produce nothing:
        // `preprocess_math_expr` rewrites every roster name to `math::…` while
        // evalexpr binds exactly these three bare, so `math::floor` is unbound and
        // all 1001 samples fail. `round` is ties-away-from-zero, as Rust's is —
        // never the platform's ties-to-even or ties-up rounding.
        if name == "floor" { return floor(v) }
        if name == "ceil" { return ceil(v) }
        return roundTiesAway(v)
    }

    // MARK: - Drawing

    /// The palette, purple first so a one-series plot matches the site's colour.
    private static let palette = ["#673AB7", "#E5390F", "#0F9D58", "#F4B400",
                                  "#00838F", "#C2185B", "#5D4037", "#455A64"]

    /// The site's margin, and the room each extra asks for beyond it.
    private static let margin = 40.0
    private static let titleRoom = 24.0
    private static let axisLabelRoom = 18.0
    private static let legendMinimum = 72.0
    private static let legendPadding = 28.0
    private static let legendFont = 11.0
    /// Never let the extras eat the figure: the plot area keeps at least this.
    private static let minPlot = 40.0

    /// One sampled point of a series, and whether it may be drawn.
    private struct Sample {
        var x: Double
        var y: Double
    }

    private static func draw(_ spec: Spec) -> String {
        // Sample first: `y: auto` fits the range to what the series actually
        // produce, so the samples have to exist before the geometry does. They
        // are kept and reused for the drawing pass — sampling twice would be both
        // slower and one more chance for the two passes to disagree.
        var sampled: [[Sample]] = []
        for series in spec.series { sampled.append(sample(series, spec)) }

        let yRange = resolveY(spec, sampled)
        let yMin = yRange.min
        let yMax = yRange.max

        var labels: [String] = []
        for series in spec.series { labels.append(series.label ?? series.source) }
        let showLegend =
            spec.legend == .on ||
            (spec.legend == .auto && (spec.series.count >= 2 || hasExplicitLabel(spec.series)))

        let width = spec.width
        let height = spec.height

        var legendWidth = 0.0
        if showLegend {
            var longest = 0.0
            for label in labels { longest = max(longest, textWidth(label, legendFont)) }
            legendWidth = max(legendMinimum, ceil(longest) + legendPadding)
            legendWidth = min(legendWidth, max(0, Double(width) - 2 * margin - minPlot))
            if legendWidth < legendMinimum / 2 { legendWidth = 0 }
        }

        let horizontal = fitMargins(
            Double(width),
            margin + (spec.yLabel.isEmpty ? 0 : axisLabelRoom),
            margin + legendWidth)
        let vertical = fitMargins(
            Double(height),
            margin + (spec.title.isEmpty ? 0 : titleRoom),
            margin + (spec.xLabel.isEmpty ? 0 : axisLabelRoom))
        let left = horizontal.low
        let top = vertical.low
        let plotW = Double(width) - left - horizontal.high
        let plotH = Double(height) - top - vertical.high

        let xMin = spec.xMin
        let xMax = spec.xMax
        let sx = { (x: Double) -> Double in left + ((x - xMin) / (xMax - xMin)) * plotW }
        let sy = { (y: Double) -> Double in top + ((yMax - y) / (yMax - yMin)) * plotH }

        let xStep = niceStep(xMax - xMin)
        let yStep = niceStep(yMax - yMin)
        let xTicks = ticks(xMin, xMax, xStep)
        let yTicks = ticks(yMin, yMax, yStep)

        var out = ""
        out += "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(width) \(height)\""
        out += " width=\"\(width)\" height=\"\(height)\" role=\"img\">"
        // The accessible name. No `id` anywhere in this SVG, deliberately: a
        // document may hold two plots, a preview may patch its DOM, and a
        // duplicated id is how one figure ends up wearing another's clip path. An
        // `<svg role="img">` takes its name from its own `<title>` with no
        // `aria-labelledby` to point at, so there is nothing to number.
        out += "<title>\(escapeHTML(accessibleName(spec, labels)))</title>"

        // Ink is `currentColor` with opacity throughout — never the site's
        // #e0e0e0 / #999 / #666 / #ccc. `renderBlock` is theme-blind in all four
        // repos, so the one SVG has to be right in the light preview, the dark
        // preview, print, an exported page and a saved standalone file.
        // `currentColor` is what does that; a baked grey is a light-mode
        // assumption. For the same reason there is no `style="background:white"`
        // on the root, and no `<style>` element: SVG `<style>` inside an HTML
        // document is document-scoped and leaks.
        if spec.grid {
            out += "<g stroke=\"currentColor\" stroke-width=\"0.5\" opacity=\"0.15\">"
            for tick in xTicks {
                let at = fixed(sx(tick), 1)
                out += "<line x1=\"\(at)\" y1=\"\(fixed(top, 1))\" x2=\"\(at)\" y2=\"\(fixed(top + plotH, 1))\"/>"
            }
            for tick in yTicks {
                let at = fixed(sy(tick), 1)
                out += "<line x1=\"\(fixed(left, 1))\" y1=\"\(at)\" x2=\"\(fixed(left + plotW, 1))\" y2=\"\(at)\"/>"
            }
            out += "</g>"
        }

        if spec.axes {
            out += "<g stroke=\"currentColor\" stroke-width=\"1\" opacity=\"0.4\">"
            if yMin <= 0 && yMax >= 0 {
                let at = fixed(sy(0), 1)
                out += "<line x1=\"\(fixed(left, 1))\" y1=\"\(at)\" x2=\"\(fixed(left + plotW, 1))\" y2=\"\(at)\"/>"
            }
            if xMin <= 0 && xMax >= 0 {
                let at = fixed(sx(0), 1)
                out += "<line x1=\"\(at)\" y1=\"\(fixed(top, 1))\" x2=\"\(at)\" y2=\"\(fixed(top + plotH, 1))\"/>"
            }
            out += "</g>"

            out += "<g font-size=\"10\" fill=\"currentColor\" opacity=\"0.65\" font-family=\"sans-serif\">"
            for tick in xTicks {
                out +=
                    "<text x=\"\(fixed(sx(tick), 1))\" y=\"\(fixed(top + plotH + 15, 1))\" text-anchor=\"middle\">"
                    + "\(escapeHTML(formatLabel(tick)))</text>"
            }
            for tick in yTicks {
                out +=
                    "<text x=\"\(fixed(left - 5, 1))\" y=\"\(fixed(sy(tick), 1))\" text-anchor=\"end\" "
                    + "dominant-baseline=\"middle\">\(escapeHTML(formatLabel(tick)))</text>"
            }
            out += "</g>"

            out +=
                "<rect x=\"\(fixed(left, 1))\" y=\"\(fixed(top, 1))\" width=\"\(fixed(plotW, 1))\" "
                + "height=\"\(fixed(plotH, 1))\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1\" opacity=\"0.25\"/>"
        }

        if !spec.title.isEmpty {
            out +=
                // Centred on the plot area, not on the canvas: the xlabel below is,
                // and a legend gutter would otherwise push the two out of line with
                // each other.
                "<text x=\"\(fixed(left + plotW / 2, 1))\" y=\"\(fixed(top - 14, 1))\" text-anchor=\"middle\" "
                + "font-size=\"13\" font-weight=\"600\" fill=\"currentColor\" opacity=\"0.85\" "
                + "font-family=\"sans-serif\">\(escapeHTML(spec.title))</text>"
        }
        if !spec.xLabel.isEmpty {
            out +=
                "<text x=\"\(fixed(left + plotW / 2, 1))\" y=\"\(fixed(Double(height) - 8, 1))\" text-anchor=\"middle\" "
                + "font-size=\"11\" fill=\"currentColor\" opacity=\"0.85\" font-family=\"sans-serif\">"
                + "\(escapeHTML(spec.xLabel))</text>"
        }
        if !spec.yLabel.isEmpty {
            let x = fixed(14, 1)
            let y = fixed(top + plotH / 2, 1)
            out +=
                "<text x=\"\(x)\" y=\"\(y)\" text-anchor=\"middle\" transform=\"rotate(-90 \(x) \(y))\" "
                + "font-size=\"11\" fill=\"currentColor\" opacity=\"0.85\" font-family=\"sans-serif\">"
                + "\(escapeHTML(spec.yLabel))</text>"
        }

        for index in 0..<spec.series.count {
            out += polylines(sampled[index], spec.series[index], colour(index),
                             sx, sy, xMin, xMax, yMin, yMax)
        }

        if legendWidth > 0 {
            let x = Double(width) - horizontal.high + 8
            out += "<g font-size=\"11\" font-family=\"sans-serif\">"
            for index in 0..<labels.count {
                let y = top + 12 + Double(index) * 16
                out +=
                    "<line x1=\"\(fixed(x, 1))\" y1=\"\(fixed(y - 4, 1))\" x2=\"\(fixed(x + 14, 1))\" "
                    + "y2=\"\(fixed(y - 4, 1))\" stroke=\"\(colour(index))\" stroke-width=\"2\"/>"
                out +=
                    "<text x=\"\(fixed(x + 20, 1))\" y=\"\(fixed(y, 1))\" fill=\"currentColor\" opacity=\"0.85\">"
                    + "\(escapeHTML(labels[index]))</text>"
            }
            out += "</g>"
        }

        out += "</svg>"
        return out
    }

    /// The polylines of one series.
    ///
    /// A point is drawable when it is finite **and** inside the window. Anything
    /// else ends the current run and the next drawable point starts a new one —
    /// which is what makes `tan(x)` seven branches instead of one figure-wide
    /// spike. A run of a single point is still emitted, exactly as the site
    /// emits it.
    private static func polylines(_ samples: [Sample], _ series: Series, _ stroke: String,
                                  _ sx: (Double) -> Double, _ sy: (Double) -> Double,
                                  _ xMin: Double, _ xMax: Double,
                                  _ yMin: Double, _ yMax: Double) -> String {
        var out = ""
        var run = ""
        var started = false
        var marks: [String] = []
        for point in samples {
            let drawable =
                isFiniteNumber(point.x) &&
                isFiniteNumber(point.y) &&
                point.x >= xMin &&
                point.x <= xMax &&
                point.y >= yMin &&
                point.y <= yMax
            if drawable {
                let at = "\(fixed(sx(point.x), 2)),\(fixed(sy(point.y), 2))"
                run += started ? " \(at)" : at
                started = true
                if series.kind == .points {
                    marks.append(
                        "<circle cx=\"\(fixed(sx(point.x), 2))\" cy=\"\(fixed(sy(point.y), 2))\" r=\"2.5\" fill=\"\(stroke)\"/>")
                }
            } else if started {
                out += "<polyline points=\"\(run)\" fill=\"none\" stroke=\"\(stroke)\" stroke-width=\"2\"/>"
                run = ""
                started = false
            }
        }
        if !run.isEmpty {
            out += "<polyline points=\"\(run)\" fill=\"none\" stroke=\"\(stroke)\" stroke-width=\"2\"/>"
        }
        for mark in marks { out += mark }
        return out
    }

    /// The samples of one series.
    ///
    /// `x_i = xMin + (i / samples) * (xMax - xMin)`, `i` in `0…samples`
    /// **inclusive** — that expression and not the cheaper `xMin + i * dx`, which
    /// differs in the last bits for 221 of the 1001 default samples and does
    /// change the output.
    private static func sample(_ series: Series, _ spec: Spec) -> [Sample] {
        var out: [Sample] = []
        if series.kind == .points {
            for point in series.points { out.append(Sample(x: point.x, y: point.y)) }
            return out
        }
        if series.kind == .parametric {
            let span = series.tMax - series.tMin
            for i in 0...spec.samples {
                let t = series.tMin + (Double(i) / Double(spec.samples)) * span
                out.append(Sample(x: evaluate(series.expression!, series.parameter, t),
                                  y: evaluate(series.yExpression!, series.parameter, t)))
            }
            return out
        }
        let span = spec.xMax - spec.xMin
        for i in 0...spec.samples {
            let x = spec.xMin + (Double(i) / Double(spec.samples)) * span
            out.append(Sample(x: x, y: evaluate(series.expression!, "x", x)))
        }
        return out
    }

    /// `y: auto` — fit the finite samples, then pad 5 % on each side.
    ///
    /// A series that produces nothing finite contributes nothing; when no series
    /// does, the range falls back to −1…1. A flat series has no span to take 5 %
    /// of, so it is padded by 5 % of its own value, or by 1 when that is zero too.
    private static func resolveY(_ spec: Spec,
                                 _ sampled: [[Sample]]) -> (min: Double, max: Double) {
        if let low = spec.yMin, let high = spec.yMax { return (low, high) }
        var low = Double.infinity
        var high = -Double.infinity
        for samples in sampled {
            for point in samples {
                if !isFiniteNumber(point.y) { continue }
                if point.y < low { low = point.y }
                if point.y > high { high = point.y }
            }
        }
        if !isFiniteNumber(low) || !isFiniteNumber(high) { return (-1, 1) }
        let span = high - low
        if span > 0 { return padded(low - span * 0.05, high + span * 0.05, low, high) }
        let padding = Swift.abs(high) * 0.05
        let pad = padding > 0 ? padding : 1
        return padded(low - pad, high + pad, low, high)
    }

    /// The padded range, or the unpadded one when padding overflowed to infinity.
    ///
    /// `high - low` overflows for a series straddling ~1e308, and `high + pad`
    /// overflows for a flat series above ~1.71e308. Either way every `sy()` would
    /// come out NaN and the emitted polyline would read `points="40.00,NaN …"` —
    /// a curve that silently vanishes with no `plot:` line to explain it. Falling
    /// back to the unpadded bounds keeps such a plot drawable; if even those are
    /// not finite the caller's `-1..1` default has already been returned.
    private static func padded(_ min: Double, _ max: Double,
                               _ low: Double, _ high: Double) -> (min: Double, max: Double) {
        if isFiniteNumber(min) && isFiniteNumber(max) && max > min { return bounded(min, max) }
        if high > low { return bounded(low, high) }
        return bounded(low - 1, high + 1)
    }

    /// A range whose *width* is finite, not merely whose ends are.
    ///
    /// `sy()` divides by `yMax - yMin`, so a series spanning ~1e308 makes that
    /// subtraction overflow even though both bounds are ordinary doubles — and
    /// then every coordinate is NaN and the curve silently vanishes. Halving each
    /// end keeps the width representable; anything beyond is outside the window
    /// and the break rule already omits it, which is the same treatment any other
    /// out-of-range point gets.
    private static func bounded(_ min: Double, _ max: Double) -> (min: Double, max: Double) {
        if !(max > min) { return (-1, 1) }
        // Only a range whose *width* overflows needs help. Halving both ends
        // halves the width — both ends are finite here, so this always terminates
        // in one step — and leaves a genuinely huge but narrow range such as
        // [1.69e308, 1.71e308] exactly as the author asked for it.
        if isFiniteNumber(max - min) { return (min, max) }
        return (min / 2, max / 2)
    }

    private static func accessibleName(_ spec: Spec, _ labels: [String]) -> String {
        if !spec.title.isEmpty { return spec.title }
        if labels.isEmpty { return "Plot" }
        return "Plot of \(labels.joined(separator: ", "))"
    }

    private static func hasExplicitLabel(_ series: [Series]) -> Bool {
        for one in series where one.label != nil { return true }
        return false
    }

    private static func colour(_ index: Int) -> String {
        palette[index % palette.count]
    }

    /// An estimate of a string's width at `size` pixels, for the legend gutter
    /// only.
    ///
    /// 0.6 em per character is the usual approximation for a sans-serif face and
    /// needs no font metrics, which is what keeps this file free of the platform.
    /// It is used to reserve space, never to position anything, so an estimate
    /// that is a few pixels out costs a few pixels of gutter.
    private static func textWidth(_ text: String, _ size: Double) -> Double {
        Double(countCharacters(text)) * size * 0.6
    }

    /// Two margins that leave at least `minPlot` between them.
    ///
    /// Without this a 160 × 120 figure carrying a title, both axis labels and a
    /// legend would compute a negative plot area and draw itself inside out.
    private static func fitMargins(_ total: Double, _ low: Double,
                                   _ high: Double) -> (low: Double, high: Double) {
        if total - low - high >= minPlot { return (low, high) }
        let room = max(0, total - minPlot)
        let sum = low + high
        if sum <= 0 { return (0, 0) }
        let scaled = floor((room * low) / sum)
        return (scaled, room - scaled)
    }

    // MARK: - Axes

    /// A decade — 10 raised to `exponent` — read from a **decimal literal**,
    /// never from `pow`.
    ///
    /// `pow` is not correctly rounded and is not specified to be, so it differs
    /// by **runtime version** — the engine's, not the CPU's. For
    /// `rough = 9.999999999999999e-05` (bits `3f1a36e2eb1c432c`), `pow(10, -4)`
    /// is `3f1a36e2eb1c432d` under Darwin's libm and under Node 26, and one ULP
    /// *lower* under Node 20, which is what md.vscode's CI runs. Node 20 is
    /// wrong on arm64 and on x86-64 alike — 68 and 69 of the 632 integer
    /// exponents in [-323, 308] — so the architecture is not the variable; the
    /// V8 version is. A different decade gives a different `norm`, `norm`
    /// selects a branch of the 1/2/5/10 ladder, and a different branch is a
    /// different tick step — so the axis draws a different number of ticks with
    /// different labels and the figure's bytes change. This is not theoretical:
    /// it turned md.vscode's CI red on the pushed v1.2.0 (`fd71a4e`) with three
    /// failures in `test/plot.test.ts`, `tiny_range` among them and an
    /// `xLabels` length of 9, while every one of them passed on this Mac's
    /// Node 26.
    ///
    /// Parsing a decimal literal **is** specified to be correctly rounded, in
    /// all four ports alike — Swift's `Double(_: String)`, JavaScript's
    /// `Number()`, Kotlin's `toDouble()`, Rust's `parse()` — so every port reads
    /// the same double out of `"1e<e>"`. **`pow(10, e)` must never come back
    /// here.**
    ///
    /// The three non-finite answers are exactly what the old expression
    /// produced, and the oracle records all three: `pow(10, nan)` is nan,
    /// `pow(10, +inf)` is +inf, `pow(10, -inf)` is 0. They are also what keeps
    /// `Int(exponent)` — which traps on a value no `Int` can hold — safe.
    static func decade(_ exponent: Double) -> Double {
        if exponent.isNaN { return Double.nan }
        if exponent >= 309 { return Double.infinity }   // 1e309 overflows a Double
        if exponent <= -324 { return 0 }                // 1e-324 underflows to zero
        return Double("1e\(Int(exponent))") ?? Double.nan
    }

    /// The site's tick spacing, ported exactly — except that the decade comes
    /// from `decade(_:)` rather than `pow`, and the exponent is pinned by exact
    /// comparison rather than trusted from `log10`.
    ///
    /// ```
    /// rough = range / 8
    /// e     = floor(log10 rough)           // an approximation, nothing more
    /// if 10^e > rough           { e -= 1 } // pin it against exact powers
    /// else if 10^(e+1) <= rough { e += 1 }
    /// mag   = 10^e ; norm = rough / mag
    /// step  = (norm<=1.5 ? 1 : norm<=3 ? 2 : norm<=7 ? 5 : 10) * mag
    /// ```
    ///
    /// `log10` is not correctly rounded either, so its `floor` cannot be trusted
    /// at a decade boundary: `log10(9.999999999999999e-05)` is exactly `-4.0`
    /// here, one decade too high for a value that is below 1e-4. The two
    /// comparisons are what fix that, and they cost nothing — `niceStep` runs
    /// twice per figure and figures are memoised in `PlotMemo`, so two string
    /// parses per axis are free.
    static func niceStep(_ range: Double) -> Double {
        let rough = range / 8
        var exponent = floor(log10(rough))
        if decade(exponent) > rough {
            exponent -= 1
        } else if decade(exponent + 1) <= rough {
            exponent += 1
        }
        let magnitude = decade(exponent)
        let normalised = rough / magnitude
        var step = 10.0
        if normalised <= 1.5 { step = 1 } else if normalised <= 3 { step = 2 }
        else if normalised <= 7 { step = 5 }
        return step * magnitude
    }

    /// How far past `max` a tick may land and still be drawn: one part in 10⁹ of
    /// a step.
    private static let tickEpsilon = 1e-9
    /// A safety valve. `niceStep` gives eight to eleven ticks; a thousand is a bug.
    private static let maxTicks = 1000

    /// The ticks of one axis.
    ///
    /// **Computed by index, never accumulated.** The site does `gx += step`,
    /// which on `[-1, 1]` at step 0.2 reaches −5.55e−17 instead of 0 and prints
    /// the tick at the origin as "-5.6e-17". `first + i * step` lands on an exact
    /// zero wherever the arithmetic can, which is the whole fix.
    ///
    /// The epsilon is the other half of it: a tick that *is* the maximum can miss
    /// it by one ulp (`[0.0001, 0.0009]` at step 0.0001 computes
    /// 9.000000000000001e-4), and dropping the last tick of an axis because of a
    /// rounding error is a visible defect.
    static func ticks(_ min: Double, _ max: Double, _ step: Double) -> [Double] {
        var out: [Double] = []
        if !(step > 0) || !isFiniteNumber(step) { return out }
        let first = ceil(min / step) * step
        let limit = max + step * tickEpsilon
        for i in 0..<maxTicks {
            let tick = first + Double(i) * step
            if tick > limit { break }
            out.append(tick)
        }
        return out
    }

    /// A tick's label, ported from the site's `format_label` **with the two
    /// corrections its own output argues for**:
    ///
    /// ```
    /// v == 0                      -> "0"
    /// |v| >= 1000 or |v| < 0.01   -> exponential, one fraction digit
    /// |v - round(v)| < 1e-9       -> integer, ROUNDED (the site truncates)
    /// otherwise                   -> two fraction digits
    /// ```
    ///
    /// The site prints `val as i64`, which truncates: a tick at −4 that arrives
    /// as −3.9999999999999996 prints "-3", out of order, in the middle of the
    /// axis.
    static func formatLabel(_ v: Double) -> String {
        if v == 0 { return "0" }
        if v.isNaN { return formatFixed(v, 2) }
        let magnitude = Swift.abs(v)
        if magnitude >= 1000 || magnitude < 0.01 { return formatExponential(v, 1) }
        let rounded = roundTiesAway(v)
        if Swift.abs(v - rounded) < 1e-9 { return formatFixed(rounded, 0) }
        return formatFixed(v, 2)
    }

    // MARK: - Number formatting, by hand

    /// Significant digits taken from the *exact* binary value.
    ///
    /// Twenty-five is enough to decide any rounding this file performs, and the
    /// argument is worth writing down because every port depends on it. A double
    /// is a dyadic rational m/2^k; a decimal tie at the second significant digit
    /// (or at the second fraction digit) is a rational k/10^m with a small m. Two
    /// such numbers that are not equal differ by at least 1/(2^52 · 10^m) — about
    /// 10⁻¹⁸ relatively — which is a hundred million times larger than the 10⁻²⁵
    /// the last of these digits resolves. So a digit string that reads "…5000…0"
    /// here *is* an exact tie, and ties-to-even is safe to apply to it.
    ///
    /// Getting these digits is the one platform call that has to be right:
    ///
    ///   * Swift — `String(format: "%.24e", v)`; the C library converts exactly.
    ///   * TypeScript — `toExponential(24)`, which ECMA-262 defines as correctly
    ///     rounded from the exact value.
    ///   * Kotlin — `java.math.BigDecimal(v)`, which is exact by construction.
    private static let significantDigitCount = 25

    private static func significantDigits(_ value: Double) -> (digits: [Unicode.Scalar], exponent: Int) {
        // `String(format:)` is not localized (that is `String(format:locale:)`),
        // so the decimal separator is always `.` — but the exponent is C's, with
        // a sign and at least two digits, which is exactly the spelling this file
        // exists to avoid emitting. Only the digits are taken from it.
        let text = Array(String(format: "%.\(significantDigitCount - 1)e", value).unicodeScalars)
        var marker = 0
        while marker < text.count && text[marker] != "e" && text[marker] != "E" { marker += 1 }
        var digits: [Unicode.Scalar] = []
        for index in 0..<marker where text[index] != "." { digits.append(text[index]) }
        var index = marker + 1
        var negative = false
        if index < text.count && (text[index] == "+" || text[index] == "-") {
            negative = text[index] == "-"
            index += 1
        }
        var exponent = 0
        while index < text.count && isDigit(text[index]) {
            exponent = exponent * 10 + Int(text[index].value) - 48
            index += 1
        }
        return (digits, negative ? -exponent : exponent)
    }

    /// Rust's `{:.<n>e}` — `1.0e3`, `-5.0e-3`, `4.9e-324`.
    ///
    /// No `+` on the exponent and no zero padding (C and Java write `1.0e+03`),
    /// and ties round to even on the exact value (`String(format: "%.1e", 1250)`
    /// rounds up to `1.3e+03`, where Rust writes `1.2e3`).
    static func formatExponential(_ v: Double, _ fractionDigits: Int) -> String {
        if v.isNaN { return "NaN" }
        if v == Double.infinity { return "inf" }
        if v == -Double.infinity { return "-inf" }
        let sign = isNegative(v) ? "-" : ""
        let magnitude = Swift.abs(v)
        if magnitude == 0 {
            return "\(sign)0\(fractionDigits > 0 ? "." + string(zeros(fractionDigits)) : "")e0"
        }
        let scanned = significantDigits(magnitude)
        let rounded = roundDigits(scanned.digits, fractionDigits + 1)
        let exponent = scanned.exponent + (rounded.overflow ? 1 : 0)
        let digits = rounded.digits
        let fraction = fractionDigits > 0 ? "." + string(slice(digits, 1, digits.count)) : ""
        return "\(sign)\(string([digits[0]]))\(fraction)e\(exponent)"
    }

    /// Rust's `{:.<n>}` — `2.50`, `-0.00`, `1000.00`.
    ///
    /// Ties to even on the exact value: 0.125 is `0.12` and 8.125 is `8.12`,
    /// where C's `%.2f` writes `0.13` and `8.13`. The sign survives a
    /// rounded-away zero (`-0.00`), which is what Rust prints and what keeps the
    /// two comparable.
    static func formatFixed(_ v: Double, _ fractionDigits: Int) -> String {
        if v.isNaN { return "NaN" }
        if v == Double.infinity { return "inf" }
        if v == -Double.infinity { return "-inf" }
        let sign = isNegative(v) ? "-" : ""
        let magnitude = Swift.abs(v)

        var whole: [Unicode.Scalar] = ["0"]
        var fraction: [Unicode.Scalar] = []
        if magnitude != 0 {
            let scanned = significantDigits(magnitude)
            let wholeLength = scanned.exponent + 1
            if wholeLength <= 0 {
                fraction = zeros(-wholeLength) + scanned.digits
            } else if wholeLength >= scanned.digits.count {
                whole = scanned.digits + zeros(wholeLength - scanned.digits.count)
            } else {
                whole = slice(scanned.digits, 0, wholeLength)
                fraction = slice(scanned.digits, wholeLength, scanned.digits.count)
            }
        }

        if fraction.count <= fractionDigits {
            fraction += zeros(fractionDigits - fraction.count)
        } else {
            let kept = slice(fraction, 0, fractionDigits)
            let next = Int(fraction[fractionDigits].value) - 48
            var up = next > 5
            if next == 5 {
                var more = false
                for index in (fractionDigits + 1)..<fraction.count where fraction[index] != "0" {
                    more = true
                    break
                }
                if more {
                    up = true
                } else {
                    let previous =
                        fractionDigits > 0
                        ? Int(fraction[fractionDigits - 1].value) - 48
                        : Int(whole[whole.count - 1].value) - 48
                    up = previous % 2 == 1
                }
            }
            if !up {
                fraction = kept
            } else {
                let carried = increment(kept)
                if carried.overflow {
                    // `.99` + 1 is `1.00`: the fraction goes back to zeros and the
                    // carry lands on the integer part, which is the one place a
                    // digit string is allowed to grow (999 -> 1000).
                    fraction = zeros(fractionDigits)
                    whole = increment(whole).digits
                } else {
                    fraction = carried.digits
                }
            }
        }

        return "\(sign)\(string(whole))\(fractionDigits > 0 ? "." + string(fraction) : "")"
    }

    /// `formatFixed`, for the coordinates the emitter writes.
    private static func fixed(_ v: Double, _ fractionDigits: Int) -> String {
        formatFixed(v, fractionDigits)
    }

    /// Round a digit string to `keep` digits, ties to even, reporting whether the
    /// carry ran off the front — in which case the digits are `1` followed by
    /// zeros and the caller owes the exponent a 1.
    private static func roundDigits(_ digits: [Unicode.Scalar],
                                    _ keep: Int) -> (digits: [Unicode.Scalar], overflow: Bool) {
        if keep >= digits.count { return (digits + zeros(keep - digits.count), false) }
        let kept = slice(digits, 0, keep)
        let next = Int(digits[keep].value) - 48
        var up = next > 5
        if next == 5 {
            var more = false
            for index in (keep + 1)..<digits.count where digits[index] != "0" {
                more = true
                break
            }
            if more { up = true } else { up = (Int(digits[keep - 1].value) - 48) % 2 == 1 }
        }
        if !up { return (kept, false) }
        let carried = increment(kept)
        if !carried.overflow { return (carried.digits, false) }
        // "999" + 1 is "1000"; renormalised to `keep` digits that is "100" one
        // decimal place further left.
        return ([Unicode.Scalar]("1".unicodeScalars) + zeros(keep - 1), true)
    }

    /// `digits` + 1, keeping the length; `overflow` says the carry ran off the
    /// front.
    private static func increment(_ digits: [Unicode.Scalar]) -> (digits: [Unicode.Scalar], overflow: Bool) {
        var out = digits
        var index = out.count - 1
        while index >= 0 {
            if out[index] == "9" {
                out[index] = "0"
                index -= 1
            } else {
                out[index] = Unicode.Scalar(out[index].value + 1)!
                return (out, false)
            }
        }
        return ([Unicode.Scalar]("1".unicodeScalars) + out, true)
    }

    /// Rust's `f64::round`: halfway cases go away from zero.
    ///
    /// Not `.rounded()` (which is ties-away too, but is a different call in every
    /// port) written as the `floor(v + 0.5)` trick, which sends
    /// 0.49999999999999994 to 1.
    private static func roundTiesAway(_ v: Double) -> Double {
        let whole = v.rounded(.towardZero)
        let fraction = v - whole
        if fraction >= 0.5 { return whole + 1 }
        if fraction <= -0.5 { return whole - 1 }
        return whole
    }

    private static func isNegative(_ v: Double) -> Bool {
        v < 0 || (v == 0 && 1 / v < 0)
    }

    private static func zeros(_ count: Int) -> [Unicode.Scalar] {
        count > 0 ? [Unicode.Scalar](repeating: "0", count: count) : []
    }

    // MARK: - Markup

    /// Four of the five predefined XML entities — `&amp;` `&lt;` `&gt;`
    /// `&quot;` — and never anything else, in particular never a named entity
    /// like `&nbsp;`, which is undefined in XML.
    ///
    /// `&apos;` is the fifth and is deliberately not emitted: a bare `'` is
    /// well-formed in both XML text and a double-quoted attribute value, which
    /// is the only kind this renderer writes. That is also byte for byte what
    /// the reference does (`md.vscode/src/render/inline.ts` `escapeHTML`, four
    /// `replaceAll`s), and byte parity with it is the whole point of this file
    /// — so this is a comment to keep accurate, not a fifth case to add.
    ///
    /// The EPUB body is XHTML, i.e. XML: one raw `&` or `<` in a title, an axis
    /// label or a legend label makes the whole content document unparseable and
    /// the book unopenable. Scalar by scalar, for the reason `ScalarText`
    /// exists: `"&\u{0301}"` does not *contain* `&` as a `Character`, and a
    /// grapheme-based replacement would let it through.
    private static func escapeHTML(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out.append(contentsOf: "&amp;".unicodeScalars)
            case "<": out.append(contentsOf: "&lt;".unicodeScalars)
            case ">": out.append(contentsOf: "&gt;".unicodeScalars)
            case "\"": out.append(contentsOf: "&quot;".unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    // MARK: - Small string helpers
    //
    // Written out rather than reached for, because the four ports have four
    // different ideas of what `trim` and `split` mean and the differences are
    // exactly the kind that survive a code review.

    private static func isSpace(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t"
    }

    private static func isDigit(_ c: Unicode.Scalar) -> Bool {
        c >= "0" && c <= "9"
    }

    private static func isLowerLetter(_ c: Unicode.Scalar) -> Bool {
        c >= "a" && c <= "z"
    }

    private static func isIdentifierStart(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_"
    }

    private static func isIdentifierPart(_ c: Unicode.Scalar) -> Bool {
        isIdentifierStart(c) || isDigit(c)
    }

    private static func isFiniteNumber(_ v: Double) -> Bool {
        !v.isNaN && v != Double.infinity && v != -Double.infinity
    }

    private static func trim(_ text: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var start = 0
        var end = text.count
        while start < end && isSpace(text[start]) { start += 1 }
        while end > start && isSpace(text[end - 1]) { end -= 1 }
        return slice(text, start, end)
    }

    private static func lowercased(_ text: [Unicode.Scalar]) -> String {
        // The locale-independent one, never a locale-aware lowercase: a Turkish
        // locale spells `AUTO` with a dotless ı and the directive would stop
        // matching. Swift's `lowercased()` is the Unicode default casing, which
        // is what `toLowerCase` and `lowercase(Locale.ROOT)` are in the siblings.
        string(text).lowercased()
    }

    /// Lines, on CRLF, LF or CR — the parser's own set, not the wide Unicode one.
    private static func splitLines(_ source: String) -> [[Unicode.Scalar]] {
        var out: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        let scalars = Array(source.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let c = scalars[index]
            if c == "\n" {
                out.append(current)
                current = []
            } else if c == "\r" {
                out.append(current)
                current = []
                if index + 1 < scalars.count && scalars[index + 1] == "\n" { index += 1 }
            } else {
                current.append(c)
            }
            index += 1
        }
        out.append(current)
        return out
    }

    private static func splitWhitespace(_ text: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
        var out: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        for index in 0..<text.count {
            let c = text[index]
            if isSpace(c) {
                if !current.isEmpty { out.append(current) }
                current = []
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func contains(_ list: [String], _ value: String) -> Bool {
        for one in list where one == value { return true }
        return false
    }

    /// The index of the first `first``second` pair, or −1.
    private static func indexOfPair(_ text: [Unicode.Scalar], _ first: Unicode.Scalar,
                                    _ second: Unicode.Scalar) -> Int {
        var index = 0
        while index + 1 < text.count {
            if text[index] == first && text[index + 1] == second { return index }
            index += 1
        }
        return -1
    }

    /// The index of the first `needle`, or −1.
    private static func indexOf(_ text: [Unicode.Scalar], _ needle: Unicode.Scalar) -> Int {
        for index in 0..<text.count where text[index] == needle { return index }
        return -1
    }

    /// The index of the `)` matching the `(` at `open`, or −1.
    private static func matchingParenthesis(_ text: [Unicode.Scalar], _ open: Int) -> Int {
        var depth = 0
        for index in open..<text.count {
            let c = text[index]
            if c == "(" { depth += 1 } else if c == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return -1
    }

    /// The index of the first comma at parenthesis depth 0, or −1.
    private static func topLevelComma(_ text: [Unicode.Scalar]) -> Int {
        var depth = 0
        for index in 0..<text.count {
            let c = text[index]
            if c == "(" { depth += 1 } else if c == ")" { depth -= 1 } else if c == "," && depth == 0 {
                return index
            }
        }
        return -1
    }

    /// Does `text` begin with `word` as a whole word?
    private static func startsWithWord(_ text: [Unicode.Scalar], _ word: String) -> Bool {
        let wanted = Array(word.unicodeScalars)
        if text.count < wanted.count { return false }
        for index in 0..<wanted.count where text[index] != wanted[index] { return false }
        if text.count == wanted.count { return true }
        return !isIdentifierPart(text[wanted.count])
    }

    /// The characters of a label, for the legend gutter.
    ///
    /// Scalars, not `Character`s: the TypeScript reference counts code points
    /// (`for (const _ of text)`), so counting scalars here is what makes the two
    /// reserve the same gutter for the same label — a family emoji is five in
    /// both, where Swift's grapheme count would say one and put the ports a few
    /// pixels apart.
    private static func countCharacters(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    // MARK: Scalar slices

    private static func slice(_ s: [Unicode.Scalar], _ from: Int, _ to: Int) -> [Unicode.Scalar] {
        guard to > from else { return [] }
        return Array(s[from..<to])
    }

    private static func string(_ scalars: [Unicode.Scalar]) -> String {
        ScalarText.string(scalars)
    }
}
