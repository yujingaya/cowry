import AppKit

/// First launch (ux.md §4.9): asks for the main currency and how to start, nothing else.
@MainActor
final class WelcomeWindowController: NSWindowController {
    private let completion: (String, Bool) -> Void
    private let currencyPopup = NSPopUpButton()
    private let suggested = NSButton(radioButtonWithTitle: String(localized: "Start with suggested categories"),
                                     target: nil, action: nil)
    private let empty = NSButton(radioButtonWithTitle: String(localized: "Start empty"), target: nil, action: nil)

    private static let currencies = ["KRW", "USD", "EUR", "JPY", "GBP", "CNY", "HKD", "TWD", "SGD", "AUD", "CAD",
                                     "CHF", "NZD", "SEK", "NOK", "DKK", "THB", "VND", "INR", "IDR", "PHP", "MYR"]

    init(completion: @escaping (String, Bool) -> Void) {
        self.completion = completion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        super.init(window: window)
        window.contentView = makeContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func makeContent() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let title = NSTextField(labelWithString: "Cowry")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        let tagline = NSTextField(wrappingLabelWithString: String(localized: "Keep an accurate record of your money, and get an instant answer to any question you ask of it."))
        tagline.textColor = .secondaryLabelColor
        let header = NSStackView(views: [icon, NSStackView(views: [title, tagline])])
        (header.arrangedSubviews[1] as? NSStackView)?.orientation = .vertical
        (header.arrangedSubviews[1] as? NSStackView)?.alignment = .leading
        header.spacing = 14

        let locale = Locale.current.currency?.identifier ?? "KRW"
        var codes = Self.currencies
        if !codes.contains(locale) { codes.insert(locale, at: 0) }
        for code in codes {
            let name = Locale.current.localizedString(forCurrencyCode: code) ?? code
            currencyPopup.addItem(withTitle: "\(name) (\(code))")
            currencyPopup.lastItem?.representedObject = code
        }
        currencyPopup.selectItem(at: codes.firstIndex(of: locale) ?? 0)
        let currencyNote = NSTextField(wrappingLabelWithString: String(localized: "From your Mac’s region settings. Totals and reports use this currency."))
        currencyNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        currencyNote.textColor = .secondaryLabelColor

        suggested.state = .on
        suggested.target = self
        suggested.action = #selector(radioChanged(_:))
        empty.target = self
        empty.action = #selector(radioChanged(_:))

        let grid = NSGridView(views: [
            [label(String(localized: "Main currency")), currencyPopup],
            [NSGridCell.emptyContentView, currencyNote],
            [label(String(localized: "Start")), suggested],
            [NSGridCell.emptyContentView, empty],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.rowAlignment = .firstBaseline
        currencyNote.preferredMaxLayoutWidth = 340

        let lock = NSImageView(image: NSImage(systemSymbolName: "lock", accessibilityDescription: nil)!)
        let privacy = NSTextField(wrappingLabelWithString: String(localized: "Your ledger stays on this Mac. No sign-up, no servers."))
        privacy.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        privacy.textColor = .secondaryLabelColor
        let start = NSButton(title: String(localized: "Get Started"), target: self, action: #selector(start(_:)))
        start.keyEquivalent = "\r"
        let footer = NSStackView(views: [lock, privacy, NSView(), start])
        footer.spacing = 8

        let stack = NSStackView(views: [header, grid, NSView(), footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.edgeInsets = NSEdgeInsets(top: 48, left: 44, bottom: 28, right: 44)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -88).isActive = true
        tagline.preferredMaxLayoutWidth = 380
        return stack
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        return field
    }

    @objc private func radioChanged(_ sender: NSButton) {
        suggested.state = sender === suggested ? .on : .off
        empty.state = sender === empty ? .on : .off
    }

    @objc private func start(_ sender: Any?) {
        let code = currencyPopup.selectedItem?.representedObject as? String ?? "KRW"
        completion(code, suggested.state == .on)
    }
}
