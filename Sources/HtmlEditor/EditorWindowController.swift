import AppKit
import WebKit
import UniformTypeIdentifiers

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {

    private let textView = MarkupTextView()
    private let webView = WKWebView()
    private var previewItem: NSSplitViewItem!

    private var fileURL: URL?
    private var isDirty = false
    private var previewRefresh: DispatchWorkItem?

    /// Live preview needs a real file on disk so relative <img src> paths resolve.
    private var previewFileURL: URL? {
        fileURL?.deletingLastPathComponent().appendingPathComponent(".htmleditor-preview.html")
    }

    private static let starterDocument = """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>Untitled</title>
    </head>
    <body>

    </body>
    </html>
    """

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.center()
        window.setFrameAutosaveName("EditorWindow")
        super.init(window: window)
        window.delegate = self
        window.contentViewController = makeSplitViewController()
        textView.string = EditorWindowController.starterDocument
        updateTitle()
        refreshPreview(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Layout

    private func makeSplitViewController() -> NSSplitViewController {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        textView.delegate = self
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFindPanel = true
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.imagePasteHandler = { [weak self] pasteboard in
            self?.handleImagePaste(from: pasteboard) ?? false
        }

        let splitViewController = NSSplitViewController()
        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin
        splitViewController.splitView.autosaveName = "EditorSplit"

        let editorItem = NSSplitViewItem(viewController: ContainerViewController(view: scrollView))
        editorItem.minimumThickness = 280
        splitViewController.addSplitViewItem(editorItem)

        previewItem = NSSplitViewItem(viewController: ContainerViewController(view: webView))
        previewItem.minimumThickness = 240
        previewItem.canCollapse = true
        splitViewController.addSplitViewItem(previewItem)

        return splitViewController
    }

    // MARK: - File actions

    @objc func newDocument(_ sender: Any?) {
        guard confirmDiscardChanges() else { return }
        removePreviewFile()
        fileURL = nil
        textView.string = EditorWindowController.starterDocument
        textView.undoManager?.removeAllActions()
        isDirty = false
        updateTitle()
        refreshPreview(nil)
    }

    @objc func openDocument(_ sender: Any?) {
        guard confirmDiscardChanges() else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func open(url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            removePreviewFile()
            fileURL = url
            textView.string = text
            textView.undoManager?.removeAllActions()
            isDirty = false
            updateTitle()
            refreshPreview(nil)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            presentError("Could not open \(url.lastPathComponent)", error.localizedDescription)
        }
    }

    @discardableResult
    @objc func saveDocument(_ sender: Any?) -> Bool {
        guard let url = fileURL else { return saveDocumentAs(sender) }
        return write(to: url)
    }

    @discardableResult
    @objc func saveDocumentAs(_ sender: Any?) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Untitled.html"
        if let directory = fileURL?.deletingLastPathComponent() {
            panel.directoryURL = directory
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        removePreviewFile()
        fileURL = url
        guard write(to: url) else { return false }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        refreshPreview(nil)
        return true
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func write(to url: URL) -> Bool {
        do {
            try textView.string.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
            updateTitle()
            return true
        } catch {
            presentError("Could not save \(url.lastPathComponent)", error.localizedDescription)
            return false
        }
    }

    // MARK: - Image paste

    /// Saves the pasted image beside the .html file and inserts an <img> tag for it.
    private func handleImagePaste(from pasteboard: NSPasteboard) -> Bool {
        guard let image = PastedImage.read(from: pasteboard) else { return false }

        guard let fileURL = fileURL else {
            let alert = NSAlert()
            alert.messageText = "Save this file first"
            alert.informativeText = "Images are stored next to the .html file, so the document needs a location on disk before you can paste one."
            alert.addButton(withTitle: "Save As…")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn, saveDocumentAs(nil) {
                return handleImagePaste(from: pasteboard)
            }
            return true
        }

        let directory = fileURL.deletingLastPathComponent()
        do {
            let name = try image.write(into: directory)
            let source = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            textView.insert("<img src=\"\(source)\" alt=\"\">")
        } catch {
            presentError("Could not save the pasted image", error.localizedDescription)
        }
        return true
    }

    // MARK: - Preview

    @objc func togglePreview(_ sender: Any?) {
        previewItem.animator().isCollapsed.toggle()
        if !previewItem.isCollapsed { refreshPreview(nil) }
    }

    @objc func refreshPreview(_ sender: Any?) {
        let html = textView.string
        guard let previewFileURL = previewFileURL else {
            webView.loadHTMLString(html, baseURL: nil)
            return
        }
        let directory = previewFileURL.deletingLastPathComponent()
        do {
            try html.write(to: previewFileURL, atomically: true, encoding: .utf8)
            webView.loadFileURL(previewFileURL, allowingReadAccessTo: directory)
        } catch {
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func schedulePreviewRefresh() {
        guard !previewItem.isCollapsed else { return }
        previewRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshPreview(nil) }
        previewRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func removePreviewFile() {
        guard let previewFileURL = previewFileURL else { return }
        try? FileManager.default.removeItem(at: previewFileURL)
    }

    // MARK: - State

    func textDidChange(_ notification: Notification) {
        isDirty = true
        updateTitle()
        schedulePreviewRefresh()
    }

    private func updateTitle() {
        window?.title = (fileURL?.lastPathComponent ?? "Untitled") + (isDirty ? " — Edited" : "")
        window?.representedURL = fileURL
        window?.isDocumentEdited = isDirty
    }

    /// Returns false only if the user cancels out of a pending save.
    func confirmDiscardChanges() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(fileURL?.lastPathComponent ?? "Untitled")?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveDocument(nil)
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard confirmDiscardChanges() else { return false }
        removePreviewFile()
        return true
    }

    private func presentError(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}

/// Wraps a plain view so it can sit in an NSSplitViewController.
final class ContainerViewController: NSViewController {
    private let contained: NSView

    init(view: NSView) {
        self.contained = view
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() { view = contained }
}
