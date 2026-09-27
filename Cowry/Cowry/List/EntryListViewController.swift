import AppKit
import Ledger
import LedgerCore

/// The list in the middle of the window (ux.md §3.4, design.md §8.3).
///
/// All Transactions keeps only a sorted key array and fetches the rows on screen in batches;
/// change events move, insert and remove single rows instead of reloading. Account and category
/// views are registers with running balances, rebuilt on change.
@MainActor
final class EntryListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Mode {
        case journal
        /// Where money is or is owed: money in, money out, running balance.
        case register(Set<Account.ID>)
        /// Spending or income: one amount column, signed so the category's direction is positive.
        case category(Set<Account.ID>, sign: Int64)
    }

    private enum Column: String, CaseIterable {
        case date, payee, flow, amount, counterpart, account, moneyIn, moneyOut, balance

        var title: String {
            switch self {
            case .date: String(localized: "Date")
            case .payee: String(localized: "Payee")
            case .flow: String(localized: "Flow")
            case .amount: String(localized: "Amount")
            case .counterpart: String(localized: "Counterpart")
            case .account: String(localized: "Account")
            case .moneyIn: String(localized: "Money In")
            case .moneyOut: String(localized: "Money Out")
            case .balance: String(localized: "Balance")
            }
        }

        var width: CGFloat {
            switch self {
            case .date: 110
            case .payee: 220
            case .flow: 220
            case .counterpart, .account: 150
            case .amount, .moneyIn, .moneyOut, .balance: 120
            }
        }

        var isNumeric: Bool {
            switch self {
            case .amount, .moneyIn, .moneyOut, .balance: true
            default: false
            }
        }
    }

    private let model: AppModel
    private let tableView = EntryTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private var mode = Mode.journal
    private var filter = JournalFilter.all

    /// Journal mode: sort keys of every visible row, and where each entry sits.
    private var keys: [JournalKey] = []
    private var keyByID: [Entry.ID: JournalKey] = [:]
    /// Register and category modes.
    private var registerRows: [RegisterRow] = []

    private var cache: [Entry.ID: Entry] = [:]
    private var isApplyingSelection = false
    /// Selection requested before its rows existed (e.g. an entry just posted).
    private var pendingSelection: [Entry.ID] = []

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 34
        tableView.usesAutomaticRowHeights = false
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.intercellSpacing = NSSize(width: 12, height: 0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onDelete = { [weak self] in self?.deleteSelection() }
        tableView.setAccessibilityLabel(String(localized: "Transactions"))

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        let container = NSView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.observe(self) { [weak self] event in
            guard let self else { return }
            switch event {
            case .ledger(let change): self.apply(change)
            case .scope: self.reload(scrollToEnd: true)
            case .query: self.reload(scrollToEnd: false)
            case .selection: self.syncSelection()
            case .summary, .newEntry: break
            }
        }
        reload(scrollToEnd: true)
    }

    // MARK: Loading

    private var rowCount: Int {
        switch mode {
        case .journal: keys.count
        case .register, .category: registerRows.count
        }
    }

    private func entryID(at row: Int) -> Entry.ID {
        switch mode {
        case .journal: keys[row].id
        case .register, .category: registerRows[row].key.id
        }
    }

    private func key(at row: Int) -> JournalKey {
        switch mode {
        case .journal: keys[row]
        case .register, .category: registerRows[row].key
        }
    }

    private func configureMode() {
        let query = model.query.isEmpty ? nil : model.query
        switch model.scope {
        case .all:
            mode = .journal
            filter = JournalFilter(text: query)
        case .account(let id):
            let accounts = model.tree.subtree(of: id)
            filter = JournalFilter(accounts: accounts, text: query)
            switch model.account(id)?.type {
            case .asset, .liability, .equity, nil: mode = .register(accounts)
            case .expense: mode = .category(accounts, sign: 1)
            case .income: mode = .category(accounts, sign: -1)
            }
        }
    }

    private var columns: [Column] {
        switch mode {
        case .journal: [.date, .payee, .flow, .amount]
        case .register: model.query.isEmpty
            ? [.date, .payee, .counterpart, .moneyIn, .moneyOut, .balance]
            : [.date, .payee, .counterpart, .moneyIn, .moneyOut]
        case .category: [.date, .payee, .account, .amount]
        }
    }

    private func installColumns() {
        let wanted = columns
        guard tableView.tableColumns.map(\.identifier.rawValue) != wanted.map(\.rawValue) else { return }
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        for column in wanted {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 60
            if column.isNumeric { tableColumn.headerCell.alignment = .right }
            tableColumn.resizingMask = column == .payee ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            tableView.addTableColumn(tableColumn)
        }
        if let payee = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == Column.payee.rawValue }),
           payee != 0 {
            tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        }
    }

    /// Rebuilds the list from scratch: on scope and query changes, and for large changes.
    private func reload(scrollToEnd: Bool) {
        Perf.measure("list reload (\(model.query.isEmpty ? "all" : "query"))") { reloadNow(scrollToEnd: scrollToEnd) }
    }

    private func reloadNow(scrollToEnd: Bool) {
        // Empty the table before switching mode and columns. Adding a column makes NSTableView
        // fetch cells for the rows it still shows, which would index the new mode's data before
        // it's loaded. Emptying clears the table's selection, so keep that from reaching the model;
        // syncSelection restores it below.
        isApplyingSelection = true
        keys = []
        keyByID = [:]
        registerRows = []
        cache = [:]
        tableView.reloadData()
        configureMode()
        installColumns()
        isApplyingSelection = false
        do {
            switch mode {
            case .journal:
                keys = try model.snapshot.journal(filter).keys
                keyByID = Dictionary(uniqueKeysWithValues: keys.map { ($0.id, $0) })
            case .register(let accounts), .category(let accounts, _):
                let register = try model.snapshot.register(of: accounts)
                if model.query.isEmpty {
                    registerRows = register.rows
                } else {
                    let matching = Set(try model.snapshot.journal(filter).keys.map(\.id))
                    registerRows = register.rows.filter { matching.contains($0.key.id) }
                }
            }
        } catch {
            model.present(error)
        }
        tableView.reloadData()
        if scrollToEnd, rowCount > 0 { tableView.scrollRowToVisible(rowCount - 1) }
        syncSelection()
        updateSummaryAndEmptyState()
    }

    /// Applies a change event. The journal moves single rows; registers rebuild.
    private func apply(_ change: LedgerChange) {
        Perf.measure("list apply \(change.entries.count) changes") { applyNow(change) }
    }

    private func applyNow(_ change: LedgerChange) {
        for id in change.entries { cache.removeValue(forKey: id) }
        if !change.accounts.isEmpty || !change.commodities.isEmpty { cache = [:] }

        guard case .journal = mode, change.entries.count <= 500 else {
            let visible = tableView.rows(in: tableView.visibleRect)
            reload(scrollToEnd: false)
            if visible.location != NSNotFound { tableView.scroll(NSPoint(x: 0, y: tableView.rect(ofRow: visible.location).minY)) }
            return
        }

        let newKeys: [JournalKey]
        do {
            newKeys = try change.snapshot.journalKeys(of: change.entries, matching: filter)
        } catch {
            model.present(error)
            return
        }
        let newByID = Dictionary(uniqueKeysWithValues: newKeys.map { ($0.id, $0) })
        let index = JournalIndex(keys: keys)

        tableView.beginUpdates()
        // Rows whose key didn't change are updated in place.
        var inPlace = IndexSet()
        var removals: [Int] = []
        for id in change.entries {
            guard let old = keyByID[id], let row = index.index(of: old) else { continue }
            if newByID[id] == old { inPlace.insert(row) } else { removals.append(row) }
        }
        for row in removals.sorted(by: >) {
            keyByID.removeValue(forKey: keys[row].id)
            keys.remove(at: row)
        }
        tableView.removeRows(at: IndexSet(removals), withAnimation: .effectFade)
        for key in newKeys.sorted() where keyByID[key.id] == nil {
            let row = JournalIndex(keys: keys).insertionIndex(of: key)
            keys.insert(key, at: row)
            keyByID[key.id] = key
            tableView.insertRows(at: [row], withAnimation: .effectFade)
        }
        tableView.endUpdates()

        // Neighbouring rows may show or hide their date; account names may have changed.
        let visible = tableView.rows(in: tableView.visibleRect)
        if visible.location != NSNotFound {
            var rows = IndexSet(integersIn: visible.location ..< visible.location + visible.length)
            rows.formUnion(inPlace)
            tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0 ..< tableView.numberOfColumns))
        }
        syncSelection()
        updateSummaryAndEmptyState()
    }

    private func entry(at row: Int) -> Entry? {
        let id = entryID(at: row)
        if let cached = cache[id] { return cached }
        // Fetch a window of rows around the requested one in a single read.
        let lower = max(0, row - 60), upper = min(rowCount, row + 60)
        let ids = (lower ..< upper).map(entryID(at:)).filter { cache[$0] == nil }
        do {
            for entry in try model.snapshot.entries(ids) { cache[entry.id] = entry }
        } catch {
            return nil
        }
        return cache[id]
    }

    private func updateSummaryAndEmptyState() {
        let count = rowCount
        switch mode {
        case .journal:
            model.summary = model.query.isEmpty
                ? String(localized: "\(count) transactions")
                : String(localized: "\(count) matching")
        case .register:
            let balance = registerRows.last?.balance ?? [:]
            model.summary = model.query.isEmpty
                ? String(localized: "Balance \(model.amounts.string(balance, primary: model.primary))")
                : String(localized: "\(count) matching")
        case .category(_, let sign):
            var total: Holdings = [:]
            for row in registerRows { for (c, a) in row.amounts { total[c, default: 0] += a * sign } }
            model.summary = String(localized: "\(count) transactions · \(model.amounts.string(total, primary: model.primary))")
        }

        if count > 0 {
            emptyLabel.isHidden = true
        } else {
            emptyLabel.isHidden = false
            emptyLabel.stringValue = model.query.isEmpty
                ? String(localized: "No transactions yet.\nChoose File › New Transaction (⌘N) to record one.")
                : String(localized: "No transactions match “\(model.query)”.")
        }
    }

    // MARK: Selection

    private func syncSelection() {
        let wanted = model.selection
        var rows = IndexSet()
        var missing: [Entry.ID] = []
        for id in wanted {
            if let row = row(of: id) { rows.insert(row) } else { missing.append(id) }
        }
        pendingSelection = missing
        guard rows != tableView.selectedRowIndexes else { return }
        isApplyingSelection = true
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { tableView.scrollRowToVisible(first) }
        isApplyingSelection = false
    }

    private func row(of id: Entry.ID) -> Int? {
        switch mode {
        case .journal:
            guard let key = keyByID[id] else { return nil }
            return JournalIndex(keys: keys).index(of: key)
        case .register, .category:
            return registerRows.firstIndex { $0.key.id == id }
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        model.selection = tableView.selectedRowIndexes.map(entryID(at:))
    }

    // MARK: Commands

    private func deleteSelection() {
        let entries = tableView.selectedRowIndexes.compactMap(entry(at:))
        Task { await model.delete(entries) }
    }

    @objc func delete(_ sender: Any?) {
        deleteSelection()
    }

    @objc func duplicate(_ sender: Any?) {
        guard let row = tableView.selectedRowIndexes.first, let entry = entry(at: row) else { return }
        var draft = EntryDraft(entry)
        draft.date = LocalDate.today()
        Task {
            do {
                let copy = try await model.post(draft)
                model.selection = [copy.id]
            } catch {
                model.present(error)
            }
        }
    }

    /// Copies the selected rows as tab-separated text, ready to paste into a spreadsheet.
    @objc func copy(_ sender: Any?) {
        let lines = tableView.selectedRowIndexes.compactMap { row -> String? in
            guard let entry = entry(at: row) else { return nil }
            let flow = EntryFlow(entry)
            return [entry.date.description, entry.payee ?? "", model.flowText(entry),
                    model.amounts.editingString(flow.amount, flow.commodity), entry.memo ?? ""]
                .joined(separator: "\t")
        }
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(delete(_:)), #selector(copy(_:)): !tableView.selectedRowIndexes.isEmpty
        case #selector(duplicate(_:)): tableView.selectedRowIndexes.count == 1
        default: true
        }
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rowCount
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rowCount, let identifier = tableColumn?.identifier,
              let column = Column(rawValue: identifier.rawValue)
        else { return nil }
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? EntryCell
            ?? EntryCell(identifier: identifier, numeric: column.isNumeric)
        let key = key(at: row)
        let entry = entry(at: row)
        let (text, secondary, dimmed) = content(column, row: row, key: key, entry: entry)
        cell.configure(text, secondary: secondary, dimmed: dimmed)
        return cell
    }

    private func content(
        _ column: Column, row: Int, key: JournalKey, entry: Entry?
    ) -> (String, String?, Bool) {
        let amounts = model.amounts
        switch column {
        case .date:
            let repeated = row > 0 && self.key(at: row - 1).date == key.date
            return (DateText.short(key.date), nil, repeated)
        case .payee:
            return (entry?.payee ?? "—", nil, entry?.payee == nil)
        case .flow:
            return (entry.map(model.flowText) ?? "", nil, true)
        case .amount:
            if case .category(_, let sign) = mode {
                let amounts = registerRows[row].amounts.mapValues { $0 * sign }
                return (model.amounts.string(amounts, primary: model.primary), nil, false)
            }
            guard let entry else { return ("", nil, false) }
            let flow = EntryFlow(entry)
            return (amounts.string(flow.amount, flow.commodity),
                    flow.counterAmount.map { amounts.string($0, flow.counterCommodity!) }, false)
        case .counterpart, .account:
            guard let entry else { return ("", nil, true) }
            switch mode {
            case .register(let accounts), .category(let accounts, _):
                return (otherSide(of: entry, excluding: accounts), nil, true)
            case .journal:
                return ("", nil, true)
            }
        case .moneyIn, .moneyOut:
            let movement = registerRows[row].amounts
            let wantPositive = column == .moneyIn
            let part = movement.filter { wantPositive ? $0.value > 0 : $0.value < 0 }.mapValues(abs)
            return (part.isEmpty ? "" : amounts.string(part, primary: model.primary), nil, false)
        case .balance:
            return (amounts.string(registerRows[row].balance, primary: model.primary), nil, false)
        }
    }

    /// Names of the accounts on the other side of an entry, seen from `accounts`.
    private func otherSide(of entry: Entry, excluding accounts: Set<Account.ID>) -> String {
        var seen = Set<Account.ID>()
        let others = entry.userPostings.map { model.resolved($0.account) }
            .filter { !accounts.contains($0) && seen.insert($0).inserted }
        guard let first = others.first else { return "—" }
        let name = model.name(of: first)
        return others.count == 1 ? name : String(localized: "\(name) + \(others.count - 1) more")
    }
}

