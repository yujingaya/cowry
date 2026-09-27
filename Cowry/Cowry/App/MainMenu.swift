import AppKit

/// Actions sent through the responder chain from menus and toolbar items.
@MainActor @objc protocol CowryActions {
    @objc optional func newTransaction(_ sender: Any?)
    @objc optional func newAccount(_ sender: Any?)
    @objc optional func showLibraryInFinder(_ sender: Any?)
    @objc optional func duplicate(_ sender: Any?)
    @objc optional func focusSearch(_ sender: Any?)
    @objc optional func goBack(_ sender: Any?)
    @objc optional func goForward(_ sender: Any?)
    @objc optional func showAllTransactions(_ sender: Any?)
    @objc optional func addSampleData(_ sender: Any?)
    @objc optional func addLargeSampleData(_ sender: Any?)
    @objc optional func verifyLedger(_ sender: Any?)
}

enum MainMenu {
    @MainActor
    static func make() -> NSMenu {
        let bar = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        bar.addItem(submenu(appName, [
            item(String(localized: "About \(appName)"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item(String(localized: "Hide \(appName)"), #selector(NSApplication.hide(_:)), "h"),
            item(String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(String(localized: "Quit \(appName)"), #selector(NSApplication.terminate(_:)), "q"),
        ]))

        bar.addItem(submenu(String(localized: "File"), [
            item(String(localized: "New Transaction"), #selector(CowryActions.newTransaction(_:)), "n"),
            item(String(localized: "New Account or Category…"), #selector(CowryActions.newAccount(_:)), "n", [.command, .shift]),
            .separator(),
            item(String(localized: "Show Ledger in Finder"), #selector(CowryActions.showLibraryInFinder(_:))),
            .separator(),
            item(String(localized: "Close Window"), #selector(NSWindow.performClose(_:)), "w"),
        ]))

        let delete = item(String(localized: "Delete"), #selector(NSText.delete(_:)),
                          String(UnicodeScalar(NSBackspaceCharacter)!), [.command])
        bar.addItem(submenu(String(localized: "Edit"), [
            item(String(localized: "Undo"), Selector(("undo:")), "z"),
            item(String(localized: "Redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"),
            item(String(localized: "Copy"), #selector(NSText.copy(_:)), "c"),
            item(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"),
            item(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item(String(localized: "Duplicate"), #selector(CowryActions.duplicate(_:)), "d"),
            delete,
            .separator(),
            item(String(localized: "Find"), #selector(CowryActions.focusSearch(_:)), "f"),
        ]))

        bar.addItem(submenu(String(localized: "View"), [
            item(String(localized: "Show Sidebar"), #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item(String(localized: "Show Inspector"), #selector(NSSplitViewController.toggleInspector(_:)), "i", [.command, .option]),
            .separator(),
            item(String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        bar.addItem(submenu(String(localized: "Go"), [
            item(String(localized: "Back"), #selector(CowryActions.goBack(_:)), "["),
            item(String(localized: "Forward"), #selector(CowryActions.goForward(_:)), "]"),
            .separator(),
            item(String(localized: "All Transactions"), #selector(CowryActions.showAllTransactions(_:)), "1"),
        ]))

        let window = submenu(String(localized: "Window"), [
            item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))),
            .separator(),
            item(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))),
        ])
        bar.addItem(window)
        NSApp.windowsMenu = window.submenu

        #if DEBUG
        bar.addItem(submenu("Debug", [
            item("Add Sample Data (5 Years)", #selector(CowryActions.addSampleData(_:))),
            item("Add 100,000 Sample Entries", #selector(CowryActions.addLargeSampleData(_:))),
            .separator(),
            item("Verify Ledger", #selector(CowryActions.verifyLedger(_:))),
        ]))
        #endif

        let help = submenu(String(localized: "Help"), [])
        bar.addItem(help)
        NSApp.helpMenu = help.submenu
        return bar
    }

    @MainActor
    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @MainActor
    private static func item(
        _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }
}
