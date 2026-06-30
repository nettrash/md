//
//  DocumentExport.swift
//  md
//
//  Created by nettrash on 28/06/2026.
//
//  Print, "share rendered PDF" and "share source" — the document's output
//  paths.
//
//  Rendering goes through an offscreen `WKWebView` rather than
//  `UIMarkupTextPrintFormatter`. WebKit honors the full typewriter CSS,
//  including the paper background, in both the PDF and the printed page —
//  the markup formatter drops backgrounds, which would lose the chosen
//  theme (and make dark mode's cream ink invisible on white). The CSS sets
//  `print-color-adjust: exact` so those backgrounds actually render.
//
//  Presentation is done imperatively against the active scene's window:
//  share sheets and the print panel need correct popover anchoring on iPad,
//  which is fiddly to thread through a SwiftUI `ShareLink`/`fileExporter`
//  when the artifact (a freshly rendered PDF) has to be produced on demand
//  first.
//

import UIKit
import WebKit
import os

/// Trace for the in-app rename, so a rename failure is visible in Console
/// (filter by subsystem `me.nettrash.md`, category `rename`).
private let renameLog = Logger(subsystem: "me.nettrash.md", category: "rename")

/// Loads themed HTML into an offscreen web view, then yields a PDF or a
/// print formatter once layout has settled. Hold a strong reference for the
/// duration of the operation — the print formatter keeps using the web view.
@MainActor
final class WebRenderer: NSObject, WKNavigationDelegate {
    /// A4 at 72 dpi, in points — the page the PDF and print job target.
    static let pageSize = CGSize(width: 595, height: 842)

    private let webView: WKWebView
    private var onReady: ((Result<Void, Error>) -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: CGRect(origin: .zero, size: WebRenderer.pageSize),
                            configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    /// Load `html` and resume when the web view reports the load finished.
    func load(html: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            onReady = { continuation.resume(with: $0) }
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func makePDF() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                continuation.resume(with: result)
            }
        }
    }

    func printFormatter() -> UIPrintFormatter { webView.viewPrintFormatter() }

    // WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onReady?(.success(())); onReady = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onReady?(.failure(error)); onReady = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onReady?(.failure(error)); onReady = nil
    }
}

/// The three document output actions, presented against the active window.
@MainActor
enum DocumentExport {

    /// Print the rendered document, themed to match the current appearance.
    static func print(source: String, title: String, dark: Bool) async {
        let html = MarkdownHTML.document(source, title: title, dark: dark)
        let renderer = WebRenderer()
        do {
            try await renderer.load(html: html)
            let controller = UIPrintInteractionController.shared
            let info = UIPrintInfo.printInfo()
            info.outputType = .general
            info.jobName = title
            controller.printInfo = info
            controller.printFormatter = renderer.printFormatter()
            // Awaiting the presentation keeps `renderer` (and its web view,
            // which the formatter is still reading) alive until printing ends.
            await presentPrint(controller)
        } catch {
            // Rendering failed (malformed HTML is essentially impossible here);
            // nothing actionable to surface to the user.
        }
        withExtendedLifetime(renderer) {}
    }

    /// Render the document to a PDF and offer it through the share sheet.
    static func sharePDF(source: String, title: String, dark: Bool) async {
        let html = MarkdownHTML.document(source, title: title, dark: dark)
        let renderer = WebRenderer()
        do {
            try await renderer.load(html: html)
            let data = try await renderer.makePDF()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(sanitized(title)).pdf")
            try data.write(to: url, options: .atomic)
            presentShare(items: [url])
        } catch {
            // Couldn't produce the PDF; leave the UI untouched.
        }
        withExtendedLifetime(renderer) {}
    }

