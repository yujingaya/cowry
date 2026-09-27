import AppKit
import Ledger
import LedgerCore

/// The primary window: sidebar, list and inspector, with navigation and search in the toolbar.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate,
    NSMenuItemValidation, CowryActions
{
    let model: AppModel
    private let split: MainSplitViewController
    private var navigationGroup: NSToolbarItemGroup?
    private var searchItem: NSSearchToolbarItem?

    private enum Item {
        static let navigation = NSToolbarItem.Identifier("Navigation")
        static let newTransaction = NSToolbarItem.Identifier("NewTransaction")
        static let search = NSToolbarItem.Identifier("Search")
    }

    init(model: AppModel) {
        self.model = model
        split = MainSplitViewController(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 820, height: 480)
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.center()
        window.setFrameAutosaveName("MainWindow")
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar

        model.observe(self) { [weak self] event in
            switch event {
            case .scope, .summary, .ledger: self?.updateTitle()
            case .query: self?.syncSearchField()
            case .selection, .newEntry: break
            }
        }
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func updateTitle() {
        window?.title = model.title(of: model.scope)
        window?.subtitle = model.summary
        navigationGroup?.subitems[0].isEnabled = model.canGoBack
        navigationGroup?.subitems[1].isEnabled = model.canGoForward
        searchItem?.searchField.placeholderString = model.scope == .all
            ? String(localized: "Search All Transactions")
            : String(localized: "Search \(model.title(of: model.scope))")
    }

    private func syncSearchField() {
        guard let field = searchItem?.searchField, field.stringValue != model.query else { return }
        field.stringValue = model.query
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        model.undoManager
    }

    // MARK: Actions

    @objc func newTransaction(_ sender: Any?) {
        split.showInspector()
        model.beginNewEntry()
    }

    @objc func newAccount(_ sender: Any?) {
        split.presentAsSheet(NewAccountViewController(model: model))
    }

    @objc func focusSearch(_ sender: Any?) {
        guard let item = searchItem else { return }
        item.beginSearchInteraction()
    }

    @objc func goBack(_ sender: Any?) {
        model.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        model.goForward()
    }

    @objc func showAllTransactions(_ sender: Any?) {
        model.navigate(to: .all)
    }

    @objc private func navigate(_ sender: NSToolbarItemGroup) {
        sender.selectedIndex == 0 ? model.goBack() : model.goForward()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): model.canGoBack
        case #selector(goForward(_:)): model.canGoForward
        default: true
        }
    }

    // MARK: Search

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        model.query = field.stringValue
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Item.navigation, .flexibleSpace, Item.newTransaction,
         Item.search, .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Item.navigation:
            let group = NSToolbarItemGroup(
                itemIdentifier: identifier,
                images: [NSImage(systemSymbolName: "chevron.left", accessibilityDescription: String(localized: "Back"))!,
                         NSImage(systemSymbolName: "chevron.right", accessibilityDescription: String(localized: "Forward"))!],
                selectionMode: .momentary,
                labels: [String(localized: "Back"), String(localized: "Forward")],
                target: self, action: #selector(navigate(_:)))
            group.label = String(localized: "Back/Forward")
            group.isNavigational = true
            navigationGroup = group
            return group
        case Item.newTransaction:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            item.label = String(localized: "New Transaction")
            item.toolTip = String(localized: "New Transaction (⌘N)")
            item.action = #selector(newTransaction(_:))
            item.target = self
            return item
        case Item.search:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField.delegate = self
            item.preferredWidthForSearchField = 300
            searchItem = item
            updateTitle()
            return item
        default:
            return nil
        }
    }
}

@MainActor
final class MainSplitViewController: NSSplitViewController {
    private let inspectorItem: NSSplitViewItem

    init(model: AppModel) {
        let sidebar = NSSplitViewItem(sidebarWithViewController: SidebarViewController(model: model))
        sidebar.minimumThickness = 200
        sidebar.maximumThickness = 360
        let list = NSSplitViewItem(viewController: EntryListViewController(model: model))
        list.minimumThickness = 420
        inspectorItem = NSSplitViewItem(inspectorWithViewController: InspectorViewController(model: model))
        inspectorItem.minimumThickness = 290
        inspectorItem.maximumThickness = 440
        super.init(nibName: nil, bundle: nil)
        addSplitViewItem(sidebar)
        addSplitViewItem(list)
        addSplitViewItem(inspectorItem)
        splitView.autosaveName = "MainSplit"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func showInspector() {
        if inspectorItem.isCollapsed { inspectorItem.animator().isCollapsed = false }
    }
}
