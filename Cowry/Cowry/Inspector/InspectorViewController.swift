import AppKit
import Ledger
import LedgerCore

/// The inspector (ux.md §3.5, §4.1): shows the selected entry and edits it in place, and hosts
/// the form for a new entry. The same form serves both, so there is no separate edit mode.
///
/// Edits to an existing entry are recorded when the selection moves on or Return is pressed;
/// Escape reverts them. One edited entry becomes one op.
@MainActor
final class InspectorViewController: NSViewController, NSTextFieldDelegate, NSComboBoxDataSource,
    NSComboBoxDelegate
{
    /// Everyday transaction kinds. Derived from accounts, never stored (ux.md §2).
    private enum Kind: Int {
        case spending, income, transfer
    }

    private enum State {
        case empty
        case multiple(Int)
        case entry(Entry)
        case draft
    }

    private enum FormError: Error {
        case amount, secondAmount, target, source
    }

    private let model: AppModel
    private var state = State.empty
    private var isDirty = false
    private var isComplex = false
    private var suggestions: [Entry] = []
    private var accountIDs: [String: Account.ID] = [:]

    // Views
    private let placeholder = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let content = NSStackView()
    private let heading = NSTextField(labelWithString: String(localized: "New Transaction"))
    private let kindControl = NSSegmentedControl(
        labels: [String(localized: "Spending"), String(localized: "Income"), String(localized: "Transfer")],
        trackingMode: .selectOne, target: nil, action: nil)
    private let grid = NSGridView()
    private let payeeBox = NSComboBox()
    private let datePicker = NSDatePicker()
    private let amountLabel = InspectorViewController.label("")
    private let amountField = NSTextField()
    private let currencyPopup = NSPopUpButton()
    private let secondLabel = InspectorViewController.label("")
    private let secondField = NSTextField()
    private let secondPopup = NSPopUpButton()
    private let rateLabel = NSTextField(labelWithString: "")
    private let targetLabel = InspectorViewController.label("")
    private let targetBox = NSComboBox()
    private let sourceLabel = InspectorViewController.label("")
    private let sourceBox = NSComboBox()
    private let memoField = NSTextField()
    private let linesField = NSTextField(wrappingLabelWithString: "")
    private let messageField = NSTextField(wrappingLabelWithString: "")
    private let buttons = NSStackView()
    private let recordButton = NSButton(title: String(localized: "Record"), target: nil, action: nil)
    private let historyHeader = NSTextField(labelWithString: "")
    private let historyStack = NSStackView()

    private enum Row: Int {
        case payee, date, amount, second, rate, target, source, memo, lines
    }

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return field
    }

    override func loadView() {
        heading.font = .systemFont(ofSize: 17, weight: .semibold)

        kindControl.target = self
        kindControl.action = #selector(kindChanged(_:))
        kindControl.selectedSegment = 0

        payeeBox.usesDataSource = true
        payeeBox.dataSource = self
        payeeBox.delegate = self
        payeeBox.completes = true
        payeeBox.font = .systemFont(ofSize: 15, weight: .semibold)
        payeeBox.placeholderString = String(localized: "Payee")
        payeeBox.setAccessibilityLabel(String(localized: "Payee"))

        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = .yearMonthDay
        datePicker.target = self
        datePicker.action = #selector(fieldChanged(_:))

        for field in [amountField, secondField] {
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            field.delegate = self
        }
        secondField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        for popup in [currencyPopup, secondPopup] {
            popup.target = self
            popup.action = #selector(currencyChanged(_:))
            popup.controlSize = .small
        }
        rateLabel.textColor = .secondaryLabelColor
        rateLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        rateLabel.alignment = .right

        for box in [targetBox, sourceBox] {
            box.completes = true
            box.delegate = self
        }
        memoField.delegate = self
        memoField.placeholderString = String(localized: "No memo")
        linesField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        grid.columnSpacing = 8
        grid.rowSpacing = 8
        grid.addRow(with: [Self.label(String(localized: "Payee")), payeeBox])
        grid.addRow(with: [Self.label(String(localized: "Date")), datePicker])
        grid.addRow(with: [amountLabel, pair(currencyPopup, amountField)])
        grid.addRow(with: [secondLabel, pair(secondPopup, secondField)])
        grid.addRow(with: [NSGridCell.emptyContentView, rateLabel])
        grid.addRow(with: [targetLabel, targetBox])
        grid.addRow(with: [sourceLabel, sourceBox])
        grid.addRow(with: [Self.label(String(localized: "Memo")), memoField])
        grid.addRow(with: [Self.label(String(localized: "Lines")), linesField])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 76
        grid.rowAlignment = .firstBaseline
        grid.cell(for: rateLabel)?.xPlacement = .trailing

        messageField.textColor = .systemRed
        messageField.isHidden = true

        let discard = NSButton(title: String(localized: "Discard"), target: self, action: #selector(discard(_:)))
        discard.bezelStyle = .push
        let recordAndNew = NSButton(title: String(localized: "Record and New"), target: self,
                                    action: #selector(recordAndNew(_:)))
        recordAndNew.keyEquivalent = "\r"
        recordAndNew.keyEquivalentModifierMask = [.command]
        recordButton.target = self
        recordButton.action = #selector(record(_:))
        recordButton.keyEquivalent = "\r"
        recordButton.bezelColor = .controlAccentColor
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addArrangedSubview(discard)
        buttons.addArrangedSubview(NSView())
        buttons.addArrangedSubview(recordAndNew)
        buttons.addArrangedSubview(recordButton)

        historyHeader.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        historyHeader.textColor = .secondaryLabelColor
        historyStack.orientation = .vertical
        historyStack.alignment = .leading
        historyStack.spacing = 4

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [heading, kindControl, grid, messageField, buttons, historyHeader, historyStack] as [NSView] {
            content.addArrangedSubview(view)
        }
        for view in [grid, messageField, buttons] as [NSView] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true
        }

        let document = FlippedView()
        document.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
        ])
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true

        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scrollView)
        container.addSubview(placeholder)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
    }

    private func pair(_ popup: NSPopUpButton, _ field: NSTextField) -> NSView {
        let stack = NSStackView(views: [popup, field])
        stack.orientation = .horizontal
        stack.spacing = 6
        popup.setContentHuggingPriority(.required, for: .horizontal)
        return stack
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.observe(self) { [weak self] event in
            guard let self else { return }
            switch event {
            case .selection: self.selectionChanged()
            case .newEntry: self.beginDraft()
            case .ledger(let change): self.ledgerChanged(change)
            case .scope, .query, .summary: break
            }
        }
        render(.empty)
    }

    // MARK: State

    private func selectionChanged() {
        if case .draft = state, model.selection.isEmpty { return }
        commitIfNeeded()
        switch model.selection.count {
        case 0: render(.empty)
        case 1:
            let fresh = model.ledger.snapshot()
            if let entry = try? fresh.entry(model.selection[0]) { render(.entry(entry)) } else { render(.empty) }
        default: render(.multiple(model.selection.count))
        }
    }

    private func ledgerChanged(_ change: LedgerChange) {
        guard case .entry(let shown) = state, change.entries.contains(shown.id), !isDirty else {
            if !change.accounts.isEmpty || !change.commodities.isEmpty { reloadChoices() }
            return
        }
        if let entry = try? change.snapshot.entry(shown.id) { render(.entry(entry)) } else { render(.empty) }
    }

    private func beginDraft() {
        commitIfNeeded()
        render(.draft)
        view.window?.makeFirstResponder(amountField)
    }

    private func render(_ newState: State) {
        state = newState
        isDirty = false
        messageField.isHidden = true
        reloadChoices()

        switch newState {
        case .empty, .multiple:
            scrollView.isHidden = true
            placeholder.isHidden = false
            if case .multiple(let count) = newState {
                placeholder.stringValue = String(localized: "\(count) transactions selected")
            } else {
                placeholder.stringValue = String(localized: "No Selection")
            }
        case .draft:
            scrollView.isHidden = false
            placeholder.isHidden = true
            heading.isHidden = false
            buttons.isHidden = false
            isComplex = false
            setKind(.spending)
            payeeBox.stringValue = ""
            datePicker.dateValue = DateText.date(LocalDate.today())
            select(currencyPopup, model.primary)
            select(secondPopup, model.primary)
            amountField.stringValue = ""
            secondField.stringValue = ""
            targetBox.stringValue = ""
            sourceBox.stringValue = ""
            memoField.stringValue = ""
            updateRows()
            showHistory(nil)
        case .entry(let entry):
            scrollView.isHidden = false
            placeholder.isHidden = true
            heading.isHidden = true
            buttons.isHidden = true
            fill(from: entry, keepPayeeAndDate: false)
            showHistory(entry)
        }
    }

    /// Fills the form from an entry. For autofill, payee and date stay as typed.
    private func fill(from entry: Entry, keepPayeeAndDate: Bool) {
        if !keepPayeeAndDate {
            payeeBox.stringValue = entry.payee ?? ""
            datePicker.dateValue = DateText.date(entry.date)
            memoField.stringValue = entry.memo ?? ""
        }
        let postings = entry.userPostings
        let debits = postings.filter { $0.amount > 0 }
        let credits = postings.filter { $0.amount < 0 }
        isComplex = !(debits.count == 1 && credits.count == 1)
        if isComplex {
            linesField.stringValue = postings.map { posting in
                "\(model.path(of: posting.account))  \(model.amounts.string(posting.amount, posting.commodity))"
            }.joined(separator: "\n")
            updateRows()
            return
        }
        let debit = debits[0], credit = credits[0]
        let debitType = model.account(model.resolved(debit.account))?.type
        let creditType = model.account(model.resolved(credit.account))?.type
        let kind: Kind = debitType == .expense ? .spending : (creditType == .income ? .income : .transfer)
        setKind(kind)
        // The primary amount belongs to the category side; the second to the account side.
        let (first, second): (Posting, Posting) = switch kind {
        case .spending: (debit, credit)
        case .income, .transfer: (credit, debit)
        }
        select(currencyPopup, first.commodity)
        select(secondPopup, second.commodity)
        amountField.stringValue = model.amounts.editingString(abs(first.amount), first.commodity)
        secondField.stringValue = model.amounts.editingString(abs(second.amount), second.commodity)
        targetBox.stringValue = model.path(of: debit.account)
        sourceBox.stringValue = model.path(of: credit.account)
        updateRows()
    }

    private func setKind(_ kind: Kind) {
        kindControl.selectedSegment = kind.rawValue
        switch kind {
        case .spending:
            amountLabel.stringValue = String(localized: "Amount")
            secondLabel.stringValue = String(localized: "Charged")
            targetLabel.stringValue = String(localized: "Category")
            sourceLabel.stringValue = String(localized: "Paid with")
        case .income:
            amountLabel.stringValue = String(localized: "Amount")
            secondLabel.stringValue = String(localized: "Received")
            targetLabel.stringValue = String(localized: "Deposited to")
            sourceLabel.stringValue = String(localized: "Category")
        case .transfer:
            amountLabel.stringValue = String(localized: "Sent")
            secondLabel.stringValue = String(localized: "Received")
            targetLabel.stringValue = String(localized: "To")
            sourceLabel.stringValue = String(localized: "From")
        }
        reloadChoices()
    }

    private var kind: Kind {
        Kind(rawValue: kindControl.selectedSegment) ?? .spending
    }

    /// Shows the rows that apply: the second amount only when two currencies are involved.
    private func updateRows() {
        let twoCurrencies = selectedCommodity(currencyPopup) != selectedCommodity(secondPopup)
        kindControl.isHidden = isComplex
        grid.row(at: Row.amount.rawValue).isHidden = isComplex
        grid.row(at: Row.second.rawValue).isHidden = isComplex || !twoCurrencies
        grid.row(at: Row.rate.rawValue).isHidden = isComplex || !twoCurrencies
        grid.row(at: Row.target.rawValue).isHidden = isComplex
        grid.row(at: Row.source.rawValue).isHidden = isComplex
        grid.row(at: Row.lines.rawValue).isHidden = !isComplex
        updateRate()
    }

    private func updateRate() {
        guard let a = selectedCommodity(currencyPopup), let b = selectedCommodity(secondPopup), a != b,
              let first = model.amounts.parse(amountField.stringValue, a), first > 0,
              let second = model.amounts.parse(secondField.stringValue, b), second > 0
        else {
            rateLabel.stringValue = ""
            return
        }
        // Rate as units of the second commodity per one unit of the first.
        let rate = (Decimal(second) / pow(10, model.amounts.scale(of: b)))
            / (Decimal(first) / pow(10, model.amounts.scale(of: a)))
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 4
        let codeA = model.amounts.commodity(a)?.code ?? "", codeB = model.amounts.commodity(b)?.code ?? ""
        rateLabel.stringValue = String(localized: "Rate: 1 \(codeA) = \(formatter.string(from: rate as NSDecimalNumber) ?? "") \(codeB)")
    }

    private func reloadChoices() {
        let commodities = model.commodities.filter { !$0.archived }
        for popup in [currencyPopup, secondPopup] {
            let selected = selectedCommodity(popup)
            popup.removeAllItems()
            for commodity in commodities {
                popup.addItem(withTitle: commodity.code)
                popup.lastItem?.representedObject = commodity.id.string
            }
            if let selected { select(popup, selected) }
        }

        let money: Set<AccountType> = [.asset, .liability]
        let (targets, sources): (Set<AccountType>, Set<AccountType>) = switch kind {
        case .spending: ([.expense], money)
        case .income: (money, [.income])
        case .transfer: (money, money)
        }
        accountIDs = [:]
        for (box, types) in [(targetBox, targets), (sourceBox, sources)] {
            let accounts = model.postableAccounts(types)
            box.removeAllItems()
            box.addItems(withObjectValues: accounts.map(\.path))
            for account in accounts { accountIDs[account.path] = account.id }
        }
    }

    private func select(_ popup: NSPopUpButton, _ commodity: Commodity.ID) {
        if let index = popup.itemArray.firstIndex(where: { $0.representedObject as? String == commodity.string }) {
            popup.selectItem(at: index)
        }
    }

    private func selectedCommodity(_ popup: NSPopUpButton) -> Commodity.ID? {
        (popup.selectedItem?.representedObject as? String).flatMap(Commodity.ID.init)
    }

    private func account(in box: NSComboBox) -> Account.ID? {
        let text = box.stringValue.trimmingCharacters(in: .whitespaces)
        if let id = accountIDs[text] { return id }
        // Accept an account's own name when it's unambiguous.
        let matches = accountIDs.filter { $0.key.split(separator: ":").last.map(String.init) == text }
        return matches.count == 1 ? matches.first?.value : nil
    }

    private func showHistory(_ entry: Entry?) {
        historyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let entry, let ops = try? model.ledger.snapshot().history(of: entry.id) else {
            historyHeader.isHidden = true
            historyStack.isHidden = true
            return
        }
        historyHeader.isHidden = false
        historyStack.isHidden = false
        historyHeader.stringValue = String(localized: "History (\(ops.count))")
        for op in ops.reversed() {
            let what: String = switch op.kind {
            case .postEntry: String(localized: "Recorded")
            case .amendEntry: String(localized: "Edited")
            case .voidEntry: String(localized: "Deleted")
            default: op.kind.rawValue
            }
            let line = NSTextField(labelWithString: "\(DateText.time(op.at)) · \(what)")
            line.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            line.textColor = .secondaryLabelColor
            historyStack.addArrangedSubview(line)
        }
    }

    // MARK: Building the entry

    private func buildDraft() throws -> EntryDraft {
        let date = DateText.localDate(datePicker.dateValue)
        let payee = payeeBox.stringValue
        let memo = memoField.stringValue
        if isComplex, case .entry(let entry) = state {
            return EntryDraft(date: date, payee: payee, memo: memo, postings: entry.userPostings)
        }
        guard let a = selectedCommodity(currencyPopup), let b = selectedCommodity(secondPopup) else {
            throw FormError.amount
        }
        guard let first = model.amounts.parse(amountField.stringValue, a), first > 0 else { throw FormError.amount }
        let second: Int64
        if a == b {
            second = first
        } else {
            guard let parsed = model.amounts.parse(secondField.stringValue, b), parsed > 0 else {
                throw FormError.secondAmount
            }
            second = parsed
        }
        guard let target = account(in: targetBox) else { throw FormError.target }
        guard let source = account(in: sourceBox) else { throw FormError.source }
        let postings: [Posting] = switch kind {
        case .spending:
            [Posting(account: target, commodity: a, amount: first), Posting(account: source, commodity: b, amount: -second)]
        case .income, .transfer:
            [Posting(account: target, commodity: b, amount: second), Posting(account: source, commodity: a, amount: -first)]
        }
        return EntryDraft(date: date, payee: payee, memo: memo, postings: postings)
    }

    private func show(_ error: Error) {
        messageField.isHidden = false
        switch error {
        case FormError.amount: messageField.stringValue = String(localized: "Enter an amount greater than zero.")
        case FormError.secondAmount: messageField.stringValue = String(localized: "Enter an amount for “\(secondLabel.stringValue)”.")
        case FormError.target, FormError.source:
            let label = error as? FormError == .target ? targetLabel.stringValue : sourceLabel.stringValue
            messageField.stringValue = String(localized: "Choose an account for “\(label)”.")
        default: messageField.stringValue = model.message(for: error)
        }
    }

    // MARK: Committing

    /// Records pending edits to the shown entry (on selection change or Return).
    private func commitIfNeeded() {
        guard isDirty, case .entry(let entry) = state else { return }
        isDirty = false
        let draft: EntryDraft
        do { draft = try buildDraft() } catch {
            show(error)
            return
        }
        Task {
            do {
                try await model.amend(entry, to: draft)
            } catch let error as ValidationError {
                if case .staleRevision = error, let fresh = try? model.ledger.snapshot().entry(entry.id) {
                    render(.entry(fresh))
                }
                show(error)
            } catch {
                show(error)
            }
        }
    }

    private func recordDraft(andNew: Bool) {
        let draft: EntryDraft
        do { draft = try buildDraft() } catch {
            show(error)
            return
        }
        Task {
            do {
                let entry = try await model.post(draft)
                if andNew {
                    let kind = self.kind, source = sourceBox.stringValue, date = datePicker.dateValue
                    render(.draft)
                    setKind(kind)
                    sourceBox.stringValue = source
                    datePicker.dateValue = date
                    view.window?.makeFirstResponder(amountField)
                } else {
                    state = .empty
                    model.selection = [entry.id]
                    if model.selection == [entry.id] { selectionChanged() }
                }
            } catch {
                show(error)
            }
        }
    }

    @objc private func record(_ sender: Any?) {
        recordDraft(andNew: false)
    }

    @objc private func recordAndNew(_ sender: Any?) {
        recordDraft(andNew: true)
    }

    @objc private func discard(_ sender: Any?) {
        selectionChanged()
        if case .draft = state { render(.empty) }
    }

    override func cancelOperation(_ sender: Any?) {
        switch state {
        case .draft: discard(sender)
        case .entry(let entry): render(.entry(entry))
        default: break
        }
    }

    // MARK: Control events

    @objc private func kindChanged(_ sender: NSSegmentedControl) {
        setKind(kind)
        targetBox.stringValue = ""
        sourceBox.stringValue = ""
        isDirty = true
    }

    @objc private func currencyChanged(_ sender: NSPopUpButton) {
        updateRows()
        isDirty = true
    }

    @objc private func fieldChanged(_ sender: Any?) {
        isDirty = true
    }

    func controlTextDidChange(_ notification: Notification) {
        isDirty = true
        messageField.isHidden = true
        if notification.object as? NSComboBox === payeeBox {
            suggestions = (try? model.snapshot.payeeSuggestions(matching: payeeBox.stringValue)) ?? []
            payeeBox.reloadData()
        }
        if notification.object as? NSTextField === amountField || notification.object as? NSTextField === secondField {
            updateRate()
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSComboBox === payeeBox { autofill() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        switch state {
        case .entry: commitIfNeeded()
        case .draft: recordDraft(andNew: false)
        default: return false
        }
        return true
    }

    /// Fills category, account and amount from the payee's last entry, for new entries only.
    private func autofill() {
        guard case .draft = state, amountField.stringValue.isEmpty, targetBox.stringValue.isEmpty,
              let match = suggestions.first(where: { $0.payee == payeeBox.stringValue })
        else { return }
        fill(from: match, keepPayeeAndDate: true)
        if isComplex {
            isComplex = false
            updateRows()
            return
        }
        amountField.currentEditor()?.selectAll(nil)
    }

    // MARK: Combo box data source

    func numberOfItems(in comboBox: NSComboBox) -> Int {
        suggestions.count
    }

    func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        suggestions[index].payee
    }

    func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
        suggestions.first { $0.payee?.hasPrefix(string) == true }?.payee
    }

    func comboBox(_ comboBox: NSComboBox, indexOfItemWithStringValue string: String) -> Int {
        suggestions.firstIndex { $0.payee == string } ?? NSNotFound
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        isDirty = true
        if notification.object as? NSComboBox === payeeBox, payeeBox.indexOfSelectedItem >= 0 {
            payeeBox.stringValue = suggestions[payeeBox.indexOfSelectedItem].payee ?? ""
            autofill()
        }
    }
}

/// A document view that lays out from the top, for scroll views.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
