//
//  MarkdownWebView.swift
//  md
//
//  The live preview pane. Renders the same themed HTML that print / PDF /
//  "share rendered" produce (`MarkdownHTML.document`) inside a `WKWebView`,
//  so the preview is pixel-identical to the exported document and gains the
//  rich renderers — LaTeX math (KaTeX), Mermaid, PlantUML — that run from
//  bundled assets under `rich/`.
//
//  Everything is offline. A `WKURLSchemeHandler` serves the app HTML and the
//  bundled `rich/` assets under a private `mdassets://` origin; that real
//  origin (rather than `file://`) is what lets `md-init.js`'s ES-module
//  `import` of the PlantUML engine resolve. No network is ever touched.
//

import SwiftUI
import UIKit
import WebKit

// MARK: - Asset scheme handler

/// Serves the current preview HTML (`index.html`) and every bundled `rich/`
/// asset over the private `mdassets://` scheme. Shared verbatim with md.macOS.
final class MdAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "mdassets"
    static let indexURL = URL(string: "mdassets://md/index.html")!

    /// The document HTML to serve for `index.html`. Updated then the web view
    /// is (re)loaded to show it.
    var html: String = ""

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL)); return
        }
        let path = url.path

        if path.isEmpty || path == "/" || path == "/index.html" {
            respond(task, url: url, data: Data(html.utf8), mime: "text/html")
            return
        }

        // A bundled asset, e.g. /rich/plantuml.js or /rich/fonts/KaTeX_Main.woff2.
        guard let root = Bundle.main.resourceURL?.standardizedFileURL else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let fileURL = root.appendingPathComponent(rel).standardizedFileURL
        // Constrain to the bundle's resource directory — no path traversal.
        // Memory-map so serving the multi-MB engines (plantuml.js is ~7 MB)
        // doesn't read the whole file into the heap on the main thread.
        guard fileURL.path.hasPrefix(root.path + "/"),
              let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            respond(task, url: url, data: Data(), mime: "application/octet-stream", status: 404)
            return
        }
        respond(task, url: url, data: data, mime: Self.mime(for: fileURL.pathExtension))
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String, status: Int = 200) {
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// Correct MIME types matter: a JS module served as octet-stream is
    /// rejected by the module loader, and fonts/CSS need their real types.
    static func mime(for ext: String) -> String {
        switch ext.lowercased() {
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "html": return "text/html"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Render-complete bridge

/// Carries md-init.js's "every engine has finished" message
/// (`notifyComplete()`, which posts to `mdRender` and sets
/// `data-md-render-complete`) through to the preview coordinator.
///
/// Its own object, holding the coordinator weakly, because a
/// `WKUserContentController` *retains* the handlers registered on it:
/// registering the coordinator itself would close the cycle coordinator →
/// web view → content controller → coordinator, and the pane would outlive
/// every document it was ever shown in.
private final class RenderCompleteRelay: NSObject, WKScriptMessageHandler {
    weak var coordinator: PreviewWebView.Coordinator?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        coordinator?.renderDidComplete()
    }
}

// MARK: - Preview navigation

/// A one-shot "scroll the preview to this heading" request, driven by the
/// table-of-contents menu. Each request carries a fresh `id` so tapping the
/// same heading twice still re-fires (plain value equality would swallow the
/// repeat — the coordinator compares ids, not slugs).
struct PreviewNavigation: Equatable {
    let id: UUID
    let slug: String
}

// MARK: - SwiftUI preview

/// Whether the preview has stopped trying to come back — see
/// `PreviewRetryPolicy`. Observable so that the pane can put one line where
/// the page would be; nothing else about the web view is SwiftUI state.
///
/// It belongs to the *document*, not to the pane: `DocumentView` owns one
/// and hands it to every preview it builds. The pane leaves the hierarchy
/// whenever the writer switches to Edit (and is rebuilt between Split and
/// Preview), and a policy kept in the pane's coordinator went with it — so a
/// preview that had given up came straight back on the next visit and cost
/// two more content-process deaths for a document that had not changed.
/// Found 2026-09-27 while bringing md.Android to the rule this file was
/// believed to follow already.
@MainActor
final class PreviewStatus: ObservableObject {
    @Published var contentProcessGaveUp = false
    /// The retry policy for this document's preview. Not `@Published`: the
    /// coordinator changes it from inside `updateUIView`, where publishing is
    /// not allowed, and nothing on screen reads it directly.
    var retry = PreviewRetryPolicy()
    /// The rendered document (the coordinator's text/title/theme key) the
    /// last pane showed. A pane built again for the same key is a mode switch,
    /// not an edit, and must not lift a give-up.
    var shownKey: String?
}

/// The preview pane: the web view, plus the one line that takes its place
/// when WebKit's content process has died twice in a row.
struct MarkdownWebView: View {
    let text: String
    let title: String
    /// The latest table-of-contents jump request, if any. Handled once per
    /// `id` by the coordinator; `nil` while no jump has been asked for.
    var navigation: PreviewNavigation?
    /// The Split layout's pane link (see `ScrollSync`): the preview
    /// reports the scrolls the user's finger makes and follows the
    /// editor's.
    var scrollSync: ScrollSync? = nil
    /// The document's preview state, owned by the caller so it outlives
    /// this pane (see `PreviewStatus`).
    @ObservedObject var status: PreviewStatus

    var body: some View {
        PreviewWebView(text: text, title: title, navigation: navigation,
                       scrollSync: scrollSync, status: status)
            .overlay {
                if status.contentProcessGaveUp { notice }
            }
    }

    /// One quiet line, on the paper the pane is already made of — not an
    /// alert, not a retry button, and no diagnostics: a preview that has
    /// given up says so once and gets out of the way. The next edit reloads
    /// it (see `PreviewRetryPolicy`), so the sentence is also the
    /// instruction.
    private var notice: some View {
        Text("The preview stopped twice in a row — it comes back as soon as you edit the document.")
            .font(Typewriter.font(12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Typewriter.paper)
    }
}

/// The web view itself. Split out from `MarkdownWebView` so the pane can
/// hold something else in front of it; the coordinator is where all of the
/// preview's behaviour lives, and a test can build one on its own.
struct PreviewWebView: UIViewRepresentable {
    let text: String
    let title: String
    var navigation: PreviewNavigation?
    var scrollSync: ScrollSync?
    let status: PreviewStatus
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(status: status) }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.update(text: text, title: title, dark: colorScheme == .dark)
        context.coordinator.attach(scrollSync)
        // A request left over from a previous incarnation of the preview
        // (mode switched away and back) is stale: adopt it as handled rather
        // than scrolling a page that hasn't even loaded yet.
        context.coordinator.adopt(navigation)
        return context.coordinator.webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(text: text, title: title, dark: colorScheme == .dark)
        context.coordinator.attach(scrollSync)
        context.coordinator.navigate(to: navigation)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
        /// The name md-init.js posts its "render complete" message under —
        /// shared verbatim with md.macOS and with `md-init.js` itself.
        static let renderMessageName = "mdRender"

        let webView: WKWebView
        private let assets = MdAssetSchemeHandler()
        /// The preview's own content controller. Kept here rather than
        /// reached for through `webView.configuration`, which vends a copy:
        /// this is the object the page's messages actually arrive on.
        private let content = WKUserContentController()
        private let renderRelay = RenderCompleteRelay()
        private var loadedOnce = false
        private var lastKey: String?
        private var savedScrollY: Double = 0
        private var pending: DispatchWorkItem?
        /// The last `PreviewNavigation.id` acted on (or adopted), so each
        /// request scrolls exactly once however many times SwiftUI calls
        /// `updateUIView` afterwards.
        private var lastNavigationID: UUID?

        /// The Split layout's pane link, when this preview is half of one.
        private var scrollSync: ScrollSync?

        /// What to do when the web content process dies (see
        /// `PreviewRetryPolicy`), and where to say it has stopped trying.
        private let status: PreviewStatus
        /// The document's policy, kept on the status so that it outlives
        /// this coordinator (see `PreviewStatus`).
        private var retry: PreviewRetryPolicy {
            get { status.retry }
            set { status.retry = newValue }
        }

        /// Read by tests: the policy's current state, without reaching into
        /// WebKit to produce it.
        var retryPolicy: PreviewRetryPolicy { retry }

        /// How many times the page has reported finishing its render. The
        /// policy alone cannot witness the bridge — a page that renders
        /// when nothing ever died leaves the count at zero either way — so
        /// this is what a test watches to know md-init.js's message really
        /// arrives.
        private(set) var renderCompletions = 0

        init(status: PreviewStatus) {
            self.status = status
            let config = WKWebViewConfiguration()
            config.setURLSchemeHandler(assets, forURLScheme: MdAssetSchemeHandler.scheme)
            config.userContentController = content
            webView = WKWebView(frame: .zero, configuration: config)
            super.init()
            // Listen for md-init.js's render-complete message. Without this
            // the preview has no way to tell a page that merely loaded from
            // one that survived its diagrams — see `renderDidComplete()`.
            renderRelay.coordinator = self
            content.add(renderRelay, name: Self.renderMessageName)
            webView.navigationDelegate = self
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            // The preview's half of the scroll sync is fully native: the
            // web view's scroll view reports the user's scrolls below.
            webView.scrollView.delegate = self
        }

        /// (Re-)hand the sync our "follow the editor" closure — from make
        /// and update, so pane recreation always leaves the live
        /// coordinator registered.
        @MainActor func attach(_ sync: ScrollSync?) {
            scrollSync = sync
            sync?.scrollPreview = { [weak self] fraction in
                self?.webView.scrollView.syncScroll(toFraction: fraction)
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // Only the reader's finger is reported — anchor jumps, reload
            // restores and the sync's own relays are all programmatic and
            // fall through the gate.
            guard scrollView.isUserScrolling, let fraction = scrollView.syncFraction else { return }
            scrollSync?.previewDidScroll(to: fraction)
        }

        /// Re-render when the text, title, or theme changes. The first render
        /// loads immediately; later ones debounce so live typing in Split mode
        /// doesn't reload (and re-run the diagram engines) on every keystroke.
        func update(text: String, title: String, dark: Bool) {
            let key = "\(dark)|\(title)|\(text)"
            guard key != lastKey else { return }
            lastKey = key
            assets.html = MarkdownHTML.document(text, title: title, dark: dark)
            pending?.cancel()
            // A changed document is worth trying: what would be loaded now
            // is not what died, so the pane stops having given up. It does
            // not clear the *count* — this runs on every keystroke in
            // Split, and see `PreviewRetryPolicy` — so an edit buys one
            // more attempt rather than an endless supply. If the pane
            // *had* given up, the page is loaded at once: there is no live
            // page left to debounce a reload of, and the reader has just
            // been told that editing brings it back.
            //
            // The notice itself is deliberately not touched here: this runs
            // from `updateUIView`, inside a SwiftUI update, where
            // publishing a change is not allowed. It goes when the page is
            // actually back — `didFinish`, below — which is also the
            // honest moment for it to go.
            // A new pane for the document the last one showed — the writer
            // switched to Edit and back, or between Split and Preview — is
            // not an edit. If that document made the preview give up, the
            // notice stays and nothing is loaded; otherwise the new pane
            // simply loads it.
            let changed = key != status.shownKey
            status.shownKey = key
            if !changed {
                if retry.hasGivenUp { return }
                if !loadedOnce {
                    loadedOnce = true
                    webView.load(URLRequest(url: MdAssetSchemeHandler.indexURL))
                }
                return
            }
            let recovering = retry.hasGivenUp
            _ = retry.handle(.documentChanged)
            if !loadedOnce || recovering {
                loadedOnce = true
                webView.load(URLRequest(url: MdAssetSchemeHandler.indexURL))
            } else {
                let work = DispatchWorkItem { [weak self] in self?.reloadPreservingScroll() }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            }
        }

        /// Mark a navigation request as already handled *without* scrolling —
        /// used at web-view creation, where the document hasn't loaded yet.
        func adopt(_ navigation: PreviewNavigation?) {
            lastNavigationID = navigation?.id
        }

        /// Scroll the rendered document to a heading's anchor — the HTML
        /// gives every top-level heading `id="<slug>"` (see MarkdownHTML).
        /// Runs once per request id.
        func navigate(to navigation: PreviewNavigation?) {
            guard let navigation, navigation.id != lastNavigationID else { return }
            lastNavigationID = navigation.id
            // Slugs contain only letters, digits, `-` and `_` (see
            // `MarkdownParser.slug`) — never quotes, backslashes or tag
            // characters — so plain interpolation can't break out of the JS
            // string literal; no escaping needed.
            webView.evaluateJavaScript(
                "document.getElementById('\(navigation.slug)')?.scrollIntoView(true)",
                completionHandler: nil)
        }

        private func reloadPreservingScroll() {
            webView.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
                self?.savedScrollY = (value as? Double) ?? 0
                self?.webView.reload()
            }
        }

        /// md-init.js has run every renderer the document asked for and
        /// said so (`notifyComplete()`). *This* is the page surviving its
        /// own render, and the only thing that ends a run of
        /// content-process failures.
        ///
        /// `didFinish` cannot stand in for it. md-init.js is a deferred
        /// module whose `run()` is registered on the load event, and its
        /// work — Mermaid, Graphviz, and a dynamic `import` of the 7 MB
        /// PlantUML engine — is all `await`ed after that. Every death this
        /// policy exists for (an iPad under memory pressure, a layout that
        /// eats the process) therefore lands *after* the navigation
        /// finished; crediting a finished navigation as a render would zero
        /// the count on every cycle and the pane would reload for ever.
        /// The print/PDF path draws the same line from the other side —
        /// `WebRenderer.waitForRenderComplete()` polls the attribute this
        /// same call sets.
        func renderDidComplete() {
            renderCompletions += 1
            _ = retry.handle(.rendered)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // A page on screen is the moment the notice has stopped being
            // true — it is not yet the moment the page has survived (see
            // `renderDidComplete()`), but the reader can see a document
            // again and the line would be a lie. A navigation callback is
            // not a SwiftUI update, so the change can go from here — but
            // only when the line is actually up: every reload in the app's
            // life ends here, and a `@Published` write re-renders whether
            // or not the value changed.
            if status.contentProcessGaveUp { status.contentProcessGaveUp = false }
            guard savedScrollY > 0 else { return }
            webView.evaluateJavaScript("window.scrollTo(0, \(savedScrollY))", completionHandler: nil)
        }

        /// WebKit's content process died and took the page with it — memory
        /// pressure, a WebView update, or a diagram engine that ran the
        /// process out of room. The pane is blank until something loads
        /// again, and nothing will unless we ask.
        ///
        /// The ask is bounded (`PreviewRetryPolicy`): the second failure in
        /// a row shows one line instead of reloading, because a document
        /// whose render kills the process will kill it again.
        ///
        /// The reload is a fresh `load`, not `reloadPreservingScroll()`:
        /// that one asks the page for `window.scrollY` first, and the page
        /// it would ask is the one that just died. Windows recovers the
        /// same way — see `OnCoreProcessFailed` in md.win's `PreviewHost`,
        /// whose comment also explains why "unresponsive" is not handled
        /// here at all: a slow PlantUML render is indistinguishable from
        /// it, and reloading would kill the render that caused it.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            switch retry.handle(.terminated) {
            case .reload:
                // Whatever scroll position was remembered belongs to a page
                // that no longer exists.
                savedScrollY = 0
                pending?.cancel()
                webView.load(URLRequest(url: MdAssetSchemeHandler.indexURL))
            case .giveUp:
                pending?.cancel()
                status.contentProcessGaveUp = true
            case .none:
                break
            }
        }

        // A tapped link never *navigates* the preview itself: in-document
        // anchors scroll it, http/https open in the browser, and everything
        // else (javascript:, data:, file:, …) is simply cancelled — so a
        // malicious `[x](javascript:…)` link can't run in this
        // network-capable WebView. Internal loads/reloads are `.other` and pass.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                let url = navigationAction.request.url
                // In-document anchor hops — `[…](#section)` onto the
                // GitHub-style heading ids the renderer emits — resolve to
                // our own `mdassets://…#fragment` origin; allowing them just
                // scrolls the page (WebKit treats a fragment-only hop as
                // same-document, nothing reloads).
                if let url, url.scheme == MdAssetSchemeHandler.scheme, url.fragment != nil {
                    decisionHandler(.allow)
                    return
                }
                if let url, url.scheme == "http" || url.scheme == "https" {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
