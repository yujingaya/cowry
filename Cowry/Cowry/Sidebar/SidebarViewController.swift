import AppKit
import Ledger
import LedgerCore

/// One row in the sidebar. Rebuilt on every ledger change; `kind` gives it identity across
/// rebuilds so expansion and selection survive.
@MainActor
final class SidebarNode: NSObject {
    enum Kind: Hashable {
        case section(Section)
        case allTransactions
        case account(Account.ID)
    }

    enum Section: Hashable {
        case browse, accounts, spending, income
    }

    let kind: Kind
    let title: String
    let value: String
    let symbol: String?
    let dimmed: Bool
    var children: [SidebarNode]

    init(kind: Kind, title: String, value: String = "", symbol: String? = nil, dimmed: Bool = false,
         children: [SidebarNode] = []) {
        self.kind = kind
        self.title = title
        self.value = value
        self.symbol = symbol
        self.dimmed = dimmed
        self.children = children
    }

    var isSection: Bool {
        if case .section = kind { return true }
        return false
    }
}

/// The sidebar (ux.md §3.3): Browse, Accounts, Spending and Income, with account trees of any depth.
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let model: AppModel
    private let outlineView = NSOutlineView()
    private var roots: [SidebarNode] = []
    private var collapsed: Set<SidebarNode.Kind> = []
    private var isSyncingSelection = false

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Main"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.rowSizeStyle = .default
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.setAccessibilityLabel(String(localized: "Sidebar"))

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.observe(self) { [weak self] event in
            switch event {
            case .ledger: self?.rebuild()
            case .scope: self?.syncSelection()
            default: break
            }
        }
        rebuild()
    }

    // MARK: Building

    private func rebuild() {
        do {
            roots = try makeRoots()
        } catch {
            model.present(error)
            return
        }
        isSyncingSelection = true
        outlineView.reloadData()
        expand(roots)
        isSyncingSelection = false
        syncSelection()
    }

    private func makeRoots() throws -> [SidebarNode] {
        let snapshot = model.snapshot
        let tree = model.tree
        let month = DateText.currentMonth()
        let balances = try snapshot.balances()
        let activity = try snapshot.activity(in: month)
        let monthName = DateText.month(month.lowerBound)

        func total(_ id: Account.ID, _ source: [Account.ID: Holdings]) -> Holdings {
            var sum = source[id] ?? [:]
            for child in tree.children(of: id) {
                for (commodity, amount) in total(child, source) { sum[commodity, default: 0] += amount }
            }
            return sum
        }

        func node(_ id: Account.ID, _ source: [Account.ID: Holdings], sign: Int64) -> SidebarNode {
            let account = tree[id]!
            let holdings = total(id, source).mapValues { $0 * sign }
            return SidebarNode(
                kind: .account(id), title: account.name,
                value: model.amounts.string(holdings, primary: model.primary),
                symbol: account.parent == nil ? symbol(for: account.type) : nil,
                dimmed: account.closedOn != nil,
                children: tree.children(of: id).map { node($0, source, sign: sign) })
        }

        func section(_ section: SidebarNode.Section, _ title: String, _ types: Set<AccountType>,
                     _ source: [Account.ID: Holdings], sign: Int64) -> SidebarNode {
            let rootIDs = tree.roots.filter { tree[$0].map { types.contains($0.type) && $0.role == nil } ?? false }
            var sum: Holdings = [:]
            for id in rootIDs {
                for (commodity, amount) in total(id, source) { sum[commodity, default: 0] += amount * sign }
            }
            return SidebarNode(kind: .section(section), title: title,
                               value: rootIDs.isEmpty ? "" : model.amounts.string(sum, primary: model.primary),
                               children: rootIDs.map { node($0, source, sign: sign) })
        }

        return [
            SidebarNode(kind: .section(.browse), title: String(localized: "Browse"), children: [
                SidebarNode(kind: .allTransactions, title: String(localized: "All Transactions"), symbol: "tray.full"),
            ]),
            section(.accounts, String(localized: "Accounts"), [.asset, .liability], balances, sign: 1),
            section(.spending, String(localized: "Spending · \(monthName)"), [.expense], activity, sign: 1),
            section(.income, String(localized: "Income · \(monthName)"), [.income], activity, sign: -1),
        ]
    }

    private func symbol(for type: AccountType) -> String {
        switch type {
        case .asset: "building.columns"
        case .liability: "creditcard"
        case .expense: "cart"
        case .income: "arrow.down.to.line"
        case .equity: "scalemass"
        }
    }

    private func expand(_ nodes: [SidebarNode]) {
        for node in nodes where !collapsed.contains(node.kind) && !node.children.isEmpty {
            outlineView.expandItem(node)
            expand(node.children)
        }
    }

    private func find(_ kind: SidebarNode.Kind, in nodes: [SidebarNode]) -> SidebarNode? {
        for node in nodes {
            if node.kind == kind { return node }
            if let found = find(kind, in: node.children) { return found }
        }
        return nil
    }

    private func syncSelection() {
        let kind: SidebarNode.Kind = switch model.scope {
        case .all: .allTransactions
        case .account(let id): .account(id)
        }
        guard let node = find(kind, in: roots) else { return }
        var parent = outlineView.parent(forItem: node)
        while let item = parent {
            outlineView.expandItem(item)
            parent = outlineView.parent(forItem: item)
        }
        let row = outlineView.row(forItem: node)
        guard row >= 0, outlineView.selectedRow != row else { return }
        isSyncingSelection = true
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        isSyncingSelection = false
    }

    // MARK: Data source and delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? SidebarNode)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.isSection ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !((item as? SidebarNode)?.isSection ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier(node.isSection ? "Header" : "Row")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarCell
            ?? SidebarCell(identifier: identifier, isHeader: node.isSection)
        cell.configure(node)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, let node = outlineView.item(atRow: outlineView.selectedRow) as? SidebarNode
        else { return }
        switch node.kind {
        case .allTransactions: model.navigate(to: .all)
        case .account(let id): model.navigate(to: .account(id))
        case .section: break
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isSyncingSelection, let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
        collapsed.insert(node.kind)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isSyncingSelection, let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
        collapsed.remove(node.kind)
    }
}

/// A sidebar row: optional symbol, name, and a trailing amount.
@MainActor
final class SidebarCell: NSTableCellView {
    private let valueField = NSTextField(labelWithString: "")
    private let isHeader: Bool

    init(identifier: NSUserInterfaceItemIdentifier, isHeader: Bool) {
        self.isHeader = isHeader
        super.init(frame: .zero)
        self.identifier = identifier

        let title = NSTextField(labelWithString: "")
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = title

        valueField.alignment = .right
        valueField.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: isHeader ? .semibold : .regular)
        valueField.textColor = .secondaryLabelColor
        valueField.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        if !isHeader {
            let image = NSImageView()
            image.symbolConfiguration = .init(scale: .medium)
            imageView = image
            stack.addArrangedSubview(image)
        }
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(valueField)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ node: SidebarNode) {
        textField?.stringValue = node.title
        textField?.textColor = node.dimmed ? .secondaryLabelColor : (isHeader ? .secondaryLabelColor : .labelColor)
        valueField.stringValue = node.value
        if let imageView {
            imageView.image = node.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            imageView.isHidden = node.symbol == nil
        }
        setAccessibilityLabel(node.value.isEmpty ? node.title : "\(node.title), \(node.value)")
    }
}
