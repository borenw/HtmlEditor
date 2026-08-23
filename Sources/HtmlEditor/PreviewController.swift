import AppKit
import WebKit

protocol PreviewControllerDelegate: AnyObject {
    /// The user clicked in the preview; `position` is an offset into the markup.
    func preview(_ preview: PreviewController, didClickAtSourcePosition position: Int)
    /// The user typed in the preview; `html` is the whole document, re-serialized.
    func preview(_ preview: PreviewController, didEditDocument html: String)
    /// The user pasted an image into the preview.
    func preview(_ preview: PreviewController, didPasteImage data: Data, fileExtension: String)
}

/// Owns the rendered pane: renders instrumented markup, keeps it editable,
/// and relays clicks, edits and image pastes back to the window controller.
final class PreviewController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    weak var delegate: PreviewControllerDelegate?

    /// Off by default: designMode swallows clicks, so scripts and interactive
    /// controls only behave like a real browser while the preview is read-only.
    var isEditable = false {
        didSet { applyEditableState() }
    }

    private var previewFileURL: URL?
    private var pendingScrollPosition: Int?

    override init() {
        super.init()
        let controller = webView.configuration.userContentController
        controller.addUserScript(WKUserScript(source: PreviewController.bridgeScript,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
        controller.add(WeakScriptMessageHandler(self), name: "editor")
        webView.navigationDelegate = self
    }

    // MARK: - Rendering

    /// Renders `source`. A document on disk is rendered through a sibling temp
    /// file so relative <img src> paths resolve against the real folder.
    func render(source: String, documentURL: URL?) {
        let html = SourceMap.instrument(source)
        guard let documentURL = documentURL else {
            previewFileURL = nil
            webView.loadHTMLString(html, baseURL: nil)
            return
        }
        let folder = documentURL.deletingLastPathComponent()
        let file = folder.appendingPathComponent(".htmleditor-preview.html")
        do {
            try html.write(to: file, atomically: true, encoding: .utf8)
            previewFileURL = file
            webView.loadFileURL(file, allowingReadAccessTo: folder)
        } catch {
            previewFileURL = nil
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func removeTemporaryFile() {
        guard let previewFileURL = previewFileURL else { return }
        try? FileManager.default.removeItem(at: previewFileURL)
        self.previewFileURL = nil
    }

    // MARK: - Commands

    /// Scrolls the rendered element that owns `position` in the markup into view.
    func scroll(toSourcePosition position: Int) {
        guard !webView.isLoading else {
            pendingScrollPosition = position
            return
        }
        webView.evaluateJavaScript("window.__heScrollTo(\(position))")
    }

    func insertImage(named name: String) {
        guard let encoded = PreviewController.javaScriptString(name) else { return }
        webView.evaluateJavaScript("window.__heInsertImage(\(encoded))")
    }

    private func applyEditableState() {
        webView.evaluateJavaScript("document.designMode = '\(isEditable ? "on" : "off")'")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyEditableState()
        if let position = pendingScrollPosition {
            pendingScrollPosition = nil
            scroll(toSourcePosition: position)
        }
    }

    // MARK: - Messages from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["type"] as? String else { return }
        switch kind {
        case "cursor":
            guard let position = (body["position"] as? NSNumber)?.intValue else { return }
            delegate?.preview(self, didClickAtSourcePosition: position)
        case "edit":
            guard let html = body["html"] as? String else { return }
            delegate?.preview(self, didEditDocument: "<!DOCTYPE html>\n" + html)
        case "image":
            guard let base64 = body["data"] as? String,
                  let data = Data(base64Encoded: base64) else { return }
            let mime = (body["mime"] as? String) ?? "image/png"
            delegate?.preview(self, didPasteImage: data, fileExtension: PreviewController.fileExtension(for: mime))
        default:
            break
        }
    }

    private static func fileExtension(for mime: String) -> String {
        switch mime.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/tiff": return "tiff"
        default: return "png"
        }
    }

    private static func javaScriptString(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8) else { return nil }
        return String(array.dropFirst().dropLast())
    }

    // MARK: - Page bridge

    private static let bridgeScript = """
    (function () {
        var POS = 'data-he-pos';

        function post(message) {
            window.webkit.messageHandlers.editor.postMessage(message);
        }

        function sourcePosition(node) {
            var element = node;
            while (element && element.nodeType !== 1) { element = element.parentNode; }
            while (element && !element.hasAttribute(POS)) { element = element.parentElement; }
            return element ? parseInt(element.getAttribute(POS), 10) : null;
        }

        // Clicking in the preview moves the caret in the markup pane.
        document.addEventListener('click', function (event) {
            var position = sourcePosition(event.target);
            if (position !== null && !isNaN(position)) { post({ type: 'cursor', position: position }); }
        }, true);

        // Typing in the preview writes the document back to the markup pane.
        function syncSource() {
            var clone = document.documentElement.cloneNode(true);
            clone.removeAttribute(POS);
            var stamped = clone.querySelectorAll('[' + POS + ']');
            for (var i = 0; i < stamped.length; i++) { stamped[i].removeAttribute(POS); }
            post({ type: 'edit', html: clone.outerHTML });
        }

        var syncTimer = null;
        document.addEventListener('input', function () {
            clearTimeout(syncTimer);
            syncTimer = setTimeout(syncSource, 400);
        });

        // A pasted picture goes through the app so it lands next to the .html file
        // instead of becoming an unsaveable blob: URL.
        document.addEventListener('paste', function (event) {
            var items = event.clipboardData ? event.clipboardData.items : null;
            if (!items) { return; }
            for (var i = 0; i < items.length; i++) {
                if (items[i].type.indexOf('image/') !== 0) { continue; }
                var file = items[i].getAsFile();
                if (!file) { continue; }
                event.preventDefault();
                var type = items[i].type;
                var reader = new FileReader();
                reader.onload = function () {
                    post({ type: 'image', mime: type, data: String(reader.result).split(',')[1] });
                };
                reader.readAsDataURL(file);
                return;
            }
        }, true);

        window.__heScrollTo = function (position) {
            if (!document.body) { return; }
            var stamped = document.body.querySelectorAll('[' + POS + ']');
            var best = null;
            for (var i = 0; i < stamped.length; i++) {
                if (parseInt(stamped[i].getAttribute(POS), 10) <= position) { best = stamped[i]; } else { break; }
            }
            if (best) { best.scrollIntoView({ block: 'center' }); }
        };

        window.__heInsertImage = function (source) {
            document.execCommand('insertHTML', false, '<img src="' + source + '">');
            syncSource();
        };
    })();
    """
}

/// WKUserContentController retains its handlers; this keeps the controller from
/// retaining itself through the web view's configuration.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
