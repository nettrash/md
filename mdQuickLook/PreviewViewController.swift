//
//  PreviewViewController.swift
//  mdQuickLook
//
//  md's Quick Look preview: a tap in Files, a peek in Mail, a preview in
//  any app that asks Quick Look for one, shows a Markdown, PlantUML, Graphviz
//  or TextBundle file as md renders it — the app's own `MarkdownHTML`, the
//  app's own engines — instead of as plain text.
//
//  The engines are not copied into the extension: it serves `rich/` from the
//  containing md.app, two folders up, so the app's size does not grow by the
//  ten megabytes they weigh. Mermaid and PlantUML are not loaded at all (see
//  `QuickLookPage`). And it reaches no network: a content rule blocks every
//  http and https load, so a remote image in the document stays a gap rather
//  than a request made on the reader's behalf by a preview they only glanced
//  at.
//

import QuickLook
import UIKit
import WebKit
import os

/// What the extension did, for Console: a preview that silently falls back
/// to the system's generic card is otherwise indistinguishable from one that
/// was never asked.
private let log = Logger(subsystem: "me.nettrash.md", category: "quicklook")

final class PreviewViewController: UIViewController, QLPreviewingController {

    private let assets = QuickLookAssetHandler()
    private var webView: WKWebView?
    private var pending: ((Error?) -> Void)?

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let source = Self.source(of: url) else {
            log.error("no text in \(url.lastPathComponent, privacy: .public)")
            handler(CocoaError(.fileReadCorruptFile))
            return
        }
        log.notice("preview \(url.lastPathComponent, privacy: .public): \(source.utf16.count, privacy: .public) units")
        let title = url.deletingPathExtension().lastPathComponent
        let dark = traitCollection.userInterfaceStyle == .dark
        assets.html = QuickLookPage.adapt(MarkdownHTML.document(source, title: title, dark: dark))
        pending = handler

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "md.quicklook.offline",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        ) { [weak self] rules, error in
            if let error { log.error("offline rule: \(error.localizedDescription, privacy: .public)") }
            DispatchQueue.main.async { self?.show(rules: rules) }
        }
    }

    private func show(rules: WKContentRuleList?) {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(assets, forURLScheme: QuickLookAssetHandler.scheme)
        // Without the offline rule the page is not shown: a preview that
        // might reach the network is not one this extension makes.
        guard let rules else {
            finish(CocoaError(.featureUnsupported))
            return
        }
        configuration.userContentController.add(rules)
        let webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        view.addSubview(webView)
        self.webView = webView
        webView.load(URLRequest(url: QuickLookAssetHandler.indexURL))
        // Quick Look should not wait on a page that never finishes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.finish(nil) }
    }

    private func finish(_ error: Error?) {
        guard let pending else { return }
        log.notice("finished: \(error?.localizedDescription ?? "ok", privacy: .public)")
        self.pending = nil
        pending(error)
    }

    /// The Markdown a file holds: a `.textbundle` folder's `text.md`, a
    /// `.textpack`'s, or the file itself decoded as the app decodes it.
    static func source(of url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            guard let wrapper = try? FileWrapper(url: url, options: .immediate) else { return nil }
            return TextBundle.textFromBundle(wrapper)?.0
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        if url.pathExtension.lowercased() == "textpack" {
            return TextBundle.textFromPack(data)?.0
        }
        return MarkdownDocument.decode(data)?.0
    }
}

extension PreviewViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) { finish(error) }

    /// Links do nothing inside a preview: an in-page anchor scrolls, and
    /// anything else is not the preview's to open.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let isOwn = action.request.url?.scheme == QuickLookAssetHandler.scheme
        decisionHandler(isOwn ? .allow : .cancel)
    }
}

/// Serves the page and the containing app's `rich/` assets over a private
/// `mdassets://` origin — the app's own arrangement (`MdAssetSchemeHandler`),
/// which is what lets `md-init.js`'s module imports resolve — reading from
/// md.app rather than from the extension's own bundle.
final class QuickLookAssetHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "mdassets"
    static let indexURL = URL(string: "mdassets://md/index.html")!

    var html = ""

    /// md.app, two folders above this extension (`md.app/PlugIns/mdQuickLook.appex`).
    private static let root: URL? = {
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: app.appendingPathComponent("rich").path) {
            return app.standardizedFileURL
        }
        return Bundle.main.resourceURL?.standardizedFileURL
    }()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        let path = url.path
        if path.isEmpty || path == "/" || path == "/index.html" {
            respond(task, url: url, data: Data(html.utf8), mime: "text/html")
            return
        }
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        // Only `rich/`, and nothing that climbs out of it.
        guard relative.hasPrefix("rich/"), let root = Self.root else {
            respond(task, url: url, data: Data(), mime: "application/octet-stream", status: 404)
            return
        }
        let file = root.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(root.appendingPathComponent("rich").path + "/"),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            respond(task, url: url, data: Data(), mime: "application/octet-stream", status: 404)
            return
        }
        respond(task, url: url, data: data, mime: Self.mime(for: file.pathExtension))
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String, status: Int = 200) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    static func mime(for ext: String) -> String {
        switch ext.lowercased() {
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }
}