/// Handles the Delete key, which `NSTableView` otherwise ignores.
@MainActor
final class EntryTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.unicodeScalars.first.map { Int($0.value) }
        if key == NSDeleteCharacter || key == NSDeleteFunctionKey {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// A list cell: one line of text, with an optional smaller second line (the charged amount of a
/// foreign purchase).
@MainActor
final class EntryCell: NSTableCellView {
    private let primary = NSTextField(labelWithString: "")
    private let secondary = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, numeric: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier
        for field in [primary, secondary] {
            field.lineBreakMode = .byTruncatingTail
            field.alignment = numeric ? .right : .left
            field.font = numeric ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                : .systemFont(ofSize: NSFont.systemFontSize)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        secondary.font = numeric ? .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.smallSystemFontSize)
        secondary.textColor = .secondaryLabelColor
        textField = primary

        let stack = NSStackView(views: [primary, secondary])
        stack.orientation = .vertical
        stack.alignment = numeric ? .trailing : .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            primary.widthAnchor.constraint(equalTo: stack.widthAnchor),
            secondary.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String, secondary second: String?, dimmed: Bool) {
        primary.stringValue = text
        primary.textColor = dimmed ? .secondaryLabelColor : .labelColor
        secondary.stringValue = second ?? ""
        secondary.isHidden = second == nil
        setAccessibilityLabel(second.map { "\(text), \($0)" } ?? text)
    }
}
