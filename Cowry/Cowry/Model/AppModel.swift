import AppKit
import Ledger
import LedgerCore

/// What the window is showing: every entry, or one account or category with everything under it.
enum Scope: Hashable {
    case all
    case account(Account.ID)
}

/// Shared state of one ledger window: the latest snapshot, navigation, search, selection, and
/// every command the UI can issue. Commands register their inverse with the undo manager.
@MainActor
final class AppModel {
    enum Event {
        case ledger(LedgerChange)
        case scope
        case query
        case selection
        case summary
        case newEntry
    }

    let ledger: Ledger
    let undoManager = UndoManager()
    let amounts = AmountFormatter()

    private(set) var snapshot: LedgerSnapshot
    private(set) var tree: AccountTree
    private(set) var primary: Commodity.ID
    private(set) var commodities: [Commodity] = []

    private(set) var scope: Scope = .all
    private var backStack: [Scope] = []
    private var forwardStack: [Scope] = []

    var query = "" {
        didSet { if query != oldValue { send(.query) } }
    }

    /// Selected entries, in list order.
    var selection: [Entry.ID] = [] {
        didSet { if selection != oldValue { send(.selection) } }
    }

    /// A line describing the current list ("1,284 transactions", "Balance −₩267,800").
    var summary = "" {
        didSet { if summary != oldValue { send(.summary) } }
    }

    private struct Observer {
        weak var owner: AnyObject?
        let handler: (Event) -> Void
    }

    private var observers: [Observer] = []

    init(ledger: Ledger) throws {
        self.ledger = ledger
        let stream = ledger.changes()
        let snapshot = ledger.snapshot()
        self.snapshot = snapshot
        tree = try snapshot.accounts()
        primary = try snapshot.primaryCommodity() ?? .iso4217("KRW")
        commodities = try snapshot.commodities()
        amounts.update(commodities)
        listen(to: stream)
    }

    func observe(_ owner: AnyObject, _ handler: @escaping (Event) -> Void) {
        observers.append(Observer(owner: owner, handler: handler))
    }

    private func send(_ event: Event) {
        observers.removeAll { $0.owner == nil }
        for observer in observers { observer.handler(event) }
    }

    private func listen(to stream: AsyncStream<LedgerChange>) {
        Task { [weak self] in
            for await change in stream {
                guard let self else { return }
                self.apply(change)
            }
        }
    }

    private func apply(_ change: LedgerChange) {
        snapshot = change.snapshot
        do {
            if !change.accounts.isEmpty { tree = try snapshot.accounts() }
            if !change.commodities.isEmpty {
                commodities = try snapshot.commodities()
                amounts.update(commodities)
            }
            if change.settings { primary = try snapshot.primaryCommodity() ?? primary }
        } catch {
            present(error)
        }
        send(.ledger(change))
    }

    // MARK: Accounts

    func account(_ id: Account.ID) -> Account? {
        tree[id]
    }

    /// Where postings to `id` land, following merges.
    func resolved(_ id: Account.ID) -> Account.ID {
        var current = id
        var hops = 0
        while let next = tree[current]?.mergedInto, hops < 64 {
            current = next
            hops += 1
        }
        return current
    }

    func name(of id: Account.ID) -> String {
        tree[resolved(id)]?.name ?? String(localized: "Unknown Account")
    }

    func path(of id: Account.ID) -> String {
        tree.path(of: resolved(id), separator: ":")
    }

