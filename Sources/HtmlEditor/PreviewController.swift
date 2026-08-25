import AppKit
import WebKit

protocol PreviewControllerDelegate: AnyObject {
    /// The user clicked in the preview, inside the element with this id.
    func preview(_ preview: PreviewController, didClickElementWithID id: Int)
    /// The user typed in the preview; `html` is that element's markup, re-serialized.
    func preview(_ preview: PreviewController, didEditElementWithID id: Int, html: String)
    /// The user pasted an image into the preview.
    func preview(_ preview: PreviewController, didPasteImage data: Data, fileExtension: String)
}

/// Owns the rendered pane: renders instrumented markup, keeps it editable,
/// and relays clicks, edits and image pastes back to the window controller.
final class PreviewController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    weak var delegate: PreviewControllerDelegate?

    /// Turning this off gives a live browser view, where the page's own scripts
    /// handle clicks instead of the editor swallowing them.
    var isEditable = true {
        didSet { applyEditableState() }
    }

    private var previewFileURL: URL?
    private var pendingScrollPosition: Int?
    /// offsets[id] = where that element's opening tag starts in the markup, or
    /// -1 once a patch has replaced the text it pointed at.
    private var offsets: [Int] = []

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
        let (html, offsets) = SourceMap.instrument(source)
        self.offsets = offsets
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

    // MARK: - Offset table

    /// Where the element with this id currently starts, or nil once a patch has
    /// replaced the markup it referred to.
    func sourceOffset(forElementWithID id: Int) -> Int? {
        guard id >= 0, id < offsets.count else { return nil }
        return offsets[id] >= 0 ? offsets[id] : nil
    }

    /// Re-aligns the table with the markup after `range` was replaced. Called in
    /// the same synchronous step as the edit, so no id can be read while stale.
    func notePatch(range: NSRange, delta: Int) {
        let end = range.location + range.length
        for index in offsets.indices {
            let offset = offsets[index]
            if offset < 0 { continue }
            if offset > range.location && offset < end {
                offsets[index] = -1          // lived inside the replaced markup
            } else if offset >= end {
                offsets[index] = offset + delta
            }
        }
    }

    // MARK: - Commands

    /// Scrolls the element covering `position` in the markup into view.
    func scroll(toSourcePosition position: Int) {
        guard !webView.isLoading else {
            pendingScrollPosition = position
            return
        }
        var best = -1
        var bestOffset = -1
        for (id, offset) in offsets.enumerated() where offset >= 0 && offset <= position && offset > bestOffset {
            best = id
            bestOffset = offset
        }
        guard best >= 0 else { return }
        webView.evaluateJavaScript("window.__heScrollTo(\(best))")
    }

    func insertImage(named name: String) {
        guard let encoded = PreviewController.javaScriptString(name) else { return }
        webView.evaluateJavaScript("window.__heInsertImage(\(encoded))")
    }

    private func applyEditableState() {
        let mode = isEditable ? "on" : "off"
        webView.evaluateJavaScript("document.designMode = '\(mode)'; if (window.__heDeselect) { window.__heDeselect(); }")
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
            guard let id = (body["id"] as? NSNumber)?.intValue else { return }
            delegate?.preview(self, didClickElementWithID: id)
        case "edit":
            guard let html = body["html"] as? String,
                  let id = (body["id"] as? NSNumber)?.intValue else { return }
            delegate?.preview(self, didEditElementWithID: id, html: html)
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
        var ID = 'data-he-id';
        var UI = 'data-he-ui';

        function post(message) {
            window.webkit.messageHandlers.editor.postMessage(message);
        }

        function stampedAncestor(node) {
            var element = node;
            while (element && element.nodeType !== 1) { element = element.parentNode; }
            while (element && !element.hasAttribute(ID)) { element = element.parentElement; }
            return element;
        }

        function selectedElement() {
            var selection = document.getSelection();
            if (!selection || !selection.rangeCount) { return null; }
            return stampedAncestor(selection.getRangeAt(0).commonAncestorContainer);
        }

        function isChrome(node) {
            return !!(node && node.closest && node.closest('[' + UI + ']'));
        }

        // Clicking in the preview moves the caret in the markup pane.
        document.addEventListener('click', function (event) {
            if (isChrome(event.target)) { return; }
            var element = stampedAncestor(event.target);
            if (!element) { return; }
            var id = parseInt(element.getAttribute(ID), 10);
            if (!isNaN(id)) { post({ type: 'cursor', id: id }); }
        }, true);

        // Typing sends back ONLY the element that changed, so the rest of the
        // file keeps its formatting and nothing the page's scripts built at
        // runtime gets written into the markup.
        var pendingElement = null;
        var syncTimer = null;

        function flush() {
            clearTimeout(syncTimer);
            syncTimer = null;
            var element = pendingElement;
            pendingElement = null;
            if (!element || !element.isConnected) { return; }
            var id = parseInt(element.getAttribute(ID), 10);
            if (isNaN(id)) { return; }
            var clone = element.cloneNode(true);
            clone.removeAttribute(ID);
            var stamped = clone.querySelectorAll('[' + ID + ']');
            for (var i = 0; i < stamped.length; i++) { stamped[i].removeAttribute(ID); }
            // Selection handles live in the page but must never reach the file.
            var uiNodes = clone.querySelectorAll('[' + UI + ']');
            for (var j = 0; j < uiNodes.length; j++) { uiNodes[j].remove(); }
            // This element's markup is about to be replaced wholesale, so the ids
            // inside it stop meaning anything. Drop them now, in the same turn as
            // the post, and later typing in there maps to this element instead.
            var inside = element.querySelectorAll('[' + ID + ']');
            for (var k = 0; k < inside.length; k++) { inside[k].removeAttribute(ID); }
            post({ type: 'edit', id: id, html: clone.outerHTML });
        }

        function commit(element) {
            var target = element.hasAttribute(ID) ? element : stampedAncestor(element);
            if (!target) { return; }
            pendingElement = target;
            flush();
        }

        document.addEventListener('input', function () {
            var element = selectedElement();
            if (!element) { return; }
            // Moving to a different element commits the previous one first.
            if (pendingElement && pendingElement !== element) { flush(); }
            pendingElement = element;
            clearTimeout(syncTimer);
            syncTimer = setTimeout(flush, 400);
        });

        // A pasted picture goes through the app so it lands next to the .html file
        // instead of becoming an unsaveable blob: URL.
        document.addEventListener('paste', function (event) {
            if (document.designMode !== 'on') { return; }
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

        // ---- Picture move and resize -------------------------------------
        // Handles are drawn in a fixed-position overlay marked data-he-ui, which
        // is stripped on the way back so the chrome never lands in the markup.

        var HANDLES = [
            ['nw', '0%', '0%', 'nwse-resize'], ['n', '50%', '0%', 'ns-resize'],
            ['ne', '100%', '0%', 'nesw-resize'], ['e', '100%', '50%', 'ew-resize'],
            ['se', '100%', '100%', 'nwse-resize'], ['s', '50%', '100%', 'ns-resize'],
            ['sw', '0%', '100%', 'nesw-resize'], ['w', '0%', '50%', 'ew-resize']
        ];

        var selectedImage = null;
        var chromeBox = null;

        function buildChrome() {
            if (chromeBox && chromeBox.isConnected) { return chromeBox; }
            chromeBox = document.createElement('div');
            chromeBox.setAttribute(UI, '1');
            chromeBox.setAttribute('contenteditable', 'false');
            chromeBox.style.cssText = 'position:fixed;display:none;pointer-events:none;z-index:2147483647;';

            var frame = document.createElement('div');
            frame.setAttribute(UI, '1');
            frame.style.cssText = 'position:absolute;left:0;top:0;right:0;bottom:0;' +
                'border:1px solid #1e90ff;box-shadow:0 0 0 1px rgba(255,255,255,0.7);pointer-events:none;';
            chromeBox.appendChild(frame);

            var grip = document.createElement('div');
            grip.setAttribute(UI, '1');
            grip.setAttribute('data-he-move', '1');
            grip.style.cssText = 'position:absolute;left:0;top:0;right:0;bottom:0;pointer-events:auto;cursor:move;';
            chromeBox.appendChild(grip);

            for (var i = 0; i < HANDLES.length; i++) {
                var spec = HANDLES[i];
                var handle = document.createElement('div');
                handle.setAttribute(UI, '1');
                handle.setAttribute('data-he-handle', spec[0]);
                handle.style.cssText = 'position:absolute;width:11px;height:11px;margin:-6px 0 0 -6px;' +
                    'background:#1e90ff;border:1px solid #fff;border-radius:2px;pointer-events:auto;' +
                    'left:' + spec[1] + ';top:' + spec[2] + ';cursor:' + spec[3] + ';';
                chromeBox.appendChild(handle);
            }

            document.body.appendChild(chromeBox);
            return chromeBox;
        }

        function placeChrome() {
            if (!selectedImage || !selectedImage.isConnected) { return; }
            var box = buildChrome();
            var rect = selectedImage.getBoundingClientRect();
            box.style.left = rect.left + 'px';
            box.style.top = rect.top + 'px';
            box.style.width = rect.width + 'px';
            box.style.height = rect.height + 'px';
            box.style.display = 'block';
        }

        window.__heSelectImage = function (image) {
            selectedImage = image;
            placeChrome();
        };

        window.__heDeselect = function () {
            selectedImage = null;
            if (chromeBox && chromeBox.isConnected) { chromeBox.style.display = 'none'; }
        };

        // Where "left" and "top" are actually measured from. NOT offsetParent:
        // that reports <body> when nothing above is positioned, but the real
        // containing block is then the initial one, whose origin is the document
        // corner — so trusting offsetParent shifts the picture by body's margin.
        function containingBlock(image) {
            var node = image.parentElement;
            while (node && node !== document.documentElement) {
                var style = window.getComputedStyle(node);
                if (style.position !== 'static' || style.transform !== 'none' ||
                    style.filter !== 'none' || style.perspective !== 'none') {
                    return node;
                }
                node = node.parentElement;
            }
            return null;
        }

        function toBlockCoordinates(image, clientX, clientY) {
            var block = containingBlock(image);
            if (!block) {
                return { left: clientX + window.scrollX, top: clientY + window.scrollY };
            }
            var rect = block.getBoundingClientRect();
            return {
                left: clientX - rect.left - block.clientLeft + block.scrollLeft,
                top: clientY - rect.top - block.clientTop + block.scrollTop
            };
        }

        // First drag lifts the picture out of the text flow, keeping it exactly
        // where it already sits so it does not jump under the pointer.
        function makeAbsolute(image) {
            if (window.getComputedStyle(image).position === 'absolute') { return; }
            var rect = image.getBoundingClientRect();
            var coordinates = toBlockCoordinates(image, rect.left, rect.top);
            image.style.position = 'absolute';
            image.style.left = Math.round(coordinates.left) + 'px';
            image.style.top = Math.round(coordinates.top) + 'px';
        }

        function drag(onMove) {
            function move(event) { event.preventDefault(); onMove(event); placeChrome(); }
            function up() {
                document.removeEventListener('mousemove', move, true);
                document.removeEventListener('mouseup', up, true);
                placeChrome();
                if (selectedImage) { commit(selectedImage); }
            }
            document.addEventListener('mousemove', move, true);
            document.addEventListener('mouseup', up, true);
        }

        function startMove(event) {
            var image = selectedImage;
            if (!image) { return; }
            // Grab offset must be read before the picture leaves the flow.
            var rect = image.getBoundingClientRect();
            var grabX = event.clientX - rect.left;
            var grabY = event.clientY - rect.top;
            makeAbsolute(image);
            drag(function (moveEvent) {
                var coordinates = toBlockCoordinates(image, moveEvent.clientX - grabX, moveEvent.clientY - grabY);
                image.style.left = Math.round(coordinates.left) + 'px';
                image.style.top = Math.round(coordinates.top) + 'px';
            });
        }

        function startResize(event, direction) {
            var image = selectedImage;
            if (!image) { return; }
            var rect = image.getBoundingClientRect();
            var startWidth = rect.width;
            var startHeight = rect.height;
            var ratio = startHeight > 0 ? startWidth / startHeight : 1;
            var startX = event.clientX;
            var startY = event.clientY;
            var style = window.getComputedStyle(image);
            var absolute = style.position === 'absolute';
            var startLeft = parseFloat(style.left) || 0;
            var startTop = parseFloat(style.top) || 0;
            var corner = direction.length === 2;

            drag(function (moveEvent) {
                var dx = moveEvent.clientX - startX;
                var dy = moveEvent.clientY - startY;
                var width = startWidth;
                var height = startHeight;
                if (direction.indexOf('e') >= 0) { width = startWidth + dx; }
                if (direction.indexOf('w') >= 0) { width = startWidth - dx; }
                if (direction.indexOf('s') >= 0) { height = startHeight + dy; }
                if (direction.indexOf('n') >= 0) { height = startHeight - dy; }
                width = Math.max(16, Math.round(width));
                height = Math.max(16, Math.round(height));
                // Corners keep the picture's proportions; edges stretch one axis.
                if (corner) { height = Math.max(16, Math.round(width / ratio)); }

                if (corner || direction === 'e' || direction === 'w') { image.style.width = width + 'px'; }
                if (corner || direction === 'n' || direction === 's') { image.style.height = height + 'px'; }
                // Dragging a top or left handle grows the picture the other way,
                // so the anchored corner has to stay put.
                if (absolute && direction.indexOf('w') >= 0) {
                    image.style.left = Math.round(startLeft + (startWidth - width)) + 'px';
                }
                if (absolute && direction.indexOf('n') >= 0) {
                    image.style.top = Math.round(startTop + (startHeight - height)) + 'px';
                }
            });
        }

        document.addEventListener('mousedown', function (event) {
            if (document.designMode !== 'on') { return; }
            var target = event.target;
            if (!target || !target.getAttribute) { return; }
            if (target.getAttribute('data-he-handle')) {
                event.preventDefault();
                startResize(event, target.getAttribute('data-he-handle'));
                return;
            }
            if (target.getAttribute('data-he-move')) {
                event.preventDefault();
                startMove(event);
                return;
            }
            if (target.tagName === 'IMG') {
                event.preventDefault();
                window.__heSelectImage(target);
                startMove(event);
                return;
            }
            window.__heDeselect();
        }, true);

        // Our own move replaces the browser's native image drag-and-drop.
        document.addEventListener('dragstart', function (event) {
            if (document.designMode === 'on' && event.target && event.target.tagName === 'IMG') {
                event.preventDefault();
            }
        }, true);

        document.addEventListener('keydown', function (event) {
            if (event.key === 'Escape') { window.__heDeselect(); }
        }, true);

        window.addEventListener('scroll', placeChrome, true);
        window.addEventListener('resize', placeChrome);

        window.__heScrollTo = function (id) {
            var target = document.querySelector('[' + ID + '="' + id + '"]');
            if (target) { target.scrollIntoView({ block: 'center' }); }
        };

        window.__heInsertImage = function (source) {
            document.execCommand('insertHTML', false, '<img src="' + source + '">');
            pendingElement = selectedElement();
            flush();
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
