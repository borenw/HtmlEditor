import AppKit

/// Plain-text HTML editor. Pasting an image hands it off to `imagePasteHandler`
/// instead of dropping unreadable binary text into the markup.
final class MarkupTextView: NSTextView {
    /// Returns true if it consumed the paste.
    var imagePasteHandler: ((NSPasteboard) -> Bool)?
    /// Called after a click has settled, so the preview can follow the caret.
    var onClick: (() -> Void)?
    /// Injectable for tests; production always reads the general pasteboard.
    var pasteboard: NSPasteboard = .general

    override func paste(_ sender: Any?) {
        if imagePasteHandler?(pasteboard) == true { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if imagePasteHandler?(pasteboard) == true { return }
        super.pasteAsPlainText(sender)
    }

    /// A plain-text view lists no image types as readable, so AppKit greys out
    /// Paste whenever the clipboard holds only a picture. We handle those, so
    /// re-enable the item ourselves.
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(paste(_:)) || item.action == #selector(pasteAsPlainText(_:)) {
            if PastedImage.isAvailable(on: pasteboard) { return true }
        }
        return super.validateMenuItem(item)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) || item.action == #selector(pasteAsPlainText(_:)) {
            if PastedImage.isAvailable(on: pasteboard) { return true }
        }
        return super.validateUserInterfaceItem(item)
    }

    override func keyDown(with event: NSEvent) {
        // Ctrl+V pastes too, alongside the standard Cmd+V.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .control, event.charactersIgnoringModifiers?.lowercased() == "v" {
            paste(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onClick?()
    }

    /// Replaces the selection with `text` through the undo-aware path.
    func insert(_ text: String) {
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
    }

    /// Swaps the whole document in one undoable step, for edits made in the preview.
    func replaceEntireText(with text: String) {
        let whole = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: whole, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: whole, with: text)
        didChangeText()
    }
}
