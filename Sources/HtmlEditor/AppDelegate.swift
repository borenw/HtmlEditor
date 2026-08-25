import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: EditorWindowController?
    private let recentDocuments = RecentDocumentsMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let controller = EditorWindowController()
        self.controller = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return controller?.confirmDiscardChanges() ?? true ? .terminateNow : .terminateCancel
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        controller?.open(url: URL(fileURLWithPath: filename))
        return true
    }

    // MARK: - Menu

    private func findItem(_ title: String, _ action: NSTextFinder.Action, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = action.rawValue
        return item
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About HtmlEditor", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit HtmlEditor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New", action: #selector(EditorWindowController.newDocument(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open…", action: #selector(EditorWindowController.openDocument(_:)), keyEquivalent: "o")
        let openRecent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        openRecent.submenu = recentDocuments.makeMenu()
        fileMenu.addItem(openRecent)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(EditorWindowController.saveDocument(_:)), keyEquivalent: "s")
        let saveAs = NSMenuItem(title: "Save As…", action: #selector(EditorWindowController.saveDocumentAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAs)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Reveal in Finder", action: #selector(EditorWindowController.revealInFinder(_:)), keyEquivalent: "")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        // performTextFinderAction reads which operation to run off the item's tag.
        editMenu.addItem(findItem("Find…", .showFindInterface, "f", [.command]))
        editMenu.addItem(findItem("Find Next", .nextMatch, "g", [.command]))
        editMenu.addItem(findItem("Find Previous", .previousMatch, "g", [.command, .shift]))
        editMenu.addItem(findItem("Use Selection for Find", .setSearchString, "e", [.command]))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let togglePreview = NSMenuItem(title: "Toggle Preview", action: #selector(EditorWindowController.togglePreview(_:)), keyEquivalent: "p")
        togglePreview.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(togglePreview)
        viewMenu.addItem(withTitle: "Refresh Preview", action: #selector(EditorWindowController.refreshPreview(_:)), keyEquivalent: "r")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(EditorWindowController.zoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(EditorWindowController.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(EditorWindowController.actualSize(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        let toggleEditing = NSMenuItem(title: "Edit in Preview", action: #selector(EditorWindowController.togglePreviewEditing(_:)), keyEquivalent: "e")
        toggleEditing.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(toggleEditing)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}
