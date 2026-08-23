import AppKit

/// Plain-text HTML editor. Pasting an image hands it off to `imagePasteHandler`
/// instead of dropping unreadable binary text into the markup.
final class MarkupTextView: NSTextView {
    /// Returns true if it consumed the paste.
    var imagePasteHandler: ((NSPasteboard) -> Bool)?

    override func paste(_ sender: Any?) {
        if imagePasteHandler?(NSPasteboard.general) == true { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if imagePasteHandler?(NSPasteboard.general) == true { return }
        super.pasteAsPlainText(sender)
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

    /// Replaces the selection with `text` through the undo-aware path.
    func insert(_ text: String) {
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
    }
}