    /// Rename the document's file *in place*, keeping it in its real folder.
    /// This is the app's own rename: `DocumentGroup` gives no in-editor rename
    /// on iOS / iPadOS (you'd otherwise have to leave the editor and rename in
    /// the document browser / Files), so we offer one from the toolbar menu.
    ///
    /// Two layers so the UI never stalls and the result is never silent:
    ///  • `renameInPlace` is the synchronous core (validation + coordinated
    ///    move + verification) — this is what the unit tests exercise.
    ///  • `rename(…)` is what the UI awaits: it runs the core *off* the main
    ///    actor and returns the result back on the main actor.
    ///
    /// The coordination runs off the main thread on purpose. The open document
    /// behind `DocumentGroup` is itself an `NSFilePresenter` in *this* process;
    /// an `NSFileCoordinator` `.forMoving` invoked synchronously on the main
    /// thread waits for that presenter to relinquish the file, but the
    /// presenter's own bookkeeping also wants the main thread — so the move can
    /// stall and quietly never happen. Coordinating on a background thread lets
    /// the presenter respond, the move completes, and `item(at:didMoveTo:)`
    /// makes the live `UIDocument` follow the move so `DocumentGroup` re-titles
    /// the window. Returns `nil` on success or a user-facing message on failure.
    static func rename(fileURL: URL, to newBaseName: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            renameInPlace(fileURL: fileURL, to: newBaseName)
        }.value
    }

    /// The synchronous rename core. `nonisolated` so the async wrapper can run
    /// it off the main actor; it only touches thread-safe file APIs and holds
    /// no main-actor state. Safe to call directly (the tests do).
    nonisolated static func renameInPlace(fileURL: URL, to newBaseName: String) -> String? {
        let trimmed = newBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "The name can’t be empty." }
        // Don't let the user type a path; a rename stays in the same folder.
        guard !trimmed.contains("/"), !trimmed.contains(":") else {
            return "A name can’t contain “/” or “:”."
        }

        let ext = fileURL.pathExtension
        var newURL = fileURL.deletingLastPathComponent().appendingPathComponent(trimmed)
        if !ext.isEmpty, newURL.pathExtension.caseInsensitiveCompare(ext) != .orderedSame {
            newURL.appendPathExtension(ext)
        }
        guard newURL != fileURL else { return nil }          // no-op rename
        if FileManager.default.fileExists(atPath: newURL.path) {
            return "“\(newURL.lastPathComponent)” already exists in this folder."
        }

        // The in-place file may be security-scoped; hold the scope across the move.
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        renameLog.log("rename start: \(fileURL.path, privacy: .public) -> \(newURL.path, privacy: .public) scoped=\(scoped)")

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var moveError: Error?
        coordinator.coordinate(writingItemAt: fileURL, options: .forMoving,
                               writingItemAt: newURL, options: .forReplacing,
                               error: &coordinationError) { from, to in
            do {
                try FileManager.default.moveItem(at: from, to: to)
                // Tell the open document's file presenter it moved, so the
                // editor keeps pointing at the renamed file.
                coordinator.item(at: from, didMoveTo: to)
            } catch {
                moveError = error
            }
        }
        if let error = (moveError ?? coordinationError) as NSError? {
            renameLog.error("rename failed: \(error.domain, privacy: .public) \(error.code) \(error.localizedDescription, privacy: .public)")
            // Surface the domain/code too — it pinpoints the cause (e.g. a
            // sandbox denial is NSCocoaErrorDomain 513 / 257).
            return "\(error.localizedDescription)\n[\(error.domain) \(error.code)]"
        }
        // Verify the move actually took effect. A coordinated move can report
        // *no error* yet not happen — e.g. the open document is holding the
        // file — so we check rather than trust a nil error.
        let newExists = FileManager.default.fileExists(atPath: newURL.path)
        let oldExists = FileManager.default.fileExists(atPath: fileURL.path)
        renameLog.log("post-move newExists=\(newExists) oldExists=\(oldExists) new=\(newURL.path, privacy: .public)")
        if !newExists {
            return "No error was reported, but “\(newURL.lastPathComponent)” is not on disk — the move didn’t take effect (the open document may be holding the file)."
        }
        if oldExists {
            return "“\(newURL.lastPathComponent)” was created, but the old “\(fileURL.lastPathComponent)” is still there too — the open document keeps rewriting it."
        }
        return nil
    }

    /// Prompt for a new name and perform the rename. Uses a UIKit
    /// `UIAlertController` text field, reading `textField.text` in the action
    /// handler — reliable across iPhone and iPad.
    static func promptRename(fileURL: URL, currentBaseName: String) {
        guard let presenter = topViewController() else {
            renameLog.error("promptRename: no presenter")
            return
        }
        let alert = UIAlertController(
            title: "Rename Document",
            message: "Enter a new name. The file keeps its place and extension.",
            preferredStyle: .alert)
        // Capture the text field strongly so the action handler reads the
        // current typed value directly.
        var nameField: UITextField!
        alert.addTextField { field in
            field.text = currentBaseName
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.returnKeyType = .done
            nameField = field
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { _ in
            let typed = nameField.text ?? ""
            renameLog.log("Rename tapped: typed=\(typed, privacy: .public)")
            // Await the off-main rename, then report on the main actor. By the
            // time this resumes the rename alert has fully dismissed, so the
            // result alert presents reliably (no fragile fixed delay).
            Task { @MainActor in
                let result = await rename(fileURL: fileURL, to: typed)
                let title = result == nil ? "Renamed" : "Couldn’t Rename"
                let message = result ?? "Renamed to “\(typed)”."
                presentMessage(title: title, message: message)
            }
        })
        presenter.present(alert, animated: true)
    }

    private static func presentMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presentAlert(alert)
    }

    /// Present a modal alert against the active window, retrying once if no
    /// window is key/foreground for a beat (a scene transition can momentarily
    /// leave no presenter, which would otherwise silently drop the result).
    private static func presentAlert(_ alert: UIAlertController, retry: Bool = true) {
        guard let presenter = topViewController() else {
            if retry {
                // Stay on the main actor (no Sendable crossing of the UIKit
                // alert) and try once more after the transition settles.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    presentAlert(alert, retry: false)
                }
            } else {
                renameLog.error("presentAlert: no presenter")
            }
            return
        }
        presenter.present(alert, animated: true)
    }

    /// Share the raw Markdown source. Shares the real file when it has been
    /// saved (so the filename and location are preserved); otherwise writes
    /// the current text to a temporary `.md` and shares that.
    static func shareSource(fileURL: URL?, text: String, title: String) {
        if let fileURL {
            presentShare(items: [fileURL])
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sanitized(title)).md")
        try? Data(text.utf8).write(to: url, options: .atomic)
        presentShare(items: [url])
    }

    // MARK: - Presentation

    private static func presentShare(items: [Any]) {
        guard let presenter = topViewController(), let anchor = presenter.view else { return }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = anchor
            popover.sourceRect = CGRect(x: anchor.bounds.maxX - 60,
                                        y: anchor.safeAreaInsets.top + 8, width: 1, height: 1)
            popover.permittedArrowDirections = [.up]
        }
        presenter.present(activity, animated: true)
    }

    private static func presentPrint(_ controller: UIPrintInteractionController) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard let anchor = topViewController()?.view else {
                continuation.resume(); return
            }
            // `present(from:in:…)` anchors the popover on iPad and is ignored
            // on iPhone, where the panel is modal.
            controller.present(from: CGRect(x: anchor.bounds.maxX - 60,
                                            y: anchor.safeAreaInsets.top + 8, width: 1, height: 1),
                               in: anchor, animated: true) { _, _, _ in
                continuation.resume()
            }
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    /// Make a string safe to use as a file name.
    private static func sanitized(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Document" : cleaned
    }
}