    /// Live accounts of the given types that people can post to, with their paths, sorted by path.
    func postableAccounts(_ types: Set<AccountType>) -> [(id: Account.ID, path: String)] {
        tree.accounts.values
            .filter { types.contains($0.type) && $0.role == nil && $0.isActive }
            .map { ($0.id, path(of: $0.id)) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func flowText(_ entry: Entry) -> String {
        let flow = EntryFlow(entry)
        func side(_ ids: [Account.ID]) -> String {
            guard let first = ids.first else { return "—" }
            let name = self.name(of: first)
            return ids.count == 1 ? name : String(localized: "\(name) + \(ids.count - 1) more")
        }
        return "\(side(flow.from)) → \(side(flow.to))"
    }

    // MARK: Navigation

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func navigate(to newScope: Scope) {
        guard newScope != scope else { return }
        backStack.append(scope)
        forwardStack.removeAll()
        setScope(newScope)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(scope)
        setScope(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(scope)
        setScope(next)
    }

    private func setScope(_ newScope: Scope) {
        scope = newScope
        query = ""
        selection = []
        send(.scope)
    }

    func title(of scope: Scope) -> String {
        switch scope {
        case .all: String(localized: "All Transactions")
        case .account(let id): name(of: id)
        }
    }

    /// Asks the inspector to start a new entry.
    func beginNewEntry() {
        send(.newEntry)
    }

    // MARK: Entry commands

    @discardableResult
    func post(_ draft: EntryDraft) async throws -> Entry {
        let entry = try await ledger.post(draft)
        registerUndo(String(localized: "Add “\(label(entry))”"), .void([entry.id]))
        return entry
    }

    @discardableResult
    func amend(_ entry: Entry, to draft: EntryDraft) async throws -> Entry {
        let before = EntryDraft(entry)
        let amended = try await ledger.amend(entry, to: draft)
        registerUndo(String(localized: "Edit “\(label(amended))”"), .amend(entry.id, before))
        return amended
    }

    func delete(_ entries: [Entry]) async {
        guard !entries.isEmpty else { return }
        do {
            for entry in entries { try await ledger.void(entry) }
            let name = entries.count == 1
                ? String(localized: "Delete “\(label(entries[0]))”")
                : String(localized: "Delete \(entries.count) Transactions")
            registerUndo(name, .restore(entries))
        } catch {
            present(error)
        }
    }

    private func label(_ entry: Entry) -> String {
        entry.payee ?? String(localized: "Transaction")
    }

    // MARK: Undo

    /// A step that can be undone. Each one knows how to perform itself and what undoes it.
    private enum UndoStep: Sendable {
        case void([Entry.ID])
        case restore([Entry])
        case amend(Entry.ID, EntryDraft)
    }

    private func registerUndo(_ name: String, _ step: UndoStep) {
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.perform(step, name: name) }
        }
        undoManager.setActionName(name)
    }

    /// Runs an undo or redo step. The inverse is registered right away, while the undo manager
    /// is still undoing, so it lands on the redo stack; the ledger write follows asynchronously.
    private func perform(_ step: UndoStep, name: String) {
        let current = ledger.snapshot()
        switch step {
        case .void(let ids):
            let entries = ids.compactMap { try? current.entry($0) }
            registerUndo(name, .restore(entries))
            run {
                for entry in entries {
                    if let fresh = try $0.ledger.snapshot().entry(entry.id) { try await $0.ledger.void(fresh) }
                }
            }
            reveal(ids)
        case .restore(let entries):
            registerUndo(name, .void(entries.map(\.id)))
            run { model in
                for entry in entries { _ = try await model.ledger.restore(entry) }
            }
            reveal(entries.map(\.id))
        case .amend(let id, let draft):
            guard let entry = try? current.entry(id) else { return }
            registerUndo(name, .amend(id, EntryDraft(entry)))
            run { model in
                if let fresh = try model.ledger.snapshot().entry(id) { _ = try await model.ledger.amend(fresh, to: draft) }
            }
            reveal([id])
        }
    }

    private func run(_ work: @escaping @MainActor (AppModel) async throws -> Void) {
        Task {
            do { try await work(self) } catch { present(error) }
        }
    }

    /// Selects what an undo or redo touched, so its effect is visible.
    private func reveal(_ ids: [Entry.ID]) {
        selection = ids
    }

    // MARK: Account commands

    /// Opens an account and, when given, records its starting balance against Opening Balances.
    @discardableResult
    func openAccount(
        name: String, type: AccountType, parent: Account.ID?, openedOn: LocalDate,
        startingBalance: (amount: Int64, commodity: Commodity.ID)?
    ) async throws -> Account {
        let account = try await ledger.openAccount(name: name, type: type, parent: parent, openedOn: openedOn)
        if let balance = startingBalance, balance.amount != 0 {
            let draft = EntryDraft(
                date: openedOn, payee: String(localized: "Starting balance"),
                postings: [
                    Posting(account: account.id, commodity: balance.commodity, amount: balance.amount),
                    Posting(account: SystemAccount.openingBalances, commodity: balance.commodity, amount: -balance.amount),
                ])
            _ = try await ledger.post(draft)
        }
        return account
    }

    // MARK: Errors

    func present(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "The change couldn’t be made.")
        alert.informativeText = message(for: error)
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    func message(for error: Error) -> String {
        guard let error = error as? ValidationError else { return error.localizedDescription }
        switch error {
        case .noPostings:
            return String(localized: "Enter an amount.")
        case .zeroAmount:
            return String(localized: "Amounts can’t be zero.")
        case .unbalanced(let commodity, let residual):
            return String(localized: "The lines don’t add up. \(amounts.string(abs(residual), commodity)) is left over.")
        case .amountOverflow:
            return String(localized: "That amount is too large.")
        case .accountNotOpen(let account, let date):
            return String(localized: "\(name(of: account)) isn’t in use on \(DateText.short(date)). Change the date or choose another account.")
        case .unknownCommodity, .unknownAccount, .unknownEntry, .unknownPrice, .unknownBalanceAssertion, .unknownOp:
            return String(localized: "Something this change refers to no longer exists.")
        case .inactiveCommodity(let commodity):
            return String(localized: "\(amounts.commodity(commodity)?.code ?? "") is hidden. Show it again to use it.")
        case .inactiveAccount(let account):
            return String(localized: "\(name(of: account)) is hidden or no longer in use.")
        case .staleRevision:
            return String(localized: "This transaction was changed elsewhere. It has been reloaded; make your change again.")
        case .alreadyExists:
            return String(localized: "That already exists.")
        case .emptyName:
            return String(localized: "Enter a name.")
        case .duplicateCode:
            return String(localized: "A currency with that code already exists.")
        case .duplicateName:
            return String(localized: "Another account here already has that name.")
        case .invalidScale:
            return String(localized: "Decimal places must be between 0 and 12.")
        case .typeMismatch:
            return String(localized: "An account can only go under an account of the same kind.")
        case .cycle:
            return String(localized: "An account can’t go under itself.")
        case .systemAccount:
            return String(localized: "This account is managed by Cowry and can’t be changed.")
        case .hasChildren(let account):
            return String(localized: "\(name(of: account)) has accounts under it. Move or delete them first.")
        case .hasPostings(let account):
            return String(localized: "\(name(of: account)) has transactions. Stop using it, or merge it into another account.")
        case .hasBalanceAssertions(let account):
            return String(localized: "\(name(of: account)) has balance checks. Remove them first.")
        case .postingsAfterClose(let account, let date):
            return String(localized: "\(name(of: account)) has transactions after \(DateText.short(date)).")
        case .closeBeforeOpen:
            return String(localized: "An account can’t stop before it starts.")
        case .notClosed:
            return String(localized: "This account is already in use.")
        case .mergeIntoSelf:
            return String(localized: "An account can’t be merged into itself.")
        case .samePair:
            return String(localized: "Choose two different currencies.")
        case .invalidSettingValue:
            return String(localized: "That setting value isn’t valid.")
        }
    }
}
