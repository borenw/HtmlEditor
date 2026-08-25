import AppKit

/// Builds the "Open Recent" list. The app doesn't use NSDocument, but it does
/// register opened files with the shared document controller, so the system's
/// own recents list is the source of truth here too.
final class RecentDocumentsMenu: NSObject, NSMenuDelegate {

    /// A fresh menu for each place it appears — a menu can only have one owner.
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Open Recent")
        menu.delegate = self
        menu.autoenablesItems = false
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let urls = NSDocumentController.shared.recentDocumentURLs
        guard !urls.isEmpty else {
            let empty = NSMenuItem(title: "No Recent Documents", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent,
                                  action: #selector(EditorWindowController.openRecentDocument(_:)),
                                  keyEquivalent: "")
            item.representedObject = url
            item.toolTip = url.path
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            // Sent down the responder chain to whichever window is in front.
            item.target = nil
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu",
                               action: #selector(NSDocumentController.clearRecentDocuments(_:)),
                               keyEquivalent: "")
        clear.target = NSDocumentController.shared
        menu.addItem(clear)
    }
}
