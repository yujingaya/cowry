import AppKit
import Ledger
import LedgerCore

/// The New Account or Category sheet (ux.md §4.7).
@MainActor
final class NewAccountViewController: NSViewController {
    private enum Kind: Int, CaseIterable {
        case money, owed, expense, income

        var type: AccountType {
            switch self {
            case .money: .asset
            case .owed: .liability
            case .expense: .expense
            case .income: .income
            }
        }

        var title: String {
            switch self {
            case .money: String(localized: "Where money is (bank, cash, investments)")
            case .owed: String(localized: "Money owed (cards, loans)")
            case .expense: String(localized: "Spending category")
            case .income: String(localized: "Income category")
            }
        }

        var hasBalance: Bool { self == .money || self == .owed }
    }

    private let model: AppModel
    private let kindPopup = NSPopUpButton()
    private let nameField = NSTextField()
    private let parentPopup = NSPopUpButton()
    private let datePicker = NSDatePicker()
    private let balanceField = NSTextField()
    private let currencyPopup = NSPopUpButton()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var balanceRow: NSGridRow?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for kind in Kind.allCases { kindPopup.addItem(withTitle: kind.title) }
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged(_:))
        nameField.placeholderString = String(localized: "Name")
        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = .yearMonthDay
        datePicker.dateValue = Date()
        balanceField.placeholderString = "0"
        balanceField.alignment = .right
        for commodity in model.commodities where !commodity.archived {
            currencyPopup.addItem(withTitle: commodity.code)
            currencyPopup.lastItem?.representedObject = commodity.id.string
            if commodity.id == model.primary { currencyPopup.select(currencyPopup.lastItem) }
        }
        message.textColor = .systemRed
        message.isHidden = true

        let balance = NSStackView(views: [currencyPopup, balanceField])
        let grid = NSGridView(views: [
            [label(String(localized: "Kind")), kindPopup],
            [label(String(localized: "Name")), nameField],
            [label(String(localized: "Inside")), parentPopup],
            [label(String(localized: "Starts on")), datePicker],
            [label(String(localized: "Starting balance")), balance],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        balanceRow = grid.row(at: 4)
        nameField.widthAnchor.constraint(equalToConstant: 280).isActive = true

        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let create = NSButton(title: String(localized: "Create"), target: self, action: #selector(create(_:)))
        create.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, create])

        let title = NSTextField(labelWithString: String(localized: "New Account or Category"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let stack = NSStackView(views: [title, grid, message, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        view = stack
        kindChanged(nil)
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        return field
    }

    private var kind: Kind {
        Kind(rawValue: kindPopup.indexOfSelectedItem) ?? .money
    }

    @objc private func kindChanged(_ sender: Any?) {
        parentPopup.removeAllItems()
        parentPopup.addItem(withTitle: String(localized: "Top Level"))
        for account in model.postableAccounts([kind.type]) {
            parentPopup.addItem(withTitle: account.path)
            parentPopup.lastItem?.representedObject = account.id.string
        }
        balanceRow?.isHidden = !kind.hasBalance
    }

    @objc private func cancel(_ sender: Any?) {
        dismiss(nil)
    }

    @objc private func create(_ sender: Any?) {
        let parent = (parentPopup.selectedItem?.representedObject as? String).flatMap(Account.ID.init)
        let commodity = (currencyPopup.selectedItem?.representedObject as? String).flatMap(Commodity.ID.init) ?? model.primary
        var balance: (Int64, Commodity.ID)?
        if kind.hasBalance, !balanceField.stringValue.isEmpty {
            guard let amount = model.amounts.parse(balanceField.stringValue, commodity) else {
                message.stringValue = String(localized: "Enter the starting balance as a number.")
                message.isHidden = false
                return
            }
            // Money owed is entered as a positive amount and stored as a credit.
            balance = (kind == .owed ? -amount : amount, commodity)
        }
        let name = nameField.stringValue, type = kind.type, date = DateText.localDate(datePicker.dateValue)
        Task {
            do {
                let account = try await model.openAccount(name: name, type: type, parent: parent, openedOn: date,
                                                          startingBalance: balance.map { ($0.0, $0.1) })
                dismiss(nil)
                model.navigate(to: .account(account.id))
            } catch {
                message.stringValue = model.message(for: error)
                message.isHidden = false
            }
        }
    }
}
