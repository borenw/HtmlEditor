import AppKit
import UniformTypeIdentifiers

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, PreviewControllerDelegate {

    private static let lastDocumentBookmarkKey = "LastDocumentBookmark"
    private static let lastDocumentPathKey = "LastDocumentPath"
    private static let defaultContentSize = NSSize(width: 1100, height: 720)

    private let textView = MarkupTextView()
    private let preview = PreviewController()
    private var previewItem: NSSplitViewItem!

    private var fileURL: URL?
    private var isDirty = false
    private var previewRefresh: DispatchWorkItem?
    /// Set while the markup pane is being rewritten from a preview edit, so we
    /// don't re-render the preview out from under the user's caret.
    private var isApplyingPreviewEdit = false
    /// Set while the caret is being moved programmatically from a preview click.
    private var isApplyingPreviewSelection = false

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
            contentRect: NSRect(origin: .zero, size: EditorWindowController.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        super.init(window: window)

        window.delegate = self
        preview.delegate = self

        // Assigning a content view controller resizes the window to fit its view,
        // which starts out empty — so the size has to be restored afterwards.
        window.contentViewController = makeSplitViewController()
        window.contentMinSize = NSSize(width: 700, height: 420)
        window.setContentSize(EditorWindowController.defaultContentSize)
        window.center()

        window.setFrameAutosaveName("EditorWindow")
        window.setFrameUsingName("EditorWindow")
        // Guard against a degenerate frame saved by an earlier build.
        if window.frame.width < window.contentMinSize.width || window.frame.height < window.contentMinSize.height {
            window.setContentSize(EditorWindowController.defaultContentSize)
            window.center()
        }

        if !restoreLastDocument() {
            textView.string = EditorWindowController.starterDocument
            updateTitle()
            renderPreview()
        }
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
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
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
        textView.onClick = { [weak self] in
            self?.syncPreviewToCaret()
        }

        let splitViewController = NSSplitViewController()
        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin
        splitViewController.splitView.autosaveName = "EditorSplit"

        let editorItem = NSSplitViewItem(viewController: ContainerViewController(view: scrollView))
        editorItem.minimumThickness = 280
        splitViewController.addSplitViewItem(editorItem)

        previewItem = NSSplitViewItem(viewController: ContainerViewController(view: preview.webView))
        previewItem.minimumThickness = 240
        previewItem.canCollapse = true
        splitViewController.addSplitViewItem(previewItem)

        return splitViewController
    }

    // MARK: - File actions

    @objc func newDocument(_ sender: Any?) {
        guard confirmDiscardChanges() else { return }
        preview.removeTemporaryFile()
        fileURL = nil
        textView.string = EditorWindowController.starterDocument
        textView.undoManager?.removeAllActions()
        isDirty = false
        updateTitle()
        renderPreview()
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

    @discardableResult
    func open(url: URL) -> Bool {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            preview.removeTemporaryFile()
            fileURL = url
            textView.string = text
            textView.undoManager?.removeAllActions()
            isDirty = false
            updateTitle()
            renderPreview()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            rememberLastDocument(url)
            return true
        } catch {
            presentError("Could not open \(url.lastPathComponent)", error.localizedDescription)
            return false
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
        preview.removeTemporaryFile()
        fileURL = url
        guard write(to: url) else { return false }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        renderPreview()
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
            rememberLastDocument(url)
            return true
        } catch {
            presentError("Could not save \(url.lastPathComponent)", error.localizedDescription)
            return false
        }
    }

    // MARK: - Reopening last session's document

    /// The bookmark keeps working if the file is moved or renamed; the plain path
    /// is a fallback for when a bookmark can't be made.
    private func rememberLastDocument(_ url: URL) {
        let defaults = UserDefaults.standard
        if let bookmark = try? url.bookmarkData() {
            defaults.set(bookmark, forKey: EditorWindowController.lastDocumentBookmarkKey)
        }
        defaults.set(url.path, forKey: EditorWindowController.lastDocumentPathKey)
    }

    /// Reopens whatever was last edited. Failures are silent — a missing file at
    /// launch should leave you on a blank document, not an error sheet.
    private func restoreLastDocument() -> Bool {
        let defaults = UserDefaults.standard
        var candidate: URL?
        if let bookmark = defaults.data(forKey: EditorWindowController.lastDocumentBookmarkKey) {
            var isStale = false
            candidate = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
        }
        if candidate == nil, let path = defaults.string(forKey: EditorWindowController.lastDocumentPathKey) {
            candidate = URL(fileURLWithPath: path)
        }
        guard let url = candidate, FileManager.default.isReadableFile(atPath: url.path) else { return false }
        return open(url: url)
    }

    // MARK: - Image paste

    /// Saves the pasted image beside the .html file and inserts an <img> tag for it.
    private func handleImagePaste(from pasteboard: NSPasteboard) -> Bool {
        guard let image = PastedImage.read(from: pasteboard) else { return false }
        guard let name = saveBesideDocument(image, retry: { self.handleImagePaste(from: pasteboard) }) else { return true }
        textView.insert("<img src=\"\(name)\" alt=\"\">")
        return true
    }

    /// Writes `image` next to the document, prompting for a location first if the
    /// document has never been saved. Returns the file name to reference.
    @discardableResult
    private func saveBesideDocument(_ image: PastedImage, retry: (() -> Bool)? = nil) -> String? {
        guard let fileURL = fileURL else {
            let alert = NSAlert()
            alert.messageText = "Save this file first"
            alert.informativeText = "Images are stored next to the .html file, so the document needs a location on disk before you can paste one."
            alert.addButton(withTitle: "Save As…")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn, saveDocumentAs(nil) {
                _ = retry?()
            }
            return nil
        }
        do {
            let name = try image.write(into: fileURL.deletingLastPathComponent())
            return name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        } catch {
            presentError("Could not save the pasted image", error.localizedDescription)
            return nil
        }
    }

    // MARK: - Preview

    @objc func togglePreview(_ sender: Any?) {
        previewItem.animator().isCollapsed.toggle()
        if !previewItem.isCollapsed { renderPreview() }
    }

    @objc func togglePreviewEditing(_ sender: Any?) {
        if !preview.isEditable, documentContainsScript, !confirmScriptedPreviewEditing() { return }
        preview.isEditable.toggle()
    }

    private var documentContainsScript: Bool {
        textView.string.range(of: "<script", options: .caseInsensitive) != nil
    }

    /// Typing in the preview re-serializes the live page, so anything the page's
    /// own scripts built at runtime gets written into the file — and handlers
    /// assigned in JavaScript don't survive the trip.
    private func confirmScriptedPreviewEditing() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Editing the preview will rewrite this page"
        alert.informativeText = "This document contains scripts. When you type in the preview, the whole page is written back from the rendered document, so elements your scripts created at runtime become part of the markup — and click handlers assigned in JavaScript are lost.\n\nEdit in the markup pane to leave the file exactly as you wrote it."
        alert.addButton(withTitle: "Enable Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc func refreshPreview(_ sender: Any?) {
        renderPreview()
    }

    private func renderPreview() {
        preview.render(source: textView.string, documentURL: fileURL)
    }

    private func schedulePreviewRefresh() {
        guard !previewItem.isCollapsed else { return }
        previewRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.renderPreview() }
        previewRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func syncPreviewToCaret() {
        guard !previewItem.isCollapsed, !isApplyingPreviewSelection else { return }
        preview.scroll(toSourcePosition: textView.selectedRange().location)
    }

    // MARK: - PreviewControllerDelegate

    func preview(_ preview: PreviewController, didClickAtSourcePosition position: Int) {
        let length = (textView.string as NSString).length
        let location = max(0, min(position, length))
        isApplyingPreviewSelection = true
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(NSRange(location: location, length: 0))
        isApplyingPreviewSelection = false
    }

    func preview(_ preview: PreviewController, didEditDocument html: String) {
        guard html != textView.string else { return }
        isApplyingPreviewEdit = true
        textView.replaceEntireText(with: html)
        isApplyingPreviewEdit = false
    }

    func preview(_ preview: PreviewController, didPasteImage data: Data, fileExtension: String) {
        let image = PastedImage(data: data, suggestedName: "pasted-image", fileExtension: fileExtension)
        guard let name = saveBesideDocument(image) else { return }
        preview.insertImage(named: name)
    }

    // MARK: - State

    func textDidChange(_ notification: Notification) {
        isDirty = true
        updateTitle()
        // An edit that came from the preview is already on screen there.
        if !isApplyingPreviewEdit { schedulePreviewRefresh() }
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
        preview.removeTemporaryFile()
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

extension EditorWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(togglePreviewEditing(_:)) {
            item.state = preview.isEditable ? .on : .off
        }
        if item.action == #selector(revealInFinder(_:)) {
            return fileURL != nil
        }
        return true
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
