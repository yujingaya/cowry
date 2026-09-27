import AppKit
import Ledger
import LedgerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, CowryActions {
    private var model: AppModel?
    private var windowController: MainWindowController?
    private var welcome: WelcomeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        #if DEBUG
        // `-CowrySampleYears N` skips the welcome window and fills a new library with sample data.
        let sampleYears = UserDefaults.standard.integer(forKey: "CowrySampleYears")
        if sampleYears > 0, !Library.exists {
            openLibrary(primaryCurrency: "KRW")
            let perDay = max(1, UserDefaults.standard.integer(forKey: "CowrySamplePerDay"))
            if let model {
                Task {
                    let start = ContinuousClock.now
                    await SampleData.add(to: model, years: sampleYears, perDay: perDay)
                    FileHandle.standardError.write(Data("[perf] sample data: \(ContinuousClock.now - start)\n".utf8))
                }
            }
            return
        }
        #endif
        if Library.exists {
            #if DEBUG
            defer { if UserDefaults.standard.bool(forKey: "CowryExerciseNavigation") { exerciseNavigation() } }
            #endif
            openLibrary(primaryCurrency: nil)
        } else {
            let welcome = WelcomeWindowController { [weak self] currency, suggested in
                self?.createLibrary(primaryCurrency: currency, suggested: suggested)
            }
            self.welcome = welcome
            welcome.showWindow(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController?.showWindow(nil) }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func createLibrary(primaryCurrency: String, suggested: Bool) {
        welcome?.close()
        welcome = nil
        openLibrary(primaryCurrency: primaryCurrency)
        if suggested, let model {
            Task {
                do { try await SuggestedAccounts.create(in: model) } catch { model.present(error) }
            }
        }
    }

    private func openLibrary(primaryCurrency: String?) {
        do {
            try Library.prepareDirectory()
            let ledger = try Ledger(at: Library.url, device: Library.device,
                                    primaryCurrency: primaryCurrency ?? Locale.current.currency?.identifier ?? "KRW")
            let model = try AppModel(ledger: ledger)
            self.model = model
            let controller = MainWindowController(model: model)
            windowController = controller
            controller.showWindow(nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "Cowry couldn’t open your ledger.")
            alert.informativeText = "\(Library.url.path)\n\n\(error)"
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    // MARK: Actions

    @objc func showLibraryInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([Library.url])
    }

    #if DEBUG
    @objc func addSampleData(_ sender: Any?) {
        guard let model else { return }
        Task { await SampleData.add(to: model, years: 5, perDay: 6) }
    }

    @objc func addLargeSampleData(_ sender: Any?) {
        guard let model else { return }
        Task { await SampleData.add(to: model, years: 20, perDay: 13) }
    }
    #endif

    #if DEBUG
    /// `-CowryExerciseNavigation YES`: visits every account and category, searching in each and
    /// going back and forward, then quits. A smoke test for list reloads with rows on screen.
    private func exerciseNavigation() {
        guard let model else { return }
        Task {
            let accounts = model.tree.accounts.values.filter { $0.role == nil && $0.isActive }.map(\.id)
            let scopes = [Scope.all] + accounts.map(Scope.account) + [Scope.all]
            for scope in scopes {
                model.navigate(to: scope)
                try? await Task.sleep(for: .milliseconds(30))
                model.query = "스"
                try? await Task.sleep(for: .milliseconds(30))
                model.query = ""
                try? await Task.sleep(for: .milliseconds(30))
            }
            for _ in 0 ..< 3 { model.goBack() }
            for _ in 0 ..< 3 { model.goForward() }
            FileHandle.standardError.write(Data("[exercise] visited \(scopes.count) scopes without crashing\n".utf8))
            NSApp.terminate(nil)
        }
    }
    #endif

    @objc func verifyLedger(_ sender: Any?) {
        guard let model else { return }
        let alert = NSAlert()
        do {
            let started = Date()
            let report = try model.ledger.verify()
            let seconds = Date().timeIntervalSince(started)
            alert.messageText = report.isValid ? "Ledger verified" : "Ledger has problems"
            alert.informativeText = "\(report.opsChecked) ops replayed in \(String(format: "%.2f", seconds)) s."
                + (report.isValid ? "" : "\n\n\(report.problems.prefix(5))")
        } catch {
            alert.messageText = "Verification failed"
            alert.informativeText = "\(error)"
        }
        alert.runModal()
    }
}

/// The categories offered on first launch (ux.md §4.9).
enum SuggestedAccounts {
    @MainActor
    static func create(in model: AppModel) async throws {
        let today = LocalDate.today()
        let start = LocalDate(year: today.year, month: 1, day: 1)!
        _ = try await model.openAccount(name: String(localized: "Cash"), type: .asset, parent: nil,
                                        openedOn: start, startingBalance: nil)
        let food = try await model.openAccount(name: String(localized: "Food"), type: .expense, parent: nil,
                                               openedOn: start, startingBalance: nil)
        for name in [String(localized: "Cafés"), String(localized: "Dining Out"), String(localized: "Groceries")] {
            _ = try await model.openAccount(name: name, type: .expense, parent: food.id, openedOn: start, startingBalance: nil)
        }
        for name in [
            String(localized: "Housing"), String(localized: "Transportation"), String(localized: "Shopping"),
            String(localized: "Household"), String(localized: "Health"), String(localized: "Culture"),
            String(localized: "Education"), String(localized: "Phone and Internet"), String(localized: "Gifts"),
        ] {
            _ = try await model.openAccount(name: name, type: .expense, parent: nil, openedOn: start, startingBalance: nil)
        }
        for name in [String(localized: "Salary"), String(localized: "Other Income")] {
            _ = try await model.openAccount(name: name, type: .income, parent: nil, openedOn: start, startingBalance: nil)
        }
    }
}
